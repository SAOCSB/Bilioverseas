import Foundation

/// Well-known Bilibili hosts.
enum BiliHost {
    static let api = "https://api.bilibili.com"
    static let app = "https://app.bilibili.com"
    static let passport = "https://passport.bilibili.com"
    static let live = "https://api.live.bilibili.com"
    static let www = "https://www.bilibili.com"
    static let search = "https://s.search.bilibili.com"
    static let comment = "https://comment.bilibili.com"
    static let message = "https://api.vc.bilibili.com"
}

enum BiliError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int)
    case api(code: Int, message: String)
    case decoding(String)
    case notLoggedIn
    case emptyData
    case cancelled
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效的地址：\(u)"
        case .http(let s): return "网络错误（HTTP \(s)）"
        case .api(let code, let msg):
            if code == -101 { return "账号未登录" }
            if code == -352 || code == -412 { return "请求被风控拦截（\(code)），请稍后再试" }
            return msg.isEmpty ? "请求失败（\(code)）" : "\(msg)（\(code)）"
        case .decoding(let m): return "数据解析失败：\(m)"
        case .notLoggedIn: return "请先登录"
        case .emptyData: return "没有数据"
        case .cancelled: return "已取消"
        case .other(let m): return m
        }
    }

    var apiCode: Int? { if case .api(let c, _) = self { return c }; return nil }
}

/// How a request's query is signed.
enum SignMode {
    case none
    /// Web "WBI" signature (adds `wts` and `w_rid`).
    case wbi
    /// App signature (adds `appkey`, `ts` and `sign`).
    case app(AppKey)
}

struct AppKey: Equatable {
    let key: String
    let secret: String
    /// Android "pink" client key.
    static let android = AppKey(key: "1d8b6e7d45233436", secret: "560c52ccd288fed045859ed18bffd973")
    /// TV / "云视听小电视" key, used for TV QR login.
    static let tv = AppKey(key: "4409e2ce8ffd12b8", secret: "59b43e04ad6965f34319062b478f83dd")
}

/// Shared HTTP client for every Bilibili request.
///
/// Cookies (SESSDATA, bili_jct, buvid3 …) live in `cookieStorage`, which `AuthService`
/// persists. All query strings are encoded like JavaScript's `encodeURIComponent`.
final class BiliHTTP: @unchecked Sendable {
    static let shared = BiliHTTP()

    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    let cookieStorage: HTTPCookieStorage
    let session: URLSession
    let wbi = WbiSigner()

    init(cookieStorage: HTTPCookieStorage = .shared) {
        self.cookieStorage = cookieStorage
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = cookieStorage
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    // MARK: Cookies

    func cookie(named name: String) -> String? {
        let cookies = cookieStorage.cookies(for: URL(string: BiliHost.api)!) ?? cookieStorage.cookies ?? []
        return cookies.first { $0.name == name && !$0.value.isEmpty }?.value
    }

    /// `bili_jct`, required as `csrf` for every write API.
    var csrf: String? { cookie(named: "bili_jct") }
    var isLoggedIn: Bool { cookie(named: "SESSDATA") != nil }
    var mid: Int64? { cookie(named: "DedeUserID").flatMap { Int64($0) } }

    func setCookie(name: String, value: String, domain: String = ".bilibili.com", expires: Date? = nil) {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/",
        ]
        props[.expires] = expires ?? Date().addingTimeInterval(365 * 24 * 3600)
        if let c = HTTPCookie(properties: props) { cookieStorage.setCookie(c) }
    }

    func removeCookies(domainSuffix: String = "bilibili.com") {
        for c in cookieStorage.cookies ?? [] where c.domain.hasSuffix(domainSuffix) {
            cookieStorage.deleteCookie(c)
        }
    }

    /// Cookie header for a URL (used by the media proxy which talks to CDNs itself).
    func cookieHeader(for url: URL) -> String? {
        let cookies = cookieStorage.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    // MARK: Requests

    /// Raw request. `form` turns the request into a `application/x-www-form-urlencoded` POST.
    func data(
        _ url: String,
        method: String? = nil,
        query: [String: Any] = [:],
        form: [String: Any]? = nil,
        sign: SignMode = .none,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> (Data, HTTPURLResponse) {
        var params = query.mapValues { BiliHTTP.stringify($0) }
        var bodyParams = form?.mapValues { BiliHTTP.stringify($0) }
        switch sign {
        case .none: break
        case .wbi: params = try await wbi.sign(params)
        case .app(let key):
            if bodyParams != nil { bodyParams = AppSigner.sign(bodyParams ?? [:], key: key) }
            else { params = AppSigner.sign(params, key: key) }
        }
        guard var comps = URLComponents(string: url) else { throw BiliError.invalidURL(url) }
        if !params.isEmpty {
            let existing = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
            comps.percentEncodedQuery = existing + BiliHTTP.encodeQuery(params, sorted: true)
        }
        guard let finalURL = comps.url else { throw BiliError.invalidURL(url) }
        var req = URLRequest(url: finalURL, timeoutInterval: timeout)
        req.httpMethod = method ?? (bodyParams == nil ? "GET" : "POST")
        req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let bodyParams {
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(BiliHTTP.encodeQuery(bodyParams, sorted: false).utf8)
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw BiliError.other("非 HTTP 响应") }
            guard (200..<300).contains(http.statusCode) else { throw BiliError.http(status: http.statusCode) }
            return (data, http)
        } catch let e as URLError where e.code == .cancelled {
            throw BiliError.cancelled
        } catch is CancellationError {
            throw BiliError.cancelled
        }
    }

    /// Returns the whole response root as JSON without checking `code`.
    func json(
        _ url: String,
        method: String? = nil,
        query: [String: Any] = [:],
        form: [String: Any]? = nil,
        sign: SignMode = .none,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> JSON {
        let (data, _) = try await self.data(url, method: method, query: query, form: form, sign: sign,
                                            headers: headers, timeout: timeout)
        do { return try JSON(data: data) } catch {
            throw BiliError.decoding(String(data: data.prefix(200), encoding: .utf8) ?? "non-utf8")
        }
    }

    /// Standard Bilibili envelope `{code, message, data | result}`: throws `BiliError.api` when
    /// `code != 0`, returns `data` (or `result` for PGC endpoints). WBI requests rejected with
    /// -352/-403 are retried once with refreshed keys.
    func api(
        _ url: String,
        method: String? = nil,
        query: [String: Any] = [:],
        form: [String: Any]? = nil,
        sign: SignMode = .none,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> JSON {
        var root = try await json(url, method: method, query: query, form: form, sign: sign, headers: headers, timeout: timeout)
        if case .wbi = sign, [-352, -403].contains(root["code"].intValue) {
            await wbi.invalidate()
            root = try await json(url, method: method, query: query, form: form, sign: sign, headers: headers, timeout: timeout)
        }
        return try BiliHTTP.unwrap(root)
    }

    static func unwrap(_ root: JSON) throws -> JSON {
        let code = root["code"].int ?? 0
        guard code == 0 else {
            let msg = root["message"].string ?? root["msg"].string ?? ""
            throw BiliError.api(code: code, message: msg)
        }
        if root["data"].exists { return root["data"] }
        if root["result"].exists { return root["result"] }
        return .null
    }

    /// Convenience for write APIs: injects `csrf` (bili_jct) into the form.
    func post(_ url: String, form: [String: Any], query: [String: Any] = [:], sign: SignMode = .none) async throws -> JSON {
        guard let csrf else { throw BiliError.notLoggedIn }
        var f = form
        f["csrf"] = csrf
        if f["csrf_token"] == nil { f["csrf_token"] = csrf }
        return try await api(url, method: "POST", query: query, form: f, sign: sign)
    }

    // MARK: Encoding

    static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "1" : "0"
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let d as Double: return d.rounded() == d ? String(Int64(d)) : String(d)
        case let a as [Any]: return a.map { stringify($0) }.joined(separator: ",")
        default: return String(describing: v)
        }
    }

    /// `encodeURIComponent` semantics: everything except `A-Z a-z 0-9 - _ . ! ~ * ' ( )` is escaped.
    static let uriComponentAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-_.!~*'()")
        return s
    }()

    /// RFC 3986 unreserved set — what WBI signing expects (`!'()*` are stripped before).
    static let unreservedAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-_.~")
        return s
    }()

    static func percentEncode(_ s: String, allowed: CharacterSet = unreservedAllowed) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func encodeQuery(_ params: [String: String], sorted: Bool) -> String {
        let keys = sorted ? params.keys.sorted() : Array(params.keys)
        return keys.map { "\(percentEncode($0))=\(percentEncode(params[$0] ?? ""))" }.joined(separator: "&")
    }
}
