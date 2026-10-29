import XCTest
@testable import BiliCore

final class HTTPRequestParserTests: XCTestCase {
    private func parse(_ text: String) -> HTTPRequestParseResult { HTTPRequestParser.parse(Data(text.utf8)) }

    func testParsesHeadWithCaseInsensitiveHeaders() {
        let raw = "GET /abc/v.m4s?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nRANGE: bytes=0-99\r\nX-Playback-Session-Id: 1\r\n"
            + "Accept: */*\r\naccept: video/mp4\r\n\r\nGET /next HTTP/1.1\r\n"
        guard case let .complete(request, consumed) = parse(raw) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/abc/v.m4s")
        XCTAssertEqual(request.query, "x=1")
        XCTAssertEqual(request.version, "HTTP/1.1")
        XCTAssertEqual(request.header("range"), "bytes=0-99")
        XCTAssertEqual(request.header("Range"), "bytes=0-99")
        XCTAssertEqual(request.header("x-playback-session-id"), "1")
        XCTAssertEqual(request.header("accept"), "*/*, video/mp4")
        XCTAssertFalse(request.wantsClose)
        XCTAssertFalse(request.hasBody)
        // The pipelined next request stays in the buffer.
        XCTAssertEqual(consumed, raw.utf8.count - "GET /next HTTP/1.1\r\n".utf8.count)
    }

    func testIncompleteTooLargeAndInvalid() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\r\n"), .incomplete)
        XCTAssertEqual(parse(""), .incomplete)
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 17 * 1024)
        XCTAssertEqual(parse(huge), .tooLarge)
        XCTAssertEqual(parse("GARBAGE\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("GET / SPDY/3\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nno colon here\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("G3T / HTTP/1.1\r\n\r\n"), .invalid)
    }

    func testConnectionSemantics() {
        func request(_ version: String, _ connection: String?) -> ProxyHTTPRequest {
            var headers: [String: String] = [:]
            if let connection { headers["connection"] = connection }
            return ProxyHTTPRequest(method: "GET", target: "/", version: version, headers: headers)
        }
        XCTAssertFalse(request("HTTP/1.1", nil).wantsClose)
        XCTAssertTrue(request("HTTP/1.1", "close").wantsClose)
        XCTAssertTrue(request("HTTP/1.1", "Keep-Alive, Close").wantsClose)
        XCTAssertTrue(request("HTTP/1.0", nil).wantsClose)
        XCTAssertFalse(request("HTTP/1.0", "keep-alive").wantsClose)
        let post = ProxyHTTPRequest(method: "POST", target: "/", headers: ["content-length": "5"])
        XCTAssertTrue(post.hasBody)
    }

    func testAbsoluteFormTarget() {
        let r = ProxyHTTPRequest(method: "GET", target: "http://127.0.0.1:1234/tok/master.m3u8?a=b")
        XCTAssertEqual(r.path, "/tok/master.m3u8")
        XCTAssertEqual(r.query, "a=b")
        XCTAssertEqual(ProxyHTTPRequest(method: "GET", target: "http://127.0.0.1:1234").path, "/")
    }

    /// lemon `parseRange` vectors (proxy-ports §3.2), total = 100.
    func testLemonRangeVectors() {
        let total: Int64 = 100
        XCTAssertEqual(HTTPRangeSpec.resolve(nil, total: total), ByteRange(start: 0, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=20-", total: total), ByteRange(start: 20, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=20-999", total: total), ByteRange(start: 20, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=-10", total: total), ByteRange(start: 90, end: 99))
        for rejected in ["bytes=100-", "bytes=20-10", "bytes=-0", "bytes=1-2,4-5", "bytes=-"] {
            XCTAssertNil(HTTPRangeSpec.resolve(rejected, total: total), rejected)
        }
    }

    func testMoreRangeForms() {
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=0-0", total: 100), ByteRange(start: 0, end: 0))
        XCTAssertEqual(HTTPRangeSpec.resolve("Bytes=5-9", total: 100), ByteRange(start: 5, end: 9))
        XCTAssertEqual(HTTPRangeSpec.resolve(" bytes=99-99 ", total: 100), ByteRange(start: 99, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=-500", total: 100), ByteRange(start: 0, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("", total: 100), ByteRange(start: 0, end: 99))
        for rejected in ["items=0-1", "bytes=a-1", "bytes=1", "bytes=", "bytes=+1-2", "bytes=1-2-3"] {
            XCTAssertNil(HTTPRangeSpec.resolve(rejected, total: 100), rejected)
        }
        XCTAssertNil(HTTPRangeSpec.resolve(nil, total: 0))
    }

    /// RFC 9110 §14.1.2: positions too large for Int64 are valid syntax, not a 416.
    func testOversizedRangeNumbers() {
        let huge = "99999999999999999999999"
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=10-\(huge)", total: 100), ByteRange(start: 10, end: 99))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=-\(huge)", total: 100), ByteRange(start: 0, end: 99))
        XCTAssertNil(HTTPRangeSpec.resolve("bytes=\(huge)-", total: 100))
        XCTAssertNil(HTTPRangeSpec.resolve("bytes=-000", total: 100))
        XCTAssertEqual(HTTPRangeSpec.resolve("bytes=-007", total: 100), ByteRange(start: 93, end: 99))
    }

    func testResponseHeadSerialization() {
        let head = ProxyHTTPResponseHead(status: 206, headers: [("Content-Type", "video/mp4"),
                                                                 ("Content-Range", "bytes 0-9/100"),
                                                                 ("Content-Length", "10")])
        XCTAssertEqual(String(decoding: head.serialized, as: UTF8.self),
                       "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes 0-9/100\r\n"
                           + "Content-Length: 10\r\n\r\n")
        XCTAssertEqual(head.value("content-length"), "10")
        XCTAssertEqual(ProxyHTTPResponseHead.reason(416), "Range Not Satisfiable")
        XCTAssertEqual(ProxyHTTPResponseHead.reason(502), "Bad Gateway")
        let unsatisfiable = LocalProxyResponse.rangeNotSatisfiable(total: 1234)
        XCTAssertEqual(unsatisfiable.status, 416)
        XCTAssertTrue(unsatisfiable.headers.contains { $0 == ("Content-Range", "bytes */1234") })
        XCTAssertTrue(unsatisfiable.headers.contains { $0 == ("Content-Length", "0") })
        XCTAssertTrue(LocalProxyResponse.methodNotAllowed.headers.contains { $0 == ("Allow", "GET, HEAD") })
    }
}
