import Foundation

/// 动态: follow feed, followed-UP strip, a user's space dynamics.
enum DynamicsAPI {
    static let features =
        "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete,onlyfansQaCard,commentsNewVersion,avatarAutoTheme,sunflowerStyle,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser"

    /// Code the feed answers when there is nothing (more) to show.
    static let noDataCode = 4101132

    // MARK: - Feeds

    /// Follow feed (login required). `type`: `all` | `video` | `pgc` | `article`. `offset` = previous `next`.
    static func feed(type: String = "all", offset: String? = nil) async throws -> Page<DynamicItem> {
        try await feedWithBaseline(type: type, offset: offset).page
    }

    /// Same as `feed`, also returning `data.update_baseline` (pass it to `newCount`) [unverified].
    static func feedWithBaseline(type: String = "all", offset: String? = nil) async throws
        -> (page: Page<DynamicItem>, updateBaseline: String) {
        var query: [String: Any] = ["type": type, "features": features, "timezone_offset": -480]
        if let offset, !offset.isEmpty { query["offset"] = offset }
        return try await fetchFeed(query: query)
    }

    /// The follow feed narrowed to one followed UP (the UP strip's tab).
    static func feed(hostMid: Int64, offset: String? = nil) async throws -> Page<DynamicItem> {
        var query: [String: Any] = ["host_mid": hostMid, "features": features, "timezone_offset": -480]
        if let offset, !offset.isEmpty { query["offset"] = offset }
        return try await fetchFeed(query: query).page
    }

    private static func fetchFeed(query: [String: Any]) async throws -> (page: Page<DynamicItem>, updateBaseline: String) {
        do {
            let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/polymer/web-dynamic/v1/feed/all", query: query)
            return (parseFeed(data), data["update_baseline"].stringValue)
        } catch BiliError.api(let code, _) where code == noDataCode {
            return (.empty, "")
        }
    }

    /// Number of new dynamics since `baseline` (red dot) [unverified].
    static func newCount(type: String = "all", baseline: String) async throws -> Int {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/polymer/web-dynamic/v1/feed/all/update",
            query: ["type": type, "update_baseline": baseline])
        return data["update_num"].intValue
    }

    /// A user's dynamics (space tab). WBI + dm_img, space Origin/Referer. -352 = risk control.
    static func spaceFeed(mid: Int64, offset: String? = nil) async throws -> Page<DynamicItem> {
        let query = BiliRisk.merged([
            "offset": offset ?? "", "host_mid": mid, "timezone_offset": "-480", "features": features,
            "platform": "web", "web_location": "333.1387",
            "x-bili-device-req-json": #"{"platform":"web","device":"pc","spmid":"333.1387"}"#,
        ], BiliRisk.dmImgParams())
        do {
            let data = try await BiliHTTP.shared.api(
                BiliHost.api + "/x/polymer/web-dynamic/v1/feed/space", query: query, sign: .wbi,
                headers: ["Origin": "https://space.bilibili.com", "Referer": "https://space.bilibili.com/\(mid)/dynamic"])
            return parseFeed(data)
        } catch BiliError.api(let code, _) where code == noDataCode {
            return .empty
        }
    }

    static func parseFeed(_ data: JSON) -> Page<DynamicItem> {
        let items = data["items"].arrayValue.compactMap { parseItem($0) }
        let offset = data["offset"].stringValue
        let hasMore = data["has_more"].boolValue && !offset.isEmpty
        return Page(items: items, hasMore: hasMore, next: hasMore ? offset : nil)
    }

    // MARK: - Item parsing

    static func kind(of rawType: String) -> DynamicKind {
        switch rawType {
        case "DYNAMIC_TYPE_AV", "DYNAMIC_TYPE_UGC_SEASON": return .video
        case "DYNAMIC_TYPE_DRAW": return .draw
        case "DYNAMIC_TYPE_WORD": return .word
        case "DYNAMIC_TYPE_FORWARD": return .forward
        case "DYNAMIC_TYPE_PGC", "DYNAMIC_TYPE_PGC_UNION": return .pgc
        case "DYNAMIC_TYPE_LIVE", "DYNAMIC_TYPE_LIVE_RCMD", "DYNAMIC_TYPE_SUBSCRIPTION_NEW": return .live
        case "DYNAMIC_TYPE_ARTICLE": return .article
        default: return .other
        }
    }

    /// One `items[]` entry (or an `orig`). Folded duplicates (`visible == false`) are dropped.
    static func parseItem(_ j: JSON, isOrig: Bool = false) -> DynamicItem? {
        guard j.object != nil else { return nil }
        if !isOrig, j["visible"].bool == false { return nil }
        let rawType = j["type"].stringValue
        let modules = j["modules"]
        let authorJSON = modules["module_author"]
        var idStr = j["id_str"].stringValue
        if idStr.isEmpty { idStr = "\(isOrig ? "orig" : "dyn")-\(rawType)-\(authorJSON["mid"].int64Value)-\(authorJSON["pub_ts"].int64Value)" }

        var d = DynamicItem(idStr: idStr)
        d.rawType = rawType
        d.type = kind(of: rawType)

        var author = UserBrief(mid: authorJSON["mid"].int64Value)
        author.name = authorJSON["name"].stringValue
        author.face = ListMapping.image(authorJSON["face"])
        author.vipLabel = authorJSON["vip"]["label"]["text"].stringValue
        author.isFollowed = authorJSON["following"].boolValue
        d.author = author
        d.pubTimeText = authorJSON["pub_time"].stringValue
        d.pubTs = authorJSON["pub_ts"].int64Value
        d.pubAction = authorJSON["pub_action"].stringValue
        d.isTop = authorJSON["is_top"].boolValue || modules["module_tag"]["text"].stringValue == "置顶"

        let stat = modules["module_stat"]
        d.stat = DynamicStat(forward: ListMapping.count(stat["forward"]["count"]),
                             comment: ListMapping.count(stat["comment"]["count"]),
                             like: ListMapping.count(stat["like"]["count"]),
                             liked: stat["like"]["status"].boolValue)
        d.commentId = j["basic"]["comment_id_str"].int64Value
        d.commentType = j["basic"]["comment_type"].intValue
        d.jumpURL = j["basic"]["jump_url"].stringValue.biliHTTPS

        let dyn = modules["module_dynamic"]
        let (text, emojis) = flattenRichText(dyn["desc"])
        d.text = text
        d.emojis = emojis
        d.topic = dyn["topic"]["name"].stringValue

        // Ads & promotions.
        if rawType == "DYNAMIC_TYPE_AD" {
            d.isAd = true
            d.adSignals.append("type=DYNAMIC_TYPE_AD")
        }
        let additional = dyn["additional"]
        if additional["type"].stringValue == "ADDITIONAL_TYPE_GOODS" {
            d.hasGoods = true
            d.adSignals.append("goods")
        }
        if additional["common"]["sub_type"].stringValue == "game" { d.adSignals.append("game") }

        applyMajor(dyn["major"], author: authorJSON, to: &d)

        if d.type == .forward || j["orig"].object != nil, let orig = parseItem(j["orig"], isOrig: true) {
            d.forwarded = orig
            if orig.hasGoods && !d.hasGoods {
                d.hasGoods = true
                d.adSignals.append("goods")
            }
        }
        // Soft promotion signals (带货 / 游戏推广) also ride on the embedded card so FeedFilter's 恰饭
        // rule sees them; the card stays `.video` (it is the UP's own upload, not a platform ad).
        // A DYNAMIC_TYPE_AD card becomes `.ad`.
        if var v = d.video {
            if d.isAd {
                v.kind = .ad
                v.adSignals = d.adSignals
            } else {
                v.adSignals = d.adSignals.filter { $0 == "goods" || $0 == "game" }
            }
            d.video = v
        }
        return d
    }

    private static func applyMajor(_ major: JSON, author: JSON, to d: inout DynamicItem) {
        let mt = major["type"].stringValue
        switch mt {
        case "MAJOR_TYPE_ARCHIVE", "MAJOR_TYPE_UGC_SEASON":
            let a = mt == "MAJOR_TYPE_ARCHIVE" ? major["archive"] : major["ugc_season"]
            d.video = archiveCard(a, author: author, desc: d.text)
            if d.type == .other { d.type = .video }
        case "MAJOR_TYPE_PGC":
            let p = major["pgc"]
            var c = ListMapping.pgcCard(seasonId: p["season_id"].int64Value, epId: p["epid"].int64Value,
                                        title: p["title"].stringValue, cover: ListMapping.image(p["cover"]))
            c.uri = p["jump_url"].stringValue.biliHTTPS
            c.viewCount = ListMapping.count(p["stat"]["play"])
            c.danmakuCount = ListMapping.count(p["stat"]["danmaku"])
            c.badge = p["badge"]["text"].stringValue
            c.ownerName = author["name"].stringValue
            c.pubdate = author["pub_ts"].int64Value
            if c.epId != 0 || c.seasonId != 0 { d.video = c }
            if d.type == .other { d.type = .pgc }
        case "MAJOR_TYPE_OPUS":
            let o = major["opus"]
            d.title = o["title"].stringValue
            if d.text.isEmpty {
                let (t, e) = flattenRichText(o["summary"])
                d.text = t
                d.emojis.merge(e) { a, _ in a }
            }
            d.images = o["pics"].arrayValue.map { ListMapping.image($0["url"]) }.filter { !$0.isEmpty }
            let jump = o["jump_url"].stringValue.biliHTTPS
            if !jump.isEmpty { d.jumpURL = jump }
        case "MAJOR_TYPE_DRAW":
            d.images = major["draw"]["items"].arrayValue.map { ListMapping.image($0["src"]) }.filter { !$0.isEmpty }
        case "MAJOR_TYPE_ARTICLE":
            let a = major["article"]
            d.title = a["title"].stringValue
            if d.text.isEmpty { d.text = a["desc"].stringValue }
            d.images = a["covers"].arrayValue.map { ListMapping.image($0) }.filter { !$0.isEmpty }
            let jump = a["jump_url"].stringValue.biliHTTPS
            if !jump.isEmpty { d.jumpURL = jump }
        case "MAJOR_TYPE_LIVE_RCMD", "MAJOR_TYPE_SUBSCRIPTION_NEW":
            let content = mt == "MAJOR_TYPE_LIVE_RCMD"
                ? major["live_rcmd"]["content"] : major["subscription_new"]["live_rcmd"]["content"]
            let info = (content.string.flatMap { try? JSON(string: $0) } ?? content)["live_play_info"]
            let room = info["room_id"].int64Value
            if room != 0 {
                var c = VideoCard(id: "live-\(room)")
                c.kind = .live
                c.roomId = room
                c.title = info["title"].stringValue
                c.cover = ListMapping.image(info["cover"])
                c.ownerMid = info["uid"].int64 ?? author["mid"].int64Value
                c.ownerName = author["name"].stringValue
                c.ownerFace = ListMapping.image(author["face"])
                c.reason = info["watched_show"]["text_large"].stringValue
                c.viewCount = ListMapping.count(info["online"])
                c.desc = info["area_name"].stringValue
                c.badge = info["live_status"].intValue == 1 ? "直播中" : "直播"
                c.uri = "https://live.bilibili.com/\(room)"
                d.video = c
            }
            if d.type == .other { d.type = .live }
        case "MAJOR_TYPE_LIVE":
            let l = major["live"]
            let room = l["id"].int64Value
            if room != 0 {
                var c = VideoCard(id: "live-\(room)")
                c.kind = .live
                c.roomId = room
                c.title = l["title"].stringValue
                c.cover = ListMapping.image(l["cover"])
                c.ownerMid = author["mid"].int64Value
                c.ownerName = author["name"].stringValue
                c.reason = l["desc_first"].stringValue
                c.badge = l["live_state"].intValue == 1 ? "直播中" : (l["badge"]["text"].string ?? "直播")
                c.uri = "https://live.bilibili.com/\(room)"
                d.video = c
            }
            if d.type == .other { d.type = .live }
        case "MAJOR_TYPE_COURSES", "MAJOR_TYPE_MEDIALIST", "MAJOR_TYPE_MUSIC", "MAJOR_TYPE_COMMON":
            let key = ["MAJOR_TYPE_COURSES": "courses", "MAJOR_TYPE_MEDIALIST": "medialist",
                       "MAJOR_TYPE_MUSIC": "music", "MAJOR_TYPE_COMMON": "common"][mt] ?? ""
            let o = major[key]
            d.title = o["title"].stringValue
            if d.text.isEmpty { d.text = o["desc"].string ?? o["sub_title"].stringValue }
            let cover = ListMapping.image(o["cover"])
            if !cover.isEmpty { d.images = [cover] }
            let jump = o["jump_url"].stringValue.biliHTTPS
            if !jump.isEmpty { d.jumpURL = jump }
        case "MAJOR_TYPE_NONE":
            d.isDeleted = true
            let tips = major["none"]["tips"].stringValue
            if d.text.isEmpty { d.text = tips.isEmpty ? "动态已被删除" : tips }
        case "MAJOR_TYPE_BLOCKED":
            let hint = major["blocked"]["hint_message"].stringValue
            if d.text.isEmpty { d.text = hint.isEmpty ? "内容不可见" : hint }
        default:
            break
        }
    }

    /// `major.archive` / `major.ugc_season` → VideoCard (spec §7.1).
    static func archiveCard(_ a: JSON, author: JSON, desc: String) -> VideoCard? {
        var c = VideoCard(id: "")
        ListMapping.applyIDs(&c, aid: a["aid"].int64Value, bvid: a["bvid"].stringValue)
        guard !c.id.isEmpty else { return nil }
        c.kind = .video
        c.title = a["title"].stringValue
        c.cover = ListMapping.image(a["cover"])
        c.duration = ListMapping.duration(a["duration_text"])
        c.viewCount = ListMapping.count(a["stat"]["play"])
        c.danmakuCount = ListMapping.count(a["stat"]["danmaku"])
        c.ownerMid = author["mid"].int64Value
        c.ownerName = author["name"].stringValue
        c.ownerFace = ListMapping.image(author["face"])
        c.pubdate = author["pub_ts"].int64Value
        c.reason = author["pub_action"].stringValue
        let archiveDesc = a["desc"].stringValue
        c.desc = archiveDesc.isEmpty ? desc : archiveDesc
        let badge = a["badge"]["text"].stringValue
        if badge != "投稿视频" { c.badge = badge }
        c.uri = a["jump_url"].stringValue.biliHTTPS
        if a["type"].intValue == 2 {
            let ep = ListMapping.epId(inURL: c.uri)
            if ep != 0 {
                c.kind = .bangumi
                c.epId = ep
            }
        }
        return c
    }

    /// `desc` / `summary` → plain text + emoji map. Each rich node's `text` already holds its display
    /// form (`[doge]`, `@name`, `#topic#`, link titles).
    static func flattenRichText(_ desc: JSON) -> (text: String, emojis: [String: String]) {
        let nodes = desc["rich_text_nodes"].arrayValue
        guard !nodes.isEmpty else { return (desc["text"].stringValue, [:]) }
        var out = ""
        var emojis: [String: String] = [:]
        for n in nodes {
            let t = n["text"].string ?? n["orig_text"].stringValue
            out += t
            if n["type"].stringValue == "RICH_TEXT_NODE_TYPE_EMOJI" {
                let e = n["emoji"]
                let url = [e["webp_url"], e["gif_url"], e["icon_url"]].map(\.stringValue).first { !$0.isEmpty } ?? ""
                let name = e["text"].string ?? t
                if !url.isEmpty, !name.isEmpty { emojis[name] = url.biliHTTPS }
            }
        }
        return (out, emojis)
    }

    // MARK: - UP strip

    /// Followed UPs for the dynamics header: currently-live UPs first, then UPs with updates.
    static func upList() async throws -> [DynamicUpEntry] {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/polymer/web-dynamic/v1/portal",
            query: ["up_list_more": 1, "web_location": "333.1365"])
        return parseUpList(data)
    }

    static func parseUpList(_ data: JSON) -> [DynamicUpEntry] {
        var out: [DynamicUpEntry] = []
        var index: [Int64: Int] = [:]
        for j in data["live_users"]["items"].arrayValue {
            let mid = j["mid"].int64Value
            guard mid != 0, index[mid] == nil else { continue }
            var u = UserBrief(mid: mid)
            u.name = j["uname"].stringValue
            u.face = ListMapping.image(j["face"])
            u.isFollowed = true
            index[mid] = out.count
            out.append(DynamicUpEntry(user: u, hasUpdate: false, isLive: true,
                                      roomId: j["room_id"].int64Value, liveTitle: j["title"].stringValue))
        }
        let ups = data["up_list"].array ?? data["up_list"]["items"].array ?? data["items"].arrayValue
        for j in ups {
            let mid = j["mid"].int64Value
            guard mid != 0 else { continue }
            let hasUpdate = j["has_update"].boolValue
            if let i = index[mid] {
                out[i].hasUpdate = out[i].hasUpdate || hasUpdate
                continue
            }
            var u = UserBrief(mid: mid)
            u.name = j["uname"].stringValue
            u.face = ListMapping.image(j["face"])
            u.isFollowed = true
            index[mid] = out.count
            out.append(DynamicUpEntry(user: u, hasUpdate: hasUpdate))
        }
        return out
    }

    // MARK: - Like

    /// JSON body of `/x/dynamic/feed/dyn/thumb` (`up` 1 = like, 2 = cancel).
    static func likeBody(dynamicId: String, like: Bool) -> [String: Any] {
        ["dyn_id_str": dynamicId, "up": like ? 1 : 2, "spmid": "333.1365.0.0"]
    }

    /// 点赞 / 取消点赞 a dynamic: `POST /x/dynamic/feed/dyn/thumb?csrf=` with a **JSON** body (PiliPlus
    /// passes a Map to Dio without a content type, i.e. `application/json`; the web client does the same).
    /// Falls back to the legacy vc endpoint.
    static func like(dynamicId: String, like: Bool) async throws {
        let http = BiliHTTP.shared
        guard let csrf = http.csrf else { throw BiliError.notLoggedIn }
        do {
            let root = try await VideoAPI.postJSON(
                BiliHost.api + "/x/dynamic/feed/dyn/thumb", query: ["csrf": csrf],
                body: likeBody(dynamicId: dynamicId, like: like), signWbi: false, referer: "https://t.bilibili.com/")
            _ = try BiliHTTP.unwrap(root)
        } catch BiliError.api(let code, let msg) {
            if code == -101 { throw BiliError.api(code: code, message: msg) }
            // 65006 已赞过 / 65004 未点赞: already in the requested state.
            if code == 65006 || code == 65004 { return }
            _ = try await http.post(BiliHost.message + "/dynamic_like/v1/dynamic_like/thumb",
                                    form: ["dynamic_id": dynamicId, "up": like ? 1 : 2, "uid": http.mid ?? 0])
        }
    }
}
