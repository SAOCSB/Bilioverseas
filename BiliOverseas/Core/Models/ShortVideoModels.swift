import Foundation

/// One video of the 短视频 feed (the official app's vertical "story" mode: full-screen, one swipe
/// per video).
struct ShortVideoItem: Identifiable, Hashable {
    /// bvid, or "av<aid>" when the item has none.
    var id: String
    var aid: Int64 = 0
    var bvid: String = ""
    /// 0 when the feed did not say; the player then asks the video's detail.
    var cid: Int64 = 0
    var title: String = ""
    var cover: String = ""
    /// Seconds (0 when unknown).
    var duration: Int = 0
    /// Display size of the video (rotation applied), 0 when unknown.
    var width: Int = 0
    var height: Int = 0
    var ownerMid: Int64 = 0
    var ownerName: String = ""
    var ownerFace: String = ""
    /// The current user follows the uploader (as the feed reported it).
    var isFollowing: Bool = false
    var viewCount: Int64 = 0
    var danmakuCount: Int64 = 0
    var likeCount: Int64 = 0
    var coinCount: Int64 = 0
    var favoriteCount: Int64 = 0
    var replyCount: Int64 = 0
    var shareCount: Int64 = 0
    var desc: String = ""
    /// 1 original / 2 reprint (at most one coin), 0 when unknown.
    var copyright: Int = 0
    /// The feed's 不感兴趣 menu, when it offers one.
    var feedback: FeedCardFeedback? = nil

    init(id: String) { self.id = id }

    /// Portrait (taller than wide). Unknown sizes count as portrait: this feed is mostly vertical.
    var isPortrait: Bool { width <= 0 || height <= 0 || height > width }

    var maxCoins: Int { copyright == 2 ? 1 : 2 }

    var videoRef: VideoRef { VideoRef(aid: aid, bvid: bvid, cid: cid, title: title, cover: cover) }

    var shareURL: URL? {
        URL(string: bvid.isEmpty ? "https://www.bilibili.com/video/av\(aid)" : "https://www.bilibili.com/video/\(bvid)")
    }
}

/// One page of the 短视频 feed. `next` is what the following request needs (nil = no more).
struct ShortVideoPage {
    var items: [ShortVideoItem]
    var next: ShortVideoCursor?
}

/// Where the next page of the 短视频 feed starts.
struct ShortVideoCursor: Hashable {
    /// The video the feed continues from (the last one received).
    var aid: Int64
    var bvid: String
    /// 1-based count of pages requested so far in this session (the app's `display_id`).
    var displayId: Int
}
