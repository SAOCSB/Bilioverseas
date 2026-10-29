import XCTest
@testable import BiliCore

final class H1ResponseParserTests: XCTestCase {
    private struct Parsed {
        var head: H1ResponseHead?
        var heads = 0
        var body = Data()
        var complete = false
        var reusable = false
    }

    /// Feeds `bytes` split at `cuts` (sorted offsets), checks event invariants, optionally signals EOF.
    private func parse(_ bytes: Data, cuts: [Int] = [], eof: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Parsed {
        var parser = H1ResponseParser()
        var out = Parsed()
        var pieces: [Data] = []
        var last = 0
        for c in cuts.sorted() where c > last && c < bytes.count {
            pieces.append(bytes.subdata(in: last ..< c))
            last = c
        }
        pieces.append(bytes.subdata(in: last ..< bytes.count))
        func take(_ events: [H1ParseEvent]) {
            for e in events {
                switch e {
                case .head(let h):
                    XCTAssertEqual(out.heads, 0, "head emitted twice", file: file, line: line)
                    out.heads += 1
                    out.head = h
                case .body(let d):
                    XCTAssertNotNil(out.head, "body before head", file: file, line: line)
                    XCTAssertFalse(d.isEmpty, "empty body event", file: file, line: line)
                    XCTAssertEqual(d.startIndex, 0, "body slices must be rebased", file: file, line: line)
                    out.body.append(d)
                }
            }
        }
        for p in pieces { take(try parser.feed(p)) }
        if eof { take(try parser.finish()) }
        out.complete = parser.isComplete
        out.reusable = parser.isReusable
        return out
    }

    private func bytewise(_ bytes: Data) -> [Int] { Array(1 ..< max(1, bytes.count)) }

    private func randomCuts(_ bytes: Data, count: Int, seed: inout UInt64) -> [Int] {
        (0 ..< count).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, bytes.count)))
        }
    }

    private static func payload(_ n: Int) -> Data {
        Data((0 ..< n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    }

    // MARK: Content-Length

    func test206ContentLengthAnySplit() throws {
        let body = Self.payload(5000)
        let raw = Data("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 100-5099/99999\r\nContent-Length: 5000\r\nContent-Type: video/mp4\r\n\r\n".utf8) + body
        var seed: UInt64 = 42
        var splits: [[Int]] = [[], bytewise(raw)]
        for n in [1, 2, 3, 7, 40] { for _ in 0 ..< 20 { splits.append(randomCuts(raw, count: n, seed: &seed)) } }
        for cuts in splits {
            let p = try parse(raw, cuts: cuts)
            XCTAssertEqual(p.head?.status, 206)
            XCTAssertEqual(p.head?.reason, "Partial Content")
            XCTAssertEqual(p.head?.headers["content-range"], "bytes 100-5099/99999")
            XCTAssertEqual(p.body, body)
            XCTAssertTrue(p.complete)
            XCTAssertTrue(p.reusable)
        }
    }

    func testHeadAndBodyInOneChunkAndExpectedLength() throws {
        var parser = H1ResponseParser()
        let events = try parser.feed(Data("HTTP/1.1 206 X\r\nContent-Length: 3\r\n\r\nabc".utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(parser.expectedBodyLength, 3)
        XCTAssertEqual(parser.bodyBytesReceived, 3)
        XCTAssertEqual(parser.framing, .contentLength(3))
        guard case .body(let d) = events[1] else { return XCTFail("expected body") }
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "abc")
        XCTAssertTrue(parser.isReusable)
    }

    func testZeroLengthAnd204AndReasonless() throws {
        let p = try parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        XCTAssertTrue(p.complete)
        XCTAssertTrue(p.reusable)
        XCTAssertTrue(p.body.isEmpty)
        let q = try parse(Data("HTTP/1.1 204\r\n\r\n".utf8))
        XCTAssertEqual(q.head?.status, 204)
        XCTAssertEqual(q.head?.reason, "")
        XCTAssertTrue(q.complete)
        XCTAssertTrue(q.reusable)
    }

    func testTruncatedBodyThrowsOnEOF() throws {
        var parser = H1ResponseParser()
        _ = try parser.feed(Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 10\r\n\r\n12345".utf8))
        XCTAssertFalse(parser.isComplete)
        XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? H1ParseError, .truncated) }
        XCTAssertFalse(parser.isReusable)
        var empty = H1ResponseParser()
        XCTAssertThrowsError(try empty.finish()) { XCTAssertEqual($0 as? H1ParseError, .truncated) }
    }

    func testTrailingBytesMakeConnectionUnreusable() throws {
        let p = try parse(Data("HTTP/1.1 206 X\r\nContent-Length: 2\r\n\r\nabHTTP/1.1 200".utf8))
        XCTAssertEqual(p.body, Data("ab".utf8))
        XCTAssertTrue(p.complete)
        XCTAssertFalse(p.reusable)
    }

    func testInvalidContentLength() {
        for v in ["abc", "5, 6", "-1", "+5", "", "1 2", "99999999999999999999"] {
            var parser = H1ResponseParser()
            XCTAssertThrowsError(try parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: \(v)\r\n\r\n".utf8)), v) {
                guard case .invalidContentLength? = $0 as? H1ParseError else { return XCTFail("\($0)") }
            }
        }
        // Identical duplicates are fine.
        var parser = H1ResponseParser()
        XCTAssertNoThrow(try parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok".utf8)))
        XCTAssertTrue(parser.isComplete)
    }

    // MARK: Chunked

    func testChunkedWithExtensionsAndTrailersAnySplit() throws {
        let raw = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5;name=value\r\nhello\r\n" +
            "1A ; ext\r\nabcdefghijklmnopqrstuvwxyz\r\n" +
            "000\r\nX-Trailer: done\r\nX-Other:  2 \r\n\r\n").utf8)
        var seed: UInt64 = 7
        var splits: [[Int]] = [[], bytewise(raw)]
        for n in [1, 3, 9] { for _ in 0 ..< 30 { splits.append(randomCuts(raw, count: n, seed: &seed)) } }
        for cuts in splits {
            var parser = H1ResponseParser()
            var body = Data()
            var last = 0
            for c in cuts.sorted() + [raw.count] where c > last {
                for e in try parser.feed(raw.subdata(in: last ..< c)) { if case .body(let d) = e { body.append(d) } }
                last = c
            }
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "helloabcdefghijklmnopqrstuvwxyz")
            XCTAssertTrue(parser.isComplete)
            XCTAssertTrue(parser.isReusable)
            XCTAssertEqual(parser.framing, .chunked)
            XCTAssertEqual(parser.trailers["x-trailer"], "done")
            XCTAssertEqual(parser.trailers["x-other"], "2")
        }
    }

    func testLargeChunkedBodyRandomSplits() throws {
        let body = Self.payload(200_000)
        var raw = Data("HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var off = 0
        var sizes = [1, 2, 17, 4096, 65536, 100]
        while off < body.count {
            let n = min(sizes.isEmpty ? 30_000 : sizes.removeFirst(), body.count - off)
            raw += Data((String(n, radix: 16) + "\r\n").utf8) + body.subdata(in: off ..< off + n) + Data("\r\n".utf8)
            off += n
        }
        raw += Data("0\r\n\r\n".utf8)
        var seed: UInt64 = 99
        for _ in 0 ..< 10 {
            let p = try parse(raw, cuts: randomCuts(raw, count: 50, seed: &seed))
            XCTAssertEqual(p.body, body)
            XCTAssertTrue(p.complete)
            XCTAssertTrue(p.reusable)
        }
    }

    func testChunkedErrors() {
        for bad in ["zz\r\nhello\r\n0\r\n\r\n", "5\r\nhelloXX0\r\n\r\n", ";ext\r\n", "1234567890abcdef0\r\n"] {
            var parser = H1ResponseParser()
            XCTAssertThrowsError(try parser.feed(Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + bad).utf8)), bad) {
                guard case .invalidChunkedEncoding? = $0 as? H1ParseError else { return XCTFail("\($0)") }
            }
        }
    }

    func testChunkedTruncatedAndTEWithContentLength() throws {
        var parser = H1ResponseParser()
        _ = try parser.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8))
        XCTAssertThrowsError(try parser.finish())
        // Transfer-Encoding wins over Content-Length, but such a connection is never reused.
        let p = try parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(p.body, Data("ok".utf8))
        XCTAssertTrue(p.complete)
        XCTAssertFalse(p.reusable)
    }

    // MARK: Connection management

    func testConnectionCloseIsNotReusable() throws {
        let p = try parse(Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 2\r\nConnection: Keep-Alive, CLOSE\r\n\r\nok".utf8))
        XCTAssertTrue(p.complete)
        XCTAssertFalse(p.reusable)
    }

    func testHTTP10IsNotReusable() throws {
        let p = try parse(Data("HTTP/1.0 206 Partial Content\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok".utf8))
        XCTAssertEqual(p.head?.majorVersion, 1)
        XCTAssertEqual(p.head?.minorVersion, 0)
        XCTAssertTrue(p.complete)
        XCTAssertFalse(p.reusable)
    }

    func testReadUntilClose() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nsome body".utf8)
        let p = try parse(raw, cuts: bytewise(raw), eof: true)
        XCTAssertEqual(p.body, Data("some body".utf8))
        XCTAssertTrue(p.complete)
        XCTAssertFalse(p.reusable)
        var parser = H1ResponseParser()
        _ = try parser.feed(raw)
        XCTAssertFalse(parser.isComplete)
        XCTAssertEqual(parser.framing, .untilClose)
    }

    // MARK: Heads

    func testSkips100ContinueAnd103EarlyHints() throws {
        let raw = Data(("HTTP/1.1 100 Continue\r\n\r\n" +
            "HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n" +
            "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\n\r\nbody").utf8)
        for cuts in [[], bytewise(raw)] {
            var parser = H1ResponseParser()
            var heads: [H1ResponseHead] = []
            var body = Data()
            var last = 0
            for c in cuts + [raw.count] where c > last {
                for e in try parser.feed(raw.subdata(in: last ..< c)) {
                    switch e {
                    case .head(let h): heads.append(h)
                    case .body(let d): body.append(d)
                    }
                }
                last = c
            }
            XCTAssertEqual(heads.map(\.status), [206])
            XCTAssertNil(heads.first?.headers["link"])
            XCTAssertEqual(body, Data("body".utf8))
            XCTAssertEqual(parser.interimResponses, 2)
            XCTAssertTrue(parser.isReusable)
        }
        var parser = H1ResponseParser()
        XCTAssertThrowsError(try parser.feed(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? H1ParseError, .unexpectedInterimResponse(101))
        }
    }

    func testMalformedStatusLines() {
        for line in ["HTTP/1.1 20 OK", "HTTP/1.1 abc OK", "HTTX/1.1 200 OK", "HTTP/1.1  200 OK", "garbage",
                     "HTTP/2 200 OK", "HTTP/1.1 2000 OK", "HTTP/1.1 099 X", " HTTP/1.1 200 OK", "SSH-2.0-OpenSSH"] {
            var parser = H1ResponseParser()
            XCTAssertThrowsError(try parser.feed(Data((line + "\r\nContent-Length: 0\r\n\r\n").utf8)), line) {
                guard case .malformedStatusLine? = $0 as? H1ParseError else { return XCTFail("\(line): \($0)") }
            }
            // The error is sticky.
            XCTAssertThrowsError(try parser.feed(Data("x".utf8)))
            XCTAssertFalse(parser.isReusable)
        }
    }

    func testMalformedHeaderLines() {
        for line in ["NoColonHere", ": empty-name", "Bad Name: x", " leading-fold-without-field: x"] {
            var parser = H1ResponseParser()
            XCTAssertThrowsError(try parser.feed(Data(("HTTP/1.1 200 OK\r\n" + line + "\r\n\r\n").utf8)), line) {
                guard case .malformedHeader? = $0 as? H1ParseError else { return XCTFail("\(line): \($0)") }
            }
        }
    }

    func testOversizedHeaders() throws {
        let big = String(repeating: "a", count: 70 * 1024)
        var parser = H1ResponseParser()
        XCTAssertThrowsError(try parser.feed(Data("HTTP/1.1 200 OK\r\nX-Big: \(big)\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? H1ParseError, .headersTooLarge)
        }
        // Detected incrementally too (never buffers more than the limit).
        var inc = H1ResponseParser()
        _ = try inc.feed(Data("HTTP/1.1 200 OK\r\n".utf8))
        let chunk = Data(String(repeating: "X-Pad: 0123456789\r\n", count: 100).utf8)
        var threw = false
        for _ in 0 ..< 100 {
            do { _ = try inc.feed(chunk) } catch { XCTAssertEqual(error as? H1ParseError, .headersTooLarge); threw = true; break }
        }
        XCTAssertTrue(threw)
        // Just under the limit is fine.
        let ok = String(repeating: "b", count: 60 * 1024)
        var fine = H1ResponseParser()
        XCTAssertNoThrow(try fine.feed(Data("HTTP/1.1 200 OK\r\nX-Big: \(ok)\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertTrue(fine.isComplete)
    }

    func testHeaderCaseInsensitivityDuplicatesFoldingAndBareLF() throws {
        let raw = Data(("HTTP/1.1 206 Partial Content\n" +
            "CONTENT-LENGTH: 3\n" +
            "X-Cache: HIT\n" +
            "x-cache:   MISS  \n" +
            "X-Folded: first\n" +
            "\t second\n" +
            "Content-Range:bytes 0-2/10\n" +
            "\nabc").utf8)
        let p = try parse(raw, cuts: bytewise(raw))
        XCTAssertEqual(p.head?.headers["content-length"], "3")
        XCTAssertEqual(p.head?["Content-Length"], "3")
        XCTAssertEqual(p.head?.headers["x-cache"], "HIT, MISS")
        XCTAssertEqual(p.head?.headers["x-folded"], "first second")
        XCTAssertEqual(p.head?.headers["content-range"], "bytes 0-2/10")
        XCTAssertNil(p.head?.headers["CONTENT-LENGTH"])
        XCTAssertEqual(p.body, Data("abc".utf8))
        XCTAssertTrue(p.reusable)
    }

    func testToleratesLeadingBlankLines() throws {
        let p = try parse(Data("\r\n\r\nHTTP/1.1 206 X\r\nContent-Length: 1\r\n\r\nz".utf8))
        XCTAssertEqual(p.head?.status, 206)
        XCTAssertEqual(p.body, Data("z".utf8))
    }

    // MARK: Request serialization

    func testRangeGETSerialization() throws {
        let url = URL(string: "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/12/34/x-1-30080.m4s?e=ig8euxZM&sign=a%2Bb%3D&x=1#frag")!
        let target = try XCTUnwrap(H1RequestTarget(url: url))
        XCTAssertEqual(target.origin, H1Origin(scheme: "https", host: "upos-sz-mirrorcos.bilivideo.com", port: 443))
        XCTAssertEqual(target.pathAndQuery, "/upgcxcode/12/34/x-1-30080.m4s?e=ig8euxZM&sign=a%2Bb%3D&x=1")
        let data = H1RequestSerializer.rangeGET(target, range: ByteRange(start: 0, end: 65535), userAgent: "UA/1.0")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text,
            "GET /upgcxcode/12/34/x-1-30080.m4s?e=ig8euxZM&sign=a%2Bb%3D&x=1 HTTP/1.1\r\n" +
            "Host: upos-sz-mirrorcos.bilivideo.com\r\n" +
            "Range: bytes=0-65535\r\n" +
            "User-Agent: UA/1.0\r\n" +
            "Accept: */*\r\n" +
            "Accept-Encoding: identity\r\n" +
            "Origin: https://www.bilibili.com\r\n" +
            "Referer: https://www.bilibili.com/\r\n" +
            "Connection: keep-alive\r\n\r\n")
        XCTAssertFalse(text.lowercased().contains("cookie"))
        XCTAssertTrue(H1RequestSerializer.mediaHeaderFields(range: ByteRange(start: 1, end: 2), userAgent: "x")
            .allSatisfy { $0.name.lowercased() != "cookie" })
    }

    func testDefaultUserAgentAndInjection() throws {
        let target = try XCTUnwrap(H1RequestTarget(url: URL(string: "https://a.bilivideo.com/x.m4s")!))
        let text = String(decoding: H1RequestSerializer.rangeGET(target, range: ByteRange(start: 5, end: 9),
                                                                  userAgent: "Evil\r\nCookie: SESSDATA=1"), as: UTF8.self)
        XCTAssertTrue(text.contains("\r\nUser-Agent: EvilCookie: SESSDATA=1\r\n"))
        XCTAssertFalse(text.contains("\r\nCookie:"))
        XCTAssertTrue(BiliHTTP.webUserAgent.contains("Chrome/"))
    }

    func testHostHeaderPortRules() throws {
        func host(_ s: String) -> String? { H1RequestTarget(url: URL(string: s)!)?.origin.hostHeader }
        XCTAssertEqual(host("https://A.Bilivideo.COM/x"), "a.bilivideo.com")
        XCTAssertEqual(host("https://a.bilivideo.com:443/x"), "a.bilivideo.com")
        XCTAssertEqual(host("https://a.bilivideo.com:8443/x"), "a.bilivideo.com:8443")
        XCTAssertEqual(host("http://127.0.0.1:80/x"), "127.0.0.1")
        XCTAssertEqual(host("http://127.0.0.1:8080/x"), "127.0.0.1:8080")
        XCTAssertEqual(host("http://127.0.0.1/x"), "127.0.0.1")
        XCTAssertEqual(host("https://peer.szbdyd.com:4483/x"), "peer.szbdyd.com:4483")
        XCTAssertEqual(host("http://[::1]:8080/x"), "[::1]:8080")
        XCTAssertEqual(H1RequestTarget(url: URL(string: "http://[::1]:8080/x")!)?.origin.host, "::1")
        XCTAssertEqual(H1RequestTarget(url: URL(string: "https://a.bilivideo.com")!)?.pathAndQuery, "/")
        XCTAssertEqual(H1RequestTarget(url: URL(string: "https://a.bilivideo.com:8443/p")!)?.origin.port, 8443)
        XCTAssertNil(H1RequestTarget(url: URL(string: "ftp://a.bilivideo.com/x")!))
        XCTAssertNil(H1RequestTarget(url: URL(string: "file:///tmp/x")!))
        XCTAssertNil(H1RequestTarget(url: URL(string: "/relative/path")!))
    }

    func testOriginFromHostSpec() {
        XCTAssertEqual(H1Origin(hostSpec: "upos-sz-mirrorali.bilivideo.com"),
                       H1Origin(scheme: "https", host: "upos-sz-mirrorali.bilivideo.com", port: 443))
        XCTAssertEqual(H1Origin(hostSpec: "cn-hk-eq-01-01.bilivideo.com:8443")?.port, 8443)
        XCTAssertEqual(H1Origin(hostSpec: "http://127.0.0.1:9000")?.isTLS, false)
        XCTAssertEqual(H1Origin(hostSpec: "http://127.0.0.1:9000")?.port, 9000)
        XCTAssertNil(H1Origin(hostSpec: ""))
        XCTAssertEqual(H1Origin(hostSpec: "127.0.0.1")?.isIPLiteral, true)
        XCTAssertEqual(H1Origin(hostSpec: "a.bilivideo.com")?.isIPLiteral, false)
        XCTAssertEqual(H1Origin(scheme: "http", host: "::1", port: nil)?.isIPLiteral, true)
        XCTAssertEqual(H1Origin(scheme: "https", host: "a.com", port: 443)?.description, "https://a.com")
    }
}

final class MediaEventPipeTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func bytes(_ s: String) -> MediaFetchEvent { .data(Data(s.utf8)) }

    func testOrderingAndNormalEnd() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: ["content-length": "6"]))
        pipe.push(bytes("ab"))
        pipe.push(bytes("cd"))
        pipe.push(bytes("ef"))
        pipe.finish()
        var seen: [String] = []
        for try await e in pipe.makeStream() {
            switch e {
            case .head(let s, _): seen.append("head\(s)")
            case .data(let d): seen.append(String(decoding: d, as: UTF8.self))
            }
        }
        XCTAssertEqual(seen, ["head206", "ab", "cd", "ef"])
        XCTAssertEqual(cancels.value, 0, "a normally finished stream must not report cancellation")
    }

    func testErrorIsThrownAfterBufferedData() async {
        let pipe = MediaEventPipe()
        pipe.push(.head(status: 206, headers: [:]))
        pipe.push(bytes("partial"))
        pipe.finish(throwing: MediaFetchError.connectionClosed)
        pipe.finish() // ignored
        var got = Data()
        do {
            for try await e in pipe.makeStream() { if case .data(let d) = e { got.append(d) } }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MediaFetchError, .connectionClosed)
        }
        XCTAssertEqual(got, Data("partial".utf8))
    }

    func testBackPressureSignalsDemandOnce() async throws {
        let pipe = MediaEventPipe(highWaterBytes: 10)
        let demand = Counter()
        pipe.setHandlers(onDemand: { demand.bump() }, onCancel: {})
        XCTAssertTrue(pipe.push(.head(status: 206, headers: [:])))
        XCTAssertTrue(pipe.push(bytes("123456")))     // 6 < 10
        XCTAssertFalse(pipe.push(bytes("789012")))    // 12 >= 10 → pause
        XCTAssertFalse(pipe.push(bytes("3")))         // still buffered, never dropped
        XCTAssertEqual(pipe.bufferedByteCount, 13)
        var it = pipe.makeStream().makeAsyncIterator()
        _ = try await it.next()                       // head: 13 still buffered
        XCTAssertEqual(demand.value, 0)
        _ = try await it.next()                       // 7 < 10 → demand
        XCTAssertEqual(demand.value, 1)
        _ = try await it.next()
        XCTAssertEqual(demand.value, 1, "demand fires once per pause")
        guard case .data(let last)? = try await it.next() else { return XCTFail("missing data") }
        XCTAssertEqual(last, Data("3".utf8))
        XCTAssertTrue(pipe.push(bytes("x")))
        pipe.finish()
        _ = try await it.next()
        let end = try await it.next()
        XCTAssertNil(end)
    }

    func testDirectHandoffToWaitingConsumer() async throws {
        let pipe = MediaEventPipe(highWaterBytes: 4)
        let demand = Counter()
        pipe.setHandlers(onDemand: { demand.bump() }, onCancel: {})
        let stream = pipe.makeStream()
        let consumer = Task { () -> Int in
            var n = 0
            for try await e in stream {
                if case .data(let d) = e { n += d.count }
                if n % 7 == 0 { await Task.yield() }
            }
            return n
        }
        var demandsSeen = 0
        var pauses = 0
        for i in 0 ..< 50 {
            // `false` = buffered but over the high-water mark: a well-behaved producer waits for onDemand.
            if !pipe.push(.data(Data(repeating: UInt8(i), count: 3))) {
                pauses += 1
                while demand.value == demandsSeen { try await Task.sleep(nanoseconds: 1_000_000) }
                demandsSeen = demand.value
            }
            XCTAssertLessThanOrEqual(pipe.bufferedByteCount, 4 + 3)
        }
        pipe.finish()
        let n = try await consumer.value
        XCTAssertEqual(n, 150)
        XCTAssertEqual(demand.value, pauses)
    }

    func testTaskCancellationWhileWaiting() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: [:]))
        let stream = pipe.makeStream()
        let consumer = Task { () -> String in
            do {
                for try await _ in stream {}
                return "ended"
            } catch {
                return "\(error)"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        let result = await consumer.value
        XCTAssertEqual(result, "\(MediaFetchError.cancelled)")
        XCTAssertEqual(cancels.value, 1)
        XCTAssertTrue(pipe.isCancelled)
        XCTAssertFalse(pipe.push(bytes("late")))
    }

    func testAlreadyCancelledConsumerEndsAndNotifies() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        let stream = pipe.makeStream()
        let consumer = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            var n = 0
            do { for try await _ in stream { n += 1 } } catch { n = -1 }
            return n
        }
        consumer.cancel()
        let n = await consumer.value
        XCTAssertTrue(n == 0 || n == -1, "a cancelled consumer sees the end or .cancelled, got \(n)")
        // The stream (and its token) are gone once the task finished.
        for _ in 0 ..< 100 where cancels.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(cancels.value, 1)
    }

    func testBreakingOutOfLoopReleasesAndNotifies() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: [:]))
        pipe.push(bytes("a"))
        func consumeOne() async throws {
            for try await _ in pipe.makeStream() { break }
        }
        try await consumeOne()
        XCTAssertEqual(cancels.value, 1)
        XCTAssertTrue(pipe.isCancelled)
    }

    func testDroppedStreamNotifies() {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        do { _ = pipe.makeStream() }
        XCTAssertEqual(cancels.value, 1)
    }
}
