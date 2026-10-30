import Foundation

/// 短视频: the Android app's vertical "story" feed (`app.bilibili.com/x/v2/feed/index/story`, what the
/// app plays after a vertical video is tapped in 推荐). Works logged out; a TV-login `access_key`
/// personalises it like the app home feed. Pages hold 5–6 videos, about half of them portrait; the
/// feed never ends. Paging keeps the entry video and counts `display_id` up from 1.
enum ShortVideoAPI {
    /// One page of the feed. `start` is the video it was entered from (page 1 only); `cursor` is the
    /// previous page's `next`.
    static func feed(start: ShortVideoItem?, cursor: ShortVideoCursor?) async throws -> ShortVideoPage {
        let displayId = cursor?.displayId ?? 1
        let aid = cursor?.aid ?? start?.aid ?? 0
        let bvid = cursor?.bvid ?? start?.bvid ?? ""
        let query = storyQuery(aid: aid, bvid: bvid, displayId: displayId)
        if let auth = FeedAPI.appAuth() {
            var personal = query
            personal["access_key"] = auth.token
            do {
                let page = parseStory(try await request(personal, key: auth.key), displayId: displayId, aid: aid, bvid: bvid)
                if !page.items.isEmpty { return page }
            } catch {
                // The personalised feed failed or came back empty: the anonymous one still works. A
                // read-only feed never signs anyone out; only actions that need the login drop a token.
                if ListMapping.isCancellation(error) { throw error }
            }
        }
        return parseStory(try await request(query, key: ListMapping.appKey), displayId: displayId, aid: aid, bvid: bvid)
    }

    private static func request(_ query: [String: Any], key: AppKey) async throws -> JSON {
        try await BiliHTTP.shared.api(BiliHost.app + "/x/v2/feed/index/story", query: query, sign: .app(key),
                                      headers: ListMapping.appHeaders())
    }

    /// The query the Android app (8.43) sends, minus `appkey` / `ts` / `sign`. `contain=false` keeps
    /// the entry video from coming back on every page.
    static func storyQuery(aid: Int64, bvid: String, displayId: Int) -> [String: Any] {
        var query = ListMapping.appParams()
        let story: [String: Any] = [
            "auto_play": 0, "contain": "false", "device": "phone", "disable_rcmd": 0, "display_id": displayId,
            "fnval": 976, "fnver": 0, "force_host": 2, "fourk": 1, "from_spmid": "tm.recommend.0.0",
            "network": "wifi", "player_net": 1, "pull": displayId == 1 ? 1 : 0, "qn": 32, "request_from": 1,
            "spmid": "main.ugc-video-detail-vertical.0.0", "video_mode": 1,
        ]
        query.merge(story) { _, new in new }
        if aid > 0 { query["aid"] = aid }
        if !bvid.isEmpty { query["bvid"] = bvid }
        return query
    }

    /// `data` of the story endpoint → videos. Without an entry video, later pages continue from the
    /// first portrait one, which keeps the feed vertical. The feed never ends: an empty page (or one of
    /// only ads) still points at the next one; the caller decides when to stop asking.
    static func parseStory(_ data: JSON, displayId: Int, aid: Int64 = 0, bvid: String = "") -> ShortVideoPage {
        let items = data["items"].arrayValue.compactMap(storyItem)
        var anchor = (aid: aid, bvid: bvid)
        if aid == 0, bvid.isEmpty, let first = items.first(where: \.isPortrait) ?? items.first {
            anchor = (first.aid, first.bvid)
        }
        return ShortVideoPage(items: items,
                              next: ShortVideoCursor(aid: anchor.aid, bvid: anchor.bvid, displayId: displayId + 1))
    }

    /// One `data.items[]` entry. Only `vertical_av` cards are videos; `vertical_ad_*`, `vertical_pgc`
    /// and `vertical_live` (and anything carrying ad markers) are dropped.
    static func storyItem(_ item: JSON) -> ShortVideoItem? {
        let goto = item["card_goto"].string ?? item["goto"].stringValue
        guard goto == "vertical_av" else { return nil }
        if ListMapping.hasPayload(item["ad_info"]) || item["card_type"].stringValue.hasPrefix("cm") { return nil }
        let args = item["player_args"]
        let uri = item["uri"].stringValue
        // A 0 counts as missing too, so the next source gets its turn.
        func positive(_ value: Int64?) -> Int64? { value.flatMap { $0 > 0 ? $0 : nil } }
        func uriNumber(_ name: String) -> Int64? { positive(ListMapping.uriQueryValue(name, in: uri).flatMap { Int64($0) }) }

        var aid = positive(args["aid"].int64) ?? positive(item["param"].int64) ?? item["stat"]["aid"].int64Value
        var bvid = item["bvid"].stringValue
        // Same ids as the list cards (ListMapping.applyIDs), so an entry card and its feed copy match.
        if bvid.isEmpty, aid > 0 { bvid = BVConverter.av2bv(aid) }
        if aid == 0, !bvid.isEmpty { aid = BVConverter.bv2av(bvid) ?? 0 }
        guard aid > 0 || !bvid.isEmpty else { return nil }
        var v = ShortVideoItem(id: !bvid.isEmpty ? bvid : "av\(aid)")
        v.aid = aid
        v.bvid = bvid
        v.cid = positive(args["cid"].int64) ?? uriNumber("cid") ?? 0
        v.title = item["title"].stringValue
        v.cover = ListMapping.image(item["cover"])
        v.duration = item["duration"].int ?? args["duration"].intValue

        let dimension = item["dimension"]
        var width = Int(positive(dimension["width"].int64) ?? uriNumber("player_width") ?? 0)
        var height = Int(positive(dimension["height"].int64) ?? uriNumber("player_height") ?? 0)
        let rotate = dimension["rotate"].int ?? ListMapping.uriQueryValue("player_rotate", in: uri).flatMap { Int($0) } ?? 0
        if rotate == 1 { swap(&width, &height) }
        v.width = width
        v.height = height

        let owner = item["owner"]
        v.ownerMid = owner["mid"].int64Value
        v.ownerName = owner["name"].stringValue
        v.ownerFace = ListMapping.image(owner["face"])
        // relation.status: 1 none, 2 following, 3 follower, 4 mutual.
        let relation = owner["relation"]["status"].intValue
        v.isFollowing = relation == 2 || relation == 4

        let stat = item["stat"]
        v.viewCount = ListMapping.count(stat["view"])
        v.danmakuCount = ListMapping.count(stat["danmaku"])
        v.likeCount = ListMapping.count(stat["like"])
        v.coinCount = ListMapping.count(stat["coin"])
        v.favoriteCount = ListMapping.count(stat["favorite"])
        v.replyCount = ListMapping.count(stat["reply"])
        v.shareCount = ListMapping.count(stat["share"])
        let desc = item["desc"].stringValue
        v.desc = desc == "-" ? "" : desc
        v.copyright = item["copyright"].intValue
        v.feedback = FeedAPI.appFeedback(item["three_point_v2"], goto: goto, param: aid)
        if v.title.isEmpty && v.cover.isEmpty { return nil }
        return v
    }

    /// The feed entry for a card tapped in a list: shown at once while page 1 loads.
    static func item(from card: VideoCard) -> ShortVideoItem {
        var v = ShortVideoItem(id: !card.bvid.isEmpty ? card.bvid : "av\(card.aid)")
        v.aid = card.aid
        v.bvid = card.bvid
        v.cid = card.cid
        v.title = card.title
        v.cover = card.cover
        v.duration = card.duration
        v.width = card.width
        v.height = card.height
        v.ownerMid = card.ownerMid
        v.ownerName = card.ownerName
        v.ownerFace = card.ownerFace
        v.isFollowing = card.isFollowed
        v.viewCount = card.viewCount
        v.danmakuCount = card.danmakuCount
        v.likeCount = card.likeCount
        v.feedback = card.feedback
        return v
    }
}
