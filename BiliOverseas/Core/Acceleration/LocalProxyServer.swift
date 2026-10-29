import Foundation
import Network

// Loopback HTTP/1.1 server for AVPlayer (proxy-ports §5.2, §6.6):
// - NWListener bound to 127.0.0.1 only (`requiredLocalEndpoint`, plus a loopback check per connection; not
//   `acceptLocalOnly`, a local-link filter that is not needed here), an ephemeral port the first
//   time, the SAME port again when it has to be rebuilt (the app was suspended, `ensureListening()`), so the URLs
//   of items already handed to AVPlayer stay valid;
// - keep-alive with several sequential requests per connection (`Connection: close` honoured), back-pressure by
//   awaiting every send's completion, client disconnect (read side EOF / error / cancelled state) cancels the task
//   producing the response;
// - a body that cannot be completed after the head was sent closes the connection (truncation, never padding).
// Request routing / content come from `LocalProxyRequestHandler` (AccelerationEngine).

/// Opt-in event trace of the loopback server (smoke test / diagnostics). Bounded so a long session cannot flood
/// the log; costs nothing while no sink is set.
enum LocalProxyTrace {
    private static let lock = NSLock()
    private static var sink: (@Sendable (String) -> Void)?
    private static var remaining = 0

    static func setSink(_ newSink: (@Sendable (String) -> Void)?, limit: Int = 400) {
        lock.lock()
        sink = newSink
        remaining = limit
        lock.unlock()
    }

    static func log(_ message: @autoclosure () -> String) {
        lock.lock()
        guard let sink, remaining > 0 else {
            lock.unlock()
            return
        }
        remaining -= 1
        lock.unlock()
        sink(message())
    }
}

enum LocalProxyServerError: Error, Equatable {
    case timeout
    case listenerFailed(String)
}

final class LocalProxyServer: LocalProxyServing, @unchecked Sendable {
    private enum Phase {
        case stopped, starting, ready, failed
    }

    private weak var handler: LocalProxyRequestHandler?
    private let queue = DispatchQueue(label: "bili.localproxy.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var phase: Phase = .stopped
    private var generation = 0
    private var boundPort: UInt16 = 0
    private var preferredPort: UInt16
    private var readyWaiters: [UUID: CheckedContinuation<UInt16, Error>] = [:]
    private var connections: [ObjectIdentifier: LocalProxyConnection] = [:]
    private var portChangeHandler: ((UInt16) -> Void)?

    /// - Parameter preferredPort: 0 = let the system pick (normal); the chosen port is reused on every rebind.
    init(handler: LocalProxyRequestHandler, preferredPort: UInt16 = 0) {
        self.handler = handler
        self.preferredPort = preferredPort
    }

    deinit {
        listener?.cancel()
    }

    var onPortChange: ((UInt16) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return portChangeHandler
        }
        set {
            lock.lock()
            portChangeHandler = newValue
            lock.unlock()
        }
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return phase == .ready ? boundPort : 0
    }

    var openConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func start() {
        lock.lock()
        let running = phase == .starting || phase == .ready
        let port = preferredPort
        lock.unlock()
        if !running { startListener(port: port, allowFallback: true) }
    }

    /// Foreground check: a listener that died while the app was suspended is rebuilt on the same port.
    func ensureListening() {
        start()
    }

    func waitUntilReady(timeout: TimeInterval) async throws -> UInt16 {
        start()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                lock.lock()
                if phase == .ready {
                    let port = boundPort
                    lock.unlock()
                    continuation.resume(returning: port)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyWaiters[id] = continuation
                lock.unlock()
                queue.asyncAfter(deadline: .now() + max(0.1, timeout)) {
                    self.failWaiter(id, LocalProxyServerError.timeout)
                }
            }
        } onCancel: {
            self.failWaiter(id, CancellationError())
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        let old = listener
        listener = nil
        phase = .stopped
        let open = Array(connections.values)
        connections = [:]
        let waiters = Array(readyWaiters.values)
        readyWaiters = [:]
        lock.unlock()
        old?.cancel()
        for connection in open { connection.cancel() }
        for waiter in waiters { waiter.resume(throwing: LocalProxyServerError.listenerFailed("stopped")) }
    }

    // MARK: Listener

    private func startListener(port: UInt16, allowFallback: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            if allowFallback && port != 0 {
                startListener(port: 0, allowFallback: false)
            } else {
                markFailed(error)
            }
            return
        }
        lock.lock()
        generation += 1
        let gen = generation
        let old = listener
        listener = created
        phase = .starting
        lock.unlock()
        old?.cancel()

        created.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        created.stateUpdateHandler = { [weak self, weak created] state in
            self?.listenerStateChanged(state, generation: gen, listener: created, requestedPort: port,
                                       allowFallback: allowFallback)
        }
        created.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, generation gen: Int, listener: NWListener?,
                                      requestedPort: UInt16, allowFallback: Bool) {
        LocalProxyTrace.log("listener#\(gen) \(state) port=\(listener?.port?.rawValue ?? 0)")
        switch state {
        case .ready:
            let actual = listener?.port?.rawValue ?? 0
            lock.lock()
            guard gen == generation else {
                lock.unlock()
                return
            }
            phase = .ready
            boundPort = actual
            let changed = preferredPort != 0 && preferredPort != actual
            preferredPort = actual
            let waiters = Array(readyWaiters.values)
            readyWaiters = [:]
            let callback = portChangeHandler
            lock.unlock()
            for waiter in waiters { waiter.resume(returning: actual) }
            if changed { callback?(actual) }
        case .failed(let error), .waiting(let error):
            lock.lock()
            guard gen == generation else {
                lock.unlock()
                return
            }
            let wasReady = phase == .ready
            self.listener = nil
            phase = .failed
            let samePort = preferredPort
            lock.unlock()
            listener?.cancel()
            if wasReady {
                // Died after being ready (e.g. while suspended): one immediate attempt on the same port; if that
                // fails too, `ensureListening()` retries when the app returns to the foreground.
                startListener(port: samePort, allowFallback: false)
            } else if allowFallback && requestedPort != 0 {
                // The old port is taken: take any port (items using the old URLs must be rebuilt).
                startListener(port: 0, allowFallback: false)
            } else {
                markFailed(error)
            }
        case .cancelled:
            lock.lock()
            if gen == generation {
                self.listener = nil
                phase = .stopped
            }
            lock.unlock()
        default:
            break
        }
    }

    private func markFailed(_ error: Error) {
        lock.lock()
        phase = .failed
        let waiters = Array(readyWaiters.values)
        readyWaiters = [:]
        lock.unlock()
        let failure = LocalProxyServerError.listenerFailed(String(describing: error))
        for waiter in waiters { waiter.resume(throwing: failure) }
    }

    private func failWaiter(_ id: UUID, _ error: Error) {
        lock.lock()
        let waiter = readyWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        if case let .hostPort(host, _) = nw.endpoint, !Self.isLoopback(host) {
            LocalProxyTrace.log("reject non-loopback peer \(nw.endpoint)")
            nw.cancel()
            return
        }
        LocalProxyTrace.log("accept \(nw.endpoint)")
        guard let handler else {
            nw.cancel()
            return
        }
        let connection = LocalProxyConnection(nw, handler: handler)
        let id = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in self?.removeConnection(id) }
        lock.lock()
        connections[id] = connection
        lock.unlock()
        connection.start()
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }

    /// 127.0.0.0/8, ::1 and IPv4-mapped 127/8. (`IPv4Address.isLoopback` is true for 127.0.0.1 only.)
    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        func loopbackV4(_ address: IPv4Address) -> Bool {
            address.isLoopback || address.rawValue.first == 127
        }
        switch host {
        case .ipv4(let address):
            return loopbackV4(address)
        case .ipv6(let address):
            return address.isLoopback || (address.asIPv4.map(loopbackV4) ?? false)
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }
}

/// One accepted client connection: reads request heads, answers them in order, streams bodies.
final class LocalProxyConnection: @unchecked Sendable {
    static let receiveChunk = 64 * 1024
    /// Unread input beyond this closes the connection (a client never needs to send that much here).
    static let maxInboxBytes = 1 << 20

    var onClose: (() -> Void)?

    private let connection: NWConnection
    private weak var handler: LocalProxyRequestHandler?
    private let queue = DispatchQueue(label: "bili.localproxy.connection")
    private let lock = NSLock()
    private var inbox = Data()
    private var inboxVersion = 0
    private var peerClosed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var serveTask: Task<Void, Never>?
    private var finished = false

    init(_ connection: NWConnection, handler: LocalProxyRequestHandler) {
        self.connection = connection
        self.handler = handler
    }

    /// Short id in trace lines.
    private let traceId = String(UInt32.random(in: 0..<100_000))

    func start() {
        let tid = traceId
        connection.stateUpdateHandler = { [weak self] state in
            LocalProxyTrace.log("conn \(tid) state \(state)")
            switch state {
            case .failed, .cancelled:
                self?.peerGone()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMore()
        let task = Task { await self.serve() }
        lock.lock()
        serveTask = task
        let gone = peerClosed
        lock.unlock()
        if gone { task.cancel() }
    }

    /// Server shutdown.
    func cancel() {
        peerGone()
    }

    private var isPeerClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerClosed
    }

    // MARK: Read side

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            LocalProxyTrace.log("conn \(self.traceId) recv \(data?.count ?? 0)B complete=\(isComplete) error=\(error.map { "\($0)" } ?? "nil")")
            var overflow = false
            self.lock.lock()
            if let data, !data.isEmpty {
                self.inbox.append(data)
                self.inboxVersion += 1
                overflow = self.inbox.count > Self.maxInboxBytes
            }
            let ended = isComplete || error != nil || overflow
            if ended { self.peerClosed = true }
            let waiting = self.waiter
            self.waiter = nil
            self.lock.unlock()
            waiting?.resume()
            if ended {
                self.peerGone()
            } else {
                self.receiveMore()
            }
        }
    }

    /// Client went away (EOF / error / cancelled): stop whatever is producing the current response.
    private func peerGone() {
        lock.lock()
        peerClosed = true
        let waiting = waiter
        waiter = nil
        let task = serveTask
        lock.unlock()
        waiting?.resume()
        task?.cancel()
        connection.cancel()
    }

    private func waitForInput(after version: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if inboxVersion != version || peerClosed || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            self.wakeWaiter()
        }
    }

    private func wakeWaiter() {
        lock.lock()
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    /// First bytes of an unparseable request head (trace only).
    private func rejectedHeadPreview() -> String {
        lock.lock()
        let head = inbox.prefix(160)
        lock.unlock()
        return String(decoding: head, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "⏎")
    }

    private enum NextStep {
        case request(ProxyHTTPRequest)
        case reject(Int)
        case wait(Int)
        case end
    }

    /// Parses the next request head out of the inbox (synchronous: NSLock is not used across suspension points).
    private func takeNextStep() -> NextStep {
        lock.lock()
        defer { lock.unlock() }
        switch HTTPRequestParser.parse(inbox) {
        case let .complete(request, consumed):
            inbox = consumed >= inbox.count ? Data() : Data(inbox[(inbox.startIndex + consumed)...])
            return .request(request)
        case .tooLarge:
            return .reject(431)
        case .invalid:
            return .reject(400)
        case .incomplete:
            return peerClosed ? .end : .wait(inboxVersion)
        }
    }

    private func nextRequest() async -> ProxyHTTPRequest? {
        while !Task.isCancelled {
            switch takeNextStep() {
            case .request(let request):
                return request
            case .reject(let status):
                LocalProxyTrace.log("conn \(traceId) reject \(status) head=\(rejectedHeadPreview())")
                let head = ProxyHTTPResponseHead(status: status, headers: [("Content-Length", "0"),
                                                                           ("Connection", "close")])
                try? await send(head.serialized)
                return nil
            case .wait(let version):
                await waitForInput(after: version)
            case .end:
                return nil
            }
        }
        return nil
    }

    // MARK: Serving

    private func serve() async {
        while !Task.isCancelled {
            guard let request = await nextRequest() else { break }
            let keepAlive = await respond(to: request)
            if !keepAlive { break }
        }
        finish()
    }

    private func finish() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        LocalProxyTrace.log("conn \(traceId) finish peerClosed=\(isPeerClosed)")
        connection.cancel()
        onClose?()
    }

    /// Writes one response. Returns whether the connection may serve another request.
    private func respond(to request: ProxyHTTPRequest) async -> Bool {
        guard let handler else {
            LocalProxyTrace.log("conn \(traceId) no handler for \(request.method) \(request.path)")
            return false
        }
        let response = await handler.handle(request)
        LocalProxyTrace.log("conn \(traceId) \(request.method) \(request.path) range=\(request.header("range") ?? "-") -> \(response.status) len=\(response.contentLength)")
        let keepAlive = !request.wantsClose && !response.closeConnection && !request.hasBody
        var headers = response.headers
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        let head = ProxyHTTPResponseHead(status: response.status, headers: headers).serialized
        let isHead = request.method.uppercased() == "HEAD"
        do {
            try Task.checkCancellation()
            switch response.body {
            case .none:
                try await send(head)
            case .data(let data):
                if isHead || data.isEmpty {
                    try await send(head)
                } else if data.count <= 64 * 1024 {
                    try await send(head + data)
                } else {
                    try await send(head)
                    try await send(data)
                }
            case .stream(let source):
                defer { source.cancel() }
                try await send(head)
                if isHead { break }
                var sent: Int64 = 0
                while sent < response.contentLength {
                    try Task.checkCancellation()
                    guard let chunk = try await source.nextChunk() else { break }
                    if chunk.isEmpty { continue }
                    let remaining = response.contentLength - sent
                    let piece = Int64(chunk.count) > remaining ? Data(chunk.prefix(Int(remaining))) : chunk
                    try await send(piece)
                    sent += Int64(piece.count)
                }
                // Short body after the head: close so the client sees the truncation.
                if sent < response.contentLength { return false }
            }
        } catch {
            LocalProxyTrace.log("conn \(traceId) response aborted: \(error)")
            if case .stream(let source) = response.body { source.cancel() }
            return false
        }
        return keepAlive
    }

    /// Sends and waits until the stack took the bytes (back-pressure).
    private func send(_ data: Data) async throws {
        if isPeerClosed { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
