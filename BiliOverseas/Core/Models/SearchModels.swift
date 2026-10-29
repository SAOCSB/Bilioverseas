import Foundation
import Combine

/// One 热搜 entry (`/x/v2/search/trending/ranking`).
struct HotSearchWord: Identifiable, Hashable {
    var id: String { keyword }
    /// What to search for.
    var keyword: String
    /// What to display (falls back to `keyword`).
    var showName: String
    /// Small tag image (新 / 热 …), https; may be empty.
    var icon: String = ""
    /// Sponsored entry (`is_commercial == "1"`); `SearchAPI.hotWords` drops these.
    var isCommercial: Bool = false
    /// `recommend_reason` with the first `·` replaced by a space.
    var recommendReason: String = ""
    var showLiveIcon: Bool = false
    /// Pinned entry from `top_list`.
    var isTop: Bool = false
}

/// 综合排序 / 最多播放 / 最新发布 / 最多弹幕 / 最多收藏.
enum SearchVideoOrder: String, CaseIterable, Identifiable {
    case totalrank, click, pubdate, dm, stow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .totalrank: return "综合排序"
        case .click: return "最多播放"
        case .pubdate: return "最新发布"
        case .dm: return "最多弹幕"
        case .stow: return "最多收藏"
        }
    }
}

/// Duration filter of video search.
enum SearchDurationFilter: Int, CaseIterable, Identifiable {
    case all = 0, under10 = 1, from10to30 = 2, from30to60 = 3, over60 = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: return "全部时长"
        case .under10: return "10分钟以下"
        case .from10to30: return "10-30分钟"
        case .from30to60: return "30-60分钟"
        case .over60: return "60分钟以上"
        }
    }
}

/// User search ordering: 默认排序 / 粉丝数由高到低 / Lv等级由高到低.
enum SearchUserOrder: String, CaseIterable, Identifiable {
    case `default` = "", fans, level
    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: return "默认排序"
        case .fans: return "粉丝数"
        case .level: return "Lv等级"
        }
    }
}

/// Local search history (most recent first, max 20, de-duplicated). Honors
/// `AppSettings.shared.general.saveSearchHistory`: when off, `add` does nothing.
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    static let maxCount = 20

    @Published private(set) var keywords: [String]

    private let defaults: UserDefaults
    private let key: String
    private let isEnabled: () -> Bool

    init(defaults: UserDefaults = .standard,
         key: String = "search.history",
         isEnabled: @escaping () -> Bool = { AppSettings.shared.general.saveSearchHistory }) {
        self.defaults = defaults
        self.key = key
        self.isEnabled = isEnabled
        keywords = (defaults.stringArray(forKey: key) ?? []).prefix(SearchHistoryStore.maxCount).map { $0 }
    }

    func add(_ keyword: String) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, isEnabled() else { return }
        var list = keywords.filter { $0 != k }
        list.insert(k, at: 0)
        if list.count > SearchHistoryStore.maxCount { list = Array(list.prefix(SearchHistoryStore.maxCount)) }
        keywords = list
        defaults.set(list, forKey: key)
    }

    func remove(_ keyword: String) {
        keywords.removeAll { $0 == keyword }
        defaults.set(keywords, forKey: key)
    }

    func clear() {
        keywords = []
        defaults.removeObject(forKey: key)
    }
}
