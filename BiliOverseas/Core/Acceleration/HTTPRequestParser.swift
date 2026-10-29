import Foundation

// HTTP/1.1 message handling for the loopback media server (proxy-ports §5.2): request-head parsing, lemon-style
// `Range` resolution, response-head serialisation, and the types the server (LocalProxyServer.swift, Network)
// and the engine (AccelerationEngine.swift, Foundation only) exchange.

/// A parsed request head. Header names are lower-cased; repeated headers are joined with ", ".
struct ProxyHTTPRequest: Equatable {
    var method: String
    /// Raw request-target as sent.
    var target: String
    /// Path without the query (absolute-form targets are reduced to their path).
    var path: String
    var query: String?
    /// e.g. "HTTP/1.1".
    var version: String
    var headers: [String: String]

    init(method: String, target: String, version: String = "HTTP/1.1", headers: [String: String] = [:]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        var t = target
        if let schemeEnd = t.range(of: "://") {
            let afterScheme = t[schemeEnd.upperBound...]
            t = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        if let q = t.firstIndex(of: "?") {
            path = String(t[..<q])
            query = String(t[t.index(after: q)...])
        } else {
            path = t
            query = nil
        }
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// True when the connection must be closed after the response (`Connection: close`, or HTTP/1.0 without
    /// `Connection: keep-alive`).
    var wantsClose: Bool {
        let tokens = (header("connection") ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains("close") { return true }
        if version.uppercased() == "HTTP/1.0" { return !tokens.contains("keep-alive") }
        return false
    }

    /// The request carries a body (which this server never reads).
    var hasBody: Bool {
        if let te = header("transfer-encoding"), !te.isEmpty { return true }
        if let cl = header("content-length"), let n = Int64(cl.trimmingCharacters(in: .whitespaces)), n > 0 {
            return true
        }
        return false
    }
}

enum HTTPRequestParseResult: Equatable {
    /// Need more bytes.
    case incomplete
    /// `consumed` = bytes of the head including the terminating CRLFCRLF.
    case complete(ProxyHTTPRequest, consumed: Int)
    /// No CRLFCRLF within `maxHeadBytes` → 431.
    case tooLarge
    /// Not a valid HTTP/1.x request head → 400.
    case invalid
}

enum HTTPRequestParser {
    static let maxHeadBytes = 16 * 1024

    /// Parses one request head from the start of `buffer`.
    static func parse(_ buffer: Data) -> HTTPRequestParseResult {
        let bytes = [UInt8](buffer.prefix(maxHeadBytes + 4))
        guard let end = headEnd(bytes) else {
            return buffer.count > maxHeadBytes ? .tooLarge : .incomplete
        }
        guard end <= maxHeadBytes else { return .tooLarge }
        guard let text = String(bytes: bytes[0..<end], encoding: .utf8)
                ?? String(bytes: bytes[0..<end], encoding: .isoLatin1) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return .invalid }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard version.uppercased().hasPrefix("HTTP/1."), !method.isEmpty,
              method.allSatisfy({ $0.isLetter && $0.isASCII }) else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return .complete(ProxyHTTPRequest(method: method, target: target, version: version, headers: headers),
                         consumed: end + 4)
    }

    /// Index of the first CRLFCRLF.
    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}

/// Client `Range` header resolution against a known file total (lemon `parseRange`, proxy-ports §3.2):
/// - no header → the whole file;
/// - `bytes=S-E` → `[S, min(E, total-1)]`, requires `E >= S` and `S < total`;
/// - `bytes=S-` → `[S, total-1]`, requires `S < total`;
/// - `bytes=-N` → the last `N` bytes, requires `N > 0`;
/// - multi-range, `bytes=-`, `bytes=-0`, malformed → nil (answer 416 with `Content-Range: bytes */total`).
enum HTTPRangeSpec {
    static func resolve(_ header: String?, total: Int64) -> ByteRange? {
        guard total > 0 else { return nil }
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return ByteRange(start: 0, end: total - 1)
        }
        guard raw.count > 6, raw.prefix(6).lowercased() == "bytes=" else { return nil }
        let spec = raw.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let first = String(pieces[0])
        let second = String(pieces[1])
        guard first.allSatisfy(\.isASCIIDigit), second.allSatisfy(\.isASCIIDigit) else { return nil }
        if first.isEmpty && second.isEmpty { return nil }
        // Digit strings too long for Int64 are still valid syntax (RFC 9110 §14.1.2): a last-pos / suffix-length at
        // or beyond the length means "to the end" / "the whole representation"; such a first-pos is unsatisfiable.
        if first.isEmpty {
            guard second.contains(where: { $0 != "0" }) else { return nil }
            let suffix = Int64(second) ?? Int64.max
            return ByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(first) else { return nil }
        let end: Int64
        if second.isEmpty {
            end = total - 1
        } else {
            end = min(Int64(second) ?? Int64.max, total - 1)
        }
        guard start < total, end >= start else { return nil }
        return ByteRange(start: start, end: end)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Status line + headers of a response.
struct ProxyHTTPResponseHead: Equatable {
    var status: Int
    /// In order; names as written.
    var headers: [(String, String)]

    init(status: Int, headers: [(String, String)] = []) {
        self.status = status
        self.headers = headers
    }

    static func == (a: ProxyHTTPResponseHead, b: ProxyHTTPResponseHead) -> Bool {
        a.status == b.status && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    func value(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    var serialized: Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

// MARK: - Server ↔ engine contract

/// Streams a response body in order. `nextChunk()` returns nil at the end; throwing after the head was sent makes
/// the server close the connection (a visibly truncated body, never padding).
protocol LocalProxyBodySource: AnyObject {
    func nextChunk() async throws -> Data?
    /// Stop producing (client gone, or the server is done). Idempotent.
    func cancel()
}

struct LocalProxyResponse {
    enum Body {
        case none
        case data(Data)
        case stream(LocalProxyBodySource)
    }

    var status: Int
    /// Without `Connection` (the server adds it).
    var headers: [(String, String)]
    var body: Body
    /// Bytes the body will carry (the `Content-Length` header value; 0 for HEAD-style responses).
    var contentLength: Int64
    /// Force `Connection: close` after this response.
    var closeConnection: Bool = false

    init(status: Int, headers: [(String, String)], body: Body, contentLength: Int64, closeConnection: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLength = contentLength
        self.closeConnection = closeConnection
    }

    /// An empty-bodied response (`Content-Length: 0`).
    static func empty(_ status: Int, headers: [(String, String)] = [], close: Bool = false) -> LocalProxyResponse {
        LocalProxyResponse(status: status, headers: headers + [("Content-Length", "0")], body: .none,
                           contentLength: 0, closeConnection: close)
    }

    static var notFound: LocalProxyResponse { empty(404) }
    static var methodNotAllowed: LocalProxyResponse { empty(405, headers: [("Allow", "GET, HEAD")]) }
    static var badGateway: LocalProxyResponse { empty(502) }

    static func rangeNotSatisfiable(total: Int64) -> LocalProxyResponse {
        empty(416, headers: [("Content-Range", "bytes */\(total)"), ("Accept-Ranges", "bytes")])
    }
}

/// Answers the loopback server's requests (implemented by `AccelerationEngine`).
protocol LocalProxyRequestHandler: AnyObject {
    func handle(_ request: ProxyHTTPRequest) async -> LocalProxyResponse
}

/// The loopback listener as seen by the engine (real one: `LocalProxyServer`; tests inject a fake).
protocol LocalProxyServing: AnyObject {
    /// Starts listening if not already (idempotent, non-blocking).
    func start()
    /// Waits until the listener is ready and returns its port.
    func waitUntilReady(timeout: TimeInterval) async throws -> UInt16
    /// After the app returns to the foreground: rebinds the SAME port if the listener died while suspended.
    func ensureListening()
    /// Current port, 0 when not listening.
    var port: UInt16 { get }
    /// Called with the new port when the listener could not get its old port back.
    var onPortChange: ((UInt16) -> Void)? { get set }
    func stop()
}
