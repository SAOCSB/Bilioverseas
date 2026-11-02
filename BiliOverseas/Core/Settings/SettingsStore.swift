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
        let adoptedKey = "settings.acceleration.cacheRouteAdopted"
        if !SettingsStore.defaults.bool(forKey: adoptedKey) {
            SettingsStore.defaults.set(true, forKey: adoptedKey)
            if SettingsStore.defaults.data(forKey: "settings.acceleration") != nil {
                acceleration = acceleration.adoptingCacheRoute()
                SettingsStore.save(acceleration, key: "settings.acceleration")
            }
        }
        // The old 「首页使用app端推荐」 turned off meant the web feed without the other as a fallback: 首页推荐来源 网页端
        // now, which behaves the same and is what 设置 shows and describes.
        if !general.useAppFeed && general.homeFeedSource == nil {
            general.homeFeedSource = .web
            SettingsStore.save(general, key: "settings.general")
        }
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
    /// The old 「首页使用app端推荐」 switch, no longer shown. A save with it off becomes 首页推荐来源 网页端 at launch
    /// (`AppSettings.init`); `FeedAPI.recommendSource` reads it the same way.
    var useAppFeed: Bool = true
    /// 「首页推荐来源」 once chosen, in settings or by long-pressing 推荐 (nil: `FeedAPI.recommendSource`).
    var homeFeedSource: HomeFeedSource? = nil
    /// 「保留首页推荐刷新」: pull to refresh on 推荐 puts the new cards above the ones already shown.
    var keepRecommendOnRefresh: Bool = true
    /// 「显示上次看到位置提示」: a 「上次看到这里」 divider where the previous refresh started.
    var showLastSeenHint: Bool = true
    /// 「搜索建议」 while typing in the search field.
    var searchSuggestion: Bool = true
    /// 「检查未读动态」: check for new dynamics every 5 minutes and badge the 动态 tab.
    var checkUnreadDynamics: Bool = true
    /// 「竖屏视频进入短视频」: tapping a portrait video in 推荐 opens the 短视频 feed from it, like the
    /// official app, and swiping on a portrait video's page goes to the next / previous video in place; off
    /// opens the normal video page and the swipe does nothing.
    var portraitOpensShortVideo: Bool = true
    /// 「只看竖屏」: swipes skip the landscape videos the feed mixes in (about half of them), which the official app
    /// shows on the same screen. A new key: the stored values of the older ones were only their defaults.
    var swipesOnlyPortrait: Bool = false
    /// Where vertical swiping gets its videos, once chosen (nil: `ShortVideoAPI.source`).
    var swipeFeedSource: SwipeFeedSource? = nil
}

/// Where 首页 推荐 gets its videos. The two differ a lot for the same account.
enum HomeFeedSource: String, Codable, CaseIterable, Identifiable {
    /// The phone app's 推荐 (`FeedAPI.appRecommend`), personalised by a TV login's `access_key`.
    case app
    /// bilibili.com's 推荐 (`FeedAPI.recommend`), personalised by the login's cookies (a TV login brings them too).
    case web

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App 端（TV 登录）"
        case .web: return "网页端"
        }
    }

    var other: HomeFeedSource { self == .app ? .web : .app }
}

/// Where vertical swiping gets its videos.
enum SwipeFeedSource: String, Codable, CaseIterable, Identifiable {
    /// The official app's vertical feed, personalised by a TV login.
    case official
    /// bilibili.com's 推荐, personalised by a web login.
    case web

    var id: String { rawValue }

    var title: String {
        switch self {
        case .official: return "官方竖屏流"
        case .web: return "网页推荐"
        }
    }
}
