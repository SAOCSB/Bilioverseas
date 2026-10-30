import XCTest
@testable import BiliCore

/// Parsing tests for the list / feed APIs, with fixtures modelled on the field paths of
/// `specs/api-lists.md` (PiliPlus parsing code).
final class ListAPIParsingTests: XCTestCase {
    private func json(_ s: String) -> JSON {
        do { return try JSON(string: s) } catch { XCTFail("bad fixture: \(error)"); return .null }
    }

    // MARK: - Shared helpers

    func testValueHelpers() {
        XCTAssertEqual(ListMapping.duration(.string("04:35")), 275)
        XCTAssertEqual(ListMapping.duration(.string("1:02:03")), 3723)
        XCTAssertEqual(ListMapping.duration(.string("12：34")), 754)
        XCTAssertEqual(ListMapping.duration(.int(99)), 99)
        XCTAssertEqual(ListMapping.duration(.string("")), 0)
        XCTAssertEqual(ListMapping.count(.string("12.3万")), 123_000)
        XCTAssertEqual(ListMapping.count(.string("1.2亿")), 120_000_000)
        XCTAssertEqual(ListMapping.count(.string("3千")), 3000)
        XCTAssertEqual(ListMapping.count(.string("-")), 0)
        XCTAssertEqual(ListMapping.count(.string("1,234")), 1234)
        XCTAssertEqual(ListMapping.count(.int(42)), 42)
        XCTAssertEqual(ListMapping.plainText(#"<em class="keyword">原神</em> &amp; 崩坏&#xFF01; &lt;3&gt; &quot;x&quot;"#),
                       #"原神 & 崩坏！ <3> "x""#)
        XCTAssertEqual(ListMapping.epId(inURL: "https://www.bilibili.com/bangumi/play/ep12345?from=search"), 12345)
        XCTAssertEqual(ListMapping.seasonId(inURL: "https://www.bilibili.com/bangumi/play/ss678"), 678)
        XCTAssertEqual(ListMapping.epId(inURL: "https://www.bilibili.com/bangumi/play/ss678"), 0)
        XCTAssertEqual(ListCursor.page(nil), 1)
        XCTAssertEqual(ListCursor.page("3"), 3)
        XCTAssertEqual(ListCursor.next(page: 3, hasMore: true), "4")
        XCTAssertNil(ListCursor.next(page: 3, hasMore: false))
    }

    /// `Int64(_: Double)` traps beyond 2^63: oversized counts from the server must clamp, not crash.
    func testCountsClampInsteadOfTrapping() throws {
        XCTAssertEqual(ListMapping.count(.double(1e20)), Int64.max)
        XCTAssertEqual(ListMapping.count(.double(-5)), 0)
        XCTAssertEqual(ListMapping.count(.string("99999999999999999999")), Int64.max)
        XCTAssertEqual(ListMapping.count(.string("999999999999亿")), Int64.max)
        let stat = try JSON(string: #"{"view":1.5e19,"like":"12.3万"}"#)
        XCTAssertEqual(ListMapping.count(stat["view"]), Int64.max)
        XCTAssertEqual(ListMapping.count(stat["like"]), 123_000)
    }

    // MARK: - Web recommend

    func testWebRecommendKindsAndAdSignals() {
        let data = json(#"""
        {"item":[
          {"id":113000000000001,"bvid":"BV1av4y1A7xx","cid":5001,"goto":"av","uri":"https://www.bilibili.com/video/BV1av4y1A7xx",
           "pic":"http://i0.hdslb.com/bfs/archive/a.jpg","title":"普通视频","duration":615,"pubdate":1700000000,
           "owner":{"mid":123,"name":"UP主","face":"//i1.hdslb.com/face.jpg"},
           "stat":{"view":10000,"like":500,"danmaku":30},"is_followed":1,
           "rcmd_reason":{"reason_type":1,"content":"已关注"},"business_info":null},
          {"id":0,"bvid":"","goto":"ad","uri":"","pic":"","title":"","duration":0,
           "business_info":{"id":9988,"title":"广告标题","pic":"//i0.hdslb.com/ad.jpg","url":"https://ad.example/x","is_ad":true,"cm_mark":1}},
          {"id":22334455,"goto":"live","uri":"https://live.bilibili.com/22334455","pic":"https://i0.hdslb.com/live.jpg",
           "title":"直播间","owner":{"mid":777,"name":"主播","face":""},
           "room_info":{"room_id":22334455,"uid":777,"live_status":1,"watched_show":{"num":5000,"text_large":"5000人看过"}},
           "business_info":null},
          {"id":113000000000002,"bvid":"BV1pr4y1B8yy","cid":5002,"goto":"av","pic":"https://i0.hdslb.com/p.jpg",
           "title":"创作推广视频","duration":120,"owner":{"mid":456,"name":"推广UP"},"stat":{"view":20,"like":1,"danmaku":0},
           "business_info":{"id":7766,"is_ad":false,"card_type":2,"business_mark":{"text":"创作推广"}}},
          {"id":1,"goto":"ogv","uri":"https://www.bilibili.com/bangumi/play/ss4321","title":"番剧推广","pic":"https://i0.hdslb.com/o.jpg",
           "business_info":{}},
          {"id":5,"goto":"banner","title":"活动","pic":"https://i0.hdslb.com/b.jpg","uri":"https://www.bilibili.com/blackboard/x.html",
           "business_info":null}
        ]}
        """#)
        let page = FeedAPI.parseRecommend(data, freshIdx: 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "3")
        XCTAssertEqual(page.items.count, 6)

        let av = page.items[0]
        XCTAssertEqual(av.kind, .video)
        XCTAssertEqual(av.aid, 113000000000001)
        XCTAssertEqual(av.bvid, "BV1av4y1A7xx")
        XCTAssertEqual(av.id, "BV1av4y1A7xx")
        XCTAssertEqual(av.cid, 5001)
        XCTAssertEqual(av.cover, "https://i0.hdslb.com/bfs/archive/a.jpg")
        XCTAssertEqual(av.duration, 615)
        XCTAssertEqual(av.ownerMid, 123)
        XCTAssertEqual(av.ownerFace, "https://i1.hdslb.com/face.jpg")
        XCTAssertEqual(av.viewCount, 10000)
        XCTAssertEqual(av.likeCount, 500)
        XCTAssertEqual(av.reason, "已关注")
        XCTAssertTrue(av.isFollowed)
        XCTAssertTrue(av.adSignals.isEmpty)

        let ad = page.items[1]
        XCTAssertEqual(ad.kind, .ad)
        XCTAssertEqual(ad.adSignals, ["goto=ad", "business_info"])
        XCTAssertEqual(ad.aid, 0)
        XCTAssertEqual(ad.title, "广告标题")
        XCTAssertEqual(ad.cover, "https://i0.hdslb.com/ad.jpg")
        XCTAssertEqual(ad.uri, "https://ad.example/x")
        XCTAssertTrue(ad.id.hasPrefix("ad"))

        let live = page.items[2]
        XCTAssertEqual(live.kind, .live)
        XCTAssertEqual(live.roomId, 22334455)
        XCTAssertEqual(live.aid, 0)
        XCTAssertEqual(live.id, "live-22334455")
        XCTAssertEqual(live.badge, "直播中")
        XCTAssertEqual(live.reason, "5000人看过")
        XCTAssertTrue(live.adSignals.isEmpty)

        let promo = page.items[3]
        XCTAssertEqual(promo.kind, .ad, "创作推广: goto=av with business_info")
        XCTAssertEqual(promo.adSignals, ["business_info"])
        XCTAssertEqual(promo.bvid, "BV1pr4y1B8yy", "keeps the real video id")
        XCTAssertEqual(promo.badge, "创作推广")
        XCTAssertNotEqual(promo.id, "BV1pr4y1B8yy")

        let ogv = page.items[4]
        XCTAssertEqual(ogv.kind, .bangumi, "empty business_info {} is not an ad signal")
        XCTAssertEqual(ogv.seasonId, 4321)
        XCTAssertTrue(ogv.adSignals.isEmpty)

        let other = page.items[5]
        XCTAssertEqual(other.kind, .other)
        XCTAssertTrue(other.adSignals.isEmpty)

        XCTAssertEqual(Set(page.items.map(\.id)).count, page.items.count, "ids unique")
    }

    // MARK: - Popular / ranking

    private let hotItem = #"""
    {"aid":170001,"bvid":"BV1xx411c7mD","cid":279786,"title":"热门视频","pic":"http://i2.hdslb.com/h.jpg","duration":300,
     "pubdate":1690000000,"desc":"简介","owner":{"mid":"9","name":"Hot UP","face":"https://i0.hdslb.com/f.jpg"},
     "stat":{"view":"12.3万","like":4000,"danmaku":77,"reply":5},"tname":"游戏","tid":17,
     "rights":{"is_cooperation":1},"rcmd_reason":{"content":"百万播放","corner_mark":0},"videos":2}
    """#

    func testPopularParsing() {
        let data = json(#"{"list":[\#(hotItem),{"aid":0,"bvid":"","title":"broken"}],"no_more":false}"#)
        let page = FeedAPI.parsePopular(data, page: 1)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "2")
        let c = page.items[0]
        XCTAssertEqual(c.kind, .video)
        XCTAssertEqual(c.aid, 170001)
        XCTAssertEqual(c.bvid, "BV1xx411c7mD")
        XCTAssertEqual(c.cover, "https://i2.hdslb.com/h.jpg")
        XCTAssertEqual(c.ownerMid, 9)
        XCTAssertEqual(c.viewCount, 123_000)
        XCTAssertEqual(c.badge, "合作")
        XCTAssertEqual(c.reason, "百万播放")
        XCTAssertEqual(c.pageCount, 2)
        XCTAssertTrue(c.adSignals.isEmpty)

        let end = FeedAPI.parsePopular(json(#"{"list":[\#(hotItem)],"no_more":true}"#), page: 5)
        XCTAssertFalse(end.hasMore)
        XCTAssertNil(end.next)
    }

    func testRankingParsingAndZones() {
        let data = json(#"""
        {"note":"根据稿件内容质量等综合评分","list":[\#(hotItem),
          {"aid":170002,"bvid":"BV1yy411c7mE","title":"番剧","pic":"https://i0.hdslb.com/x.jpg","duration":1400,
           "owner":{"mid":1,"name":"官方"},"stat":{"view":1},"redirect_url":"https://www.bilibili.com/bangumi/play/ep998877",
           "charging_pay":{"level":1}}]}
        """#)
        let cards = FeedAPI.parseRanking(data)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[1].kind, .bangumi)
        XCTAssertEqual(cards[1].epId, 998877)
        XCTAssertEqual(cards[1].badge, "充电专属")
        XCTAssertEqual(FeedAPI.rankingZones.first?.rid, 0)
        XCTAssertEqual(FeedAPI.rankingZones.first?.name, "全站")
        XCTAssertEqual(Set(FeedAPI.rankingZones.map(\.rid)).count, FeedAPI.rankingZones.count)
        for z in FeedAPI.rankingZones where z.rid != 0 { XCTAssertNotNil(FeedAPI.legacyRankingRids[z.rid], z.name) }
    }

    // MARK: - Search

    func testSearchVideoParsing() throws {
        let data = json(#"""
        {"page":1,"pagesize":20,"numResults":1000,"numPages":50,"result":[
          {"type":"video","id":80433022,"aid":80433022,"bvid":"BV1EJ411u7Dh","mid":2,"author":"碧诗",
           "upic":"//i0.hdslb.com/bfs/face/u.jpg","title":"【<em class=\"keyword\">原神</em>】超&amp;燃 &#39;剪辑&#39;",
           "description":"desc","pic":"//i1.hdslb.com/bfs/archive/p.jpg","play":"1.5万","video_review":12,"danmaku":"34",
           "like":99,"favorites":3,"review":7,"pubdate":1580000000,"senddate":1580000100,"duration":"4:35",
           "arcurl":"http://www.bilibili.com/video/av80433022","is_union_video":1},
          {"type":"ketang","id":1234,"title":"<em class=\"keyword\">原神</em>课程","pic":"//i0.hdslb.com/k.jpg","duration":"1:00:00",
           "arcurl":"https://www.bilibili.com/cheese/play/ss1234","mid":3,"author":"讲师"},
          {"type":"live_room","roomid":5566,"title":"直播","pic":"//i0.hdslb.com/l.jpg","duration":"0:00","mid":4}
        ]}
        """#)
        XCTAssertNoThrow(try SearchAPI.checkRisk(data))
        let page = SearchAPI.parseVideos(data, page: 1)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "2")
        let v = page.items[0]
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.title, "【原神】超&燃 '剪辑'")
        XCTAssertEqual(v.duration, 275)
        XCTAssertEqual(v.cover, "https://i1.hdslb.com/bfs/archive/p.jpg")
        XCTAssertEqual(v.ownerFace, "https://i0.hdslb.com/bfs/face/u.jpg")
        XCTAssertEqual(v.viewCount, 15_000)
        XCTAssertEqual(v.danmakuCount, 34)
        XCTAssertEqual(v.aid, 80433022)
        XCTAssertEqual(v.bvid, "BV1EJ411u7Dh")
        XCTAssertEqual(v.badge, "合作")
        XCTAssertEqual(v.cid, 0)

        let course = page.items[1]
        XCTAssertEqual(course.kind, .other)
        XCTAssertEqual(course.badge, "课堂")
        XCTAssertEqual(course.duration, 3600)
        XCTAssertEqual(course.aid, 0, "courses open their web page, not the video player")

        XCTAssertEqual(page.items[2].kind, .live)
        XCTAssertEqual(page.items[2].roomId, 5566)

        let risk = json(#"{"v_voucher":"voucher_abc"}"#)
        XCTAssertThrowsError(try SearchAPI.checkRisk(risk)) { err in
            XCTAssertEqual(err.localizedDescription, SearchAPI.riskMessage)
        }
    }

    func testSearchUsersBangumiLiveAndHotWords() {
        let users = SearchAPI.parseUsers(json(#"""
        {"numPages":1,"result":[{"mid":546195,"uname":"<em class=\"keyword\">老番茄</em>","usign":"签名","fans":"1880万",
          "videos":300,"upic":"//i0.hdslb.com/u.jpg","level":6,"is_atten":1}]}
        """#), page: 1)
        XCTAssertEqual(users.items.first?.name, "老番茄")
        XCTAssertEqual(users.items.first?.fans, 18_800_000)
        XCTAssertEqual(users.items.first?.isFollowed, true)
        XCTAssertFalse(users.hasMore)

        let pgc = SearchAPI.parsePGC(json(#"""
        {"numPages":2,"result":[{"season_id":28747,"media_id":28229002,"title":"<em class=\"keyword\">进击</em>的巨人",
          "cover":"//i0.hdslb.com/c.jpg","url":"https://www.bilibili.com/bangumi/play/ss28747","season_type_name":"番剧",
          "index_show":"全25话","areas":"日本","styles":"热血"}]}
        """#), page: 1)
        XCTAssertEqual(pgc.items.first?.kind, .bangumi)
        XCTAssertEqual(pgc.items.first?.seasonId, 28747)
        XCTAssertEqual(pgc.items.first?.title, "进击的巨人")
        XCTAssertEqual(pgc.items.first?.cover, "https://i0.hdslb.com/c.jpg")
        XCTAssertTrue(pgc.hasMore)

        let live = SearchAPI.parseLive(json(#"""
        {"numPages":1,"result":[{"roomid":21452505,"uid":1,"uname":"主播","uface":"//i0.hdslb.com/f.jpg",
          "title":"<em class=\"keyword\">游戏</em>直播","cover":"//i0.hdslb.com/c.jpg","user_cover":"","online":3200,
          "cate_name":"<em class=\"keyword\">单机</em>游戏","live_status":1}]}
        """#), page: 1)
        XCTAssertEqual(live.items.first?.kind, .live)
        XCTAssertEqual(live.items.first?.roomId, 21452505)
        XCTAssertEqual(live.items.first?.title, "游戏直播")
        XCTAssertEqual(live.items.first?.viewCount, 3200)

        let hot = SearchAPI.parseHotWords(json(#"""
        {"top_list":[{"keyword":"置顶词","show_name":"置顶"}],
         "list":[{"keyword":"热词A","show_name":"热词A展示","icon":"http://i0.hdslb.com/new.png","recommend_reason":"科技·热门"},
                 {"keyword":"广告词","show_name":"广告","is_commercial":"1"},
                 {"keyword":"热词B","show_name":""}]}
        """#))
        XCTAssertEqual(hot.map(\.keyword), ["置顶词", "热词A", "热词B"])
        XCTAssertTrue(hot[0].isTop)
        XCTAssertEqual(hot[1].icon, "https://i0.hdslb.com/new.png")
        XCTAssertEqual(hot[1].recommendReason, "科技 热门")
        XCTAssertEqual(hot[2].showName, "热词B")

        let sug = SearchAPI.parseSuggest(json(#"""
        {"result":{"tag":[{"value":"原神","term":"原神","name":"<em class=\"suggest_high_light\">原</em>神"},
                          {"term":"","value":"","name":"<em>原</em>神启动"}]}}
        """#))
        XCTAssertEqual(sug, ["原神", "原神启动"])
    }

    func testSearchHistoryStore() {
        let suite = "ListAPIParsingTests.history"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var enabled = true
        let store = SearchHistoryStore(defaults: defaults, key: "h", isEnabled: { enabled })
        for i in 0..<25 { store.add("kw\(i)") }
        XCTAssertEqual(store.keywords.count, SearchHistoryStore.maxCount)
        XCTAssertEqual(store.keywords.first, "kw24")
        store.add("kw10")
        XCTAssertEqual(store.keywords.first, "kw10")
        XCTAssertEqual(store.keywords.filter { $0 == "kw10" }.count, 1)
        store.add("   ")
        XCTAssertEqual(store.keywords.first, "kw10")
        enabled = false
        store.add("ignored")
        XCTAssertFalse(store.keywords.contains("ignored"))
        let reloaded = SearchHistoryStore(defaults: defaults, key: "h", isEnabled: { true })
        XCTAssertEqual(reloaded.keywords, store.keywords)
        store.remove("kw10")
        XCTAssertFalse(store.keywords.contains("kw10"))
        store.clear()
        XCTAssertTrue(store.keywords.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - History

    func testHistoryCursorParsing() {
        let data = json(#"""
        {"cursor":{"max":0,"view_at":0,"business":"","ps":20},
         "tab":[{"type":"archive","name":"视频"}],
         "list":[
          {"title":"看过的视频","cover":"http://i0.hdslb.com/1.jpg","history":{"oid":1001,"epid":0,"bvid":"BV1Ab411c7aa","page":2,"cid":2002,"part":"P2","business":"archive","dt":2},
           "videos":3,"author_name":"作者","author_mid":55,"view_at":1700000500,"progress":-1,"duration":600,"kid":1001,"show_title":"P2 第二集"},
          {"title":"番剧","cover":"https://i0.hdslb.com/2.jpg","history":{"oid":3003,"epid":4004,"bvid":"BV1Cd411c7bb","cid":5005,"business":"pgc"},
           "view_at":1700000400,"progress":120,"duration":1400,"kid":6006,"badge":"番剧","show_title":"第3话"},
          {"title":"直播间","covers":["//i0.hdslb.com/3.jpg"],"history":{"oid":7007,"business":"live"},"view_at":1700000300,"live_status":1,"kid":7007},
          {"title":"专栏","covers":["https://i0.hdslb.com/4.jpg"],"history":{"oid":8008,"cid":0,"business":"article"},"view_at":1700000200,"kid":8008}
         ]}
        """#)
        let page = HistoryAPI.parseList(data)
        XCTAssertEqual(page.items.count, 4)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "8008|1700000200|article", "falls back to the last item when data.cursor is zero")
        let decoded = HistoryAPI.decodeCursor(page.next)
        XCTAssertEqual(decoded.max, 8008)
        XCTAssertEqual(decoded.viewAt, 1700000200)
        XCTAssertEqual(decoded.business, "article")
        XCTAssertEqual(HistoryAPI.decodeCursor(nil).max, 0)

        let v = page.items[0]
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.id, "archive_1001")
        XCTAssertEqual(v.aid, 1001)
        XCTAssertEqual(v.cid, 2002)
        XCTAssertEqual(v.progress, -1)
        XCTAssertEqual(v.viewAt, 1700000500)
        XCTAssertEqual(v.cover, "https://i0.hdslb.com/1.jpg")
        XCTAssertEqual(HistoryAPI.historyKid(for: v), "archive_1001")

        let pgc = page.items[1]
        XCTAssertEqual(pgc.kind, .bangumi)
        XCTAssertEqual(pgc.epId, 4004)
        XCTAssertEqual(pgc.progress, 120)
        XCTAssertEqual(HistoryAPI.historyKid(for: pgc), "pgc_6006")

        let live = page.items[2]
        XCTAssertEqual(live.kind, .live)
        XCTAssertEqual(live.roomId, 7007)
        XCTAssertEqual(live.aid, 0)
        XCTAssertEqual(live.badge, "直播中")
        XCTAssertEqual(live.cover, "https://i0.hdslb.com/3.jpg")

        XCTAssertEqual(page.items[3].kind, .article)
        XCTAssertEqual(page.items[3].uri, "https://www.bilibili.com/read/cv8008")

        let serverCursor = HistoryAPI.parseList(json(#"""
        {"cursor":{"max":42,"view_at":1699999999,"business":"archive"},
         "list":[{"title":"x","history":{"oid":1,"business":"archive"},"view_at":5,"kid":1}]}
        """#))
        XCTAssertEqual(serverCursor.next, "42|1699999999|archive")

        let end = HistoryAPI.parseList(json(#"{"cursor":{"max":0,"view_at":0},"list":[]}"#))
        XCTAssertFalse(end.hasMore)
        XCTAssertNil(end.next)
    }

    func testWatchLaterParsing() {
        let data = json(#"""
        {"count":2,"list":[
          {"aid":1,"bvid":"BV1GJ411x7h7","cid":11,"title":"稍后再看1","pic":"https://i0.hdslb.com/a.jpg","duration":100,
           "owner":{"mid":5,"name":"u","face":""},"stat":{"view":10,"danmaku":1},"progress":-1,"add_at":1700000000},
          {"aid":2,"bvid":"","cid":22,"title":"某番剧 第2话","pic":"https://i0.hdslb.com/b.jpg","duration":1400,"is_pgc":true,
           "bangumi":{"ep_id":3344,"season":{"season_id":55,"title":"某番剧"}},"progress":30,"pgc_label":"番剧"}
        ]}
        """#)
        let page = WatchLaterAPI.parsePage(data, page: 1, pageSize: 20)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.items[0].progress, -1)
        XCTAssertEqual(page.items[0].viewAt, 1700000000)
        XCTAssertEqual(page.items[1].kind, .bangumi)
        XCTAssertEqual(page.items[1].epId, 3344)
        XCTAssertEqual(page.items[1].seasonId, 55)
        XCTAssertEqual(page.items[1].desc, "第2话")
        XCTAssertEqual(page.items[1].badge, "番剧")
        XCTAssertEqual(page.items[1].bvid, BVConverter.av2bv(2))
    }

    // MARK: - Favorites

    func testFavFoldersAndContents() {
        let folders = FavAPI.parseFolderPage(json(#"""
        {"count":2,"has_more":false,"list":[
          {"id":1052622027,"fid":10526220,"mid":27,"attr":0,"title":"默认收藏夹","cover":"http://i0.hdslb.com/c.jpg","media_count":12,"intro":""},
          {"id":2000,"fid":20,"mid":27,"attr":3,"title":"私密","media_count":0,"upper":{"mid":27,"name":"me","face":"//i0.hdslb.com/f.jpg"}}
        ]}
        """#), page: 1)
        XCTAssertEqual(folders.items.count, 2)
        XCTAssertFalse(folders.hasMore)
        XCTAssertTrue(folders.items[0].isDefault)
        XCTAssertFalse(folders.items[0].isPrivate)
        XCTAssertEqual(folders.items[0].cover, "https://i0.hdslb.com/c.jpg")
        XCTAssertEqual(folders.items[0].count, 12)
        XCTAssertTrue(folders.items[1].isPrivate)
        XCTAssertFalse(folders.items[1].isDefault)
        XCTAssertEqual(folders.items[1].upperName, "me")

        let data = json(#"""
        {"info":{"id":1052622027,"title":"默认收藏夹","media_count":3,"attr":0},"has_more":true,"medias":[
          {"id":12345,"type":2,"title":"收藏的视频","cover":"http://i0.hdslb.com/v.jpg","intro":"简介","duration":233,
           "upper":{"mid":8,"name":"UP","face":"https://i0.hdslb.com/u.jpg"},"cnt_info":{"play":999,"danmaku":9},
           "bvid":"BV1aa411c7Ab","ugc":{"first_cid":67890},"fav_time":1700000000,"attr":0},
          {"id":778899,"type":24,"title":"番剧收藏","cover":"https://i0.hdslb.com/o.jpg","duration":1420,
           "ogv":{"type_name":"番剧","season_id":4455},"cnt_info":{"play":100,"danmaku":2},"fav_time":1700000001,"attr":0},
          {"id":555,"type":2,"title":"已失效视频","cover":"","attr":9,"bv_id":"BV1bb411c7Bc"}
        ]}
        """#)
        let page = FavAPI.parseContents(data, page: 1)
        XCTAssertEqual(page.items.count, 2, "invalid items skipped by default")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "2")
        let v = page.items[0]
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.aid, 12345)
        XCTAssertEqual(v.cid, 67890)
        XCTAssertEqual(v.viewCount, 999)
        XCTAssertEqual(v.viewAt, 1700000000)
        XCTAssertEqual(FavAPI.resourceKey(for: v), "12345:2")
        let ogv = page.items[1]
        XCTAssertEqual(ogv.kind, .bangumi)
        XCTAssertEqual(ogv.epId, 778899)
        XCTAssertEqual(ogv.seasonId, 4455)
        XCTAssertEqual(ogv.aid, 0)
        XCTAssertEqual(ogv.badge, "番剧")
        XCTAssertEqual(FavAPI.resourceKey(for: ogv), "778899:24")

        let withInvalid = FavAPI.parseContents(data, page: 1, includeInvalid: true)
        XCTAssertEqual(withInvalid.items.count, 3)
        XCTAssertEqual(withInvalid.items[2].badge, "已失效")
        XCTAssertEqual(withInvalid.items[2].kind, .other)
        XCTAssertEqual(withInvalid.items[2].bvid, "BV1bb411c7Bc")
        XCTAssertEqual(FavAPI.parseFolderInfo(data)?.id, 1052622027)
    }

    /// Removing audio / invalid PGC items used to send `0:2` (aid 0, video type).
    func testFavResourceKeysForAudioAndInvalidPGC() {
        let data = json(#"""
        {"has_more":false,"medias":[
          {"id":3344,"type":12,"title":"音频","cover":"https://i0.hdslb.com/a.jpg","attr":0},
          {"id":778899,"type":24,"title":"已失效视频","cover":"","attr":1,"ogv":{"season_id":4455}},
          {"id":555,"type":2,"title":"已失效视频","cover":"","attr":9,"bv_id":"BV1bb411c7Bc"}
        ]}
        """#)
        let items = FavAPI.parseContents(data, page: 1, includeInvalid: true).items
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map { FavAPI.resourceKey(for: $0) }, ["3344:12", "778899:24", "555:2"])
        // Other PGC cards (timeline / rank) carry only an ep id.
        XCTAssertEqual(FavAPI.resourceKey(for: ListMapping.pgcCard(seasonId: 1, epId: 99, title: "", cover: "")), "99:24")
        // A PGC history card carries the episode's archive aid and keeps the video key.
        var history = VideoCard(id: "pgc_7890")
        history.kind = .bangumi
        history.aid = 1234
        history.epId = 99
        XCTAssertEqual(FavAPI.resourceKey(for: history), "1234:2")
    }

    // MARK: - Dynamics

    func testDynamicsFeedParsing() throws {
        let liveContent = #"{\"type\":1,\"live_play_info\":{\"room_id\":9090,\"live_status\":1,\"title\":\"直播动态\",\"cover\":\"http://i0.hdslb.com/l.jpg\",\"watched_show\":{\"text_large\":\"1万人看过\"}}}"#
        let data = json(#"""
        {"has_more":true,"offset":"913000000000000001","update_baseline":"913000000000000099","update_num":3,"items":[
          {"id_str":"900000000000000001","type":"DYNAMIC_TYPE_AV","visible":true,
           "basic":{"comment_id_str":"170001","comment_type":1},
           "modules":{
             "module_author":{"mid":100,"name":"视频UP","face":"https://i0.hdslb.com/a.jpg","pub_time":"5分钟前","pub_ts":1700000000,"pub_action":"投稿了视频"},
             "module_dynamic":{"desc":null,"major":{"type":"MAJOR_TYPE_ARCHIVE","archive":{"aid":"170001","bvid":"BV1xx411c7mD",
               "title":"动态视频","cover":"http://i0.hdslb.com/v.jpg","desc":"视频简介","duration_text":"10:05",
               "jump_url":"//www.bilibili.com/video/BV1xx411c7mD/","stat":{"play":"1.2万","danmaku":"34"},"badge":{"text":"投稿视频"},"type":1}},
               "additional":{"type":"ADDITIONAL_TYPE_GOODS","goods":{}}},
             "module_stat":{"comment":{"count":10},"forward":{"count":2},"like":{"count":300,"status":true}}}},
          {"id_str":"900000000000000002","type":"DYNAMIC_TYPE_DRAW",
           "modules":{
             "module_author":{"mid":101,"name":"图文UP","face":"","pub_time":"1小时前","pub_ts":1699990000},
             "module_dynamic":{"desc":null,"major":{"type":"MAJOR_TYPE_OPUS","opus":{"title":"标题",
               "summary":{"text":"图文内容[doge]","rich_text_nodes":[{"type":"RICH_TEXT_NODE_TYPE_TEXT","text":"图文内容","orig_text":"图文内容"},
                 {"type":"RICH_TEXT_NODE_TYPE_EMOJI","text":"[doge]","orig_text":"[doge]","emoji":{"text":"[doge]","icon_url":"http://i0.hdslb.com/doge.png"}}]},
               "pics":[{"url":"http://i0.hdslb.com/p1.jpg","width":100,"height":100},{"url":"https://i0.hdslb.com/p2.jpg"}],
               "jump_url":"//www.bilibili.com/opus/900000000000000002"}}},
             "module_stat":{"comment":{"count":0},"forward":{"count":0},"like":{"count":"1.1万","status":false}}}},
          {"id_str":"900000000000000003","type":"DYNAMIC_TYPE_FORWARD",
           "modules":{
             "module_author":{"mid":102,"name":"转发者","pub_ts":1699980000},
             "module_dynamic":{"desc":{"text":"转发了 @原作者 //","rich_text_nodes":[{"type":"RICH_TEXT_NODE_TYPE_TEXT","text":"转发了 "},
               {"type":"RICH_TEXT_NODE_TYPE_AT","text":"@原作者","rid":"103"},{"type":"RICH_TEXT_NODE_TYPE_TEXT","text":" //"}]},"major":null}},
           "orig":{"id_str":"900000000000000004","type":"DYNAMIC_TYPE_LIVE_RCMD",
             "modules":{"module_author":{"mid":103,"name":"原作者","face":"https://i0.hdslb.com/o.jpg"},
               "module_dynamic":{"major":{"type":"MAJOR_TYPE_LIVE_RCMD","live_rcmd":{"content":"\#(liveContent)","reserve_type":0}},
                 "additional":{"type":"ADDITIONAL_TYPE_GOODS"}}}}},
          {"id_str":"900000000000000005","type":"DYNAMIC_TYPE_WORD","visible":false,"modules":{"module_author":{"mid":1}}},
          {"id_str":"900000000000000006","type":"DYNAMIC_TYPE_AD",
           "modules":{"module_author":{"mid":104,"name":"广告主"},
             "module_dynamic":{"major":{"type":"MAJOR_TYPE_ARCHIVE","archive":{"aid":5,"bvid":"","title":"广告视频","duration_text":"0:30"}}}}}
        ]}
        """#)
        let page = DynamicsAPI.parseFeed(data)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "913000000000000001")
        XCTAssertEqual(page.items.count, 4, "folded (visible:false) item dropped")

        let video = page.items[0]
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.idStr, "900000000000000001")
        XCTAssertEqual(video.author.mid, 100)
        XCTAssertEqual(video.pubTimeText, "5分钟前")
        XCTAssertEqual(video.commentId, 170001)
        XCTAssertEqual(video.commentType, 1)
        XCTAssertEqual(video.stat.like, 300)
        XCTAssertTrue(video.stat.liked)
        XCTAssertTrue(video.hasGoods)
        XCTAssertEqual(video.adSignals, ["goods"])
        XCTAssertFalse(video.isAd)
        let card = try XCTUnwrap(video.video)
        XCTAssertEqual(card.kind, .video, "goods is a soft signal; the UP's video stays a video")
        XCTAssertEqual(card.adSignals, ["goods"])
        XCTAssertEqual(card.aid, 170001)
        XCTAssertEqual(card.duration, 605)
        XCTAssertEqual(card.viewCount, 12_000)
        XCTAssertEqual(card.danmakuCount, 34)
        XCTAssertEqual(card.badge, "")
        XCTAssertEqual(card.cover, "https://i0.hdslb.com/v.jpg")
        XCTAssertEqual(card.uri, "https://www.bilibili.com/video/BV1xx411c7mD/")
        XCTAssertEqual(card.ownerName, "视频UP")
        XCTAssertEqual(card.pubdate, 1700000000)
        XCTAssertEqual(card.reason, "投稿了视频")

        let draw = page.items[1]
        XCTAssertEqual(draw.type, .draw)
        XCTAssertEqual(draw.text, "图文内容[doge]")
        XCTAssertEqual(draw.title, "标题")
        XCTAssertEqual(draw.emojis["[doge]"], "https://i0.hdslb.com/doge.png")
        XCTAssertEqual(draw.images, ["https://i0.hdslb.com/p1.jpg", "https://i0.hdslb.com/p2.jpg"])
        XCTAssertEqual(draw.stat.like, 11_000)
        XCTAssertNil(draw.video)

        let fwd = page.items[2]
        XCTAssertEqual(fwd.type, .forward)
        XCTAssertEqual(fwd.text, "转发了 @原作者 //")
        let orig = try XCTUnwrap(fwd.forwarded)
        XCTAssertEqual(orig.type, .live)
        XCTAssertEqual(orig.author.name, "原作者")
        XCTAssertEqual(orig.video?.kind, .live)
        XCTAssertEqual(orig.video?.roomId, 9090)
        XCTAssertEqual(orig.video?.reason, "1万人看过")
        XCTAssertTrue(orig.hasGoods)
        XCTAssertTrue(fwd.hasGoods, "goods on the original marks the forward too")

        let ad = page.items[3]
        XCTAssertTrue(ad.isAd)
        XCTAssertEqual(ad.adSignals, ["type=DYNAMIC_TYPE_AD"])
        XCTAssertEqual(ad.video?.kind, .ad)
        XCTAssertEqual(ad.video?.adSignals, ["type=DYNAMIC_TYPE_AD"])
    }

    /// dyn/thumb takes a JSON body (csrf in the query); the old code sent a form body.
    func testDynamicLikeBodyIsJSON() throws {
        let body = DynamicsAPI.likeBody(dynamicId: "913000000000000001", like: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        let back = try JSON(data: data)
        XCTAssertEqual(back["dyn_id_str"].stringValue, "913000000000000001", "id stays a string (> 2^53)")
        XCTAssertEqual(back["up"].intValue, 2)
        XCTAssertEqual(back["spmid"].stringValue, "333.1365.0.0")
        XCTAssertNil(body["csrf"], "csrf goes in the query")
        XCTAssertEqual(DynamicsAPI.likeBody(dynamicId: "1", like: true)["up"] as? Int, 1)
    }

    func testDynamicsUpList() {
        let ups = DynamicsAPI.parseUpList(json(#"""
        {"live_users":{"count":1,"items":[{"mid":7,"uname":"直播UP","face":"//i0.hdslb.com/7.jpg","room_id":700,"title":"开播了"}]},
         "up_list":{"has_more":false,"items":[{"mid":7,"uname":"直播UP","face":"","has_update":true},
                                             {"mid":8,"uname":"更新UP","face":"https://i0.hdslb.com/8.jpg","has_update":true},
                                             {"mid":9,"uname":"普通UP","has_update":false}]}}
        """#))
        XCTAssertEqual(ups.map(\.user.mid), [7, 8, 9])
        XCTAssertTrue(ups[0].isLive)
        XCTAssertEqual(ups[0].roomId, 700)
        XCTAssertTrue(ups[0].hasUpdate)
        XCTAssertTrue(ups[1].hasUpdate)
        XCTAssertFalse(ups[2].hasUpdate)
        XCTAssertEqual(ups[0].user.face, "https://i0.hdslb.com/7.jpg")
    }

    // MARK: - Space

    func testSpaceArcSearchParsing() {
        let data = json(#"""
        {"list":{"slist":[],"tlist":{"4":{"tid":4,"count":10,"name":"游戏"}},"vlist":[
          {"aid":880001,"bvid":"BV1Ua4y1x7aa","title":"UP的视频","pic":"http://i0.hdslb.com/s.jpg","description":"d",
           "created":1700000000,"length":"12:34","mid":42,"author":"UP","play":5000,"video_review":66,"comment":3,
           "is_union_video":1,"is_charging_arc":false,"playback_position":50,"jump_url":"bilibili://video/880001","season_id":12},
          {"aid":880002,"bvid":"BV1Ub4y1x7bb","title":"看完了","pic":"","length":"00:30","mid":42,"author":"UP",
           "play":"--","video_review":0,"playback_position":100}
        ]},"page":{"pn":1,"ps":30,"count":31}}
        """#)
        let page = SpaceAPI.parseArcSearch(data, page: 1, pageSize: 30)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "web:2:880002")
        let c = page.items[0]
        XCTAssertEqual(c.kind, .video)
        XCTAssertEqual(c.duration, 754)
        XCTAssertEqual(c.danmakuCount, 66)
        XCTAssertEqual(c.viewCount, 5000)
        XCTAssertEqual(c.pubdate, 1700000000)
        XCTAssertEqual(c.badge, "合作")
        XCTAssertEqual(c.progress, 377)
        XCTAssertEqual(c.seasonId, 0, "UGC season id must not turn the card into a PGC ref")
        XCTAssertFalse(c.videoRef.isPGC)
        XCTAssertEqual(page.items[1].progress, -1)
        XCTAssertEqual(page.items[1].viewCount, 0)

        let cursor = SpaceAPI.decodeVideoCursor(page.next)
        XCTAssertFalse(cursor.app)
        XCTAssertEqual(cursor.page, 2)
        XCTAssertEqual(cursor.lastAid, 880002)
        XCTAssertTrue(SpaceAPI.decodeVideoCursor("app:123").app)
        XCTAssertEqual(SpaceAPI.decodeVideoCursor("3").page, 3)

        let app = SpaceAPI.parseAppArchive(json(#"""
        {"count":100,"has_next":true,"item":[{"param":"990001","bvid":"BV1Uc4y1x7cc","first_cid":77,"title":"app视频",
          "cover":"http://i0.hdslb.com/a.jpg","duration":95,"play":1000,"danmaku":5,"author":"UP","publish_time_text":"3天前"}]}
        """#), mid: 42)
        XCTAssertEqual(app.items.first?.aid, 990001)
        XCTAssertEqual(app.items.first?.cid, 77)
        XCTAssertEqual(app.items.first?.ownerMid, 42)
        XCTAssertEqual(app.next, "app:990001")
    }

    func testSpaceInfoParsing() {
        var info = SpaceAPI.parseAccInfo(json(#"""
        {"mid":2,"name":"碧诗","sex":"男","face":"http://i0.hdslb.com/face.jpg","sign":"签名","level":6,"is_followed":true,
         "top_photo":"http://i1.hdslb.com/top.png","official":{"role":2,"title":"bilibili创始人","desc":"","type":0},
         "vip":{"type":2,"status":1,"label":{"text":"年度大会员"}},
         "live_room":{"roomStatus":1,"liveStatus":1,"title":"直播中","roomid":5440}}
        """#))
        SpaceAPI.mergeCard(json(#"{"card":{"mid":"2","fans":100,"attention":20},"archive_count":55,"follower":101,"like_num":9999,"following":true}"#), into: &info)
        SpaceAPI.applyRelationStat(json(#"{"mid":2,"following":21,"follower":102}"#), to: &info)
        XCTAssertEqual(info.mid, 2)
        XCTAssertEqual(info.level, 6)
        XCTAssertEqual(info.vipLabel, "年度大会员")
        XCTAssertEqual(info.officialTitle, "bilibili创始人")
        XCTAssertEqual(info.officialType, 0)
        XCTAssertEqual(info.topPhoto, "https://i1.hdslb.com/top.png")
        XCTAssertTrue(info.isFollowed)
        XCTAssertTrue(info.isLive)
        XCTAssertEqual(info.archiveCount, 55)
        XCTAssertEqual(info.likes, 9999)
        XCTAssertEqual(info.fans, 102)
        XCTAssertEqual(info.following, 21)

        let card = SpaceAPI.parseCard(json(#"""
        {"card":{"mid":"3","name":"卡片","face":"//i0.hdslb.com/c.jpg","sign":"s","fans":7,"attention":8,
          "level_info":{"current_level":5},"Official":{"type":1,"title":"","desc":"机构认证"},"vip":{"label":{"text":""}}},
         "space":{"l_img":"http://i0.hdslb.com/l.png"},"following":false,"archive_count":4,"follower":7,"like_num":3}
        """#))
        XCTAssertEqual(card.mid, 3)
        XCTAssertEqual(card.level, 5)
        XCTAssertEqual(card.officialTitle, "机构认证")
        XCTAssertEqual(card.topPhoto, "https://i0.hdslb.com/l.png")
        XCTAssertEqual(card.fans, 7)
        XCTAssertEqual(card.following, 8)
        XCTAssertEqual(card.archiveCount, 4)

        let rel = SpaceAPI.parseRelationList(json(#"""
        {"total":3,"list":[{"mid":10,"uname":"a","face":"//i0.hdslb.com/a.jpg","sign":"x","attribute":6},
                           {"mid":11,"uname":"b","attribute":0}]}
        """#), page: 1, pageSize: 2)
        XCTAssertEqual(rel.items.count, 2)
        XCTAssertTrue(rel.items[0].isFollowed)
        XCTAssertFalse(rel.items[1].isFollowed)
        XCTAssertTrue(rel.hasMore)
        XCTAssertEqual(rel.next, "2")
    }

    // MARK: - Live

    func testLivePlayURLAssembly() {
        let data = json(#"""
        {"room_id":22334455,"short_id":0,"uid":777,"is_portrait":false,"live_status":1,"live_time":1700000000,
         "playurl_info":{"playurl":{
           "g_qn_desc":[{"qn":10000,"desc":"原画"},{"qn":400,"desc":"蓝光"},{"qn":250,"desc":"超清"}],
           "stream":[
             {"protocol_name":"http_stream","format":[{"format_name":"flv","codec":[{"codec_name":"avc","current_qn":10000,"accept_qn":[10000,400],
               "base_url":"/live-bvc/live_1.flv?","url_info":[{"host":"https://cn-flv.bilivideo.com","extra":"expires=1"}]}]}]},
             {"protocol_name":"http_hls","format":[
               {"format_name":"ts","codec":[{"codec_name":"avc","current_qn":10000,"accept_qn":[10000,400],
                 "base_url":"/live-bvc/live_1/index.m3u8?","url_info":[{"host":"https://cn-ts.bilivideo.com","extra":"expires=2"}]}]},
               {"format_name":"fmp4","codec":[
                 {"codec_name":"hevc","current_qn":10000,"accept_qn":[10000],
                  "base_url":"/live-bvc/live_1_hevc/index.m3u8?","url_info":[{"host":"https://cn-hevc.bilivideo.com","extra":"expires=3"}]},
                 {"codec_name":"avc","current_qn":10000,"accept_qn":[10000,400,250],
                  "base_url":"/live-bvc/live_1_fmp4/index.m3u8?","url_info":[
                    {"host":"https://cn-a.bilivideo.com","extra":"expires=4&sign=a"},
                    {"host":"https://cn-b.bilivideo.com","extra":"expires=4&sign=b"}]}]}
             ]}
           ]}}}
        """#)
        let info = LiveAPI.parsePlayInfo(data)
        XCTAssertTrue(info.isLive)
        XCTAssertEqual(info.roomId, 22334455)
        // fmp4 (any codec) before ts: the ts lines time out from outside China.
        XCTAssertEqual(info.urls, [
            "https://cn-a.bilivideo.com/live-bvc/live_1_fmp4/index.m3u8?expires=4&sign=a",
            "https://cn-b.bilivideo.com/live-bvc/live_1_fmp4/index.m3u8?expires=4&sign=b",
            "https://cn-hevc.bilivideo.com/live-bvc/live_1_hevc/index.m3u8?expires=3",
            "https://cn-ts.bilivideo.com/live-bvc/live_1/index.m3u8?expires=2",
        ])
        XCTAssertFalse(info.urls.contains { $0.contains(".flv") })
        XCTAssertEqual(info.format, "fmp4")
        XCTAssertEqual(info.codec, "avc")
        XCTAssertEqual(info.currentQn, 10000)
        XCTAssertEqual(info.qualities.map(\.qn), [10000, 400, 250])
        XCTAssertEqual(info.qualities.map(\.desc), ["原画", "蓝光", "超清"])

        let offline = LiveAPI.parsePlayInfo(json(#"{"room_id":1,"live_status":0,"playurl_info":null}"#))
        XCTAssertFalse(offline.isLive)
        XCTAssertTrue(offline.urls.isEmpty)

        let flvOnly = LiveAPI.parsePlayInfo(json(#"""
        {"live_status":1,"playurl_info":{"playurl":{"stream":[{"protocol_name":"http_stream","format":[{"format_name":"flv",
          "codec":[{"codec_name":"avc","base_url":"/a.flv?","url_info":[{"host":"https://x","extra":""}]}]}]}]}}}
        """#))
        XCTAssertTrue(flvOnly.urls.isEmpty)
    }

    func testLiveFeedsAndRoomInfo() {
        let feed = LiveAPI.parseAppFeed(json(#"""
        {"has_more":1,"card_list":[
          {"card_type":"banner_v2","card_data":{"banner_v2":{"list":[{"id":1}]}}},
          {"card_type":"my_idol_v1","card_data":{"my_idol_v1":{"list":[{"roomid":1,"title":"idol"}]}}},
          {"card_type":"small_card_v1","card_data":{"small_card_v1":{"id":3003,"uid":30,"uname":"主播3","face":"http://i0.hdslb.com/f3.jpg",
            "title":"推荐直播","cover":"http://i0.hdslb.com/c3.jpg","system_cover":"","area_name":"英雄联盟",
            "watched_show":{"text_large":"2万人看过","num":20000}}}},
          {"card_type":"small_card_v1","card_data":{"small_card_v1":{"roomid":4004,"title":"另一个","cover":"https://i0.hdslb.com/c4.jpg",
            "system_cover":"https://i0.hdslb.com/s4.jpg"}}}
        ]}
        """#), page: 1)
        XCTAssertEqual(feed.items.map(\.roomId), [3003, 4004], "only small_card_v1")
        XCTAssertTrue(feed.hasMore)
        XCTAssertEqual(feed.next, "2")
        XCTAssertEqual(feed.items[0].cover, "https://i0.hdslb.com/c3.jpg")
        XCTAssertEqual(feed.items[0].watchedText, "2万人看过")
        XCTAssertEqual(feed.items[0].online, 20000)
        XCTAssertEqual(feed.items[1].cover, "https://i0.hdslb.com/s4.jpg", "system_cover preferred")
        XCTAssertEqual(feed.items[0].card.kind, .live)
        XCTAssertEqual(feed.items[0].card.roomId, 3003)

        let following = LiveAPI.parseFollowing(json(#"""
        {"totalPage":3,"list":[{"roomid":1,"uid":11,"uname":"a","title":"t","room_cover":"https://i0.hdslb.com/r.jpg","live_status":1,"text_small":"1.2万"},
                               {"roomid":2,"uname":"b","live_status":0}]}
        """#))
        XCTAssertEqual(following.rooms.map(\.roomId), [1])
        XCTAssertEqual(following.rooms.first?.cover, "https://i0.hdslb.com/r.jpg")
        XCTAssertTrue(following.sawOffline)
        XCTAssertEqual(following.totalPage, 3)

        let room = LiveAPI.parseH5Info(json(#"""
        {"room_info":{"room_id":5440,"uid":2,"title":"房间","cover":"http://i0.hdslb.com/c.jpg","live_status":1,"area_name":"聊天"},
         "anchor_info":{"base_info":{"uname":"主播","face":"https://i0.hdslb.com/f.jpg"}},"watched_show":{"text_large":"3万人看过"}}
        """#), roomId: 1)
        XCTAssertEqual(room.roomId, 5440)
        XCTAssertEqual(room.uname, "主播")
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.watchedText, "3万人看过")

        let dm = LiveAPI.parseDanmuInfo(json(#"{"token":"tok","host_list":[{"host":"a.chat.bilibili.com","port":2243,"wss_port":443,"ws_port":2244}]}"#))
        XCTAssertEqual(dm.token, "tok")
        XCTAssertEqual(dm.hosts.first?.wssURL, "wss://a.chat.bilibili.com:443/sub")
    }

    func testWebLiveRecommendRealShape() {
        // getUserRecommend (WBI) as served today: string-typed numbers, has_more 0 / 1.
        let page = LiveAPI.parseWebRecommend(json(#"""
        {"list":[
          {"roomid":"7734200","uid":"50329118","title":"赛事直播","uname":"哔哩哔哩英雄联盟赛事","online":"2233369",
           "user_cover":"https://i0.hdslb.com/bfs/live/new_room_cover/a.jpg","system_cover":"https://i0.hdslb.com/bfs/live-key-frame/k.jpg",
           "face":"https://i2.hdslb.com/bfs/face/f.jpg","area_name":"游戏赛事","watched_show":{"num":2233369,"text_large":"223.3万人看过"}},
          {"roomid":"7734200","title":"重复的房间"},
          {"roomid":"21622811","uid":"1","title":"另一个","uname":"主播"}
        ],"has_more":1,"cover_source":0}
        """#), page: 1)
        XCTAssertEqual(page.items.map(\.roomId), [7734200, 21622811])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "2")
        XCTAssertEqual(page.items[0].uname, "哔哩哔哩英雄联盟赛事")
        XCTAssertEqual(page.items[0].title, "赛事直播")
        let last = LiveAPI.parseWebRecommend(json(#"{"list":[{"roomid":"1","title":"t"}],"has_more":0}"#), page: 3)
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.next)
    }

    func testLiveRecommendCursorKeepsItsList() {
        XCTAssertNil(LiveAPI.recommendCursor(nil).source)
        XCTAssertEqual(LiveAPI.recommendCursor(nil).page, 1)
        XCTAssertEqual(LiveAPI.recommendCursor("a2").source, .app)
        XCTAssertEqual(LiveAPI.recommendCursor("a2").page, 2)
        XCTAssertEqual(LiveAPI.recommendCursor("w3").source, .web)
        XCTAssertEqual(LiveAPI.recommendCursor("w3").page, 3)
        // A bare page number (an older cursor) is an app-feed page; garbage starts over.
        XCTAssertEqual(LiveAPI.recommendCursor("2").source, .app)
        XCTAssertEqual(LiveAPI.recommendCursor("2").page, 2)
        XCTAssertNil(LiveAPI.recommendCursor("x5").source)
        XCTAssertEqual(LiveAPI.recommendCursor("x5").page, 1)
    }

    func testLivePlayURLPutsAV1Last() {
        let info = LiveAPI.parsePlayInfo(json(#"""
        {"live_status":1,"playurl_info":{"playurl":{"stream":[{"protocol_name":"http_hls","format":[
          {"format_name":"fmp4","codec":[
            {"codec_name":"av1","base_url":"/av1.m3u8?","url_info":[{"host":"https://av1","extra":""}]},
            {"codec_name":"hevc","base_url":"/hevc.m3u8?","url_info":[{"host":"https://hevc","extra":""}]}]},
          {"format_name":"ts","codec":[
            {"codec_name":"avc","base_url":"/ts.m3u8?","url_info":[{"host":"https://ts","extra":""}]}]}
        ]}]}}}
        """#))
        XCTAssertEqual(info.urls, ["https://hevc/hevc.m3u8?", "https://ts/ts.m3u8?", "https://av1/av1.m3u8?"])
        XCTAssertEqual(info.codec, "hevc")
    }

    // MARK: - Bangumi

    func testBangumiTimelineRankAndFollows() {
        let days = BangumiAPI.parseTimeline(json(#"""
        [{"date":"3-12","date_ts":1710172800,"day_of_week":2,"is_today":1,"episodes":[
          {"season_id":46000,"episode_id":800001,"title":"新番","cover":"http://i0.hdslb.com/n.jpg","pub_index":"第5话","pub_time":"01:30","follow":1}]},
         {"date":"3-13","day_of_week":3,"is_today":0,"episodes":[]}]
        """#))
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days[0].isToday)
        XCTAssertEqual(days[0].weekdayName, "周二")
        let ep = days[0].episodes[0]
        XCTAssertEqual(ep.kind, .bangumi)
        XCTAssertEqual(ep.seasonId, 46000)
        XCTAssertEqual(ep.epId, 800001)
        XCTAssertEqual(ep.reason, "01:30 第5话")
        XCTAssertTrue(ep.isFollowed)
        XCTAssertTrue(ep.videoRef.isPGC)

        let rank = BangumiAPI.parseRank(json(#"""
        {"list":[{"rank":1,"title":"排行番","cover":"https://i0.hdslb.com/r.jpg","url":"https://www.bilibili.com/bangumi/play/ss33378",
          "new_ep":{"index_show":"更新至第12话"},"stat":{"view":1000000,"follow":5000},"badge":"会员专享"},
         {"rank":2,"title":"无id","url":""}]}
        """#))
        XCTAssertEqual(rank.count, 1)
        XCTAssertEqual(rank[0].seasonId, 33378)
        XCTAssertEqual(rank[0].reason, "更新至第12话")
        XCTAssertEqual(rank[0].viewCount, 1_000_000)
        XCTAssertEqual(rank[0].badge, "会员专享")

        let follows = BangumiAPI.parseFollows(json(#"""
        {"total":16,"list":[{"season_id":1,"title":"追的番","cover":"//i0.hdslb.com/f.jpg","badge":"独家","progress":"看到第3话",
          "new_ep":{"index_show":"全12话"}}]}
        """#), page: 1, pageSize: 15)
        XCTAssertEqual(follows.items.first?.reason, "看到第3话")
        XCTAssertEqual(follows.items.first?.cover, "https://i0.hdslb.com/f.jpg")
        XCTAssertTrue(follows.hasMore)
    }
}
