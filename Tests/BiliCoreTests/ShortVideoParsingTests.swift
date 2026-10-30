import XCTest
@testable import BiliCore

/// 短视频: the app story feed (`x/v2/feed/index/story`) parser, its paging cursor and query, and the
/// portrait marker the app home feed's `uri` carries.
final class ShortVideoParsingTests: XCTestCase {
    private func json(_ s: String) -> JSON {
        (try? JSON(string: s)) ?? .null
    }

    /// Trimmed from a real logged-out response (2026-10-30).
    private let storyPage = #"""
    {"items":[
      {"card_goto":"vertical_av","goto":"vertical_av","param":"117518291178772","bvid":"BV1XgxE6BEE6",
       "title":"拍拍长颈鹿、被用头撞击","desc":"-","cover":"http://i2.hdslb.com/bfs/archive/c08a.jpg",
       "duration":54,"dimension":{"width":1080,"height":1920,"rotate":0},
       "stat":{"aid":117518291178772,"view":514866,"danmaku":106,"reply":957,"favorite":1179,"coin":166,
               "share":143,"like":19173},
       "player_args":{"aid":117518291178772,"cid":43126358029,"type":"av"},
       "uri":"bilibili://story/117518291178772?cid=43126358029&player_height=1920&player_rotate=0&player_width=1080",
       "idx":1,"display_id":1,"copyright":3,"req_user":{},
       "owner":{"mid":476658350,"name":"虎熊寺","face":"https://i2.hdslb.com/bfs/face/6075.jpg",
                "relation":{"status":1}}},
      {"card_goto":"vertical_av","param":"117000000000002","bvid":"BV1landscape",
       "title":"横屏测评","cover":"//i0.hdslb.com/b.jpg","duration":1492,
       "dimension":{"width":1920,"height":1080,"rotate":0},
       "player_args":{"aid":117000000000002,"cid":2002},"stat":{"like":"1.2万"},
       "owner":{"mid":2,"name":"横屏UP","relation":{"status":2}},"copyright":2},
      {"card_goto":"vertical_av","param":"117000000000003","title":"旋转过的竖屏",
       "cover":"https://i0.hdslb.com/c.jpg","dimension":{"width":1920,"height":1080,"rotate":1},
       "player_args":{"aid":117000000000003,"cid":3003},"owner":{"mid":3,"relation":{"status":4}}},
      {"card_goto":"vertical_av","param":"117000000000004","bvid":"BV1onlyuri","title":"只有uri尺寸",
       "cover":"https://i0.hdslb.com/d.jpg",
       "uri":"bilibili://story/117000000000004?cid=4004&player_width=720&player_height=1280&player_rotate=0"},
      {"card_goto":"vertical_ad_av","param":"117000000000005","title":"竖屏广告","cover":"https://x/e.jpg",
       "player_args":{"aid":117000000000005}},
      {"card_goto":"vertical_pgc","param":"6006","title":"番剧竖屏","cover":"https://x/f.jpg"},
      {"card_goto":"vertical_av","param":"117000000000007","title":"带广告信息","cover":"https://x/g.jpg",
       "ad_info":{"creative_id":1},"player_args":{"aid":117000000000007}},
      {"card_goto":"vertical_av","title":"没有id","cover":"https://x/h.jpg"}
    ]}
    """#

    func testStoryItemsFieldsAndFiltering() {
        let page = ShortVideoAPI.parseStory(json(storyPage), displayId: 1, aid: 117385835055683, bvid: "BV1RZHp67EQr")
        let derived = BVConverter.av2bv(117000000000003)
        XCTAssertEqual(page.items.map(\.id), ["BV1XgxE6BEE6", "BV1landscape", derived, "BV1onlyuri"],
                       "a missing bvid is derived from the aid, like the list cards")

        let first = page.items[0]
        XCTAssertEqual(first.aid, 117518291178772)
        XCTAssertEqual(first.cid, 43126358029)
        XCTAssertEqual(first.title, "拍拍长颈鹿、被用头撞击")
        XCTAssertEqual(first.cover, "https://i2.hdslb.com/bfs/archive/c08a.jpg")
        XCTAssertEqual(first.duration, 54)
        XCTAssertEqual(first.width, 1080)
        XCTAssertEqual(first.height, 1920)
        XCTAssertTrue(first.isPortrait)
        XCTAssertEqual(first.ownerMid, 476658350)
        XCTAssertEqual(first.ownerName, "虎熊寺")
        XCTAssertFalse(first.isFollowing)
        XCTAssertEqual(first.viewCount, 514866)
        XCTAssertEqual(first.likeCount, 19173)
        XCTAssertEqual(first.coinCount, 166)
        XCTAssertEqual(first.favoriteCount, 1179)
        XCTAssertEqual(first.replyCount, 957)
        XCTAssertEqual(first.shareCount, 143)
        XCTAssertEqual(first.danmakuCount, 106)
        XCTAssertEqual(first.desc, "", "a lone '-' is the feed's empty description")
        XCTAssertEqual(first.maxCoins, 2)
        XCTAssertEqual(first.shareURL?.absoluteString, "https://www.bilibili.com/video/BV1XgxE6BEE6")

        let landscape = page.items[1]
        XCTAssertFalse(landscape.isPortrait)
        XCTAssertTrue(landscape.isFollowing)
        XCTAssertEqual(landscape.likeCount, 12000)
        XCTAssertEqual(landscape.maxCoins, 1, "reprints take one coin")
        XCTAssertEqual(landscape.cover, "https://i0.hdslb.com/b.jpg")

        let rotated = page.items[2]
        XCTAssertEqual(rotated.width, 1080, "rotate 1 swaps the stored size")
        XCTAssertEqual(rotated.height, 1920)
        XCTAssertTrue(rotated.isPortrait)
        XCTAssertTrue(rotated.isFollowing, "status 4 is mutual following")
        XCTAssertEqual(rotated.bvid, derived)
        XCTAssertEqual(rotated.shareURL?.absoluteString, "https://www.bilibili.com/video/\(derived)")

        let fromURI = page.items[3]
        XCTAssertEqual(fromURI.aid, 117000000000004, "param stands in for player_args.aid")
        XCTAssertEqual(fromURI.cid, 4004)
        XCTAssertEqual(fromURI.width, 720)
        XCTAssertEqual(fromURI.height, 1280)
    }

    func testStoryCursorKeepsTheEntryVideo() {
        let page = ShortVideoAPI.parseStory(json(storyPage), displayId: 3, aid: 117385835055683, bvid: "BV1RZHp67EQr")
        XCTAssertEqual(page.next, ShortVideoCursor(aid: 117385835055683, bvid: "BV1RZHp67EQr", displayId: 4))
    }

    func testStoryWithoutEntryContinuesFromFirstPortrait() {
        let data = json(#"""
        {"items":[
          {"card_goto":"vertical_av","param":"11","bvid":"BV1wide","title":"横","cover":"https://x/a.jpg",
           "dimension":{"width":1920,"height":1080}},
          {"card_goto":"vertical_av","param":"12","bvid":"BV1tall","title":"竖","cover":"https://x/b.jpg",
           "dimension":{"width":1080,"height":1920}}
        ]}
        """#)
        let page = ShortVideoAPI.parseStory(data, displayId: 1)
        XCTAssertEqual(page.next, ShortVideoCursor(aid: 12, bvid: "BV1tall", displayId: 2))
    }

    func testEmptyStoryPageKeepsPaging() {
        // The feed never ends: an empty (or all-ads) page points at the next one with the same entry.
        let empty = ShortVideoAPI.parseStory(json(#"{"items":[]}"#), displayId: 2, aid: 1, bvid: "BV1")
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.next, ShortVideoCursor(aid: 1, bvid: "BV1", displayId: 3))
        let adsOnly = ShortVideoAPI.parseStory(json(#"""
        {"items":[{"card_goto":"vertical_ad_av","param":"5","title":"广告","cover":"https://x/a.jpg"}]}
        """#), displayId: 4, aid: 7)
        XCTAssertEqual(adsOnly.next?.displayId, 5)
        XCTAssertEqual(adsOnly.next?.aid, 7)
    }

    func testZeroFieldsFallBackToTheNextSource() {
        let data = json(#"""
        {"items":[{"card_goto":"vertical_av","param":"117000000000009","title":"零值","cover":"https://x/z.jpg",
                   "player_args":{"aid":0,"cid":0},"dimension":{"width":0,"height":0,"rotate":0},
                   "uri":"bilibili://story/117000000000009?cid=909&player_width=720&player_height=1280"}]}
        """#)
        let item = ShortVideoAPI.parseStory(data, displayId: 1).items[0]
        XCTAssertEqual(item.aid, 117000000000009)
        XCTAssertEqual(item.cid, 909)
        XCTAssertEqual(item.width, 720)
        XCTAssertEqual(item.height, 1280)
        XCTAssertEqual(item.id, BVConverter.av2bv(117000000000009))
    }

    func testURIQueryValues() {
        XCTAssertEqual(ListMapping.uriQueryValue("cid", in: "bilibili://story/1?cid=42&player_width=1080"), "42")
        XCTAssertEqual(ListMapping.uriQueryValue("player_width", in: "bilibili://story/1?cid=42&player_width=1080"), "1080")
        XCTAssertNil(ListMapping.uriQueryValue("missing", in: "bilibili://story/1?cid=42"))
        // JSON in a value (player_preload) must not hide the parameters after it.
        let uri = #"bilibili://story/1?cid=7&player_preload={"a":"b c"}&player_height=1920"#
        XCTAssertEqual(ListMapping.uriQueryValue("player_height", in: uri), "1920")
        XCTAssertEqual(ListMapping.uriQueryValue("cid", in: uri), "7")
    }

    func testOnlyTokenCodesDropTheTVLogin() {
        for code in [-101, -2, -663] {
            XCTAssertTrue(AuthService.isRejectedAppToken(BiliError.api(code: code, message: "")), "\(code)")
        }
        for code in [-400, -352, 0, 65007] {
            XCTAssertFalse(AuthService.isRejectedAppToken(BiliError.api(code: code, message: "")), "\(code)")
        }
        XCTAssertFalse(AuthService.isRejectedAppToken(BiliError.http(status: 500)))
        XCTAssertEqual(VideoAPI.friendlyMessage(code: 65007), "已经点过踩了")
        XCTAssertEqual(VideoAPI.friendlyMessage(code: 65005), "还没有点过踩")
    }

    func testStoryQuery() {
        let first = ShortVideoAPI.storyQuery(aid: 117385835055683, bvid: "BV1RZHp67EQr", displayId: 1)
        XCTAssertEqual(first["aid"] as? Int64, 117385835055683)
        XCTAssertEqual(first["bvid"] as? String, "BV1RZHp67EQr")
        XCTAssertEqual(first["display_id"] as? Int, 1)
        XCTAssertEqual(first["pull"] as? Int, 1)
        XCTAssertEqual(first["contain"] as? String, "false")
        XCTAssertEqual(first["fnval"] as? Int, 976)
        XCTAssertEqual(first["mobi_app"] as? String, "android")
        XCTAssertEqual(first["build"] as? Int, ListMapping.appBuild)
        XCTAssertEqual(first["spmid"] as? String, "main.ugc-video-detail-vertical.0.0")

        let later = ShortVideoAPI.storyQuery(aid: 0, bvid: "", displayId: 3)
        XCTAssertNil(later["aid"])
        XCTAssertNil(later["bvid"])
        XCTAssertEqual(later["pull"] as? Int, 0)
        XCTAssertEqual(later["display_id"] as? Int, 3)
    }

    func testAppFeedCardsKnowTheirShape() {
        XCTAssertTrue(FeedAPI.appVideoSize(uri: "bilibili://video/1?player_width=1080&player_height=1920&player_rotate=0") == (1080, 1920))
        XCTAssertTrue(FeedAPI.appVideoSize(uri: "bilibili://video/1?player_width=1920&player_height=1080&player_rotate=1") == (1080, 1920))
        XCTAssertTrue(FeedAPI.appVideoSize(uri: "bilibili://video/1") == (0, 0))

        let data = json(#"""
        {"items":[
          {"card_goto":"av","param":"5","title":"竖屏卡","can_play":1,"rcmd_reason":"竖屏",
           "uri":"bilibili://video/5?cid=55&player_height=1920&player_width=1080&player_rotate=0",
           "player_args":{"aid":5,"cid":55,"duration":30}},
          {"card_goto":"av","param":"6","title":"普通卡","can_play":1,"uri":"bilibili://video/6",
           "player_args":{"aid":6,"cid":66}}
        ]}
        """#)
        let cards = FeedAPI.parseAppRecommend(data).items
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards[0].isPortraitVideo)
        XCTAssertEqual(cards[0].reason, "", "the 竖屏 reason is still hidden")
        XCTAssertFalse(cards[1].isPortraitVideo, "unknown sizes are not portrait")

        let entry = ShortVideoAPI.item(from: cards[0])
        XCTAssertEqual(entry.aid, 5)
        XCTAssertFalse(cards[0].bvid.isEmpty, "applyIDs derives the bvid from the aid")
        XCTAssertEqual(entry.id, cards[0].bvid)
        XCTAssertEqual(entry.cid, 55)
        XCTAssertTrue(entry.isPortrait)
    }
}
