import Foundation

// Port of Bilibili-thread-ripper `src/range-core.js` (MIT): media-URL whitelist, byte-range parsing, piece
// splitting, custom-host sanitizing, and the fixed constants of the downloader (BTR spec §1, §2).

/// Every fixed number of the BTR downloader in one place (BTR spec §1.1–1.3, proxy-ports §3).
enum BTRConstants {
    /// Floor piece size; also the startup head size.
    static let minChunkBytes = 64 * 1024
    /// Upper bound of an adaptive piece.
    static let maxChunkBytes = 1024 * 1024
    /// lemon: an audio piece is at least this large (one 64 KiB piece per round trip capped audio near 1 Mbit/s).
    static let audioPieceFloorBytes = 256 * 1024
    /// Abort an attempt whose response headers have not arrived.
    static let firstByteTimeoutMs: Double = 5500
    /// Abort an attempt whose body stopped for this long (re-armed per chunk).
    static let stallTimeoutMs: Double = 4000
    /// Hard cap on one attempt, headers + body.
    static let attemptTimeoutMs: Double = 15000
    /// Maximum (and unmeasured) hedge delay.
    static let hedgeDelayMs: Double = 900
    /// Rounds over a piece's candidate list.
    static let pieceRounds = 3
    /// No new round once a piece has been running this long.
    static let pieceRetryWindowMs: Double = 25000
    /// Resume from a verified prefix only if it is at least this long.
    static let resumeMinBytes = 32 * 1024
    static let hedgeSlackMs: Double = 1500
    static let hedgePace = 0.6
    static let hedgeFaster = 1.5
    /// +20 priority per 0.9 s waited (ordinary class with a deadline only).
    static let queueAgingPerMs = 20.0 / 900.0
    /// Shorter transfers never update a speed.
    static let speedSampleMinBytes = 48 * 1024
    /// Per-piece candidate cap.
    static let maxPieceCandidates = 8
    /// Hedge copies queue with this much more priority (and on the rescue lane).
    static let hedgeCopyPriorityBonus = 20
    /// init / index race and startup head probe.
    static let startupPriority = 220
    /// init / index race: candidate i starts this long after the race.
    static let metaStaggerMs: [Double] = [0, 120, 300]
    static let metaRaceWidth = 3
    /// hedgeDue polling interval.
    static let hedgePollMs: Double = 50
    /// Ordinary ranges shorter than this are a single piece (desktop `maxConcurrency 1`); its node is picked in turns.
    static let singlePieceBelowBytes: Int64 = 128 * 1024
    static let maxSplitPieces = 512

    /// Pause before round `round` (1-based) of a piece: 500 ms, 1000 ms, … at most 2 s.
    static func roundPauseMs(_ round: Int, baseMs: Double = 500) -> Double {
        min(2000, baseMs * pow(2, Double(max(0, round - 1))))
    }
}

/// One sub-range of a range, downloaded by one or more attempts.
struct BTRPiece: Hashable {
    var index: Int
    var start: Int64
    var end: Int64
    var length: Int { Int(end - start + 1) }
    var range: ByteRange { ByteRange(start: start, end: end) }
}

/// A parsed `Content-Range: bytes a-b/total` header.
struct BTRContentRange: Hashable {
    var start: Int64
    var end: Int64
    /// nil for `*`.
    var total: Int64?
    var length: Int64 { end - start + 1 }
}

enum BTRRangeCore {
    static let mediaSuffixes = [".m4s", ".mp4", ".flv"]
    /// `MEDIA_HOST_RE` = `(?:^|\.)(?:bilivideo\.(?:com|cn|net)|akamaized\.net|szbdyd\.com|hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$`
    static let mediaHostSuffixes = [
        "bilivideo.com", "bilivideo.cn", "bilivideo.net", "akamaized.net", "szbdyd.com", "hdslb.com",
        "xycdn.com", "mountaintoys.cn", "nexusedgeio.com", "ahdohpiechei.com",
    ]

    // MARK: Whitelist

    /// Host matches `MEDIA_HOST_RE` (case-insensitive).
    static func isMediaHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return mediaHostSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Path (percent-encoded, as `URL.pathname`) ends with `.m4s` / `.mp4` / `.flv` (case-insensitive).
    static func isMediaPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return mediaSuffixes.contains { p.hasSuffix($0) }
    }

    /// `isBilibiliMediaUrl`: https only, media path suffix, media host. Signed URLs never go anywhere else.
    static func isBilibiliMediaURL(_ value: String) -> Bool {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty else { return false }
        return isMediaPath(c.percentEncodedPath) && isMediaHost(host)
    }

    /// DNS name: `^[a-z\d](?:[a-z\d-]*[a-z\d])?(?:\.[a-z\d](?:[a-z\d-]*[a-z\d])?)+$` (lower-case input).
    static func isDNSName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard let first = label.first, let last = label.last else { return false }
            for ch in label.unicodeScalars {
                let ok = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "-"
                if !ok { return false }
            }
            if first == "-" || last == "-" { return false }
        }
        return true
    }

    /// Sanitizes a custom CDN host entered by the user (BTR `normalizeCdnHost`): only the host name of a Bilibili
    /// media server survives; anything else becomes "".
    static func normalizeCdnHost(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty || text.count > 253 { return "" }
        let hasScheme: Bool = {
            guard let r = text.range(of: "://") else { return false }
            let scheme = text[text.startIndex..<r.lowerBound]
            guard let f = scheme.unicodeScalars.first, f >= "a" && f <= "z" else { return false }
            return scheme.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "+" || $0 == "." || $0 == "-" }
        }()
        guard let c = URLComponents(string: hasScheme ? text : "https://\(text)"), let host = c.host?.lowercased(), !host.isEmpty
        else { return "" }
        return isDNSName(host) && isMediaHost(host) ? host : ""
    }

    // MARK: Ranges

    private static func parseDigits<S: StringProtocol>(_ s: S) -> Int64? {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        // JS requires a safe integer (≤ 2^53 − 1).
        guard let v = Int64(s), v <= 9_007_199_254_740_991 else { return nil }
        return v
    }

    /// `"123-456"` → range; requires safe integers and `end >= start` (`parseByteRange`).
    static func parseByteRange(_ value: String) -> ByteRange? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let s = parseDigits(parts[0]), let e = parseDigits(parts[1]), e >= s else { return nil }
        return ByteRange(start: s, end: e)
    }

    /// `bytes=a-b` (closed only — an open-ended `bytes=a-` is not accelerated) (`parseRangeHeader`).
    static func parseRangeHeader(_ value: String?) -> ByteRange? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 6, t.prefix(6).lowercased() == "bytes=" else { return nil }
        return parseByteRange(String(t.dropFirst(6)))
    }

    /// `bytes a-b/total` or `bytes a-b/*` (`parseContentRange`); rejects `total <= end`.
    static func parseContentRange(_ value: String?) -> BTRContentRange? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 5, t.prefix(5).lowercased() == "bytes" else { return nil }
        var rest = Substring(t.dropFirst(5))
        let afterSpace = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard afterSpace.count < rest.count else { return nil } // `\s+`
        rest = afterSpace
        guard let dash = rest.firstIndex(of: "-"), let slash = rest.firstIndex(of: "/"), dash < slash else { return nil }
        guard let start = parseDigits(rest[rest.startIndex..<dash]),
              let end = parseDigits(rest[rest.index(after: dash)..<slash]), end >= start else { return nil }
        let totalText = rest[rest.index(after: slash)...]
        if totalText == "*" { return BTRContentRange(start: start, end: end, total: nil) }
        guard let total = parseDigits(totalText), total > end else { return nil }
        return BTRContentRange(start: start, end: end, total: total)
    }

    /// The player's `Range` header against a known file size (lemon `parseRange`): absent → whole file; `a-`, `a-b`
    /// (clamped to the end) and suffix `-n`; multi-range and unsatisfiable ranges → nil (answer 416).
    static func parseClientRange(_ value: String?, total: Int64) -> ByteRange? {
        guard total > 0 else { return nil }
        guard let value else { return ByteRange(start: 0, end: total - 1) }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6, t.prefix(6).lowercased() == "bytes=" else { return nil }
        let spec = t.dropFirst(6)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let a = parts[0], b = parts[1]
        if a.isEmpty && b.isEmpty { return nil }
        let start: Int64, end: Int64
        if a.isEmpty {
            guard let suffix = parseDigits(b), suffix > 0 else { return nil }
            start = max(0, total - suffix)
            end = total - 1
        } else {
            guard let s = parseDigits(a) else { return nil }
            start = s
            if b.isEmpty { end = total - 1 } else {
                guard let e = parseDigits(b) else { return nil }
                end = min(e, total - 1)
            }
        }
        guard start < total, end >= start else { return nil }
        return ByteRange(start: start, end: end)
    }

    /// Equal pieces, remainder spread over the first ones; at most `min(512, concurrency)` pieces of at least
    /// `max(32 KiB, minChunkBytes)` (`splitRange`).
    static func splitRange(start: Int64, end: Int64, concurrency: Int, minChunkBytes: Int = 128 * 1024) -> [BTRPiece] {
        guard end >= start else { return [] }
        let length = end - start + 1
        let limit = Int64(max(1, min(BTRConstants.maxSplitPieces, concurrency)))
        let minimum = Int64(max(32 * 1024, minChunkBytes > 0 ? minChunkBytes : 128 * 1024))
        let count = max(1, min(limit, (length + minimum - 1) / minimum))
        let base = length / count, remainder = length % count
        var pieces: [BTRPiece] = []
        pieces.reserveCapacity(Int(count))
        var cursor = start
        for index in 0..<count {
            let size = base + (index < remainder ? 1 : 0)
            pieces.append(BTRPiece(index: Int(index), start: cursor, end: cursor + size - 1))
            cursor += size
        }
        return pieces
    }
}

// MARK: - Errors

/// Failures of the BTR downloader. `status` feeds the ban list (4xx = a refused address).
enum BTRError: Error, Equatable, CustomStringConvertible {
    /// Not a 206, or a Content-Range that does not match the request exactly ("Range 校验失败：HTTP x").
    case rangeRejected(status: Int)
    /// The node reports another file size than the track's ("绝不混拼").
    case inconsistentTotal(expected: Int64, got: Int64)
    /// Body shorter than the verified Content-Range ("子块长度不符").
    case lengthMismatch(received: Int, expected: Int)
    /// Body longer than the verified Content-Range.
    case oversized
    /// "CDN 首字节超时"
    case firstByteTimeout
    /// "CDN 子块停止传输"
    case stallTimeout
    /// "CDN 子块总耗时超限"
    case attemptTimeout
    /// Network / protocol failure of the HTTP client.
    case transport(String)
    /// "没有可用 CDN"
    case noCandidates
    /// "不同 CDN 返回的文件总长度不一致"
    case totalsDiffer
    /// The track handle was not made by this downloader.
    case foreignTrack

    /// HTTP status for the ban list: the refused status, 206 for a mismatching total, else 0.
    var status: Int {
        switch self {
        case .rangeRejected(let s): return s
        case .inconsistentTotal: return 206
        default: return 0
        }
    }

    var isTimeout: Bool {
        switch self {
        case .firstByteTimeout, .stallTimeout, .attemptTimeout: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .rangeRejected(let s): return "Range 校验失败：HTTP \(s)"
        case let .inconsistentTotal(e, g): return "CDN 文件总长度不一致：\(g)/\(e)"
        case let .lengthMismatch(r, e): return "子块长度不符：\(r)/\(e)"
        case .oversized: return "子块超出目标长度"
        case .firstByteTimeout: return "CDN 首字节超时"
        case .stallTimeout: return "CDN 子块停止传输"
        case .attemptTimeout: return "CDN 子块总耗时超限"
        case .transport(let m): return "CDN 连接失败：\(m)"
        case .noCandidates: return "没有可用 CDN"
        case .totalsDiffer: return "不同 CDN 返回的文件总长度不一致"
        case .foreignTrack: return "未知的媒体轨道"
        }
    }
}

extension Error {
    /// Task cancellation or a cancelled HTTP request (BTR "AbortError"): never a CDN failure.
    var btrIsCancellation: Bool {
        if self is CancellationError { return true }
        if let e = self as? MediaFetchError, e == .cancelled { return true }
        return false
    }

    var btrStatus: Int { (self as? BTRError)?.status ?? 0 }
    var btrIsTimeout: Bool { (self as? BTRError)?.isTimeout ?? false }
}

// MARK: - Small helpers

extension Array where Element: Hashable {
    /// Keeps the first occurrence of each element, in order.
    func btrDeduped() -> [Element] {
        var seen = Set<Element>()
        var out: [Element] = []
        out.reserveCapacity(count)
        for e in self where seen.insert(e).inserted { out.append(e) }
        return out
    }
}

extension Array {
    /// Stable sort (JS `Array.prototype.sort` is stable; Swift's `sort` is not documented to be).
    func btrStableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// Real-time sleep that throws `CancellationError` when the task is cancelled.
func btrSleep(ms: Double) async throws {
    guard ms > 0 else {
        try Task.checkCancellation()
        return
    }
    try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
}
