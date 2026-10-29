import Foundation

/// Display kind of a dynamic (动态), derived from `type` / `major.type`.
enum DynamicKind: String, Hashable {
    case video      // DYNAMIC_TYPE_AV / UGC_SEASON (投稿视频)
    case draw       // DYNAMIC_TYPE_DRAW (图文)
    case word       // DYNAMIC_TYPE_WORD (纯文字)
    case forward    // DYNAMIC_TYPE_FORWARD (转发)
    case pgc        // DYNAMIC_TYPE_PGC / PGC_UNION (番剧)
    case live       // DYNAMIC_TYPE_LIVE / LIVE_RCMD (直播)
    case article    // DYNAMIC_TYPE_ARTICLE (专栏)
    case other      // courses, music, medialist, common, deleted …
}

struct DynamicStat: Hashable {
    var forward: Int64 = 0
    var comment: Int64 = 0
    var like: Int64 = 0
    /// The current user liked it (`like.status`).
    var liked: Bool = false
}

/// One dynamic card of the follow feed or a user's space feed.
struct DynamicItem: Identifiable, Hashable {
    var id: String { idStr }
    var idStr: String
    var type: DynamicKind = .other
    /// Raw `DYNAMIC_TYPE_*`.
    var rawType: String = ""
    var author: UserBrief = UserBrief(mid: 0)
    /// e.g. "5分钟前", "昨天 12:00".
    var pubTimeText: String = ""
    /// Unix seconds.
    var pubTs: Int64 = 0
    /// e.g. "投稿了视频", "发布了动态".
    var pubAction: String = ""
    /// Plain text (rich text flattened; emoji kept as `[name]`, @mentions as `@name`, topics as `#t#`).
    var text: String = ""
    /// Title of an opus / article, when present.
    var title: String = ""
    /// `[name]` → emoji image URL, for rendering `text` richly.
    var emojis: [String: String] = [:]
    /// https image URLs (图文 / opus pics / article covers).
    var images: [String] = []
    /// Embedded playable card: a video (`kind .video`), PGC episode (`.bangumi`) or live room (`.live`).
    var video: VideoCard? = nil
    var stat = DynamicStat()
    /// Comment thread (`basic.comment_id_str`, `basic.comment_type`).
    var commentId: Int64 = 0
    var commentType: Int = 0
    var jumpURL: String = ""
    var topic: String = ""
    /// 置顶.
    var isTop: Bool = false
    /// `DYNAMIC_TYPE_AD`.
    var isAd: Bool = false
    /// 带货: `additional.type == ADDITIONAL_TYPE_GOODS` on the item or its original.
    var hasGoods: Bool = false
    /// Raw filter signals: `"type=DYNAMIC_TYPE_AD"`, `"goods"`, `"game"` (game promotion card).
    /// They are NOT copied into `video.adSignals`; filter dynamics on these.
    var adSignals: [String] = []
    /// Deleted / unavailable placeholder (`MAJOR_TYPE_NONE`); `text` holds the tips.
    var isDeleted: Bool = false

    /// The forwarded original (only for `.forward`).
    var forwarded: DynamicItem? {
        get { forwardedStorage.first }
        set { forwardedStorage = newValue.map { [$0] } ?? [] }
    }
    private var forwardedStorage: [DynamicItem] = []

    init(idStr: String) { self.idStr = idStr }
}

/// A followed UP in the dynamics header (portal `up_list` / `live_users`).
struct DynamicUpEntry: Identifiable, Hashable {
    var id: Int64 { user.mid }
    var user: UserBrief
    /// Red dot: has new dynamics.
    var hasUpdate: Bool = false
    /// Currently live (from `live_users`).
    var isLive: Bool = false
    var roomId: Int64 = 0
    var liveTitle: String = ""
}
