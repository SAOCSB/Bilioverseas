import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Web QR poll result (api-auth §7.2).
enum QRLoginState: Equatable {
    /// 86101: 未扫码.
    case waitingScan
    /// 86090: 已扫码，等待手机确认.
    case scannedWaitingConfirm
    /// 86038: 二维码已失效.
    case expired
    /// 0: the response already stored SESSDATA/bili_jct via Set-Cookie. `refreshToken` is the web
    /// `ac_time_value`; `crossDomainURL` carries the same cookies in its query.
    case success(refreshToken: String, crossDomainURL: String)
}

/// TV QR poll result (api-auth §7.1).
enum TVQRLoginState {
    case waitingScan
    case scannedWaitingConfirm
    case expired
    case success(TVLoginResult)
}

/// Successful TV QR login payload.
struct TVLoginResult {
    var mid: Int64
    /// App `access_key`, minted for `AppKey.tv`.
    var accessToken: String
    var refreshToken: String
    /// Seconds.
    var expiresIn: Int64
    /// `cookie_info.cookies`, normalized to domain `.bilibili.com`, path `/`.
    var cookies: [HTTPCookie]

    /// `data` of a successful poll.
    init?(data d: JSON, now: Date = Date()) {
        let token = d["access_token"].string ?? d[path: "token_info.access_token"].stringValue
        guard !token.isEmpty else { return nil }
        accessToken = token
        refreshToken = d["refresh_token"].string ?? d[path: "token_info.refresh_token"].stringValue
        mid = d["mid"].int64 ?? d[path: "token_info.mid"].int64Value
        expiresIn = d["expires_in"].int64 ?? d[path: "token_info.expires_in"].int64Value
        var out: [HTTPCookie] = []
        for c in d[path: "cookie_info.cookies"].arrayValue {
            let name = c["name"].stringValue, value = c["value"].stringValue
            guard !name.isEmpty, !value.isEmpty else { continue }
            let exp = c["expires"].int64Value
            let expires = exp > Int64(now.timeIntervalSince1970) ? Date(timeIntervalSince1970: TimeInterval(exp)) : nil
            if let cookie = LoginAPI.makeCookie(name: name, value: value, expires: expires,
                                                secure: c["secure"].intValue == 1,
                                                httpOnly: c["http_only"].intValue == 1, now: now) {
                out.append(cookie)
            }
        }
        cookies = out
        if mid == 0, let dede = out.first(where: { $0.name == "DedeUserID" }) { mid = Int64(dede.value) ?? 0 }
    }
}

/// Passport endpoints: web QR, TV QR, cookie refresh, logout. Session state lives in `AuthService`.
enum LoginAPI {
    static let webQRSource = "main-fe-header"
    /// TV passport host first (what bilibili-api uses), then the main passport host.
    static let tvPassportHosts = ["https://passport.snm0516.aisee.tv", BiliHost.passport]
    /// Cookies that make up a login (cleared on logout / account switch).
    static let sessionCookieNames: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
    /// SESSDATA lives ~6 months; used when the server gives no expiry.
    static let defaultSessionLifetime: TimeInterval = 180 * 24 * 3600

    // MARK: - Web QR (§7.2)

    static func generateWebQR() async throws -> (url: String, key: String) {
        let data = try await BiliHTTP.shared.api(BiliHost.passport + "/x/passport-login/web/qrcode/generate",
                                                 query: ["source": webQRSource], timeout: 10)
        let url = data["url"].stringValue, key = data["qrcode_key"].stringValue
        guard !url.isEmpty, !key.isEmpty else { throw BiliError.emptyData }
        return (url, key)
    }

    static func pollWebQR(key: String) async throws -> QRLoginState {
        let root = try await BiliHTTP.shared.json(BiliHost.passport + "/x/passport-login/web/qrcode/poll",
                                                  query: ["qrcode_key": key, "source": webQRSource], timeout: 10)
        return try parseWebQRPoll(root)
    }

    /// Status is in `data.code`; the top-level `code` is 0 unless the request itself failed.
    static func parseWebQRPoll(_ root: JSON) throws -> QRLoginState {
        let data = try BiliHTTP.unwrap(root)
        let code = data["code"].int ?? -1
        switch code {
        case 0:
            return .success(refreshToken: data["refresh_token"].stringValue, crossDomainURL: data["url"].stringValue)
        case 86101: return .waitingScan
        case 86090: return .scannedWaitingConfirm
        case 86038: return .expired
        default:
            throw BiliError.api(code: code, message: data["message"].string ?? root["message"].stringValue)
        }
    }

    /// Cookies carried in the success `data.url` query
    /// (`…/crossDomain?DedeUserID=…&DedeUserID__ckMd5=…&Expires=…&SESSDATA=…&bili_jct=…&gourl=…`).
    /// Values are kept percent-encoded exactly as sent (SESSDATA contains `%2C`, which is how the
    /// server's own Set-Cookie stores it).
    static func cookies(fromCrossDomainURL url: String, now: Date = Date()) -> [HTTPCookie] {
        guard let q = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: q)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        var pairs: [(String, String)] = []
        var expires: Date?
        for item in query.split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let name = String(kv[0]), value = String(kv[1])
            if name == "Expires", let t = TimeInterval(value), t > now.timeIntervalSince1970 {
                expires = Date(timeIntervalSince1970: t)
            } else if sessionCookieNames.contains(name), !value.isEmpty {
                pairs.append((name, value))
            }
        }
        return pairs.compactMap { name, value in
            makeCookie(name: name, value: value, expires: expires, secure: name == "SESSDATA",
                       httpOnly: name == "SESSDATA", now: now)
        }
    }

    // MARK: - TV QR (§7.1)

    static func generateTVQR() async throws -> (url: String, authCode: String) {
        let root = try await tvRequest("/x/passport-tv-login/qrcode/auth_code", form: ["local_id": "0"])
        let data = try BiliHTTP.unwrap(root)
        let url = data["url"].stringValue, code = data["auth_code"].stringValue
        guard !url.isEmpty, !code.isEmpty else { throw BiliError.emptyData }
        return (url, code)
    }

    static func pollTVQR(authCode: String) async throws -> TVQRLoginState {
        let root = try await tvRequest("/x/passport-tv-login/qrcode/poll", form: ["auth_code": authCode, "local_id": "0"])
        return try parseTVQRPoll(root)
    }

    /// TV poll status is the top-level `code`.
    static func parseTVQRPoll(_ root: JSON, now: Date = Date()) throws -> TVQRLoginState {
        let code = root["code"].int ?? -1
        switch code {
        case 0:
            guard let r = TVLoginResult(data: root["data"], now: now) else { throw BiliError.emptyData }
            return .success(r)
        case 86039: return .waitingScan
        case 86090: return .scannedWaitingConfirm
        case 86038: return .expired
        default:
            throw BiliError.api(code: code, message: root["message"].string ?? root["msg"].stringValue)
        }
    }

    /// App-signed (`AppKey.tv`) form POST, trying the next host only on transport-level failures.
    private static func tvRequest(_ path: String, form: [String: Any]) async throws -> JSON {
        var lastError: Error = BiliError.other("网络错误")
        for host in tvPassportHosts {
            do {
                return try await BiliHTTP.shared.json(host + path, method: "POST", form: form, sign: .app(.tv), timeout: 10)
            } catch BiliError.cancelled {
                throw BiliError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Cookie paste (§7.7)

    /// Parses `SESSDATA=…; bili_jct=…; DedeUserID=…` (an optional `Cookie:` prefix, newlines and
    /// DevTools' tab-separated rows are accepted). Later duplicates win; order is preserved.
    static func parseCookieString(_ raw: String) -> [(name: String, value: String)] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") { s = String(s.dropFirst(7)) }
        var out: [(name: String, value: String)] = []
        func add(_ name: String, _ value: String) {
            var v = value.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !v.isEmpty, !n.contains(" "), !n.contains("\t") else { return }
            out.removeAll { $0.name == n }
            out.append((n, v))
        }
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = String(line)
            if !l.contains("="), l.contains("\t") {
                let cols = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if cols.count >= 2 { add(cols[0], cols[1]) }
                continue
            }
            for part in l.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { add(String(kv[0]), String(kv[1])) }
            }
        }
        return out
    }

    /// A `.bilibili.com` `/` cookie. `expires == nil` → `now + defaultSessionLifetime`.
    static func makeCookie(name: String, value: String, expires: Date? = nil, secure: Bool = false,
                           httpOnly: Bool = false, now: Date = Date()) -> HTTPCookie? {
        StoredCookie(name: name, value: value, domain: ".bilibili.com", path: "/",
                     expires: (expires ?? now.addingTimeInterval(defaultSessionLifetime)).timeIntervalSince1970,
                     secure: secure, httpOnly: httpOnly).httpCookie
    }

    // MARK: - Web cookie refresh (§8)

    static let correspondPublicKeyPKCS1Base64 =
        "MIGJAoGBAMuB3Y4CRwZW2gTdOFRERuKjQSBRz+mtxqMwpe+QIoUJaElglwuRwzYMopxJ4WkP+PoGjLnfxhedHpWFy5Qk6EfbHvWfM+N91NyozPt2Me6bSpJkDQDIIEMAFSoKt82AKInTRFrsaZGP5gIrU0kS57CVvjQk2tG6gRRelptTMYHxAgMBAAE="

    /// `GET passport/x/passport-login/web/cookie/info` → (`data.refresh`, `data.timestamp` ms).
    static func checkCookieRefresh() async throws -> (needsRefresh: Bool, timestamp: Int64) {
        guard let csrf = BiliHTTP.shared.csrf else { throw BiliError.notLoggedIn }
        let data = try await BiliHTTP.shared.api(BiliHost.passport + "/x/passport-login/web/cookie/info",
                                                 query: ["csrf": csrf], timeout: 10)
        return (data["refresh"].boolValue, data["timestamp"].int64Value)
    }

    /// RSA-OAEP(SHA-256) of `"refresh_<ms>"` with the fixed public key, lowercase hex (256 chars).
    static func correspondPath(timestampMs: Int64) throws -> String {
        #if canImport(Security)
        guard let der = Data(base64Encoded: correspondPublicKeyPKCS1Base64) else {
            throw BiliError.other("RSA 公钥无效")
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw BiliError.other("RSA 公钥无效")
        }
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else { throw BiliError.other("不支持 RSA-OAEP") }
        let message = Data("refresh_\(timestampMs)".utf8)
        guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, message as CFData, &error) as Data? else {
            throw BiliError.other("RSA 加密失败")
        }
        return encrypted.map { String(format: "%02x", $0) }.joined()
        #else
        throw BiliError.other("当前平台不支持 Cookie 刷新")
        #endif
    }

    /// `<div id="1-name">refresh_csrf</div>` from the correspond page.
    static func extractRefreshCSRF(html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"<div\s+id\s*=\s*["']1-name["'][^>]*>\s*(.+?)\s*</div>"#,
                                                options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        let v = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Full §8 flow. Returns the new `ac_time_value`, or `nil` when the server says no refresh is
    /// needed. New cookies arrive via Set-Cookie into `BiliHTTP.shared.cookieStorage`.
    static func refreshWebCookies(refreshToken: String) async throws -> String? {
        let http = BiliHTTP.shared
        guard let oldCSRF = http.csrf else { throw BiliError.notLoggedIn }
        let check = try await checkCookieRefresh()
        guard check.needsRefresh else { return nil }
        let ts = check.timestamp > 0 ? check.timestamp : Int64(Date().timeIntervalSince1970 * 1000)
        let path = try correspondPath(timestampMs: ts)
        let (html, _) = try await http.data(BiliHost.www + "/correspond/1/" + path,
                                            headers: ["Accept": "text/html,application/xhtml+xml"], timeout: 10)
        guard let page = String(data: html, encoding: .utf8), let refreshCSRF = extractRefreshCSRF(html: page) else {
            throw BiliError.other("获取 refresh_csrf 失败")
        }
        let data = try await http.api(BiliHost.passport + "/x/passport-login/web/cookie/refresh", method: "POST",
                                      form: ["csrf": oldCSRF, "refresh_csrf": refreshCSRF,
                                             "source": "main_web", "refresh_token": refreshToken],
                                      timeout: 10)
        let newToken = data["refresh_token"].stringValue
        guard !newToken.isEmpty else { throw BiliError.emptyData }
        // Invalidate the old session with the NEW csrf and the OLD refresh token.
        if let newCSRF = http.csrf {
            _ = try? await http.api(BiliHost.passport + "/x/passport-login/web/confirm/refresh", method: "POST",
                                    form: ["csrf": newCSRF, "refresh_token": refreshToken], timeout: 10)
        }
        return newToken
    }

    // MARK: - Logout (§10.3)

    static func logout() async throws {
        guard let csrf = BiliHTTP.shared.csrf else { throw BiliError.notLoggedIn }
        _ = try await BiliHTTP.shared.api(BiliHost.passport + "/login/exit/v2", method: "POST",
                                          form: ["biliCSRF": csrf], timeout: 8)
    }
}
