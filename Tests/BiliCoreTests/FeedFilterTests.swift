import XCTest
@testable import BiliCore

final class FeedFilterTests: XCTestCase {
    // MARK: Helpers

    private func video(_ title: String = "普通视频", mid: Int64 = 1, name: String = "某UP", duration: Int = 300,
                       views: Int64 = 0, likes: Int64 = 0, desc: String = "", badge: String = "",
                       reason: String = "", kind: CardKind = .video, signals: [String] = [],
                       followed: Bool = false) -> VideoCard {
        var c = VideoCard(id: UUID().uuidString)
        c.kind = kind
        c.title = title
        c.ownerMid = mid
        c.ownerName = name
        c.duration = duration
        c.viewCount = views
        c.likeCount = likes
        c.desc = desc
        c.badge = badge
        c.reason = reason
        c.adSignals = signals
        c.isFollowed = followed
        return c
    }

    private func filter(_ configure: (inout FeedFilterSettings) -> Void = { _ in },
                        followed: Set<Int64> = []) -> FeedFilter {
        var s = FeedFilterSettings()
        configure(&s)
        return FeedFilter(settings: s, followedMids: followed)
    }

    private let listScopes: [FeedScope] = [.recommend, .popular, .ranking, .search, .related, .dynamics, .space]

    // MARK: Defaults

    func testDefaults() {
        let s = FeedFilterSettings()
        XCTAssertTrue(s.blockAdCards)
        XCTAssertFalse(s.blockPromotedVideos)
        XCTAssertTrue(s.blockLiveCards)
        XCTAssertFalse(s.blockPGCCards)
        XCTAssertEqual(s.minDuration, 0)
        XCTAssertEqual(s.minLikeRatio, 0)
        XCTAssertEqual(s.minPlayCount, 0)
        XCTAssertTrue(s.exemptFollowed)
        XCTAssertTrue(s.applyToAllLists)
        // A plain video passes everywhere with default settings.
        let f = filter()
        for scope in FeedScope.allCases { XCTAssertTrue(f.allows(video(), scope: scope), "\(scope)") }
    }

    func testOldSavedSettingsGetNewFieldDefaults() throws {
        let suite = "FeedFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = SettingsStore.defaults
        SettingsStore.defaults = defaults
        defer {
            SettingsStore.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        let old = #"{"blockAdCards":false,"blockedKeywords":["抽奖"],"minDuration":60}"#
        defaults.set(Data(old.utf8), forKey: "settings.feedFilter")
        let s = SettingsStore.load(FeedFilterSettings.self, key: "settings.feedFilter")
        XCTAssertFalse(s.blockAdCards)
        XCTAssertEqual(s.blockedKeywords, ["抽奖"])
        XCTAssertEqual(s.minDuration, 60)
        XCTAssertEqual(s.minLikeRatio, 0)
        XCTAssertEqual(s.minPlayCount, 0)
        XCTAssertTrue(s.exemptFollowed)
    }

    // MARK: Ads

    func testAdKindBlockedInEveryListButUserCurated() {
        let f = filter()
        let ad = video("某品牌新品", kind: .ad)
        for scope in listScopes { XCTAssertFalse(f.allows(ad, scope: scope), "\(scope)") }
        XCTAssertTrue(f.allows(ad, scope: .history))
        XCTAssertTrue(f.allows(ad, scope: .favorites))
        XCTAssertEqual(f.reason(for: ad, scope: .recommend), .ad(signal: "kind=ad"))
        XCTAssertTrue(filter { $0.blockAdCards = false }.allows(ad, scope: .recommend))
    }

    func testHardAdSignalsBlockEvenWhenKindIsVideo() {
        let f = filter()
        for signal in ["goto=ad", "business_info", "card_goto=ad_av", "ad_info", "card_type=cm_v2"] {
            let c = video("创作推广的视频", signals: [signal])
            XCTAssertEqual(f.reason(for: c, scope: .recommend), .ad(signal: signal))
            XCTAssertFalse(f.allows(c, scope: .search))
        }
    }

    func testAdCardsBlockedEvenFromFollowedUpsAndWithoutApplyToAll() {
        let f = filter({ $0.applyToAllLists = false }, followed: [1])
        let c = video(mid: 1, signals: ["business_info"], followed: true)
        XCTAssertFalse(f.allows(c, scope: .recommend))
        XCTAssertFalse(f.allows(c, scope: .popular))
    }

    func testGoodsSignalIsPromotionNotAdCard() {
        let goods = video("新视频", kind: .ad, signals: ["goods"])
        XCTAssertNil(FeedFilter.hardAdSignal(of: goods))
        // Default settings: ads blocked, promotion heuristic off → goods card stays.
        XCTAssertTrue(filter().allows(goods, scope: .recommend))
        XCTAssertTrue(filter().allows(goods, scope: .dynamics))
        let f = filter { $0.blockPromotedVideos = true }
        XCTAssertEqual(f.reason(for: goods, scope: .recommend), .promoted(evidence: "带货标记（goods）"))
        // Dynamics are all followed UPs: the 带货 rule ignores the follow exemption there.
        let followedGoods = video("新视频", signals: ["goods"], followed: true)
        XCTAssertFalse(f.allows(followedGoods, scope: .dynamics))
        XCTAssertTrue(f.allows(followedGoods, scope: .recommend))
        // Mixed: a hard signal next to goods is still an ad card.
        let mixed = video(signals: ["goods", "ad_info"])
        XCTAssertEqual(filter().reason(for: mixed, scope: .recommend), .ad(signal: "ad_info"))
    }

    // MARK: Card types

    func testLiveAndPGCOnlyInRecommend() {
        let live = video("直播中", kind: .live)
        let pgc = video("番剧", kind: .bangumi)
        let f = filter { $0.blockLiveCards = true; $0.blockPGCCards = true }
        XCTAssertEqual(f.reason(for: live, scope: .recommend), .liveCard)
        XCTAssertEqual(f.reason(for: pgc, scope: .recommend), .pgcCard)
        for scope in [FeedScope.popular, .ranking, .search, .related, .dynamics, .space] {
            XCTAssertTrue(f.allows(live, scope: scope), "\(scope)")
            XCTAssertTrue(f.allows(pgc, scope: scope), "\(scope)")
        }
        let off = filter { $0.blockLiveCards = false; $0.blockPGCCards = false }
        XCTAssertTrue(off.allows(live, scope: .recommend))
        XCTAssertTrue(off.allows(pgc, scope: .recommend))
    }

    // MARK: Keywords

    func testPlainKeywordCaseInsensitiveSubstring() {
        let f = filter { $0.blockedKeywords = ["ASMR", "  抽奖 ", ""] }
        XCTAssertEqual(f.reason(for: video("深夜asmr助眠"), scope: .recommend), .keyword(rule: "ASMR"))
        XCTAssertEqual(f.reason(for: video("评论区抽奖送耳机"), scope: .recommend), .keyword(rule: "抽奖"))
        XCTAssertTrue(f.allows(video("正常的科普视频"), scope: .recommend))
        // Search titles carry <em> markup.
        XCTAssertFalse(f.allows(video(#"<em class="keyword">AS</em>MR合集"#), scope: .search))
    }

    func testRegexKeyword() {
        let f = filter { $0.blockedKeywords = ["/震惊|速看/", "/^【.{1,4}】$/"] }
        XCTAssertEqual(f.reason(for: video("震惊！这个视频"), scope: .recommend), .keyword(rule: "/震惊|速看/"))
        XCTAssertFalse(f.allows(video("速看，马上删"), scope: .recommend))
        XCTAssertFalse(f.allows(video("【预告】"), scope: .recommend))
        XCTAssertTrue(f.allows(video("【预告】第二季"), scope: .recommend))
        // Case-insensitive regexes.
        let g = filter { $0.blockedKeywords = ["/^minecraft/"] }
        XCTAssertFalse(g.allows(video("MineCraft 生存 #1"), scope: .recommend))
    }

    func testInvalidRegexIgnored() {
        XCTAssertFalse(FeedFilter.isValidKeywordRule("/[unclosed/"))
        XCTAssertFalse(FeedFilter.isValidKeywordRule("   "))
        XCTAssertTrue(FeedFilter.isValidKeywordRule("/a|b/"))
        XCTAssertTrue(FeedFilter.isValidKeywordRule("[unclosed"))   // plain text
        XCTAssertTrue(FeedFilter.isValidKeywordRule("//"))          // too short for a regex → plain
        let f = filter { $0.blockedKeywords = ["/[unclosed/", "/(?<bad/", "抽奖"] }
        XCTAssertTrue(f.allows(video("[unclosed 测试"), scope: .recommend))
        XCTAssertFalse(f.allows(video("抽奖"), scope: .recommend))
        // Building the filter twice reuses the cached (invalid) compile result.
        XCTAssertTrue(filter { $0.blockedKeywords = ["/[unclosed/"] }.allows(video("x"), scope: .recommend))
    }

    // MARK: Uploaders

    func testUploaderByNameAndMid() {
        let f = filter { $0.blockedUploaders = ["营销号A", "12345", "UID:678", "uid： 999", "@AbcUp"] }
        XCTAssertEqual(f.reason(for: video(mid: 2, name: "营销号A"), scope: .recommend), .uploader(rule: "营销号A"))
        XCTAssertTrue(f.allows(video(mid: 2, name: "营销号AB"), scope: .recommend))     // exact names only
        XCTAssertEqual(f.reason(for: video(mid: 12345, name: "x"), scope: .recommend), .uploader(rule: "12345"))
        XCTAssertFalse(f.allows(video(mid: 678, name: "y"), scope: .recommend))
        XCTAssertFalse(f.allows(video(mid: 999, name: "z"), scope: .recommend))
        XCTAssertFalse(f.allows(video(mid: 3, name: "abcup"), scope: .recommend))
        XCTAssertTrue(f.allows(video(mid: 3, name: "其他"), scope: .recommend))
        XCTAssertEqual(FeedFilter.parseMid("UID:678"), 678)
        XCTAssertNil(FeedFilter.parseMid("midnight"))
        XCTAssertNil(FeedFilter.parseMid("0"))
    }

    func testBlockedUploaderWinsOverFollowExemption() {
        let f = filter({ $0.blockedUploaders = ["12345"] }, followed: [12345])
        XCTAssertFalse(f.allows(video(mid: 12345, followed: true), scope: .recommend))
    }

    // MARK: Thresholds

    func testMinDuration() {
        let f = filter { $0.minDuration = 60; $0.blockLiveCards = false }
        XCTAssertEqual(f.reason(for: video(duration: 20), scope: .recommend), .tooShort(duration: 20, minimum: 60))
        XCTAssertTrue(f.allows(video(duration: 60), scope: .recommend))
        XCTAssertTrue(f.allows(video(duration: 0), scope: .recommend))          // unknown duration
        XCTAssertTrue(f.allows(video(duration: 20, kind: .live), scope: .recommend))
        XCTAssertFalse(f.allows(video(duration: 20), scope: .related))
        XCTAssertTrue(f.allows(video(duration: 20), scope: .search))            // never on search
    }

    func testLikeRatio() {
        let f = filter { $0.minLikeRatio = 2 }
        XCTAssertEqual(f.reason(for: video(views: 1000, likes: 10), scope: .recommend),
                       .lowLikeRatio(likes: 10, views: 1000, minimumPercent: 2))
        XCTAssertTrue(f.allows(video(views: 1000, likes: 20), scope: .recommend))   // exactly 2 %
        XCTAssertTrue(f.allows(video(views: 1000, likes: 0), scope: .recommend))    // likes unknown
        XCTAssertTrue(f.allows(video(views: 0, likes: 5), scope: .recommend))       // views unknown
        XCTAssertFalse(f.allows(video(views: 100_000, likes: 100), scope: .popular))
    }

    func testMinPlayCount() {
        let f = filter { $0.minPlayCount = 100 }
        XCTAssertEqual(f.reason(for: video(views: 30), scope: .recommend), .lowPlayCount(views: 30, minimum: 100))
        XCTAssertTrue(f.allows(video(views: 100), scope: .recommend))
        XCTAssertTrue(f.allows(video(views: 0), scope: .recommend))
    }

    // MARK: Follow exemption

    func testExemptFollowed() {
        let rules: (inout FeedFilterSettings) -> Void = {
            $0.blockedKeywords = ["抽奖"]
            $0.minDuration = 60
            $0.blockPromotedVideos = true
        }
        let f = filter(rules, followed: [42])
        XCTAssertTrue(f.allows(video("抽奖", mid: 7, followed: true), scope: .recommend))  // card flag
        XCTAssertTrue(f.allows(video("抽奖", mid: 42), scope: .recommend))                 // followed set
        XCTAssertTrue(f.allows(video("抽奖", mid: 7, reason: "已关注"), scope: .recommend)) // feed reason
        XCTAssertTrue(f.allows(video("短", mid: 42, duration: 10), scope: .related))
        XCTAssertTrue(f.allows(video("【恰饭】", mid: 42), scope: .recommend))
        XCTAssertFalse(f.allows(video("抽奖", mid: 7), scope: .recommend))
        let strict = filter({ rules(&$0); $0.exemptFollowed = false }, followed: [42])
        XCTAssertEqual(strict.reason(for: video("抽奖", mid: 42), scope: .recommend), .keyword(rule: "抽奖"))
        XCTAssertTrue(f.isFollowed(video(mid: 42)))
        XCTAssertFalse(f.isFollowed(video(mid: 0)))
    }

    // MARK: Scopes

    func testApplyToAllListsControlsSecondaryScopes() {
        let card = video("抽奖")
        let on = filter { $0.blockedKeywords = ["抽奖"] }
        let off = filter { $0.blockedKeywords = ["抽奖"]; $0.applyToAllLists = false }
        for scope in [FeedScope.popular, .ranking, .search, .related] {
            XCTAssertFalse(on.allows(card, scope: scope), "\(scope)")
            XCTAssertTrue(off.allows(card, scope: scope), "\(scope)")
        }
        XCTAssertFalse(off.allows(card, scope: .recommend))
        for scope in [FeedScope.dynamics, .space, .history, .favorites] {
            XCTAssertTrue(on.allows(card, scope: scope), "\(scope)")
        }
    }

    func testHistoryAndFavoritesAreNeverFiltered() {
        let f = filter {
            $0.blockedKeywords = ["抽奖"]; $0.blockedUploaders = ["1"]; $0.minDuration = 600
            $0.blockPromotedVideos = true; $0.blockLiveCards = true; $0.blockPGCCards = true
        }
        let cards = [video("抽奖"), video(kind: .ad), video(signals: ["ad_info"]), video("【恰饭】"),
                     video(kind: .live), video(duration: 5)]
        for scope in [FeedScope.history, .favorites] {
            XCTAssertEqual(f.apply(cards, scope: scope).count, cards.count)
        }
    }

    func testFilterClosureAndApply() {
        let f = filter { $0.blockedKeywords = ["抽奖"] }
        let keep = f.filterClosure(scope: .recommend)
        XCTAssertFalse(keep(video("抽奖")))
        XCTAssertTrue(keep(video("正常")))
        let out = f.apply([video("a"), video("抽奖"), video(kind: .ad), video("b")], scope: .recommend)
        XCTAssertEqual(out.map(\.title), ["a", "b"])
    }

    func testExplain() {
        let f = filter { $0.blockedKeywords = ["抽奖"]; $0.minLikeRatio = 3 }
        XCTAssertNil(f.explain(video("正常"), scope: .recommend))
        XCTAssertEqual(f.explain(video("抽奖"), scope: .recommend), "命中关键词 抽奖")
        XCTAssertEqual(f.explain(video(signals: ["goto=ad"]), scope: .recommend), "广告卡片（goto=ad）")
        XCTAssertEqual(f.explain(video(views: 1000, likes: 5), scope: .recommend), "点赞率 0.50%，低于 3%")
        XCTAssertNotNil(filter { $0.blockPromotedVideos = true }.explain(video("【恰饭】耳机"), scope: .recommend))
    }

    // MARK: 恰饭 heuristic

    func testPromotionHeuristicTruePositives() {
        let f = filter { $0.blockPromotedVideos = true }
        let cases: [VideoCard] = [
            video("【恰饭】这款耳机真的值得买吗"),
            video("[商单] 新手机上手"),
            video("（广告）夏日新品"),
            video("本期视频由XX品牌赞助播出"),
            video("开箱", desc: "感谢XX对本期视频的赞助！"),
            video("开箱", desc: "本视频由XX提供支持"),
            video("这是一期商单，大家理解一下"),
            video("#品牌合作# 新品体验"),
            video("新品体验 #恰饭"),
            video("种草！夏季好物推荐"),
            video("UP也要恰饭的嘛"),
            video("恰个饭，顺便聊聊近况"),
            video("感谢金主爸爸"),
            video("评测", desc: "购买链接见置顶，专属优惠码 BILI"),
            video("新品", badge: "广告"),
            video("新品", reason: "创作推广"),
            video("本视频含商业推广"),
            video("【已恰饭】耳机体验"),
            video("评测", desc: "本期视频由 XX 独家冠名"),
            video("【推广】新游戏试玩"),
        ]
        for c in cases {
            XCTAssertNotNil(FeedPromotionDetector.evidence(for: c), "should block: \(c.title) / \(c.desc) / \(c.badge) / \(c.reason)")
            XCTAssertFalse(f.allows(c, scope: .recommend), c.title)
        }
    }

    func testPromotionHeuristicFalsePositives() {
        let f = filter { $0.blockPromotedVideos = true }
        let cases: [VideoCard] = [
            video("广告学专业解读"),
            video("【广告学】考研经验分享"),
            video("推广普通话的意义"),
            video("无广告纯享版"),
            video("去广告教程"),
            video("非商单，自费购买的真实测评"),
            video("绝对不是恰饭！良心推荐"),
            video("这期是恰饭吗？"),
            video("长沙恰饭vlog"),
            video("如何接商单？UP主经验谈"),
            video("UP主商单收入揭秘"),
            video("盘点那些魔性的广告"),
            video("广告推广的十种方法"),
            video("经典广告片赏析"),
            video("F1 车队的赞助商有哪些"),
            video("直播带货乱象调查"),
            video("游戏实况", desc: "商务合作请联系：abc@qq.com"),
            video("日常", desc: "商单/广告合作请私信，不接受任何形式的推广"),
            video("测评", desc: "本视频无广告，耳机自费购买，购买链接见置顶"),
            video("感谢大家的支持，本期没有赞助"),
            video("一个普通的视频", badge: "合作", reason: "1万点赞"),
            video("新番推荐 #番剧"),
            video("日常", desc: "合作请联系邮箱 商单勿扰"),
            video("日常", desc: "商单dd"),
            video("测评", desc: "本视频不含任何商业推广"),
            video("测评", desc: "本期没有任何广告和赞助"),
            video("带货主播翻车，优惠券竟是假的"),
            video("【无广告】纯享版"),
            video("【广告位招租】"),
            video("#推广普通话#"),
            video("[4K60帧] 广告太多了"),
        ]
        for c in cases {
            XCTAssertNil(FeedPromotionDetector.evidence(for: c), "false positive: \(c.title) / \(c.desc)")
            XCTAssertTrue(f.allows(c, scope: .recommend), c.title)
        }
    }

    func testPromotionHeuristicOffByDefault() {
        XCTAssertTrue(filter().allows(video("【恰饭】这款耳机"), scope: .recommend))
    }

    // MARK: Shared instance / followed store

    func testCurrentFollowsAppSettings() {
        let saved = AppSettings.shared.feedFilter
        defer { AppSettings.shared.feedFilter = saved }
        AppSettings.shared.feedFilter.blockedKeywords = ["当前规则"]
        XCTAssertFalse(FeedFilter.current.allows(video("当前规则测试"), scope: .recommend))
        let live = FeedFilter.liveFilter(scope: .recommend)
        XCTAssertFalse(live(video("当前规则测试")))
        AppSettings.shared.feedFilter.blockedKeywords = []
        XCTAssertTrue(FeedFilter.current.allows(video("当前规则测试"), scope: .recommend))
        XCTAssertTrue(live(video("当前规则测试")))
    }

    func testFollowedUpsStore() {
        let store = FollowedUpsStore(defaults: nil)
        XCTAssertTrue(store.mids.isEmpty)
        store.update([1, 2, 3])
        XCTAssertTrue(store.contains(2))
        store.insert(4)
        store.remove(1)
        XCTAssertEqual(store.mids, [2, 3, 4])
        store.mids = [9]
        XCTAssertEqual(store.count, 1)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i % 2 == 0 { store.insert(Int64(1000 + i)) } else { _ = store.contains(Int64(i)) }
        }
        XCTAssertEqual(store.count, 101)
        store.clear()
        XCTAssertTrue(store.mids.isEmpty)

        let f = FeedFilter(settings: { var s = FeedFilterSettings(); s.blockedKeywords = ["x"]; return s }(),
                           isFollowed: { store.contains($0) })
        XCTAssertFalse(f.allows(video("x", mid: 77), scope: .recommend))
        store.insert(77)
        XCTAssertTrue(f.allows(video("x", mid: 77), scope: .recommend))
    }

    func testFollowedUpsStorePersists() throws {
        let suite = "FeedFilterTests.store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        FollowedUpsStore(defaults: defaults).update([5, 6])
        XCTAssertEqual(FollowedUpsStore(defaults: defaults).mids, [5, 6])
        FollowedUpsStore(defaults: defaults).clear()
        XCTAssertTrue(FollowedUpsStore(defaults: defaults).mids.isEmpty)
    }
}
