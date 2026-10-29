// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): detectors.js. Upstream cases from
// test-branch 24d28a8 (`label-confidence`, `subtitle-local`) plus the spec's worked examples (§15).

import XCTest
@testable import BiliCore

final class SmartSkipLabelTests: XCTestCase {
    func testEnglishSubstringsAndNegatedLabelsAreNotAds() {
        for label in ["Download", "Shader tutorial", "Adapter", "无广告", "不是广告", "非广告", "没有赞助", "No ads",
                      "without sponsorship", "Ad-free tutorial"] {
            XCTAssertNil(SmartSkipDetectors.getAdLabelEvidence(label), label)
        }
    }

    func testDiscussingAdvertisingRequiresConfirmation() {
        for label in ["广告识别算法", "广告的发展历史", "广告：为什么越来越多", "广告（识别教程）", "Ad detection", "sponsor marketing history"] {
            let evidence = SmartSkipDetectors.getAdLabelEvidence(label)
            XCTAssertEqual(evidence?.requiresConfirmation, true, label)
            XCTAssertEqual(evidence?.reason, "ambiguous-ad-label", label)
        }
    }

    func testExplicitLabels() {
        for label in ["广告", "广告时间：某产品", "恰饭环节", "某产品（广告）", "Ad", "Sponsored segment: product", " 赞助 ", "sponsorship",
                      "推广环节 | 某 App", "广告片段(30s)", "某产品 (ad)"] {
            let evidence = SmartSkipDetectors.getAdLabelEvidence(label)
            XCTAssertEqual(evidence?.requiresConfirmation, false, label)
            XCTAssertEqual(evidence?.reason, "explicit-ad-label", label)
        }
    }

    func testMatchedKeywordsAreOrderedAndDeduplicated() {
        XCTAssertEqual(SmartSkipDetectors.getAdLabelEvidence("推广 广告 ad Ad sponsored")?.matchedKeywords, ["广告", "推广", "ad", "sponsored"])
        XCTAssertEqual(SmartSkipDetectors.getAdLabelEvidence("广告ad")?.matchedKeywords, ["广告", "ad"], "ASCII \\b between 告 and a")
        XCTAssertNil(SmartSkipDetectors.getAdLabelEvidence("sponsors"), "sponsor+s has no word boundary")
        XCTAssertNil(SmartSkipDetectors.getAdLabelEvidence(""))
    }

    func testFirstExplicitChapterWinsEvenIfLaterInvalid() {
        let chapters = [SSFixtures.chapter(30, 50, "广告历史"), SSFixtures.chapter(30, 50, "广告"), SSFixtures.chapter(100, 150, "广告")]
        XCTAssertEqual(SmartSkipDetectors.detectFromChapters(chapters)?.start, 30)
        XCTAssertEqual(SmartSkipDetectors.detectFromChapters(chapters)?.requiresConfirmation, false)
        let ambiguousOnly = [SSFixtures.chapter(70, 130, "广告历史"), SSFixtures.chapter(200, 250, "赞助商的故事")]
        XCTAssertEqual(SmartSkipDetectors.detectFromChapters(ambiguousOnly)?.start, 70, "first ambiguous kept as fallback")
        XCTAssertNil(SmartSkipDetectors.detectFromChapters([]))
        XCTAssertNil(SmartSkipDetectors.detectFromChapters(nil))
    }

    func testDescriptionEntries() {
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1:10 Download\n2:20 正片", 600))
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1:10 无广告\n2:20 正片", 600))
        let ambiguous = SmartSkipDetectors.detectFromDescription("1:10 广告历史\n2:20 正片", 600)
        XCTAssertEqual(ambiguous?.requiresConfirmation, true)
        let explicit = SmartSkipDetectors.detectFromDescription("1:10 广告\n2:20 正片", 600)
        XCTAssertEqual([explicit?.start, explicit?.end], [70, 140])
        XCTAssertEqual(explicit?.requiresConfirmation, false)
        let last = SmartSkipDetectors.detectFromDescription("1:00 正片\n2:00 广告", 600)
        XCTAssertEqual([last?.start, last?.end], [120, 600], "the last entry ends at the video duration")
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1:10 广告", 600), "needs at least two entries")
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("", 600))
    }

    func testDescriptionQuirksLikeMaster() {
        // `\s` spans newlines: the label swallows the next line (spec §15.4).
        let swallowed = SmartSkipDetectors.detectFromDescription("01:30\n02:00 正片\n03:00 广告\n04:00 正片", 600)
        XCTAssertEqual([swallowed?.start, swallowed?.end], [180, 240])
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1：10 广告\n2：20 正片", 600), "full-width colon is not accepted here")
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1:70 广告\n2:00 正片\n3:00 正片", 600), "seconds ≥ 60 skip the entry")
        XCTAssertNil(SmartSkipDetectors.detectFromDescription("1:02:03 广告\n1:03:00 正片", 600), "hour stamps never match")
        let leading = SmartSkipDetectors.detectFromDescription("  简介\n 1:10 广告\n2:20 正片", 600)
        XCTAssertEqual(leading?.start, 70)
    }
}

final class SmartSkipSubtitleLocalTests: XCTestCase {
    private func line(_ from: Double, _ content: String, _ length: Double = 2) -> SubtitleLine { SSFixtures.line(from, content, length) }
    private func detect(_ subtitles: [SubtitleLine]?) -> SmartSkipSegment? { SmartSkipDetectors.detectFromSubtitles(subtitles, []) }

    func testOrdinaryFreeSearchPurchaseCooperationWordsDoNotEstablishAnAd() {
        for subtitles in [
            [line(79, "这个工具是免费的"), line(99, "搜索你想了解的内容")],
            [line(141.38, "你拿金币购买的武器"), line(261.789, "一部分可购买资源"), line(263.589, "一部分不可购买资源"), line(367.34, "只能购买六个")],
            [line(835.2, "日本从英国和法国购买的装甲巡洋舰"), line(850, "两国合作建造军舰")],
            [line(100, "欢迎在评论区讨论"), line(108, "点赞关注推荐给大家")],
            [line(100, "点击链接查看免费教程"), line(108, "评论区下载资料")],
        ] {
            XCTAssertNil(detect(subtitles), "\(subtitles.map(\.content))")
        }
    }

    func testLocalSponsorshipPlusConcreteOfferRetainsManualCandidate() {
        let result = detect([line(100, "本期视频由某品牌赞助"), line(114, "新用户专属优惠券")])
        XCTAssertEqual(result?.requiresConfirmation, true)
        XCTAssertEqual(result?.reason, "subtitle-sponsor-offer")
        XCTAssertEqual([result?.start, result?.end], [100, 116])
    }

    func testSponsorshipWithoutNearbyOfferDoesNotBridgeATopic() {
        XCTAssertNil(detect([line(100, "本期视频由某品牌赞助"), line(150, "注册免费体验课程")]))
        XCTAssertNil(detect([line(100, "这里讨论商业赞助"), line(110, "新用户有优惠券")]))
    }

    func testSingleExplicitCTAProducesOnlyABoundedManualHint() {
        let subtitles = [line(323.91, "现在点击下方评论区链接就能直达服饰会场", 3.43)]
        let danmaku = [SmartSkipDanmaku(time: 207.593, textContent: "我女票买了同款")]
        let result = SmartSkipDetectors.detectFromSubtitles(subtitles, danmaku)
        XCTAssertEqual(result!.start, 318.91, accuracy: 1e-9)
        XCTAssertEqual(result!.end, 332.34, accuracy: 0.001)
        XCTAssertEqual(result?.boundaryPaddingSeconds, 5)
        XCTAssertEqual(result?.requiresConfirmation, true)
        XCTAssertEqual(result?.reason, "subtitle-local-cta")

        let fixture = SSFixture(subtitles: subtitles, danmaku: danmaku)
        let (selected, h) = SSHarness.detectAndAttach(fixture, mode: .auto)
        XCTAssertEqual(selected?.source, "subtitles")
        h.tick(selected!.start)
        h.advance(10)
        XCTAssertSeeks(h, [])
        let (manualSegment, manual) = SSHarness.detectAndAttach(fixture, mode: .auto)
        manual.tick(manualSegment!.start)
        manual.click()
        XCTAssertSeeks(manual, [manualSegment!.end + 0.05])
    }

    func testSingleTransactionInstructionsAreRetainedWithoutABrandDictionary() {
        let result = detect([line(196.6, "一键下单就能通通打包带走", 2.28)])
        XCTAssertEqual(result?.requiresConfirmation, true)
        XCTAssertLessThan(result!.end - result!.start, 13)
        XCTAssertNil(detect([line(196.6, "我刚刚下单了"), line(202, "他也购买了")]))
    }

    func testCTASplitAcrossAdjacentRowsIsRecognized() {
        let result = detect([line(100, "请点击"), line(102, "评论区置顶链接"), line(104, "领取专属优惠券")])
        XCTAssertEqual(result?.requiresConfirmation, true)
        XCTAssertTrue(result?.matchedKeywords.contains { $0.contains("点击评论区置顶链接") } ?? false, "\(String(describing: result?.matchedKeywords))")
    }

    func testDistantRowsCannotBeCombinedIntoOneArtificialCTA() {
        XCTAssertNil(detect([line(100, "请点击"), line(130, "评论区置顶链接")]))
    }

    func testNegatedSponsorAndPurchaseInstructionsAreNotPositiveEvidence() {
        for text in ["本期视频不是由任何公司赞助", "本期视频没有赞助", "不要点击评论区链接领取优惠券", "千万别点击评论区链接", "禁止点击链接购买"] {
            XCTAssertNil(detect([line(100, text)]), text)
        }
        XCTAssertNil(detect([line(100, "千万不要"), line(102, "点击链接购买商品")]))
    }

    func testEnglishSponsorshipSurvivesWhitespaceNormalization() {
        let result = detect([line(100, "This video is sponsored by Example"), line(110, "新用户优惠券")])
        XCTAssertEqual(result?.reason, "subtitle-sponsor-offer")
        XCTAssertEqual(result?.requiresConfirmation, true)
    }

    func testGenericRouteNeedsNearbyCommercialEvidence() {
        XCTAssertNil(detect([line(100, "点击下方链接")]))
        let result = detect([line(100, "点击下方链接"), line(110, "领取新用户优惠券")])
        XCTAssertEqual(result?.requiresConfirmation, true)
    }

    func testNegativeClauseDoesNotEraseAnIndependentPositiveClause() {
        let result = detect([line(100, "不要乱买，点击下方蓝链领取优惠券")])
        XCTAssertEqual(result?.requiresConfirmation, true)
    }

    func testRealSausageHistoryPurchaseCannotExtendThePrecedingPromotion() {
        let result = detect([
            line(220.1, "叠加新人优惠到手更是低至60出头", 2.82),
            line(231.96, "全场包邮", 0.84),
            line(232.8, "快来点击置顶评论区链接", 1.6),
            line(234.4, "直接领券", 0.78),
            line(244.96, "快来点击置顶评论区链接吧", 1.78),
            line(252.42, "在汉堡包以外"),
            line(256.68, "其实是各式各样的香肠制品"),
            line(293.5, "纽约洋基体育场内有个小贩大声的叫卖吆喝"),
            line(297.18, "鼓动观众趁热购买自家的腊肠犬香肠", 3.14),
        ])
        XCTAssertEqual(result!.end, 246.74, accuracy: 1e-9)
        XCTAssertEqual(result?.boundaryPaddingSeconds, 0)
    }

    func testLongNeutralPassagesSplitEvidenceEvenWhenTimingIsDense() {
        let subtitles = [line(100, "本期视频由某品牌赞助")]
            + (0..<9).map { line(102 + Double($0), "下面讨论历史正文", 1) }
            + [line(111, "专属优惠券")]
        XCTAssertNil(detect(subtitles))
    }

    func testTwoLocalCTAGroupsRemainSeparateAndTheStrongerGroupWins() {
        let result = detect([line(100, "点击下方链接"), line(190, "点击评论区领取优惠券"), line(202, "立即下单")])
        XCTAssertEqual([result?.start, result?.end], [190, 204])
    }

    func testInvalidSubtitleTimesAreIgnoredAndInputIsNotMutated() {
        // (the upstream `null` row cannot exist in a Swift `[SubtitleLine]`)
        let subtitles = [line(120, "现在下单"), line(.nan, "点击链接"), line(-1, "点击链接"),
                         SubtitleLine(from: 10, to: 9, content: "点击链接"), line(100, "今天聊别的")]
        let copy = subtitles
        let result = detect(subtitles)
        XCTAssertEqual(result?.start, 115)
        XCTAssertEqual(subtitles.map(\.content), copy.map(\.content))
        XCTAssertNil(detect(nil))
    }

    func testExplicitDanmakuTimestampsRetainPriorityOverASubtitleCTA() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: [line(100, "点击评论区领取优惠券")],
                                                               danmaku: [SmartSkipDanmaku(time: 74, textContent: "跳过广告 2:00")]))
        XCTAssertEqual(segment?.source, "danmaku-time")
        XCTAssertEqual(segment?.requiresConfirmation, false)
        h.tick(segment!.start)
        XCTAssertSeeks(h, [120.05])
    }

    func testSubtitleEvidenceClausesAndCategories() {
        let evidence = SmartSkipDetectors.getSubtitleEvidence("本期视频由某品牌赞助，点击下方蓝链领取优惠券")
        XCTAssertEqual(evidence.categories, ["sponsor", "cta", "route", "offer", "pitch"])
        XCTAssertTrue(evidence.matched.contains("优惠券"))
        XCTAssertEqual(SmartSkipDetectors.getSubtitleEvidence("不要点击链接，限时优惠").categories, ["offer", "pitch"],
                       "the negated clause is skipped, the other clause still counts")
        XCTAssertEqual(SmartSkipDetectors.getSubtitleEvidence("不要点击链接限时优惠").categories, [],
                       "without a comma it is one negated clause")
        XCTAssertEqual(SmartSkipDetectors.getSubtitleEvidence("").categories, [])
    }
}

final class SmartSkipDanmakuDetectorTests: XCTestCase {
    private func cues(_ text: String) -> [String] {
        let reference = SmartSkipUtils.extractTimeFromText(text)!.reference
        return SmartSkipDetectors.getTimestampSkipCues(text, reference)
    }

    func testTimestampSkipCues() {
        XCTAssertEqual(cues("空降2:00 不错"), [], "any 不 negates")
        XCTAssertEqual(cues("跳过广告到03:10"), ["跳过广告"])
        XCTAssertEqual(cues("3:10广告结束"), ["广告结束"])
        XCTAssertEqual(cues("705工程"), ["工程"])
        XCTAssertEqual(cues(" 0705工程！"), ["工程"])
        XCTAssertEqual(cues("非常感谢，空降2:00"), ["空降"], "bare 非 is not a negation")
        XCTAssertEqual(cues("非赞助，空降2:00"), [])
        XCTAssertEqual(cues("03:10的空降兵很厉害"), [])
        XCTAssertEqual(cues("03:10展示传送功能"), [])
        XCTAssertEqual(cues("空降 2:00"), ["空降"])
        XCTAssertEqual(cues("2:00 跳过"), ["跳过"])
        XCTAssertEqual(cues("3:10广告结束了！"), ["广告结束"])
        XCTAssertEqual(cues("传送门→2:00"), ["传送门"])
        XCTAssertEqual(cues("指路 二分十秒"), ["指路"])
        XCTAssertEqual(cues("看看 2:00 的细节"), [])
        XCTAssertEqual(cues("705工程是辆好车"), [])
    }

    func testCueUsesFirstOccurrenceOfTheReference() {
        // reference "1:20" is found (indexOf) inside "11:205", so the cue is not adjacent.
        XCTAssertEqual(SmartSkipUtils.extractTimeFromText("11:205 空降1:20")?.reference, "1:20")
        XCTAssertEqual(cues("11:205 空降1:20"), [])
    }

    func testFindAdTimestampsWorkedExample() {
        let best = SmartSkipDetectors.findAdTimestamps([SmartSkipDanmaku(time: 100, textContent: "空降 3:30")], 600)
        XCTAssertEqual(best?.start, 105)
        XCTAssertEqual(best?.end, 210)
        XCTAssertEqual(best?.requiresConfirmation, false)
        XCTAssertEqual(best?.matchedKeywords, ["空降"])
        XCTAssertEqual(best?.reason, "explicit-danmaku-skip")
        XCTAssertEqual(best?.earlyAdEvidence, false)
        XCTAssertEqual(best?.referenceCount, 1)
        XCTAssertEqual(best?.explicitCount, 1)
        XCTAssertEqual(best?.alternativeDestinations, [])
    }

    func testFindAdTimestampsRankingAndAlternatives() {
        let best = SmartSkipDetectors.findAdTimestamps([
            SmartSkipDanmaku(time: 100, textContent: "空降 3:30"),
            SmartSkipDanmaku(time: 101, textContent: "空降 3:30"),
            SmartSkipDanmaku(time: 102, textContent: "跳过广告 3:20"),
            SmartSkipDanmaku(time: 90, textContent: "看看 4:00 恰饭"),
        ], 600)
        XCTAssertEqual(best?.end, 210)
        XCTAssertEqual(best?.explicitCount, 2)
        XCTAssertEqual(best?.alternativeDestinations, [SmartSkipAlternativeDestination(end: 200, explicitCount: 1)],
                       "bare destinations are not alternatives")
        let bare = SmartSkipDetectors.findAdTimestamps([SmartSkipDanmaku(time: 90, textContent: "看看 4:00 恰饭广告")], 600)
        XCTAssertEqual(bare?.requiresConfirmation, true)
        XCTAssertEqual(bare?.reason, "unconfirmed-time-reference")
        XCTAssertEqual(bare?.matchedKeywords, ["恰饭", "广告"])
        XCTAssertNil(SmartSkipDetectors.findAdTimestamps([], 600))
    }

    func testDirectionalKeywordClusters() {
        let segment = SmartSkipDetectors.getAdTimeByKeywords([
            SmartSkipDanmaku(time: 100, textContent: "广告开始了"), SmartSkipDanmaku(time: 105, textContent: "广告开始"),
            SmartSkipDanmaku(time: 150, textContent: "欢迎回来"), SmartSkipDanmaku(time: 155, textContent: "欢迎回来"),
        ])
        XCTAssertEqual([segment?.start, segment?.end], [100, 155])
        XCTAssertEqual(segment?.matchedKeywords, ["广告开始", "广告", "欢迎回来"])
        XCTAssertNil(segment?.requiresConfirmation, "rc is set by selectSegment")
    }

    func testGeneralKeywordSpan() {
        let danmaku = [SmartSkipDanmaku(time: 70, textContent: "下单了"), SmartSkipDanmaku(time: 90, textContent: "买了买了"),
                       SmartSkipDanmaku(time: 130, textContent: "恰饭"), SmartSkipDanmaku(time: 300, textContent: "购买")]
        let segment = SmartSkipDetectors.getAdTimeByKeywords(danmaku)
        XCTAssertEqual([segment?.start, segment?.end], [65, 130])
        XCTAssertEqual(segment?.matchedKeywords, ["下单", "买了", "恰饭"])
        XCTAssertTrue(SmartSkipDetectors.checkAdSegVaild(segment, 600))
        let primary = SmartSkipPipeline.getSkipSegment(SSFixture(danmaku: danmaku).inputs)
        XCTAssertEqual(primary?.source, "danmaku-keywords")
        XCTAssertEqual(primary?.requiresConfirmation, true)
        XCTAssertEqual(primary?.confidence, "low")
    }

    func testGeneralKeywordSpanStartingAtZeroIsNotFound() {
        XCTAssertNil(SmartSkipDetectors.getAdTimeByGeneralKeywords([0, 40]), "JS truthiness: adStart 0 is falsy")
        XCTAssertEqual(SmartSkipDetectors.getAdTimeByGeneralKeywords([1, 40])?.start, -4)
        XCTAssertNil(SmartSkipDetectors.getAdTimeByGeneralKeywords([10]))
        XCTAssertNil(SmartSkipDetectors.getAdTimeByGeneralKeywords([]))
    }

    func testFindClusterPrefersTheEarliestDensestWindow() {
        let c = SmartSkipDetectors.findCluster([5, 1, 3, 30, 31, 32], 15, 2)
        XCTAssertEqual(c?.start, 1)
        XCTAssertEqual(c?.end, 5)
        XCTAssertEqual(c?.center, 3)
        XCTAssertNil(SmartSkipDetectors.findCluster([1], 15, 2))
        XCTAssertNil(SmartSkipDetectors.findCluster([1, 100], 15, 2))
    }

    func testKeywordDictionariesAreVerbatim() {
        XCTAssertEqual(SmartSkipConstants.adStartKeywords.count, 7)
        XCTAssertEqual(SmartSkipConstants.adEndKeywords.count, 7)
        XCTAssertEqual(SmartSkipConstants.adGeneralKeywords.count, 18)
        XCTAssertEqual(SmartSkipConstants.adContentKeywords.count, 39)
        XCTAssertEqual(SmartSkipConstants.adGeneralKeywords.first, "已买")
        XCTAssertEqual(SmartSkipConstants.adGeneralKeywords.last, "有转无赞")
    }
}
