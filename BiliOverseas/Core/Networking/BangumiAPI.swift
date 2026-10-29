import Foundation

/// One day of the 新番时间表.
struct BangumiDay: Identifiable, Hashable {
    var id: String { date }
    /// e.g. "3-12".
    var date: String
    var dateTs: Int64 = 0
    /// 1 = Monday … 7 = Sunday.
    var weekday: Int
    var isToday: Bool
    /// `.bangumi` cards (seasonId + epId). `reason` = "<pub_time> <pub_index>", `desc` = pub_index.
    var episodes: [VideoCard]

    /// 周一 … 周日.
    var weekdayName: String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return (1...7).contains(weekday) ? names[weekday - 1] : ""
    }
}

/// 番剧 / 国创 / 影视 (PGC) lists. PGC endpoints answer under `result` (BiliHTTP.api handles it).
enum BangumiAPI {
    // MARK: - Timeline

    /// 新番时间表. `type`: 1 番剧, 3 电影, 4 国创.
    static func timeline(type: Int = 1, before: Int = 6, after: Int = 6) async throws -> [BangumiDay] {
        let result = try await BiliHTTP.shared.api(
            BiliHost.api + "/pgc/web/timeline", query: ["types": type, "before": before, "after": after])
        return parseTimeline(result)
    }

    static func parseTimeline(_ result: JSON) -> [BangumiDay] {
        let days = result.array ?? result["result"].arrayValue
        return days.map { d in
            let episodes: [VideoCard] = d["episodes"].arrayValue.compactMap { e in
                let ss = e["season_id"].int64Value
                let ep = e["episode_id"].int64 ?? e["ep_id"].int64Value
                guard ss != 0 || ep != 0 else { return nil }
                let cover = ListMapping.image(e["cover"])
                var c = ListMapping.pgcCard(seasonId: ss, epId: ep, title: e["title"].stringValue,
                                            cover: cover.isEmpty ? ListMapping.image(e["square_cover"]) : cover)
                let index = e["pub_index"].stringValue
                let time = e["pub_time"].stringValue
                c.desc = index
                c.reason = [time, index].filter { !$0.isEmpty }.joined(separator: " ")
                c.pubdate = e["pub_ts"].int64Value
                c.isFollowed = e["follow"].intValue == 1
                if e["delay"].intValue == 1 { c.badge = "停更" }
                return c
            }
            return BangumiDay(date: d["date"].stringValue, dateTs: d["date_ts"].int64Value,
                              weekday: d["day_of_week"].intValue, isToday: d["is_today"].intValue == 1,
                              episodes: episodes)
        }
    }

    // MARK: - Rank

    /// PGC 排行榜 (三日). `seasonType`: 1 番剧, 4 国创, 3 纪录片, 2 电影, 5 电视剧, 7 综艺.
    static func rank(seasonType: Int = 1, day: Int = 3) async throws -> [VideoCard] {
        let url = seasonType == 1
            ? BiliHost.api + "/pgc/web/rank/list"
            : BiliHost.api + "/pgc/season/rank/web/list"
        let data = try await BiliHTTP.shared.api(url, query: ["day": day, "season_type": seasonType], sign: .wbi)
        return parseRank(data)
    }

    static func parseRank(_ data: JSON) -> [VideoCard] {
        (data["list"].array ?? data.arrayValue).compactMap { j in
            let url = j["url"].stringValue
            var ss = j["season_id"].int64Value
            if ss == 0 { ss = ListMapping.seasonId(inURL: url) }
            let ep = ListMapping.epId(inURL: url)
            guard ss != 0 || ep != 0 else { return nil }
            let cover = ListMapping.image(j["cover"])
            var c = ListMapping.pgcCard(seasonId: ss, epId: ss != 0 ? 0 : ep, title: j["title"].stringValue,
                                        cover: cover.isEmpty ? ListMapping.image(j["ss_horizontal_cover"]) : cover)
            c.uri = url
            c.reason = j["new_ep"]["index_show"].stringValue
            c.viewCount = ListMapping.count(j["stat"]["view"])
            c.danmakuCount = ListMapping.count(j["stat"]["danmaku"])
            let badge = j["badge"].stringValue
            c.badge = badge.isEmpty ? j["badge_info"]["text"].stringValue : badge
            c.desc = j["rating"].stringValue
            return c
        }
    }

    // MARK: - Index (番剧索引)

    /// 番剧 / 国创 index list (default ordering `order` 3 = 追番人数). `next` = next page.
    static func index(seasonType: Int = 1, page: Int = 1, order: Int = 3) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/pgc/season/index/result",
            query: [
                "st": seasonType, "order": order, "season_version": -1, "spoken_language_type": -1, "area": -1,
                "is_finish": -1, "copyright": -1, "season_status": -1, "season_month": -1, "year": -1,
                "style_id": -1, "sort": 0, "season_type": seasonType, "pagesize": 20, "type": 1, "page": page,
            ])
        return parseIndex(data, page: page)
    }

    static func parseIndex(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards: [VideoCard] = data["list"].arrayValue.compactMap { j in
            let ss = j["season_id"].int64Value
            guard ss != 0 else { return nil }
            var c = ListMapping.pgcCard(seasonId: ss, epId: 0, title: j["title"].stringValue,
                                        cover: ListMapping.image(j["cover"]))
            c.badge = j["badge"].stringValue
            c.reason = j["order"].stringValue
            c.desc = j["index_show"].stringValue
            c.uri = j["link"].stringValue
            return c
        }
        let hasMore = data["has_next"].boolValue && !cards.isEmpty
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    // MARK: - My follows (追番 / 追剧)

    /// 我的追番 (`type` 1) / 追剧 (`type` 2). `status`: 1 想看, 2 在看, 3 看过, nil = all.
    /// `mid` defaults to the logged-in user.
    static func myFollows(type: Int = 1, page: Int = 1, status: Int? = nil, mid: Int64? = nil) async throws -> Page<VideoCard> {
        guard let vmid = mid ?? BiliHTTP.shared.mid else { throw BiliError.notLoggedIn }
        var query: [String: Any] = ["vmid": vmid, "type": type, "pn": page, "ps": 15]
        if let status { query["follow_status"] = status }
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/space/bangumi/follow/list", query: query)
        return parseFollows(data, page: page, pageSize: 15)
    }

    static func parseFollows(_ data: JSON, page: Int, pageSize: Int = 15) -> Page<VideoCard> {
        let cards: [VideoCard] = data["list"].arrayValue.compactMap { j in
            let ss = j["season_id"].int64Value
            guard ss != 0 else { return nil }
            var c = ListMapping.pgcCard(seasonId: ss, epId: 0, title: j["title"].stringValue,
                                        cover: ListMapping.image(j["cover"]))
            let progress = j["progress"].stringValue
            let newEp = j["new_ep"]["index_show"].stringValue
            c.reason = progress.isEmpty ? newEp : progress
            c.desc = newEp
            c.badge = j["badge"].stringValue
            c.isFollowed = true
            c.uri = j["url"].stringValue
            return c
        }
        let total = data["total"].intValue
        let hasMore = !cards.isEmpty && (total > 0 ? page * pageSize < total : cards.count >= pageSize)
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    /// 追番 / 取消追番.
    static func setFollow(seasonId: Int64, follow: Bool) async throws {
        _ = try await BiliHTTP.shared.post(
            BiliHost.api + (follow ? "/pgc/web/follow/add" : "/pgc/web/follow/del"), form: ["season_id": seasonId])
    }
}
