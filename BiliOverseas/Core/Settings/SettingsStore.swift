import Foundation
import Combine

/// A persisted group of settings. New fields only need a default value: stored JSON is
/// deep-merged over the defaults before decoding, so older saves keep working.
protocol SettingsGroup: Codable, Equatable {
    init()
}

enum SettingsStore {
    static var defaults: UserDefaults = .standard

    static func load<T: SettingsGroup>(_ type: T.Type = T.self, key: String) -> T {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(T()),
              let base = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return T() }
        let merged = deepMerge(base, saved)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let value = try? JSONDecoder().decode(T.self, from: mergedData)
        else { return T() }
        return value
    }

    static func save<T: SettingsGroup>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in overlay {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = deepMerge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }
}

/// Single source of truth for every user preference. Observe it from SwiftUI with
/// `@ObservedObject var settings = AppSettings.shared`; non-UI code reads `AppSettings.shared.x`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var general: GeneralSettings { didSet { SettingsStore.save(general, key: "settings.general") } }
    @Published var acceleration: AccelerationSettings {
        didSet {
            SettingsStore.save(acceleration, key: "settings.acceleration")
            NotificationCenter.default.post(name: Self.accelerationDidChange, object: self)
        }
    }
    @Published var player: PlayerSettings { didSet { SettingsStore.save(player, key: "settings.player") } }
    @Published var danmaku: DanmakuSettings { didSet { SettingsStore.save(danmaku, key: "settings.danmaku") } }
    @Published var smartSkip: SmartSkipSettings { didSet { SettingsStore.save(smartSkip, key: "settings.smartSkip") } }
    @Published var feedFilter: FeedFilterSettings { didSet { SettingsStore.save(feedFilter, key: "settings.feedFilter") } }

    init() {
        general = SettingsStore.load(key: "settings.general")
        acceleration = SettingsStore.load(key: "settings.acceleration")
        player = SettingsStore.load(key: "settings.player")
        danmaku = SettingsStore.load(key: "settings.danmaku")
        smartSkip = SettingsStore.load(key: "settings.smartSkip")
        feedFilter = SettingsStore.load(key: "settings.feedFilter")
    }

    /// Posted on the changing (main) thread after every `acceleration` change; the acceleration engine copies the
    /// new values into the snapshot its download threads read.
    static let accelerationDidChange = Notification.Name("AppSettings.accelerationDidChange")

    func resetAll() {
        general = GeneralSettings()
        acceleration = AccelerationSettings()
        player = PlayerSettings()
        danmaku = DanmakuSettings()
        smartSkip = SmartSkipSettings()
        feedFilter = FeedFilterSettings()
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

struct GeneralSettings: SettingsGroup {
    var theme: AppTheme = .system
    /// Grid columns on iPhone portrait for video feeds (1 = list rows, 2 = cards).
    var feedColumns: Int = 2
    /// Request smaller cover images (`@..w_..h.webp`) to save bandwidth.
    var compactImages: Bool = true
    /// Index of the home top tab opened at launch (0 = 推荐).
    var defaultHomeTab: Int = 0
    /// Record watch history on the server (history/report + heartbeat).
    var reportHistory: Bool = true
    /// Keep local search history.
    var saveSearchHistory: Bool = true
    /// 「首页使用app端推荐」: 推荐 comes from the app feed (`FeedAPI.appRecommend`, with 不感兴趣 reasons);
    /// the web feed is the fallback when it fails.
    var useAppFeed: Bool = true
    /// 「保留首页推荐刷新」: pull to refresh on 推荐 puts the new cards above the ones already shown.
    var keepRecommendOnRefresh: Bool = true
    /// 「显示上次看到位置提示」: a 「上次看到这里」 divider where the previous refresh started.
    var showLastSeenHint: Bool = true
    /// 「搜索建议」 while typing in the search field.
    var searchSuggestion: Bool = true
    /// 「检查未读动态」: check for new dynamics every 5 minutes and badge the 动态 tab.
    var checkUnreadDynamics: Bool = true
    /// 「竖屏视频进入短视频」: tapping a portrait video in 推荐 opens the 短视频 feed from it, like the
    /// official app, and swiping on a portrait video's page goes to the next / previous portrait video in
    /// place; off opens the normal video page and the swipe does nothing.
    var portraitOpensShortVideo: Bool = true
    /// 短视频 「只看竖屏」: skip the landscape videos the feed mixes in (about half of them). A new key, not the
    /// old `shortVideoPortraitOnly`: its stored `false` was only the former default.
    var shortVideoOnlyPortrait: Bool = true
}
