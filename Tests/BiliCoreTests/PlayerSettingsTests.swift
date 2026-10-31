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

    func testVerticalVideosFollowTheCacheRouteByDefault() throws {
        var s = AccelerationSettings()
        XCTAssertEqual(s.cdnMode, .auto)
        XCTAssertFalse(s.verticalVideosDirect)
        XCTAssertTrue(s.accelerates(pgc: false, vertical: true))
        XCTAssertTrue(s.accelerates(pgc: false, vertical: false))
        XCTAssertTrue(s.accelerates(pgc: true, vertical: false))

        s.verticalVideosDirect = true
        XCTAssertFalse(s.accelerates(pgc: false, vertical: true))
        XCTAssertFalse(s.accelerates(pgc: true, vertical: true))
        s.verticalVideosDirect = false
        XCTAssertTrue(s.accelerates(pgc: false, vertical: true))
        s.accelerateBangumi = false
        XCTAssertFalse(s.accelerates(pgc: true, vertical: true))
        XCTAssertTrue(s.accelerates(pgc: false, vertical: true))
        s.enabled = false
        XCTAssertFalse(s.accelerates(pgc: false, vertical: false))
        XCTAssertFalse(s.accelerates(pgc: false, vertical: true))
    }

    func testSettingsSavedBeforeTheSwitchExistedGetItsDefault() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let old = SettingsStore.defaults
        SettingsStore.defaults = suite
        defer {
            SettingsStore.defaults = old
            suite.removePersistentDomain(forName: suiteName)
        }
        suite.set(try JSONSerialization.data(withJSONObject: ["enabled": true, "manualConcurrency": 8]),
                  forKey: "settings.acceleration")
        let s: AccelerationSettings = SettingsStore.load(key: "settings.acceleration")
        XCTAssertEqual(s.manualConcurrency, 8)
        XCTAssertFalse(s.verticalVideosDirect)
        XCTAssertEqual(s.cdnMode, .auto)
    }

    func testCacheRouteIsAdoptedOnceOverOldDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let old = SettingsStore.defaults
        SettingsStore.defaults = suite
        defer {
            SettingsStore.defaults = old
            suite.removePersistentDomain(forName: suiteName)
        }
        suite.set(try JSONSerialization.data(withJSONObject: ["cdnMode": "mainland", "verticalVideosDirect": true,
                                                              "manualConcurrency": 8]),
                  forKey: "settings.acceleration")
        let first = AppSettings()
        XCTAssertEqual(first.acceleration.cdnMode, .auto)
        XCTAssertFalse(first.acceleration.verticalVideosDirect)
        XCTAssertEqual(first.acceleration.manualConcurrency, 8, "what was chosen stays")

        // Choosing the old values afterwards sticks.
        first.acceleration.cdnMode = .mainland
        first.acceleration.verticalVideosDirect = true
        let second = AppSettings()
        XCTAssertEqual(second.acceleration.cdnMode, .mainland)
        XCTAssertTrue(second.acceleration.verticalVideosDirect)
    }

    func testAdoptingTheCacheRouteKeepsAnotherChosenMode() {
        var s = AccelerationSettings()
        s.verticalVideosDirect = true
        s.cdnMode = .original
        XCTAssertEqual(s.adoptingCacheRoute().cdnMode, .original)
        XCTAssertTrue(s.adoptingCacheRoute().verticalVideosDirect, "no cache route to replace it there")
        s.cdnMode = .custom
        XCTAssertEqual(s.adoptingCacheRoute().cdnMode, .custom)
    }

    func testFreshInstallIsNotRewrittenByTheAdoption() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let old = SettingsStore.defaults
        SettingsStore.defaults = suite
        defer {
            SettingsStore.defaults = old
            suite.removePersistentDomain(forName: suiteName)
        }
        _ = AppSettings()
        XCTAssertNil(suite.data(forKey: "settings.acceleration"))
    }

    func testFreshInstallKeepsAutoPlayingNext() throws {
        let s = try load(nil)
        XCTAssertNil(s.playRepeatChoice)
        XCTAssertEqual(s.playRepeat, .autoPlayRelated)
        XCTAssertEqual(s.pgcSkipType, .skipOnce)
    }

    func testThinProgressLineIsHiddenInFullscreenByDefault() throws {
        // Saves from before the setting existed get the default too.
        XCTAssertEqual(try load(["autoNext": true]).thinProgressMode, .hiddenInFullscreen)
        XCTAssertEqual(try load(nil).thinProgressMode, .hiddenInFullscreen)
        XCTAssertEqual(try load(["thinProgressMode": "always"]).thinProgressMode, .always)

        XCTAssertTrue(ThinProgressMode.hiddenInFullscreen.shows(fullscreen: false))
        XCTAssertFalse(ThinProgressMode.hiddenInFullscreen.shows(fullscreen: true))
        XCTAssertTrue(ThinProgressMode.always.shows(fullscreen: true))
        XCTAssertFalse(ThinProgressMode.never.shows(fullscreen: false))
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
