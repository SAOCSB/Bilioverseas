// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): content.js pipeline end to end
// (`getSkipSegment` + tracker, `getSkipSegments`, `combineSkipSegments`). Upstream cases from
// test-branch 24d28a8: `regression`, `early-timestamp`, `label-confidence`, `issue14-real`,
// `multiple-segments`. Log-only assertions are replaced by assertions on the returned values.

import XCTest
@testable import BiliCore

private typealias F = SSFixtures

final class SmartSkipRegressionTests: XCTestCase {
    func testRealSubtitleHistoryPurchaseDoesNotExtendTheAd() {
        let subtitles = [
            F.row(197.96, 200.58, "加上现在得物准备的超高新客福利"),
            F.row(200.58, 203.62, "注册就能领最高520元无门槛优惠券"),
            F.row(231.96, 232.8, "全场包邮"),
            F.row(232.8, 234.4, "快来点击置顶评论区链接"),
            F.row(234.4, 235.18, "直接领券"),
            F.row(244.96, 246.74, "快来点击置顶评论区链接吧"),
            F.row(297.18, 300.32, "鼓动观众趁热购买自家的腊肠犬香肠"),
        ]
        let (candidate, h) = SSHarness.detectAndAttach(SSFixture(subtitles: subtitles))
        XCTAssertNotNil(candidate)
        XCTAssertLessThan(candidate!.end, 252.42, "candidate must end before the historical narrative resumes")
        XCTAssertEqual(candidate?.requiresConfirmation, true)
        h.tick(candidate!.start)
        XCTAssertSeeks(h, [])

        let (segment, crossChecked) = SSHarness.detectAndAttach(SSFixture(subtitles: subtitles, danmaku: [F.timestamp("空降 4:12", 183.811)]))
        XCTAssertEqual(segment?.source, "danmaku-time")
        XCTAssertEqual(segment?.end, 252)
        crossChecked.tick(segment!.start)
        XCTAssertSeeks(crossChecked, [252.05])
    }

    func testRealShortParachuteInstructionsAreNotDroppedByThe30SecondGate() {
        for (bvid, time, text, end) in [("BV1yMQrBSE5H", 137.001, "跳伞02：36", 156.0), ("BV1H8iCBEEGG", 128.111, "跳伞2:28", 148.0)] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(text, time)]))
            XCTAssertNotNil(segment, bvid)
            XCTAssertEqual(segment?.requiresConfirmation, false, bvid)
            h.tick(time + 5)
            XCTAssertSeeks(h, [end + 0.05], bvid)
        }
    }

    func testShortTimelineRelaxationOnlyForExplicitInstructionsAndStill10Seconds() {
        for (time, text) in [(137.001, "看看02：36"), (142.0, "跳伞02：36")] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(text, time)]))
            XCTAssertNil(segment, text)
            h.tick(time + 5)
            XCTAssertSeeks(h, [], text)
        }
    }

    func testWeakSubtitlesAt79SecondsWithoutDanmakuNeverSeek() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.weakSubtitles))
        XCTAssertNil(segment, "ordinary 免费/搜索 no longer produce an ad candidate")
        h.tick(79)
        h.advance(10)
        XCTAssertSeeks(h, [])
    }

    func testObviousAdSubtitlesKeepACandidateThatOnlyAClickSkips() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.strongSubtitles))
        XCTAssertEqual(segment?.source, "subtitles")
        XCTAssertEqual(segment?.requiresConfirmation, true)
        XCTAssertEqual([segment?.start, segment?.end], [79, 103])
        h.tick(segment!.start)
        XCTAssertSeeks(h, [])
        XCTAssertTrue(h.buttonIsSuspicious)
        h.click()
        XCTAssertSeeks(h, [segment!.end + 0.05])
        XCTAssertEqual(h.autoSkips, [], "trigger is manual")
    }

    func testOrdinaryTutorialLinkNoLongerGuessesAnAdStart() {
        var subtitles = F.transcript("点击链接查看免费教程", "搜索资料", start: 139, gap: 161)
        subtitles[2].to = 142
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: subtitles))
        XCTAssertNil(segment)
        h.tick(82)
        XCTAssertSeeks(h, [])
    }

    func testSubtitleTrustIsPerSegmentNotGlobalState() {
        // Upstream forces the legacy global `isSuspiciousAd = false`; Swift has no such global —
        // trust is a property of the segment.
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.strongSubtitles))
        XCTAssertNotNil(segment)
        h.tick(segment!.start)
        XCTAssertSeeks(h, [])
    }

    func testExplicitDanmakuTimelineBeatsWeakSubtitlesAndUsesTheUserEnd() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.weakSubtitles, danmaku: [F.timestamp()]))
        XCTAssertEqual(segment?.source, "danmaku-time")
        XCTAssertEqual(segment?.confidence, "high")
        XCTAssertEqual(segment?.requiresConfirmation, false)
        XCTAssertEqual(segment?.end, 120)
        h.tick(79)
        XCTAssertSeeks(h, [120.05])
        XCTAssertEqual(h.autoSkips.map(\.source), ["danmaku-time"], "trigger is auto")
    }

    func testIsolatedOrdinaryTimeReferenceIsManualOnly() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp("看看 2:00 的细节")]))
        XCTAssertEqual(segment?.source, "danmaku-time")
        XCTAssertEqual(segment?.requiresConfirmation, true)
        h.tick(79)
        XCTAssertSeeks(h, [])
    }

    func testWeakTimelineConflictingWithSubtitlesIsNotMerged() {
        let fixture = SSFixture(subtitles: F.strongSubtitles, danmaku: [F.timestamp("看看 5:00", 235)])
        let (segment, h) = SSHarness.detectAndAttach(fixture)
        XCTAssertEqual(segment?.start, 240)
        XCTAssertEqual(segment?.end, 300)
        XCTAssertEqual(segment?.requiresConfirmation, true)
        h.tick(79)
        h.tick(240)
        XCTAssertSeeks(h, [])
        // cross-check diagnostics
        let timestamp = SmartSkipDetectors.findAdTimestamps(fixture.danmaku, 600)!
        let subtitles = SmartSkipDetectors.detectFromSubtitles(fixture.subtitles)!
        XCTAssertFalse(max(timestamp.start, subtitles.start) < min(timestamp.end, subtitles.end))
        XCTAssertGreaterThan(abs(timestamp.end - subtitles.end), 150)
    }

    func testRepeatedBareTimeReferencesAreNotIndependentVotes() {
        let danmaku = (0..<12).map { F.timestamp("2:00", 70 + Double($0)) }
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: danmaku))
        XCTAssertEqual(segment?.requiresConfirmation, true)
        h.tick(79)
        XCTAssertSeeks(h, [])
    }

    func testCommercialSubtitlesOverlappingAnOrdinaryReferenceStayManual() {
        let fixture = SSFixture(subtitles: F.strongSubtitles, danmaku: [F.timestamp("看看 1:43", 70)])
        let (segment, h) = SSHarness.detectAndAttach(fixture)
        XCTAssertEqual(segment?.requiresConfirmation, true)
        h.tick(79)
        XCTAssertSeeks(h, [])
        let timestamp = SmartSkipDetectors.findAdTimestamps(fixture.danmaku, 600)!
        let subtitles = SmartSkipDetectors.detectFromSubtitles(fixture.subtitles)!
        XCTAssertTrue(max(timestamp.start, subtitles.start) < min(timestamp.end, subtitles.end), "cross-check overlap")
    }

    func testNegatedSkipInstructionNeverAutoSkips() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp("不要跳过 2:00")]))
        XCTAssertEqual(segment?.requiresConfirmation, true)
        h.tick(79)
        XCTAssertSeeks(h, [])
    }

    func testOrdinaryDescriptionsOrNegatedInstructionsStayManual() {
        for text in ["03:10展示传送功能", "03:10的空降兵很厉害", "不要直接空降03:10", "03:10不是广告结束"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(text)]))
            XCTAssertEqual(segment?.source, "danmaku-time", text)
            XCTAssertEqual(segment?.start, 79, text)
            XCTAssertEqual(segment?.end, 190, text)
            XCTAssertEqual(segment?.requiresConfirmation, true, text)
            h.tick(79)
            XCTAssertSeeks(h, [], text)
            XCTAssertTrue(h.buttonIsSuspicious, text)
        }
    }

    func testAdjacentExplicitInstructionsStillAutoSkip() {
        for text in ["空降03:10", "跳过广告到03:10", "3:10广告结束"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(text)]))
            XCTAssertEqual(segment?.source, "danmaku-time", text)
            XCTAssertEqual(segment?.start, 79, text)
            XCTAssertEqual(segment?.end, 190, text)
            XCTAssertEqual(segment?.requiresConfirmation, false, text)
            h.tick(74)
            XCTAssertSeeks(h, [], text)
            h.tick(79)
            XCTAssertSeeks(h, [190.05], text)
        }
    }

    func testOrdinaryReferenceCannotExtendTheReliableStartBackwards() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp("看看 2:30", 60), F.timestamp("跳过广告 2:30", 95)]))
        XCTAssertEqual(segment?.start, 100)
        h.tick(79)
        XCTAssertSeeks(h, [])
        h.tick(100)
        XCTAssertSeeks(h, [150.05])
    }

    func testManyOrdinaryReferencesDoNotOutvoteAnExplicitInstruction() {
        let danmaku = (0..<12).map { F.timestamp("看看 2:00", 70 + Double($0)) } + [F.timestamp("跳过广告 3:00", 100)]
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: danmaku))
        XCTAssertEqual(segment?.end, 180)
        XCTAssertEqual(segment?.requiresConfirmation, false)
        h.tick(105)
        XCTAssertSeeks(h, [180.05])
    }

    func testInvalidTimesAndIntervalsNeverSeek() {
        for danmaku in [
            [F.timestamp("跳过广告 2:99")],
            [F.timestamp("跳过广告 2:00", .nan)],
            [F.timestamp("跳过广告 2:00", .infinity)],
            [F.timestamp("空降 2:00", 20)],
            [F.timestamp("跳过广告 10:00", 500)],
            [F.timestamp("跳过广告 9:50", 500)],
        ] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: danmaku))
            XCTAssertNil(segment, danmaku[0].textContent)
            h.tick(79)
            h.tick(505)
            XCTAssertSeeks(h, [])
        }
    }

    func testNoSubtitlesAndNoDanmakuDetectsNothing() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture())
        XCTAssertNil(segment)
        h.tick(79)
        XCTAssertSeeks(h, [])
        XCTAssertEqual(SmartSkipPipeline.getSkipSegments(SSFixture().inputs), [])
    }

    func testExplicitDanmakuTimelineWorksWithoutSubtitles() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp()]))
        XCTAssertNotNil(segment)
        h.tick(79)
        XCTAssertSeeks(h, [120.05])
    }

    func testChaptersBeatDescriptionDanmakuAndSubtitles() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(
            desc: "1:10 广告\n2:20 正片", chapters: [F.chapter(70, 135, "广告")],
            subtitles: F.strongSubtitles, danmaku: [F.timestamp()]))
        XCTAssertEqual(segment?.source, "chapters")
        XCTAssertEqual(segment?.requiresConfirmation, false)
        XCTAssertEqual(segment?.end, 135)
        h.tick(79)
        XCTAssertSeeks(h, [135.05])
    }

    func testDescriptionBeatsDanmakuAndSubtitles() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(desc: "1:10 广告\n2:20 正片", subtitles: F.strongSubtitles, danmaku: [F.timestamp()]))
        XCTAssertEqual(segment?.source, "description")
        XCTAssertEqual(segment?.end, 140)
        h.tick(79)
        XCTAssertSeeks(h, [140.05])
    }

    func testManualToAutoStartsSkippingATrustedTimeline() {
        let (_, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp()]), mode: .manual)
        h.tick(79)
        XCTAssertSeeks(h, [])
        XCTAssertTrue(h.buttonVisible)
        h.setMode(.auto)
        h.tick(80)
        XCTAssertSeeks(h, [120.05])
    }

    func testAutoToManualWaitsForTheClick() {
        let (_, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp()]))
        h.setMode(.manual)
        h.tick(79)
        XCTAssertSeeks(h, [])
        h.click()
        XCTAssertSeeks(h, [120.05])
    }

    func testManualToAutoNeverUpgradesSubtitles() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.strongSubtitles), mode: .manual)
        h.tick(segment!.start)
        h.setMode(.auto)
        h.tick(segment!.start + 1)
        XCTAssertSeeks(h, [])
    }

    func testReentrantTimeUpdatesAndSeekingBackSkipOnlyOnce() {
        let (_, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp()]))
        h.tick(79)
        h.tick(80)            // seek completion is deliberately delayed
        h.seeked()
        h.advance(2)
        h.tick(79)            // the user seeks backwards into the segment
        XCTAssertSeeks(h, [120.05])
        XCTAssertTrue(h.buttonVisible, "re-entering a skipped segment offers the manual button")
    }

    func testSuspiciousCountdownExpiryNeverSeeks() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.strongSubtitles))
        h.tick(segment!.start)
        XCTAssertTrue(h.buttonVisible)
        h.advance(10)
        XCTAssertSeeks(h, [])
        XCTAssertFalse(h.buttonVisible)
    }

    func testFullPipelineManualClickSeeksOnce() {
        let (segments, h) = SSHarness.detectAllAndAttach(SSFixture(subtitles: F.strongSubtitles, danmaku: [F.timestamp("看看 1:43", 70)]))
        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments.map(\.start), [75])
        h.tick(segments[0].start)
        h.click()
        XCTAssertEqual(h.seeks.count, 1)
    }

    func testDetectionCarriesSourceConfidenceAndKeywords() {
        let inputs = SSFixture(subtitles: F.strongSubtitles).inputs
        XCTAssertEqual(inputs.bvid, "BV_fixture")
        XCTAssertEqual(inputs.cid, 14)
        let detail = SmartSkipPipeline.getSkipSegment(inputs)
        XCTAssertEqual(detail?.source, "subtitles")
        XCTAssertEqual(detail?.confidence, "low")
        XCTAssertEqual(detail?.requiresConfirmation, true)
        XCTAssertTrue(detail?.matchedKeywords.contains { $0.contains("优惠券") } ?? false)
        XCTAssertTrue(detail?.evidenceCategories?.contains("offer") ?? false)
    }

    func testStrongSubtitlesThroughTheFullPipelineKeepThePrimary() {
        let segments = SmartSkipPipeline.getSkipSegments(SSFixture(subtitles: F.strongSubtitles).inputs)
        XCTAssertEqual(segments.map { [$0.start, $0.end] }, [[79, 103]])
        XCTAssertEqual(segments.first?.source, "subtitles")
        let proposals = SmartSkipSegmentDetector.detectSegments(SSFixture(subtitles: F.strongSubtitles).inputs, .production)
        XCTAssertEqual(proposals.map { [$0.start, $0.end] }, [[79, 83]])
        XCTAssertEqual(proposals.first?.boundaryEvidence?.end?.kind, "last-observed-commercial-line")
    }

    func testSyntheticMatrixBroadSubtitlesNeverAutoSkip() {
        let phrases = ["这个工具是免费的", "搜索这段文字", "推荐给大家学习", "点击这个菜单", "下载示例文件"]
        var scenarios = 0
        for first in phrases {
            for second in phrases {
                for start in [79.0, 210.0] {
                    for gap in [12.0, 60.0, 121.0] {
                        let (_, h) = SSHarness.detectAndAttach(SSFixture(subtitles: F.transcript(first, second, start: start, gap: gap)))
                        h.tick(start)
                        h.tick(start + gap)
                        h.advance(10)
                        XCTAssertSeeks(h, [], "\(first) / \(second), start=\(start), gap=\(gap)")
                        let full = SSHarness(SmartSkipPipeline.getSkipSegments(SSFixture(subtitles: F.transcript(first, second, start: start, gap: gap)).inputs))
                        full.tick(start)
                        full.tick(start + gap)
                        XCTAssertSeeks(full, [], "full pipeline: \(first) / \(second), start=\(start), gap=\(gap)")
                        scenarios += 1
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 150)
    }

    func testSyntheticMatrixExplicitIntentsKeepCommonTimeFormats() {
        var scenarios = 0
        for intent in ["跳过广告", "空降", "跳伞", "指路", "传送", "正片开始"] {
            for (time, end) in [("2:00", 120.0), ("2：00", 120), ("2;00", 120), ("2；00", 120), ("二分十秒", 130), ("2分0秒", 120)] {
                let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp("\(intent) \(time)")]))
                XCTAssertEqual(segment?.requiresConfirmation, false, "\(intent) \(time)")
                h.tick(79)
                XCTAssertSeeks(h, [end + 0.05], "\(intent) \(time)")
                scenarios += 1
            }
        }
        for time in ["200工程", "0200工程"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(time)]))
            XCTAssertNotNil(segment, time)
            h.tick(79)
            XCTAssertSeeks(h, [120.05], time)
            scenarios += 1
        }
        XCTAssertEqual(scenarios, 38)
    }
}

final class SmartSkipEarlyTimestampTests: XCTestCase {
    func testRealEarlyAdvertisementSurvivesTheOpeningGuard() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(duration: 291, danmaku: [F.timestamp("恭喜接广！跳伞01:32", 34.751)]))
        XCTAssertEqual(segment!.start, 39.751, accuracy: 1e-9)
        XCTAssertEqual(segment?.end, 92)
        XCTAssertEqual(segment?.earlyAdEvidence, true)
        h.tick(34.751)
        XCTAssertSeeks(h, [])
        h.tick(segment!.start)
        XCTAssertSeeks(h, [92.05])
    }

    func testOpeningGuardStillAppliesToGeneralJumpsBareTimesAndNegatedAds() {
        for text in ["空降1:32", "1:32", "不是广告，跳伞1:32", "不要跳过广告1:32", "非恰饭，空降1:32", "非赞助，空降1:32", "广告里讲的游戏，空降01:32看操作"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp(text, 34.751)]))
            XCTAssertNil(segment, text)
            h.tick(40)
            XCTAssertSeeks(h, [], text)
        }
    }

    func testExplicitEarlyAdStillRejectsMalformedOversizedAndEndOfVideoIntervals() {
        for (time, text) in [(-2.0, "跳过广告1:32"), (20, "跳过广告9:00"), (20, "跳过广告0:30"), (20, "跳过广告9:50")] {
            XCTAssertNil(SmartSkipPipeline.getSkipSegment(SSFixture(danmaku: [F.timestamp(text, time)]).inputs), text)
        }
    }
}

final class SmartSkipLabelConfidencePipelineTests: XCTestCase {
    func testEnglishSubstringsAndNegatedChapterLabelsDoNotIdentifyAds() {
        for label in ["Download", "Shader tutorial", "Adapter", "无广告", "不是广告", "非广告", "没有赞助", "No ads", "without sponsorship", "Ad-free tutorial"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(chapters: [F.chapter(70, 130, label)]))
            XCTAssertNil(segment, label)
            h.tick(80)
            XCTAssertSeeks(h, [], label)
        }
    }

    func testChapterDiscussingAdvertisingRequiresConfirmation() {
        for label in ["广告识别算法", "广告的发展历史", "广告：为什么越来越多", "广告（识别教程）", "Ad detection", "sponsor marketing history"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(chapters: [F.chapter(70, 130, label)]))
            XCTAssertEqual(segment?.requiresConfirmation, true, label)
            h.tick(80)
            XCTAssertSeeks(h, [], label)
        }
    }

    func testExplicitAdChapterLabelsPermitAutomaticSkips() {
        for label in ["广告", "广告时间：某产品", "恰饭环节", "某产品（广告）", "Ad", "Sponsored segment: product"] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(chapters: [F.chapter(70, 130, label)]))
            XCTAssertEqual(segment?.requiresConfirmation, false, label)
            h.tick(80)
            XCTAssertSeeks(h, [130.05], label)
        }
    }

    func testUncertainChapterDoesNotMaskALaterExplicitChapterOrDanmakuDestination() {
        for fixture in [
            SSFixture(chapters: [F.chapter(70, 130, "广告历史"), F.chapter(200, 250, "恰饭")]),
            SSFixture(chapters: [F.chapter(70, 130, "广告历史")], danmaku: [F.timestamp("跳过广告 4:10", 195)]),
        ] {
            let (segment, h) = SSHarness.detectAndAttach(fixture)
            XCTAssertEqual(segment?.start, 200)
            XCTAssertEqual(segment?.end, 250)
            h.tick(80)
            XCTAssertSeeks(h, [])
            h.tick(205)
            XCTAssertSeeks(h, [250.05])
        }
    }

    func testDescriptionTimestampsShareTheLabelPolicy() {
        for (label, expected) in [("Download", nil), ("无广告", nil), ("广告历史", true), ("广告", false)] as [(String, Bool?)] {
            let (segment, h) = SSHarness.detectAndAttach(SSFixture(desc: "1:10 \(label)\n2:20 正片"))
            if let expected { XCTAssertEqual(segment?.requiresConfirmation, expected, label) } else { XCTAssertNil(segment, label) }
            h.tick(80)
            XCTAssertEqual(h.seeks.count, expected == false ? 1 : 0, label)
        }
    }

    func testVeryThankfulDoesNotNegateAValidInstruction() {
        let (segment, h) = SSHarness.detectAndAttach(SSFixture(danmaku: [F.timestamp("非常感谢，空降2:00")]))
        XCTAssertEqual(segment?.requiresConfirmation, false)
        h.tick(80)
        XCTAssertSeeks(h, [120.05])
    }
}

final class SmartSkipIssue14Tests: XCTestCase {
    func testActualGrassAndValueForMoneyDoNotCreateAnAd() {
        let subtitles = [
            F.row(0.08, 1.46, "家居废物坑货多"),
            F.row(1.46, 2.82, "有用东西真不多"),
            F.row(2.82, 4.66, "今天我又是从粑粑里淘金"),
            F.row(78.54, 80.92, "我是看了网上那些种草视频买的哈"),
            F.row(152.96, 154.72, "总体来说性价比还算不错"),
        ]
        let fixture = SSFixture(cid: 37625333201, duration: 237, subtitles: subtitles)
        let (segment, h) = SSHarness.detectAndAttach(fixture)
        XCTAssertNil(segment)
        h.tick(78.54)
        h.tick(79)
        h.tick(152.96)
        h.advance(10)
        XCTAssertSeeks(h, [])
        XCTAssertFalse(h.buttonVisible)
        XCTAssertEqual(SmartSkipPipeline.getSkipSegments(fixture.inputs), [], "the full pipeline agrees")
    }
}

final class SmartSkipCombineTests: XCTestCase {
    private func automatic(_ start: Double, _ end: Double, source: String = "fixture") -> SmartSkipSegment {
        SmartSkipSegment(start: start, end: end, source: source, requiresConfirmation: false)
    }

    func testExplicitPublisherBoundariesWinOverlapsAndLaterBreaksSurvive() {
        let chapter = automatic(60, 120, source: "chapters")
        let result = SmartSkipPipeline.combineSkipSegments(chapter, [automatic(55, 119), automatic(160, 190)])
        XCTAssertEqual(result, [chapter, automatic(160, 190)])
    }

    func testSourceAgreementRefinesTimestampStartWithoutStretching() {
        let timestamp = automatic(75, 120, source: "danmaku-time")
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(timestamp, [automatic(60, 119)]).first?.start, 60)
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(timestamp, [automatic(60, 180)]).first?.start, 75)
        var manual = automatic(60, 119)
        manual.requiresConfirmation = true
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(timestamp, [manual]).first?.start, 75)
    }

    func testKeepAnnotationsCannotEnterTheSkipSchedule() {
        var keep = automatic(60, 120)
        keep.skipDecision = "keep"
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(nil, [keep]).count, 0)
    }

    func testManualPrimaryIsReplacedByACoveringProposalWithinItsPadding() {
        var primary = SmartSkipSegment(start: 95, end: 107, source: "subtitles", requiresConfirmation: true)
        primary.boundaryPaddingSeconds = 5
        var proposal = SmartSkipSegment(start: 99, end: 103, source: "segment-detector", requiresConfirmation: true)
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(primary, [proposal]).map(\.source), ["segment-detector"])
        proposal.start = 101
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(primary, [proposal]).map(\.source), ["subtitles"])
        proposal.requiresConfirmation = false
        XCTAssertEqual(SmartSkipPipeline.combineSkipSegments(primary, [proposal]).map(\.source), ["segment-detector"],
                       "any overlapping trusted proposal replaces a manual primary")
    }

    func testGreedyFillPrefersTrustedProposalsAndNeverOverlaps() {
        var manual = SmartSkipSegment(start: 50, end: 100, source: "segment-detector", requiresConfirmation: true)
        manual.skipDecision = "skip"
        let trusted = SmartSkipSegment(start: 90, end: 130, source: "segment-detector", requiresConfirmation: false)
        let touching = SmartSkipSegment(start: 130, end: 150, source: "segment-detector")
        let result = SmartSkipPipeline.combineSkipSegments(nil, [manual, trusted, touching])
        XCTAssertEqual(result.map { [$0.start, $0.end] }, [[90, 130], [130, 150]], "touching ≠ overlapping")
    }

    func testTimestampConflictingWithAnExplicitReturnCannotOverrideStructure() {
        let (result, h) = SSHarness.detectAllAndAttach(SSFixture(subtitles: [
            F.row(70, 73, "本视频由某品牌赞助"),
            F.row(73, 80, "这款产品功能很多"),
            F.row(80, 85, "新人领取优惠券"),
            F.row(85, 95, "现在点击评论区链接购买下单"),
            F.row(100, 104, "现在回到视频"),
            F.row(104, 160, "以下全是正常正文"),
        ], danmaku: [SmartSkipDanmaku(time: 74, textContent: "跳过广告3:00")]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.reason, "cross-source-boundary-conflict")
        XCTAssertEqual(result.first?.start, 70)
        XCTAssertEqual(result.first?.end, 95)
        XCTAssertEqual(result.first?.conflictingTimestamp?.end, 180)
        XCTAssertEqual(result.first?.reviewReasons?.last, "trusted-destination-conflicts-with-observed-boundary")
        h.tick(79)
        XCTAssertSeeks(h, [])
    }

    func testObservedPromotionContinuingPastATimestampPreventsTruncation() {
        let primary = automatic(80, 120, source: "danmaku-time")
        let result = SmartSkipPipeline.combineSkipSegments(primary, [SmartSkipSegment(
            start: 70, end: 132, source: "segment-detector", requiresConfirmation: true,
            boundaryEvidence: SmartSkipBoundaryEvidence(end: SmartSkipBoundaryPoint(kind: "commercial-continuation-after-timestamp")))])
        XCTAssertEqual(result.first?.end, 132)
        XCTAssertEqual(result.first?.requiresConfirmation, true)
        XCTAssertEqual(result.first?.reason, "cross-source-boundary-conflict")
    }

    func testContradictoryCommunityEndpointsCannotRegainTrust() {
        let result = SmartSkipPipeline.combineSkipSegments(automatic(80, 120, source: "danmaku-time"), [SmartSkipSegment(
            start: 70, end: 120, source: "segment-detector", requiresConfirmation: true,
            boundaryEvidence: SmartSkipBoundaryEvidence(alternativeEnds: [SmartSkipAlternativeEnd(end: 180, references: 1)]),
            reviewReasons: ["conflicting-time-destinations"])])
        XCTAssertEqual(result.first?.start, 70)
        XCTAssertEqual(result.first?.end, 120)
        XCTAssertEqual(result.first?.requiresConfirmation, true)
        XCTAssertEqual(result.first?.conflictingTimestamp?.end, 120)
    }

    func testExplicitReturnRemainsContraryEvidenceWhenContinuityIsUncertain() {
        let (result, h) = SSHarness.detectAllAndAttach(SSFixture(subtitles: [
            F.row(80, 83, "本视频由某品牌赞助"),
            F.row(96, 100, "这款产品功能很多"),
            F.row(100, 105, "原理是普通物理知识"),
            F.row(105, 110, "新人可以免费试用"),
            F.row(110, 118, "现在点击评论区链接领取优惠券"),
            F.row(120, 124, "现在回到视频"),
            F.row(124, 170, "以下全是正常正文"),
        ], danmaku: [SmartSkipDanmaku(time: 85, textContent: "跳过广告3:00")]))
        XCTAssertEqual(result.first?.end, 118)
        XCTAssertEqual(result.first?.requiresConfirmation, true)
        XCTAssertEqual(result.first?.reason, "cross-source-boundary-conflict")
        h.tick(90)
        XCTAssertSeeks(h, [])
    }

    func testTrustedTimestampAgreeingWithAnAutoProposalIsReplacedByIt() {
        // ad() break with a matching explicit destination: the structural proposal replaces the
        // primary (its start is earlier and its end agrees within 3 s).
        var rows = SmartSkipSegmentDetectorTests.ad(100)
        rows.removeLast()
        let segments = SmartSkipPipeline.getSkipSegments(SSFixture(subtitles: rows, danmaku: [SmartSkipDanmaku(time: 101, textContent: "空降2:20")]).inputs)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.source, "segment-detector")
        XCTAssertEqual([segments.first?.start, segments.first?.end], [100, 140])
        XCTAssertEqual(segments.first?.requiresConfirmation, false)
    }
}
