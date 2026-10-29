import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Bilibili links and ids the app opens itself: BV / av ids typed or pasted into search, share text from the
// official app (「【标题】 https://b23.tv/xxxx」), bilibili.com / b23.tv URLs and the app's own `bilioverseas://`
// URL scheme (Info.plist CFBundleURLTypes). Short links are expanded by reading their redirect (PiliPlus
// `UrlUtils.parseRedirectUrl`: HEAD, redirects not followed, no account cookies).

/// Where a Bilibili link points.
enum BiliLinkTarget: Hashable {
    case video(VideoRef)
    case user(mid: Int64)
    case live(roomId: Int64)
    case search(keyword: String)
    /// A b23.tv-style short link: `BiliLinkResolver.resolve` expands it first.
    case shortLink(URL)
    /// Another Bilibili page (opened in the in-app browser).
    case web(URL)
}

enum BiliLinkParser {
    /// The app's URL scheme, e.g. `bilioverseas://video/BV1GJ411x7h7`, `bilioverseas://open?url=<link>`.
    static let appScheme = "bilioverseas"
    static let shortLinkHosts: Set<String> = ["b23.tv", "bili2233.cn"]
    /// BV ids are base58 (no 0, I, O, l) after the fixed `BV1`.
    static let bvPattern = #"BV1[1-9A-HJ-NP-Za-km-z]{9}"#

    /// Typed or pasted text: an exact BV / av id, or the first Bilibili link inside it. nil = an ordinary keyword.
    static func parse(text: String) -> BiliLinkTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = exactID(trimmed) { return .video(id) }
        for candidate in linkCandidates(in: trimmed) {
            if let target = parse(url: candidate) { return target }
        }
        return nil
    }

    /// A URL: bilibili.com pages, short links, `bilibili://` and `bilioverseas://`. nil = not a Bilibili link.
    static func parse(url: URL) -> BiliLinkTarget? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == appScheme { return parse(appURL: url) }
        if scheme == "bilibili" { return parseOfficialScheme(url) }
        guard scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        if isShortLinkHost(host) { return url.path.count > 1 ? .shortLink(url) : nil }
        guard isBilibiliHost(host) else { return nil }
        let path = url.path
        let query = queryItems(of: url)
        if host == "space.bilibili.com", let mid = firstNumber(in: path) { return .user(mid: mid) }
        if host == "m.bilibili.com", path.hasPrefix("/space/"), let mid = firstNumber(in: path) { return .user(mid: mid) }
        if host == "live.bilibili.com", let room = firstNumber(in: path) { return .live(roomId: room) }
        if host == "search.bilibili.com", let keyword = query["keyword"], !keyword.isEmpty {
            return .search(keyword: keyword)
        }
        if let bvid = firstMatch(bvPattern, in: path) ?? query["bvid"].flatMap({ firstMatch("^" + bvPattern + "$", in: $0) }) {
            return .video(withStartTime(.bvid(bvid), query))
        }
        if let av = firstMatch(#"/video/av\d+"#, in: path), let aid = Int64(av.dropFirst("/video/av".count)), aid > 0 {
            return .video(withStartTime(.aid(aid), query))
        }
        if path.contains("/bangumi/play/"), let ids = VideoDetail.parsePGCLink(path) {
            return .video(VideoRef(epId: ids.epId, seasonId: ids.seasonId))
        }
        return .web(url)
    }

    static func isShortLinkHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return shortLinkHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func isBilibiliHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "bilibili.com" || h.hasSuffix(".bilibili.com")
    }

    // MARK: Pieces

    /// `BV1…` (any case for the prefix) or `av123`.
    static func exactID(_ text: String) -> VideoRef? {
        if text.range(of: "^(?i:bv)1[1-9A-HJ-NP-Za-km-z]{9}$", options: .regularExpression) != nil {
            return .bvid("BV" + text.dropFirst(2))
        }
        if text.range(of: #"^(?i:av)\d{1,19}$"#, options: .regularExpression) != nil,
           let aid = Int64(text.dropFirst(2)), aid > 0 {
            return .aid(aid)
        }
        return nil
    }

    /// Bilibili / short-link URLs inside free text, with or without `https://`, in order.
    static func linkCandidates(in text: String) -> [URL] {
        let pattern = #"(?i)(?<![a-z0-9.\-])(?:https?://)?(?:[a-z0-9-]+\.)*(?:bilibili\.com|b23\.tv|bili2233\.cn)(?![a-z0-9\-]|\.[a-z])(?:/[^\s<>"'，。！？、；：【】「」『』（）《》]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var raw = ns.substring(with: match.range)
            if raw.range(of: "^(?i)https?://", options: .regularExpression) == nil { raw = "https://" + raw }
            return URL(string: raw) ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap { URL(string: $0) }
        }
    }

    /// `bilioverseas://video/BV…`, `…/video/av…`, `…/BV…`, `…/space/<mid>`, `…/live/<room>`, `…/bangumi/ep…`,
    /// `…/search?keyword=…`, `…/open?url=<link>` (`t=` sets the start time of a video).
    static func parse(appURL url: URL) -> BiliLinkTarget? {
        let query = queryItems(of: url)
        if let link = query["url"], !link.isEmpty { return parse(text: link) }
        // Host and path come from the raw string: `URL.host` may change the case of a BV id.
        let raw = url.absoluteString
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        var rest = String(raw[schemeEnd.upperBound...])
        if let q = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<q]) }
        let parts = (rest.removingPercentEncoding ?? rest).split(separator: "/").map(String.init)
        guard let kind = parts.first else { return nil }
        let value = parts.count > 1 ? parts[1] : ""
        switch kind.lowercased() {
        case "video":
            if let ref = exactID(value) { return .video(withStartTime(ref, query)) }
            if let aid = Int64(value), aid > 0 { return .video(withStartTime(.aid(aid), query)) }
        case "space", "user":
            if let mid = Int64(value), mid > 0 { return .user(mid: mid) }
        case "live":
            if let room = Int64(value), room > 0 { return .live(roomId: room) }
        case "bangumi":
            if let ids = VideoDetail.parsePGCLink(parts.dropFirst().joined(separator: "/")) {
                return .video(VideoRef(epId: ids.epId, seasonId: ids.seasonId))
            }
        case "search":
            let keyword = query["keyword"] ?? value
            if !keyword.isEmpty { return .search(keyword: keyword) }
        default:
            if let ref = exactID(kind) { return .video(withStartTime(ref, query)) }
        }
        return nil
    }

    /// The official client's scheme: `bilibili://video/<aid|BV>`, `bilibili://space/<mid>`, `bilibili://live/<room>`.
    static func parseOfficialScheme(_ url: URL) -> BiliLinkTarget? {
        let raw = url.absoluteString
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        var rest = String(raw[schemeEnd.upperBound...])
        if let q = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<q]) }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0].lowercased() {
        case "video":
            if let ref = exactID(parts[1]) { return .video(ref) }
            if let aid = Int64(parts[1]), aid > 0 { return .video(.aid(aid)) }
        case "space", "author":
            if let mid = Int64(parts[1]), mid > 0 { return .user(mid: mid) }
        case "live":
            if let room = Int64(parts[1]), room > 0 { return .live(roomId: room) }
        default:
            break
        }
        return nil
    }

    private static func withStartTime(_ ref: VideoRef, _ query: [String: String]) -> VideoRef {
        var ref = ref
        if let t = query["t"].flatMap(Double.init), t.isFinite, t > 0 { ref.startTime = t }
        return ref
    }

    private static func queryItems(of url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where out[item.name] == nil {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    /// First run of digits right after a `/` (`/h5/123` → 123), PiliPlus `uriDigitRegExp`.
    private static func firstNumber(in path: String) -> Int64? {
        guard let match = firstMatch(#"/\d+"#, in: path), let value = Int64(match.dropFirst()), value > 0 else {
            return nil
        }
        return value
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
}

enum BiliLinkResolver {
    /// `BiliLinkParser.parse(text:)`, with a short link expanded and parsed again. A short link that cannot be
    /// expanded, or that points at a page the app has no screen for, opens in the in-app browser.
    static func resolve(text: String) async -> BiliLinkTarget? {
        guard let target = BiliLinkParser.parse(text: text) else { return nil }
        return await expanded(target)
    }

    /// Same for a URL handed to the app (`onOpenURL`).
    static func resolve(url: URL) async -> BiliLinkTarget? {
        guard let target = BiliLinkParser.parse(url: url) else { return nil }
        return await expanded(target)
    }

    private static func expanded(_ target: BiliLinkTarget) async -> BiliLinkTarget {
        guard case .shortLink(let short) = target else { return target }
        guard let long = try? await expand(short) else { return .web(short) }
        switch BiliLinkParser.parse(url: long) {
        case .some(.shortLink), .none: return .web(long)
        case .some(let parsed): return parsed
        }
    }

    /// Where a short link redirects to: one HEAD request without cookies; redirects inside the short-link
    /// domain are followed, the first one leaving it is read from `Location` instead of being loaded.
    static func expand(_ url: URL, timeout: TimeInterval = 8) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { _, response, error in
                if let response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let location = http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "location" }?.value as? String
        guard let target = redirectTarget(status: http.statusCode, location: location, finalURL: http.url,
                                          requested: url) else { throw URLError(.badServerResponse) }
        return target
    }

    /// The expanded URL from the response: a 3xx `Location` (relative to the request), or the URL the transfer
    /// ended at when it already left the short-link domain. Only http(s) targets count.
    static func redirectTarget(status: Int, location: String?, finalURL: URL?, requested: URL) -> URL? {
        var target: URL?
        if (300..<400).contains(status), let location, !location.isEmpty {
            target = URL(string: location, relativeTo: requested)?.absoluteURL
        } else if let finalURL, let host = finalURL.host, !BiliLinkParser.isShortLinkHost(host) {
            target = finalURL
        }
        guard let result = target, let scheme = result.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return result
    }

    private static let redirectGate = BiliLinkRedirectGate()

    /// Ephemeral (no cookies, no cache), so short-link lookups never carry the account.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: redirectGate, delegateQueue: nil)
    }()
}

/// Follows redirects only while they stay on a short-link host.
final class BiliLinkRedirectGate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let host = request.url?.host, BiliLinkParser.isShortLinkHost(host) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
