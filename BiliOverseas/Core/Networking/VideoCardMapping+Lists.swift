import Foundation

/// Shared JSON → `VideoCard` helpers for the list APIs (feed, search, history, favorites,
/// watch later, space, dynamics, bangumi, live). Pure functions so the parsers stay testable.
enum ListMapping {
    /// App key/secret PiliPlus signs its `app.bilibili.com` and `api.live.bilibili.com/xlive/app-interface`
    /// requests with (`mobi_app=android`, build 8430300).
    static let appKey = AppKey(key: "dfca71928277209b", secret: "b5475a8825547a4fc26c7d518eaaa02e")
    static let appBuild = 8430300
    static let appVersion = "8.43.0"
    static let appStatistics = #"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#
    static let appUserAgent =
        "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2"

    /// Common query items of the Android app endpoints.
    static func appParams() -> [String: Any] {
        [
            "build": appBuild, "version": appVersion, "c_locale": "zh_CN", "s_locale": "zh_CN",
            "channel": "master", "mobi_app": "android", "platform": "android", "statistics": appStatistics,
        ]
    }

    /// Headers of the Android app endpoints. No cookies are added here (the cookie jar still
    /// applies for *.bilibili.com hosts).
    static func appHeaders(appKeyHeader: String = "android") -> [String: String] {
        var h: [String: String] = [
            "User-Agent": appUserAgent,
            "env": "prod",
            "app-key": appKeyHeader,
            "bili-http-engine": "cronet",
            "x-bili-trace-id": "11111111111111111111111111111111:1111111111111111:0:0",
            "fp_local": String(repeating: "1", count: 64),
            "fp_remote": String(repeating: "1", count: 64),
            "session_id": "11111111",
        ]
        if let buvid = BiliHTTP.shared.cookie(named: "buvid3") { h["buvid"] = buvid }
        return h
    }

    // MARK: - Values

    /// `"mm:ss"`, `"h:mm:ss"` (also full-width `：`), or plain seconds (int or numeric string).
    static func duration(_ j: JSON) -> Int {
        switch j {
        case .int, .double: return max(0, j.intValue)
        case .string(let raw):
            let s = raw.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return 0 }
            return max(0, Fmt.parseDuration(s))
        default: return 0
        }
    }

    /// Counts sent as ints or as strings such as `"12.3万"`, `"1.2亿"`, `"3千"`, `"1,234"`, `"-"`.
    static func count(_ j: JSON) -> Int64 {
        switch j {
        case .int(let i): return max(0, i)
        case .double(let d): return clampedCount(d)
        case .string(let s): return parseCount(s)
        case .bool: return 0
        default: return 0
        }
    }

    /// Regex `([\d.]+)([千万亿])?` with multipliers 千=1e3, 万=1e4, 亿=1e8; no digits → 0.
    static func parseCount(_ s: String) -> Int64 {
        let t = s.replacingOccurrences(of: ",", with: "")
        guard let r = t.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
              let v = Double(String(t[r])) else { return 0 }
        let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
        var mul = 1.0
        if rest.hasPrefix("千") { mul = 1e3 } else if rest.hasPrefix("万") { mul = 1e4 } else if rest.hasPrefix("亿") { mul = 1e8 }
        return clampedCount((v * mul).rounded())
    }

    /// `Int64(_: Double)` traps outside ±2^63 (and on NaN); server data must never crash the app.
    static func clampedCount(_ d: Double) -> Int64 {
        guard d.isFinite, d > 0 else { return 0 }
        return d >= Double(Int64.max) ? Int64.max : Int64(d)
    }

    /// Image URL normalised to https.
    static func image(_ j: JSON) -> String {
        j.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).biliHTTPS
    }

    /// Strips HTML tags (search `<em class="keyword">` highlights) and decodes HTML entities.
    static func plainText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var s = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        guard s.contains("&") else { return s }
        s = decodeNumericEntities(s)
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func decodeNumericEntities(_ input: String) -> String {
        var s = input
        var searchStart = s.startIndex
        while let r = s.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression, range: searchStart..<s.endIndex) {
            var body = s[r].dropFirst(2).dropLast()
            var radix = 10
            if body.first == "x" || body.first == "X" { radix = 16; body = body.dropFirst() }
            if let code = UInt32(String(body), radix: radix), let scalar = Unicode.Scalar(code) {
                let replacement = String(Character(scalar))
                let lower = s.distance(from: s.startIndex, to: r.lowerBound)
                s.replaceSubrange(r, with: replacement)
                searchStart = s.index(s.startIndex, offsetBy: lower + replacement.count)
            } else {
                searchStart = r.upperBound
            }
        }
        return s
    }

    /// First capture group of `pattern` in `text`.
    /// One query value of an app `uri` (`bilibili://…?a=b&c=d`). iOS 16's URLComponents rejects some of these
    /// strings (it was relaxed in iOS 17), so a plain match is the fallback.
    static func uriQueryValue(_ name: String, in uri: String) -> String? {
        if let items = URLComponents(string: uri)?.queryItems {
            return items.first { $0.name == name }?.value
        }
        return firstCapture("[?&]" + NSRegularExpression.escapedPattern(for: name) + "=([^&#]*)", in: uri)
            .map { $0.removingPercentEncoding ?? $0 }
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    /// `…/bangumi/play/ep12345…` → 12345.
    static func epId(inURL url: String) -> Int64 {
        firstCapture(#"(?:^|[^A-Za-z])ep(\d+)"#, in: url).flatMap { Int64($0) } ?? 0
    }

    /// `…/bangumi/play/ss678…` → 678.
    static func seasonId(inURL url: String) -> Int64 {
        firstCapture(#"(?:^|[^A-Za-z])ss(\d+)"#, in: url).flatMap { Int64($0) } ?? 0
    }

    /// `BV…` id inside a URL.
    static func bvid(inURL url: String) -> String {
        firstCapture(#"(BV[0-9A-Za-z]{10})"#, in: url) ?? ""
    }

    /// Non-empty object / array / string → it carries a payload.
    static func hasPayload(_ j: JSON) -> Bool {
        switch j {
        case .object(let d): return !d.isEmpty
        case .array(let a): return !a.isEmpty
        case .string(let s): return !s.isEmpty
        default: return false
        }
    }

    // MARK: - Cards

    /// Fills `aid`/`bvid` (deriving one from the other) and returns the card id (bvid, else `av<aid>`).
    static func applyIDs(_ c: inout VideoCard, aid: Int64, bvid: String) {
        var a = aid
        var b = bvid
        if b.isEmpty, a > 0 { b = BVConverter.av2bv(a) }
        if a == 0, !b.isEmpty { a = BVConverter.bv2av(b) ?? 0 }
        c.aid = a
        c.bvid = b
        c.id = !b.isEmpty ? b : (a != 0 ? "av\(a)" : c.id)
    }

    static func applyOwner(_ c: inout VideoCard, _ owner: JSON) {
        c.ownerMid = owner["mid"].int64Value
        c.ownerName = owner["name"].stringValue
        c.ownerFace = image(owner["face"])
    }

    /// HotVideoItem badge: 充电专属 / 合作 / pgc_label.
    static func hotBadge(_ j: JSON) -> String {
        if j["charging_pay"]["level"].exists { return "充电专属" }
        if j["rights"]["is_cooperation"].intValue == 1 { return "合作" }
        return j["pgc_label"].stringValue
    }

    /// HotVideoItem mapping, shared by popular / ranking / weekly / precious / related / watch later.
    static func hotVideo(_ j: JSON) -> VideoCard? {
        var c = VideoCard(id: "")
        applyIDs(&c, aid: j["aid"].int64Value, bvid: j["bvid"].stringValue)
        guard !c.id.isEmpty else { return nil }
        c.cid = j["cid"].int64Value
        c.title = j["title"].stringValue
        c.cover = image(j["pic"])
        c.duration = duration(j["duration"])
        c.pubdate = j["pubdate"].int64 ?? j["ctime"].int64Value
        c.desc = j["desc"].stringValue
        applyOwner(&c, j["owner"])
        c.viewCount = count(j["stat"]["view"])
        c.likeCount = count(j["stat"]["like"])
        c.danmakuCount = count(j["stat"]["danmaku"])
        let reason = j["rcmd_reason"]
        c.reason = reason.object != nil ? reason["content"].stringValue : reason.stringValue
        c.badge = hotBadge(j)
        c.pageCount = j["videos"].intValue
        c.zone = j["tname"].stringValue
        let redirect = j["redirect_url"].stringValue
        if !redirect.isEmpty {
            c.uri = redirect
            let ep = epId(inURL: redirect)
            if ep != 0 {
                c.kind = .bangumi
                c.epId = ep
            }
        } else if !c.bvid.isEmpty {
            c.uri = "https://www.bilibili.com/video/\(c.bvid)"
        }
        return c
    }

    /// A PGC (bangumi / film) card keyed by season or episode.
    static func pgcCard(seasonId: Int64, epId: Int64, title: String, cover: String) -> VideoCard {
        var c = VideoCard(id: epId != 0 ? "ep\(epId)" : "ss\(seasonId)")
        c.kind = .bangumi
        c.seasonId = seasonId
        c.epId = epId
        c.title = title
        c.cover = cover
        return c
    }

    /// Runs an async throwing operation and captures its outcome (for `async let` fan-out).
    static func capture<T>(_ op: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if case BiliError.cancelled = error { return true }
        return error is CancellationError
    }
}

/// Helpers for page-number pagination behind the opaque `Page.next` cursor.
///
///     PagedListModel { cursor in try await FeedAPI.popular(page: ListCursor.page(cursor)) }
enum ListCursor {
    /// Page number encoded in a cursor (nil / garbage → 1).
    static func page(_ cursor: String?) -> Int {
        guard let cursor, let n = Int(cursor), n > 0 else { return 1 }
        return n
    }

    static func next(page: Int, hasMore: Bool) -> String? {
        hasMore ? String(page + 1) : nil
    }
}
