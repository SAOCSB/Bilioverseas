import XCTest
@testable import BiliCore

/// Gesture switches, 画面比例 and 字幕设置 fields of `PlayerSettings` (features.md §1.5–1.6, §3.6, §3.7, §13).
final class PlayerDisplaySettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let s = PlayerSettings()
        XCTAssertTrue(s.slideVolumeBrightness)
        XCTAssertTrue(s.slideFullscreen)
        XCTAssertEqual(s.slideSeekSeconds, 90)
        XCTAssertEqual(s.aspectMode, "fit")
        XCTAssertEqual(s.subtitleFontScale, 1.0)
        XCTAssertEqual(s.subtitleFontScaleFullscreen, 1.5)
        XCTAssertEqual(s.subtitleFontWeight, 5)
        XCTAssertEqual(s.subtitleStrokeWidth, 2.0)
        XCTAssertEqual(s.subtitlePaddingH, 24)
        XCTAssertEqual(s.subtitleBottomPadding, 24)
        XCTAssertEqual(s.subtitleBgOpacity, 0.67)
    }

    func testOlderSavesGetTheNewDefaults() {
        let defaults = UserDefaults(suiteName: "PlayerDisplaySettingsTests") ?? .standard
        let previous = SettingsStore.defaults
        SettingsStore.defaults = defaults
        defer {
            defaults.removeObject(forKey: "test.player")
            SettingsStore.defaults = previous
        }
        defaults.set(Data(#"{"longPressSpeed":3,"seekStep":15}"#.utf8), forKey: "test.player")
        let loaded: PlayerSettings = SettingsStore.load(key: "test.player")
        XCTAssertEqual(loaded.longPressSpeed, 3)
        XCTAssertEqual(loaded.seekStep, 15)
        XCTAssertTrue(loaded.slideFullscreen)
        XCTAssertEqual(loaded.slideSeekSeconds, 90)
        XCTAssertEqual(loaded.aspectMode, "fit")
        XCTAssertEqual(loaded.subtitleBgOpacity, 0.67)
    }
}
