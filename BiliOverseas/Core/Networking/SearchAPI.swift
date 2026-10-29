import Foundation

/// Search: hot words, suggestions, and typed search (video / user / bangumi / live / article).
enum SearchAPI {
    static let riskMessage = "搜索被风控拦截，请稍后再试"

    // MARK: - Hot words & suggest

    /// 热搜 (pinned `top_list` first). Sponsored entries are dropped.
    static func hotWords(limit: Int = 30) async throws -> [HotSearchWord] {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/v2/search/trending/ranking", query: ["limit": limit])
        return parseHotWords(data)
    }

    static func parseHotWords(_ data: JSON) -> [HotSearchWord] {
        var seen = Set<String>()
        var out: [HotSearchWord] = []
        func add(_ j: JSON, top: Bool) {
            let keyword = j["keyword"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, !seen.contains(keyword) else { return }
            let commercial = j["is_commercial"].stringValue == "1" || j["is_commercial"].boolValue
            if commercial { return }
            seen.insert(keyword)
            var reason = j["recommend_reason"].stringValue
            if let r = reason.range(of: "·") { reason.replaceSubrange(r, with: " ") }
            let show = j["show_name"].stringValue
            out.append(HotSearchWord(keyword: keyword, showName: show.isEmpty ? keyword : show,
                                     icon: ListMapping.image(j["icon"]), isCommercial: false,
                                     recommendReason: reason, showLiveIcon: j["show_live_icon"].boolValue,
                                     isTop: top))
        }
        for j in data["top_list"].arrayValue { add(j, top: true) }
        for j in data["list"].arrayValue { add(j, top: false) }
        return out
    }

    /// Search-as-you-type suggestions (plain strings).
    static func suggest(term: String) async throws -> [String] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/suggest",
            query: ["term": t, "highlight": 0, "spmid": "333.1365", "web_location": "333.1365"],
            sign: .wbi)
        return parseSuggest(data)
    }

    static func parseSuggest(_ data: JSON) -> [String] {
        let tags = data["result"]["tag"].array ?? data["tag"].arrayValue
        var seen = Set<String>()
        return tags.compactMap { j in
            var s = j["term"].stringValue
            if s.isEmpty { s = j["value"].stringValue }
            if s.isEmpty { s = ListMapping.plainText(j["name"].stringValue) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, seen.insert(s).inserted else { return nil }
            return s
        }
    }

    // MARK: - Typed search

    static func searchVideos(keyword: String, page: Int = 1, order: SearchVideoOrder = .totalrank,
                             duration: SearchDurationFilter = .all, tids: Int? = nil) async throws -> Page<VideoCard> {
        var extra: [String: Any] = ["duration": duration.rawValue]
        if order != .totalrank { extra["order"] = order.rawValue }
        if let tids { extra["tids"] = tids }
        let data = try await search(type: "video", keyword: keyword, page: page, extra: extra)
        return parseVideos(data, page: page)
    }

    static func searchUsers(keyword: String, page: Int = 1, order: SearchUserOrder = .default) async throws -> Page<UserBrief> {
        var extra: [String: Any] = [:]
        if order != .default { extra["order"] = order.rawValue; extra["order_sort"] = 0 }
        let data = try await search(type: "bili_user", keyword: keyword, page: page, extra: extra)
        return parseUsers(data, page: page)
    }

    /// 番剧 + 影视 (`media_bangumi` and `media_ft`, fetched together and merged, bangumi first).
    static func searchBangumi(keyword: String, page: Int = 1) async throws -> Page<VideoCard> {
        async let bangumi = ListMapping.capture { try await search(type: "media_bangumi", keyword: keyword, page: page) }
        async let ft = ListMapping.capture { try await search(type: "media_ft", keyword: keyword, page: page) }
        let results = [await bangumi, await ft]
        var items: [VideoCard] = []
        var hasMore = false
        var firstError: Error?
        var seen = Set<String>()
        for r in results {
            switch r {
            case .success(let data):
                let p = parsePGC(data, page: page)
                for c in p.items where seen.insert(c.id).inserted { items.append(c) }
                hasMore = hasMore || p.hasMore
            case .failure(let e):
                if firstError == nil { firstError = e }
            }
        }
        if let firstError, results.allSatisfy({ if case .failure = $0 { return true }; return false }) {
            throw firstError
        }
        return Page(items: items, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    static func searchLive(keyword: String, page: Int = 1) async throws -> Page<VideoCard> {
        let data = try await search(type: "live_room", keyword: keyword, page: page)
        return parseLive(data, page: page)
    }

    /// 专栏 (`search_type=article`): `.article` cards that open `https://www.bilibili.com/read/cv<id>`.
    static func searchArticles(keyword: String, page: Int = 1) async throws -> Page<VideoCard> {
        let data = try await search(type: "article", keyword: keyword, page: page)
        return parseArticles(data, page: page)
    }

    /// `/x/web-interface/wbi/search/type` → `data`. Maps -412 / `v_voucher` captchas to `riskMessage`.
    static func search(type: String, keyword: String, page: Int, extra: [String: Any] = [:]) async throws -> JSON {
        await ensureBuvid()
        var query: [String: Any] = [
            "search_type": type, "keyword": keyword, "page": page, "page_size": 20,
            "platform": "pc", "web_location": 1430654,
        ]
        for (k, v) in extra { query[k] = v }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let headers = [
            "Origin": "https://search.bilibili.com",
            "Referer": "https://search.bilibili.com/\(type)?keyword=\(encoded)",
        ]
        let data: JSON
        do {
            data = try await BiliHTTP.shared.api(BiliHost.api + "/x/web-interface/wbi/search/type",
                                                 query: query, sign: .wbi, headers: headers)
        } catch BiliError.api(let code, _) where code == -412 || code == -352 {
            throw BiliError.other(riskMessage)
        } catch BiliError.http(let status) where status == 412 {
            throw BiliError.other(riskMessage)
        }
        try checkRisk(data)
        return data
    }

    /// `code == 0` but `data.v_voucher` present → a captcha is required.
    static func checkRisk(_ data: JSON) throws {
        if data["v_voucher"].exists { throw BiliError.other(riskMessage) }
    }

    /// Search answers -412 without a `buvid3` cookie; seed one if the jar has none.
    static func ensureBuvid() async {
        let http = BiliHTTP.shared
        guard http.cookie(named: "buvid3") == nil else { return }
        guard let data = try? await http.api(BiliHost.api + "/x/frontend/finger/spi") else { return }
        let b3 = data["b_3"].stringValue
        let b4 = data["b_4"].stringValue
        if !b3.isEmpty { http.setCookie(name: "buvid3", value: b3) }
        if !b4.isEmpty { http.setCookie(name: "buvid4", value: b4) }
    }

    // MARK: - Parsers

    private static func pagination(_ data: JSON, page: Int, itemCount: Int) -> (Bool, String?) {
        let numPages = data["numPages"].intValue
        let hasMore = itemCount > 0 && (numPages > 0 ? page < numPages : itemCount >= 20)
        return (hasMore, ListCursor.next(page: page, hasMore: hasMore))
    }

    /// `data.result` as a list (search/type), or the matching block of search/all/v2.
    static func resultList(_ data: JSON, type: String) -> [JSON] {
        let result = data["result"]
        if let list = result.array {
            if let first = list.first, first["result_type"].exists {
                return list.first { $0["result_type"].stringValue == type }?["data"].arrayValue ?? []
            }
            return list
        }
        // `search_type=live` answers {live_room: [], live_user: []}.
        return result[type].arrayValue
    }

    static func parseVideos(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards = resultList(data, type: "video").compactMap(videoCard)
        let (hasMore, next) = pagination(data, page: page, itemCount: cards.count)
        return Page(items: cards, hasMore: hasMore, next: next)
    }

    static func videoCard(_ j: JSON) -> VideoCard? {
        let type = j["type"].stringValue
        var c = VideoCard(id: "")
        c.title = ListMapping.plainText(j["title"].stringValue)
        c.cover = ListMapping.image(j["pic"])
        c.duration = ListMapping.duration(j["duration"])
        c.pubdate = j["pubdate"].int64 ?? j["senddate"].int64Value
        c.desc = ListMapping.plainText(j["description"].stringValue)
        c.ownerMid = j["mid"].int64Value
        c.ownerName = ListMapping.plainText(j["author"].stringValue)
        c.ownerFace = ListMapping.image(j["upic"])
        c.viewCount = ListMapping.count(j["play"])
        c.danmakuCount = ListMapping.count(j["danmaku"].exists ? j["danmaku"] : j["video_review"])
        c.likeCount = ListMapping.count(j["like"])
        c.uri = j["arcurl"].stringValue
        switch type {
        case "live_room":
            c.kind = .live
            c.roomId = j["roomid"].int64Value
            guard c.roomId != 0 else { return nil }
            c.id = "live-\(c.roomId)"
            c.badge = "直播"
            return c
        case "ketang":
            c.kind = .other
            c.badge = "课堂"
            c.id = "ketang-\(j["id"].int64 ?? j["aid"].int64Value)"
            if c.uri.isEmpty { c.uri = j["url"].stringValue }
            return c
        default:
            ListMapping.applyIDs(&c, aid: j["aid"].int64 ?? j["id"].int64Value, bvid: j["bvid"].stringValue)
            guard !c.id.isEmpty else { return nil }
            c.kind = .video
            if j["is_union_video"].intValue == 1 { c.badge = "合作" }
            return c
        }
    }

    static func parseUsers(_ data: JSON, page: Int) -> Page<UserBrief> {
        let users: [UserBrief] = resultList(data, type: "bili_user").compactMap { j in
            let mid = j["mid"].int64Value
            guard mid != 0 else { return nil }
            var u = UserBrief(mid: mid)
            u.name = ListMapping.plainText(j["uname"].stringValue)
            u.face = ListMapping.image(j["upic"])
            u.sign = j["usign"].stringValue
            u.level = j["level"].intValue
            u.fans = ListMapping.count(j["fans"])
            u.isFollowed = j["is_atten"].intValue != 0
            return u
        }
        let (hasMore, next) = pagination(data, page: page, itemCount: users.count)
        return Page(items: users, hasMore: hasMore, next: next)
    }

    static func parsePGC(_ data: JSON, page: Int) -> Page<VideoCard> {
        var items: [JSON]
        if data["result"].array?.first?["result_type"].exists == true {
            items = resultList(data, type: "media_bangumi") + resultList(data, type: "media_ft")
        } else {
            items = data["result"].arrayValue
        }
        let cards: [VideoCard] = items.compactMap { j in
            let url = j["url"].string ?? j["goto_url"].stringValue
            var seasonId = j["season_id"].int64Value
            if seasonId == 0 { seasonId = ListMapping.seasonId(inURL: url) }
            // Search hits open the season; an episode only when the URL names one.
            var epId = ListMapping.epId(inURL: url)
            if seasonId == 0 && epId == 0 { epId = j["eps"][0]["id"].int64Value }
            guard seasonId != 0 || epId != 0 else { return nil }
            var c = ListMapping.pgcCard(seasonId: seasonId, epId: epId,
                                        title: ListMapping.plainText(j["title"].stringValue),
                                        cover: ListMapping.image(j["cover"]))
            c.uri = url
            c.desc = j["desc"].stringValue
            c.pubdate = j["pubtime"].int64Value
            c.badge = j["season_type_name"].stringValue
            c.reason = j["index_show"].stringValue
            let areas = j["areas"].stringValue
            let styles = j["styles"].stringValue
            c.ownerName = [areas, styles].filter { !$0.isEmpty }.joined(separator: " · ")
            return c
        }
        let (hasMore, next) = pagination(data, page: page, itemCount: cards.count)
        return Page(items: cards, hasMore: hasMore, next: next)
    }

    /// Article hits (`id` = cvid, `image_urls[]`, `view`, `like`, `reply`, `mid`, `pub_time`,
    /// `category_name`). `reason` = category, `danmakuCount` = comments (`reply`).
    static func parseArticles(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards: [VideoCard] = resultList(data, type: "article").compactMap { j in
            let cv = j["id"].int64Value
            guard cv > 0 else { return nil }
            var c = VideoCard(id: "cv\(cv)")
            c.kind = .article
            c.title = ListMapping.plainText(j["title"].stringValue)
            c.cover = ListMapping.image(j["image_urls"].arrayValue.first ?? .null)
            c.desc = ListMapping.plainText(j["desc"].stringValue)
            c.ownerMid = j["mid"].int64Value
            c.viewCount = ListMapping.count(j["view"])
            c.likeCount = ListMapping.count(j["like"])
            c.danmakuCount = ListMapping.count(j["reply"])
            c.pubdate = j["pub_time"].int64Value
            c.reason = j["category_name"].stringValue
            c.uri = "https://www.bilibili.com/read/cv\(cv)"
            return c
        }
        let (hasMore, next) = pagination(data, page: page, itemCount: cards.count)
        return Page(items: cards, hasMore: hasMore, next: next)
    }

    static func parseLive(_ data: JSON, page: Int) -> Page<VideoCard> {
        let cards: [VideoCard] = resultList(data, type: "live_room").compactMap { j in
            let room = j["roomid"].int64Value
            guard room != 0 else { return nil }
            var c = VideoCard(id: "live-\(room)")
            c.kind = .live
            c.roomId = room
            c.title = ListMapping.plainText(j["title"].stringValue)
            let userCover = ListMapping.image(j["user_cover"])
            c.cover = userCover.isEmpty ? ListMapping.image(j["cover"]) : userCover
            c.ownerMid = j["uid"].int64Value
            c.ownerName = ListMapping.plainText(j["uname"].stringValue)
            c.ownerFace = ListMapping.image(j["uface"])
            c.viewCount = ListMapping.count(j["online"])
            c.reason = j["watched_show"]["text_large"].stringValue
            c.desc = ListMapping.plainText(j["cate_name"].stringValue)
            c.badge = j["live_status"].int.map { $0 == 1 ? "直播中" : "直播" } ?? "直播"
            c.uri = "https://live.bilibili.com/\(room)"
            return c
        }
        let (hasMore, next) = pagination(data, page: page, itemCount: cards.count)
        return Page(items: cards, hasMore: hasMore, next: next)
    }
}
