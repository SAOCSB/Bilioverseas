import Foundation

/// Anti-risk-control ("风控", code -352) parameters the web client sends with WBI-signed
/// requests (playurl, space, dynamics). Merge them into the query before signing.
enum BiliRisk {
    /// `dm_img_list`, `dm_img_str`, `dm_cover_img_str`, `dm_img_inter`.
    static func dmImgParams() -> [String: Any] {
        [
            "dm_img_list": "[]",
            "dm_img_str": randomB64(minBytes: 16, maxBytes: 64),
            "dm_cover_img_str": randomB64(minBytes: 32, maxBytes: 128),
            "dm_img_inter": #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#,
        ]
    }

    /// Extra params the web player adds to playurl requests.
    static func playurlParams() -> [String: Any] {
        var p = dmImgParams()
        p["gaia_source"] = "pre-load"
        p["isGaiaAvoided"] = "true"
        p["web_location"] = "1315873"
        return p
    }

    /// N random bytes (N in [min, max]) each in 0x26…0x7E, base64 encoded, last 2 chars dropped.
    static func randomB64(minBytes: Int, maxBytes: Int) -> String {
        let n = Int.random(in: minBytes...maxBytes)
        let bytes = (0..<n).map { _ in UInt8(0x26 + Int.random(in: 0..<0x59)) }
        let b64 = Data(bytes).base64EncodedString()
        return String(b64.dropLast(2))
    }

    /// Merges `extra` into `base` without overriding keys already present.
    static func merged(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        base.merging(extra) { current, _ in current }
    }
}
