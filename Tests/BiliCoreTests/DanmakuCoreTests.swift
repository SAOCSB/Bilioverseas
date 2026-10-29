import XCTest
@testable import BiliCore

// MARK: - Helpers

private func elem(id: Int64 = 1, progressMs: Int64 = 1500, mode: Int64 = 1, fontsize: Int64 = 25,
                  color: Int64 = 0xFFFFFF, midHash: String = "abc", content: String = "hello",
                  ctime: Int64 = 1_700_000_000, weight: Int64 = 5, pool: Int64 = 0, attr: Int64 = 0,
                  colorful: Int64 = 0, extraUnknown: Bool = false) -> ProtobufWriter {
    var w = ProtobufWriter()
    w.write(1, int64: id)
    w.write(2, int64: progressMs)
    w.write(3, int64: mode)
    w.write(4, int64: fontsize)
    w.write(5, int64: color)
    w.write(6, string: midHash)
    w.write(7, string: content)
    w.write(8, int64: ctime)
    w.write(9, int64: weight)
    if extraUnknown {
        w.write(10, string: "action")             // known-but-ignored
        w.write(22, string: "{\"anim\":1}")        // animation
        w.write(99, int64: 12345)                  // unknown varint
        w.writeTag(30, .fixed32)                   // unknown fixed32 (4 raw bytes)
        for _ in 0..<4 { w.writeVarint(0x11) }
        w.writeTag(31, .fixed64)                   // unknown fixed64 (8 raw bytes)
        for _ in 0..<8 { w.writeVarint(0x22) }
        w.write(7, int64: 7)                       // known field number, wrong wire type → skipped
    }
    w.write(11, int64: pool)
    w.write(13, int64: attr)
    w.write(15, int64: 42)
    if colorful != 0 { w.write(24, int64: colorful) }
    return w
}

private func item(_ id: Int64, _ time: Double, _ content: String = "x", mode: Int = 1, color: UInt32 = 0xFFFFFF,
                  midHash: String = "", weight: Int = 5) -> DanmakuItem {
    DanmakuItem(id: id, time: time, mode: mode, color: color, midHash: midHash, content: content, weight: weight)
}

// MARK: - Protobuf

final class DanmakuProtobufTests: XCTestCase {
    func testDecodeSegmentReply() throws {
        var reply = ProtobufWriter()
        reply.write(1, message: elem(id: 11, progressMs: 61_234, mode: 5, color: 0xFE0302, content: "顶部", extraUnknown: true))
        reply.write(1, message: elem(id: 12, progressMs: 2_000, mode: 1, content: "滚动", colorful: 60001))
        reply.write(2, int64: 1)
        var aiFlag = ProtobufWriter()
        var flag = ProtobufWriter()
        flag.write(1, int64: 11)
        flag.write(2, int64: 3)
        aiFlag.write(1, message: flag)
        reply.write(3, message: aiFlag)          // ai_flag (ignored)
        reply.write(4, int64: 9)                 // segment_rules (ignored)
        reply.write(6, string: "ctx")            // context_src (ignored)
        reply.write(77, string: "future field")  // unknown top-level field

        let decoded = try DanmakuProtobuf.decodeSegmentReply(reply.data)
        XCTAssertEqual(decoded.state, 1)
        XCTAssertTrue(decoded.isClosed)
        XCTAssertEqual(decoded.items.count, 2)
        let a = decoded.items[0]
        XCTAssertEqual(a.id, 11)
        XCTAssertEqual(a.time, 61.234, accuracy: 1e-9)
        XCTAssertEqual(a.mode, 5)
        XCTAssertEqual(a.kind, .top)
        XCTAssertEqual(a.fontSize, 25)
        XCTAssertEqual(a.color, 0xFE0302)
        XCTAssertEqual(a.midHash, "abc")
        XCTAssertEqual(a.content, "顶部")   // the wrong-wire-type field 7 did not overwrite it
        XCTAssertEqual(a.ctime, 1_700_000_000)
        XCTAssertEqual(a.weight, 5)
        XCTAssertEqual(a.likeCount, 42)
        XCTAssertTrue(a.isColorful)
        let b = decoded.items[1]
        XCTAssertEqual(b.id, 12)
        XCTAssertEqual(b.time, 2.0, accuracy: 1e-9)
        XCTAssertTrue(b.isVipGradient)
        XCTAssertTrue(b.isColorful)
    }

    func testIdStrFallbackAndNegativeValues() throws {
        var e = ProtobufWriter()
        e.write(2, int64: -5)               // negative progress clamps to 0
        e.write(3, int64: -1)               // negative int32 (10-byte varint)
        e.write(7, string: "x")
        e.write(12, string: "987654321")
        var reply = ProtobufWriter()
        reply.write(1, message: e)
        let decoded = try DanmakuProtobuf.decodeSegmentReply(reply.data)
        XCTAssertEqual(decoded.items.first?.id, 987_654_321)
        XCTAssertEqual(decoded.items.first?.time, 0)
        XCTAssertEqual(decoded.items.first?.mode, -1)
        XCTAssertEqual(decoded.items.first?.kind, .scroll)
    }

    func testEmptyBodyIsEmptyReply() throws {
        XCTAssertEqual(try DanmakuProtobuf.decodeSegmentReply(Data()), .empty)
        // Elements without content are dropped.
        var e = ProtobufWriter()
        e.write(1, int64: 3)
        var reply = ProtobufWriter()
        reply.write(1, message: e)
        XCTAssertTrue(try DanmakuProtobuf.decodeSegmentReply(reply.data).items.isEmpty)
    }

    func testGarbageBodiesThrowInsteadOfCrashing() {
        let bodies: [[UInt8]] = [
            Array(#"{"code":-101,"message":"账号未登录","ttl":1}"#.utf8),
            Array("<!DOCTYPE html><html><body>412</body></html>".utf8),
            Array("<?xml version=\"1.0\"?><i></i>".utf8),
            Array("Not Found".utf8),
            [0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],   // absurd length
            [0x0A, 0x05, 0x01],                                               // truncated
            [0x0A, 0x02, 0x3A, 0x7F],                                         // nested length overflow
            [0x1F, 0x8B, 0x08, 0x00],                                         // gzip magic
            [0x00, 0x01],                                                     // field 0
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        ]
        for body in bodies {
            XCTAssertThrowsError(try DanmakuProtobuf.decodeSegmentReply(bytes: body), "\(body.prefix(12))")
        }
        // A Chinese JSON message whose UTF-8 bytes form long varint runs.
        let zh = Array("账号未登录账号未登录".utf8)
        XCTAssertThrowsError(try DanmakuProtobuf.decodeSegmentReply(bytes: [0x0A] + zh))
    }

    func testLegacyXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver><chatid>1</chatid>\
        <d p="12.345,1,25,16777215,1700000000,0,83dcefb7,1001,7">第一条 &amp; 测试</d>\
        <d p="3.5,5,18,16646914,1700000001,0,abcd,1002,2">顶部</d>\
        <d p="bad">x</d></i>
        """
        let items = DanmakuXMLDecoder.decode(Data(xml.utf8))
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].id, 1002)
        XCTAssertEqual(items?[0].kind, .top)
        XCTAssertEqual(items?[0].color, 16646914)
        XCTAssertEqual(items?[1].time ?? 0, 12.345, accuracy: 1e-9)
        XCTAssertEqual(items?[1].content, "第一条 & 测试")
        XCTAssertEqual(items?[1].midHash, "83dcefb7")
        XCTAssertEqual(items?[1].weight, 7)
        XCTAssertNil(DanmakuXMLDecoder.decode(Data(#"{"code":-404}"#.utf8)))
        XCTAssertNil(DanmakuXMLDecoder.decode(Data("<html><i>x</i></html>".utf8)))
    }
}

// MARK: - Models / hashing / segments

final class DanmakuModelTests: XCTestCase {
    func testCRC32AndMidHash() {
        XCTAssertEqual(DanmakuHash.crc32("123456789"), 0xCBF4_3926)
        XCTAssertEqual(DanmakuHash.midHash(mid: 1), "83dcefb7")
        XCTAssertEqual(DanmakuHash.normalizeUserRule(" 1 "), "83dcefb7")
        XCTAssertEqual(DanmakuHash.normalizeUserRule("0xABC"), "abc")
        XCTAssertEqual(DanmakuHash.normalizeUserRule("d0e1f2"), "d0e1f2")
        XCTAssertNil(DanmakuHash.normalizeUserRule("zz"))
        XCTAssertNil(DanmakuHash.normalizeUserRule(""))
    }

    func testSegmentIndex() {
        XCTAssertEqual(DanmakuSegment.index(for: 0), 1)
        XCTAssertEqual(DanmakuSegment.index(for: -3), 1)
        XCTAssertEqual(DanmakuSegment.index(for: 359.999), 1)
        XCTAssertEqual(DanmakuSegment.index(for: 360), 2)
        XCTAssertEqual(DanmakuSegment.index(for: 725), 3)
        XCTAssertEqual(DanmakuSegment.range(of: 2), 360..<720)
        XCTAssertEqual(DanmakuSegment.count(forDuration: 720), 2)
        XCTAssertEqual(DanmakuSegment.count(forDuration: 721), 3)
        XCTAssertEqual(DanmakuSegment.count(forDuration: 0), 1)
    }

    func testKindsAndDisplayText() {
        XCTAssertEqual(item(1, 0, mode: 1).kind, .scroll)
        XCTAssertEqual(item(1, 0, mode: 6).kind, .scroll)
        XCTAssertEqual(item(1, 0, mode: 4).kind, .bottom)
        XCTAssertEqual(item(1, 0, mode: 5).kind, .top)
        XCTAssertEqual(item(1, 0, mode: 7).kind, .advanced)
        XCTAssertEqual(item(1, 0, mode: 9).kind, .advanced)
        var d = item(1, 0, "哈哈")
        XCTAssertEqual(d.displayText, "哈哈")
        d.count = 3
        XCTAssertEqual(d.displayText, "哈哈 ×3")
    }

    func testSettingsDefaultsMatchSpec() {
        let s = DanmakuSettings()
        XCTAssertEqual(s.opacity, 1.0)
        XCTAssertEqual(s.strokeWidth, 1.5)
        XCTAssertEqual(s.scrollDuration, 7)
        XCTAssertEqual(s.fixedDuration, 4)
        XCTAssertEqual(s.lineHeight, 1.6)
        XCTAssertEqual(s.area, .half)
        XCTAssertEqual(s.fontWeight, 5)
        XCTAssertTrue(s.bold)
        XCTAssertFalse(s.mergeDuplicates)
        XCTAssertEqual(s.resolvedFontSize(fullscreen: false), 15)
        XCTAssertEqual(s.resolvedFontSize(fullscreen: true), 18, accuracy: 1e-9)
        var t = s
        t.bold = false
        XCTAssertEqual(t.fontWeight, 3)
        t.bold = true
        XCTAssertEqual(t.fontWeight, 5)
        t.blockedKeywords = ["a"]
        t.opacity = 0.3
        t.resetDisplayOptions()
        XCTAssertEqual(t.opacity, 1.0)
        XCTAssertEqual(t.blockedKeywords, ["a"])
        // Persistence round trip ignores the computed `bold`.
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(DanmakuSettings.self, from: data), s)
    }
}

// MARK: - Filter

final class DanmakuFilterTests: XCTestCase {
    func testKeywordsAreCaseInsensitiveSubstrings() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["Spoiler", "  ", "剧透"]
        let f = DanmakuFilter(settings: s)
        XCTAssertFalse(f.shouldShow(item(1, 0, "big SPOILER here")))
        XCTAssertFalse(f.shouldShow(item(2, 0, "前方剧透注意")))
        XCTAssertTrue(f.shouldShow(item(3, 0, "nothing")))
    }

    func testRegexRulesAndInvalidRegexIgnored() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["/^哈+$/", "/[unclosed/", "/AB\\d+/"]
        let f = DanmakuFilter(settings: s)
        XCTAssertEqual(f.regexes.count, 2)
        XCTAssertTrue(f.keywords.isEmpty)
        XCTAssertFalse(f.shouldShow(item(1, 0, "哈哈哈")))
        XCTAssertTrue(f.shouldShow(item(2, 0, "哈哈哈好")))
        XCTAssertFalse(f.shouldShow(item(3, 0, "xx ab12 yy")))   // case-insensitive
        XCTAssertTrue(f.shouldShow(item(4, 0, "[unclosed")))    // invalid rule ignored entirely
        XCTAssertNil(DanmakuFilter.compiledRegex("[unclosed"))
        XCTAssertNil(DanmakuFilter.regexPattern(from: "//"))
        XCTAssertNil(DanmakuFilter.regexPattern(from: "plain"))
        XCTAssertEqual(DanmakuFilter.regexPattern(from: " /a|b/ "), "a|b")
    }

    func testBlockedUsersAndSelfBypass() {
        var s = DanmakuSettings()
        s.blockedUsers = ["DEADBEEF"]
        s.blockedKeywords = ["bad"]
        s.hideScroll = true
        let me = DanmakuHash.midHash(mid: 42)
        let f = DanmakuFilter(settings: s, selfMidHash: me)
        XCTAssertFalse(f.shouldShow(item(1, 0, "ok", mode: 5, midHash: "deadbeef")))
        XCTAssertTrue(f.shouldShow(item(2, 0, "ok", mode: 5, midHash: "cafe")))
        // Own danmaku bypass type, keyword and user rules.
        XCTAssertTrue(f.shouldShow(item(3, 0, "bad", mode: 1, midHash: me)))
        let applied = f.apply([item(3, 0, "bad", midHash: me), item(4, 1, "bad", mode: 5)])
        XCTAssertEqual(applied.map(\.id), [3])
        XCTAssertTrue(applied[0].isSelf)
    }

    func testCloudBlockLevel() {
        var s = DanmakuSettings()
        s.cloudBlockLevel = 5
        let f = DanmakuFilter(settings: s)
        XCTAssertFalse(f.shouldShow(item(1, 0, weight: 4)))
        XCTAssertTrue(f.shouldShow(item(2, 0, weight: 5)))
        XCTAssertTrue(f.shouldShow(item(3, 0, weight: 11)))
        s.cloudBlockLevel = 0
        XCTAssertTrue(DanmakuFilter(settings: s).shouldShow(item(4, 0, weight: 0)))
    }

    func testTypeBlocks() {
        var s = DanmakuSettings()
        s.hideAdvanced = false
        var f = DanmakuFilter(settings: s)
        for mode in [1, 4, 5, 7] { XCTAssertTrue(f.shouldShow(item(1, 0, mode: mode)), "mode \(mode)") }
        s.hideScroll = true
        s.hideTop = true
        f = DanmakuFilter(settings: s)
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 1)))
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 2)))
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 6)))
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 5)))
        XCTAssertTrue(f.shouldShow(item(1, 0, mode: 4)))
        XCTAssertTrue(f.shouldShow(item(1, 0, mode: 7)))
        s = DanmakuSettings()
        s.hideBottom = true
        f = DanmakuFilter(settings: s)
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 4)))
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 7)), "advanced hidden by default")
        XCTAssertFalse(f.shouldShow(item(1, 0, mode: 8)))
    }

    func testColorfulBlock() {
        var s = DanmakuSettings()
        s.hideColorful = true
        let f = DanmakuFilter(settings: s)
        XCTAssertTrue(f.shouldShow(item(1, 0, color: 0xFFFFFF)))
        XCTAssertFalse(f.shouldShow(item(2, 0, color: 0xFE0302)))
        var vip = item(3, 0, color: 0xFFFFFF)
        vip.colorful = DanmakuItem.vipGradualColor
        XCTAssertFalse(f.shouldShow(vip))
        XCTAssertTrue(DanmakuFilter(settings: DanmakuSettings()).shouldShow(item(2, 0, color: 0xFE0302)))
    }

    func testFilterFieldsChanged() {
        let a = DanmakuSettings()
        var b = a
        b.opacity = 0.5
        XCTAssertFalse(DanmakuFilter.filterFieldsChanged(a, b))
        b.blockedKeywords = ["x"]
        XCTAssertTrue(DanmakuFilter.filterFieldsChanged(a, b))
    }
}

// MARK: - Merge

final class DanmakuMergeTests: XCTestCase {
    func testMergeWithinWindow() {
        let items = [
            item(1, 1.0, "哈哈哈"),
            item(2, 2.0, " 哈哈哈 "),
            item(3, 3.0, "other"),
            item(4, 5.0, "ＯＴＨＥＲ"),      // full-width + case fold
            item(5, 30.0, "哈哈哈"),         // outside 20 s window → new group
            item(6, 31.0, "哈 哈 哈"),
        ]
        let merged = DanmakuFilter.merge(items, window: 20)
        XCTAssertEqual(merged.map(\.id), [1, 3, 5])
        XCTAssertEqual(merged.map(\.count), [2, 2, 2])
        XCTAssertEqual(merged[0].displayText, "哈哈哈 ×2")
    }

    func testWholeBatchMergeAndSelfNotMerged() {
        var mine = item(3, 2, "a")
        mine.isSelf = true
        let merged = DanmakuFilter.merge([item(1, 0, "a"), item(2, 100, "A"), mine, item(4, 300, "a")], window: 0)
        XCTAssertEqual(merged.map(\.id), [1, 3])
        XCTAssertEqual(merged[0].count, 3)
        XCTAssertEqual(merged[1].count, 1)
    }

    func testApplyMergesOnlyWhenEnabled() {
        var s = DanmakuSettings()
        let items = [item(1, 0, "x"), item(2, 1, "x")]
        XCTAssertEqual(DanmakuFilter(settings: s).apply(items).count, 2)
        s.mergeDuplicates = true
        let merged = DanmakuFilter(settings: s).apply(items)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].count, 2)
        XCTAssertEqual(DanmakuFilter.normalizedContent(" Ａb\u{3000}C "), "abc")
    }
}

// MARK: - Layout

final class DanmakuLayoutTests: XCTestCase {
    private func config(width: Double = 400, height: Double = 404, area: Double = 1.0, track: Double = 24,
                        duration: Double = 4) -> DanmakuLayoutConfig {
        var c = DanmakuLayoutConfig()
        c.viewWidth = width
        c.viewHeight = height
        c.areaFraction = area
        c.trackHeight = track
        c.topInset = 4
        c.scrollDuration = duration
        c.staticDuration = 4
        return c
    }

    func testTrackCountPerArea() {
        // Usable height 400, track 24.
        XCTAssertEqual(config(area: 0.25).trackCount, 4)
        XCTAssertEqual(config(area: 0.5).trackCount, 8)
        XCTAssertEqual(config(area: 0.75).trackCount, 12)
        XCTAssertEqual(config(area: 1.0).trackCount, 15)   // 16 − 1 (room for subtitles)
        // Exact divisions are not lost to floating point.
        XCTAssertEqual(config(area: 0.25, track: 25).trackCount, 4)
        XCTAssertEqual(config(area: 1.0, track: 25).trackCount, 15)
        for area in DanmakuArea.allCases {
            XCTAssertEqual(config(area: area.rawValue, track: 25).trackCount,
                           area == .full ? 15 : Int(400 * area.rawValue / 25))
        }
        XCTAssertEqual(config(height: 30, area: 1.0).trackCount, 1)
        XCTAssertEqual(config(height: 10).trackCount, 0)
        XCTAssertEqual(config().trackY(2), 52)
    }

    func testPositionFormula() {
        var engine = DanmakuLayoutEngine(config: config(duration: 4))
        let p = engine.place(kind: .scroll, width: 100, at: 10)!
        XCTAssertEqual(p.x(at: 10), 400)
        XCTAssertEqual(p.x(at: 12), 400 - 2.0 / 4 * 500, accuracy: 1e-9)
        XCTAssertEqual(p.x(at: 14), -100, accuracy: 1e-9)
        XCTAssertEqual(p.endTime, 14, accuracy: 1e-9)
        XCTAssertFalse(p.isExpired(at: 13.99))
        XCTAssertTrue(p.isExpired(at: 14))
    }

    func testCatchUpRuleMatchesReferenceFormula() {
        let c = config(duration: 4)
        let lastV = c.scrollVelocity(width: 50)
        let last = DanmakuPlacement(kind: .scroll, track: 0, startTime: 0, width: 50, originX: 400,
                                    velocity: lastV, endTime: 450 / lastV, overlapped: false)
        let newV = c.scrollVelocity(width: 300)
        for t in stride(from: 0.0, through: 4.0, by: 0.05) {
            let x = last.x(at: t)
            let reference = (x + 50 <= 400) && ((x + 50) * 300 <= 400 * (400 - x) || x + 50 <= 0)
            XCTAssertEqual(DanmakuLayoutEngine.canFollow(last, newWidth: 300, newVelocity: newV, at: t, viewWidth: 400),
                           reference, "t=\(t)")
        }
        XCTAssertFalse(DanmakuLayoutEngine.canFollow(last, newWidth: 300, newVelocity: newV, at: 1, viewWidth: 400))
        XCTAssertTrue(DanmakuLayoutEngine.canFollow(last, newWidth: 300, newVelocity: newV, at: 2.5, viewWidth: 400))
        // A slower (narrower) follower only needs the previous one to have fully entered.
        let slowV = c.scrollVelocity(width: 20)
        XCTAssertTrue(DanmakuLayoutEngine.canFollow(last, newWidth: 20, newVelocity: slowV, at: 0.45, viewWidth: 400))
        XCTAssertFalse(DanmakuLayoutEngine.canFollow(last, newWidth: 20, newVelocity: slowV, at: 0.3, viewWidth: 400))
    }

    /// Simulates a dense stream and checks that no two items in a scroll track ever overlap.
    func testNoOverlapInTrackUnderCatchUpRule() {
        for fixed in [false, true] {
            var c = config(area: 0.5, duration: 5)
            c.fixedVelocity = fixed
            var engine = DanmakuLayoutEngine(config: c)
            var seed: UInt64 = 12345
            func rnd() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            var placed: [DanmakuPlacement] = []
            var dropped = 0
            var t = 0.0
            for _ in 0..<600 {
                t += rnd() * 0.08
                let w = 20 + rnd() * 300
                if let p = engine.place(kind: .scroll, width: w, at: t) {
                    XCTAssertFalse(p.overlapped)
                    placed.append(p)
                } else {
                    dropped += 1
                }
            }
            XCTAssertGreaterThan(placed.count, 50)
            XCTAssertGreaterThan(dropped, 0, "stream should be dense enough to drop some")
            let byTrack = Dictionary(grouping: placed, by: \.track)
            for (_, list) in byTrack {
                for (a, b) in zip(list, list.dropFirst()) {
                    // b follows a in the same track; sample their common lifetime.
                    var s = b.startTime
                    while s < min(a.endTime, b.endTime) {
                        let aTail = a.x(at: s) + a.width
                        let bHead = b.x(at: s)
                        XCTAssertGreaterThanOrEqual(bHead + 1e-6, aTail, "overlap fixed=\(fixed) at \(s)")
                        s += 0.01
                    }
                }
            }
        }
    }

    func testDropVersusOverlapLeastRecentlyUsed() {
        var c = config(height: 4 + 4 * 24, area: 0.75, duration: 4)   // exactly 3 tracks
        XCTAssertEqual(c.trackCount, 3)
        var engine = DanmakuLayoutEngine(config: c)
        for i in 0..<3 { XCTAssertEqual(engine.place(kind: .scroll, width: 100, at: 0)?.track, i) }
        XCTAssertNil(engine.place(kind: .scroll, width: 100, at: 0.01))

        c.allowOverlap = true
        engine = DanmakuLayoutEngine(config: c)
        for i in 0..<3 { XCTAssertEqual(engine.place(kind: .scroll, width: 100, at: 0)?.track, i) }
        let o1 = engine.place(kind: .scroll, width: 100, at: 0.01)
        let o2 = engine.place(kind: .scroll, width: 100, at: 0.02)
        let o3 = engine.place(kind: .scroll, width: 100, at: 0.03)
        let o4 = engine.place(kind: .scroll, width: 100, at: 0.04)
        XCTAssertEqual([o1?.track, o2?.track, o3?.track, o4?.track], [0, 1, 2, 0])
        XCTAssertEqual(o1?.overlapped, true)

        // Own danmaku without a free track go to track 0 even without 海量弹幕.
        c.allowOverlap = false
        engine = DanmakuLayoutEngine(config: c)
        for _ in 0..<3 { _ = engine.place(kind: .scroll, width: 100, at: 0) }
        let mine = engine.place(kind: .scroll, width: 100, at: 0.01, isSelf: true)
        XCTAssertEqual(mine?.track, 0)
        XCTAssertEqual(mine?.overlapped, true)
    }

    func testStaticTopFromTopBottomFromBottom() {
        var engine = DanmakuLayoutEngine(config: config(area: 0.25, duration: 4))   // 4 tracks
        XCTAssertEqual(engine.trackCount, 4)
        XCTAssertEqual(engine.place(kind: .bottom, width: 80, at: 0)?.track, 3)
        XCTAssertEqual(engine.place(kind: .bottom, width: 80, at: 0)?.track, 2)
        XCTAssertEqual(engine.place(kind: .top, width: 80, at: 0)?.track, 0)
        XCTAssertEqual(engine.place(kind: .top, width: 80, at: 0)?.track, 1)
        XCTAssertNil(engine.place(kind: .top, width: 80, at: 1))      // all 4 busy, one per track
        XCTAssertNil(engine.place(kind: .bottom, width: 80, at: 3.9))
        // After the static duration the lanes are free again.
        let p = engine.place(kind: .bottom, width: 80, at: 4.0)
        XCTAssertEqual(p?.track, 3)
        XCTAssertEqual(p?.x(at: 5), 160)        // centred: (400 − 80) / 2
        XCTAssertEqual(p?.endTime, 8)
        // Clearing one kind frees only its lanes.
        engine.clear(kind: .top)
        XCTAssertEqual(engine.place(kind: .top, width: 80, at: 4.1)?.track, 0)
    }

    func testStaticToScroll() {
        var c = config(area: 0.25, duration: 4)
        c.static2Scroll = true
        var engine = DanmakuLayoutEngine(config: c)
        for _ in 0..<4 { XCTAssertEqual(engine.place(kind: .top, width: 80, at: 0)?.kind, .top) }
        let converted = engine.place(kind: .top, width: 80, at: 0.5)
        XCTAssertEqual(converted?.kind, .scroll)
        let wide = engine.place(kind: .bottom, width: 500, at: 5)
        XCTAssertEqual(wide?.kind, .scroll, "wider than the view → scroll")
        c.static2Scroll = false
        engine = DanmakuLayoutEngine(config: c)
        XCTAssertEqual(engine.place(kind: .bottom, width: 500, at: 5)?.kind, .bottom)
    }

    func testDeterminismAndReconfigure() {
        func run() -> [DanmakuPlacement?] {
            var c = config(area: 0.5, duration: 6)
            c.allowOverlap = true
            var engine = DanmakuLayoutEngine(config: c)
            var out: [DanmakuPlacement?] = []
            for i in 0..<300 {
                let kind: DanmakuTrackKind = i % 7 == 0 ? .top : (i % 11 == 0 ? .bottom : .scroll)
                out.append(engine.place(kind: kind, width: Double(30 + (i * 37) % 250), at: Double(i) * 0.05))
            }
            return out
        }
        XCTAssertEqual(run(), run())

        var engine = DanmakuLayoutEngine(config: config(area: 0.5))
        _ = engine.place(kind: .scroll, width: 100, at: 0)
        var c2 = config(area: 0.5)
        c2.scrollDuration = 9
        XCTAssertFalse(engine.reconfigure(c2), "duration change keeps lanes")
        XCTAssertEqual(engine.place(kind: .scroll, width: 100, at: 0.01)?.track, 1)
        XCTAssertTrue(engine.reconfigure(config(area: 0.25)), "area change resets lanes")
        XCTAssertEqual(engine.trackCount, 4)
        XCTAssertEqual(engine.place(kind: .scroll, width: 100, at: 0.02)?.track, 0)
        var empty = DanmakuLayoutEngine(config: config(height: 0))
        XCTAssertNil(empty.place(kind: .scroll, width: 10, at: 0))
    }
}

// MARK: - Segment loader

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    private var allCount = 0
    var failSegments: Set<Int> = []
    func hit(_ i: Int) -> Int { lock.lock(); defer { lock.unlock() }; counts[i, default: 0] += 1; return counts[i]! }
    func count(_ i: Int) -> Int { lock.lock(); defer { lock.unlock() }; return counts[i, default: 0] }
    func hitAll() { lock.lock(); allCount += 1; lock.unlock() }
    var all: Int { lock.lock(); defer { lock.unlock() }; return allCount }
}

final class DanmakuSegmentLoaderTests: XCTestCase {
    func testSegmentsToLoad() {
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 10, duration: 1000, afterSeek: false), [1])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 335, duration: 1000, afterSeek: false), [1, 2])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 335, duration: 350, afterSeek: false), [1])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 335, duration: 0, afterSeek: false), [1, 2])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 365, duration: 1000, afterSeek: true), [2, 1])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 365, duration: 1000, afterSeek: false), [2])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 400, duration: 1000, afterSeek: true), [2])
        XCTAssertEqual(DanmakuSegmentLoader.segmentsToLoad(time: 5, duration: 1000, afterSeek: true), [1])
    }

    func testLoadCachesDedupesAndRetries() async {
        let counter = FetchCounter()
        counter.failSegments = [2]
        let loader = DanmakuSegmentLoader(cid: 1, aid: 2, duration: 1000, fetchSegment: { index in
            let n = counter.hit(index)
            try await Task.sleep(nanoseconds: 20_000_000)
            if counter.failSegments.contains(index), n == 1 { throw BiliError.http(status: 500) }
            let base = DanmakuSegment.range(of: index).lowerBound
            return DanmakuSegmentReply(items: [
                DanmakuItem(id: Int64(index * 10 + 2), time: base + 20, content: "b"),
                DanmakuItem(id: Int64(index * 10 + 1), time: base + 10, content: "a"),
            ], state: index == 3 ? 1 : 0)
        })
        async let a = loader.load(segment: 1)
        async let b = loader.load(segment: 1)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra?.map(\.id), [11, 12], "sorted by time")
        XCTAssertEqual(rb?.map(\.id), [11, 12])
        XCTAssertEqual(counter.count(1), 1, "concurrent loads share one request")
        _ = await loader.load(segment: 1)
        XCTAssertEqual(counter.count(1), 1, "cached")

        let failed = await loader.load(segment: 2)
        XCTAssertNil(failed, "no fallback configured → nil, retry later")
        let retried = await loader.load(segment: 2)
        XCTAssertEqual(retried?.count, 2)
        XCTAssertEqual(counter.count(2), 2)

        let closedBefore = await loader.isClosed
        XCTAssertFalse(closedBefore)
        _ = await loader.load(segment: 3)
        let closedAfter = await loader.isClosed
        XCTAssertTrue(closedAfter)

        let window = await loader.items(from: 365, to: 375)
        XCTAssertEqual(window.map(\.id), [21])
        let all = await loader.allLoadedItems()
        XCTAssertEqual(all.map(\.id), [11, 12, 21, 22, 31, 32])
    }

    func testXMLFallbackSlicesIntoSegments() async {
        let counter = FetchCounter()
        let loader = DanmakuSegmentLoader(cid: 1, aid: 2, duration: 1000, fetchSegment: { _ in
            throw BiliError.http(status: 412)
        }, fetchAll: {
            counter.hitAll()
            return [
                DanmakuItem(id: 3, time: 400, content: "c"),
                DanmakuItem(id: 1, time: 5, content: "a"),
                DanmakuItem(id: 2, time: 359.9, content: "b"),
            ]
        })
        let s1 = await loader.load(segment: 1)
        let s2 = await loader.load(segment: 2)
        let s3 = await loader.load(segment: 3)
        XCTAssertEqual(s1?.map(\.id), [1, 2])
        XCTAssertEqual(s2?.map(\.id), [3])
        XCTAssertEqual(s3?.map(\.id), [])
        XCTAssertEqual(counter.all, 1, "the XML list is fetched once")
    }

    func testCloudRuleMerge() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["dup"]
        let added = DanmakuCloudRule.merge([
            DanmakuCloudRule(id: 1, type: 0, filter: "dup"),
            DanmakuCloudRule(id: 2, type: 0, filter: "new"),
            DanmakuCloudRule(id: 3, type: 1, filter: "a+b"),
            DanmakuCloudRule(id: 4, type: 1, filter: "/c+/"),
            DanmakuCloudRule(id: 5, type: 2, filter: "ABCD"),
        ], into: &s)
        XCTAssertEqual(added, 4)
        XCTAssertEqual(s.blockedKeywords, ["dup", "new", "/a+b/", "/c+/"])
        XCTAssertEqual(s.blockedUsers, ["abcd"])
    }
}
