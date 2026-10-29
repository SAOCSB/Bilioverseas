import XCTest
@testable import BiliCore

// MARK: - 高级弹幕 (mode 7)

final class DanmakuAdvancedSpecTests: XCTestCase {
    func testFullArrayWithMoveFadeAndRotation() throws {
        let spec = try XCTUnwrap(DanmakuAdvancedSpec.parse(
            #"[0.1,0.2,"1-0.5",4,"前方/n高能",30,0,0.5,0.6,1000,500,1,"黑体",1]"#))
        XCTAssertEqual(spec.startX, 0.1)
        XCTAssertEqual(spec.startY, 0.2)
        XCTAssertEqual(spec.endX, 0.5)
        XCTAssertEqual(spec.endY, 0.6)
        XCTAssertEqual(spec.startAlpha, 1)
        XCTAssertEqual(spec.endAlpha, 0.5)
        XCTAssertEqual(spec.duration, 4)
        XCTAssertEqual(spec.text, "前方\n高能")
        XCTAssertEqual(spec.rotateZ, 30)
        XCTAssertEqual(spec.moveDuration, 1)
        XCTAssertEqual(spec.moveDelay, 0.5)
        XCTAssertTrue(spec.hasStroke)
        XCTAssertTrue(spec.easeIn)

        // Waits for the delay, then eases in (cubic) to the end point and stays there.
        XCTAssertEqual(spec.position(at: 0.4).x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(spec.position(at: 1.0).x, 0.1 + 0.4 * 0.125, accuracy: 1e-9)
        XCTAssertEqual(spec.position(at: 3).y, 0.6, accuracy: 1e-9)
        XCTAssertEqual(spec.alpha(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(spec.alpha(at: 2), 0.75, accuracy: 1e-9)
        XCTAssertEqual(spec.alpha(at: 10), 0.5, accuracy: 1e-9)
    }

    func testMinimalArrayAndPixelCoordinates() throws {
        // Strings, pixel coordinates of the 682 × 438 reference player, no move fields.
        let spec = try XCTUnwrap(DanmakuAdvancedSpec.parse(#"["341","219","0.8",2.5,"居中"]"#))
        XCTAssertEqual(spec.startX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(spec.startY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(spec.endX, spec.startX)
        XCTAssertFalse(spec.isMoving)
        XCTAssertEqual(spec.startAlpha, 0.8)
        XCTAssertEqual(spec.endAlpha, 0.8)
        XCTAssertEqual(spec.moveDuration, 2.5, "no move duration: the whole lifetime")
        XCTAssertTrue(spec.hasStroke)
        XCTAssertFalse(spec.easeIn)
        XCTAssertEqual(spec.position(at: 1).x, 0.5, accuracy: 1e-9)

        // A decimal string is a fraction, a number above 1 is pixels.
        let mixed = try XCTUnwrap(DanmakuAdvancedSpec.parse(#"["0.25",682,"1-1",3,"a",0,0,"0.75",0,0,0,0]"#))
        XCTAssertEqual(mixed.startX, 0.25)
        XCTAssertEqual(mixed.startY, 682 / 438, accuracy: 1e-9)
        XCTAssertEqual(mixed.endX, 0.75)
        XCTAssertEqual(mixed.moveDuration, 3, "a zero move duration spans the lifetime")
        XCTAssertFalse(mixed.hasStroke)
    }

    func testRawLineBreaksAndInvalidContent() throws {
        let spec = try XCTUnwrap(DanmakuAdvancedSpec.parse("[0,0,\"1-0\",3,\"第一行\n第二行\"]"))
        XCTAssertEqual(spec.text, "第一行\n第二行")
        XCTAssertEqual(spec.endAlpha, 0)

        XCTAssertNil(DanmakuAdvancedSpec.parse("普通弹幕"))
        XCTAssertNil(DanmakuAdvancedSpec.parse("[0,0,\"1-1\",3]"), "no text element")
        XCTAssertNil(DanmakuAdvancedSpec.parse("[0,0,\"1-1\",3,\"  \"]"), "blank text")
        XCTAssertNil(DanmakuAdvancedSpec.parse("[\"x\",0,\"1-1\",3,\"a\"]"), "non-numeric x")
        XCTAssertNil(DanmakuAdvancedSpec.parse("[0,0,"), "broken JSON")
        let noDuration = try XCTUnwrap(DanmakuAdvancedSpec.parse("[0,0,\"1-1\",\"\",\"a\"]"))
        XCTAssertEqual(noDuration.duration, DanmakuAdvancedSpec.defaultDuration)
    }

    func testHostileNumbersStayFinite() throws {
        // Huge coordinates (also negative "fractions") and angles: × the view size or × π they would overflow to an
        // infinite layer position or a NaN transform in the renderer.
        let spec = try XCTUnwrap(DanmakuAdvancedSpec.parse(
            #"[-1e308,1e308,"1-0",1e308,"a",1e308,-1e308,1.7e308,-1.7e308,1e308,1e308,1,0,1]"#))
        let limit = DanmakuAdvancedSpec.coordinateLimit
        XCTAssertEqual(spec.startX, -limit)
        XCTAssertEqual(spec.startY, limit)
        XCTAssertEqual(spec.endX, limit)
        XCTAssertEqual(spec.endY, -limit)
        XCTAssertTrue(spec.rotateZ.isFinite && abs(spec.rotateZ) < 360)
        XCTAssertTrue(spec.rotateY.isFinite && abs(spec.rotateY) < 360)
        XCTAssertTrue((spec.rotateZ * .pi / 180).isFinite)
        for t in [0, 1, 1e300] {
            let p = spec.position(at: t)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && (p.x * 3000 * 3).isFinite, "t = \(t)")
            XCTAssertTrue(spec.alpha(at: t).isFinite)
        }
        // NaN / infinity spelled as strings, short arrays and wrong element types.
        XCTAssertNil(DanmakuAdvancedSpec.parse(#"["nan",0,"1-1",3,"a"]"#))
        XCTAssertNil(DanmakuAdvancedSpec.parse(#"[0,"inf","1-1",3,"a"]"#))
        let odd = try XCTUnwrap(DanmakuAdvancedSpec.parse(#"[0,0,"nan-inf","inf","a","nan","inf","nan",{},[],null,"x"]"#))
        XCTAssertEqual(odd.startAlpha, 1)
        XCTAssertEqual(odd.endAlpha, 1)
        XCTAssertEqual(odd.duration, DanmakuAdvancedSpec.defaultDuration)
        XCTAssertEqual(odd.rotateZ, 0)
        XCTAssertEqual(odd.rotateY, 0)
        XCTAssertFalse(odd.isMoving)
        XCTAssertNil(DanmakuAdvancedSpec.parse("[]"))
        XCTAssertNil(DanmakuAdvancedSpec.parse("[0,0,{},[],{}]"))
    }

    func testReadableText() {
        let advanced = DanmakuItem(id: 1, time: 0, mode: 7, content: #"[0.1,0.1,"1-1",3,"你好"]"#)
        XCTAssertEqual(advanced.readableText, "你好")
        XCTAssertEqual(DanmakuItem(id: 2, time: 0, content: "[普通]").readableText, "[普通]")
        XCTAssertTrue(advanced.hasServerID)
        XCTAssertFalse(DanmakuItem(id: -1, time: 0, content: "local").hasServerID)
    }
}

// MARK: - 跳转 timestamps

final class DanmakuTimestampTests: XCTestCase {
    func testMinutesSecondsAndHours() {
        XCTAssertEqual(DanmakuTimestamp.seconds(in: "3:25 高能", duration: 600), 205)
        XCTAssertEqual(DanmakuTimestamp.seconds(in: "空降 12：05", duration: 1000), 725)
        XCTAssertEqual(DanmakuTimestamp.seconds(in: "1:02:03", duration: 4000), 3723)
        XCTAssertEqual(DanmakuTimestamp.seconds(in: "看 0:59", duration: 0), 59, "unknown duration accepts any time")
    }

    func testOutOfRangeAndNonTimestamps() {
        XCTAssertNil(DanmakuTimestamp.seconds(in: "10:00", duration: 300), "past the end")
        XCTAssertNil(DanmakuTimestamp.seconds(in: "0:00", duration: 300), "zero")
        XCTAssertNil(DanmakuTimestamp.seconds(in: "比分 2:345", duration: 3000), "seconds must be two digits at most")
        XCTAssertNil(DanmakuTimestamp.seconds(in: "没有时间", duration: 300))
        XCTAssertNil(DanmakuTimestamp.seconds(in: "3:75", duration: 3000), "75 is not a seconds field")
    }
}

// MARK: - Account-synced block rules

final class DanmakuCloudSyncTests: XCTestCase {
    func testMergeRemembersIdsIncludingExistingRules() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["dup"]
        s.blockedUsers = ["abcd"]
        let added = DanmakuCloudRule.merge([
            DanmakuCloudRule(id: 1, type: 0, filter: "dup"),
            DanmakuCloudRule(id: 3, type: 1, filter: "a+b"),
            DanmakuCloudRule(id: 5, type: 2, filter: "ABCD"),
            DanmakuCloudRule(id: 6, type: 2, filter: "beef"),
        ], into: &s)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(s.cloudRuleIds, ["dup": 1, "/a+b/": 3])
        XCTAssertEqual(s.cloudUserRuleIds, ["abcd": 5, "beef": 6])
    }

    func testCloudFormAndPendingUploads() {
        XCTAssertEqual(DanmakuCloudRule.cloudForm(keyword: "剧透").type, 0)
        XCTAssertEqual(DanmakuCloudRule.cloudForm(keyword: "剧透").filter, "剧透")
        XCTAssertEqual(DanmakuCloudRule.cloudForm(keyword: "/^哈+$/").type, 1)
        XCTAssertEqual(DanmakuCloudRule.cloudForm(keyword: "/^哈+$/").filter, "^哈+$")

        var s = DanmakuSettings()
        s.blockedKeywords = ["synced", "local", "/re/"]
        s.blockedUsers = ["abcd", "beef"]
        s.cloudRuleIds = ["synced": 9]
        s.cloudUserRuleIds = ["abcd": 10]
        let pending = DanmakuCloudRule.pendingUploads(s)
        XCTAssertEqual(pending.map(\.rule), ["local", "/re/", "beef"])
        XCTAssertEqual(pending.map(\.type), [0, 1, 2])
        XCTAssertEqual(pending.map(\.filter), ["local", "re", "beef"])
    }

    func testRemoveBlockRulesReturnsServerIds() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["a", "b", "/c/"]
        s.blockedUsers = ["abcd", "beef"]
        s.blockedUserLabels = ["abcd": "123"]
        s.cloudRuleIds = ["a": 1, "/c/": 3]
        s.cloudUserRuleIds = ["abcd": 4]
        let ids = s.removeBlockRules(keywords: ["a", "b"], users: ["abcd"])
        XCTAssertEqual(Set(ids), [1, 4])
        XCTAssertEqual(s.blockedKeywords, ["/c/"])
        XCTAssertEqual(s.blockedUsers, ["beef"])
        XCTAssertTrue(s.blockedUserLabels.isEmpty)
        XCTAssertEqual(s.cloudRuleIds, ["/c/": 3])
        XCTAssertTrue(s.cloudUserRuleIds.isEmpty)

        // The ids survive 「恢复默认设置」 like the rules themselves.
        s.resetDisplayOptions()
        XCTAssertEqual(s.cloudRuleIds, ["/c/": 3])
    }

    func testServerIdsBelongToOneAccount() {
        var s = DanmakuSettings()
        s.blockedKeywords = ["a", "b"]
        s.blockedUsers = ["abcd"]
        s.cloudRuleIds = ["a": 1]
        s.cloudUserRuleIds = ["abcd": 2]
        s.claimCloudRuleIds(for: 0)
        XCTAssertEqual(s.cloudRulesMid, 0, "logged out: nothing to claim")
        s.claimCloudRuleIds(for: 100)
        XCTAssertEqual(s.cloudRulesMid, 100, "ids without an owner are adopted")
        XCTAssertEqual(s.cloudRuleIds, ["a": 1])
        s.claimCloudRuleIds(for: 100)
        XCTAssertEqual(s.cloudUserRuleIds, ["abcd": 2])
        s.resetDisplayOptions()
        XCTAssertEqual(s.cloudRulesMid, 100)

        // Logged in as another account: the first account's ids are dropped, so its rules upload to this one.
        s.claimCloudRuleIds(for: 200)
        XCTAssertEqual(s.cloudRulesMid, 200)
        XCTAssertTrue(s.cloudRuleIds.isEmpty && s.cloudUserRuleIds.isEmpty)
        XCTAssertEqual(s.blockedKeywords, ["a", "b"])
        XCTAssertEqual(DanmakuCloudRule.pendingUploads(s).map(\.rule), ["a", "b", "abcd"])
    }

    func testNewFieldsDecodeFromOlderSaves() throws {
        // A save from before `tapToInteract` / the id maps existed.
        let defaults = UserDefaults(suiteName: "DanmakuCloudSyncTests") ?? .standard
        let previous = SettingsStore.defaults
        SettingsStore.defaults = defaults
        defer {
            defaults.removeObject(forKey: "test.danmaku")
            SettingsStore.defaults = previous
        }
        defaults.set(Data(#"{"enabled":false,"blockedKeywords":["x"]}"#.utf8), forKey: "test.danmaku")
        let loaded: DanmakuSettings = SettingsStore.load(key: "test.danmaku")
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.blockedKeywords, ["x"])
        XCTAssertTrue(loaded.tapToInteract)
        XCTAssertFalse(loaded.hideAdvanced)
        XCTAssertTrue(loaded.cloudRuleIds.isEmpty)
    }
}
