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

/// Home feeds: 推荐 (web), 热门, 排行榜, 每周必看, 入站必刷.
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
        return c
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
