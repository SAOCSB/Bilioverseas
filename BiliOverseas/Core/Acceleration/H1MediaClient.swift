import Foundation
import Network
import Security

/// HTTP/1.1 upstream client on Network.framework (proxy-ports spec §6.3 (a)).
///
/// TLS ALPN is pinned to `http/1.1`, so N in-flight requests really are N TCP connections; URLSession would negotiate
/// HTTP/2 and multiplex (or even coalesce hosts) onto one connection, which defeats BTR's multi-connection speed-up.
///
/// - One request per connection at a time. Completed responses whose framing allows it return the connection to a
///   per-origin LIFO idle pool (`idleTimeout`, checked `.ready` before reuse, watched for server close while idle).
///   Cancelled, failed or partially read connections are closed, never reused.
/// - If a pooled connection fails before any response byte arrives, the request is retried once, transparently, on a
///   fresh connection.
/// - At most `maxConnectionsPerHost` connections (busy + idle + connecting) per origin; further requests wait FIFO
///   (high-priority ones ahead of the others).
/// - Back-pressure: at most ~`maxBufferedBytesPerRequest` of body bytes not yet taken by the consumer; reading pauses
///   (TCP flow control then throttles the server) and resumes on demand. No data is ever dropped.
/// - Timeouts: `connectTimeout` (TCP + TLS) and a backstop `responseTimeout` of reading silence. The downloader runs
///   BTR's first-byte / stall / attempt timers itself and cancels the consuming task.
///
/// Stream contract (`get`): `.head` exactly once first (1xx skipped; any status, including 403/404, is a head, not an
/// error), then `.data` in order, then the stream ends (body complete per Content-Length / chunked / close) or throws:
/// - `.invalidURL`: not http(s), no host, or `range.end < range.start` (thrown before any head);
/// - `.connectFailed`: DNS / refused / unreachable / `connectTimeout`, or no response byte within `responseTimeout`;
/// - `.tls`: handshake or record failure (`NWError.tls`; a TLS close alert after the handshake is a hang-up:
///   `.connectionClosed`);
/// - `.malformedResponse`: bad status line, header section > 64 KiB, bad Content-Length / chunk framing;
/// - `.connectionClosed`: EOF or reset before the body was complete (also a mid-body `responseTimeout` stall);
/// - `.cancelled`: the consumer's task was cancelled while waiting in `next()`. If it was cancelled before calling
///   `next()`, the stream just ends (standard `AsyncThrowingStream` behaviour) — check `Task.isCancelled`.
/// Cancelling the task or dropping the stream/iterator force-closes the connection (RST) so the server stops sending.
///
/// Thread safety: all state lives on one serial queue (also the NWConnection callback queue); the open-connection
/// counter is lock-protected. Configure the `var` tunables before the first request.
final class H1MediaClient: MediaHTTPClient {
    let maxConnectionsPerHost: Int
    let userAgent: String
    let idleTimeout: TimeInterval
    let connectTimeout: TimeInterval
    /// Backstop: fail a request when nothing arrives for this long while we are waiting for response bytes.
    var responseTimeout: TimeInterval = 30
    /// Body bytes buffered for a slow consumer before reading pauses.
    var maxBufferedBytesPerRequest = MediaEventPipe.defaultHighWaterBytes
    /// `maximumLength` of each `NWConnection.receive`.
    var receiveChunkSize = 128 * 1024

    private let queue = DispatchQueue(label: "bili.h1-media-client", qos: .userInitiated)
    private let countLock = NSLock()
    private var openConnections = 0
    // Queue-confined:
    private var pools: [H1Origin: HostPool] = [:]

    init(maxConnectionsPerHost: Int = 64, userAgent: String = BiliHTTP.webUserAgent,
         idleTimeout: TimeInterval = 30, connectTimeout: TimeInterval = 10) {
        self.maxConnectionsPerHost = max(1, maxConnectionsPerHost)
        self.userAgent = userAgent
        self.idleTimeout = idleTimeout
        self.connectTimeout = connectTimeout
    }

    deinit {
        // Queue blocks and NW callbacks hold `self` weakly, so nothing else touches `pools` now.
        for pool in pools.values {
            for ex in pool.waiters where !ex.finished {
                ex.finished = true
                ex.pipe.finish(throwing: MediaFetchError.cancelled)
            }
            for c in pool.live {
                c.state = .closed
                c.nw.stateUpdateHandler = nil
                c.nw.forceCancel()
                if let ex = c.exchange {
                    // Break the Connection <-> Exchange cycle, or both (and the NWConnection) leak.
                    c.exchange = nil
                    ex.connection = nil
                    if !ex.finished {
                        ex.finished = true
                        ex.pipe.finish(throwing: MediaFetchError.cancelled)
                    }
                }
            }
        }
    }

    // MARK: - MediaHTTPClient

    var openConnectionCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return openConnections
    }

    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error> {
        let pipe = MediaEventPipe(highWaterBytes: maxBufferedBytesPerRequest)
        guard let target = H1RequestTarget(url: url), range.start >= 0, range.end >= range.start else {
            pipe.finish(throwing: MediaFetchError.invalidURL)
            return pipe.makeStream()
        }
        let request = H1RequestSerializer.rangeGET(target, range: range, userAgent: userAgent)
        let ex = Exchange(origin: target.origin, request: request, highPriority: highPriority, pipe: pipe)
        pipe.setHandlers(
            onDemand: { [weak self, weak ex] in
                guard let self, let ex else { return }
                self.queue.async { self.resumeReading(ex) }
            },
            onCancel: { [weak self, weak ex] in
                guard let self, let ex else { return }
                self.queue.async { self.cancelExchange(ex) }
            }
        )
        queue.async { self.submit(ex) }
        return pipe.makeStream()
    }

    func preconnect(hosts: [String]) {
        let origins = hosts.compactMap { H1Origin(hostSpec: $0) }
        guard !origins.isEmpty else { return }
        queue.async {
            for origin in origins {
                let pool = self.pool(for: origin)
                guard pool.idle.isEmpty, pool.spares.isEmpty, pool.live.count < self.maxConnectionsPerHost else { continue }
                let c = self.openConnection(origin, highPriority: false)
                pool.spares.append(c)
            }
        }
    }

    func closeIdleConnections() {
        queue.async {
            for pool in Array(self.pools.values) {
                for c in pool.idle + pool.spares { self.close(c, force: false) }
            }
        }
    }

    // MARK: - Model (queue-confined)

    private final class HostPool {
        let origin: H1Origin
        /// Every open connection of this origin (busy, idle, connecting).
        var live: [Connection] = []
        /// Ready, unassigned; LIFO (most recently used last).
        var idle: [Connection] = []
        /// Preconnected and still connecting, unassigned.
        var spares: [Connection] = []
        /// Requests waiting for a connection slot, FIFO.
        var waiters: [Exchange] = []
        init(origin: H1Origin) { self.origin = origin }
    }

    private final class Connection {
        enum State { case connecting, ready, closed }
        let origin: H1Origin
        let nw: NWConnection
        var state: State = .connecting
        var exchange: Exchange?
        var receivePending = false
        var idleSince: TimeInterval = 0
        var idleGeneration = 0
        init(origin: H1Origin, nw: NWConnection) {
            self.origin = origin
            self.nw = nw
        }
    }

    private final class Exchange {
        let origin: H1Origin
        let request: Data
        let highPriority: Bool
        let pipe: MediaEventPipe
        var parser = H1ResponseParser()
        var connection: Connection?
        var finished = false
        /// Sent on a connection taken from the idle pool (eligible for one transparent retry).
        var onPooledConnection = false
        var retried = false
        var gotResponseBytes = false
        var receivePaused = false
        var lastActivity: TimeInterval = 0
        var attempt = 0
        init(origin: H1Origin, request: Data, highPriority: Bool, pipe: MediaEventPipe) {
            self.origin = origin
            self.request = request
            self.highPriority = highPriority
            self.pipe = pipe
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func pool(for origin: H1Origin) -> HostPool {
        if let p = pools[origin] { return p }
        let p = HostPool(origin: origin)
        pools[origin] = p
        return p
    }

    // MARK: - Scheduling

    private func submit(_ ex: Exchange) {
        guard !ex.finished else { return }
        let pool = pool(for: ex.origin)
        let now = Self.now
        while let c = pool.idle.popLast() {
            if case .ready = c.nw.state, c.state == .ready, now - c.idleSince < idleTimeout {
                start(ex, on: c, pooled: true)
                return
            }
            close(c, force: false, serviceWaiters: false)
        }
        if !pool.spares.isEmpty {
            let c = pool.spares.removeFirst()
            attach(ex, to: c) // sent once it is ready
            return
        }
        if pool.live.count < maxConnectionsPerHost {
            attach(ex, to: openConnection(ex.origin, highPriority: ex.highPriority))
            return
        }
        // High-priority requests (BTR startup / meta / early pieces) queue ahead of normal ones; FIFO within a class.
        if ex.highPriority, let i = pool.waiters.firstIndex(where: { !$0.highPriority }) {
            pool.waiters.insert(ex, at: i)
        } else {
            pool.waiters.append(ex)
        }
    }

    private func attach(_ ex: Exchange, to c: Connection) {
        c.exchange = ex
        ex.connection = c
    }

    @discardableResult
    private func detach(_ ex: Exchange) -> Connection? {
        guard let c = ex.connection else { return nil }
        ex.connection = nil
        if c.exchange === ex { c.exchange = nil }
        return c
    }

    /// Give a finished connection to the next waiter, or park it in the idle pool.
    private func release(_ c: Connection) {
        c.exchange = nil
        let pool = pool(for: c.origin)
        while !pool.waiters.isEmpty {
            let w = pool.waiters.removeFirst()
            if w.finished { continue }
            start(w, on: c, pooled: true)
            return
        }
        c.idleSince = Self.now
        c.idleGeneration &+= 1
        pool.idle.append(c)
        let generation = c.idleGeneration
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self, weak c] in
            guard let self, let c, c.state == .ready, c.exchange == nil, c.idleGeneration == generation else { return }
            self.close(c, force: false)
        }
        receive(on: c) // notice the server closing the idle connection
    }

    /// Open connections for queued requests while there is room under the per-host cap.
    private func serviceWaiters(_ pool: HostPool) {
        while pool.live.count < maxConnectionsPerHost, !pool.waiters.isEmpty {
            let w = pool.waiters.removeFirst()
            if w.finished { continue }
            attach(w, to: openConnection(pool.origin, highPriority: w.highPriority))
        }
    }

    // MARK: - Connections

    private func makeParameters(for origin: H1Origin, highPriority: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        let parameters: NWParameters
        if origin.isTLS {
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            if !origin.isIPLiteral {
                sec_protocol_options_set_tls_server_name(sec, origin.host)
            }
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.serviceClass = highPriority ? .responsiveData : .bestEffort
        return parameters
    }

    private func openConnection(_ origin: H1Origin, highPriority: Bool) -> Connection {
        let nw = NWConnection(host: NWEndpoint.Host(origin.host),
                              port: NWEndpoint.Port(rawValue: origin.port) ?? .https,
                              using: makeParameters(for: origin, highPriority: highPriority))
        let c = Connection(origin: origin, nw: nw)
        pool(for: origin).live.append(c)
        countLock.lock()
        openConnections += 1
        countLock.unlock()
        // The handler retains `c` (and so `nw`): the cycle is broken in close().
        nw.stateUpdateHandler = { [weak self] state in
            self?.connection(c, didChange: state)
        }
        nw.start(queue: queue)
        let timeout = connectTimeout
        queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak c] in
            guard let self, let c, c.state == .connecting else { return }
            self.connectFailed(c, .connectFailed("connect to \(c.origin) timed out after \(Int(timeout)) s"))
        }
        return c
    }

    private func connection(_ c: Connection, didChange state: NWConnection.State) {
        guard c.state != .closed else { return }
        switch state {
        case .ready:
            guard c.state == .connecting else { return }
            c.state = .ready
            if let ex = c.exchange {
                start(ex, on: c, pooled: false)
            } else {
                let pool = pool(for: c.origin)
                if let i = pool.spares.firstIndex(where: { $0 === c }) { pool.spares.remove(at: i) }
                release(c)
            }
        case .waiting(let error), .failed(let error):
            // `.waiting` means "can't connect right now" (refused, no route, DNS…): fail fast, BTR picks another node.
            if c.state == .connecting {
                connectFailed(c, Self.connectError(error))
            } else {
                connectionLost(c, Self.ioError(error))
            }
        case .cancelled:
            connectionLost(c, .connectionClosed)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func connectFailed(_ c: Connection, _ error: MediaFetchError) {
        if let ex = c.exchange {
            fail(ex, error)
        } else {
            close(c)
        }
    }

    private func connectionLost(_ c: Connection, _ error: MediaFetchError) {
        if let ex = c.exchange {
            failOrRetry(ex, error)
        } else {
            close(c)
        }
    }

    /// `force`: abort (RST) instead of a graceful close — for in-flight requests, so the server stops sending now.
    private func close(_ c: Connection, force: Bool = true, serviceWaiters: Bool = true) {
        guard c.state != .closed else { return }
        c.state = .closed
        c.nw.stateUpdateHandler = nil
        if force { c.nw.forceCancel() } else { c.nw.cancel() }
        if let ex = c.exchange {
            c.exchange = nil
            if ex.connection === c { ex.connection = nil }
        }
        let pool = pool(for: c.origin)
        pool.live.removeAll { $0 === c }
        pool.idle.removeAll { $0 === c }
        pool.spares.removeAll { $0 === c }
        countLock.lock()
        openConnections -= 1
        countLock.unlock()
        if serviceWaiters { self.serviceWaiters(pool) }
        // Pools are kept (a few dozen CDN origins at most) so callers' local `pool` references never go stale.
    }

    // MARK: - Exchanges

    private func start(_ ex: Exchange, on c: Connection, pooled: Bool) {
        attach(ex, to: c)
        ex.onPooledConnection = pooled
        ex.parser = H1ResponseParser()
        ex.gotResponseBytes = false
        ex.receivePaused = false
        ex.attempt += 1
        ex.lastActivity = Self.now
        c.nw.send(content: ex.request, completion: .contentProcessed { [weak self] error in
            guard let self, let error, c.exchange === ex else { return }
            self.failOrRetry(ex, Self.ioError(error))
        })
        receive(on: c)
        scheduleBackstop(ex, attempt: ex.attempt, after: responseTimeout)
    }

    private func receive(on c: Connection) {
        guard !c.receivePending, c.state != .closed else { return }
        c.receivePending = true
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkSize) { [weak self] data, _, isComplete, error in
            c.receivePending = false
            self?.connection(c, didReceive: data, isComplete: isComplete, error: error)
        }
    }

    private func connection(_ c: Connection, didReceive data: Data?, isComplete: Bool, error: NWError?) {
        guard c.state != .closed else { return }
        guard let ex = c.exchange, !ex.finished else {
            // Idle (pooled) connection: bytes, EOF or an error all mean it can't carry another request.
            close(c, force: true)
            return
        }
        guard c.state == .ready else { return }
        if let data, !data.isEmpty {
            ex.gotResponseBytes = true
            ex.lastActivity = Self.now
            let events: [H1ParseEvent]
            do {
                events = try ex.parser.feed(data)
            } catch {
                fail(ex, .malformedResponse(String(describing: error)))
                return
            }
            var more = true
            for event in events { more = deliver(event, to: ex) }
            if ex.finished { return } // consumer vanished meanwhile (handled by cancelExchange)
            if ex.parser.isComplete {
                complete(ex, reusable: ex.parser.isReusable && !isComplete && error == nil)
                return
            }
            if !more { ex.receivePaused = true }
        }
        if isComplete {
            do {
                for event in try ex.parser.finish() { _ = deliver(event, to: ex) }
                complete(ex, reusable: false) // read-until-close body
            } catch {
                failOrRetry(ex, .connectionClosed)
            }
            return
        }
        if let error {
            failOrRetry(ex, Self.ioError(error))
            return
        }
        if !ex.receivePaused { receive(on: c) }
    }

    private func deliver(_ event: H1ParseEvent, to ex: Exchange) -> Bool {
        switch event {
        case .head(let head): return ex.pipe.push(.head(status: head.status, headers: head.headers))
        case .body(let data): return ex.pipe.push(.data(data))
        }
    }

    private func resumeReading(_ ex: Exchange) {
        guard !ex.finished, ex.receivePaused, let c = ex.connection else { return }
        ex.receivePaused = false
        ex.lastActivity = Self.now
        receive(on: c)
    }

    private func complete(_ ex: Exchange, reusable: Bool) {
        guard !ex.finished else { return }
        ex.finished = true
        ex.pipe.finish()
        guard let c = detach(ex) else { return }
        if reusable, c.state == .ready, case .ready = c.nw.state {
            release(c)
        } else {
            close(c, force: false)
        }
    }

    private func fail(_ ex: Exchange, _ error: MediaFetchError) {
        guard !ex.finished else { return }
        ex.finished = true
        ex.pipe.finish(throwing: error)
        removeWaiter(ex)
        if let c = detach(ex) { close(c) }
    }

    /// A pooled connection that dies before any response byte (server closed it while idle) is replaced once by a
    /// fresh connection; otherwise the request fails.
    private func failOrRetry(_ ex: Exchange, _ error: MediaFetchError) {
        guard !ex.finished else { return }
        guard ex.onPooledConnection, !ex.gotResponseBytes, !ex.retried, !ex.pipe.isCancelled else {
            fail(ex, error)
            return
        }
        ex.retried = true
        if let c = detach(ex) { close(c, serviceWaiters: false) }
        let pool = pool(for: ex.origin)
        if pool.live.count < maxConnectionsPerHost {
            attach(ex, to: openConnection(ex.origin, highPriority: ex.highPriority))
        } else {
            pool.waiters.insert(ex, at: 0)
        }
    }

    /// The consumer cancelled or dropped the stream: close the connection (never pooled).
    private func cancelExchange(_ ex: Exchange) {
        guard !ex.finished else { return }
        ex.finished = true
        ex.pipe.finish(throwing: MediaFetchError.cancelled)
        removeWaiter(ex)
        if let c = detach(ex) { close(c, force: true) }
    }

    private func removeWaiter(_ ex: Exchange) {
        guard let pool = pools[ex.origin] else { return }
        pool.waiters.removeAll { $0 === ex }
    }

    private func scheduleBackstop(_ ex: Exchange, attempt: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0.05, delay)) { [weak self, weak ex] in
            guard let self, let ex, !ex.finished, ex.attempt == attempt, ex.connection != nil else { return }
            let now = Self.now
            if ex.receivePaused { // waiting for the consumer, not the network
                ex.lastActivity = now
                self.scheduleBackstop(ex, attempt: attempt, after: self.responseTimeout)
                return
            }
            let silent = now - ex.lastActivity
            if silent >= self.responseTimeout {
                let seconds = Int(self.responseTimeout)
                self.fail(ex, ex.gotResponseBytes ? .connectionClosed : .connectFailed("no response within \(seconds) s"))
            } else {
                self.scheduleBackstop(ex, attempt: attempt, after: self.responseTimeout - silent)
            }
        }
    }

    // MARK: - Error mapping

    private static func connectError(_ error: NWError) -> MediaFetchError {
        if case .tls(let status) = error { return .tls("TLS handshake failed (OSStatus \(status))") }
        return .connectFailed(error.debugDescription)
    }

    /// Errors after the handshake. TLS "closed" statuses (errSSLClosedGraceful -9805, errSSLClosedAbort -9806,
    /// errSSLClosedNoNotify -9816) are the peer hanging up, not a TLS failure: report them as `.connectionClosed` so
    /// they don't count towards the engine's "TLS is broken here" fallback switch.
    private static func ioError(_ error: NWError) -> MediaFetchError {
        if case .tls(let status) = error, ![-9805, -9806, -9816].contains(status) {
            return .tls("TLS error (OSStatus \(status))")
        }
        return .connectionClosed
    }
}
