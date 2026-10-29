// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): api.js data loading. Upstream
// `tests/api.test.cjs` @ test-branch 24d28a8 adapted to an injected transport (the page-bridge
// cases are web-only), plus protobuf / XML decoding and the analyzer entry point.

import XCTest
@testable import BiliCore

final class SmartSkipDataLoaderTests: XCTestCase {
    private let bvid = "BV1iQeM6uEEH"

    private func sample(bvid: String? = nil, desc: String = "", pages: [[String: Any]]? = nil) -> [String: Any] {
        ["bvid": bvid ?? self.bvid, "cid": 101, "title": "Video", "desc": desc, "duration": 600,
         "pages": pages ?? [["page": 1, "cid": 101, "duration": 240], ["page": 2, "cid": 102, "duration": 360]]]
    }

    private func envelope(_ data: Any) -> Data { SSFakeTransport.json(["code": 0, "message": "0", "data": data]) }

    private struct NetworkFailure: Error {}

    // MARK: metadata

    func testNormalizeVideoInfoUsesThePartsOwnCidAndDuration() throws {
        let data = JSON(any: sample())
        XCTAssertEqual(SmartSkipDataLoader.normalizeVideoInfo(data, bvid: bvid, pageNumber: 1),
                       SmartSkipVideoInfo(cid: 101, title: "Video", desc: "", duration: 240))
        XCTAssertEqual(SmartSkipDataLoader.normalizeVideoInfo(data, bvid: bvid, pageNumber: 2),
                       SmartSkipVideoInfo(cid: 102, title: "Video", desc: "", duration: 360))
        XCTAssertNil(SmartSkipDataLoader.normalizeVideoInfo(JSON(any: sample(pages: [])), bvid: bvid, pageNumber: 2))
        XCTAssertNil(SmartSkipDataLoader.normalizeVideoInfo(JSON(any: sample(pages: [["page": 1, "cid": 101, "duration": 240]])), bvid: bvid, pageNumber: 2),
                     "missing P2 never falls back to P1")
        XCTAssertEqual(SmartSkipDataLoader.normalizeVideoInfo(JSON(any: sample(pages: [])), bvid: bvid, pageNumber: 1)?.cid, 101,
                       "no pages: P1 uses the top-level cid")
        XCTAssertNil(SmartSkipDataLoader.normalizeVideoInfo(JSON(any: sample(bvid: "BV1otherVideo")), bvid: bvid, pageNumber: 1))
        XCTAssertNil(SmartSkipDataLoader.normalizeVideoInfo(.null, bvid: bvid, pageNumber: 1))
    }

    func testNormalizeVideoInfoCoercesLikeJSNumber() throws {
        let strings = JSON(any: ["bvid": bvid, "cid": "37625333201", "title": 5, "desc": NSNull(), "duration": "abc",
                                 "pages": [["page": "1", "cid": "37625333201", "duration": " 237 "]]] as [String: Any])
        XCTAssertEqual(SmartSkipDataLoader.normalizeVideoInfo(strings, bvid: bvid, pageNumber: 1),
                       SmartSkipVideoInfo(cid: 37625333201, title: "", desc: "", duration: 237))
        let badCid = JSON(any: ["bvid": bvid, "cid": 1.5, "duration": 0] as [String: Any])
        XCTAssertNil(SmartSkipDataLoader.normalizeVideoInfo(badCid, bvid: bvid, pageNumber: 1))
        let unknownDuration = JSON(any: ["bvid": bvid, "cid": 7, "duration": -3] as [String: Any])
        XCTAssertEqual(SmartSkipDataLoader.normalizeVideoInfo(unknownDuration, bvid: bvid, pageNumber: 1)?.duration, 0)
        XCTAssertEqual(SmartSkipDataLoader.validPage(0), 1)
        XCTAssertEqual(SmartSkipDataLoader.validPage(3), 3)
    }

    func testViewAPIRequestIsCredentialed() async {
        let transport = SSFakeTransport { _ in self.envelope(self.sample()) }
        let info = await SmartSkipDataLoader(transport: transport).fetchVideoInfo(bvid: bvid)
        XCTAssertEqual(info?.cid, 101)
        XCTAssertEqual(transport.requests, [.init(url: "https://api.bilibili.com/x/web-interface/view", query: ["bvid": bvid],
                                                  credentials: .include, wbi: false)])
    }

    func testHTTP412ReturnsNilWithoutParsing() async {
        let transport = SSFakeTransport { _ in throw BiliError.http(status: 412) }
        let info = await SmartSkipDataLoader(transport: transport).fetchVideoInfo(bvid: bvid)
        XCTAssertNil(info)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testP2UsesItsOwnCidAndStaleOrFailedMetadataIsRejected() async {
        let loader = SmartSkipDataLoader(transport: SSFakeTransport { _ in self.envelope(self.sample()) })
        let p2 = await loader.fetchVideoInfo(bvid: bvid, pageNumber: 2)
        XCTAssertEqual(p2, SmartSkipVideoInfo(cid: 102, title: "Video", desc: "", duration: 360))
        let stale = SSFakeTransport { _ in self.envelope(self.sample(bvid: "BV1otherVideo")) }
        let staleInfo = await SmartSkipDataLoader(transport: stale).fetchVideoInfo(bvid: bvid)
        XCTAssertNil(staleInfo)
        XCTAssertEqual(stale.requests.count, 1)
        let apiError = SSFakeTransport { _ in SSFakeTransport.json(["code": -404, "message": "啥都木有"]) }
        let missing = await SmartSkipDataLoader(transport: apiError).fetchVideoInfo(bvid: bvid)
        XCTAssertNil(missing)
        let html = SSFakeTransport { _ in Data("<html>".utf8) }
        let notJSON = await SmartSkipDataLoader(transport: html).fetchVideoInfo(bvid: bvid)
        XCTAssertNil(notJSON)
    }

    // MARK: player info & subtitles

    func testPlayerInfoIsWBISignedAndParsed() async {
        let transport = SSFakeTransport { _ in
            self.envelope(["view_points": [["type": 2, "from": 90, "to": 120, "content": "广告", "imgUrl": ""], ["content": "no times"]],
                           "subtitle": ["subtitles": [["id": 7, "lan": "ai-zh", "lan_doc": "中文（自动生成）", "subtitle_url": "//aisubtitle.hdslb.com/x.json", "type": 1]]]])
        }
        let info = await SmartSkipDataLoader(transport: transport).fetchPlayerInfo(bvid: bvid, cid: 101)
        XCTAssertEqual(info.viewPoints.first, VideoChapter(from: 90, to: 120, title: "广告"))
        XCTAssertTrue(info.viewPoints[1].from.isNaN, "missing times stay invalid")
        XCTAssertEqual(info.subtitles, [SubtitleTrack(id: 7, lan: "ai-zh", lanDoc: "中文（自动生成）", url: "//aisubtitle.hdslb.com/x.json", isAI: true)])
        XCTAssertEqual(transport.requests, [.init(url: "https://api.bilibili.com/x/player/wbi/v2", query: ["bvid": bvid, "cid": "101"],
                                                  credentials: .include, wbi: true)])
        let failing = SSFakeTransport { _ in SSFakeTransport.json(["code": -400]) }
        let empty = await SmartSkipDataLoader(transport: failing).fetchPlayerInfo(bvid: bvid, cid: 101)
        XCTAssertEqual(empty, SmartSkipPlayerInfo())
    }

    func testSubtitleTrackChoice() {
        func track(_ lan: String) -> SubtitleTrack { SubtitleTrack(id: 0, lan: lan, lanDoc: "", url: lan, isAI: false) }
        XCTAssertEqual(SmartSkipDataLoader.chooseSubtitleTrack([track("en-US"), track("ai-zh"), track("zh-CN")])?.lan, "ai-zh",
                       "first zh-CN / ai-zh in array order")
        XCTAssertEqual(SmartSkipDataLoader.chooseSubtitleTrack([track("en-US"), track("ja")])?.lan, "en-US")
        XCTAssertNil(SmartSkipDataLoader.chooseSubtitleTrack([]))
    }

    func testSubtitleBodyOmitsCookiesAndFixesProtocolRelativeURLs() async {
        let transport = SSFakeTransport { _ in
            SSFakeTransport.json(["body": [["from": 1.5, "to": 3, "content": "本期视频由某品牌赞助", "location": 2]]])
        }
        let loader = SmartSkipDataLoader(transport: transport)
        let rows = await loader.fetchSubtitleBody("//aisubtitle.hdslb.com/bfs/ai_subtitle/x.json?auth_key=1")
        XCTAssertEqual(rows, [SubtitleLine(from: 1.5, to: 3, content: "本期视频由某品牌赞助")])
        XCTAssertEqual(transport.requests, [.init(url: "https://aisubtitle.hdslb.com/bfs/ai_subtitle/x.json?auth_key=1", query: [:],
                                                  credentials: .omit, wbi: false)])
        let none = await loader.fetchSubtitleBody("")
        XCTAssertEqual(none, [], "the empty AI-subtitle URL of logged-out users")
        XCTAssertEqual(transport.requests.count, 1)
        let notArray = SSFakeTransport { _ in SSFakeTransport.json(["body": "x"]) }
        let bad = await SmartSkipDataLoader(transport: notArray).fetchSubtitleBody("https://x/y.json")
        XCTAssertEqual(bad, [])
    }

    // MARK: protobuf

    func testDecodeDanmakuProto() throws {
        var element = ProtobufWriter()
        element.write(1, int64: 99)                       // id (varint) ignored
        element.write(2, int64: 3_600_000)                // progress ms
        element.write(3, int64: 1)
        element.write(7, string: "\u{FEFF}空降 2:00")       // BOM stripped like TextDecoder
        element.write(9, bytes: [1, 2, 3])                // other length-delimited field skipped
        var message = ProtobufWriter()
        message.write(1, bytes: element.bytes)
        var emptyContent = ProtobufWriter()
        emptyContent.write(2, int64: 5000)
        message.write(1, bytes: emptyContent.bytes)       // dropped: empty content
        message.write(2, int64: 7)                        // unknown top-level varint
        let rows = try SmartSkipDataLoader.decodeDanmakuProto(message.data)
        XCTAssertEqual(rows, [SmartSkipDanmaku(time: 3600, textContent: "空降 2:00")])
    }

    func testDecodeDanmakuProtoKeepsJSInt32Semantics() throws {
        var element = ProtobufWriter()
        element.write(2, int64: -1)                       // 10-byte varint → int32 -1
        element.write(7, string: "x")
        var message = ProtobufWriter()
        message.write(1, bytes: element.bytes)
        XCTAssertEqual(try SmartSkipDataLoader.decodeDanmakuProto(message.data), [SmartSkipDanmaku(time: -0.001, textContent: "x")])
    }

    func testDecodeDanmakuProtoThrowsOnAnOutOfRangeLength() {
        XCTAssertThrowsError(try SmartSkipDataLoader.decodeDanmakuProto(Data([0x0A, 0x05, 0x10, 0x01])))
        XCTAssertEqual(try SmartSkipDataLoader.decodeDanmakuProto(Data()), [])
    }

    func testProtobufSegmentsSurviveAnotherSegmentFailingAndAreSorted() async {
        let transport = SSFakeTransport { request in
            XCTAssertEqual(URL(string: request.url)?.host, "api.bilibili.com")
            let index = Int(request.query["segment_index"]!)!
            if index == 2 { throw NetworkFailure() }
            return SSFakeTransport.protobuf([(index == 1 ? 12 : 5, "segment-\(index)")])
        }
        let rows = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 101, duration: 1080)
        XCTAssertEqual(rows, [SmartSkipDanmaku(time: 5, textContent: "segment-3"), SmartSkipDanmaku(time: 12, textContent: "segment-1")])
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0.credentials == .include && $0.query["type"] == "1" && $0.query["oid"] == "101" })
    }

    func testProtobufFetchingStaysAtTwoConcurrentRequests() async {
        let transport = SSFakeTransport { request in
            try await Task.sleep(nanoseconds: 20_000_000)
            let index = Int(request.query["segment_index"]!)!
            return SSFakeTransport.protobuf([(Double(index), "segment-\(index)")])
        }
        let rows = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 101, duration: 1800)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.time), [1, 2, 3, 4, 5])
        XCTAssertEqual(transport.peakConcurrency, 2)
        XCTAssertEqual(transport.requests.count, 5)
    }

    func testUnknownDurationAssumesTenMinutes() async {
        let transport = SSFakeTransport { _ in SSFakeTransport.protobuf([(1, "x")]) }
        _ = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 1, duration: 0)
        XCTAssertEqual(transport.requests.count, 2, "ceil(600 / 360)")
    }

    func test412StopsNewRequestsButKeepsTheInFlightResult() async {
        let transport = SSFakeTransport { request in
            let index = Int(request.query["segment_index"]!)!
            XCTAssertLessThanOrEqual(index, 2, "no requests after the two already in flight")
            if index == 1 {
                try await Task.sleep(nanoseconds: 30_000_000)
                throw BiliError.http(status: 412)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            return SSFakeTransport.protobuf([(400, "kept")])
        }
        let rows = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 101, duration: 3600)
        XCTAssertEqual(rows, [SmartSkipDanmaku(time: 400, textContent: "kept")])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testXMLFailureReturnsEmptyAndThePublicXMLOmitsCredentials() async {
        let transport = SSFakeTransport { request in
            if URL(string: request.url)?.host == "api.bilibili.com" { throw BiliError.http(status: 412) }
            throw NetworkFailure()
        }
        let rows = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 101, duration: 600)
        XCTAssertEqual(rows, [])
        let xml = transport.requests.filter { $0.url.hasSuffix(".xml") }
        XCTAssertEqual(xml, [.init(url: "https://comment.bilibili.com/101.xml", query: [:], credentials: .omit, wbi: false)])
    }

    func testXMLFallbackIsUsedOnlyWhenProtobufYieldsNothing() async {
        let body = #"<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver><d p="12.5,1,25,16777215,0,0,ab,1">后面</d><d p="3.25,1,25,16777215,0,0,cd,2">前面 &amp; 后</d><d p="-1,1">neg</d><d p="x">nan</d><d p="7,1"></d></i>"#
        let transport = SSFakeTransport { request in
            if request.url.hasSuffix(".xml") { return Data(body.utf8) }
            return SSFakeTransport.protobuf([])
        }
        let rows = await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 9, duration: 300)
        XCTAssertEqual(rows, [SmartSkipDanmaku(time: 3.25, textContent: "前面 & 后"), SmartSkipDanmaku(time: 12.5, textContent: "后面")])
        let withRows = SSFakeTransport { request in
            if request.url.hasSuffix(".xml") { XCTFail("XML must not be requested"); return Data() }
            return SSFakeTransport.protobuf([(1, "pb")])
        }
        let pb = await SmartSkipDataLoader(transport: withRows).fetchDanmakuWithTime(cid: 9, duration: 300)
        XCTAssertEqual(pb, [SmartSkipDanmaku(time: 1, textContent: "pb")])
    }

    func testCancelledDanmakuFetchDoesNotFallBackToXML() async {
        let transport = SSFakeTransport { request in
            if request.url.hasSuffix(".xml") { return Data("<i></i>".utf8) }
            try await Task.sleep(nanoseconds: 10_000_000_000)   // cancelled long before
            return SSFakeTransport.protobuf([])
        }
        let task = Task { await SmartSkipDataLoader(transport: transport).fetchDanmakuWithTime(cid: 9, duration: 300) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()                                          // the player switched video
        let rows = await task.value
        XCTAssertEqual(rows, [])
        XCTAssertFalse(transport.requests.contains { $0.url.hasSuffix(".xml") }, "no XML download after cancellation")
    }

    func testDanmakuXMLRejectsInvalidDocuments() {
        XCTAssertThrowsError(try SmartSkipDataLoader.parseDanmakuXML(Data("<root><d p=\"1\">x</d></root>".utf8)), "root must be <i>")
        XCTAssertThrowsError(try SmartSkipDataLoader.parseDanmakuXML(Data("<i><d p=\"1\">x</i>".utf8)), "parser error")
        XCTAssertEqual(try SmartSkipDataLoader.parseDanmakuXML(Data("<i></i>".utf8)), [])
    }

    // MARK: pipeline data + analyzer

    /// `danmakuOK: false` → seg.so answers 412 and the XML is unreachable (a degraded load).
    private func pipelineTransport(chapters: [[String: Any]], desc: String = "",
                                   subtitles: [[String: Any]] = [], subtitleBody: [[String: Any]] = [],
                                   danmakuOK: Bool = false) -> SSFakeTransport {
        SSFakeTransport { request in
            if request.url.contains("/x/web-interface/view") { return self.envelope(self.sample(desc: desc)) }
            if request.url.contains("/x/player/") { return self.envelope(["view_points": chapters, "subtitle": ["subtitles": subtitles]]) }
            if request.url.contains("/x/v2/dm/") {
                if danmakuOK { return SSFakeTransport.protobuf([(1, "前排")]) }
                throw BiliError.http(status: 412)
            }
            if request.url.hasSuffix(".json") { return SSFakeTransport.json(["body": subtitleBody]) }
            throw NetworkFailure()   // XML (and anything else) unavailable
        }
    }

    /// Local detection only (no 空降助手 request), independent of the stored settings.
    static let localOnly: SmartSkipSettings = {
        var s = SmartSkipSettings()
        s.sponsorBlockEnabled = false
        return s
    }()

    func testChaptersAndDescriptionStillDetectWhenBothDanmakuSourcesFail() async {
        for source in ["chapters", "description"] {
            let transport = pipelineTransport(
                chapters: source == "chapters" ? [["from": 90, "to": 120, "content": "广告"]] : [],
                desc: source == "description" ? "00:00 正片\n01:30 广告\n02:00 正片" : "")
            let loader = SmartSkipDataLoader(transport: transport)
            let context = await loader.complete(SmartSkipVideoContext(bvid: bvid, cid: 0, duration: 0, title: "", desc: ""))
            XCTAssertEqual(context?.cid, 101, source)
            XCTAssertEqual(context?.danmaku, [], source)
            let result = SmartSkipPipeline.getSkipSegment(context!.inputs)
            XCTAssertEqual(result?.source, source)
            XCTAssertEqual([result?.start, result?.end], [90, 120], source)
            XCTAssertEqual(result?.requiresConfirmation, false, source)
        }
    }

    func testCompleteUsesThePlayersDataWithoutAnyRequest() async {
        let transport = SSFakeTransport { request in XCTFail("unexpected request \(request.url)"); return Data() }
        let context = SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "t", desc: "",
                                            chapters: [], subtitleLines: [], danmaku: [SSFixtures.timestamp()])
        let complete = await SmartSkipDataLoader(transport: transport).complete(context)
        XCTAssertEqual(complete?.danmaku, [SSFixtures.timestamp()])
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testCompleteFetchesTheChosenSubtitleTrackOnce() async {
        let transport = pipelineTransport(chapters: [],
                                          subtitles: [["lan": "en", "subtitle_url": "//x/en.json"], ["lan": "ai-zh", "subtitle_url": "//x/zh.json"]],
                                          subtitleBody: [["from": 79, "to": 83, "content": "本期视频由某品牌赞助"]])
        let complete = await SmartSkipDataLoader(transport: transport).complete(SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "", desc: ""))
        XCTAssertEqual(complete?.subtitleLines, [SubtitleLine(from: 79, to: 83, content: "本期视频由某品牌赞助")])
        XCTAssertEqual(transport.requests.filter { $0.url.hasSuffix(".json") }.map(\.url), ["https://x/zh.json"])
        XCTAssertFalse(transport.requests.contains { $0.url.contains("/x/web-interface/view") }, "cid known → no view request")
    }

    func testNoSubtitleTrackMeansNoSubtitleRequest() async {
        let transport = pipelineTransport(chapters: [])
        let complete = await SmartSkipDataLoader(transport: transport).complete(
            SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "", desc: "", danmaku: [SSFixtures.timestamp()]))
        XCTAssertEqual(complete?.subtitleLines, [])
        XCTAssertFalse(transport.requests.contains { $0.url.hasSuffix(".json") })
        XCTAssertFalse(transport.requests.contains { $0.url.contains("/x/v2/dm/") }, "danmaku supplied by the player")
    }

    func testProvidedDanmakuIsStablySortedForTheDetectors() {
        let context = SmartSkipVideoContext(bvid: bvid, cid: 1, duration: 600, title: "", desc: "",
                                            danmaku: [SmartSkipDanmaku(time: 9, textContent: "b"), SmartSkipDanmaku(time: 3, textContent: "a"),
                                                      SmartSkipDanmaku(time: 9, textContent: "c")])
        XCTAssertEqual(context.inputs.danmaku.map(\.textContent), ["a", "b", "c"])
    }

    func testAnalyzerEndToEndAndCache() async {
        let transport = pipelineTransport(chapters: [["from": 90, "to": 120, "content": "广告"]], danmakuOK: true)
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: transport), accountID: { 0 })
        let context = SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 240, title: "Video", desc: "")
        let segments = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertEqual(segments, [AdSegment(id: "90:120", start: 90, end: 120, requiresConfirmation: false, source: "chapters",
                                            reason: "explicit-ad-label", matchedKeywords: ["广告"])])
        let count = transport.requests.count
        let again = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertEqual(again, segments)
        XCTAssertEqual(transport.requests.count, count, "cached per video")
    }

    func testResultsComputedFromFailedRequestsAreNotCached() async {
        // seg.so answers 412 and the XML is unreachable: the chapters still detect, but the next
        // open must run again (upstream re-runs on every page load).
        let transport = pipelineTransport(chapters: [["from": 90, "to": 120, "content": "广告"]])
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: transport), accountID: { 0 })
        let context = SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 240, title: "Video", desc: "")
        let first = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertEqual(first.map(\.id), ["90:120"])
        let count = transport.requests.count
        let again = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertEqual(again, first)
        XCTAssertGreaterThan(transport.requests.count, count, "a degraded result is recomputed")
    }

    func testCacheIsPerAccount() async {
        let account = SSAccountBox()
        let transport = pipelineTransport(chapters: [], danmakuOK: true)
        let analyzer = SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: transport), accountID: { account.mid })
        let context = SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 240, title: "Video", desc: "")
        _ = await analyzer.analyze(context, settings: Self.localOnly)
        let count = transport.requests.count
        _ = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertEqual(transport.requests.count, count)
        account.mid = 42   // logged in: AI subtitles may be available now
        _ = await analyzer.analyze(context, settings: Self.localOnly)
        XCTAssertGreaterThan(transport.requests.count, count)
    }

    func testLoadReportsFailedInputs() async {
        let context = SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "", desc: "")
        let zh: [[String: Any]] = [["lan": "zh-CN", "subtitle_url": "//x/zh.json"]]
        let complete = await SmartSkipDataLoader(transport: pipelineTransport(chapters: [], subtitles: zh, danmakuOK: true)).load(context)
        XCTAssertEqual(complete?.degraded, false)
        XCTAssertEqual(complete?.context.danmaku?.count, 2)

        let noDanmaku = await SmartSkipDataLoader(transport: pipelineTransport(chapters: [], subtitles: zh)).load(context)
        XCTAssertEqual(noDanmaku?.degraded, true, "seg.so 412 + XML failure")
        XCTAssertEqual(noDanmaku?.context.danmaku, [])

        let playerDown = SSFakeTransport { request in
            if request.url.contains("/x/player/") { throw BiliError.http(status: 412) }
            return SSFakeTransport.protobuf([(1, "前排")])
        }
        let noPlayer = await SmartSkipDataLoader(transport: playerDown).load(context)
        XCTAssertEqual(noPlayer?.degraded, true)
        XCTAssertEqual(noPlayer?.context.chapters, [])

        let bodyDown = SSFakeTransport { request in
            if request.url.hasSuffix(".json") { throw NetworkFailure() }
            return SSFakeTransport.protobuf([(1, "前排")])
        }
        let noBody = await SmartSkipDataLoader(transport: bodyDown)
            .load(SmartSkipVideoContext(bvid: bvid, cid: 101, duration: 600, title: "", desc: "", chapters: [],
                                        subtitleTracks: [SubtitleTrack(id: 1, lan: "zh-CN", lanDoc: "中文", url: "//x/zh.json", isAI: false)]))
        XCTAssertEqual(noBody?.degraded, true)
        XCTAssertEqual(noBody?.context.subtitleLines, [])

        // The logged-out AI track has no URL: nothing to retry.
        let aiOnly: [[String: Any]] = [["lan": "ai-zh", "subtitle_url": ""]]
        let transport = pipelineTransport(chapters: [], subtitles: aiOnly, danmakuOK: true)
        let loggedOut = await SmartSkipDataLoader(transport: transport).load(context)
        XCTAssertEqual(loggedOut?.degraded, false)
        XCTAssertFalse(transport.requests.contains { $0.url.hasSuffix(".json") })
    }

    func testAnalyzerReturnsNothingWhenTheCidCannotBeResolved() async {
        let transport = SSFakeTransport { _ in throw BiliError.http(status: 412) }
        let segments = await SmartSkipAnalyzer(loader: SmartSkipDataLoader(transport: transport))
            .analyze(SmartSkipVideoContext(bvid: bvid, cid: 0, duration: 0, title: "", desc: ""), settings: SmartSkipSettings())
        XCTAssertEqual(segments, [])
        XCTAssertEqual(transport.requests.count, 1, "only the view request (neither source runs without a cid)")
    }

    func testDetectIsThePurePipeline() {
        let segments = SmartSkipAnalyzer.detect(SSFixture(danmaku: [SSFixtures.timestamp()]).inputs)
        XCTAssertEqual(segments.map(\.id), ["79:120"])
        XCTAssertEqual(segments.first?.requiresConfirmation, false)
        XCTAssertEqual(segments.first?.source, "danmaku-time")
    }
}
