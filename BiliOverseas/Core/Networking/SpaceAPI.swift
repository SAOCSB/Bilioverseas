import Foundation

/// 个人空间: header info, videos, follow / unfollow, followings and fans.
enum SpaceAPI {
    static func spaceHeaders(mid: Int64, path: String = "") -> [String: String] {
        ["Origin": "https://space.bilibili.com", "Referer": "https://space.bilibili.com/\(mid)\(path)"]
    }

    // MARK: - Info

    /// Space header. Fetches `acc/info` (WBI + dm_img; risk-controlled), `web-interface/card`
    /// (lenient; also the fallback), `relation/stat` and, when logged in, `upstat` concurrently.
    static func info(mid: Int64) async throws -> SpaceInfo {
        let loggedIn = BiliHTTP.shared.isLoggedIn
        async let accR = ListMapping.capture { try await accInfoJSON(mid: mid) }
        async let cardR = ListMapping.capture {
            try await BiliHTTP.shared.api(BiliHost.api + "/x/web-interface/card", query: ["mid": mid, "photo": "true"])
        }
        async let statR = ListMapping.capture {
            try await BiliHTTP.shared.api(BiliHost.api + "/x/relation/stat", query: ["vmid": mid])
        }
        async let upR = ListMapping.capture { () async throws -> JSON in
            guard loggedIn else { throw BiliError.notLoggedIn }
            return try await BiliHTTP.shared.api(BiliHost.api + "/x/space/upstat", query: ["mid": mid])
        }
        let acc = await accR, card = await cardR, stat = await statR, up = await upR

        var info: SpaceInfo
        switch (acc, card) {
        case (.success(let a), .success(let c)):
            info = parseAccInfo(a)
            mergeCard(c, into: &info)
        case (.success(let a), .failure):
            info = parseAccInfo(a)
        case (.failure, .success(let c)):
            info = parseCard(c)
        case (.failure(let e), .failure):
            throw e
        }
        if case .success(let s) = stat { applyRelationStat(s, to: &info) }
        if case .success(let u) = up {
            let likes = u["likes"].int64Value
            if likes > 0 { info.likes = likes }
        }
        info.user.fans = info.fans
        info.user.isFollowed = info.isFollowed
        return info
    }

    private static func accInfoJSON(mid: Int64) async throws -> JSON {
        let query = BiliRisk.merged(
            ["mid": mid, "token": "", "platform": "web", "web_location": 1550101], BiliRisk.dmImgParams())
        return try await BiliHTTP.shared.api(BiliHost.api + "/x/space/wbi/acc/info", query: query, sign: .wbi,
                                             headers: spaceHeaders(mid: mid, path: "/dynamic"))
    }

    /// `/x/space/wbi/acc/info` `data`.
    static func parseAccInfo(_ d: JSON) -> SpaceInfo {
        var u = UserBrief(mid: d["mid"].int64Value)
        u.name = d["name"].stringValue
        u.face = ListMapping.image(d["face"])
        u.sign = d["sign"].stringValue
        u.level = d["level"].intValue
        u.vipLabel = d["vip"]["label"]["text"].stringValue
        u.isFollowed = d["is_followed"].boolValue
        var info = SpaceInfo(user: u)
        info.sex = d["sex"].stringValue
        let official = d["official"]
        info.officialType = official["type"].int ?? -1
        let title = official["title"].stringValue
        info.officialTitle = title.isEmpty ? official["desc"].stringValue : title
        info.topPhoto = ListMapping.image(d["top_photo"])
        if info.topPhoto.isEmpty { info.topPhoto = ListMapping.image(d["top_photo_v2"]["l_img"]) }
        info.isFollowed = u.isFollowed
        let live = d["live_room"]
        info.liveRoomId = live["roomid"].int64Value
        info.liveStatus = live["liveStatus"].intValue
        info.liveTitle = live["title"].stringValue
        info.isSeniorMember = d["is_senior_member"].intValue == 1
        return info
    }

    /// `/x/web-interface/card?photo=true` `data` (fallback).
    static func parseCard(_ d: JSON) -> SpaceInfo {
        let card = d["card"]
        var u = UserBrief(mid: card["mid"].int64Value)
        u.name = card["name"].stringValue
        u.face = ListMapping.image(card["face"])
        u.sign = card["sign"].stringValue
        u.level = card["level_info"]["current_level"].intValue
        u.vipLabel = card["vip"]["label"]["text"].stringValue
        u.isFollowed = d["following"].boolValue
        var info = SpaceInfo(user: u)
        info.sex = card["sex"].stringValue
        let official = card["Official"].object != nil ? card["Official"] : card["official"]
        info.officialType = official["type"].int ?? -1
        let title = official["title"].stringValue
        info.officialTitle = title.isEmpty ? official["desc"].stringValue : title
        info.isFollowed = u.isFollowed
        mergeCard(d, into: &info)
        return info
    }

    /// Fills counts (and the banner) that `acc/info` lacks from a card response.
    static func mergeCard(_ d: JSON, into info: inout SpaceInfo) {
        let card = d["card"]
        if info.archiveCount == 0 { info.archiveCount = d["archive_count"].int64Value }
        if info.likes == 0 { info.likes = d["like_num"].int64Value }
        if info.fans == 0 { info.fans = d["follower"].int64 ?? card["fans"].int64Value }
        if info.following == 0 { info.following = card["attention"].int64Value }
        if info.topPhoto.isEmpty { info.topPhoto = ListMapping.image(d["space"]["l_img"]) }
        if !info.isFollowed, d["following"].boolValue {
            info.isFollowed = true
            info.user.isFollowed = true
        }
    }

    static func applyRelationStat(_ d: JSON, to info: inout SpaceInfo) {
        if let f = d["follower"].int64 { info.fans = f }
        if let f = d["following"].int64 { info.following = f }
    }

    // MARK: - Videos

    /// A UP's videos. `cursor` = previous `next` (opaque; nil = first page). Uses web `arc/search`
    /// (WBI + dm_img) and falls back to the app archive cursor API when the web one is risk-controlled.
    static func videos(mid: Int64, cursor: String? = nil, order: SpaceVideoOrder = .pubdate,
                       keyword: String = "") async throws -> Page<VideoCard> {
        let c = decodeVideoCursor(cursor)
        if c.app { return try await appVideos(mid: mid, afterAid: c.lastAid, order: order) }
        do {
            return try await webVideos(mid: mid, page: c.page, order: order, keyword: keyword)
        } catch {
            if ListMapping.isCancellation(error) || !keyword.isEmpty { throw error }
            if case BiliError.api(let code, _) = error, code == -404 { throw error }
            if let page = try? await appVideos(mid: mid, afterAid: c.lastAid, order: order) { return page }
            throw error
        }
    }

    /// Cursor forms: `"web:<page>:<lastAid>"`, `"app:<lastAid>"`, or a bare page number.
    static func decodeVideoCursor(_ cursor: String?) -> (app: Bool, page: Int, lastAid: Int64) {
        guard let cursor, !cursor.isEmpty else { return (false, 1, 0) }
        let parts = cursor.split(separator: ":").map(String.init)
        if parts.first == "app" { return (true, 1, parts.count > 1 ? Int64(parts[1]) ?? 0 : 0) }
        if parts.first == "web" {
            return (false, max(1, parts.count > 1 ? Int(parts[1]) ?? 1 : 1), parts.count > 2 ? Int64(parts[2]) ?? 0 : 0)
        }
        return (false, ListCursor.page(cursor), 0)
    }

    static func webVideos(mid: Int64, page: Int, order: SpaceVideoOrder, keyword: String = "",
                          pageSize: Int = 30) async throws -> Page<VideoCard> {
        var base: [String: Any] = [
            "mid": mid, "ps": pageSize, "tid": 0, "pn": page, "order": order.rawValue,
            "platform": "web", "web_location": "333.1387", "order_avoided": "true",
        ]
        if !keyword.isEmpty { base["keyword"] = keyword }
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/space/wbi/arc/search", query: BiliRisk.merged(base, BiliRisk.dmImgParams()),
            sign: .wbi, headers: spaceHeaders(mid: mid))
        return parseArcSearch(data, page: page, pageSize: pageSize)
    }

    static func parseArcSearch(_ data: JSON, page: Int, pageSize: Int = 30) -> Page<VideoCard> {
        let cards = data["list"]["vlist"].arrayValue.compactMap(arcCard)
        let total = data["page"]["count"].intValue
        let hasMore = !cards.isEmpty && (total > 0 ? page * pageSize < total : cards.count >= pageSize)
        let lastAid = cards.last?.aid ?? 0
        return Page(items: cards, hasMore: hasMore, next: hasMore ? "web:\(page + 1):\(lastAid)" : nil)
    }

    static func arcCard(_ j: JSON) -> VideoCard? {
        var c = VideoCard(id: "")
        ListMapping.applyIDs(&c, aid: j["aid"].int64Value, bvid: j["bvid"].stringValue)
        guard !c.id.isEmpty else { return nil }
        c.kind = .video
        c.title = j["title"].stringValue
        c.cover = ListMapping.image(j["pic"])
        c.desc = j["description"].stringValue
        c.pubdate = j["created"].int64Value
        c.duration = ListMapping.duration(j["length"])
        c.ownerMid = j["mid"].int64Value
        c.ownerName = j["author"].stringValue
        c.viewCount = ListMapping.count(j["play"])
        c.danmakuCount = ListMapping.count(j["video_review"])
        if j["is_lesson_video"].intValue == 1 { c.badge = "课堂" }
        else if j["is_charging_arc"].boolValue { c.badge = "充电专属" }
        else if j["is_union_video"].intValue == 1 { c.badge = "合作" }
        c.uri = j["jump_url"].stringValue
        let pos = j["playback_position"].intValue
        if pos >= 100 { c.progress = -1 } else if pos > 0, c.duration > 0 {
            c.progress = Int((Double(pos) / 100 * Double(c.duration)).rounded())
        }
        return c
    }

    /// App space archive (`app.bilibili.com/x/v2/space/archive/cursor`, APP-signed).
    static func appVideos(mid: Int64, afterAid: Int64, order: SpaceVideoOrder) async throws -> Page<VideoCard> {
        var query = ListMapping.appParams()
        query["vmid"] = mid
        query["ps"] = 20
        query["order"] = order == .click ? "click" : "pubdate"
        query["sort"] = "desc"
        query["qn"] = 80
        if afterAid > 0 { query["aid"] = afterAid }
        let data = try await BiliHTTP.shared.api(
            BiliHost.app + "/x/v2/space/archive/cursor", query: query, sign: .app(ListMapping.appKey),
            headers: ["User-Agent": ListMapping.appUserAgent, "bili-http-engine": "cronet"])
        return parseAppArchive(data, mid: mid)
    }

    static func parseAppArchive(_ data: JSON, mid: Int64 = 0) -> Page<VideoCard> {
        let cards: [VideoCard] = data["item"].arrayValue.compactMap { j in
            var c = VideoCard(id: "")
            ListMapping.applyIDs(&c, aid: j["param"].int64 ?? j["aid"].int64Value, bvid: j["bvid"].stringValue)
            guard !c.id.isEmpty else { return nil }
            c.kind = .video
            c.cid = j["first_cid"].int64Value
            c.title = j["title"].stringValue
            c.cover = ListMapping.image(j["cover"])
            c.duration = j["duration"].int ?? ListMapping.duration(j["length"])
            c.viewCount = ListMapping.count(j["play"])
            c.danmakuCount = ListMapping.count(j["danmaku"])
            c.ownerMid = mid
            c.ownerName = j["author"].stringValue
            c.pubdate = j["ctime"].int64Value
            c.reason = j["publish_time_text"].stringValue
            c.uri = j["uri"].stringValue
            if j["is_pgc"].boolValue { c.badge = "番剧" }
            else if j["is_pugv"].boolValue { c.badge = "课堂" }
            else if j["is_cooperation"].boolValue { c.badge = "合作" }
            else if let b = j["badges"].arrayValue.first?["text"].string { c.badge = b }
            return c
        }
        let hasMore = data["has_next"].boolValue && !cards.isEmpty
        let lastAid = cards.last?.aid ?? 0
        return Page(items: cards, hasMore: hasMore, next: hasMore ? "app:\(lastAid)" : nil)
    }

    // MARK: - Relation

    /// 关注 (`act` 1) / 取消关注 (2) / 拉黑 (5) / 取消拉黑 (6) / 移除粉丝 (7).
    static func modifyRelation(mid: Int64, act: Int) async throws {
        let http = BiliHTTP.shared
        guard let csrf = http.csrf else { throw BiliError.notLoggedIn }
        let extend = #"{"entity":"user","entity_id":\#(mid),"fp":"\#(BiliHTTP.webUserAgent)"}"#
        _ = try await http.api(
            BiliHost.api + "/x/relation/modify", method: "POST",
            query: [
                "statistics": #"{"appId":100,"platform":5}"#,
                "x-bili-device-req-json": #"{"platform":"web","device":"pc","spmid":"333.1387"}"#,
            ],
            form: [
                "fid": mid, "act": act, "re_src": 11, "gaia_source": "web_main", "spmid": "333.1387",
                "extend_content": extend, "csrf": csrf,
            ],
            headers: spaceHeaders(mid: mid, path: "/dynamic"))
        syncFollowedStore(mid: mid, act: act)
    }

    /// Keeps `FollowedUpsStore` (FeedFilter's 关注 exemption) in sync after a successful change.
    private static func syncFollowedStore(mid: Int64, act: Int) {
        switch act {
        case 1, 3: FollowedUpsStore.shared.insert(mid)
        case 2, 4, 5: FollowedUpsStore.shared.remove(mid)
        default: break
        }
        // 拉黑 / 取消拉黑 also update FeedFilter's account blacklist.
        if act == 5 { AccountBlacklistStore.shared.insert(mid) } else if act == 6 { AccountBlacklistStore.shared.remove(mid) }
    }

    /// Fills `FollowedUpsStore` with the logged-in user's followings (call after login / on launch).
    @discardableResult
    static func refreshFollowedUps(cap: Int = 2000) async throws -> Set<Int64> {
        guard let me = BiliHTTP.shared.mid else { throw BiliError.notLoggedIn }
        let mids = try await allFollowingMids(mid: me, cap: cap)
        FollowedUpsStore.shared.update(mids)
        return mids
    }

    static func modifyRelation(mid: Int64, action: RelationAction) async throws {
        try await modifyRelation(mid: mid, act: action.rawValue)
    }

    static func follow(mid: Int64) async throws { try await modifyRelation(mid: mid, act: 1) }
    static func unfollow(mid: Int64) async throws { try await modifyRelation(mid: mid, act: 2) }

    /// The signed-in user's relation to `fid` (`/x/relation`: 悄悄关注 / 已关注 / 已互关 / 特别关注 / 已拉黑).
    /// `.notFollowing` when logged out.
    static func relation(fid: Int64) async throws -> UserRelationState {
        guard BiliHTTP.shared.isLoggedIn, fid > 0 else { return .notFollowing }
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/relation", query: ["fid": fid])
        return UserRelationState(json: data)
    }

    /// 关注列表. Other users' lists may be private (error 22115) or capped by the server.
    static func followings(mid: Int64, page: Int = 1, pageSize: Int = 20) async throws -> Page<UserBrief> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/relation/followings",
            query: ["vmid": mid, "pn": page, "ps": pageSize, "order": "desc", "order_type": ""])
        return parseRelationList(data, page: page, pageSize: pageSize)
    }

    /// 粉丝列表.
    static func fans(mid: Int64, page: Int = 1, pageSize: Int = 20) async throws -> Page<UserBrief> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/relation/fans",
            query: ["vmid": mid, "pn": page, "ps": pageSize, "order": "desc"])
        return parseRelationList(data, page: page, pageSize: pageSize)
    }

    static func parseRelationList(_ data: JSON, page: Int, pageSize: Int) -> Page<UserBrief> {
        let users: [UserBrief] = data["list"].arrayValue.compactMap { j in
            let mid = j["mid"].int64Value
            guard mid != 0 else { return nil }
            var u = UserBrief(mid: mid)
            u.name = j["uname"].stringValue
            u.face = ListMapping.image(j["face"])
            u.sign = j["sign"].stringValue
            u.vipLabel = j["vip"]["label"]["text"].stringValue
            let attr = j["attribute"].intValue
            u.isFollowed = attr == 2 || attr == 6
            return u
        }
        let total = data["total"].intValue
        let hasMore = !users.isEmpty && (total > 0 ? page * pageSize < total : users.count >= pageSize)
        return Page(items: users, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    /// Every followed mid (paged, at most `cap`), for the "exempt followed UPs" filter.
    /// Throws only if the first page fails; later failures return what was collected.
    static func allFollowingMids(mid: Int64, cap: Int = 2000) async throws -> Set<Int64> {
        var mids = Set<Int64>()
        var page = 1
        let ps = 50
        while mids.count < cap {
            let p: Page<UserBrief>
            do {
                p = try await followings(mid: mid, page: page, pageSize: ps)
            } catch {
                if page == 1 || ListMapping.isCancellation(error) { throw error }
                break
            }
            for u in p.items { mids.insert(u.mid) }
            guard p.hasMore else { break }
            page += 1
        }
        return mids
    }
}
