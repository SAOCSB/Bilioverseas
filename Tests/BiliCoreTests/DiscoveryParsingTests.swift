import XCTest
@testable import BiliCore

/// Parsers behind 首页 / 搜索 discovery: the app recommend feed (incl. 不感兴趣 reasons), zone names on
/// hot lists and 专栏 search results.
final class DiscoveryParsingTests: XCTestCase {
    private func json(_ s: String) -> JSON {
        (try? JSON(string: s)) ?? .null
    }

    func testAppRecommendKindsSignalsAndFeedback() throws {
        let data = json(#"""
        {"items":[
          {"card_goto":"av","card_type":"small_cover_v2","goto":"av","param":"170001","title":"普通视频",
           "cover":"//i0.hdslb.com/a.jpg","uri":"bilibili://video/170001","can_play":1,
           "args":{"up_id":42,"up_name":"某UP","tname":"鬼畜调教"},
           "player_args":{"aid":170001,"cid":9,"duration":321},
           "cover_left_text_1":"12.3万","cover_left_text_2":"456","rcmd_reason":"已关注",
           "three_point_v2":[
             {"type":"watch_later","title":"添加至稍后再看"},
             {"type":"dislike","title":"不感兴趣","reasons":[{"id":1,"name":"不感兴趣","toast":"将减少相似内容推荐"},
                                                       {"id":4,"name":"UP主:某UP"},{"name":"无id"}]},
             {"type":"feedback","reasons":[{"id":2,"name":"内容引起不适"}]}]},
          {"card_goto":"av","param":"170002","title":"点赞理由","can_play":1,"cover_right_text":"1:05",
           "args":{"up_name":"UP2"},"rcmd_reason":"1万点赞"},
          {"card_goto":"av","param":"170003","title":"不可播放","can_play":0},
          {"card_goto":"bangumi","param":"3344","title":"某番剧 第1话","cover_right_text":"会员专享",
           "desc_button":{"text":"番剧"}},
          {"card_goto":"live","param":"5566","title":"直播中","uri":"bilibili://live/5566","can_play":0},
          {"card_goto":"ad_av","param":"170004","title":"广告视频","player_args":{"aid":170004}},
          {"card_goto":"av","param":"170005","title":"带广告信息","ad_info":{"creative_id":1},"can_play":1},
          {"card_goto":"av","card_type":"cm_v2","param":"170006","title":"cm卡","can_play":1},
          {"card_goto":"article","param":"777","title":"专栏","can_play":0},
          {"card_goto":"banner","title":"横幅"}
        ]}
        """#)
        let page = FeedAPI.parseAppRecommend(data, idx: 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "4")
        XCTAssertEqual(page.items.count, 7)

        let v = page.items[0]
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.aid, 170001)
        XCTAssertEqual(v.id, v.bvid)
        XCTAssertEqual(v.cid, 9)
        XCTAssertEqual(v.duration, 321)
        XCTAssertEqual(v.ownerMid, 42)
        XCTAssertEqual(v.ownerName, "某UP")
        XCTAssertEqual(v.zone, "鬼畜调教")
        XCTAssertEqual(v.viewCount, 123_000)
        XCTAssertEqual(v.danmakuCount, 456)
        XCTAssertTrue(v.isFollowed)
        XCTAssertEqual(v.reason, "已关注")
        XCTAssertEqual(v.cover, "https://i0.hdslb.com/a.jpg")
        let fb = try XCTUnwrap(v.feedback)
        XCTAssertEqual(fb.goto, "av")
        XCTAssertEqual(fb.param, 170001)
        XCTAssertEqual(fb.reasons.map(\.id), [1, 4])
        XCTAssertEqual(fb.reasons.first?.toast, "将减少相似内容推荐")
        XCTAssertEqual(fb.feedbacks.map(\.name), ["内容引起不适"])
        XCTAssertTrue(fb.feedbacks.allSatisfy(\.isFeedback))
        XCTAssertFalse(fb.reasons.contains(where: \.isFeedback))

        let liked = page.items[1]
        XCTAssertEqual(liked.likeCount, 10_000)
        XCTAssertEqual(liked.duration, 65)
        XCTAssertFalse(liked.isFollowed)
        XCTAssertNil(liked.feedback)

        let pgc = page.items[2]
        XCTAssertEqual(pgc.kind, .bangumi)
        XCTAssertEqual(pgc.epId, 3344)
        XCTAssertEqual(pgc.id, "ep3344")
        XCTAssertEqual(pgc.badge, "会员专享")
        XCTAssertEqual(pgc.ownerName, "番剧")

        let live = page.items[3]
        XCTAssertEqual(live.kind, .live)
        XCTAssertEqual(live.roomId, 5566)
        XCTAssertEqual(live.uri, "https://live.bilibili.com/5566")

        let ads = Array(page.items[4...6])
        XCTAssertTrue(ads.allSatisfy { $0.kind == .ad })
        XCTAssertEqual(ads.map(\.adSignals), [["card_goto=ad_av"], ["ad_info"], ["card_type=cm_v2"]])
        XCTAssertEqual(Set(page.items.map(\.id)).count, page.items.count)
        // Default settings hide every ad card; the follow mark exempts the followed UP's video.
        let filter = FeedFilter(settings: { var s = FeedFilterSettings(); s.blockedZones = ["鬼畜调教"]; return s }())
        let shown = filter.apply(page.items, scope: .recommend)
        XCTAssertEqual(shown.map(\.id), [v.id, liked.id, pgc.id])
        XCTAssertNil(FeedAPI.appFeedback(.null, goto: "av", param: 1))
        XCTAssertNil(FeedAPI.appFeedback(json(#"[{"type":"dislike","reasons":[{"id":1,"name":"x"}]}]"#), goto: "av", param: 0))
    }

    func testHotListsCarryTheZone() {
        let item = json(#"{"aid":170001,"bvid":"BV1xx411c7mD","title":"热门","tname":"单机游戏","owner":{"mid":1,"name":"a"}}"#)
        XCTAssertEqual(ListMapping.hotVideo(item)?.zone, "单机游戏")
        let ranked = FeedAPI.parseRanking(json(#"{"list":[{"aid":5,"title":"排行","tname":"鬼畜调教"}]}"#))
        XCTAssertEqual(ranked.first?.zone, "鬼畜调教")
        let popular = FeedAPI.parsePopular(json(#"{"list":[{"aid":6,"title":"热门","tname":"手游"}],"no_more":false}"#), page: 1)
        XCTAssertEqual(popular.items.first?.zone, "手游")
    }

    func testSearchArticles() {
        let data = json(#"""
        {"numPages":2,"result":[
          {"id":123456,"title":"<em class=\"keyword\">原神</em>攻略","desc":"简介 &amp; 说明",
           "image_urls":["//i0.hdslb.com/cv.jpg","//i0.hdslb.com/cv2.jpg"],"view":"1.5万","like":30,"reply":4,
           "mid":77,"pub_time":1700000000,"category_name":"游戏"},
          {"id":0,"title":"无效"}
        ]}
        """#)
        let page = SearchAPI.parseArticles(data, page: 1)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "2")
        let c = page.items[0]
        XCTAssertEqual(c.kind, .article)
        XCTAssertEqual(c.id, "cv123456")
        XCTAssertEqual(c.title, "原神攻略")
        XCTAssertEqual(c.desc, "简介 & 说明")
        XCTAssertEqual(c.cover, "https://i0.hdslb.com/cv.jpg")
        XCTAssertEqual(c.viewCount, 15_000)
        XCTAssertEqual(c.likeCount, 30)
        XCTAssertEqual(c.danmakuCount, 4)
        XCTAssertEqual(c.ownerMid, 77)
        XCTAssertEqual(c.reason, "游戏")
        XCTAssertEqual(c.uri, "https://www.bilibili.com/read/cv123456")
        XCTAssertFalse(SearchAPI.parseArticles(json(#"{"numPages":2,"result":[]}"#), page: 2).hasMore)
    }
}
