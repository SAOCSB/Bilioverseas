import Network
import XCTest
@testable import BiliCore

// Apple-only (Network.framework): loopback tests of H1MediaClient against a tiny plain-HTTP/1.1 fake CDN.

/// Plain-HTTP/1.1 fake CDN on loopback. Serves a deterministic 64 MiB virtual file with Range → 206.
///
/// Routes (all honour `Range: bytes=a-b`):
/// - `/file`        206, 64 KiB writes as fast as the client reads
/// - `/slow`        206, 16 KiB every 10 ms
/// - `/close`       206 with `Connection: close`, then closes
/// - `/stale-drop`  206, then silently closes the connection when the next request arrives on it
/// - `/early-close` 206 declaring the full length, sends half, then closes
/// - `/chunked`     206 with `Transfer-Encoding: chunked` (uneven chunks, an extension and a trailer)
/// - `/forbidden`   403 with a 9-byte body, keep-alive
final class LoopbackCDN: @unchecked Sendable {
    static let fileSize = 64 << 20

    /// Byte `p` of the virtual file = little-endian byte `p % 4` of `UInt32(p / 4)`.
    static func content(offset: Int, count: Int) -> Data {
        guard count > 0 else { return Data() }
        let firstWord = offset >> 2
        let lastWord = (offset + count + 3) >> 2
        var words = [UInt32](repeating: 0, count: lastWord - firstWord)
        words.withUnsafeMutableBufferPointer { buf in
            for i in 0 ..< buf.count { buf[i] = UInt32(truncatingIfNeeded: firstWord + i).littleEndian }
        }
        let skip = offset - firstWord * 4
        return words.withUnsafeBytes { Data($0[skip ..< skip + count]) }
    }

    fileprivate let queue = DispatchQueue(label: "LoopbackCDN")
    private let listener: NWListener
    private let lock = NSLock()
    private var acceptedCount = 0
    private var closedCount = 0
    private var bodyBytes = 0
    private var requestHeads: [String] = []
    private var boundPort: UInt16 = 0
    private var sessions: [Session] = [] // queue-confined

    static func start() async throws -> LoopbackCDN {
        let server = try LoopbackCDN()
        try await server.waitReady()
        return server
    }

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    private func waitReady() async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            once.set(cont)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.setPort(self?.listener.port?.rawValue ?? 0)
                    once.resume(nil)
                case .failed(let error):
                    once.resume(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async {
            for s in self.sessions { s.markClosed() }
            self.sessions.removeAll()
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    var port: UInt16 { locked { boundPort } }
    var accepted: Int { locked { acceptedCount } }
    var closed: Int { locked { closedCount } }
    var bodyBytesSent: Int { locked { bodyBytes } }
    var lastRequestHead: String { locked { requestHeads.last ?? "" } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setPort(_ p: UInt16) { locked { boundPort = p } }
    fileprivate func noteClosed() { locked { closedCount += 1 } }
    fileprivate func addSent(_ n: Int) { locked { bodyBytes += n } }
    fileprivate func record(_ head: String) { locked { requestHeads.append(head) } }

    private func accept(_ conn: NWConnection) {
        locked { acceptedCount += 1 }
        let session = Session(conn: conn, server: self)
        sessions.append(session)
        session.begin()
    }

    fileprivate final class Session {
        let conn: NWConnection
        unowned let server: LoopbackCDN
        var buffer = Data()
        var busy = false
        var isClosed = false
        var dropNextRequest = false

        init(conn: NWConnection, server: LoopbackCDN) {
            self.conn = conn
            self.server = server
        }

        func begin() {
            conn.start(queue: server.queue)
            read()
        }

        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.process()
                }
                if isComplete || error != nil {
                    self.markClosed()
                    return
                }
                self.read()
            }
        }

        func markClosed() {
            guard !isClosed else { return }
            isClosed = true
            server.noteClosed()
            conn.cancel()
        }

        private func process() {
            guard !busy, !isClosed, let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex ..< end.upperBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ..< end.upperBound)
            server.record(head)
            if dropNextRequest {
                markClosed()
                return
            }
            busy = true
            respond(to: head) { [weak self] in
                guard let self else { return }
                self.busy = false
                self.process()
            }
        }

        private func respond(to head: String, done: @escaping () -> Void) {
            let lines = head.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let size = LoopbackCDN.fileSize
            let parts = (headers["range"] ?? "").replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-").compactMap { Int($0) }
            let start = parts.count == 2 ? parts[0] : 0
            let end = parts.count == 2 ? parts[1] : size - 1
            func partialHead(_ extra: String = "", length: Int? = nil) -> String {
                "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes \(start)-\(end)/\(size)\r\n" +
                    "Content-Length: \(length ?? end - start + 1)\r\n\(extra)\r\n"
            }
            switch path {
            case "/forbidden":
                write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nforbidden", then: done)
                return
            case "/file", "/slow", "/close", "/stale-drop", "/early-close", "/chunked":
                break
            default:
                write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", then: done)
                return
            }
            guard start <= end, end < size else {
                write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\n\r\n", then: done)
                return
            }
            switch path {
            case "/slow":
                write(partialHead()) { self.sendBody(from: start, to: end, chunk: 16 << 10, delay: 0.01, then: done) }
            case "/close":
                write(partialHead("Connection: close\r\n")) {
                    self.sendBody(from: start, to: end, chunk: 64 << 10, delay: 0) { self.markClosed() }
                }
            case "/stale-drop":
                write(partialHead()) {
                    self.sendBody(from: start, to: end, chunk: 64 << 10, delay: 0) {
                        self.dropNextRequest = true
                        done()
                    }
                }
            case "/early-close":
                let half = (end - start + 1) / 2
                write(partialHead()) {
                    self.sendBody(from: start, to: start + half - 1, chunk: 64 << 10, delay: 0) { self.markClosed() }
                }
            case "/chunked":
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(size)\r\n" +
                    "Transfer-Encoding: chunked\r\n\r\n"
                write(head) { self.sendChunked(from: start, to: end, sizes: [1, 7, 1000, 4096], then: done) }
            default: // "/file"
                write(partialHead()) { self.sendBody(from: start, to: end, chunk: 64 << 10, delay: 0, then: done) }
            }
        }

        private func write(_ text: String, then: @escaping () -> Void) {
            send(Data(text.utf8), countAsBody: 0, then: then)
        }

        private func send(_ data: Data, countAsBody: Int, then: @escaping () -> Void) {
            guard !isClosed else { return }
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isClosed else { return }
                if error != nil {
                    self.markClosed()
                    return
                }
                if countAsBody > 0 { self.server.addSent(countAsBody) }
                then()
            })
        }

        private func sendBody(from: Int, to: Int, chunk: Int, delay: TimeInterval, then: @escaping () -> Void) {
            guard !isClosed else { return }
            if from > to {
                then()
                return
            }
            let n = min(chunk, to - from + 1)
            send(LoopbackCDN.content(offset: from, count: n), countAsBody: n) { [weak self] in
                guard let self else { return }
                if delay > 0 {
                    self.server.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.sendBody(from: from + n, to: to, chunk: chunk, delay: delay, then: then)
                    }
                } else {
                    self.sendBody(from: from + n, to: to, chunk: chunk, delay: delay, then: then)
                }
            }
        }

        private func sendChunked(from: Int, to: Int, sizes: [Int], then: @escaping () -> Void) {
            guard !isClosed else { return }
            if from > to {
                write("0\r\nX-Trailer: yes\r\n\r\n", then: then)
                return
            }
            let n = min(sizes.first ?? 50_000, to - from + 1)
            let ext = sizes.count == 3 ? ";foo=bar" : ""
            var frame = Data((String(n, radix: 16) + ext + "\r\n").utf8)
            frame.append(LoopbackCDN.content(offset: from, count: n))
            frame.append(Data("\r\n".utf8))
            send(frame, countAsBody: n) { [weak self] in
                self?.sendChunked(from: from + n, to: to, sizes: Array(sizes.dropFirst()), then: then)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        func set(_ c: CheckedContinuation<Void, Error>) {
            lock.lock()
            cont = c
            lock.unlock()
        }
        func resume(_ error: Error?) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }
    }
}

final class H1MediaClientLoopbackTests: XCTestCase {
    private var server: LoopbackCDN!

    override func setUp() async throws {
        server = try await LoopbackCDN.start()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    private func makeClient(maxConnectionsPerHost: Int = 64) -> H1MediaClient {
        let client = H1MediaClient(maxConnectionsPerHost: maxConnectionsPerHost, idleTimeout: 30, connectTimeout: 2)
        client.responseTimeout = 3 // backstop so a bug fails fast instead of hanging CI
        return client // deinit at the end of the test closes whatever is still open
    }

    private struct Fetched {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private func fetch(_ client: MediaHTTPClient, _ path: String, _ range: ByteRange,
                       highPriority: Bool = false) async throws -> Fetched {
        var status: Int?
        var headers: [String: String] = [:]
        var body = Data()
        for try await event in client.get(server.url(path), range: range, highPriority: highPriority) {
            switch event {
            case .head(let s, let h):
                XCTAssertNil(status, "head must come exactly once")
                status = s
                headers = h
            case .data(let d):
                XCTAssertNotNil(status, "data before head")
                body.append(d)
            }
        }
        return Fetched(status: status ?? -1, headers: headers, body: body)
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func range(_ start: Int, count: Int) -> ByteRange {
        ByteRange(start: Int64(start), end: Int64(start + count - 1))
    }

    // MARK: - Basics

    func testRangeRequestReturnsExactBytesAndSendsTheMediaProfile() async throws {
        let client = makeClient()
        let r = try await fetch(client, "/file?sign=a%2Bb&x=1", range(1000, count: 300_000), highPriority: true)
        XCTAssertEqual(r.status, 206)
        XCTAssertEqual(r.headers["content-range"], "bytes 1000-300999/\(LoopbackCDN.fileSize)")
        XCTAssertEqual(r.headers["content-length"], "300000")
        XCTAssertEqual(r.body.count, 300_000)
        XCTAssertTrue(r.body == LoopbackCDN.content(offset: 1000, count: 300_000))

        let head = server.lastRequestHead
        XCTAssertTrue(head.hasPrefix("GET /file?sign=a%2Bb&x=1 HTTP/1.1\r\n"), head)
        XCTAssertTrue(head.contains("\r\nHost: 127.0.0.1:\(server.port)\r\n"), head)
        XCTAssertTrue(head.contains("\r\nRange: bytes=1000-300999\r\n"), head)
        XCTAssertTrue(head.contains("\r\nUser-Agent: \(BiliHTTP.webUserAgent)\r\n"), head)
        XCTAssertTrue(head.contains("\r\nReferer: https://www.bilibili.com/\r\n"), head)
        XCTAssertTrue(head.contains("\r\nOrigin: https://www.bilibili.com\r\n"), head)
        XCTAssertTrue(head.contains("\r\nAccept: */*\r\n"), head)
        XCTAssertTrue(head.contains("\r\nAccept-Encoding: identity\r\n"), head)
        XCTAssertTrue(head.contains("\r\nConnection: keep-alive\r\n"), head)
        XCTAssertFalse(head.lowercased().contains("cookie"), head)
    }

    func testSequentialRequestsReuseOneConnection() async throws {
        let client = makeClient()
        for i in 0 ..< 4 {
            let r = try await fetch(client, "/file", range(i * 100_000, count: 50_000))
            XCTAssertEqual(r.status, 206)
            XCTAssertTrue(r.body == LoopbackCDN.content(offset: i * 100_000, count: 50_000))
            XCTAssertEqual(client.openConnectionCount, 1)
        }
        XCTAssertEqual(server.accepted, 1, "keep-alive: one TCP connection for sequential requests")
    }

    func testConcurrentRequestsUseSeparateConnections() async throws {
        let client = makeClient()
        let n = 8
        let bodies = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Int: Data] in
            for i in 0 ..< n {
                group.addTask { (i, try await self.fetch(client, "/slow", self.range(i * 1_000_000, count: 160_000)).body) }
            }
            var out: [Int: Data] = [:]
            for try await (i, d) in group { out[i] = d }
            return out
        }
        for i in 0 ..< n {
            XCTAssertTrue(bodies[i] == LoopbackCDN.content(offset: i * 1_000_000, count: 160_000), "request \(i)")
        }
        XCTAssertEqual(server.accepted, n, "N in-flight requests must be N TCP connections")
        XCTAssertEqual(client.openConnectionCount, n, "all returned to the idle pool")
        _ = try await fetch(client, "/file", range(0, count: 1000))
        XCTAssertEqual(server.accepted, n, "pooled connections are reused")
    }

    func testPerHostCapQueuesExtraRequests() async throws {
        let client = makeClient(maxConnectionsPerHost: 2)
        let ok = try await withThrowingTaskGroup(of: Bool.self) { group -> Bool in
            for i in 0 ..< 6 {
                group.addTask {
                    let r = try await self.fetch(client, "/slow", self.range(i * 70_000, count: 64_000))
                    return r.body == LoopbackCDN.content(offset: i * 70_000, count: 64_000)
                }
            }
            var all = true
            for try await one in group { all = all && one }
            return all
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(server.accepted, 2)
        XCTAssertEqual(client.openConnectionCount, 2)
    }

    func testInvalidURLAndRange() async {
        let client = makeClient()
        for (url, r) in [(URL(string: "ftp://127.0.0.1/x")!, range(0, count: 10)),
                         (server.url("/file"), ByteRange(start: 10, end: 5))] {
            do {
                for try await _ in client.get(url, range: r, highPriority: false) {}
                XCTFail("expected .invalidURL")
            } catch {
                XCTAssertEqual(error as? MediaFetchError, .invalidURL)
            }
        }
        XCTAssertEqual(client.openConnectionCount, 0)
    }

    // MARK: - Cancellation and back-pressure

    func testCancellingTheTaskClosesTheConnectionAndStopsTheServer() async throws {
        let client = makeClient()
        let total = 4 << 20
        let url = server.url("/slow")
        let consumer = Task { () -> Int in
            var got = 0
            do {
                for try await event in client.get(url, range: ByteRange(start: 0, end: Int64(total - 1)), highPriority: true) {
                    if case .data(let d) = event { got += d.count }
                }
            } catch {
                XCTAssertEqual(error as? MediaFetchError, .cancelled)
            }
            return got
        }
        let started = await waitUntil { self.server.bodyBytesSent >= 64 << 10 }
        XCTAssertTrue(started)
        consumer.cancel()
        let got = await consumer.value
        XCTAssertLessThan(got, total)
        let closed = await waitUntil { client.openConnectionCount == 0 && self.server.closed == 1 }
        XCTAssertTrue(closed, "cancelled request must close its connection (open=\(client.openConnectionCount))")
        let sentAtClose = server.bodyBytesSent
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.bodyBytesSent, sentAtClose, "server kept writing after cancellation")
        XCTAssertLessThan(sentAtClose, total)
        // A fresh request still works (opens a new connection).
        let r = try await fetch(client, "/file", range(0, count: 10_000))
        XCTAssertEqual(r.body.count, 10_000)
        XCTAssertEqual(server.accepted, 2)
    }

    func testBreakingOutOfTheLoopClosesTheConnection() async throws {
        let client = makeClient()
        var got = 0
        for try await event in client.get(server.url("/slow"), range: range(0, count: 4 << 20), highPriority: false) {
            if case .data(let d) = event {
                got += d.count
                if got >= 32 << 10 { break }
            }
        }
        let closed = await waitUntil { client.openConnectionCount == 0 && self.server.closed == 1 }
        XCTAssertTrue(closed, "abandoned stream must close its connection (open=\(client.openConnectionCount))")
    }

    func testBackPressureLosesNoBytes() async throws {
        let client = makeClient()
        let size = 32 << 20
        var it = client.get(server.url("/file"), range: range(0, count: size), highPriority: false).makeAsyncIterator()
        guard case .head(let status, _)? = try await it.next() else { return XCTFail("missing head") }
        XCTAssertEqual(status, 206)
        try await Task.sleep(nanoseconds: 400_000_000) // a stalled consumer
        let sentWhileStalled = server.bodyBytesSent
        XCTAssertLessThan(sentWhileStalled, size, "client kept reading without demand")
        var body = Data()
        body.reserveCapacity(size)
        while let event = try await it.next() {
            if case .data(let d) = event {
                body.append(d)
                if body.count % (4 << 20) < d.count { try await Task.sleep(nanoseconds: 20_000_000) } // stall again
            }
        }
        XCTAssertEqual(body.count, size)
        XCTAssertTrue(body == LoopbackCDN.content(offset: 0, count: size))
        XCTAssertEqual(server.accepted, 1)
    }

    // MARK: - Response kinds

    func testForbiddenDeliversHeadAndBodyAndKeepsTheConnection() async throws {
        let client = makeClient()
        let r = try await fetch(client, "/forbidden", range(0, count: 100))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "forbidden")
        _ = try await fetch(client, "/file", range(0, count: 100))
        XCTAssertEqual(server.accepted, 1)
    }

    func testEarlyCloseThrowsConnectionClosedAfterThePartialBody() async throws {
        let client = makeClient()
        var body = Data()
        var status = 0
        do {
            for try await event in client.get(server.url("/early-close"), range: range(500, count: 100_000), highPriority: false) {
                switch event {
                case .head(let s, _): status = s
                case .data(let d): body.append(d)
                }
            }
            XCTFail("expected .connectionClosed")
        } catch {
            XCTAssertEqual(error as? MediaFetchError, .connectionClosed)
        }
        XCTAssertEqual(status, 206)
        XCTAssertTrue(body == LoopbackCDN.content(offset: 500, count: 50_000))
        let closed = await waitUntil { client.openConnectionCount == 0 }
        XCTAssertTrue(closed)
    }

    func testConnectionCloseResponseIsNotPooled() async throws {
        let client = makeClient()
        let r = try await fetch(client, "/close", range(0, count: 70_000))
        XCTAssertTrue(r.body == LoopbackCDN.content(offset: 0, count: 70_000))
        let closed = await waitUntil { client.openConnectionCount == 0 }
        XCTAssertTrue(closed)
        _ = try await fetch(client, "/file", range(0, count: 100))
        XCTAssertEqual(server.accepted, 2)
    }

    func testChunkedResponseIsDecodedAndReusable() async throws {
        let client = makeClient()
        let r = try await fetch(client, "/chunked", range(12345, count: 200_000))
        XCTAssertEqual(r.status, 206)
        XCTAssertTrue(r.body == LoopbackCDN.content(offset: 12345, count: 200_000))
        _ = try await fetch(client, "/file", range(0, count: 100))
        XCTAssertEqual(server.accepted, 1)
    }

    func testStalePooledConnectionIsRetriedTransparently() async throws {
        let client = makeClient()
        let first = try await fetch(client, "/stale-drop", range(0, count: 10_000))
        XCTAssertEqual(first.status, 206)
        // The server drops the pooled connection when this request arrives: retried once on a fresh connection.
        let second = try await fetch(client, "/file", range(777, count: 20_000))
        XCTAssertEqual(second.status, 206)
        XCTAssertTrue(second.body == LoopbackCDN.content(offset: 777, count: 20_000))
        XCTAssertEqual(server.accepted, 2)
    }

    // MARK: - Connections

    func testConnectRefusedMapsToConnectFailed() async throws {
        let dead = try await LoopbackCDN.start()
        let url = dead.url("/file")
        dead.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        let client = makeClient()
        do {
            for try await _ in client.get(url, range: range(0, count: 10), highPriority: false) {}
            XCTFail("expected a connect failure")
        } catch {
            guard case .connectFailed? = error as? MediaFetchError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(client.openConnectionCount, 0)
    }

    func testPreconnectWarmsThePoolAndCloseIdleEmptiesIt() async throws {
        let client = makeClient()
        client.preconnect(hosts: ["http://127.0.0.1:\(server.port)", "http://127.0.0.1:\(server.port)"])
        let warmed = await waitUntil { self.server.accepted == 1 && client.openConnectionCount == 1 }
        XCTAssertTrue(warmed)
        try await Task.sleep(nanoseconds: 50_000_000)
        let r = try await fetch(client, "/file", range(0, count: 1000))
        XCTAssertEqual(r.status, 206)
        XCTAssertEqual(server.accepted, 1, "the preconnected connection is used")
        client.closeIdleConnections()
        let drained = await waitUntil { client.openConnectionCount == 0 && self.server.closed == 1 }
        XCTAssertTrue(drained)
    }

    // MARK: - URLSession fallback

    func testURLSessionClientFetchesExactBytesAndCancels() async throws {
        let client = URLSessionMediaClient(lanes: 2)
        let r: Fetched
        do {
            r = try await fetch(client, "/file", range(4096, count: 200_000))
        } catch MediaFetchError.connectFailed(let message) where message.contains("-1022") {
            throw XCTSkip("ATS blocks cleartext loopback in this test host")
        }
        XCTAssertEqual(r.status, 206)
        XCTAssertEqual(r.headers["content-range"], "bytes 4096-204095/\(LoopbackCDN.fileSize)")
        XCTAssertTrue(r.body == LoopbackCDN.content(offset: 4096, count: 200_000))
        XCTAssertTrue(server.lastRequestHead.contains("\r\nAccept-Encoding: identity\r\n"), server.lastRequestHead)
        XCTAssertFalse(server.lastRequestHead.lowercased().contains("cookie"))

        // Back-pressure + cancellation: stop after 64 KiB of a large slow body.
        var got = 0
        for try await event in client.get(server.url("/slow"), range: range(0, count: 4 << 20), highPriority: true) {
            if case .data(let d) = event {
                got += d.count
                if got >= 64 << 10 { break }
            }
        }
        let idle = await waitUntil { client.openConnectionCount == 0 }
        XCTAssertTrue(idle, "cancelled task must be removed")
    }
}
