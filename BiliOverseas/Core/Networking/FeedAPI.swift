import Foundation

/// One issue of 每周必看.
struct PopularWeeklyIssue: Identifiable, Hashable {
    var id: Int { number }
    var number: Int
    /// e.g. "2024第1期".
    var name: String
    /// Theme of the issue, when present.
    var subject: String = ""
}

/// One 不感兴趣 / 反馈 option of an app-feed card (`three_point_v2[].reasons[]`).
struct FeedDislikeReason: Identifiable, Hashable {
    var id: Int64
    var name: String
    /// What the official client toasts after it was chosen.
    var toast: String = ""
    /// A `feedback` reason (sent as `feedback_id`) rather than a `dislike` one (`reason_id`).
    var isFeedback: Bool = false
}

/// What 不感兴趣 tells the feed about a card: its `goto` / id and the reasons it offers. App-feed cards
/// (`card_goto` / `param`) are reported with the TV-login `access_key`, web-feed cards with the cookies.
struct FeedCardFeedback: Hashable {
    enum Source: Hashable { case app, web }

    var goto: String
    var param: Int64
    var reasons: [FeedDislikeReason] = []
    var feedbacks: [FeedDislikeReason] = []
    var source: Source = .app
    /// Web feed only: the card's `track_id` and its UP's mid, which bilibili.com sends back with it.
    var trackId: String = ""
    var mid: Int64 = 0

    var isEmpty: Bool { reasons.isEmpty && feedbacks.isEmpty }
}

/// Home feeds: 推荐 (app / web), 热门, 排行榜, 每周必看, 入站必刷.
enum FeedAPI {
    // MARK: - Recommend (web)

    /// Web home recommend feed. `cursor` is the previous page's `next` (nil = refresh, starts a new
    /// brush). The feed never ends. Ad / promotion / live / PGC cards are kept but typed
    /// (`kind`, `adSignals`, spec §1.5) so `FeedFilter` decides what to hide.
    static func recommend(cursor: String?, pageSize: Int = 20) async throws -> Page<VideoCard> {
        let idx = max(0, Int(cursor ?? "") ?? 0)
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/wbi/index/top/feed/rcmd",
            query: [
                "version": 1, "feed_version": "V8", "homepage_ver": 1, "ps": pageSize,
                "fresh_type": 4, "fresh_idx": idx, "fresh_idx_1h": idx, "brush": idx,
                "web_location": 1430650,
            ],
            sign: .wbi)
        return parseRecommend(data, freshIdx: idx)
    }

    /// Whether 推荐 asks the app feed first. It is personalised only by a TV-login `access_key`: with
    /// just a web (cookie) login it would come back anonymous, so the cookie-personalised web feed goes
    /// first then. Signed out, both are anonymous and the app feed offers more (sizes, 不感兴趣 reasons).
    static func prefersAppFeed(useAppFeed: Bool, hasAppToken: Bool, isLoggedIn: Bool) -> Bool {
        useAppFeed && (hasAppToken || !isLoggedIn)
    }

    // MARK: - Video sizes

    /// Fills `width` / `height` of the video cards that came without them (web 推荐 carries no sizes),
    /// so portrait videos open 短视频 from either feed: one `x/article/cards` request per 40 cards.
    /// Best effort: cards the lookup misses come back unchanged.
    static func fillVideoSizes(_ cards: [VideoCard]) async -> [VideoCard] {
        let ids = Array(Set(cards.compactMap(sizeLookupID)))
        guard !ids.isEmpty else { return cards }
        var sizes: [String: (width: Int, height: Int)] = [:]
        for start in stride(from: 0, to: ids.count, by: 40) {
            let chunk = ids[start..<min(start + 40, ids.count)]
            guard let data = try? await BiliHTTP.shared.api(BiliHost.api + "/x/article/cards",
                                                         query: ["ids": chunk.joined(separator: ",")], timeout: 5)
            else { continue }
            sizes.merge(videoSizes(data)) { _, new in new }
        }
        return applyVideoSizes(sizes, to: cards)
    }

    /// The id `x/article/cards` takes for a video card that still needs its size; nil otherwise.
    static func sizeLookupID(_ card: VideoCard) -> String? {
        guard card.kind == .video, card.width == 0 || card.height == 0 else { return nil }
        if !card.bvid.isEmpty { return card.bvid }
        return card.aid != 0 ? "av\(card.aid)" : nil
    }

    /// `x/article/cards` `data` (keyed by the requested `BV…` / `av…` id) → display sizes, rotation applied.
    static func videoSizes(_ data: JSON) -> [String: (width: Int, height: Int)] {
        var out: [String: (width: Int, height: Int)] = [:]
        for (id, card) in data.objectValue {
            let w = card[path: "dimension.width"].intValue, h = card[path: "dimension.height"].intValue
            guard w > 0, h > 0 else { continue }
            out[id] = card[path: "dimension.rotate"].intValue == 1 ? (h, w) : (w, h)
        }
        return out
    }

    static func applyVideoSizes(_ sizes: [String: (width: Int, height: Int)], to cards: [VideoCard]) -> [VideoCard] {
        cards.map { card in
            guard let id = sizeLookupID(card), let size = sizes[id] else { return card }
            var c = card
            c.width = size.width
            c.height = size.height
            return c
        }
    }

    /// `data` of the web rcmd endpoint → cards. `next` = freshIdx + 1.
    static func parseRecommend(_ data: JSON, freshIdx: Int = 0) -> Page<VideoCard> {
        var cards: [VideoCard] = []
        for (i, item) in data["item"].arrayValue.enumerated() {
            if let c = recommendCard(item, position: "\(freshIdx)-\(i)") { cards.append(c) }
        }
        return Page(items: cards, hasMore: true, next: String(freshIdx + 1))
    }

    /// One `data.item[]` entry. `position` makes ids of id-less cards (ads) unique.
    static func recommendCard(_ item: JSON, position: String) -> VideoCard? {
        let goto = item["goto"].stringValue
        let business = item["business_info"]
        var signals: [String] = []
        if goto == "ad" { signals.append("goto=ad") }
        if ListMapping.hasPayload(business) { signals.append("business_info") }

        var c = VideoCard(id: "")
        c.title = item["title"].stringValue
        c.cover = ListMapping.image(item["pic"])
        c.duration = ListMapping.duration(item["duration"])
        c.pubdate = item["pubdate"].int64Value
        c.cid = item["cid"].int64Value
        ListMapping.applyOwner(&c, item["owner"])
        c.viewCount = ListMapping.count(item["stat"]["view"])
        c.likeCount = ListMapping.count(item["stat"]["like"])
        c.danmakuCount = ListMapping.count(item["stat"]["danmaku"])
        c.reason = item["rcmd_reason"].object != nil ? item["rcmd_reason"]["content"].stringValue : item["rcmd_reason"].stringValue
        c.isFollowed = item["is_followed"].intValue == 1
        c.uri = item["uri"].stringValue

        switch goto {
        case "live" where signals.isEmpty:
            let room = item["room_info"]
            c.kind = .live
            c.roomId = room["room_id"].int64 ?? item["id"].int64Value
            if c.roomId == 0 { c.roomId = ListMapping.firstCapture(#"live\.bilibili\.com/(\d+)"#, in: c.uri).flatMap { Int64($0) } ?? 0 }
            c.id = "live-\(c.roomId)"
            if c.ownerMid == 0 { c.ownerMid = room["uid"].int64Value }
            c.badge = room["live_status"].int.map { $0 == 1 ? "直播中" : "直播" } ?? "直播"
            let watched = room["watched_show"]
            if c.viewCount == 0 { c.viewCount = ListMapping.count(watched["num"]) }
            if c.reason.isEmpty { c.reason = watched["text_large"].stringValue }
            if c.uri.isEmpty, c.roomId != 0 { c.uri = "https://live.bilibili.com/\(c.roomId)" }
        case "ogv" where signals.isEmpty:
            let ep = ListMapping.epId(inURL: c.uri)
            let ss = ListMapping.seasonId(inURL: c.uri)
            let ogv = item["ogv_info"]
            c.epId = ep != 0 ? ep : ogv["ep_id"].int64Value
            c.seasonId = ss != 0 ? ss : ogv["season_id"].int64Value
            if c.epId != 0 || c.seasonId != 0 {
                c.kind = .bangumi
                c.id = c.epId != 0 ? "ep\(c.epId)" : "ss\(c.seasonId)"
            } else {
                c.kind = .other
                c.id = "ogv-\(position)"
            }
            if c.badge.isEmpty { c.badge = ogv["badge"].string ?? "番剧" }
        default:
            let isVideoGoto = goto == "av" || goto.isEmpty
            if isVideoGoto {
                ListMapping.applyIDs(&c, aid: item["id"].int64 ?? item["aid"].int64Value, bvid: item["bvid"].stringValue)
            } else {
                // For ads / banners / unknown cards `id` is not an aid: only trust a real bvid.
                ListMapping.applyIDs(&c, aid: 0, bvid: item["bvid"].stringValue)
            }
            if !signals.isEmpty {
                c.kind = .ad
                c.adSignals = signals
                // Real ads carry their creative in business_info; creative-promotion (创作推广) cards
                // are genuine videos, so keep their ids playable.
                if c.title.isEmpty { c.title = business["title"].stringValue }
                if c.cover.isEmpty { c.cover = ListMapping.image(business["pic"]) }
                if c.uri.isEmpty { c.uri = business["url"].stringValue }
                if c.badge.isEmpty {
                    let mark = business["business_mark"]["text"].stringValue
                    c.badge = !mark.isEmpty ? mark : (goto == "ad" ? "广告" : "推广")
                }
                let creative = business["id"].int64Value
                c.id = (c.id.isEmpty ? "ad" : "ad-\(c.id)") + "-\(position)" + (creative != 0 ? "-\(creative)" : "")
            } else if isVideoGoto {
                c.kind = .video
                if c.id.isEmpty { return nil }
            } else {
                c.kind = .other
                c.id = c.id.isEmpty ? "\(goto.isEmpty ? "card" : goto)-\(position)" : "\(goto)-\(c.id)"
            }
        }
        if c.title.isEmpty && c.cover.isEmpty { return nil }
        // 不感兴趣 as bilibili.com offers it on videos and live rooms (ads take another form).
        let feedbackID = c.kind == .video ? c.aid : c.kind == .live ? c.roomId : 0
        if feedbackID != 0 {
            c.feedback = FeedCardFeedback(goto: c.kind == .live ? "live" : "av", param: feedbackID,
                                          reasons: webDislikeReasons, source: .web,
                                          trackId: item["track_id"].stringValue, mid: c.ownerMid)
        }
        return c
    }

    /// The 不感兴趣 reasons bilibili.com's home page offers (fixed in the page, not sent by the server).
    static let webDislikeReasons = [
        FeedDislikeReason(id: 1, name: "内容不感兴趣", toast: "将减少此类内容推荐"),
        FeedDislikeReason(id: 4, name: "不想看此UP主", toast: "将减少此类内容推荐"),
    ]

    /// The form bilibili.com's home page posts for 不感兴趣 and its 撤销 (`BiliHTTP.post` adds csrf).
    static func webDislikeForm(_ feedback: FeedCardFeedback, reason: FeedDislikeReason) -> [String: Any] {
        [
            "app_id": 100, "platform": 5, "from_spmid": "", "spmid": "333.1007.0.0", "goto": feedback.goto,
            "id": feedback.param, "mid": feedback.mid, "track_id": feedback.trackId, "feedback_page": 1,
            "reason_id": reason.id,
        ]
    }

    /// Whether 不感兴趣 can be reported for a card: web-feed cards need the web login (cookies),
    /// app-feed cards the TV-login `access_key`. Otherwise the menu only hides the card here.
    static func canReport(_ feedback: FeedCardFeedback, isLoggedIn: Bool, hasAppToken: Bool) -> Bool {
        feedback.source == .web ? isLoggedIn : hasAppToken
    }

    static func canReport(_ feedback: FeedCardFeedback) -> Bool {
        canReport(feedback, isLoggedIn: BiliHTTP.shared.isLoggedIn, hasAppToken: appAuth() != nil)
    }

    // MARK: - Recommend (app)

    /// App home feed (`app.bilibili.com/x/v2/feed/index`, api-lists §2.2). Unlike the web feed it
    /// carries zone names (分区屏蔽), 不感兴趣 reasons and the 「已关注」 mark. `cursor` is the previous
    /// page's `next` (nil = refresh); the feed never ends. App-signed; a TV-login `access_key`
    /// personalises it and is signed with the appkey it was minted for. Ads stay in, typed (§1.5).
    static func appRecommend(cursor: String?) async throws -> Page<VideoCard> {
        let idx = max(0, Int(cursor ?? "") ?? 0)
        var query: [String: Any] = [
            "build": ListMapping.appBuild, "c_locale": "zh_CN", "channel": "master", "column": 2,
            "device": "phone", "device_name": "android", "device_type": 0, "disable_rcmd": 0,
            "flush": 8, "fnval": 976, "fnver": 0, "force_host": 2, "fourk": 1, "guidance": 1,
            "https_url_req": 1, "idx": idx, "mobi_app": "android_i", "network": "wifi",
            "platform": "android", "player_net": 1, "pull": idx == 0 ? "true" : "false", "qn": 32,
            "recsys_mode": 0, "s_locale": "zh_CN", "splash_id": "", "statistics": ListMapping.appStatistics,
            "voice_balance": 0,
        ]
        var key = ListMapping.appKey
        if let auth = appAuth() {
            query["access_key"] = auth.token
            key = auth.key
        }
        let data = try await BiliHTTP.shared.api(BiliHost.app + "/x/v2/feed/index", query: query,
                                                 sign: .app(key), headers: appFeedHeaders())
        return parseAppRecommend(data, idx: idx)
    }

    /// `data` of the app feed → cards. `next` = idx + 1.
    static func parseAppRecommend(_ data: JSON, idx: Int = 0) -> Page<VideoCard> {
        var cards: [VideoCard] = []
        for (i, item) in data["items"].arrayValue.enumerated() {
            if let c = appRecommendCard(item, position: "app\(idx)-\(i)") { cards.append(c) }
        }
        return Page(items: cards, hasMore: true, next: String(idx + 1))
    }

    /// One `data.items[]` entry. Videos (`can_play == 1`), episodes and live rooms are kept; ads are
    /// kept but typed (`card_goto=ad_*`, `ad_info`, `card_type=cm_*`, `goto=ad`) so `FeedFilter`
    /// decides; articles, pictures, banners, specials and games are dropped (OURS: av / bangumi only).
    static func appRecommendCard(_ item: JSON, position: String) -> VideoCard? {
        let cardGoto = item["card_goto"].stringValue
        let cardType = item["card_type"].stringValue
        var signals: [String] = []
        if cardGoto.hasPrefix("ad") { signals.append("card_goto=\(cardGoto)") }
        if ListMapping.hasPayload(item["ad_info"]) { signals.append("ad_info") }
        if cardType.hasPrefix("cm") { signals.append("card_type=\(cardType)") }
        if item["goto"].stringValue == "ad" { signals.append("goto=ad") }

        let args = item["args"]
        let playerArgs = item["player_args"]
        let param = item["param"].int64Value
        var c = VideoCard(id: "")
        c.title = item["title"].stringValue
        c.cover = ListMapping.image(item["cover"])
        c.uri = item["uri"].stringValue
        c.desc = item["desc"].stringValue
        c.zone = args["tname"].stringValue
        c.ownerMid = args["up_id"].int64Value
        let upName = args["up_name"].stringValue
        c.ownerName = cardGoto == "av" && !upName.isEmpty ? upName : item["desc_button"]["text"].stringValue
        c.viewCount = ListMapping.count(item["cover_left_text_1"])
        c.danmakuCount = ListMapping.count(item["cover_left_text_2"])
        var reason = item["rcmd_reason"].object != nil ? item["rcmd_reason"]["content"].stringValue : item["rcmd_reason"].stringValue
        if reason == "竖屏" { reason = "" }
        // 「1万点赞」: the only like count this feed gives (used by 点赞率过滤).
        if reason.contains("赞") { c.likeCount = ListMapping.parseCount(reason) }
        c.isFollowed = FeedFilter.followedMarkers.contains(reason)
        c.reason = reason
        c.feedback = appFeedback(item["three_point_v2"], goto: cardGoto, param: param)

        if !signals.isEmpty {
            c.kind = .ad
            c.adSignals = signals
            ListMapping.applyIDs(&c, aid: playerArgs["aid"].int64Value, bvid: item["bvid"].stringValue)
            // `cm_*` creatives keep their title / image in `ad_info.creative_content` [unverified names].
            let creative = item["ad_info"]["creative_content"]
            if c.title.isEmpty { c.title = creative["title"].stringValue }
            if c.cover.isEmpty { c.cover = ListMapping.image(creative["image_url"]) }
            if c.uri.isEmpty { c.uri = creative["url"].stringValue }
            if c.badge.isEmpty { c.badge = "广告" }
            c.id = (c.id.isEmpty ? "ad" : "ad-\(c.id)") + "-\(position)"
            // An empty ad slot would be a blank, dead card when 屏蔽广告卡片 is off (like the web feed).
            return c.title.isEmpty && c.cover.isEmpty ? nil : c
        }
        switch cardGoto {
        case "av":
            guard (item["can_play"].int ?? 1) == 1 else { return nil }
            ListMapping.applyIDs(&c, aid: playerArgs["aid"].int64 ?? param, bvid: item["bvid"].stringValue)
            guard !c.id.isEmpty else { return nil }
            c.kind = .video
            c.cid = playerArgs["cid"].int64Value
            let seconds = playerArgs["duration"].intValue
            c.duration = seconds > 0 ? seconds : ListMapping.duration(item["cover_right_text"])
            (c.width, c.height) = appVideoSize(uri: c.uri)
        case "bangumi":
            guard param != 0 else { return nil }
            c.kind = .bangumi
            c.epId = param
            c.id = "ep\(param)"
            c.badge = item["cover_right_text"].stringValue
        case "live":
            var room = param
            if room == 0 { room = ListMapping.firstCapture(#"live(?:\.bilibili\.com)?/(\d+)"#, in: c.uri).flatMap { Int64($0) } ?? 0 }
            guard room != 0 else { return nil }
            c.kind = .live
            c.roomId = room
            c.id = "live-\(room)"
            c.badge = "直播"
            c.uri = "https://live.bilibili.com/\(room)"
        default:
            return nil
        }
        if c.title.isEmpty && c.cover.isEmpty { return nil }
        return c
    }

    /// Video size from an app-feed card's `uri` (`player_width` / `player_height` / `player_rotate`,
    /// rotation applied); (0, 0) when it has none.
    static func appVideoSize(uri: String) -> (width: Int, height: Int) {
        func value(_ name: String) -> Int { ListMapping.uriQueryValue(name, in: uri).flatMap { Int($0) } ?? 0 }
        let (w, h) = (value("player_width"), value("player_height"))
        guard w > 0, h > 0 else { return (0, 0) }
        return value("player_rotate") == 1 ? (h, w) : (w, h)
    }

    /// `three_point_v2[]` (`{type: dislike | feedback, reasons[{id, name, toast}]}`) → the card's
    /// 不感兴趣 menu, nil when it offers none. Reasons can share an id (every 「频道:…」 is 3) and the
    /// feed sometimes repeats one outright; the repeats are dropped.
    static func appFeedback(_ threePoint: JSON, goto: String, param: Int64) -> FeedCardFeedback? {
        guard !goto.isEmpty, param != 0 else { return nil }
        var fb = FeedCardFeedback(goto: goto, param: param)
        var seen = Set<String>()
        for entry in threePoint.arrayValue {
            let type = entry["type"].stringValue
            guard type == "dislike" || type == "feedback" else { continue }
            let reasons: [FeedDislikeReason] = entry["reasons"].arrayValue.compactMap { r in
                let name = r["name"].stringValue
                guard let id = r["id"].int64, !name.isEmpty, seen.insert("\(type) \(id) \(name)").inserted else { return nil }
                return FeedDislikeReason(id: id, name: name, toast: r["toast"].stringValue, isFeedback: type == "feedback")
            }
            if type == "dislike" { fb.reasons += reasons } else { fb.feedbacks += reasons }
        }
        return fb.isEmpty ? nil : fb
    }

    /// 不感兴趣 / 反馈 for a feed card, `undo` withdraws it. App-feed cards: `GET app.bilibili.com/x/feed/dislike`
    /// (`…/dislike/cancel`) with the TV-login `access_key`. Web-feed cards: `POST api.bilibili.com/x/web-interface/
    /// feedback/dislike` (`…/cancel`) with the cookies, WBI-signed like bilibili.com.
    static func dislike(_ feedback: FeedCardFeedback, reason: FeedDislikeReason, undo: Bool = false) async throws {
        if feedback.source == .web {
            let path = undo ? "/x/web-interface/feedback/dislike/cancel" : "/x/web-interface/feedback/dislike"
            _ = try await BiliHTTP.shared.post(BiliHost.api + path, form: webDislikeForm(feedback, reason: reason), sign: .wbi)
            return
        }
        guard let auth = appAuth() else { throw BiliError.other("提交反馈需要使用 TV 扫码登录") }
        var query: [String: Any] = [
            "goto": feedback.goto, "id": feedback.param, "build": 1, "mobi_app": "android", "access_key": auth.token,
        ]
        query[reason.isFeedback ? "feedback_id" : "reason_id"] = reason.id
        do {
            _ = try await BiliHTTP.shared.api(BiliHost.app + (undo ? "/x/feed/dislike/cancel" : "/x/feed/dislike"),
                                              query: query, sign: .app(auth.key), headers: appFeedHeaders())
        } catch {
            if AuthService.isRejectedAppToken(error) {
                AuthService.shared.dropAppToken(ifToken: auth.token)
                throw BiliError.other(AuthService.appTokenRejectedMessage)
            }
            throw error
        }
    }

    /// The TV-login `access_key` and the appkey it must be signed with; nil without one.
    static func appAuth() -> (token: String, key: AppKey)? {
        guard let token = AuthService.shared.accessKey, let key = AuthService.shared.accessKeyAppKey else { return nil }
        return (token, key)
    }

    /// Headers PiliPlus sends with the app feed (the `android_hd` client).
    private static func appFeedHeaders() -> [String: String] {
        var h = ListMapping.appHeaders(appKeyHeader: "android_hd")
        h["User-Agent"] = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2"
        h["x-bili-aurora-eid"] = ""
        h["x-bili-aurora-zone"] = ""
        return h
    }

    // MARK: - Popular

    /// 热门. Page numbers start at 1; `next` is the next page number.
    static func popular(page: Int = 1, pageSize: Int = 20) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/popular", query: ["pn": page, "ps": pageSize])
        return parsePopular(data, page: page)
    }

    static func parsePopular(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards = data["list"].arrayValue.compactMap(ListMapping.hotVideo)
        let hasMore = !cards.isEmpty && !data["no_more"].boolValue
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    // MARK: - Ranking

    /// UGC ranking tabs (`/x/web-interface/ranking/v2?rid=`), PiliPlus's current (2025 new-zone) rids.
    /// PGC tabs (番剧 / 国创 / 纪录片 / 电影 / 电视剧 / 综艺) are `pgcRankingZones` → `BangumiAPI.rank(seasonType:)`.
    static let rankingZones: [(rid: Int, name: String)] = [
        (0, "全站"), (1005, "动画"), (1003, "音乐"), (1004, "舞蹈"), (1008, "游戏"), (1010, "知识"),
        (1012, "科技"), (1018, "运动"), (1013, "汽车"), (1020, "美食"), (1024, "动物圈"), (1007, "鬼畜"),
        (1014, "时尚"), (1002, "娱乐"), (1001, "影视"),
    ]

    static let pgcRankingZones: [(seasonType: Int, name: String)] = [
        (1, "番剧"), (4, "国创"), (3, "纪录片"), (2, "电影"), (5, "电视剧"), (7, "综艺"),
    ]

    /// Legacy (pre-2025) rids, tried when the new rid is rejected or returns nothing.
    static let legacyRankingRids: [Int: Int] = [
        1005: 1, 1003: 3, 1004: 129, 1008: 4, 1010: 36, 1012: 188, 1018: 234, 1013: 223,
        1020: 211, 1024: 217, 1007: 119, 1014: 155, 1002: 5, 1001: 181,
    ]

    /// 排行榜 for one zone (one list, ~100 items, no pagination). `type` is `all`, or `origin` / `rookie`
    /// (原创 / 新人, rid 0) [unverified].
    static func ranking(rid: Int, type: String = "all") async throws -> [VideoCard] {
        func fetch(_ r: Int) async throws -> [VideoCard] {
            let data = try await BiliHTTP.shared.api(
                BiliHost.api + "/x/web-interface/ranking/v2",
                query: ["rid": r, "type": type], sign: .wbi)
            return parseRanking(data)
        }
        guard let legacy = legacyRankingRids[rid] else { return try await fetch(rid) }
        do {
            let cards = try await fetch(rid)
            if !cards.isEmpty { return cards }
            return try await fetch(legacy)
        } catch {
            if ListMapping.isCancellation(error) { throw error }
            if let cards = try? await fetch(legacy), !cards.isEmpty { return cards }
            throw error
        }
    }

    static func parseRanking(_ data: JSON) -> [VideoCard] {
        let list = data["list"].array ?? data.arrayValue
        return list.compactMap(ListMapping.hotVideo)
    }

    // MARK: - 每周必看 / 入站必刷

    private static func popularHeaders(referer: String) -> [String: String] {
        ["Origin": "https://www.bilibili.com", "Referer": referer]
    }

    /// All 每周必看 issues, newest first.
    static func weeklyList() async throws -> [PopularWeeklyIssue] {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/popular/series/list",
            query: ["web_location": "333.934"], sign: .wbi,
            headers: popularHeaders(referer: "https://www.bilibili.com/v/popular/weekly"))
        return parseWeeklyList(data)
    }

    static func parseWeeklyList(_ data: JSON) -> [PopularWeeklyIssue] {
        data["list"].arrayValue.compactMap { j in
            guard let n = j["number"].int, n > 0 else { return nil }
            return PopularWeeklyIssue(number: n, name: j["name"].stringValue, subject: j["subject"].stringValue)
        }
    }

    /// Videos of one 每周必看 issue.
    static func weekly(number: Int) async throws -> [VideoCard] {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/popular/series/one",
            query: ["number": number, "web_location": "333.934"], sign: .wbi,
            headers: popularHeaders(referer: "https://www.bilibili.com/v/popular/weekly?num=\(number)"))
        return parseWeekly(data)
    }

    static func parseWeekly(_ data: JSON) -> [VideoCard] {
        data["list"].arrayValue.compactMap(ListMapping.hotVideo)
    }

    /// 入站必刷 (about 100 classics, returned in one page). `reason` carries the `achievement` text.
    static func precious(page: Int = 1) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/popular/precious",
            query: ["page_size": 100, "page": page, "web_location": "333.934"], sign: .wbi,
            headers: popularHeaders(referer: "https://www.bilibili.com/v/popular/history"))
        return parsePrecious(data, page: page)
    }

    static func parsePrecious(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards: [VideoCard] = data["list"].arrayValue.compactMap { j in
            guard var c = ListMapping.hotVideo(j) else { return nil }
            let achievement = j["achievement"].stringValue
            if !achievement.isEmpty { c.reason = achievement }
            return c
        }
        let hasMore = cards.count >= 100
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }
}
