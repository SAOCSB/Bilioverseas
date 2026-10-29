import XCTest
@testable import BiliCore

/// 「播放顺序」 migration from the older 「自动连播」 switch and the new player defaults.
final class PlayerSettingsTests: XCTestCase {
    private let suiteName = "PlayerSettingsTests"

    private func load(_ saved: [String: Any]?) throws -> PlayerSettings {
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let old = SettingsStore.defaults
        SettingsStore.defaults = suite
        defer {
            SettingsStore.defaults = old
            suite.removePersistentDomain(forName: suiteName)
        }
        if let saved { suite.set(try JSONSerialization.data(withJSONObject: saved), forKey: "settings.player") }
        return SettingsStore.load(key: "settings.player")
    }

    func testFreshInstallKeepsAutoPlayingNext() throws {
        let s = try load(nil)
        XCTAssertNil(s.playRepeatChoice)
        XCTAssertEqual(s.playRepeat, .autoPlayRelated)
        XCTAssertEqual(s.pgcSkipType, .skipOnce)
    }

    func testOlderSaveWithAutoNextOffMeansPauseAtTheEnd() throws {
        XCTAssertEqual(try load(["autoNext": false]).playRepeat, .pause)
        XCTAssertEqual(try load(["autoNext": true]).playRepeat, .autoPlayRelated)
    }

    func testChosenModeRoundTripsAndKeepsAutoNextInSync() throws {
        var s = PlayerSettings()
        s.playRepeat = .singleCycle
        XCTAssertTrue(s.autoNext)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        let back = try load(json)
        XCTAssertEqual(back.playRepeat, .singleCycle)
        s.playRepeat = .pause
        XCTAssertFalse(s.autoNext)
        XCTAssertEqual(s.playRepeat, .pause)
    }

    func testUnsetChoiceIsNotWrittenSoNewDefaultsStillApply() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlayerSettings())) as? [String: Any])
        XCTAssertNil(json["playRepeatChoice"])
        XCTAssertEqual(json["pgcSkipType"] as? String, "skipOnce")
    }
}
