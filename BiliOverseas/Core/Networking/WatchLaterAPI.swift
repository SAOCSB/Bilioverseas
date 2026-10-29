import Foundation

/// 稍后再看 (login required). `progress` is seconds watched, `-1` = 已看完.
enum WatchLaterAPI {
    /// The whole list (classic `/x/v2/history/toview`, one request); falls back to paging the web list.
    static func list() async throws -> [VideoCard] {
        do {
            let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/v2/history/toview")
            return parseList(data)
        } catch {
            if ListMapping.isCancellation(error) { throw error }
            if case BiliError.api(let code, _) = error, code == -101 { throw error }
            var all: [VideoCard] = []
            var cursor: String?
            for _ in 0..<50 {
                let p = try await page(cursor: cursor)
                all += p.items
                guard p.hasMore, let n = p.next else { break }
                cursor = n
            }
            return all
        }
    }

    /// One page of the web list (`/x/v2/history/toview/web`, WBI). `viewed`: 0 全部, 2 未看完.
    static func page(cursor: String?, viewed: Int = 0, keyword: String = "", ascending: Bool = false,
                     pageSize: Int = 20) async throws -> Page<VideoCard> {
        let pn = ListCursor.page(cursor)
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/v2/history/toview/web",
            query: [
                "pn": pn, "ps": pageSize, "viewed": viewed, "key": keyword, "asc": ascending ? "true" : "false",
                "need_split": "true", "web_location": "333.881",
            ],
            sign: .wbi)
        return parsePage(data, page: pn, pageSize: pageSize)
    }

    static func parseList(_ data: JSON) -> [VideoCard] {
        data["list"].arrayValue.compactMap(laterCard)
    }

    static func parsePage(_ data: JSON, page: Int, pageSize: Int) -> Page<VideoCard> {
        let cards = parseList(data)
        let total = data["count"].intValue
        let hasMore = !cards.isEmpty && (total > 0 ? page * pageSize < total : cards.count >= pageSize)
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    static func laterCard(_ j: JSON) -> VideoCard? {
        guard var c = ListMapping.hotVideo(j) else { return nil }
        c.progress = j["progress"].intValue
        c.viewAt = j["add_at"].int64Value
        if j["is_pgc"].boolValue || j["bangumi"].object != nil {
            let ep = j["bangumi"]["ep_id"].int64Value
            if ep != 0 {
                c.kind = .bangumi
                c.epId = ep
                c.seasonId = j["bangumi"]["season"]["season_id"].int64Value
                let seasonTitle = j["bangumi"]["season"]["title"].stringValue
                if !seasonTitle.isEmpty, c.title.hasPrefix(seasonTitle + " ") {
                    c.desc = String(c.title.dropFirst(seasonTitle.count + 1))
                }
            }
        }
        if j["is_pugv"].boolValue {
            c.badge = "课堂"
        }
        return c
    }

    // MARK: Mutations

    static func add(aid: Int64) async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/add", form: ["aid": aid])
    }

    static func add(bvid: String) async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/add", form: ["bvid": bvid])
    }

    static func remove(aids: [Int64]) async throws {
        guard !aids.isEmpty else { return }
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/v2/dels",
                                           form: ["resources": aids.map { String($0) }.joined(separator: ",")])
    }

    /// 移除已观看.
    static func clearWatched() async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/clear", form: ["clean_type": 2])
    }

    /// 移除失效视频.
    static func clearInvalid() async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/clear", form: ["clean_type": 1])
    }

    /// 清空.
    static func clearAll() async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v2/history/toview/clear", form: [:])
    }
}
