import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Account state for the whole app (contract §9).
///
/// * `isLoggedIn` / `profile` / `stat` are published on the main actor; observe them in SwiftUI
///   (`@ObservedObject var auth = AuthService.shared`, `auth.$isLoggedIn`) or listen for
///   `AuthService.loginStateDidChange`.
/// * Non-UI code should read the cookie-backed `BiliHTTP.shared.isLoggedIn / mid / csrf`, which are
///   thread-safe.
/// * Cookies live in `BiliHTTP.shared.cookieStorage`; this class mirrors them (plus tokens) into the
///   Keychain via `CookiePersistence`.
final class AuthService: ObservableObject, @unchecked Sendable {
    static let shared = AuthService()

    /// Posted on the main thread after login, logout, account switch or server-side session
    /// invalidation (object: the AuthService).
    static let loginStateDidChange = Notification.Name("AuthServiceLoginStateDidChange")

    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var profile: UserProfile?
    @Published private(set) var stat: UserStat?

    let http: BiliHTTP

    private let lock = NSLock()
    /// Tokens of the current session (its `cookies` field is unused; cookies come from storage).
    private var tokens = StoredSession()
    /// Bumped on every login / logout so late responses of an older session are dropped.
    private var generation = 0
    private var bootstrapTask: Task<Void, Never>?
    private var profileTask: (generation: Int, task: Task<Void, Never>)?
    private var activatedKeys: Set<String> = []
    private var persistPending = false
    private var observers: [NSObjectProtocol] = []
    private let persistQueue = DispatchQueue(label: "io.github.bilioverseas.auth.persist", qos: .utility)

    private static let profileCacheKey = "bili.auth.profileCache"
    private static let statCacheKey = "bili.auth.statCache"
    private static let lastRefreshCheckKey = "bili.auth.lastCookieRefreshCheck"
    /// Device cookies kept across logout.
    static let deviceCookieNames: Set<String> = ["buvid3", "buvid4", "b_nut", "_uuid", "buvid_fp", "b_lsid"]

    init(http: BiliHTTP = .shared) {
        self.http = http
        // Restoring is a single Keychain read, so the very first frame already knows the login state.
        if let stored = CookiePersistence.load() {
            CookiePersistence.restore(stored.cookies, into: http.cookieStorage)
            var t = stored
            t.cookies = []
            tokens = t
        }
        let loggedIn = http.isLoggedIn
        isLoggedIn = loggedIn
        profile = loggedIn ? AuthService.loadCached(UserProfile.self, key: AuthService.profileCacheKey) : nil
        stat = loggedIn ? AuthService.loadCached(UserStat.self, key: AuthService.statCacheKey) : nil
        observeChanges()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Public API

    /// Mid of the signed-in account, 0 when logged out.
    var mid: Int64 { profile?.mid ?? http.mid ?? 0 }

    /// App `access_key` (only after TV QR login).
    var accessKey: String? {
        locked {
            guard let k = tokens.accessKey, !k.isEmpty else { return nil }
            if let exp = tokens.accessKeyExpiresAt, exp < Date().timeIntervalSince1970 { return nil }
            return k
        }
    }

    /// The appkey `accessKey` was minted for. Sign app requests that carry it with this key.
    var accessKeyAppKey: AppKey? {
        guard accessKey != nil, let key = locked({ tokens.accessKeyAppKey }) else { return nil }
        switch key {
        case AppKey.tv.key: return .tv
        case AppKey.android.key: return .android
        default: return nil
        }
    }

    /// Whether a web `refresh_token` (ac_time_value) is stored, i.e. cookie refresh is possible.
    var canRefreshCookies: Bool { !(locked { tokens.refreshToken } ?? "").isEmpty }

    /// App start: restores the session, makes sure the web device cookies exist, activates them,
    /// refreshes bili_ticket, fetches nav (WBI keys + profile) and checks for cookie refresh at most
    /// daily. Never throws; returns after at most ~1.5 s while the rest continues in the background.
    func bootstrap() async {
        let task: Task<Void, Never> = locked {
            if let t = bootstrapTask { return t }
            let t = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runBootstrap()
            }
            bootstrapTask = t
            return t
        }
        await AuthService.wait(for: task, atMost: 1.5)
    }

    /// Re-fetches nav (+ nav/stat and the signature). A `-101` answer clears the stored session.
    func refreshProfile() async {
        let task: Task<Void, Never> = locked {
            if let p = profileTask, p.generation == generation { return p.task }
            let gen = generation
            let t = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loadProfile(generation: gen)
                self?.clearProfileTask(generation: gen)
            }
            profileTask = (gen, t)
            return t
        }
        await task.value
    }

    /// Server logout (`/login/exit/v2`, best effort), then clears the session locally. Device
    /// cookies (buvid3 …) are kept.
    func logout() async {
        if http.isLoggedIn {
            try? await LoginAPI.logout()
        }
        bumpGeneration()
        clearSessionLocally()
        await publishLoggedOut()
        Task.detached(priority: .utility) { [weak self] in
            await self?.ensureBiliTicket(force: true)
        }
    }

    /// Adds login cookies (normalized to `.bilibili.com`), persists them with the web refresh token
    /// and loads the profile. Cookies already set by the server (Set-Cookie) are kept.
    func applyLoginCookies(_ cookies: [HTTPCookie], refreshToken: String?) async {
        await applyLogin(cookies: cookies, replaceExisting: false) { t in
            t.refreshToken = refreshToken
        }
    }

    /// Web QR success: the poll response already stored the cookies via Set-Cookie; the
    /// cross-domain URL carries them again and is applied on top.
    func completeWebQRLogin(refreshToken: String, crossDomainURL: String) async {
        await applyLoginCookies(LoginAPI.cookies(fromCrossDomainURL: crossDomainURL),
                                refreshToken: refreshToken.isEmpty ? nil : refreshToken)
    }

    /// TV QR success: cookie_info cookies + `access_key` (minted for `AppKey.tv`).
    func completeTVLogin(_ result: TVLoginResult) async {
        await applyLogin(cookies: result.cookies, replaceExisting: true) { t in
            t.accessKey = result.accessToken
            t.accessKeyAppKey = AppKey.tv.key
            t.appRefreshToken = result.refreshToken.isEmpty ? nil : result.refreshToken
            t.accessKeyExpiresAt = result.expiresIn > 0 ? Date().timeIntervalSince1970 + Double(result.expiresIn) : nil
        }
    }

    /// Pasted cookie login ("SESSDATA=…; bili_jct=…; DedeUserID=…"). Verified against nav with
    /// only the pasted cookies before anything is stored. An `ac_time_value=` / `refresh_token=`
    /// entry is kept as the web refresh token.
    func loginWithCookieString(_ s: String) async throws {
        var pairs = LoginAPI.parseCookieString(s)
        var refreshToken: String?
        pairs.removeAll { p in
            if p.name == "ac_time_value" || p.name == "refresh_token" { refreshToken = p.value; return true }
            return false
        }
        pairs = pairs.map { p in
            // A SESSDATA copied in decoded form contains "," / "*"; the server's own cookie is encoded.
            guard p.name == "SESSDATA", p.value.contains(",") || p.value.contains("*") else { return p }
            return (name: p.name,
                    value: p.value.replacingOccurrences(of: ",", with: "%2C").replacingOccurrences(of: "*", with: "%2A"))
        }
        guard pairs.contains(where: { $0.name == "SESSDATA" }) else {
            throw BiliError.other("未找到 SESSDATA，请检查 Cookie 格式")
        }
        let header = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let nav = try await verifyCookieHeader(header)
        guard nav.isLogin else {
            throw nav.code == 0 || nav.code == -101 ? BiliError.other("Cookie 无效或已过期") : BiliError.api(code: nav.code, message: "")
        }
        let cookies = pairs.compactMap { LoginAPI.makeCookie(name: $0.name, value: $0.value) }
        await applyLogin(cookies: cookies, replaceExisting: true) { t in
            t.refreshToken = refreshToken
        }
    }

    /// Web cookie refresh (§8) when the server asks for it. Runs at most once a day unless forced.
    func refreshCookiesIfNeeded(force: Bool = false) async {
        guard http.isLoggedIn, let token = locked({ tokens.refreshToken }), !token.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: AuthService.lastRefreshCheckKey)
        guard force || now - last >= 24 * 3600 else { return }
        let gen = currentGeneration
        do {
            let newToken = try await LoginAPI.refreshWebCookies(refreshToken: token)
            guard gen == currentGeneration else { return }
            // Only a completed check counts, so a flaky network retries on the next launch.
            UserDefaults.standard.set(now, forKey: AuthService.lastRefreshCheckKey)
            guard let newToken else { return }
            locked { tokens.refreshToken = newToken }
            persistNow()
            await refreshProfile()
        } catch {
            // Non-fatal: the old cookies keep working until they expire; nav reports -101 then.
        }
    }

    /// Writes cookies + tokens to the Keychain now (also done automatically, debounced, whenever
    /// the cookie storage changes and when the app enters the background).
    func persistNow() {
        persistQueue.sync { writeStore() }
    }

    // MARK: - Bootstrap

    private func runBootstrap() async {
        await ensureDeviceCookies()
        activateIfNeeded()
        async let ticket: Void = ensureBiliTicket(force: false)
        async let nav: Void = refreshProfile()
        _ = await (ticket, nav)
        schedulePersist()
        await refreshCookiesIfNeeded()
    }

    /// buvid3 / buvid4 (finger/spi, local fallback), b_nut, _uuid and a fresh b_lsid (§4.8).
    private func ensureDeviceCookies() async {
        let year: TimeInterval = 365 * 24 * 3600
        if http.cookie(named: "buvid3") == nil || http.cookie(named: "buvid4") == nil {
            if let d = try? await http.api(BiliHost.api + "/x/frontend/finger/spi", timeout: 4) {
                let b3 = d["b_3"].stringValue, b4 = d["b_4"].stringValue
                if !b3.isEmpty, http.cookie(named: "buvid3") == nil {
                    http.setCookie(name: "buvid3", value: b3, expires: Date().addingTimeInterval(year))
                }
                if !b4.isEmpty, http.cookie(named: "buvid4") == nil {
                    http.setCookie(name: "buvid4", value: b4, expires: Date().addingTimeInterval(year))
                }
            }
            if http.cookie(named: "buvid3") == nil {
                http.setCookie(name: "buvid3", value: WebDeviceID.localBuvid3(), expires: Date().addingTimeInterval(year))
            }
        }
        if http.cookie(named: "b_nut") == nil {
            http.setCookie(name: "b_nut", value: String(Int64(Date().timeIntervalSince1970)),
                           expires: Date().addingTimeInterval(year))
        }
        if http.cookie(named: "_uuid") == nil {
            http.setCookie(name: "_uuid", value: WebDeviceID.uuid(), expires: Date().addingTimeInterval(year))
        }
        // Per-launch session id like the web client; a session cookie.
        if let c = StoredCookie(name: "b_lsid", value: WebDeviceID.bLsid()).httpCookie {
            http.cookieStorage.setCookie(c)
        }
    }

    /// ExClimbWuzhi buvid activation (§4.6), once per launch per account, fire-and-forget.
    private func activateIfNeeded() {
        let key = http.cookie(named: "DedeUserID") ?? "anonymous"
        let shouldRun: Bool = locked {
            if activatedKeys.contains(key) { return false }
            activatedKeys.insert(key)
            return true
        }
        guard shouldRun, let body = WebDeviceID.exClimbWuzhiBody(),
              let url = URL(string: BiliHost.api + "/x/internal/gaia-gateway/ExClimbWuzhi") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        let session = http.session
        Task.detached(priority: .utility) {
            _ = try? await session.data(for: req)
        }
    }

    /// `bili_ticket` (§4.7), refreshed when missing or within an hour of `bili_ticket_expires`.
    private func ensureBiliTicket(force: Bool) async {
        let now = Int64(Date().timeIntervalSince1970)
        if !force, http.cookie(named: "bili_ticket") != nil,
           let exp = http.cookie(named: "bili_ticket_expires").flatMap({ Int64($0) }), exp > now + 3600 {
            return
        }
        let query: [String: Any] = [
            "key_id": "ec02",
            "hexsign": BiliTicket.hexsign(ts: now),
            "context[ts]": String(now),
            "csrf": http.csrf ?? "",
        ]
        guard let d = try? await http.api(BiliHost.api + "/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket",
                                          method: "POST", query: query, timeout: 6) else { return }
        let ticket = d["ticket"].stringValue
        guard !ticket.isEmpty else { return }
        let created = d["created_at"].int64 ?? now
        let ttl = d["ttl"].int64 ?? BiliTicket.defaultTTL
        let expires = created + (ttl > 0 ? ttl : BiliTicket.defaultTTL)
        let expDate = Date(timeIntervalSince1970: TimeInterval(expires))
        http.setCookie(name: "bili_ticket", value: ticket, expires: expDate)
        http.setCookie(name: "bili_ticket_expires", value: String(expires), expires: expDate)
        let img = d[path: "nav.img"].stringValue, sub = d[path: "nav.sub"].stringValue
        if !img.isEmpty, !sub.isEmpty { await http.wbi.update(imgURL: img, subURL: sub) }
    }

    // MARK: - Profile

    private func loadProfile(generation gen: Int) async {
        let hadSession = http.isLoggedIn
        guard let root = try? await http.json(BiliHost.api + "/x/web-interface/nav", timeout: 8) else { return }
        let nav = AccountNavInfo(root: root)
        if !nav.wbiImgURL.isEmpty, !nav.wbiSubURL.isEmpty {
            await http.wbi.update(imgURL: nav.wbiImgURL, subURL: nav.wbiSubURL)
        }
        guard gen == currentGeneration else { return }
        if nav.isLogin, var p = nav.profile {
            AuthService.saveCached(p, key: AuthService.profileCacheKey)
            await publish(generation: gen, loggedIn: true, profile: p, stat: nil, updateStat: false)
            activateIfNeeded()
            async let statResult = fetchStat()
            async let signResult = fetchSign(mid: p.mid)
            let (s, sign) = await (statResult, signResult)
            guard gen == currentGeneration else { return }
            if let sign { p.sign = sign }
            AuthService.saveCached(p, key: AuthService.profileCacheKey)
            if let s { AuthService.saveCached(s, key: AuthService.statCacheKey) }
            await publish(generation: gen, loggedIn: true, profile: p, stat: s, updateStat: s != nil)
        } else if nav.isLoggedOutResponse {
            if hadSession {
                // The stored session is no longer valid (expired / revoked elsewhere).
                guard bumpGenerationIfCurrent(gen) else { return }
                clearSessionLocally()
                await publishLoggedOut()
            } else {
                await publish(generation: gen, loggedIn: false, profile: nil, stat: nil, updateStat: true)
            }
        }
        // Other codes (-352 / -412 risk control, 5xx): keep the current state.
    }

    private func fetchStat() async -> UserStat? {
        guard let d = try? await http.api(BiliHost.api + "/x/web-interface/nav/stat", timeout: 8) else { return nil }
        return UserStat(json: d)
    }

    private func fetchSign(mid: Int64) async -> String? {
        guard let d = try? await http.api(BiliHost.api + "/x/web-interface/card",
                                          query: ["mid": mid, "photo": "false"], timeout: 8) else { return nil }
        return d[path: "card.sign"].string
    }

    private func clearProfileTask(generation gen: Int) {
        locked { if profileTask?.generation == gen { profileTask = nil } }
    }

    // MARK: - Login / logout plumbing

    private func applyLogin(cookies: [HTTPCookie], replaceExisting: Bool, tokens update: (inout StoredSession) -> Void) async {
        bumpGeneration()
        if replaceExisting { removeSessionCookies() }
        removeCookies(named: ["bili_ticket", "bili_ticket_expires"])
        for c in cookies { http.cookieStorage.setCookie(AuthService.normalized(c)) }
        locked {
            var t = StoredSession()
            update(&t)
            tokens = t
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: AuthService.lastRefreshCheckKey)
        UserDefaults.standard.removeObject(forKey: AuthService.profileCacheKey)
        UserDefaults.standard.removeObject(forKey: AuthService.statCacheKey)
        persistNow()
        let gen = currentGeneration
        let loggedIn = http.isLoggedIn
        await publish(generation: gen, loggedIn: loggedIn, profile: nil, stat: nil, updateStat: true, notify: true)
        await refreshProfile()
        activateIfNeeded()
        Task.detached(priority: .utility) { [weak self] in
            await self?.ensureBiliTicket(force: true)
        }
    }

    /// Removes login cookies + tokens + caches, keeps device cookies, persists.
    private func clearSessionLocally() {
        for c in http.cookieStorage.cookies ?? []
        where CookiePersistence.isBiliDomain(c.domain) && !AuthService.deviceCookieNames.contains(c.name) {
            http.cookieStorage.deleteCookie(c)
        }
        locked { tokens = StoredSession() }
        UserDefaults.standard.removeObject(forKey: AuthService.profileCacheKey)
        UserDefaults.standard.removeObject(forKey: AuthService.statCacheKey)
        UserDefaults.standard.removeObject(forKey: AuthService.lastRefreshCheckKey)
        persistNow()
    }

    private func removeSessionCookies() {
        removeCookies(named: LoginAPI.sessionCookieNames)
    }

    private func removeCookies(named names: Set<String>) {
        for c in http.cookieStorage.cookies ?? [] where names.contains(c.name) && CookiePersistence.isBiliDomain(c.domain) {
            http.cookieStorage.deleteCookie(c)
        }
    }

    /// Host-only / foreign-domain cookies are re-scoped to `.bilibili.com` `/` so api.* sees them.
    static func normalized(_ c: HTTPCookie) -> HTTPCookie {
        if c.domain == ".bilibili.com", c.path == "/" { return c }
        var s = StoredCookie(c)
        s.domain = ".bilibili.com"
        s.path = "/"
        return s.httpCookie ?? c
    }

    /// Requests nav with an explicit Cookie header through a cookie-less ephemeral session.
    private func verifyCookieHeader(_ header: String) async throws -> AccountNavInfo {
        guard let url = URL(string: BiliHost.api + "/x/web-interface/nav") else { throw BiliError.invalidURL("nav") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 10)
        var cookie = header
        if let b3 = http.cookie(named: "buvid3"), !header.contains("buvid3=") { cookie += "; buvid3=\(b3)" }
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw BiliError.cancelled
        }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw BiliError.http(status: h.statusCode) }
        guard let root = try? JSON(data: data) else { throw BiliError.decoding("nav") }
        return AccountNavInfo(root: root)
    }

    // MARK: - Publishing (main actor)

    @MainActor
    private func publish(generation gen: Int, loggedIn: Bool, profile p: UserProfile?, stat s: UserStat?,
                         updateStat: Bool, notify: Bool = false) {
        guard gen == currentGeneration else { return }
        let changed = isLoggedIn != loggedIn
        if changed { isLoggedIn = loggedIn }
        if profile != p { profile = p }
        if updateStat, stat != s { stat = s }
        if changed || notify {
            NotificationCenter.default.post(name: AuthService.loginStateDidChange, object: self)
        }
    }

    @MainActor
    private func publishLoggedOut() {
        isLoggedIn = false
        profile = nil
        stat = nil
        NotificationCenter.default.post(name: AuthService.loginStateDidChange, object: self)
    }

    // MARK: - Persistence

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSHTTPCookieManagerCookiesChanged, object: nil, queue: nil) { [weak self] _ in
            self?.schedulePersist()
        })
        // UIApplication.didEnterBackgroundNotification (Core cannot import UIKit).
        observers.append(center.addObserver(forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"),
                                            object: nil, queue: nil) { [weak self] _ in
            self?.persistNow()
        })
    }

    private func schedulePersist() {
        let schedule: Bool = locked {
            if persistPending { return false }
            persistPending = true
            return true
        }
        guard schedule else { return }
        persistQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.locked { self.persistPending = false }
            self.writeStore()
        }
    }

    /// Must run on `persistQueue`.
    private func writeStore() {
        var s = locked { tokens }
        s.cookies = CookiePersistence.snapshot(from: http.cookieStorage)
        s.savedAt = Date().timeIntervalSince1970
        CookiePersistence.save(s)
    }

    private static func loadCached<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func saveCached<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var currentGeneration: Int { locked { generation } }

    private func bumpGeneration() {
        locked { generation += 1 }
    }

    private func bumpGenerationIfCurrent(_ gen: Int) -> Bool {
        locked {
            guard generation == gen else { return false }
            generation += 1
            return true
        }
    }

    /// Waits for `task` but returns after `seconds` at the latest (the task keeps running).
    static func wait(for task: Task<Void, Never>, atMost seconds: TimeInterval) async {
        let gate = OnceGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task {
                await task.value
                if gate.fire() { cont.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.fire() { cont.resume() }
            }
        }
    }
}

/// Returns `true` exactly once.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Web device identifiers (api-auth §4.1, §4.6).
enum WebDeviceID {
    /// PiliPlus-style local buvid3: `UUID().uppercased() + 5 digits + "infoc"` (46 chars).
    static func localBuvid3() -> String {
        let n = String(Int.random(in: 0..<100000))
        return UUID().uuidString.uppercased() + String(repeating: "0", count: 5 - n.count) + n + "infoc"
    }

    /// Web `_uuid`: 8-4-4-4-12 groups drawn from 1…F plus the two-char token "10", then
    /// `ms % 100000` right-padded with "0" to 5 chars, then "infoc".
    static func uuid(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let mp = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F", "10"]
        let groups = [8, 4, 4, 4, 12].map { n in (0..<n).map { _ in mp.randomElement()! }.joined() }
        let t = String(nowMs % 100000)
        return groups.joined(separator: "-") + t + String(repeating: "0", count: max(0, 5 - t.count)) + "infoc"
    }

    /// `b_lsid`: 8 random uppercase hex + "_" + uppercase hex of the ms timestamp.
    static func bLsid(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let hex = Array("0123456789ABCDEF")
        let r = String((0..<8).map { _ in hex[Int.random(in: 0..<16)] })
        return r + "_" + String(nowMs, radix: 16, uppercase: true)
    }

    /// `{"payload":"{\"3064\":1,\"39c8\":\"333.1387.fp.risk\",\"3c43\":{\"adca\":\"MacIntel\",\"bfe9\":…}}"}`
    static func exClimbWuzhiBody() -> Data? {
        var bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        bytes += [0, 0, 0, 0, 73, 69, 78, 68] // "IEND"
        bytes += (0..<4).map { _ in UInt8.random(in: 0...255) }
        let randPngEnd = String(Data(bytes).base64EncodedString().suffix(50))
        let payload: [String: Any] = [
            "3064": 1,
            "39c8": "333.1387.fp.risk",
            "3c43": ["adca": "MacIntel", "bfe9": randPngEnd],
        ]
        guard let p = try? JSONSerialization.data(withJSONObject: payload),
              let ps = String(data: p, encoding: .utf8) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["payload": ps])
    }
}

/// `bili_ticket` signing (api-auth §4.7).
enum BiliTicket {
    static let hmacKey = "XgwSnGZ1p"
    static let defaultTTL: Int64 = 3 * 86400

    static func hexsign(ts: Int64) -> String {
        Hashing.hmacSHA256Hex(key: hmacKey, message: "ts\(ts)")
    }
}
