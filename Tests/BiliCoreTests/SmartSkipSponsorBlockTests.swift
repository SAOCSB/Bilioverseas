// 「空降助手」 (BilibiliSponsorBlock) as a SmartSkip source: response parsing, the request, the
// per-category mapping, the merge with local detections, the analyzer integration and the
// tracker rules for 总是跳过 / 仅显示 (features.md §11). Not part of the BiliSmartSkip port.

import XCTest
@testable import BiliCore

final class SmartSkipSponsorBlockTests: XCTestCase {
    private let bvid = "BV1iQeM6uEEH"
    private struct NetworkFailure: Error {}

    private func row(_ category: String, _ start: Double, _ end: Double, uuid: String? = nil,
                     action: String = "skip") -> SponsorBlockSegment {
        SponsorBlockSegment(uuid: uuid ?? "\(category)-\(start)", category: category, actionType: action, start: start, end: end)
    }

    private func settings(_ configure: (inout SmartSkipSettings) -> Void = { _ in }) -> SmartSkipSettings {
        var s = SmartSkipSettings()
        configure(&s)
        return s
    }

    // MARK: response + request

    func testParseSegments() throws {
        let body = #"""
        [{"cid":"101","category":"sponsor","actionType":"skip","segment":[12.5,40],"UUID":"u1","videoDuration":600,"votes":3},
         {"category":"intro","segment":[0,8.25],"UUID":"u2"},
         {"category":"outro","segment":[590],"UUID":"bad"},
         {"category":"filler","segment":["x",3],"UUID":"bad2"}]
        """#
        let rows = try SponsorBlockClient.parseSegments(Data(body.utf8))
        XCTAssertEqual(rows, [
            SponsorBlockSegment(uuid: "u1", category: "sponsor", actionType: "skip", start: 12.5, end: 40, votes: 3, videoDuration: 600),
            SponsorBlockSegment(uuid: "u2", category: "intro", actionType: "skip", start: 0, end: 8.25),
        ], "a missing actionType means skip; rows without a numeric range are dropped")
        XCTAssertThrowsError(try SponsorBlockClient.parseSegments(Data(#"{"message":"x"}"#.utf8)))
        XCTAssertThrowsError(try SponsorBlockClient.parseSegments(Data("<html>".utf8)))
    }

    func testNormalizedServer() {
        XCTAssertEqual(SponsorBlockClient.normalizedServer("https://www.bsbsb.top/"), "https://www.bsbsb.top")
        XCTAssertEqual(SponsorBlockClient.normalizedServer("  bsbsb.top  "), "https://bsbsb.top")
        XCTAssertEqual(SponsorBlockClient.normalizedServer("http://192.168.1.2:8080"), "http://192.168.1.2:8080")
        XCTAssertNil(SponsorBlockClient.normalizedServer(""))
        XCTAssertNil(SponsorBlockClient.normalizedServer("ftp://x.org"))
    }

    func testRequestIsCookielessAndAsksForEveryRangeCategory() async throws {
        let transport = SSFakeTransport { _ in SSFakeTransport.json([["category": "sponsor", "segment": [1, 2], "UUID": "a"]]) }
        let rows = await SponsorBlockClient(transport: transport).skipSegments(bvid: bvid, cid: 101, server: "https://www.bsbsb.top/")
        XCTAssertEqual(rows?.map(\.uuid), ["a"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url, "https://www.bsbsb.top/api/skipSegments")
        XCTAssertEqual(request.credentials, .omit, "never the Bilibili cookies")
        XCTAssertFalse(request.wbi)
        XCTAssertEqual(request.query["videoID"], bvid)
        XCTAssertEqual(request.query["cid"], "101")
        let categories = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(request.query["categories"]).utf8)) as? [String]
        XCTAssertEqual(categories, ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "padding",
                                    "filler", "music_offtopic", "jumpscare"])
        XCTAssertEqual(request.query["actionTypes"], #"["skip","mute"]"#)
    }

    func testNotFoundMeansNoSegmentsAndOtherFailuresAreNil() async {
        let notFound = SSFakeTransport { _ in throw BiliError.http(status: 404) }
        let none = await SponsorBlockClient(transport: notFound).skipSegments(bvid: bvid, cid: 101, server: "https://www.bsbsb.top")
        XCTAssertEqual(none, [])
        for failure: Error in [BiliError.http(status: 500), BiliError.http(status: 429), NetworkFailure()] {
            let transport = SSFakeTransport { _ in throw failure }
            let rows = await SponsorBlockClient(transport: transport).skipSegments(bvid: bvid, cid: 101, server: "https://www.bsbsb.top")
            XCTAssertNil(rows, "\(failure)")
            XCTAssertEqual(transport.requests.count, 1, "no retry")
        }
        let html = SSFakeTransport { _ in Data("<html>".utf8) }
        let garbage = await SponsorBlockClient(transport: html).skipSegments(bvid: bvid, cid: 101, server: "https://www.bsbsb.top")
        XCTAssertNil(garbage)
        let unused = SSFakeTransport { _ in XCTFail("no request"); return Data() }
        let noServer = await SponsorBlockClient(transport: unused).skipSegments(bvid: bvid, cid: 101, server: " ")
        let noVideo = await SponsorBlockClient(transport: unused).skipSegments(bvid: "", cid: 101, server: "https://www.bsbsb.top")
        XCTAssertNil(noServer)
        XCTAssertNil(noVideo)
    }

    func testRejectedFiltersFallBackToThePlainRequestOnce() async {
        let transport = SSFakeTransport { request in
            if request.query["categories"] != nil { throw BiliError.http(status: 400) }
            return SSFakeTransport.json([["category": "intro", "segment": [0, 5], "UUID": "i"]])
        }
        let rows = await SponsorBlockClient(transport: transport).skipSegments(bvid: bvid, cid: 7, server: "https://www.bsbsb.top")
        XCTAssertEqual(rows?.map(\.category), ["intro"])
        XCTAssertEqual(transport.requests.map(\.query), [
            SponsorBlockClient.query(bvid: bvid, cid: 7, filtered: true),
            ["videoID": bvid, "cid": "7"],
        ])
    }

    // MARK: mapping

    func testDefaultSkipTypeIsSkipOnceForEveryCategory() {
        let defaults = SmartSkipSettings()
        XCTAssertTrue(defaults.sponsorBlockEnabled)
        XCTAssertEqual(defaults.sponsorBlockServer, "https://www.bsbsb.top")
        XCTAssertEqual(defaults.sponsorBlockMinDuration, 0)
        for category in SponsorBlockCategory.allCases {
            XCTAssertEqual(defaults.sponsorBlockSkipType(for: category), .skipOnce, category.rawValue)
        }
    }

    func testSkipTypesMapOntoTheTrackerFlags() {
        let s = settings {
            $0.setSponsorBlockSkipType(.alwaysSkip, for: .intro)
            $0.setSponsorBlockSkipType(.skipManually, for: .outro)
            $0.setSponsorBlockSkipType(.showOnly, for: .filler)
            $0.setSponsorBlockSkipType(.disable, for: .preview)
        }
        let segments = SponsorBlockSource.adSegments([
            row("sponsor", 60, 120, uuid: "s"), row("intro", 0, 10, uuid: "i"), row("outro", 580, 600, uuid: "o"),
            row("filler", 200, 230, uuid: "f"), row("preview", 10, 20, uuid: "p"),
        ], settings: s)
        XCTAssertEqual(segments.map(\.id), ["sponsorblock:s", "sponsorblock:i", "sponsorblock:o", "sponsorblock:f"])
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let sponsor = byID["sponsorblock:s"]!
        XCTAssertEqual([sponsor.requiresConfirmation, sponsor.alwaysSkip, sponsor.displayOnly], [false, false, false], "跳过一次")
        XCTAssertEqual(sponsor.source, "sponsorblock")
        XCTAssertEqual(sponsor.reason, "sponsor")
        XCTAssertEqual(sponsor.label, "赞助")
        XCTAssertEqual(sponsor.color, 0x00D400)
        XCTAssertEqual(sponsor.promptTitle, "跳过: 赞助")
        XCTAssertEqual(sponsor.skippedToast, "已跳过赞助片段")
        let intro = byID["sponsorblock:i"]!
        XCTAssertEqual([intro.requiresConfirmation, intro.alwaysSkip], [false, true], "总是跳过")
        XCTAssertTrue(byID["sponsorblock:o"]!.requiresConfirmation, "手动跳过 → button only")
        XCTAssertEqual(byID["sponsorblock:o"]!.promptTitle, "跳过: 片尾")
        XCTAssertTrue(byID["sponsorblock:f"]!.displayOnly, "仅显示")
    }

    func testUnusableRowsAreDroppedAndShortOrMuteSegmentsOnlyShown() {
        let s = settings { $0.sponsorBlockMinDuration = 5 }
        let segments = SponsorBlockSource.adSegments([
            row("sponsor", 0, 0, uuid: "label"),              // whole-video label
            row("poi_highlight", 30, 30, uuid: "poi", action: "poi"),
            row("exclusive_access", 0, 0, uuid: "full", action: "full"),
            row("sponsor", 50, 40, uuid: "reversed"),
            row("unknown_category", 1, 9, uuid: "unknown"),
            row("jumpscare", 70, 80, uuid: "mute", action: "mute"),
            row("interaction", 90, 93, uuid: "short"),
            row("selfpromo", -2, 20, uuid: "early"),
            row("selfpromo", -2, 20, uuid: "early"),           // duplicate UUID
            SponsorBlockSegment(uuid: "", category: "intro", actionType: "skip", start: 100, end: 110),
        ], settings: s)
        XCTAssertEqual(segments.map(\.id), ["sponsorblock:mute", "sponsorblock:short", "sponsorblock:early", "sponsorblock:intro:100:110"])
        XCTAssertTrue(segments[0].displayOnly, "mute cannot be applied: shown only")
        XCTAssertTrue(segments[1].displayOnly, "shorter than 「最短片段时长」")
        XCTAssertEqual(segments[2].start, 0, "clamped to the start of the video")
        XCTAssertFalse(segments[2].displayOnly)
    }

    func testMergeTrustsCommunityPromotionOverOverlappingLocalDetections() {
        let local = [
            AdSegment(start: 55, end: 125, requiresConfirmation: false, source: "danmaku-time"),
            AdSegment(start: 300, end: 360, requiresConfirmation: true, source: "subtitles"),
            AdSegment(start: 400, end: 450, requiresConfirmation: false, source: "chapters"),
        ]
        let s = settings { $0.setSponsorBlockSkipType(.showOnly, for: .selfpromo) }
        let sponsor = SponsorBlockSource.adSegments([
            row("sponsor", 60, 120, uuid: "ad"), row("intro", 290, 310, uuid: "intro"), row("selfpromo", 420, 440, uuid: "shown"),
        ], settings: s)
        let merged = SponsorBlockSource.merge(local: local, sponsor: sponsor)
        XCTAssertEqual(merged.map(\.id), ["sponsorblock:ad", "sponsorblock:intro", "300:360", "400:450", "sponsorblock:shown"],
                       "the overlapping local ad is replaced; an intro or a 仅显示 promotion does not replace anything")
        XCTAssertEqual(SponsorBlockSource.merge(local: local, sponsor: []), local)
        XCTAssertEqual(SponsorBlockSource.merge(local: [], sponsor: sponsor).count, 3)
    }

    func testAdSegmentTextsForLocalDetections() {
        XCTAssertEqual(AdSegment(start: 1, end: 2, requiresConfirmation: false, source: "chapters").promptTitle, "跳过广告")
        XCTAssertEqual(AdSegment(start: 1, end: 2, requiresConfirmation: true, source: "subtitles").promptTitle, "跳过疑似广告")
        XCTAssertEqual(AdSegment(start: 1, end: 2, requiresConfirmation: false, source: "chapters").skippedToast, "已跳过广告")
    }

    // MARK: analyzer

    /// Bilibili side: chapters mark a local ad at 90…120; danmaku and subtitles are fine.
    private func transport(sponsor: @escaping () throws -> Any) -> SSFakeTransport {
        SSFakeTransport { request in
            if request.url.contains("/api/skipSegments") { return SSFakeTransport.json(try sponsor()) }
            if request.url.contains("/x/player/") {
                return SSFakeTransport.json(["code": 0, "data": ["view_points": [["from": 90, "to": 120, "content": "广告"]],
                                                                 "subtitle": ["subtitles": []]]])
            }
            if request.url.contains("/x/v2/dm/") { return SSFakeTransport.protobuf([(1, "前排")]) }
            throw NetworkFailure()
        }
    }

    private var context: SmartSkipVideoContext {
        SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "Video", desc: "")
    }

    func testAnalyzerMergesBothSourcesAndCachesTheCommunityRows() async {
        let t = transport { [["category": "sponsor", "segment": [85, 125], "UUID": "ad"], ["category": "outro", "segment": [580, 600], "UUID": "end"]] }
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: t), accountID: { 0 })
        let segments = await analyzer.analyze(context, settings: settings())
        XCTAssertEqual(segments.map(\.id), ["sponsorblock:ad", "sponsorblock:end"], "the chapter ad 90…120 is covered by the community one")
        let count = t.requests.count
        let changed = await analyzer.analyze(context, settings: settings { $0.setSponsorBlockSkipType(.disable, for: .sponsor) })
        XCTAssertEqual(changed.map(\.id), ["90:120", "sponsorblock:end"], "settings apply to the cached rows")
        XCTAssertEqual(t.requests.count, count, "both sources cached")
        _ = await analyzer.analyze(context, settings: settings { $0.sponsorBlockServer = "https://example.org" })
        XCTAssertEqual(t.requests.filter { $0.url.contains("/api/skipSegments") }.map(\.url).last,
                       "https://example.org/api/skipSegments", "another server is another cache entry")
    }

    func testUnreachableServerFailsSoftAndIsRetriedLater() async {
        let reachable = SSAccountBox()   // mid 0 = down, otherwise up
        let t = transport {
            if reachable.mid == 0 { throw BiliError.http(status: 503) }
            return [["category": "intro", "segment": [0, 10], "UUID": "intro"]]
        }
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: t), accountID: { 0 })
        let down = await analyzer.analyze(context, settings: settings())
        XCTAssertEqual(down.map(\.id), ["90:120"], "local detection is unaffected")
        reachable.mid = 1
        let up = await analyzer.analyze(context, settings: settings())
        XCTAssertEqual(up.map(\.id), ["sponsorblock:intro", "90:120"], "a failed lookup is not cached")
    }

    func testSourceToggles() async {
        let t = transport { [["category": "intro", "segment": [0, 10], "UUID": "intro"]] }
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: t), accountID: { 0 })
        let localOnly = await analyzer.analyze(context, settings: settings { $0.sponsorBlockEnabled = false })
        XCTAssertEqual(localOnly.map(\.id), ["90:120"])
        XCTAssertFalse(t.requests.contains { $0.url.contains("/api/skipSegments") })

        let t2 = transport { [["category": "intro", "segment": [0, 10], "UUID": "intro"]] }
        let analyzer2 = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: t2), accountID: { 0 })
        let communityOnly = await analyzer2.analyze(context, settings: settings { $0.localDetection = false })
        XCTAssertEqual(communityOnly.map(\.id), ["sponsorblock:intro"])
        XCTAssertEqual(t2.requests.map(\.url), ["https://www.bsbsb.top/api/skipSegments"], "no Bilibili request at all")

        let none = await analyzer2.analyze(context, settings: settings { $0.localDetection = false; $0.sponsorBlockEnabled = false })
        XCTAssertEqual(none, [])
    }

    func testAnUnknownCidIsResolvedOnceForBothSources() async {
        let t = SSFakeTransport { request in
            if request.url.contains("/x/web-interface/view") {
                return SSFakeTransport.json(["code": 0, "data": ["bvid": self.bvid, "cid": 102, "title": "Video", "desc": "", "duration": 300,
                                                                 "pages": [["page": 1, "cid": 101, "duration": 240], ["page": 2, "cid": 102, "duration": 300]]]])
            }
            if request.url.contains("/api/skipSegments") { return SSFakeTransport.json([] as [Any]) }
            if request.url.contains("/x/player/") { return SSFakeTransport.json(["code": 0, "data": ["view_points": []]]) }
            return SSFakeTransport.protobuf([(1, "前排")])
        }
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: t), accountID: { 0 })
        _ = await analyzer.analyze(SmartSkipVideoContext(bvid: bvid, cid: 0, page: 2, duration: 0, title: "", desc: ""), settings: settings())
        XCTAssertEqual(t.requests.filter { $0.url.contains("/x/web-interface/view") }.count, 1)
        XCTAssertEqual(t.requests.first { $0.url.contains("/api/skipSegments") }?.query["cid"], "102", "P2's own cid")
    }

    // MARK: tracker

    private func sb(_ start: Double, _ end: Double, always: Bool = false, manual: Bool = false, shown: Bool = false) -> AdSegment {
        AdSegment(id: "sponsorblock:\(start)", start: start, end: end, requiresConfirmation: manual || shown,
                  source: "sponsorblock", reason: "intro", alwaysSkip: always, displayOnly: shown, label: "开场动画")
    }

    func testAlwaysSkipSkipsOnEveryEntry() {
        let h = SSHarness(segments: [sb(0, 10, always: true)])
        h.tick(0.2)
        h.seeked()
        h.tick(10.3)
        h.seek(4)                       // the user scrubs back in
        h.seeked()
        h.tick(4.1)
        XCTAssertSeeks(h, [10.05, 4, 10.05])
        XCTAssertFalse(h.buttonVisible)
    }

    func testAlwaysSkipRespectsUndoForThatVisit() {
        let h = SSHarness(segments: [sb(20, 40, always: true)])
        h.tick(20)
        h.seeked()
        let back = h.tracker.undo(sb(20, 40, always: true))
        XCTAssertEqual(back, 20)
        h.seek(back!)
        h.seeked()
        h.tick(20.5)
        h.tick(30)
        XCTAssertSeeks(h, [40.05, 20], "watching after 「撤销」")
        h.tick(41)
        h.tick(25)
        XCTAssertSeeks(h, [40.05, 20, 40.05], "a later entry is skipped again")
    }

    func testSkipOnceOffersTheButtonOnReentryAndManualModeOnlyPrompts() {
        let h = SSHarness(segments: [sb(20, 40)])
        h.tick(20)
        h.seeked()
        h.tick(25)
        XCTAssertSeeks(h, [40.05])
        XCTAssertTrue(h.buttonVisible)
        XCTAssertEqual(h.prompt?.segment.promptTitle, "跳过: 开场动画")
        let manual = SSHarness(segments: [sb(0, 10, always: true)], mode: .manual)
        manual.tick(1)
        XCTAssertSeeks(manual, [], "「手动」 mode never seeks by itself")
        XCTAssertTrue(manual.buttonVisible)
    }

    func testDisplayOnlySegmentsAreIgnoredByTheTracker() {
        let tracker = SmartSkipTracker(segments: [sb(0, 10, shown: true), sb(20, 30)], mode: .auto)
        XCTAssertEqual(tracker.segments.map(\.start), [20])
        XCTAssertNil(tracker.update(time: 5, isPlaying: true, now: 0))
        tracker.replaceSegments([sb(0, 10, shown: true)])
        XCTAssertEqual(tracker.segments, [])
    }
}
