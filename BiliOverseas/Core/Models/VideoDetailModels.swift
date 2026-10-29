import Foundation

// Models for the video detail page, player side-data, interactions and PGC (bangumi) seasons.
// Every model is built from the lenient `JSON` type; missing fields fall back to defaults.

// MARK: - UGC detail (`/x/web-interface/wbi/view` → data)

/// `data.stat` of a UGC archive.
struct VideoStat: Hashable {
    var view: Int64 = 0
    var danmaku: Int64 = 0
    var reply: Int64 = 0
    var favorite: Int64 = 0
    var coin: Int64 = 0
    var share: Int64 = 0
    var like: Int64 = 0
    /// The web API always reports 0 here; nil when the key is absent.
    var dislike: Int64? = nil
    /// Highest all-site rank ever reached (0 = never ranked).
    var hisRank: Int = 0

    init() {}

    init(json: JSON) {
        view = json["view"].int64Value
        danmaku = json["danmaku"].int64Value
        reply = json["reply"].int64Value
        favorite = json["favorite"].int64Value
        coin = json["coin"].int64Value
        share = json["share"].int64Value
        like = json["like"].int64Value
        dislike = json["dislike"].int64
        hisRank = json["his_rank"].intValue
    }
}

/// One part (分P) of a UGC video (`data.pages[]`, `/x/player/pagelist` → `data[]`).
struct VideoPart: Hashable, Identifiable {
    var id: Int64 { cid }
    var cid: Int64 = 0
    /// 1-based page number.
    var page: Int = 1
    /// Part title.
    var part: String = ""
    /// Seconds.
    var duration: Int = 0
    var width: Int = 0
    var height: Int = 0
    /// 1 means width/height are swapped (the stream is rotated).
    var rotate: Int = 0
    var firstFrame: String = ""

    init(cid: Int64, page: Int = 1, part: String = "", duration: Int = 0) {
        self.cid = cid
        self.page = page
        self.part = part
        self.duration = duration
    }

    init(json: JSON) {
        cid = json["cid"].int64Value
        page = json["page"].int ?? 1
        part = json["part"].stringValue
        duration = json["duration"].intValue
        width = json[path: "dimension.width"].intValue
        height = json[path: "dimension.height"].intValue
        rotate = json[path: "dimension.rotate"].intValue
        firstFrame = json["first_frame"].stringValue.biliHTTPS
    }

    /// Display size after applying `rotate`.
    var displayWidth: Int { rotate == 1 ? height : width }
    var displayHeight: Int { rotate == 1 ? width : height }
    var isVertical: Bool { displayHeight > displayWidth }
}

/// One episode of a UGC season (合集) — `ugc_season.sections[].episodes[]`.
struct UgcEpisode: Hashable, Identifiable {
    /// Episode id inside the season (falls back to aid).
    var id: Int64 = 0
    var sectionId: Int64 = 0
    var aid: Int64 = 0
    var bvid: String = ""
    var cid: Int64 = 0
    var title: String = ""
    var cover: String = ""
    /// Seconds.
    var duration: Int = 0
    var badge: String = ""
    var viewCount: Int64 = 0
    var danmakuCount: Int64 = 0
    var pubdate: Int64 = 0
    var ownerMid: Int64 = 0
    var ownerName: String = ""
    var ownerFace: String = ""
    /// Number of parts of this episode's archive.
    var pageCount: Int = 1

    init() {}

    init(json: JSON) {
        aid = json["aid"].int64 ?? json[path: "arc.aid"].int64Value
        id = json["id"].int64 ?? aid
        sectionId = json["section_id"].int64Value
        bvid = json["bvid"].stringValue
        if bvid.isEmpty { bvid = json[path: "arc.bvid"].stringValue }
        if bvid.isEmpty, aid > 0 { bvid = BVConverter.av2bv(aid) }
        cid = json["cid"].int64 ?? json[path: "page.cid"].int64Value
        let arc = json["arc"]
        title = json["title"].stringValue
        if title.isEmpty { title = arc["title"].stringValue }
        cover = arc["pic"].stringValue.biliHTTPS
        if cover.isEmpty { cover = json["cover"].stringValue.biliHTTPS }
        duration = arc["duration"].int ?? json[path: "page.duration"].intValue
        badge = json["badge"].stringValue
        viewCount = arc[path: "stat.view"].int64Value
        danmakuCount = arc[path: "stat.danmaku"].int64Value
        pubdate = arc["pubdate"].int64Value
        ownerMid = arc[path: "author.mid"].int64Value
        ownerName = arc[path: "author.name"].stringValue
        ownerFace = arc[path: "author.face"].stringValue.biliHTTPS
        pageCount = max(1, json["pages"].arrayValue.count)
    }

    var videoRef: VideoRef { VideoRef(aid: aid, bvid: bvid, cid: cid, title: title, cover: cover) }
}

struct UgcSeasonSection: Hashable, Identifiable {
    var id: Int64 = 0
    var title: String = ""
    var episodes: [UgcEpisode] = []

    init() {}

    init(json: JSON) {
        id = json["id"].int64Value
        title = json["title"].stringValue
        episodes = json["episodes"].arrayValue.map(UgcEpisode.init(json:))
    }
}

/// UGC season (合集) attached to a video (`data.ugc_season`).
struct UgcSeason: Hashable, Identifiable {
    var id: Int64 = 0
    var title: String = ""
    var cover: String = ""
    var mid: Int64 = 0
    var intro: String = ""
    var sections: [UgcSeasonSection] = []
    /// `ep_count` (falls back to the number of parsed episodes).
    var episodeCount: Int = 0

    init() {}

    init(json: JSON) {
        id = json["id"].int64Value
        title = json["title"].stringValue
        cover = json["cover"].stringValue.biliHTTPS
        mid = json["mid"].int64Value
        intro = json["intro"].stringValue
        sections = json["sections"].arrayValue.map(UgcSeasonSection.init(json:))
        episodeCount = json["ep_count"].int ?? sections.reduce(0) { $0 + $1.episodes.count }
    }

    var allEpisodes: [UgcEpisode] { sections.flatMap(\.episodes) }

    /// Index of the section containing `aid` (0 when not found).
    func sectionIndex(containing aid: Int64) -> Int {
        sections.firstIndex { $0.episodes.contains { $0.aid == aid } } ?? 0
    }
}

/// Full UGC detail.
struct VideoDetail: Identifiable, Hashable {
    struct Staff: Hashable, Identifiable {
        var id: Int64 { user.mid }
        var user: UserBrief
        /// Role, e.g. "UP主", "剪辑".
        var title: String
    }

    struct Rights: Hashable {
        /// Interactive video (互动视频).
        var isSteinGate = false
        /// 未经作者授权禁止转载.
        var noReprint = false
        /// Joint submission (联合投稿).
        var isCooperation = false
        /// Paid (UGC pay / charging-exclusive) video.
        var isPaid = false
        var is360 = false
    }

    var id: Int64 { aid }
    var aid: Int64 = 0
    var bvid: String = ""
    /// First part's cid.
    var cid: Int64 = 0
    var title: String = ""
    var desc: String = ""
    var cover: String = ""
    /// Unix seconds.
    var pubdate: Int64 = 0
    var ctime: Int64 = 0
    /// Seconds (whole archive).
    var duration: Int = 0
    var tid: Int = 0
    var tname: String = ""
    /// 1 = original (自制), 2 = repost (转载).
    var copyright: Int = 1
    var owner = UserBrief(mid: 0)
    var stat = VideoStat()
    var pages: [VideoPart] = []
    var ugcSeason: UgcSeason? = nil
    var staff: [Staff] = []
    var rights = Rights()
    /// Charging-exclusive (充电专属).
    var isUpowerExclusive = false
    /// Non-empty for PGC content opened through a BV link.
    var redirectURL: String = ""
    /// Parsed from `redirect_url` (`…/ep123`), non-zero → open the PGC flow.
    var redirectEpId: Int64 = 0
    var redirectSeasonId: Int64 = 0
    /// `honor_reply.honor[].desc`, e.g. "全站排行榜最高第3名".
    var honors: [String] = []
    /// Controversy banner (`argue_info.argue_msg`).
    var argueText: String = ""
    /// Filled by `VideoAPI.tags` (the view endpoint carries none).
    var tags: [String] = []
    var width: Int = 0
    var height: Int = 0
    var rotate: Int = 0
    /// `pub_location` (IP属地), may be empty.
    var pubLocation: String = ""

    init() {}

    init(json: JSON) {
        aid = json["aid"].int64Value
        bvid = json["bvid"].stringValue
        if bvid.isEmpty, aid > 0 { bvid = BVConverter.av2bv(aid) }
        if aid == 0, !bvid.isEmpty { aid = BVConverter.bv2av(bvid) ?? 0 }
        cid = json["cid"].int64Value
        title = json["title"].stringValue
        desc = json["desc"].stringValue
        if desc.isEmpty || desc == "-" {
            let v2 = json["desc_v2"].arrayValue.map { $0["raw_text"].stringValue }.joined()
            if !v2.isEmpty { desc = v2 }
        }
        cover = json["pic"].stringValue.biliHTTPS
        pubdate = json["pubdate"].int64Value
        ctime = json["ctime"].int64Value
        duration = json["duration"].intValue
        tid = json["tid"].intValue
        tname = json["tname"].stringValue
        copyright = json["copyright"].int ?? 1
        let o = json["owner"]
        owner = UserBrief(mid: o["mid"].int64Value, name: o["name"].stringValue, face: o["face"].stringValue.biliHTTPS)
        stat = VideoStat(json: json["stat"])
        pages = json["pages"].arrayValue.map(VideoPart.init(json:))
        if cid == 0 { cid = pages.first?.cid ?? 0 }
        if json["ugc_season"]["id"].int64Value != 0 { ugcSeason = UgcSeason(json: json["ugc_season"]) }
        staff = json["staff"].arrayValue.map { s in
            var u = UserBrief(mid: s["mid"].int64Value, name: s["name"].stringValue, face: s["face"].stringValue.biliHTTPS)
            u.vipLabel = s[path: "vip.label.text"].stringValue
            u.fans = s["follower"].int64Value
            u.isFollowed = s["attention"].boolValue
            return Staff(user: u, title: s["title"].stringValue)
        }
        let r = json["rights"]
        rights = Rights(isSteinGate: r["is_stein_gate"].boolValue,
                        noReprint: r["no_reprint"].boolValue,
                        isCooperation: r["is_cooperation"].boolValue,
                        isPaid: r["ugc_pay"].boolValue || r["arc_pay"].boolValue || r["pay"].boolValue,
                        is360: r["is_360"].boolValue)
        isUpowerExclusive = json["is_upower_exclusive"].boolValue
        redirectURL = json["redirect_url"].stringValue
        if let ids = VideoDetail.parsePGCLink(redirectURL) {
            redirectEpId = ids.epId
            redirectSeasonId = ids.seasonId
        }
        honors = json[path: "honor_reply.honor"].arrayValue.map { $0["desc"].stringValue }.filter { !$0.isEmpty }
        argueText = json[path: "argue_info.argue_msg"].stringValue
        width = json[path: "dimension.width"].intValue
        height = json[path: "dimension.height"].intValue
        rotate = json[path: "dimension.rotate"].intValue
        pubLocation = json["pub_location"].stringValue
    }

    var honorText: String? { honors.first }
    /// PGC content behind a BV link (open `PGCSeason` with `redirectEpId`/`redirectSeasonId`).
    var isPGCRedirect: Bool { redirectEpId != 0 || redirectSeasonId != 0 }
    var isOriginal: Bool { copyright == 1 }
    /// Coins a viewer may give (2 for original works, 1 for reposts).
    var maxCoins: Int { copyright == 1 ? 2 : 1 }
    var isVertical: Bool {
        let (w, h) = rotate == 1 ? (height, width) : (width, height)
        return h > w
    }

    /// Part for `cid` (or the first part).
    func part(for cid: Int64) -> VideoPart? { pages.first { $0.cid == cid } ?? pages.first }

    /// Extracts `ep`/`ss` ids from links like `https://www.bilibili.com/bangumi/play/ep123456`.
    static func parsePGCLink(_ url: String) -> (epId: Int64, seasonId: Int64)? {
        guard !url.isEmpty else { return nil }
        var ep: Int64 = 0, ss: Int64 = 0
        if let r = url.range(of: #"(?<![A-Za-z])ep\d+"#, options: .regularExpression) {
            ep = Int64(url[r].dropFirst(2)) ?? 0
        }
        if let r = url.range(of: #"(?<![A-Za-z])ss\d+"#, options: .regularExpression) {
            ss = Int64(url[r].dropFirst(2)) ?? 0
        }
        if ep == 0, ss == 0 { return nil }
        return (ep, ss)
    }
}

// MARK: - Interaction state

/// `/x/web-interface/archive/relation` (UGC) or `/pgc/season/episode/community` (PGC).
struct VideoRelation: Hashable {
    var liked = false
    var disliked = false
    /// Coins the current user has given (0–2).
    var coinCount = 0
    var favored = false
    /// Following the uploader.
    var followingUp = false
    /// Subscribed to the UGC season (合集).
    var seasonFav = false

    init() {}

    init(liked: Bool, disliked: Bool = false, coinCount: Int, favored: Bool, followingUp: Bool = false, seasonFav: Bool = false) {
        self.liked = liked
        self.disliked = disliked
        self.coinCount = coinCount
        self.favored = favored
        self.followingUp = followingUp
        self.seasonFav = seasonFav
    }

    /// UGC `archive/relation` data.
    init(json: JSON) {
        liked = json["like"].boolValue
        disliked = json["dislike"].boolValue
        coinCount = json["coin"].intValue
        favored = json["favorite"].boolValue
        followingUp = json["attention"].boolValue
        seasonFav = json["season_fav"].boolValue
    }

    /// PGC `episode/community` data.
    init(pgcJSON json: JSON) {
        liked = json["like"].boolValue
        coinCount = json["coin_number"].intValue
        favored = json["favorite"].boolValue
    }
}

/// A favourite folder with the membership state of one resource.
struct FavFolderState: Hashable, Identifiable {
    /// `media_id` used by fav/resource/deal.
    var id: Int64
    var title: String
    var count: Int
    var isFavorited: Bool
    var isDefault: Bool
    var isPrivate: Bool = false
    var cover: String = ""

    init(id: Int64, title: String, count: Int, isFavorited: Bool, isDefault: Bool, isPrivate: Bool = false, cover: String = "") {
        self.id = id
        self.title = title
        self.count = count
        self.isFavorited = isFavorited
        self.isDefault = isDefault
        self.isPrivate = isPrivate
        self.cover = cover
    }

    /// `list[]` item of `/x/v3/fav/folder/created/list-all`. `attr` bit 0 = private, bit 1 = 0 for the default folder.
    init(json: JSON, index: Int = 0) {
        id = json["id"].int64Value
        title = json["title"].stringValue
        count = json["media_count"].intValue
        isFavorited = json["fav_state"].intValue == 1
        if let attr = json["attr"].int {
            isDefault = attr & 2 == 0
            isPrivate = attr & 1 == 1
        } else {
            isDefault = index == 0
        }
        cover = json["cover"].stringValue.biliHTTPS
    }
}

// MARK: - Player side data (`/x/player/wbi/v2`)

struct PlayerExtraInfo: Hashable {
    /// Sorted: Chinese first, human-made before AI.
    var subtitles: [SubtitleTrack] = []
    /// Only filled when the server marks them as chapters (`view_points[0].type == 2`).
    var chapters: [VideoChapter] = []
    /// Seconds (server `last_play_time` is ms). 0 = none.
    var lastPlayTime: Double = 0
    var lastPlayCid: Int64 = 0
    /// Server says subtitles exist but require login (`need_login_subtitle`).
    var needLoginSubtitle: Bool = false
    /// e.g. "3人在看" when `online_count` is present.
    var onlineHint: String? = nil
    /// Interactive-video graph version (0 if not interactive).
    var steinGraphVersion: Int64 = 0
    /// Charging preview toast (`preview_toast`) when `is_ugc_pay_preview`.
    var previewToast: String? = nil

    init() {}
}

/// Seek-preview sprite sheet (`/x/player/videoshot`).
struct VideoShotInfo: Hashable {
    /// Sprite sheet URLs (https).
    var images: [String] = []
    /// Timestamps (seconds) of each tile, across all sheets.
    var index: [Double] = []
    /// Tiles per row / column in one sheet.
    var columns: Int = 10
    var rows: Int = 10
    /// Size of one tile in pixels.
    var tileWidth: Int = 160
    var tileHeight: Int = 90

    var isEmpty: Bool { images.isEmpty || index.isEmpty }

    /// Tile for `time`: (sheet URL, column, row) or nil.
    func tile(at time: Double) -> (image: String, column: Int, row: Int)? {
        guard !isEmpty, columns > 0, rows > 0 else { return nil }
        var i = 0
        // Last index whose timestamp <= time.
        var lo = 0, hi = index.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if index[mid] <= time { i = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let perSheet = columns * rows
        let sheet = i / perSheet
        guard sheet < images.count else { return nil }
        let inSheet = i % perSheet
        return (images[sheet], inSheet % columns, inSheet / columns)
    }
}

/// PGC opening/ending/other clip from `video_info.clip_info_list`.
struct PGCClipInfo: Hashable {
    enum Kind: String, Hashable { case opening, ending, other }
    /// Seconds.
    var start: Double
    var end: Double
    var kind: Kind
    /// Raw `clipType`, e.g. "CLIP_TYPE_OP".
    var rawType: String

    init(start: Double, end: Double, rawType: String) {
        self.start = start
        self.end = end
        self.rawType = rawType
        switch rawType.uppercased() {
        case "CLIP_TYPE_OP": kind = .opening
        case "CLIP_TYPE_ED": kind = .ending
        default: kind = .other
        }
    }
}

// MARK: - PGC (bangumi / movie / documentary …)

struct PGCEpisode: Hashable, Identifiable {
    var id: Int64 { epId }
    var epId: Int64 = 0
    var aid: Int64 = 0
    var bvid: String = ""
    var cid: Int64 = 0
    /// Short title, e.g. "1".
    var title: String = ""
    var longTitle: String = ""
    /// e.g. "第1话 出发"; may be empty.
    var showTitle: String = ""
    var cover: String = ""
    /// "会员" / "限免" / "预告" …
    var badge: String = ""
    /// Seconds (the API sends ms for PGC, s for PUGV).
    var duration: Int = 0
    /// Trailer / PV (预告).
    var isPreview: Bool = false
    /// `status == 13` (会员专享) or a 会员 badge.
    var isVipOnly: Bool = false
    var status: Int = 0
    /// Unix seconds.
    var pubTime: Int64 = 0
    var link: String = ""
    var width: Int = 0
    var height: Int = 0
    var rotate: Int = 0

    init() {}

    init(json: JSON, durationInMilliseconds: Bool = true) {
        epId = json["ep_id"].int64 ?? json["id"].int64Value
        if epId == 0 { epId = json["id"].int64Value }
        aid = json["aid"].int64Value
        bvid = json["bvid"].stringValue
        if bvid.isEmpty, aid > 0 { bvid = BVConverter.av2bv(aid) }
        cid = json["cid"].int64Value
        title = json["title"].stringValue
        longTitle = json["long_title"].stringValue
        showTitle = json["show_title"].stringValue
        cover = json["cover"].stringValue.biliHTTPS
        badge = json["badge"].stringValue
        if badge.isEmpty { badge = json[path: "badge_info.text"].stringValue }
        let rawDuration = json["duration"].int64Value
        duration = Int(durationInMilliseconds ? rawDuration / 1000 : rawDuration)
        status = json["status"].intValue
        isPreview = badge.contains("预告")
        isVipOnly = status == 13 || badge.contains("会员")
        pubTime = json["pub_time"].int64 ?? json["release_date"].int64Value
        link = json["link"].stringValue
        width = json[path: "dimension.width"].intValue
        height = json[path: "dimension.height"].intValue
        rotate = json[path: "dimension.rotate"].intValue
    }

    /// Title for lists: `show_title`, else "title longTitle", numeric titles become "第N话".
    var displayTitle: String {
        if !showTitle.isEmpty { return showTitle }
        let head = Int(title) != nil ? "第\(title)话" : title
        return longTitle.isEmpty ? head : (head.isEmpty ? longTitle : "\(head) \(longTitle)")
    }

    func videoRef(seasonId: Int64) -> VideoRef {
        VideoRef(aid: aid, bvid: bvid, cid: cid, epId: epId, seasonId: seasonId, title: displayTitle, cover: cover)
    }
}

/// Extra section (PV / 花絮 / OP …) of a season — `result.section[]`.
struct PGCSection: Hashable, Identifiable {
    var id: Int64 = 0
    var title: String = ""
    var type: Int = 0
    var episodes: [PGCEpisode] = []

    init() {}

    init(json: JSON, durationInMilliseconds: Bool = true) {
        id = json["id"].int64Value
        title = json["title"].stringValue
        type = json["type"].intValue
        let isTrailerSection = title.contains("预告")
        episodes = json["episodes"].arrayValue.map {
            var e = PGCEpisode(json: $0, durationInMilliseconds: durationInMilliseconds)
            if isTrailerSection { e.isPreview = true }
            return e
        }
    }
}

/// `/pgc/view/web/season` → result.
struct PGCSeason: Identifiable, Hashable {
    struct Stat: Hashable {
        var views: Int64 = 0
        var danmakus: Int64 = 0
        var coins: Int64 = 0
        var likes: Int64 = 0
        /// Series followers (追番/追剧).
        var favorites: Int64 = 0
        /// Favourites (收藏).
        var favorite: Int64 = 0
        var reply: Int64 = 0
        var share: Int64 = 0
        /// e.g. "123.4万追番" when provided.
        var followText: String = ""
    }

    struct Rating: Hashable {
        var score: Double = 0
        var count: Int64 = 0
    }

    struct UserStatus: Hashable {
        var follow = false
        var progressEpId: Int64 = 0
        /// Seconds.
        var progressTime: Double = 0
        var isVip = false
        var isPaid = false
        var areaLimited = false
    }

    /// Another season of the same series (`result.seasons[]`).
    struct SeasonLink: Hashable, Identifiable {
        var id: Int64 { seasonId }
        var seasonId: Int64
        var mediaId: Int64
        var title: String
        var cover: String
    }

    var id: Int64 { seasonId }
    var seasonId: Int64 = 0
    var mediaId: Int64 = 0
    var title: String = ""
    var seasonTitle: String = ""
    var subtitle: String = ""
    var cover: String = ""
    var evaluate: String = ""
    /// 1 番剧, 2 电影, 3 纪录片, 4 国创, 5 电视剧, 7 综艺.
    var type: Int = 1
    var areas: [String] = []
    var styles: [String] = []
    var actors: String = ""
    var stat = Stat()
    var rating: Rating? = nil
    /// `new_ep.desc`, e.g. "已完结, 全12话" / "连载中, 每周六更新".
    var newEpDesc: String = ""
    var publishTime: String = ""
    var isFinished = false
    var upInfo: UserBrief? = nil
    var episodes: [PGCEpisode] = []
    var sections: [PGCSection] = []
    var seasons: [SeasonLink] = []
    var userStatus = UserStatus()
    var shareURL: String = ""

    init() {}

    init(json: JSON, durationInMilliseconds: Bool = true) {
        seasonId = json["season_id"].int64Value
        mediaId = json["media_id"].int64Value
        title = json["title"].stringValue
        seasonTitle = json["season_title"].stringValue
        subtitle = json["subtitle"].stringValue
        cover = json["cover"].stringValue.biliHTTPS
        evaluate = json["evaluate"].stringValue
        type = json["type"].int ?? 1
        areas = json["areas"].arrayValue.map { $0["name"].stringValue }.filter { !$0.isEmpty }
        styles = json["styles"].arrayValue.compactMap { $0.string ?? $0["name"].string }.filter { !$0.isEmpty }
        actors = json["actors"].stringValue
        let s = json["stat"]
        stat = Stat(views: s["views"].int64 ?? s["view"].int64Value,
                    danmakus: s["danmakus"].int64 ?? s["danmaku"].int64Value,
                    coins: s["coins"].int64 ?? s["coin"].int64Value,
                    likes: s["likes"].int64 ?? s["like"].int64Value,
                    favorites: s["favorites"].int64Value,
                    favorite: s["favorite"].int64Value,
                    reply: s["reply"].int64Value,
                    share: s["share"].int64Value,
                    followText: s["follow_text"].stringValue)
        if json["rating"].exists {
            rating = Rating(score: json[path: "rating.score"].doubleValue, count: json[path: "rating.count"].int64Value)
        }
        newEpDesc = json[path: "new_ep.desc"].stringValue
        publishTime = json[path: "publish.pub_time_show"].stringValue
        isFinished = json[path: "publish.is_finish"].boolValue
        let up = json["up_info"]
        if up["mid"].int64Value != 0 {
            upInfo = UserBrief(mid: up["mid"].int64Value, name: up["uname"].stringValue, face: up["avatar"].stringValue.biliHTTPS)
        }
        episodes = json["episodes"].arrayValue.map { PGCEpisode(json: $0, durationInMilliseconds: durationInMilliseconds) }
        sections = json["section"].arrayValue.map { PGCSection(json: $0, durationInMilliseconds: durationInMilliseconds) }
        seasons = json["seasons"].arrayValue.map {
            SeasonLink(seasonId: $0["season_id"].int64Value, mediaId: $0["media_id"].int64Value,
                       title: $0["season_title"].string ?? $0["title"].stringValue,
                       cover: $0["cover"].stringValue.biliHTTPS)
        }
        let us = json["user_status"]
        userStatus = UserStatus(follow: (us["follow"].bool ?? us["favored"].bool) ?? false,
                                progressEpId: us[path: "progress.last_ep_id"].int64Value,
                                progressTime: us[path: "progress.last_time"].doubleValue,
                                isVip: us["vip"].boolValue || us[path: "vip_info.status"].intValue == 1,
                                isPaid: us["pay"].boolValue,
                                areaLimited: us["area_limit"].boolValue)
        shareURL = json["share_url"].stringValue
    }

    var typeName: String {
        switch type {
        case 1: return "番剧"
        case 2: return "电影"
        case 3: return "纪录片"
        case 4: return "国创"
        case 5: return "电视剧"
        case 7: return "综艺"
        default: return "番剧"
        }
    }

    /// Bangumi / 国创 use "追番", others "追剧".
    var followVerb: String { type == 1 || type == 4 ? "追番" : "追剧" }

    var allEpisodes: [PGCEpisode] { episodes + sections.flatMap(\.episodes) }

    func episode(withId epId: Int64) -> PGCEpisode? { allEpisodes.first { $0.epId == epId } }

    /// Episode to open: the requested one, else the watch progress, else the first main / section episode.
    func defaultEpisode(preferredEpId: Int64 = 0) -> PGCEpisode? {
        if preferredEpId != 0, let e = episode(withId: preferredEpId) { return e }
        if userStatus.progressEpId != 0, let e = episode(withId: userStatus.progressEpId) { return e }
        return episodes.first ?? sections.first?.episodes.first
    }
}
