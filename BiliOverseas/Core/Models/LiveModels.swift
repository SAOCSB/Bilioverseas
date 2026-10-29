import Foundation

/// A live room card / header.
struct LiveRoom: Identifiable, Hashable {
    var id: Int64 { roomId }
    var roomId: Int64
    /// Anchor mid.
    var uid: Int64 = 0
    var title: String = ""
    /// Room cover (https).
    var cover: String = ""
    /// Live keyframe screenshot (https), may be empty.
    var keyframe: String = ""
    var uname: String = ""
    var face: String = ""
    /// Legacy popularity number (0 when the server only sends `watchedText`).
    var online: Int64 = 0
    /// e.g. "1.2万人看过".
    var watchedText: String = ""
    var areaName: String = ""
    var parentAreaName: String = ""
    /// 0 未开播, 1 直播中, 2 轮播中.
    var liveStatus: Int = 0

    init(roomId: Int64) { self.roomId = roomId }

    var isLive: Bool { liveStatus == 1 }

    /// The room as a `.live` VideoCard (for VideoCardGrid / routing).
    var card: VideoCard {
        var c = VideoCard(id: "live-\(roomId)")
        c.kind = .live
        c.roomId = roomId
        c.title = title
        c.cover = cover.isEmpty ? keyframe : cover
        c.ownerMid = uid
        c.ownerName = uname
        c.ownerFace = face
        c.viewCount = online
        c.reason = watchedText
        c.desc = areaName
        c.badge = liveStatus == 1 ? "直播中" : (liveStatus == 2 ? "轮播中" : "未开播")
        c.uri = "https://live.bilibili.com/\(roomId)"
        return c
    }
}

struct LiveQualityOption: Identifiable, Hashable {
    var id: Int { qn }
    /// 30000 杜比, 25000 4K原画, 20000 4K, 15000 2K, 10000 原画, 400 蓝光, 250 超清, 150 高清, 80 流畅.
    var qn: Int
    var desc: String
}

/// Playable (HLS-only) stream URLs for a live room.
struct LivePlayInfo: Hashable {
    /// Real room id (short ids resolve to this).
    var roomId: Int64 = 0
    var uid: Int64 = 0
    /// 1 = 直播中. When not live, `urls` is empty (show "未开播").
    var liveStatus: Int = 0
    /// HLS URLs, best first: fmp4 before ts, avc before hevc, one per CDN host. Never FLV.
    var urls: [String] = []
    /// Qualities the chosen stream accepts.
    var qualities: [LiveQualityOption] = []
    /// Quality actually returned (trust this over the requested one).
    var currentQn: Int = 0
    /// `fmp4` / `ts` of `urls.first`.
    var format: String = ""
    /// `avc` / `hevc` of `urls.first`.
    var codec: String = ""
    var isPortrait: Bool = false

    var isLive: Bool { liveStatus == 1 }
}

struct LiveDanmuHost: Hashable {
    var host: String
    var port: Int = 0
    var wssPort: Int = 443
    var wsPort: Int = 0

    /// `wss://<host>:<wss_port>/sub`.
    var wssURL: String { "wss://\(host):\(wssPort)/sub" }
}

/// Live danmaku WebSocket credentials (`getDanmuInfo`).
struct LiveDanmuInfo: Hashable {
    var token: String
    var hosts: [LiveDanmuHost]
}
