import Foundation

/// Comment list order (`mode` of `/x/v2/reply/main`).
enum ReplySort: Int, CaseIterable, Identifiable, Hashable {
    /// 按热度 (mode 3).
    case hot = 3
    /// 按时间 (mode 2).
    case time = 2

    var id: Int { rawValue }
    var mode: Int { rawValue }
    var title: String { self == .hot ? "按热度" : "按时间" }
}

/// One comment (REST reply object).
struct ReplyItem: Identifiable, Hashable {
    var id: Int64 { rpid }
    var rpid: Int64 = 0
    var oid: Int64 = 0
    /// Comment area type (1 = video).
    var type: Int = 1
    /// Root comment id (0 for a root comment).
    var root: Int64 = 0
    /// Directly replied comment id (0 for a root comment).
    var parent: Int64 = 0
    var dialog: Int64 = 0

    var mid: Int64 = 0
    var uname: String = ""
    var avatar: String = ""
    var level: Int = 0
    var isSeniorMember = false
    var isVip = false
    /// Nickname colour for VIPs, e.g. "#FB7299".
    var vipColorHex: String? = nil
    /// Fan medal ("粉丝牌 12") when shown.
    var memberLabel: String? = nil
    /// The commenter is the uploader (UP).
    var isUploader = false

    var message: String = ""
    /// Emote token (e.g. "[doge]") → https image URL.
    var emotes: [String: String] = [:]
    /// Tokens of large (size 2) emotes.
    var largeEmotes: Set<String> = []
    /// @-mentioned names → mid.
    var atMembers: [String: Int64] = [:]
    /// Highlighted keywords (`content.jump_url`) → link (may be empty).
    var jumpLinks: [String: String] = [:]
    /// Picture URLs (https).
    var pictures: [String] = []

    var likeCount: Int64 = 0
    /// Number of sub replies (`rcount`).
    var replyCount: Int = 0
    /// Unix seconds.
    var ctime: Int64 = 0
    /// Server time text, e.g. "3天前发布" (may be empty).
    var timeDesc: String = ""
    /// "IP属地：广东" (may be empty).
    var location: String = ""
    /// Pinned (置顶).
    var isUpTop = false
    /// UP主觉得很赞.
    var upLiked = false
    /// UP主回复了.
    var upReplied = false
    /// Current user liked it (`action == 1`).
    var userLiked = false
    /// Current user disliked it (`action == 2`).
    var userDisliked = false
    /// Up to ~3 preview sub replies.
    var previewReplies: [ReplyItem] = []
    /// "共12条回复" (empty when there are no sub replies).
    var replyCountText: String = ""

    init() {}

    init(json j: JSON, upperMid: Int64 = 0) {
        rpid = j["rpid"].int64 ?? Int64(j["rpid_str"].stringValue) ?? 0
        oid = j["oid"].int64Value
        type = j["type"].int ?? 1
        root = j["root"].int64Value
        parent = j["parent"].int64Value
        dialog = j["dialog"].int64Value

        let m = j["member"]
        mid = j["mid"].int64 ?? m["mid"].int64Value
        if mid == 0 { mid = m["mid"].int64Value }
        uname = m["uname"].stringValue
        avatar = m["avatar"].stringValue.biliHTTPS
        level = m[path: "level_info.current_level"].intValue
        isSeniorMember = m["is_senior_member"].boolValue
        let vip = m["vip"]
        let vipStatus = vip["vipStatus"].int ?? vip["status"].intValue
        let vipType = vip["vipType"].int ?? vip["type"].intValue
        isVip = vipStatus == 1 && vipType > 0
        if isVip {
            let color = vip["nickname_color"].stringValue
            vipColorHex = color.isEmpty ? (vipType == 2 ? "#FB7299" : nil) : color
        }
        let medal = m[path: "fans_detail.medal_name"].stringValue
        if !medal.isEmpty {
            let lv = m[path: "fans_detail.level"].intValue
            memberLabel = lv > 0 ? "\(medal) \(lv)" : medal
        }
        isUploader = upperMid != 0 && mid == upperMid

        let c = j["content"]
        message = c["message"].stringValue
        for (token, e) in c["emote"].objectValue {
            let url = (e["url"].string ?? e["gif_url"].stringValue).biliHTTPS
            guard !url.isEmpty else { continue }
            emotes[token] = url
            if e[path: "meta.size"].intValue == 2 { largeEmotes.insert(token) }
        }
        for member in c["members"].arrayValue {
            let name = member["uname"].stringValue
            if !name.isEmpty { atMembers[name] = member["mid"].int64Value }
        }
        for (name, v) in c["at_name_to_mid"].objectValue where atMembers[name] == nil {
            atMembers[name] = v.int64Value
        }
        for (keyword, v) in c["jump_url"].objectValue {
            jumpLinks[keyword] = v["pc_url"].string ?? v["app_url_schema"].stringValue
        }
        pictures = c["pictures"].arrayValue.map { $0["img_src"].stringValue.biliHTTPS }.filter { !$0.isEmpty }

        likeCount = j["like"].int64Value
        replyCount = j["rcount"].int ?? j["count"].intValue
        ctime = j["ctime"].int64Value
        let rc = j["reply_control"]
        timeDesc = rc["time_desc"].stringValue
        location = rc["location"].stringValue
        isUpTop = rc["is_up_top"].boolValue
        upLiked = j[path: "up_action.like"].boolValue
        upReplied = j[path: "up_action.reply"].boolValue
        let action = j["action"].intValue
        userLiked = action == 1
        userDisliked = action == 2
        previewReplies = j["replies"].arrayValue.map { ReplyItem(json: $0, upperMid: upperMid) }
        let entry = rc["sub_reply_entry_text"].stringValue
        replyCountText = !entry.isEmpty ? entry : (replyCount > 0 ? "共\(replyCount)条回复" : "")
    }
}

/// A page of comments.
struct ReplyPage: Hashable {
    var items: [ReplyItem] = []
    /// Pinned comments (first page of the main list only).
    var topItems: [ReplyItem] = []
    /// Opaque cursor for the next request (main list: `next_offset`; sub replies: page number).
    var nextCursor: String? = nil
    var hasMore = false
    var totalCount = 0
    /// The uploader's mid (for the "UP" badge).
    var upperMid: Int64 = 0
    /// Root comment (sub-reply pages only).
    var root: ReplyItem? = nil
    /// Input box placeholder (`control.root_input_text` / `child_input_text`).
    var inputPlaceholder: String = ""
    /// Commenting disabled for this area (`control.input_disable`).
    var inputDisabled = false

    init() {}
}
