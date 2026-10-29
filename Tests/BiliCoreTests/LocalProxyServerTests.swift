import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Network
import XCTest
@testable import BiliCore

// End-to-end over real loopback sockets: LocalProxyServer + AccelerationEngine + a fake downloader serving a
// synthetic fMP4-shaped file. Uses Network.framework (skipped by the Linux harness unless WITH_NETWORK=1).

/// A minimal HTTP/1.1 client on one NWConnection (keep-alive aware).
final class EngineRawHTTPClient: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    struct ClientError: Error {
        var message: String
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.rawhttp")
    private var buffer = Data()
    private var sawEOF = false

    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func take() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { c.resume() }
                case .failed(let e), .waiting(let e):
                    if once.take() { c.resume(throwing: e) }
                case .cancelled:
                    if once.take() { c.resume(throwing: ClientError(message: "cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// Appends received bytes to the buffer; false at EOF.
    private func receiveMore() async throws -> Bool {
        if sawEOF { return false }
        let chunk: Data? = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if isComplete {
                    c.resume(returning: nil)
                } else if let error {
                    c.resume(throwing: error)
                } else {
                    c.resume(returning: Data())
                }
            }
        }
        guard let chunk else {
            sawEOF = true
            return false
        }
        buffer.append(chunk)
        return true
    }

    func readResponse(head isHead: Bool = false) async throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        var headEnd = buffer.range(of: separator)
        while headEnd == nil {
            guard try await receiveMore() else { throw ClientError(message: "EOF before head") }
            headEnd = buffer.range(of: separator)
        }
        let headData = buffer.subdata(in: buffer.startIndex..<headEnd!.lowerBound)
        buffer = Data(buffer[headEnd!.upperBound...])
        let lines = String(decoding: headData, as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw ClientError(message: lines[0]) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = isHead ? 0 : Int(headers["content-length"] ?? "0") ?? 0
        while buffer.count < length {
            guard try await receiveMore() else { throw ClientError(message: "EOF in body (\(buffer.count)/\(length))") }
        }
        let body = buffer.prefix(length)
        buffer = Data(buffer.dropFirst(length))
        return Response(status: status, headers: headers, body: Data(body))
    }

    /// True when the server closes the connection (EOF / reset) within `timeout`.
    func waitForClose(timeout: Double = 3) async -> Bool {
        do {
            return try await withEngineTimeout(seconds: timeout) {
                while try await self.receiveMore() {}
                return true
            }
        } catch {
            return !(error is AccelerationEngineError)
        }
    }

    func close() {
        connection.cancel()
    }
}

final class LocalProxyServerTests: XCTestCase {
    private let videoFile = EngineSyntheticMP4.make(segmentSizes: [120_000, 100_000, 90_000],
                                                    durations: [2000, 2000, 1500], seed: 5)
    private let audioFile = EngineSyntheticMP4.make(segmentSizes: [40_000, 40_000, 30_000],
                                                    durations: [2000, 2000, 1500], moovSize: 600, seed: 11)

    private func makeEngine(downloader: EngineFakeDownloader) -> AccelerationEngine {
        var deps = AccelerationEngine.Dependencies(
            makeServer: { LocalProxyServer(handler: $0) },
            makePrimaryClient: { EngineFakeMediaClient(name: "h1") },
            makeFallbackClient: { EngineFakeMediaClient(name: "urlsession") },
            makeDownloader: { _, _ in downloader },
            auto: EngineFakeAuto(),
            settings: { AccelerationSettings() })
        deps.metadataTimeout = 5
        deps.refreshCheckInterval = 3600
        return AccelerationEngine(dependencies: deps)
    }

    private func prepare(_ engine: AccelerationEngine) async throws -> PlaybackSession {
        try await engine.prepare(PlaybackRequest(
            routeKey: "BVtest:p1", video: EngineSyntheticMP4.stream(.video, file: videoFile),
            audio: EngineSyntheticMP4.stream(.audio, file: audioFile, bandwidth: 128_000), duration: 5.5,
            accelerate: true, allowHDR: false))
    }

    private func slice(_ file: EngineSyntheticMP4.File, _ range: ByteRange) -> Data {
        file.data.subdata(in: Int(range.start)..<Int(range.end + 1))
    }

    private func timed<T: Sendable>(_ seconds: Double = 5, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withEngineTimeout(seconds: seconds, body)
    }

    func testKeepAliveConnectionServesPlaylistsAndRanges() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        engine.startIfNeeded()
        let session = try await prepare(engine)
        let port = UInt16(session.url.port ?? 0)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(session.url.host, "127.0.0.1")
        let tok = session.id
        let client = EngineRawHTTPClient(port: port)
        try await timed { try await client.connect() }

        try await client.send("GET /\(tok)/master.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let master = try await timed { try await client.readResponse() }
        XCTAssertEqual(master.status, 200)
        XCTAssertEqual(master.headers["content-type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(master.headers["connection"], "keep-alive")
        XCTAssertTrue(String(decoding: master.body, as: UTF8.self).hasPrefix("#EXTM3U\n"))

        // Same connection: media playlist, then a segment range.
        try await client.send("GET /\(tok)/v.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Playback-Session-Id: A\r\n\r\n")
        let media = try await timed { try await client.readResponse() }
        XCTAssertEqual(media.status, 200)
        XCTAssertTrue(String(decoding: media.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))

        let s1 = videoFile.segments[1]
        try await client.send("GET /\(tok)/v.m4s HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(s1.start)-\(s1.end)\r\n\r\n")
        let partial = try await timed { try await client.readResponse() }
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.headers["content-range"], "bytes \(s1.start)-\(s1.end)/\(videoFile.data.count)")
        XCTAssertEqual(partial.headers["content-length"], "\(s1.length)")
        XCTAssertEqual(partial.headers["content-type"], "video/mp4")
        XCTAssertEqual(partial.body, slice(videoFile, s1))

        try await client.send("HEAD /\(tok)/a.m4s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let head = try await timed { try await client.readResponse(head: true) }
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headers["content-length"], "\(audioFile.data.count)")
        XCTAssertEqual(head.headers["accept-ranges"], "bytes")

        try await client.send("GET /\(tok)/v.m4s HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(videoFile.data.count)-\r\n\r\n")
        let unsatisfiable = try await timed { try await client.readResponse() }
        XCTAssertEqual(unsatisfiable.status, 416)
        XCTAssertEqual(unsatisfiable.headers["content-range"], "bytes */\(videoFile.data.count)")

        try await client.send("GET /\(String(repeating: "0", count: 48))/master.m3u8 HTTP/1.1\r\nHost: x\r\n\r\n")
        let unknown = try await timed { try await client.readResponse() }
        XCTAssertEqual(unknown.status, 404)

        try await client.send("DELETE /\(tok)/v.m4s HTTP/1.1\r\nHost: x\r\n\r\n")
        let delete = try await timed { try await client.readResponse() }
        XCTAssertEqual(delete.status, 405)

        // `Connection: close` → answered, then closed by the server.
        try await client.send("GET /\(tok)/a.m3u8 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        let last = try await timed { try await client.readResponse() }
        XCTAssertEqual(last.status, 200)
        XCTAssertEqual(last.headers["connection"], "close")
        let closed = await client.waitForClose()
        XCTAssertTrue(closed)
        client.close()
        session.close()
    }

    /// The real clients are CFNetwork (URLSession / AVPlayer), not a hand-written socket client.
    func testURLSessionClientGetsPlaylistsAndRanges() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        engine.startIfNeeded()
        let session = try await prepare(engine)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let urlSession = URLSession(configuration: config)
        defer {
            urlSession.invalidateAndCancel()
            session.close()
        }
        let (masterData, masterResponse) = try await urlSession.data(for: URLRequest(url: session.url))
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: masterData, as: UTF8.self).hasPrefix("#EXTM3U\n"))

        let base = session.url.deletingLastPathComponent()
        let (mediaData, _) = try await urlSession.data(for: URLRequest(url: base.appendingPathComponent("v.m3u8")))
        XCTAssertTrue(String(decoding: mediaData, as: UTF8.self).contains("#EXT-X-ENDLIST"))

        let s1 = videoFile.segments[1]
        var request = URLRequest(url: base.appendingPathComponent("v.m4s"))
        request.setValue("bytes=\(s1.start)-\(s1.end)", forHTTPHeaderField: "Range")
        let (segment, segmentResponse) = try await urlSession.data(for: request)
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(segment, slice(videoFile, s1))
    }

    func testWholeFileWithoutRangeAndPipelinedRequests() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        let session = try await prepare(engine)
        let tok = session.id
        let client = EngineRawHTTPClient(port: UInt16(session.url.port!))
        try await timed { try await client.connect() }
        // Two requests in one write: answered in order.
        try await client.send("GET /\(tok)/v.m4s HTTP/1.1\r\nHost: x\r\n\r\nGET /\(tok)/a.m4s HTTP/1.1\r\nHost: x\r\n"
            + "Range: bytes=-100\r\n\r\n")
        let full = try await timed { try await client.readResponse() }
        XCTAssertEqual(full.status, 200)
        XCTAssertNil(full.headers["content-range"])
        XCTAssertEqual(full.body, videoFile.data)
        let tail = try await timed { try await client.readResponse() }
        XCTAssertEqual(tail.status, 206)
        XCTAssertEqual(tail.body, audioFile.data.suffix(100))
        client.close()
        session.close()
    }

    func testClientDisconnectCancelsTheDownload() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        let session = try await prepare(engine)
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let s2 = videoFile.segments[2]
        let client = EngineRawHTTPClient(port: UInt16(session.url.port!))
        try await timed { try await client.connect() }
        try await client.send("GET /\(session.id)/v.m4s HTTP/1.1\r\nHost: x\r\nRange: bytes=\(s2.start)-\(s2.end)\r\n\r\n")
        let waiting = await engineEventually { gate.waitingCount == 1 }
        XCTAssertTrue(waiting, "download started and is waiting for the CDN")
        client.close()
        let cancelled = await engineEventually { downloader.cancelledCalls.contains { $0.range == s2 } }
        XCTAssertTrue(cancelled, "closing the client connection cancels the producing download")
        gate.open()
        session.close()
    }

    func testFailureBeforeHeadIsA502AndConnectionStaysUsable() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        let session = try await prepare(engine)
        downloader.acceleratedFailures = 100
        downloader.directFailures = 100
        let s0 = videoFile.segments[0]
        let client = EngineRawHTTPClient(port: UInt16(session.url.port!))
        try await timed { try await client.connect() }
        try await client.send("GET /\(session.id)/v.m4s HTTP/1.1\r\nHost: x\r\nRange: bytes=\(s0.start)-\(s0.end)\r\n\r\n")
        let failed = try await timed { try await client.readResponse() }
        XCTAssertEqual(failed.status, 502)
        XCTAssertEqual(failed.body.count, 0)
        try await client.send("GET /\(session.id)/master.m3u8 HTTP/1.1\r\nHost: x\r\n\r\n")
        let master = try await timed { try await client.readResponse() }
        XCTAssertEqual(master.status, 200)
        client.close()
        session.close()
    }

    func testMalformedRequestIsRejectedAndClosed() async throws {
        let downloader = EngineFakeDownloader(files: [.video: videoFile.data, .audio: audioFile.data])
        let engine = makeEngine(downloader: downloader)
        let session = try await prepare(engine)
        let client = EngineRawHTTPClient(port: UInt16(session.url.port!))
        try await timed { try await client.connect() }
        try await client.send("NOT HTTP\r\n\r\n")
        let response = try await timed { try await client.readResponse() }
        XCTAssertEqual(response.status, 400)
        let closed = await client.waitForClose()
        XCTAssertTrue(closed)
        client.close()
        session.close()
    }

    func testListenerRebindsSamePortAfterDying() async throws {
        final class Handler: LocalProxyRequestHandler {
            func handle(_ request: ProxyHTTPRequest) async -> LocalProxyResponse { .empty(204) }
        }
        let handler = Handler()
        let server = LocalProxyServer(handler: handler)
        final class Box: @unchecked Sendable { var changed: UInt16? }
        let box = Box()
        server.onPortChange = { box.changed = $0 }
        let first = try await server.waitUntilReady(timeout: 3)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(server.port, first)
        server.start() // idempotent
        XCTAssertEqual(server.port, first)
        server.stop()
        XCTAssertEqual(server.port, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        server.ensureListening()
        let second = try await server.waitUntilReady(timeout: 3)
        // Same port normally; if the OS kept it, the change is reported so items can be rebuilt.
        XCTAssertTrue(second == first || box.changed == second, "first \(first) second \(second)")
        server.stop()
    }

    func testLoopbackCheck() {
        XCTAssertTrue(LocalProxyServer.isLoopback(.ipv4(.loopback)))
        XCTAssertTrue(LocalProxyServer.isLoopback(.ipv4(IPv4Address("127.0.0.2")!)))
        XCTAssertFalse(LocalProxyServer.isLoopback(.ipv4(IPv4Address("192.168.1.20")!)))
        XCTAssertTrue(LocalProxyServer.isLoopback(.ipv4(IPv4Address("127.255.0.9")!)))
        XCTAssertFalse(LocalProxyServer.isLoopback(.ipv4(IPv4Address("128.0.0.1")!)))
        XCTAssertTrue(LocalProxyServer.isLoopback(.ipv6(.loopback)))
        XCTAssertTrue(LocalProxyServer.isLoopback(.ipv6(IPv6Address("::ffff:127.0.0.2")!)))
        XCTAssertFalse(LocalProxyServer.isLoopback(.ipv6(IPv6Address("::ffff:10.0.0.1")!)))
        XCTAssertFalse(LocalProxyServer.isLoopback(.ipv6(IPv6Address("fe80::1")!)))
    }
}
