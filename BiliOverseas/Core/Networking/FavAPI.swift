import Foundation

/// 收藏夹: folders, contents and mutations.
enum FavAPI {
    // MARK: - Folders

    /// All folders created by `mid`, with covers (pages `created/list`; falls back to `list-all`, no covers).
    static func myFolders(mid: Int64) async throws -> [FavFolder] {
        do {
            var all: [FavFolder] = []
            var page = 1
            while page <= 20 {
                let p = try await createdFolders(mid: mid, page: page)
                all += p.items
                guard p.hasMore else { break }
                page += 1
            }
            return all
        } catch {
            if ListMapping.isCancellation(error) { throw error }
            return try await allFolders(mid: mid)
        }
    }

    /// One page of `created/list` (has covers).
    static func createdFolders(mid: Int64, page: Int = 1, pageSize: Int = 20) async throws -> Page<FavFolder> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/v3/fav/folder/created/list",
            query: ["pn": page, "ps": pageSize, "up_mid": mid, "web_location": "333.1387"])
        return parseFolderPage(data, page: page)
    }

    /// `created/list-all`: every folder in one request (no covers). With `rid` (aid, or ep_id with
    /// `type: 24`) each folder's `containsResource` tells whether it already holds that item.
    static func allFolders(mid: Int64, rid: Int64? = nil, type: Int = 2) async throws -> [FavFolder] {
        var query: [String: Any] = ["up_mid": mid]
        if let rid { query["rid"] = rid; query["type"] = type }
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/v3/fav/folder/created/list-all", query: query)
        return data["list"].arrayValue.compactMap(parseFolder)
    }

    /// Subscribed folders and 合集 (收藏的收藏夹/合集).
    static func collectedFolders(mid: Int64, page: Int = 1, pageSize: Int = 20) async throws -> Page<FavFolder> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/v3/fav/folder/collected/list",
            query: ["up_mid": mid, "pn": page, "ps": pageSize, "platform": "web"])
        return parseFolderPage(data, page: page)
    }

    static func parseFolderPage(_ data: JSON, page: Int) -> Page<FavFolder> {
        let folders = data["list"].arrayValue.compactMap(parseFolder)
        let hasMore: Bool
        if let more = data["has_more"].bool { hasMore = more && !folders.isEmpty } else {
            hasMore = !folders.isEmpty && folders.count + (page - 1) * 20 < data["count"].intValue
        }
        return Page(items: folders, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    static func parseFolder(_ j: JSON) -> FavFolder? {
        let id = j["id"].int64 ?? j["media_id"].int64Value
        guard id != 0 else { return nil }
        var f = FavFolder(id: id)
        f.fid = j["fid"].int64Value
        f.mid = j["mid"].int64Value
        f.title = j["title"].stringValue
        f.cover = ListMapping.image(j["cover"])
        f.count = j["media_count"].intValue
        let attr = j["attr"].intValue
        f.isPrivate = attr & 1 == 1
        f.isDefault = j["attr"].exists && attr & 2 == 0
        f.intro = j["intro"].stringValue
        let upper = j["upper"]
        f.upperMid = upper["mid"].int64 ?? f.mid
        f.upperName = upper["name"].stringValue
        f.upperFace = ListMapping.image(upper["face"])
        f.containsResource = j["fav_state"].intValue == 1
        f.isSeason = j["type"].intValue == 21
        return f
    }

    // MARK: - Contents

    /// Items of a folder. `order`: `mtime` (最近收藏) | `view` (最多播放) | `pubtime` (最近投稿).
    /// Deleted items (`attr` 1/9, "已失效视频") are skipped unless `includeInvalid`, in which case they
    /// come back as `kind == .other` with badge "已失效" (still carrying `aid` so they can be removed).
    static func folderContents(mediaId: Int64, page: Int = 1, keyword: String = "", order: String = "mtime",
                               includeInvalid: Bool = false) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/v3/fav/resource/list",
            query: [
                "media_id": mediaId, "pn": page, "ps": 20, "keyword": keyword, "order": order,
                "type": 0, "tid": 0, "platform": "web",
            ])
        return parseContents(data, page: page, includeInvalid: includeInvalid)
    }

    /// Folder header (`data.info`) of a contents response.
    static func parseFolderInfo(_ data: JSON) -> FavFolder? {
        parseFolder(data["info"])
    }

    static func parseContents(_ data: JSON, page: Int, includeInvalid: Bool = false) -> Page<VideoCard> {
        let cards = data["medias"].arrayValue.compactMap { mediaCard($0, includeInvalid: includeInvalid) }
        let hasMore = data["has_more"].boolValue
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    static func isInvalid(_ j: JSON) -> Bool {
        let attr = j["attr"].intValue
        return attr == 1 || attr == 9 || j["title"].stringValue == "已失效视频"
    }

    static func mediaCard(_ j: JSON, includeInvalid: Bool = false) -> VideoCard? {
        let invalid = isInvalid(j)
        if invalid && !includeInvalid { return nil }
        let type = j["type"].int ?? 2
        let id = j["id"].int64Value
        guard id != 0 else { return nil }
        var c = VideoCard(id: "")
        c.title = j["title"].stringValue
        c.cover = ListMapping.image(j["cover"])
        c.desc = j["intro"].stringValue
        c.duration = ListMapping.duration(j["duration"])
        ListMapping.applyOwner(&c, j["upper"])
        c.viewCount = ListMapping.count(j["cnt_info"]["play"])
        c.danmakuCount = ListMapping.count(j["cnt_info"]["danmaku"])
        c.pubdate = j["pubtime"].int64 ?? j["ctime"].int64Value
        c.viewAt = j["fav_time"].int64Value
        c.pageCount = j["page"].intValue
        switch type {
        case 24:
            c.kind = .bangumi
            c.epId = id
            c.seasonId = j["ogv"]["season_id"].int64Value
            c.id = "ep\(id)"
            c.badge = j["ogv"]["type_name"].stringValue
            let bvid = j["bvid"].string ?? j["bv_id"].stringValue
            if !bvid.isEmpty { c.bvid = bvid }
        case 12:
            c.kind = .other
            c.id = "au\(id)"
            c.badge = "音频"
            c.uri = "https://www.bilibili.com/audio/au\(id)"
        default:
            ListMapping.applyIDs(&c, aid: id, bvid: j["bvid"].string ?? j["bv_id"].stringValue)
            c.cid = j["ugc"]["first_cid"].int64Value
            c.kind = .video
            c.uri = "https://www.bilibili.com/video/\(c.bvid)"
        }
        if invalid {
            c.kind = .other
            c.badge = "已失效"
        }
        return c
    }

    /// Items of a subscribed UGC 合集 (`FavFolder.isSeason`).
    static func seasonContents(seasonId: Int64, page: Int = 1) async throws -> Page<VideoCard> {
        let data = try await BiliHTTP.shared.api(
            BiliHost.api + "/x/space/fav/season/list", query: ["season_id": seasonId, "pn": page, "ps": 20])
        let cards = data["medias"].arrayValue.compactMap { mediaCard($0) }
        let total = data["info"]["media_count"].intValue
        let hasMore = !cards.isEmpty && (total > 0 ? page * 20 < total : cards.count >= 20)
        return Page(items: cards, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    // MARK: - Mutations

    /// `"<rid>:<type>"` for a card: video `aid:2`, PGC `ep_id:24`.
    static func resourceKey(for card: VideoCard) -> String {
        if card.kind == .bangumi, card.epId != 0, card.aid == 0 || card.id.hasPrefix("ep") { return "\(card.epId):24" }
        return "\(card.aid):2"
    }

    @discardableResult
    static func createFolder(title: String, intro: String = "", isPrivate: Bool = false) async throws -> FavFolder {
        let data = try await BiliHTTP.shared.post(
            BiliHost.api + "/x/v3/fav/folder/add",
            form: ["title": title, "intro": intro, "privacy": isPrivate ? 1 : 0, "cover": ""])
        var f = parseFolder(data) ?? FavFolder(id: data.int64Value)
        if f.title.isEmpty { f.title = title }
        if f.intro.isEmpty { f.intro = intro }
        f.isPrivate = isPrivate
        return f
    }

    static func editFolder(mediaId: Int64, title: String, intro: String = "", isPrivate: Bool = false) async throws {
        _ = try await BiliHTTP.shared.post(
            BiliHost.api + "/x/v3/fav/folder/edit",
            form: ["media_id": mediaId, "title": title, "intro": intro, "privacy": isPrivate ? 1 : 0, "cover": ""])
    }

    static func deleteFolder(mediaId: Int64) async throws {
        try await deleteFolders(mediaIds: [mediaId])
    }

    static func deleteFolders(mediaIds: [Int64]) async throws {
        guard !mediaIds.isEmpty else { return }
        _ = try await BiliHTTP.shared.post(
            BiliHost.api + "/x/v3/fav/folder/del",
            form: ["media_ids": mediaIds.map { String($0) }.joined(separator: ","), "platform": "web"])
    }

    /// Removes items from one folder. `resources` are `"<rid>:<type>"` keys (see `resourceKey(for:)`).
    static func removeItems(mediaId: Int64, resources: [String]) async throws {
        guard !resources.isEmpty else { return }
        let joined = resources.joined(separator: ",")
        do {
            _ = try await BiliHTTP.shared.post(
                BiliHost.api + "/x/v3/fav/resource/batch-del",
                form: ["media_id": mediaId, "resources": joined, "platform": "web"])
        } catch BiliError.api(let code, _) where code != -101 && code != -111 {
            // Fall back to batch-deal (what PiliPlus uses), one resource at a time.
            for r in resources {
                try await deal(resource: r, add: [], remove: [mediaId])
            }
        }
    }

    static func removeItems(mediaId: Int64, cards: [VideoCard]) async throws {
        try await removeItems(mediaId: mediaId, resources: cards.map(resourceKey(for:)))
    }

    /// Adds / removes one resource to / from several folders at once (收藏弹窗).
    static func deal(resource: String, add: [Int64], remove: [Int64]) async throws {
        _ = try await BiliHTTP.shared.post(
            BiliHost.api + "/x/v3/fav/resource/batch-deal",
            form: [
                "resources": resource,
                "add_media_ids": add.map { String($0) }.joined(separator: ","),
                "del_media_ids": remove.map { String($0) }.joined(separator: ","),
                "platform": "web",
            ])
    }

    /// 清除失效内容.
    static func cleanInvalid(mediaId: Int64) async throws {
        _ = try await BiliHTTP.shared.post(BiliHost.api + "/x/v3/fav/resource/clean",
                                           form: ["media_id": mediaId, "platform": "web"])
    }
}
