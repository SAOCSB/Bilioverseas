import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Serializable copy of one `HTTPCookie`.
struct StoredCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    /// Unix seconds; `nil` = session cookie.
    var expires: Double?
    var secure: Bool
    var httpOnly: Bool

    init(name: String, value: String, domain: String = ".bilibili.com", path: String = "/",
         expires: Double? = nil, secure: Bool = false, httpOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }

    init(_ c: HTTPCookie) {
        self.init(name: c.name, value: c.value, domain: c.domain, path: c.path.isEmpty ? "/" : c.path,
                  expires: c.expiresDate?.timeIntervalSince1970, secure: c.isSecure, httpOnly: c.isHTTPOnly)
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expires else { return false }
        return expires <= now.timeIntervalSince1970
    }

    var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if let expires { props[.expires] = Date(timeIntervalSince1970: expires) }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}

/// Everything that makes up the signed-in session (api-auth §10.2).
struct StoredSession: Codable, Equatable {
    /// Every `*.bilibili.com` cookie (device cookies such as buvid3 included).
    var cookies: [StoredCookie] = []
    /// Web `ac_time_value` from web QR login, needed for cookie refresh (§8).
    var refreshToken: String?
    /// App `access_key` (TV QR login).
    var accessKey: String?
    /// The appkey that minted `accessKey`; app calls made with it must be signed with the same key.
    var accessKeyAppKey: String?
    /// Unix seconds.
    var accessKeyExpiresAt: Double?
    /// App/TV `refresh_token` (not usable for the web refresh flow).
    var appRefreshToken: String?
    /// Unix seconds of the last save.
    var savedAt: Double?
}

/// Saves / restores the session in the Keychain (generic password, service
/// `io.github.bilioverseas.session`, accessible after first unlock) as JSON.
/// Falls back to UserDefaults where Security is unavailable (Linux) or the Keychain rejects the
/// write (e.g. an unsigned simulator build without keychain entitlements).
/// Never logs cookie values.
enum CookiePersistence {
    static let service = "io.github.bilioverseas.session"
    static let account = "session"
    static let fallbackDefaultsKey = "io.github.bilioverseas.session.fallback"
    /// Keychain items survive an app deletion; this flag detects a fresh install so a reinstalled
    /// app does not silently come back logged in.
    static let installMarkerKey = "io.github.bilioverseas.session.installed"

    private static let lock = NSLock()

    // MARK: Store

    static func load(defaults: UserDefaults = .standard) -> StoredSession? {
        lock.lock(); defer { lock.unlock() }
        if !defaults.bool(forKey: installMarkerKey) {
            keychainDelete()
            defaults.removeObject(forKey: fallbackDefaultsKey)
            defaults.set(true, forKey: installMarkerKey)
            return nil
        }
        if let data = keychainRead(), let s = decode(data) { return s }
        if let data = defaults.data(forKey: fallbackDefaultsKey), let s = decode(data) { return s }
        return nil
    }

    @discardableResult
    static func save(_ session: StoredSession, defaults: UserDefaults = .standard) -> Bool {
        guard let data = encode(session) else { return false }
        lock.lock(); defer { lock.unlock() }
        defaults.set(true, forKey: installMarkerKey)
        if keychainWrite(data) {
            defaults.removeObject(forKey: fallbackDefaultsKey)
            return true
        }
        defaults.set(data, forKey: fallbackDefaultsKey)
        return true
    }

    static func clear(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        keychainDelete()
        defaults.removeObject(forKey: fallbackDefaultsKey)
    }

    static func encode(_ s: StoredSession) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(s)
    }

    static func decode(_ data: Data) -> StoredSession? {
        try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    // MARK: Cookie storage bridge

    /// Unexpired cookies of every `bilibili.com` domain in `storage`.
    static func snapshot(from storage: HTTPCookieStorage, now: Date = Date()) -> [StoredCookie] {
        (storage.cookies ?? [])
            .filter { isBiliDomain($0.domain) }
            .map(StoredCookie.init)
            .filter { !$0.isExpired(now: now) }
    }

    /// Puts unexpired cookies back into `storage`. Returns how many were restored.
    @discardableResult
    static func restore(_ cookies: [StoredCookie], into storage: HTTPCookieStorage, now: Date = Date()) -> Int {
        var n = 0
        for c in cookies where !c.isExpired(now: now) && isBiliDomain(c.domain) {
            if let hc = c.httpCookie { storage.setCookie(hc); n += 1 }
        }
        return n
    }

    static func isBiliDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d == "bilibili.com" || d.hasSuffix(".bilibili.com")
    }

    // MARK: Keychain

    #if canImport(Security)
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainRead() -> Data? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ data: Data) -> Bool {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            for (k, v) in attrs { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func keychainDelete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
    #else
    private static func keychainRead() -> Data? { nil }
    private static func keychainWrite(_ data: Data) -> Bool { false }
    private static func keychainDelete() {}
    #endif
}
