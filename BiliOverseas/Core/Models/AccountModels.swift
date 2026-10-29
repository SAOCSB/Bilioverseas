import Foundation

/// 认证信息 (`official` in nav): `type` 0 = 个人认证, 1 = 机构认证.
struct AccountOfficial: Hashable, Codable {
    var type: Int
    var role: Int
    var title: String
    var desc: String

    var isPersonal: Bool { type == 0 }
    var isOrganization: Bool { type == 1 }
}

/// The logged-in user's own profile, built from `GET /x/web-interface/nav` (api-auth §9.1).
struct UserProfile: Hashable, Codable {
    var mid: Int64
    var name: String
    /// https avatar URL.
    var face: String
    /// 个性签名. Not part of nav; filled from `/x/web-interface/card` when available.
    var sign: String?
    /// 0…6.
    var level: Int
    var currentMinExp: Int64 = 0
    var currentExp: Int64 = 0
    /// `nil` at level 6 (the server sends `"--"`).
    var nextExp: Int64?
    /// 硬币 (`money`, may be fractional).
    var coins: Double = 0
    /// B币 (`wallet.bcoin_balance`).
    var bcoin: Double?
    /// 0 = none, 1 = 月度大会员, 2 = 年度大会员 (pink name).
    var vipType: Int = 0
    /// 1 = active.
    var vipStatus: Int = 0
    /// Unix milliseconds.
    var vipDueDate: Int64 = 0
    /// "大会员" / "年度大会员" / "" (`vip_label.text`).
    var vipLabelText: String = ""
    /// e.g. "#FB7299"; empty when the name is not colored.
    var vipNicknameColorHex: String = ""
    var vipAvatarSubscript: Int = 0
    /// 硬核会员.
    var isSeniorMember: Bool = false
    var official: AccountOfficial?
    /// 头像挂件 image URL (empty when none).
    var pendantImage: String = ""
    var emailVerified: Bool = false
    var mobileVerified: Bool = false

    init(mid: Int64, name: String, face: String = "", level: Int = 0) {
        self.mid = mid
        self.name = name
        self.face = face
        self.level = level
    }

    var isVip: Bool { vipStatus > 0 && vipType > 0 }
    var isAnnualVip: Bool { isVip && vipType == 2 }

    /// Exp bar fraction 0…1 (`current_exp / next_exp`, 1 at max level).
    var levelProgress: Double {
        guard let nextExp, nextExp > 0 else { return 1 }
        return min(1, max(0, Double(currentExp) / Double(nextExp)))
    }

    /// "1234/1500" (or "28800/--" at level 6).
    var expText: String { "\(currentExp)/\(nextExp.map(String.init) ?? "--")" }

    /// `data` of nav. Returns `nil` when the payload is not a logged-in user.
    init?(nav d: JSON) {
        let mid = d["mid"].int64Value
        guard d["isLogin"].boolValue, mid > 0 else { return nil }
        self.init(mid: mid, name: d["uname"].stringValue, face: d["face"].stringValue.biliHTTPS,
                  level: d[path: "level_info.current_level"].intValue)
        currentMinExp = d[path: "level_info.current_min"].int64Value
        currentExp = d[path: "level_info.current_exp"].int64Value
        // Level 6 sends "--" here; the lenient accessor yields nil for it.
        nextExp = d[path: "level_info.next_exp"].int64
        coins = d["money"].doubleValue
        let wallet = d["wallet"]
        if wallet["bcoin_balance"].exists { bcoin = wallet["bcoin_balance"].doubleValue }
        let vip = d["vip"]
        vipType = d["vipType"].int ?? vip["type"].intValue
        vipStatus = d["vipStatus"].int ?? vip["status"].intValue
        vipDueDate = d["vipDueDate"].int64 ?? vip["due_date"].int64Value
        vipLabelText = d[path: "vip_label.text"].string ?? vip[path: "label.text"].stringValue
        vipNicknameColorHex = d["vip_nickname_color"].string ?? vip["nickname_color"].stringValue
        vipAvatarSubscript = d["vip_avatar_subscript"].int ?? vip["avatar_subscript"].intValue
        isSeniorMember = d["is_senior_member"].intValue == 1
        let off = d["official"]
        let offType = off["type"].int ?? d[path: "officialVerify.type"].int ?? -1
        if offType >= 0 {
            official = AccountOfficial(
                type: offType,
                role: off["role"].intValue,
                title: off["title"].string ?? d[path: "officialVerify.desc"].stringValue,
                desc: off["desc"].stringValue)
        }
        pendantImage = d[path: "pendant.image"].stringValue.biliHTTPS
        emailVerified = d["email_verified"].intValue == 1
        mobileVerified = d["mobile_verified"].intValue == 1
    }
}

/// 关注 / 粉丝 / 动态 counts from `GET /x/web-interface/nav/stat` (§9.2).
struct UserStat: Hashable, Codable {
    var following: Int64
    var follower: Int64
    var dynamicCount: Int64

    init(following: Int64 = 0, follower: Int64 = 0, dynamicCount: Int64 = 0) {
        self.following = following
        self.follower = follower
        self.dynamicCount = dynamicCount
    }

    /// `data` of nav/stat.
    init(json d: JSON) {
        self.init(following: d["following"].int64Value,
                  follower: d["follower"].int64Value,
                  dynamicCount: d["dynamic_count"].int64Value)
    }
}

/// Everything AuthService needs from one nav response (whole root, any `code`).
struct AccountNavInfo {
    var code: Int
    var isLogin: Bool
    var profile: UserProfile?
    /// WBI key sources; present even for code -101.
    var wbiImgURL: String
    var wbiSubURL: String

    init(root: JSON) {
        code = root["code"].int ?? -1
        let d = root["data"]
        isLogin = code == 0 && d["isLogin"].boolValue
        profile = isLogin ? UserProfile(nav: d) : nil
        wbiImgURL = d[path: "wbi_img.img_url"].stringValue
        wbiSubURL = d[path: "wbi_img.sub_url"].stringValue
    }

    /// The server says this request carried no valid session.
    var isLoggedOutResponse: Bool { code == -101 || (code == 0 && !isLogin) }
}
