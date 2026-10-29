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
    @Published var acceleration: AccelerationSettings { didSet { SettingsStore.save(acceleration, key: "settings.acceleration") } }
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
}
