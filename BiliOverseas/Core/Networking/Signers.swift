import Foundation
import CryptoKit

enum Hashing {
    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func hmacSHA256Hex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Web "WBI" request signing (`w_rid`, `wts`).
///
/// Keys come from `/x/web-interface/nav` → `data.wbi_img.{img_url,sub_url}` (file name without
/// extension). That endpoint answers code -101 when logged out but still carries `wbi_img`.
actor WbiSigner {
    static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    private static let defaultsKey = "bili.wbi.keys"
    private var mixinKey: String?
    private var fetchedAt: Date?
    private var inflight: Task<String, Error>?

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: WbiSigner.defaultsKey),
           let key = saved["mixin"] as? String,
           let ts = saved["ts"] as? Double {
            mixinKey = key
            fetchedAt = Date(timeIntervalSince1970: ts)
        }
    }

    static func mixinKey(imgKey: String, subKey: String) -> String {
        let raw = Array(imgKey + subKey)
        guard raw.count >= 64 else { return String(raw.prefix(32)) }
        return String(mixinKeyEncTab.prefix(32).map { raw[$0] })
    }

    /// Extracts the key from a URL like `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`.
    static func keyFromURL(_ url: String) -> String {
        let last = url.split(separator: "/").last.map(String.init) ?? url
        return last.split(separator: ".").first.map(String.init) ?? last
    }

    /// Pure signing step, separated for unit tests.
    static func sign(_ params: [String: String], mixinKey: String, wts: Int64) -> [String: String] {
        var p: [String: String] = [:]
        let banned = CharacterSet(charactersIn: "!'()*")
        for (k, v) in params {
            p[k] = String(String.UnicodeScalarView(v.unicodeScalars.filter { !banned.contains($0) }))
        }
        p["wts"] = String(wts)
        let query = BiliHTTP.encodeQuery(p, sorted: true)
        p["w_rid"] = Hashing.md5Hex(query + mixinKey)
        return p
    }

    func sign(_ params: [String: String]) async throws -> [String: String] {
        let key = try await currentKey()
        return WbiSigner.sign(params, mixinKey: key, wts: Int64(Date().timeIntervalSince1970))
    }

    func invalidate() {
        mixinKey = nil
        fetchedAt = nil
    }

    /// Lets `AuthService` seed the keys from a nav response it already fetched.
    func update(imgURL: String, subURL: String) {
        let key = WbiSigner.mixinKey(imgKey: WbiSigner.keyFromURL(imgURL), subKey: WbiSigner.keyFromURL(subURL))
        store(key)
    }

    private func store(_ key: String) {
        mixinKey = key
        fetchedAt = Date()
        UserDefaults.standard.set(["mixin": key, "ts": Date().timeIntervalSince1970], forKey: WbiSigner.defaultsKey)
    }

    private func currentKey() async throws -> String {
        if let mixinKey, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 6 * 3600 { return mixinKey }
        if let inflight { return try await inflight.value }
        let task = Task<String, Error> {
            let root = try await BiliHTTP.shared.json(BiliHost.api + "/x/web-interface/nav")
            let img = root[path: "data.wbi_img.img_url"].stringValue
            let sub = root[path: "data.wbi_img.sub_url"].stringValue
            guard !img.isEmpty, !sub.isEmpty else { throw BiliError.other("获取 WBI 密钥失败") }
            return WbiSigner.mixinKey(imgKey: WbiSigner.keyFromURL(img), subKey: WbiSigner.keyFromURL(sub))
        }
        inflight = task
        defer { inflight = nil }
        do {
            let key = try await task.value
            store(key)
            return key
        } catch {
            if let mixinKey { return mixinKey } // stale key beats no key
            throw error
        }
    }
}

/// App (`appkey` + `sign`) request signing.
enum AppSigner {
    static func sign(_ params: [String: String], key: AppKey, ts: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: String] {
        var p = params
        p["appkey"] = key.key
        if p["ts"] == nil { p["ts"] = String(ts) }
        p.removeValue(forKey: "sign")
        let query = BiliHTTP.encodeQuery(p, sorted: true)
        p["sign"] = Hashing.md5Hex(query + key.secret)
        return p
    }
}
