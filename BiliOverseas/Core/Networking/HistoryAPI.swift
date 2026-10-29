import Foundation

/// 观看历史 (login required).
///
/// Card ids are `<business>_<kid>` (e.g. `archive_123456`, `pgc_7890`), which is exactly what
/// `delete(card:)` sends. `progress` is seconds watched, `-1` = 已看完; `viewAt` = unix seconds.
enum HistoryAPI {
    /// History tabs (`type` param).
    static let tabs: [(type: String, name: String)] = [
        ("all", "全部"), ("archive", "视频"), ("live", "直播"), ("article", "专栏"),
    ]

    /// One page. `cursor` is the opaque `next` of the previous page (`"max|view_at|business"`), nil = first page.
    static func list(cursor: String?, type: String = "all", pageSize: Int = 20) async throws -> Page<VideoCard> {
        let c = decodeCursor(cursor)
        var query: [String: Any] = ["type": type, "ps": pageSize, "max": c.max, "view_at": c.viewAt]
        if !c.business.isEmpty { query["business"] = c.business }
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/web-interface/history/cursor", query: query)
        return parseList(data)
    }

    /// Searches the history (`pn` pages).
    static func search(keyword: String, page: Int = 1) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/web-interface/history/search",
            query: ["pn": page, "keyword": keyword, "business": "all"])
        let cards = data["list"].arrayValue.compactMap(historyCard)
        let hasMore = !cards.isEmpty && data["has_more"].bool != false
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    // MARK: Cursor

    static func encodeCursor(max: Int64, viewAt: Int64, business: String) -> String {
        "\(max)|\(viewAt)|\(business)"
    }

    static func decodeCursor(_ cursor: String?) -> (max: Int64, viewAt: Int64, business: String) {
        guard let cursor, !cursor.isEmpty else { return (0, 0, "") }
        let parts = cursor.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let max = parts.count > 0 ? Int64(parts[0]) ?? 0 : 0
        let viewAt = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
        let business = parts.count > 2 ? parts[2] : ""
        return (max, viewAt, business)
    }

    /// `data` of history/cursor → page. The next cursor is the server's `data.cursor` when present,
    /// else (like PiliPlus) the last item's `history.oid` / `view_at` / `history.business`.
    static func parseList(_ data: JSON) -> Page<VideoCard> {
        let list = data["list"].arrayValue
        let cards = list.compactMap(historyCard)
        guard let last = list.last else { return Page(items: [], hasMore: false) }
        var max = data["cursor"]["max"].int64Value
        var viewAt = data["cursor"]["view_at"].int64Value
        var business = data["cursor"]["business"].stringValue
        if max == 0 || viewAt == 0 {
            max = last["history"]["oid"].int64Value
            viewAt = last["view_at"].int64Value
            business = last["history"]["business"].stringValue
        }
        let hasMore = viewAt != 0
        return Page(items: cards, hasMore: hasMore,
                    next: hasMore ? encodeCursor(max: max, viewAt: viewAt, business: business) : nil)
    }

    static func historyCard(_ j: JSON) -> VideoCard? {
        let h = j["history"]
        let business = h["business"].stringValue
        let oid = h["oid"].int64Value
        let kid = j["kid"].int64 ?? oid
        guard !business.isEmpty || oid != 0 else { return nil }
        var c = VideoCard(id: "\(business.isEmpty ? "archive" : business)_\(kid)")
        c.title = j["title"].stringValue
        c.cover = ListMapping.image(j["cover"])
        if c.cover.isEmpty { c.cover = ListMapping.image(j["covers"][0]) }
        c.duration = ListMapping.duration(j["duration"])
        c.progress = j["progress"].intValue
        c.viewAt = j["view_at"].int64Value
        c.ownerMid = j["author_mid"].int64Value
        c.ownerName = j["author_name"].stringValue
        c.ownerFace = ListMapping.image(j["author_face"])
        c.desc = j["show_title"].stringValue
        c.badge = j["badge"].stringValue
        c.pageCount = j["videos"].intValue
        c.uri = j["uri"].stringValue
        switch business {
        case "archive", "":
            c.kind = .video
            c.aid = oid
            c.bvid = h["bvid"].string.flatMap { $0.isEmpty ? nil : $0 } ?? (oid > 0 ? BVConverter.av2bv(oid) : "")
            c.cid = h["cid"].int64Value
        case "pgc":
            c.kind = .bangumi
            c.aid = oid
            c.bvid = h["bvid"].stringValue
            c.cid = h["cid"].int64Value
            c.epId = h["epid"].int64Value
        case "live":
            c.kind = .live
            c.roomId = oid
            c.progress = 0
            if j["live_status"].intValue == 1 { c.badge = "直播中" } else if c.badge.isEmpty { c.badge = "未开播" }
            if c.uri.isEmpty { c.uri = "https://live.bilibili.com/\(oid)" }
        case "article", "article-list":
            c.kind = .article
            let articleId = business == "article-list" ? h["cid"].int64Value : oid
            if c.uri.isEmpty || !c.uri.hasPrefix("http") { c.uri = "https://www.bilibili.com/read/cv\(articleId)" }
        default:
            // cheese (课堂) and anything else: open the web page.
            c.kind = .other
            if c.badge.isEmpty, business == "cheese" { c.badge = "课堂" }
        }
        return c
    }

    // MARK: Mutations

    /// `kid` string for history/delete: `<business>_<kid>`.
    static func historyKid(for card: VideoCard) -> String {
        if card.id.range(of: #"^[a-z\-]+_\d+$"#, options: .regularExpression) != nil { return card.id }
        switch card.kind {
        case .live: return "live_\(card.roomId)"
        default: return "archive_\(card.aid)"
        }
    }

    static func delete(card: VideoCard) async throws {
        try await delete(cards: [card])
    }

    static func delete(cards: [VideoCard]) async throws {
        guard !cards.isEmpty else { return }
        let kids = cards.map(historyKid(for:)).joined(separator: ",")
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/delete", form: ["kid": kids, "jsonp": "jsonp"])
    }

    /// 清空历史记录.
    static func clear() async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/clear", form: ["jsonp": "jsonp"])
    }

    /// 暂停记录历史 (`true`) / 恢复 (`false`).
    static func setPaused(_ paused: Bool) async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/shadow/set",
                                           form: ["switch": paused ? "true" : "false", "jsonp": "jsonp"])
    }

    static func isPaused() async throws -> Bool {
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/v2/history/shadow", query: ["jsonp": "jsonp"])
        return data.boolValue
    }
}
