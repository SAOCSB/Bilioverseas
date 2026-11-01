import Foundation

/// 短视频: the Android app's vertical "story" feed (`app.bilibili.com/x/v2/feed/index/story`, what the
/// app plays after a vertical video is tapped in 推荐). Works logged out; a TV-login `access_key`
/// personalises it like the app home feed. Pages hold 5–6 videos, about half of them portrait; the
/// feed never ends. Paging keeps the entry video and counts `display_id` up from 1.
/// With `SwipeFeedSource.web`, bilibili.com's 推荐 stands in for it, personalised by the web login.
enum ShortVideoAPI {
    /// The source chosen, else the one a login personalises: without a TV login the vertical feed is anonymous. Only
    /// 「只看竖屏」 stays with it either way, since the web feed has hardly any vertical videos.
    static func source(chosen: SwipeFeedSource?) -> SwipeFeedSource {
        source(chosen: chosen, hasAppToken: FeedAPI.appAuth() != nil, isLoggedIn: BiliHTTP.shared.isLoggedIn,
               onlyPortrait: AppSettings.shared.general.swipesOnlyPortrait)
    }

    static func source(chosen: SwipeFeedSource?, hasAppToken: Bool, isLoggedIn: Bool, onlyPortrait: Bool) -> SwipeFeedSource {
        chosen ?? (!hasAppToken && isLoggedIn && !onlyPortrait ? .web : .official)
    }

    /// Why a source would not go by the account, for where it is chosen.
    static func loginNote(for source: SwipeFeedSource) -> String? {
        switch source {
        case .official: return FeedAPI.appAuth() == nil ? "未 TV 登录，不按账号推荐" : nil
        case .web: return BiliHTTP.shared.isLoggedIn ? nil : "未登录，不按账号推荐"
        }
    }

    /// One page of the feed. `start` is the video it was entered from (page 1 only); `cursor` is the
    /// previous page's `next`.
    static func feed(start: ShortVideoItem?, cursor: ShortVideoCursor?,
                     source: SwipeFeedSource = .official) async throws -> ShortVideoPage {
        if source == .web {
            do {
                return try await webFeed(cursor: cursor)
            } catch {
                // Chosen, this is the answer. Only as the login's default, the official feed still works.
                if ListMapping.isCancellation(error) || AppSettings.shared.general.swipeFeedSource == .web { throw error }
                let code = (error as? BiliError).map { "\($0)" } ?? "error"
                PlaybackSession.routeLog?("swipe feed web: \(code.prefix(80)), official instead")
            }
        }
        let displayId = cursor?.displayId ?? 1
        // A web page's cursor knows no video to go on from.
        let aid = cursor.flatMap { $0.aid != 0 ? $0.aid : nil } ?? start?.aid ?? 0
        let bvid = cursor.flatMap { $0.bvid.isEmpty ? nil : $0.bvid } ?? start?.bvid ?? ""
        let query = storyQuery(aid: aid, bvid: bvid, displayId: displayId)
        if let auth = FeedAPI.appAuth() {
            var personal = query
            personal["access_key"] = auth.token
            do {
                let page = parseStory(try await request(personal, key: auth.key), displayId: displayId, aid: aid, bvid: bvid)
                if !page.items.isEmpty {
                    trace(page, source: "official with TV login", number: displayId)
                    return page
                }
                PlaybackSession.routeLog?("swipe feed official with TV login: empty, anonymous instead")
            } catch {
                // The personalised feed failed or came back empty: the anonymous one still works. A
                // read-only feed never signs anyone out; only actions that need the login drop a token.
                if ListMapping.isCancellation(error) { throw error }
                let code = (error as? BiliError).map { "\($0)" } ?? "error"
                PlaybackSession.routeLog?("swipe feed official with TV login: \(code.prefix(80)), anonymous instead")
            }
        }
        let page = parseStory(try await request(query, key: ListMapping.appKey), displayId: displayId, aid: aid, bvid: bvid)
        trace(page, source: "official anonymous", number: displayId)
        return page
    }

    /// bilibili.com's 推荐 as a feed of swipes. Its cards come without a size, which swipes need to show them, and without
    /// most counts: the lookup of the sizes has those too.
    private static func webFeed(cursor: ShortVideoCursor?) async throws -> ShortVideoPage {
        let number = cursor?.displayId ?? 1
        let cards = swipeCards(try await FeedAPI.recommend(cursor: String(number - 1)).items)
        let looked = await FeedAPI.lookUpVideos(cards)
        let sized = FeedAPI.applyVideoSizes(FeedAPI.videoSizes(looked), to: cards)
        let allowed = FeedFilter.liveFilter(scope: .recommend)
        let items = zip(cards, sized).filter { allowed($0.1) }.map { card, sized in
            webItem(from: sized, lookedUp: FeedAPI.sizeLookupID(card).flatMap { looked[$0] })
        }
        let page = ShortVideoPage(items: items, next: ShortVideoCursor(aid: 0, bvid: "", displayId: number + 1))
        trace(page, source: "web", number: number)
        return page
    }

    /// A web card as a video to swipe to. The lookup can miss it, and then it counts as landscape, like nearly all of them.
    static func webItem(from card: VideoCard, lookedUp: JSON?) -> ShortVideoItem {
        var v = item(from: card)
        if let lookedUp {
            let stat = lookedUp["stat"]
            v.replyCount = stat["reply"].int64Value
            v.coinCount = stat["coin"].int64Value
            v.favoriteCount = stat["favorite"].int64Value
            v.shareCount = stat["share"].int64Value
            v.copyright = lookedUp["copyright"].intValue
        }
        if v.width <= 0 || v.height <= 0 {
            v.width = 16
            v.height = 9
        }
        return v
    }

    /// The cards of a feed that swipes can go to.
    static func swipeCards(_ cards: [VideoCard]) -> [VideoCard] {
        cards.filter { $0.kind == .video && $0.adSignals.isEmpty && ($0.aid != 0 || !$0.bvid.isEmpty) }
    }

    /// What the feed gave, for the playback log: the only way to tell afterwards which feed a viewer was on.
    private static func trace(_ page: ShortVideoPage, source: String, number: Int) {
        let landscape = page.items.filter { !$0.isPortrait }.count
        let followed = page.items.filter(\.isFollowing).count
        PlaybackSession.routeLog?("swipe feed \(source) page \(number): \(page.items.count) videos, \(landscape) landscape, "
            + "\(followed) by followed uploaders")
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
