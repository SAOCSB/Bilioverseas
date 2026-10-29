// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): segment-detector.js. Upstream
// `tests/segment-detector.test.cjs` @ test-branch 24d28a8 (spec §14.6). `H` = production helpers,
// otherwise called without helpers (fallback path), exactly as upstream.

import XCTest
@testable import BiliCore

final class SmartSkipSegmentDetectorTests: XCTestCase {
    private let H = SmartSkipDetectorHelpers.production

    private static func line(_ from: Double, _ to: Double, _ content: String) -> SubtitleLine { SSFixtures.row(from, to, content) }
    private func line(_ from: Double, _ to: Double, _ content: String) -> SubtitleLine { SSFixtures.row(from, to, content) }

    static func ad(_ start: Double = 40) -> [SubtitleLine] {
        [line(start, start + 3, "本视频由测试赞助商赞助播出"),
         line(start + 3, start + 8, "这款产品采用一种不同的设计"),
         line(start + 8, start + 23, "下面解释内部工作原理和各个部件的连接方式"),
         line(start + 23, start + 28, "整个过程包括三个步骤"),
         line(start + 28, start + 33, "现在可以免费试用全部功能"),
         line(start + 33, start + 38, "点击评论区链接领取优惠券"),
         line(start + 40, start + 44, "现在回到视频")]
    }
    private func ad(_ start: Double = 40) -> [SubtitleLine] { Self.ad(start) }
    private func adWithoutReturn(_ start: Double = 40) -> [SubtitleLine] { Array(ad(start).dropLast()) }

    private func input(_ subtitles: [SubtitleLine]) -> SmartSkipInputs {
        SmartSkipInputs(bvid: "", cid: 1, duration: 500, title: "星空为什么发光", desc: "", chapters: [], danmaku: [], subtitles: subtitles)
    }
    private func dm(_ time: Double, _ text: String) -> SmartSkipDanmaku { SmartSkipDanmaku(time: time, textContent: text) }
    private func ch(_ from: Double, _ to: Double, _ title: String = "") -> VideoChapter { SSFixtures.chapter(from, to, title) }
    private func spans(_ segments: [SmartSkipSegment]) -> [[Double]] { segments.map { [$0.start, $0.end] } }

    func testSponsorBreakRetainsNeutralExplanationAndEndsBeforeTheReturnSentence() {
        let segment = SmartSkipSegmentDetector.detectSegments(input(ad()), H).first!
        XCTAssertEqual([segment.start, segment.end], [40, 78])
        XCTAssertEqual(segment.autoEligible, true)
        XCTAssertEqual(segment.requiresConfirmation, false)
        XCTAssertEqual(segment.skipDecision, "skip")
        XCTAssertEqual(segment.boundaryEvidence?.end?.kind, "explicit-return")
        XCTAssertGreaterThanOrEqual(segment.observedLineCount ?? 0, 6)
        XCTAssertEqual(segment.contentType, "ad")
        XCTAssertEqual(segment.reason, "complete-sponsor-break")
        XCTAssertEqual(segment.boundaryEvidence?.end?.returnLine?.from, 80)
        XCTAssertEqual(segment.earlyAdEvidence, true, "auto and start < 60")
    }

    func testNeutralExplanationMayExceedTwentySecondsWithoutFragmenting() {
        let rows = [line(50, 53, "这个视频由某服务赞助"), line(53, 80, "接下来解释学习时知识怎样被组织起来"),
                    line(80, 112, "你可以按顺序练习并观察每一步的反馈"), line(112, 118, "可免费体验全部功能"),
                    line(118, 126, "使用下方链接获取专属优惠"), line(128, 132, "现在回到视频")]
        let segment = SmartSkipSegmentDetector.detectSegments(input(rows)).first!
        XCTAssertEqual([segment.start, segment.end], [50, 126])
        XCTAssertEqual(segment.autoEligible, true)
    }

    func testIndependentCommercialChapterRecoversSetupBeforeSponsorship() {
        var record = input([line(100, 120, "为什么会产生这个问题呢")] + ad(150))
        record.chapters = [ch(0, 100, "星空"), ch(100, 190, "🙂"), ch(190, 500, "正文")]
        let segment = SmartSkipSegmentDetector.detectSegments(record, H).first!
        XCTAssertEqual([segment.start, segment.end], [100, 190])
        XCTAssertEqual(segment.autoEligible, true)
        XCTAssertEqual(segment.boundaryEvidence?.start?.kind, "chapter-start")
        XCTAssertEqual(segment.sources, ["subtitles", "chapters"])
    }

    func testChapterWithCommercialChainAndNoSponsorRemainsAFullManualProposal() {
        var record = input([line(100, 120, "先介绍一个问题"), line(160, 165, "这款产品享有专属优惠"), line(178, 184, "点击评论区链接领取优惠券")])
        record.chapters = [ch(0, 100), ch(100, 190, "🙂"), ch(190, 500)]
        let segment = SmartSkipSegmentDetector.detectSegments(record, H).first!
        XCTAssertEqual([segment.start, segment.end], [100, 190])
        XCTAssertEqual(segment.requiresConfirmation, true)
        XCTAssertEqual(segment.autoEligible, false)
        XCTAssertEqual(segment.reviewReasons, ["commercial-chapter-without-explicit-sponsor-start"])
    }

    func testExplicitLocalTimeDestinationSupportsASponsorEnding() {
        var record = input(adWithoutReturn())
        record.danmaku = [dm(42, "120工程")]
        let segment = SmartSkipSegmentDetector.detectSegments(record, H).first!
        XCTAssertEqual([segment.start, segment.end], [40, 80])
        XCTAssertEqual(segment.autoEligible, true)
        XCTAssertEqual(segment.boundaryEvidence?.end?.kind, "explicit-danmaku-end")
        XCTAssertEqual(segment.sources, ["subtitles", "danmaku-time"])
    }

    func testConflictingTimestampDestinationsAreExposedAndCannotAuthorizeFusion() {
        var record = input(adWithoutReturn())
        record.danmaku = [dm(42, "120工程"), dm(44, "200工程")]
        let segment = SmartSkipSegmentDetector.detectSegments(record, H).first!
        XCTAssertEqual(segment.requiresConfirmation, true)
        XCTAssertTrue(segment.reviewReasons?.contains("conflicting-time-destinations") ?? false)
        XCTAssertEqual(segment.boundaryEvidence?.alternativeEnds?.map(\.end), [120])
    }

    func testDecoratedIsolatedInstructionsAreSupportedWithoutStrippingNarrativeOrNegation() {
        for text in ["░░120工程░░", "120工程"] {
            var record = input(adWithoutReturn())
            record.danmaku = [dm(42, text)]
            XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record, H).first?.autoEligible, true, text)
        }
        for text in ["░120工程是辆好车░", "不要空降1:20", "他说1:20是开始", "1:20"] {
            var record = input(adWithoutReturn())
            record.danmaku = [dm(42, text)]
            XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record, H).first?.autoEligible, false, text)
        }
        XCTAssertEqual(SmartSkipSegmentDetector.cleanInstruction(" ★☆跳过广告 2:00☆★ "), "跳过广告 2:00")
    }

    func testTwoSponsorBreaksSeparatedByNormalContentRemainSeparate() {
        let segments = SmartSkipSegmentDetector.detectSegments(input(ad(40) + [line(88, 120, "普通的天文知识解释")] + ad(150)))
        XCTAssertEqual(spans(segments), [[40, 78], [150, 188]])
        XCTAssertTrue(segments.allSatisfy { $0.autoEligible == true })
    }

    func testSingleOpeningSponsorshipStatementIsKeptAndCannotConnectToALaterAd() {
        let segments = SmartSkipSegmentDetector.detectSegments(input([line(0.08, 2.4, "本视频由测试品牌赞助"),
            line(3, 18, "下面介绍链表的数据结构"), line(18, 35, "我们首先讨论内存的组织方式")] + ad(150)))
        XCTAssertEqual(spans(segments), [[0.08, 2.4], [150, 188]])
        XCTAssertEqual(segments.map(\.skipDecision), ["keep", "skip"])
        XCTAssertEqual(segments[0].autoEligible, false)
        XCTAssertEqual(segments[1].autoEligible, true)
        XCTAssertEqual(segments[0].reviewReasons, ["single-statement-without-promotional-continuation"])
    }

    func testProductThemedContentAndCourseIntroductionsDoNotBecomeAutomaticAds() {
        var themed = input(adWithoutReturn())
        themed.title = "新产品开箱试吃"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(themed).first?.skipDecision, "keep")
        var course = input([line(0, 4, "本课程的第一课将介绍教学目标")] + ad(40))
        course.title = "编程课程入门"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(course).first?.autoEligible, true,
                       "a separate explicitly bounded sponsor break can occur inside a tutorial")
        course.subtitles = [line(0, 5, "本课程介绍学习方法"), line(5, 15, "免费搜索教程和购买教材")]
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(course), [])
    }

    func testOrdinaryPurchaseFreeSearchTeachingLinkAndAdDiscussionInventNoBreak() {
        for content in ["免费搜索教程，推荐给大家", "点击链接查看免费教程", "他购买香肠之后回到家里",
                        "他说本视频由某商家赞助", "“本视频由某商家赞助”是常见的广告词", "本视频没有商家赞助"] {
            let rows = [line(40, 45, content), line(45, 50, "今天价格只要100元"), line(50, 55, "现在回到视频")]
            XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(input(rows)), [], content)
        }
    }

    func testGratitudeWithoutExplicitSponsorIdentityIsManual() {
        var rows = ad()
        rows[0].content = "感谢一下某商家的催更"
        let segment = SmartSkipSegmentDetector.detectSegments(input(rows)).first!
        XCTAssertEqual(segment.requiresConfirmation, true)
        XCTAssertTrue(segment.reviewReasons?.contains("weak-sponsor-identity") ?? false)
    }

    func testSubtitleWrappingRepairsSponsorWordingWithoutAbsorbingThePreviousSentence() {
        var rows = ad()
        rows.replaceSubrange(0..<1, with: [line(37, 40, "刚才讲的是星球"), line(40, 41, "本视频由某商家"), line(41, 43, "赞助播出")])
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(input(rows)).first?.start, 40)
        let negative = input([line(39, 40, "没有"), line(40, 43, "本视频由商家赞助")] + ad().dropFirst())
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(negative), [])
    }

    func testPostOfferWeakTransitionsCloseAFullManualRange() {
        var rows = ad()
        rows[rows.count - 1].content = "让我们从夏季常遇到的问题开始"
        let segment = SmartSkipSegmentDetector.detectSegments(input(rows)).first!
        XCTAssertEqual([segment.start, segment.end], [40, 78])
        XCTAssertEqual(segment.autoEligible, false)
        XCTAssertEqual(segment.boundaryEvidence?.end?.kind, "post-offer-transition")
    }

    func testSearchDurationIsAConfidenceBoundNotAnAutomaticCrop() {
        let rows = [line(40, 43, "本视频由商家赞助"), line(60, 100, "这款产品工作原理"),
                    line(150, 180, "可免费试用"), line(320, 330, "点击评论区领优惠券"), line(400, 410, "现在回到视频")]
        XCTAssertTrue(SmartSkipSegmentDetector.detectSegments(input(rows)).allSatisfy { $0.autoEligible != true })
    }

    func testEveryExplicitAdChapterIsReturnedEvenWithNoSubtitleTrack() {
        var record = input([])
        record.chapters = [ch(0, 50, "开场"), ch(50, 80, "广告"), ch(80, 180, "正文"), ch(180, 220, "赞助环节"), ch(220, 500, "正文")]
        let segments = SmartSkipSegmentDetector.detectSegments(record, H)
        XCTAssertEqual(spans(segments), [[50, 80], [180, 220]])
        XCTAssertEqual(segments.map(\.autoEligible), [true, true])
        XCTAssertEqual(segments.map(\.reason), ["explicit-ad-chapter", "explicit-ad-chapter"])
        XCTAssertEqual(segments.first?.matchedKeywords, ["广告"])
        // no-helper fallback recognises the same plain labels
        XCTAssertEqual(spans(SmartSkipSegmentDetector.detectSegments(record)), [[50, 80], [180, 220]])
    }

    func testShortExplicitAdChapterNeedsReviewAndHasNoOpeningGuard() {
        var record = input([])
        record.chapters = [ch(0, 5, "广告"), ch(5, 500, "正文")]
        let segment = SmartSkipSegmentDetector.detectSegments(record, H).first!
        XCTAssertEqual([segment.start, segment.end], [0, 5])
        XCTAssertEqual(segment.autoEligible, false)
        XCTAssertEqual(segment.reviewReasons, ["chapter-duration-needs-review"])
    }

    func testInvalidInputOverlappingChapterEnvelopesAndDuplicateRows() {
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(nil), [])
        var nanDuration = input([])
        nanDuration.duration = .nan
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(nanDuration), [])
        let record = input(ad() + ad() + [line(.nan, 80, "本视频由商家赞助")])
        let before = record.subtitles
        let result = SmartSkipSegmentDetector.detectSegments(record)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.observedLineCount, 6)
        XCTAssertEqual(record.subtitles.count, before.count)
        var overlapping = input([line(130, 134, "点击评论区领优惠券"), line(140, 145, "专属优惠")])
        overlapping.chapters = [ch(0, 120), ch(100, 150), ch(150, 500)]
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(overlapping), [])
    }

    func testSingleCompleteOfferCTACanSupportAWholeManualChapterButNeverAuto() {
        var record = input([line(100, 120, "先铺垫一个问题"), line(178, 184, "点击评论区领优惠券")])
        record.chapters = [ch(0, 100), ch(100, 190), ch(190, 500)]
        let segment = SmartSkipSegmentDetector.detectSegments(record).first!
        XCTAssertEqual([segment.start, segment.end], [100, 190])
        XCTAssertEqual(segment.autoEligible, false)
    }

    func testCommercialGratitudeNeedsTransactionsAndASeparateExplicitTimestamp() {
        var rows = adWithoutReturn()
        rows[0].content = "感谢某商家的催更"
        rows[1].content = "这个产品到手价只要100元"
        var record = input(rows)
        record.danmaku = [dm(42, "120工程")]
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, true)
        record.subtitles[0].content = "感谢观众的催更"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record), [], "ordinary viewer gratitude is not sponsor identity")
    }

    func testInstructionEndingDuringALaterOfferCannotShortenItOrBecomeAutomatic() {
        var rows = adWithoutReturn()
        rows[1].content = "这个产品到手价只要100元"
        rows[2].content = "平台提供专属优惠"
        var record = input(rows)
        record.danmaku = [dm(42, "110工程")]
        let segment = SmartSkipSegmentDetector.detectSegments(record).first!
        XCTAssertEqual(segment.end, 78)
        XCTAssertEqual(segment.autoEligible, false)
        XCTAssertTrue(segment.reviewReasons?.contains("commercial-content-after-time-destination") ?? false)
        XCTAssertEqual(segment.boundaryEvidence?.end?.kind, "commercial-continuation-after-timestamp")
    }

    func testTimestampNearAClosingBoundaryDoesNotConsumeTheNextSentence() {
        var record = input(adWithoutReturn() + [line(78, 79, "好就是这样"), line(79, 84, "接着讲星球的组成")])
        record.danmaku = [dm(42, "120工程")]
        let segment = SmartSkipSegmentDetector.detectSegments(record).first!
        XCTAssertEqual(segment.end, 79)
        XCTAssertEqual(segment.boundaryEvidence?.timeReferences?.first?.end, 80)
        XCTAssertEqual(segment.autoEligible, true)
    }

    func testMiddleChapterNeedsRelationshipCompleteCTAAndDistinctReactionsForAuto() {
        var record = input([line(100, 120, "先铺垫这个问题"), line(145, 150, "我们合作4年了"),
                            line(160, 166, "这款产品有很多功能"), line(178, 184, "点击评论区领优惠券")])
        record.chapters = [ch(0, 100), ch(100, 190), ch(190, 500)]
        record.danmaku = [dm(140, "感谢甲方爸爸"), dm(142, "甲方这文案真有意思")]
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, true)
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.boundaryEvidence?.commercialReactions?.count, 2)
        record.danmaku[1].textContent = "感谢甲方爸爸"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, false, "duplicate wording is not independent corroboration")
        record.danmaku[1].textContent = "不是甲方这文案"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, false)
        record.danmaku[1].textContent = "甲方这文案真有意思"
        record.title = "新产品开箱评测"
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, false,
                       "a main product-review chapter needs further evidence of an insertion")
    }

    func testLaterSponsorAndItsReturnCannotAuthorizeAnUnresolvedEarlierSponsor() {
        var record = input([line(100, 103, "本视频由某商家赞助"), line(103, 110, "这款产品可免费试用"),
                            line(110, 118, "点击评论区领取优惠券"), line(118, 180, "这里已经回到普通天文学原理的连续解释")] + ad(200))
        let segments = SmartSkipSegmentDetector.detectSegments(record)
        XCTAssertEqual(spans(segments), [[100, 118], [200, 238]])
        XCTAssertEqual(segments.map(\.autoEligible), [false, true])
        XCTAssertEqual(segments[0].boundaryEvidence?.end?.kind, "unresolved-before-next-sponsor")
        record.danmaku = [dm(102, "400工程")]
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(record).first?.autoEligible, false,
                       "a timestamp cannot bridge another sponsor start either")
    }

    func testOpeningCreditFollowedByMaterialPriceCannotInheritALaterChain() {
        let record = input([line(0.08, 2.4, "本视频由某品牌赞助"), line(3, 18, "最初实验的材料价格是100元"),
                            line(18, 60, "我们首先讨论实验的科学原理"), line(60, 140, "接下来分析实验数据并重建整个过程")] + ad(150))
        let segments = SmartSkipSegmentDetector.detectSegments(record)
        XCTAssertEqual(spans(segments), [[0.08, 2.4], [150, 188]])
        XCTAssertEqual(segments.map(\.skipDecision), ["keep", "skip"])
        XCTAssertTrue(segments.filter { $0.autoEligible == true }.allSatisfy { $0.start >= 150 })
    }

    func testEarlierWeakReturnEndsItsOwnManualBreak() {
        let record = input([line(40, 43, "本视频由某品牌赞助"), line(43, 50, "可免费试用全部功能"),
                            line(50, 58, "点击评论区链接领取优惠券"), line(58, 64, "让我们从夏季常遇到的问题开始"),
                            line(64, 140, "普通电动气泵拆机")] + ad(150))
        let segments = SmartSkipSegmentDetector.detectSegments(record)
        XCTAssertEqual(spans(segments), [[40, 58], [150, 188]])
        XCTAssertEqual(segments.map(\.autoEligible), [false, true])
    }

    func testLegitimateEarlySponsorBreakCanRetainNeutralProductExplanation() {
        let record = input([line(0.08, 2.4, "本视频由某品牌赞助"), line(3, 20, "这款产品的内部设计包括三个部分"),
                            line(20, 50, "各个部件通过反馈调节整个过程"), line(50, 56, "可免费试用全部功能"),
                            line(56, 63, "点击评论区领优惠券"), line(64, 68, "现在回到视频")])
        let segment = SmartSkipSegmentDetector.detectSegments(record).first!
        XCTAssertEqual([segment.start, segment.end], [0.08, 63])
        XCTAssertEqual(segment.autoEligible, true)
    }

    func testAdvertisingExampleIntroducedInAPrecedingSubtitleIsNotASponsorship() {
        XCTAssertEqual(SmartSkipSegmentDetector.detectSegments(input([line(35, 40, "下面是广告词的一种示例：")] + ad(40))), [])
    }

    func testHelpersAndFallbackClassifyTheSameAdBreak() {
        XCTAssertEqual(spans(SmartSkipSegmentDetector.detectSegments(input(ad()), H)),
                       spans(SmartSkipSegmentDetector.detectSegments(input(ad()))))
    }

    func testChapterRangesExcludeFirstLastAndOversizedChapters() {
        let ranges = SmartSkipSegmentDetector.chapterRanges([ch(0, 50, "a"), ch(50, 400, "too long"), ch(400, 420, "b"), ch(420, 500, "c")], 500)
        XCTAssertEqual(ranges.map(\.title), ["b"])
        XCTAssertEqual(SmartSkipSegmentDetector.chapterRanges([ch(0, 50), ch(40, 60), ch(60, 500)], 500), [], "any overlap → no envelopes")
    }
}
