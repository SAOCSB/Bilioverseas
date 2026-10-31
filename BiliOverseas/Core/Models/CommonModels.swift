import Foundation

/// What a feed card links to.
enum CardKind: String, Codable, Hashable {
    case video      // goto=av / ugc
    case bangumi    // pgc episode / season
    case live       // live room
    case article    // 专栏
    case ad         // commercial card (广告 / 创作推广)
    case other
}

/// Unified card used by every video list (recommend, popular, ranking, search, history,
/// favorites, watch later, space, related, dynamics). Each API maps its JSON into this.
struct VideoCard: Identifiable, Hashable {
    /// Unique per list position source; prefer bvid, fall back to aid / room / ep ids.
    var id: String
    var kind: CardKind = .video
    var aid: Int64 = 0
    var bvid: String = ""
    var cid: Int64 = 0
    var title: String = ""
    /// Full https cover URL.
    var cover: String = ""
    /// Seconds (0 when unknown).
    var duration: Int = 0
    var ownerMid: Int64 = 0
    var ownerName: String = ""
    var ownerFace: String = ""
    var viewCount: Int64 = 0
    var danmakuCount: Int64 = 0
    var likeCount: Int64 = 0
    /// Unix seconds.
    var pubdate: Int64 = 0
    var desc: String = ""
    /// Small badge text such as "已关注", "1万点赞", "番剧", "直播中".
    var badge: String = ""
    /// Recommend reason / rank text.
    var reason: String = ""
    /// Seconds watched (history / continue watching); -1 means finished.
    var progress: Int = 0
    /// Unix seconds when it was viewed (history) or added (favorites).
    var viewAt: Int64 = 0
    var epId: Int64 = 0
    var seasonId: Int64 = 0
    var roomId: Int64 = 0
    /// Original link, used for ads / articles / unknown cards.
    var uri: String = ""
    /// The uploader is followed by the current user (exempts it from filters).
    var isFollowed: Bool = false
    /// Raw signals for FeedFilter: ad / business markers found while parsing.
    var adSignals: [String] = []
    /// Number of parts (分P) when known.
    var pageCount: Int = 0
    /// Zone / partition name (`tname`) when known.
    var zone: String = ""
    /// 首页推荐 不感兴趣 menu (the app feed's `three_point_v2`, or the web feed's fixed reasons), nil for every other list.
    var feedback: FeedCardFeedback? = nil
    /// Display size of the video (rotation applied) when the list says (app feed), 0 otherwise.
    var width: Int = 0
    var height: Int = 0

    init(id: String) { self.id = id }

    /// A known portrait (vertical) video; unknown sizes are not.
    var isPortraitVideo: Bool { width > 0 && height > width }

    var videoRef: VideoRef {
        VideoRef(aid: aid, bvid: bvid, cid: cid, epId: epId, seasonId: seasonId,
                 title: title, cover: cover, startTime: progress > 0 ? Double(progress) : nil)
    }
}

/// Everything needed to open a video detail page.
struct VideoRef: Hashable {
    var aid: Int64 = 0
    var bvid: String = ""
    /// Specific part; 0 = first part.
    var cid: Int64 = 0
    /// Bangumi episode (opens the PGC player when non-zero).
    var epId: Int64 = 0
    var seasonId: Int64 = 0
    /// Optional placeholders shown while loading.
    var title: String = ""
    var cover: String = ""
    /// Start playback here (seconds) instead of the saved progress.
    var startTime: Double? = nil
    /// 播放全部 list (稍后再看 / 收藏夹) the video page continues through after this video; nil for a single video.
    var playlist: VideoPlaylist? = nil
    /// Opened from the 短视频 feed (完整视频页): a swipe up on the vertical video goes back to that feed.
    var fromShortVideos: Bool = false

    var isPGC: Bool { epId != 0 || seasonId != 0 }

    static func bvid(_ bvid: String) -> VideoRef { VideoRef(bvid: bvid) }
    static func aid(_ aid: Int64) -> VideoRef { VideoRef(aid: aid) }
}

struct UserBrief: Identifiable, Hashable {
    var id: Int64 { mid }
    var mid: Int64
    var name: String = ""
    var face: String = ""
    var sign: String = ""
    var level: Int = 0
    var vipLabel: String = ""
    var isFollowed: Bool = false
    var fans: Int64 = 0
}

/// Cursor-or-page pagination result used by list APIs.
struct Page<Item> {
    var items: [Item]
    var hasMore: Bool
    /// Opaque cursor for the next request (page number, offset string, view_at …).
    var next: String?

    init(items: [Item], hasMore: Bool, next: String? = nil) {
        self.items = items
        self.hasMore = hasMore
        self.next = next
    }

    static var empty: Page<Item> { Page(items: [], hasMore: false) }
}

extension String {
    /// Normalises Bilibili image URLs: `//i0.hdslb.com/...` → `https://…`, http → https.
    var biliHTTPS: String {
        if hasPrefix("//") { return "https:" + self }
        if hasPrefix("http://") { return "https://" + dropFirst(7) }
        return self
    }

    /// Removes the `<em class="keyword">` highlight markup used by search results.
    var strippingHTMLTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
