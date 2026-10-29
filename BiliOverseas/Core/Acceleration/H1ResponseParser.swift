import Foundation

// Pure-Foundation HTTP/1.1 building blocks for `H1MediaClient` (no Network import, so this file is unit-tested on
// Linux too): an incremental response parser, the request serializer, and URL → connection-origin mapping.

// MARK: - Origin / request target

/// Where a connection goes: scheme (TLS or not), host and port. Connections are pooled per origin.
struct H1Origin: Hashable, CustomStringConvertible {
    var isTLS: Bool
    /// Lower-cased host name, or an IP literal (IPv6 without brackets).
    var host: String
    var port: UInt16

    init?(scheme: String, host: String, port: Int?) {
        switch scheme.lowercased() {
        case "https": isTLS = true
        case "http": isTLS = false
        default: return nil
        }
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty, !h.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "/") }) else {
            return nil
        }
        self.host = h
        let p = port ?? (isTLS ? 443 : 80)
        guard p > 0, p <= 65535 else { return nil }
        self.port = UInt16(p)
    }

    /// `"host"`, `"host:port"` or a URL string (`"https://host[:port]/…"`). Bare hosts mean https.
    init?(hostSpec: String) {
        let spec = hostSpec.trimmingCharacters(in: .whitespaces)
        let urlString = spec.contains("://") ? spec : "https://" + spec
        guard let comps = URLComponents(string: urlString), let scheme = comps.scheme, let host = comps.host else {
            return nil
        }
        self.init(scheme: scheme, host: host, port: comps.port)
    }

    var defaultPort: UInt16 { isTLS ? 443 : 80 }

    var isIPLiteral: Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && (Int(p) ?? 256) <= 255
        }
    }

    /// `Host` header value: port only when it isn't the scheme's default; IPv6 literals in brackets.
    var hostHeader: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? h : "\(h):\(port)"
    }

    var description: String { "\(isTLS ? "https" : "http")://\(hostHeader)" }
}

/// Origin + origin-form request target of one URL.
struct H1RequestTarget: Equatable {
    var origin: H1Origin
    /// `"/path?query"`, percent-encoding preserved byte for byte (signed CDN queries must not be re-encoded).
    var pathAndQuery: String

    init?(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = comps.scheme, let host = comps.host,
              let origin = H1Origin(scheme: scheme, host: host, port: comps.port) else { return nil }
        var target = comps.percentEncodedPath
        if target.isEmpty { target = "/" }
        guard target.hasPrefix("/") else { return nil }
        if let q = comps.percentEncodedQuery { target += "?" + q }
        // Request-target must be visible ASCII: no spaces / controls / raw non-ASCII (would corrupt the request line).
        guard target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        self.origin = origin
        pathAndQuery = target
    }
}

// MARK: - Request serializer

enum H1RequestSerializer {
    static let referer = "https://www.bilibili.com/"
    static let origin = "https://www.bilibili.com"

    /// Media request headers shared by both upstream clients (BTR spec §12). Never includes cookies.
    static func mediaHeaderFields(range: ByteRange, userAgent: String) -> [(name: String, value: String)] {
        [
            ("Range", "bytes=\(range.start)-\(range.end)"),
            ("User-Agent", sanitize(userAgent)),
            ("Accept", "*/*"),
            ("Accept-Encoding", "identity"),
            ("Origin", origin),
            ("Referer", referer),
        ]
    }

    /// `GET <path?query> HTTP/1.1` with Host, the media headers and `Connection: keep-alive`.
    static func rangeGET(_ target: H1RequestTarget, range: ByteRange, userAgent: String) -> Data {
        var s = "GET \(target.pathAndQuery) HTTP/1.1\r\nHost: \(target.origin.hostHeader)\r\n"
        for field in mediaHeaderFields(range: range, userAgent: userAgent) {
            s += "\(field.name): \(field.value)\r\n"
        }
        s += "Connection: keep-alive\r\n\r\n"
        return Data(s.utf8)
    }

    /// Strips CR/LF and other control characters (header injection).
    static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }
}

// MARK: - Response parser

struct H1ResponseHead: Equatable {
    var majorVersion: Int
    var minorVersion: Int
    var status: Int
    var reason: String
    /// Lower-cased field names; repeated fields joined with `", "`.
    var headers: [String: String]

    subscript(name: String) -> String? { headers[name.lowercased()] }

    var isHTTP11OrLater: Bool { majorVersion > 1 || (majorVersion == 1 && minorVersion >= 1) }

    /// Lower-cased tokens of the `Connection` header.
    var connectionTokens: [String] {
        guard let v = headers["connection"] else { return [] }
        return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

enum H1ParseError: Error, Equatable, CustomStringConvertible {
    case malformedStatusLine(String)
    case malformedHeader(String)
    case headersTooLarge
    case invalidContentLength(String)
    case invalidChunkedEncoding(String)
    /// 101 Switching Protocols (never requested) or too many 1xx interim responses.
    case unexpectedInterimResponse(Int)
    /// The peer closed the connection before the message was complete.
    case truncated

    var description: String {
        switch self {
        case .malformedStatusLine(let l): return "malformed status line: \(l.prefix(80))"
        case .malformedHeader(let l): return "malformed header: \(l.prefix(80))"
        case .headersTooLarge: return "response header section too large"
        case .invalidContentLength(let v): return "invalid Content-Length: \(v.prefix(40))"
        case .invalidChunkedEncoding(let m): return "invalid chunked encoding: \(m.prefix(80))"
        case .unexpectedInterimResponse(let s): return "unexpected interim response \(s)"
        case .truncated: return "connection closed before the response was complete"
        }
    }
}

enum H1ParseEvent: Equatable {
    /// Final (non-1xx) response head. Emitted exactly once, before any body bytes.
    case head(H1ResponseHead)
    /// Decoded body bytes (chunked framing removed), in order. Never empty.
    case body(Data)
}

/// Incremental HTTP/1.x response parser for one response on a connection.
///
/// Feed it byte chunks split anywhere; it emits the head (1xx interim responses are skipped), then body bytes
/// framed by `Content-Length`, `Transfer-Encoding: chunked`, or read-until-close (call `finish()` on EOF).
/// After completion, `isReusable` says whether the connection may carry another request.
struct H1ResponseParser {
    static let defaultMaxHeaderBytes = 64 * 1024
    static let maxChunkLineBytes = 4 * 1024
    static let maxInterimResponses = 16

    enum Framing: Equatable {
        case noBody
        case contentLength(Int64)
        case chunked
        case untilClose
    }

    let maxHeaderBytes: Int
    private(set) var head: H1ResponseHead?
    private(set) var framing: Framing?
    private(set) var isComplete = false
    /// Decoded body bytes emitted so far.
    private(set) var bodyBytesReceived: Int64 = 0
    /// Bytes arrived after the end of the response (no pipelining, so the connection can't be trusted).
    private(set) var hasTrailingData = false
    private(set) var interimResponses = 0
    private(set) var trailers: [String: String] = [:]

    private enum State {
        case head
        case fixed(remaining: Int64)
        case untilClose
        case chunkSize
        case chunkData(remaining: Int64)
        case chunkDataEnd(sawCR: Bool)
        case trailers
        case done
    }

    private var state: State = .head
    private var failure: H1ParseError?
    /// Head bytes collected so far (also reused for chunk-size and trailer lines).
    private var buffer: [UInt8] = []
    private var headBytesSeen = 0
    private var currentLineLength = 0
    private var trailerBytesSeen = 0
    /// Framing ambiguity (Transfer-Encoding together with Content-Length, or TE on HTTP/1.0): never reuse.
    private var forceClose = false

    init(maxHeaderBytes: Int = H1ResponseParser.defaultMaxHeaderBytes) {
        self.maxHeaderBytes = maxHeaderBytes
    }

    /// Declared body length (nil unless framed by Content-Length).
    var expectedBodyLength: Int64? {
        if case .contentLength(let n)? = framing { return n }
        return nil
    }

    /// The connection may carry another request: complete, HTTP/1.1+, no `Connection: close`, self-delimited body,
    /// no stray bytes after the message.
    var isReusable: Bool {
        guard isComplete, failure == nil, !hasTrailingData, !forceClose, let head, head.isHTTP11OrLater else {
            return false
        }
        if head.connectionTokens.contains("close") { return false }
        if framing == .untilClose { return false }
        return true
    }

    // MARK: Feeding

    mutating func feed(_ data: Data) throws -> [H1ParseEvent] {
        if let failure { throw failure }
        do {
            return try parse(data)
        } catch let e as H1ParseError {
            failure = e
            throw e
        }
    }

    /// The peer closed the connection (EOF). Completes a read-until-close body; otherwise throws `.truncated` unless
    /// the response was already complete.
    mutating func finish() throws -> [H1ParseEvent] {
        if let failure { throw failure }
        switch state {
        case .done:
            return []
        case .untilClose:
            state = .done
            isComplete = true
            return []
        default:
            failure = .truncated
            throw H1ParseError.truncated
        }
    }

    private mutating func parse(_ data: Data) throws -> [H1ParseEvent] {
        var events: [H1ParseEvent] = []
        var body: Data?
        func emit(_ range: Range<Data.Index>) {
            guard !range.isEmpty else { return }
            let piece = (range.lowerBound == data.startIndex && range.upperBound == data.endIndex)
                ? data : Data(data[range])
            if body == nil { body = piece } else { body!.append(piece) }
        }

        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            switch state {
            case .head:
                while i < end {
                    let b = data[i]
                    i += 1
                    headBytesSeen += 1
                    if headBytesSeen > maxHeaderBytes { throw H1ParseError.headersTooLarge }
                    if b == 0x0A {
                        if currentLineLength == 0 {
                            if buffer.allSatisfy({ $0 == 0x0D || $0 == 0x0A }) {
                                buffer.removeAll(keepingCapacity: true) // tolerate stray CRLFs before a status line
                                continue
                            }
                            let parsed = try Self.parseHead(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            headBytesSeen = 0
                            if parsed.status < 200 {
                                interimResponses += 1
                                if parsed.status == 101 || interimResponses > Self.maxInterimResponses {
                                    throw H1ParseError.unexpectedInterimResponse(parsed.status)
                                }
                                continue // 100-continue / 103 early hints: wait for the final response
                            }
                            try begin(parsed)
                            events.append(.head(parsed))
                            break // leaves the head-scanning loop; the outer loop continues with the body state
                        }
                        buffer.append(b)
                        currentLineLength = 0
                    } else {
                        buffer.append(b)
                        if b != 0x0D { currentLineLength += 1 }
                    }
                }

            case .fixed(let remaining):
                let take = Int(min(remaining, Int64(end - i)))
                emit(i ..< i + take)
                i += take
                bodyBytesReceived += Int64(take)
                if remaining - Int64(take) == 0 { complete() } else { state = .fixed(remaining: remaining - Int64(take)) }

            case .untilClose:
                emit(i ..< end)
                bodyBytesReceived += Int64(end - i)
                i = end

            case .chunkSize:
                while i < end {
                    let b = data[i]
                    i += 1
                    if b == 0x0A {
                        let size = try Self.parseChunkSize(buffer)
                        buffer.removeAll(keepingCapacity: true)
                        if size == 0 {
                            state = .trailers
                            currentLineLength = 0
                        } else {
                            state = .chunkData(remaining: size)
                        }
                        break
                    }
                    buffer.append(b)
                    if buffer.count > Self.maxChunkLineBytes {
                        throw H1ParseError.invalidChunkedEncoding("chunk-size line too long")
                    }
                }

            case .chunkData(let remaining):
                let take = Int(min(remaining, Int64(end - i)))
                emit(i ..< i + take)
                i += take
                bodyBytesReceived += Int64(take)
                state = remaining - Int64(take) == 0 ? .chunkDataEnd(sawCR: false) : .chunkData(remaining: remaining - Int64(take))

            case .chunkDataEnd(let sawCR):
                let b = data[i]
                i += 1
                if b == 0x0A {
                    state = .chunkSize
                } else if b == 0x0D && !sawCR {
                    state = .chunkDataEnd(sawCR: true)
                } else {
                    throw H1ParseError.invalidChunkedEncoding("missing CRLF after chunk data")
                }

            case .trailers:
                while i < end {
                    let b = data[i]
                    i += 1
                    trailerBytesSeen += 1
                    if trailerBytesSeen > maxHeaderBytes { throw H1ParseError.headersTooLarge }
                    if b == 0x0A {
                        if currentLineLength == 0 {
                            try parseTrailers(buffer)
                            buffer.removeAll()
                            complete()
                            break
                        }
                        buffer.append(b)
                        currentLineLength = 0
                    } else {
                        buffer.append(b)
                        if b != 0x0D { currentLineLength += 1 }
                    }
                }

            case .done:
                hasTrailingData = true
                i = end
            }
        }
        if let b = body { events.append(.body(b)) }
        return events
    }

    private mutating func complete() {
        state = .done
        isComplete = true
    }

    /// Picks the body framing for the final head (RFC 9112 §6.3).
    private mutating func begin(_ h: H1ResponseHead) throws {
        head = h
        if h.status == 204 || h.status == 304 {
            framing = .noBody
            complete()
            return
        }
        if let te = h.headers["transfer-encoding"] {
            let codings = te.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "identity" }
            if !codings.isEmpty {
                if h.headers["content-length"] != nil || !h.isHTTP11OrLater { forceClose = true }
                if codings.last == "chunked" {
                    framing = .chunked
                    state = .chunkSize
                } else {
                    framing = .untilClose
                    state = .untilClose
                }
                return
            }
        }
        if let cl = h.headers["content-length"] {
            let n = try Self.parseContentLength(cl)
            framing = .contentLength(n)
            if n == 0 { complete() } else { state = .fixed(remaining: n) }
            return
        }
        framing = .untilClose
        state = .untilClose
    }

    // MARK: Line parsing

    static func parseContentLength(_ value: String) throws -> Int64 {
        var result: Int64?
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int64(t),
                  result == nil || result == n else {
                throw H1ParseError.invalidContentLength(value)
            }
            result = n
        }
        guard let result else { throw H1ParseError.invalidContentLength(value) }
        return result
    }

    static func parseChunkSize(_ line: [UInt8]) throws -> Int64 {
        var bytes = line[...]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        if let semi = bytes.firstIndex(of: UInt8(ascii: ";")) { bytes = bytes[..<semi] } // chunk extensions
        while let f = bytes.first, f == 0x20 || f == 0x09 { bytes = bytes.dropFirst() }
        while let l = bytes.last, l == 0x20 || l == 0x09 { bytes = bytes.dropLast() }
        let text = String(decoding: line, as: UTF8.self)
        guard !bytes.isEmpty else { throw H1ParseError.invalidChunkedEncoding("empty chunk size: \(text)") }
        var value: Int64 = 0
        var significant = 0
        for b in bytes {
            let digit: Int64
            switch b {
            case 48...57: digit = Int64(b - 48)
            case 65...70: digit = Int64(b - 55)
            case 97...102: digit = Int64(b - 87)
            default: throw H1ParseError.invalidChunkedEncoding("bad chunk size: \(text)")
            }
            if significant > 0 || digit != 0 { significant += 1 }
            if significant > 15 { throw H1ParseError.invalidChunkedEncoding("chunk size overflow: \(text)") }
            value = value * 16 + digit
        }
        return value
    }

    /// Splits a head into lines (LF or CRLF), parses the status line and header fields.
    static func parseHead(_ bytes: [UInt8]) throws -> H1ResponseHead {
        var lines: [ArraySlice<UInt8>] = []
        var start = 0
        for (idx, b) in bytes.enumerated() where b == 0x0A {
            lines.append(trimCR(bytes[start ..< idx]))
            start = idx + 1
        }
        if start < bytes.count { lines.append(trimCR(bytes[start...])) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let statusLine = lines.first else { throw H1ParseError.malformedStatusLine("") }
        var head = try parseStatusLine(statusLine)
        head.headers = try parseFields(lines.dropFirst())
        return head
    }

    static func parseStatusLine(_ line: ArraySlice<UInt8>) throws -> H1ResponseHead {
        let b = Array(line)
        let text = String(decoding: b, as: UTF8.self)
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        guard b.count >= 12,
              b[0] == UInt8(ascii: "H"), b[1] == UInt8(ascii: "T"), b[2] == UInt8(ascii: "T"),
              b[3] == UInt8(ascii: "P"), b[4] == UInt8(ascii: "/"),
              isDigit(b[5]), b[6] == UInt8(ascii: "."), isDigit(b[7]), b[8] == 0x20,
              isDigit(b[9]), isDigit(b[10]), isDigit(b[11]), b[9] != 48,
              b.count == 12 || b[12] == 0x20 else {
            throw H1ParseError.malformedStatusLine(text)
        }
        let status = Int(b[9] - 48) * 100 + Int(b[10] - 48) * 10 + Int(b[11] - 48)
        let reason = b.count > 13 ? String(decoding: b[13...], as: UTF8.self) : ""
        return H1ResponseHead(majorVersion: Int(b[5] - 48), minorVersion: Int(b[7] - 48), status: status,
                              reason: reason, headers: [:])
    }

    static func parseFields<S: Sequence>(_ lines: S) throws -> [String: String] where S.Element == ArraySlice<UInt8> {
        var fields: [String: String] = [:]
        var lastName: String?
        for line in lines where !line.isEmpty {
            if let f = line.first, f == 0x20 || f == 0x09 { // obsolete line folding: continuation of the last field
                guard let name = lastName else {
                    throw H1ParseError.malformedHeader(String(decoding: line, as: UTF8.self))
                }
                let more = trimOWS(line)
                if !more.isEmpty { fields[name, default: ""] += " " + String(decoding: more, as: UTF8.self) }
                continue
            }
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
                throw H1ParseError.malformedHeader(String(decoding: line, as: UTF8.self))
            }
            var nameBytes = line[line.startIndex ..< colon]
            while let l = nameBytes.last, l == 0x20 || l == 0x09 { nameBytes = nameBytes.dropLast() }
            guard !nameBytes.isEmpty, !nameBytes.contains(where: { $0 <= 0x20 || $0 >= 0x7F }) else {
                throw H1ParseError.malformedHeader(String(decoding: line, as: UTF8.self))
            }
            let name = String(decoding: nameBytes, as: UTF8.self).lowercased()
            let value = String(decoding: trimOWS(line[(colon + 1)...]), as: UTF8.self)
            if let existing = fields[name] { fields[name] = existing + ", " + value } else { fields[name] = value }
            lastName = name
        }
        return fields
    }

    private mutating func parseTrailers(_ bytes: [UInt8]) throws {
        var lines: [ArraySlice<UInt8>] = []
        var start = 0
        for (idx, b) in bytes.enumerated() where b == 0x0A {
            lines.append(Self.trimCR(bytes[start ..< idx]))
            start = idx + 1
        }
        if start < bytes.count { lines.append(Self.trimCR(bytes[start...])) }
        trailers = try Self.parseFields(lines)
    }

    private static func trimCR(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        s.last == 0x0D ? s.dropLast() : s
    }

    private static func trimOWS(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var s = s
        while let f = s.first, f == 0x20 || f == 0x09 { s = s.dropFirst() }
        while let l = s.last, l == 0x20 || l == 0x09 { s = s.dropLast() }
        return s
    }
}
