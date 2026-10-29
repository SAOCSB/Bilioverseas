import Foundation

// Settings groups owned by individual modules. Each module may add fields (always with a
// default value) — persistence deep-merges stored JSON over these defaults.

/// BTR-style acceleration (owned by Core/Acceleration).
enum CDNMode: String, Codable, CaseIterable, Identifiable {
    /// Mainland CDN nodes (BTR's recommended default for overseas users: the origin tier has every
    /// video cached, and multi-connection download compensates for the long distance).
    case mainland
    /// Overseas nodes (akamai / aliov / cosov …) — try this if mainland routes are poor locally.
    case overseas
    /// Only the hosts the user entered.
    case custom
    /// Use whatever playurl returned, no host substitution.
    case original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mainland: return "大陆 CDN（推荐）"
        case .overseas: return "海外 CDN"
        case .custom: return "自定义"
        case .original: return "官方分配（不替换）"
        }
    }
}

struct AccelerationSettings: SettingsGroup {
    /// Master switch. When off the local proxy still converts DASH to HLS but downloads with a
    /// single connection to the URL playurl returned.
    var enabled: Bool = true
    var cdnMode: CDNMode = .mainland
    var customHosts: [String] = []
    /// Automatic concurrency (BTR "自动"); otherwise `manualConcurrency` connections.
    var autoConcurrency: Bool = true
    var manualConcurrency: Int = 16
    /// Accelerate bangumi / movies / documentaries too.
    var accelerateBangumi: Bool = true
    /// Accelerate live streams (experimental, off by default like BTR).
    var accelerateLive: Bool = false
    /// Seconds of media AVPlayer should try to keep buffered ahead.
    var forwardBufferSeconds: Double = 60
}

/// In-video sponsor-segment skipping (owned by Core/SmartSkip).
enum SmartSkipMode: String, Codable, CaseIterable, Identifiable {
    case auto, manual
    var id: String { rawValue }
    var title: String { self == .auto ? "自动跳过" : "手动（显示跳过按钮）" }
}

struct SmartSkipSettings: SettingsGroup {
    var enabled: Bool = true
    var mode: SmartSkipMode = .auto
}

/// Feed filtering incl. "block ad videos" (owned by Core/Filter).
struct FeedFilterSettings: SettingsGroup {
    /// Remove ad / commercial cards (goto=ad, business_info, 创作推广 …) from feeds.
    var blockAdCards: Bool = true
    /// Also hide normal videos that look like paid promotions (恰饭/商单 keywords, cooperation flags).
    var blockPromotedVideos: Bool = false
    /// Hide live-room and bangumi/course cards mixed into the recommend feed.
    var blockLiveCards: Bool = false
    var blockPGCCards: Bool = false
    /// Title keywords (plain text, or `/regex/`).
    var blockedKeywords: [String] = []
    /// UP names or mids to hide.
    var blockedUploaders: [String] = []
    /// Hide videos shorter than this many seconds (0 = off).
    var minDuration: Int = 0
    /// Never filter videos from UPs you follow.
    var exemptFollowed: Bool = true
    /// Also apply keyword/UP filters to popular, ranking, search and related lists.
    var applyToAllLists: Bool = true
}

/// Danmaku display (owned by Core/Danmaku). Values mirror the official client's ranges.
enum DanmakuArea: Double, Codable, CaseIterable, Identifiable {
    case quarter = 0.25, half = 0.5, threeQuarters = 0.75, full = 1.0
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .quarter: return "1/4 屏"
        case .half: return "半屏"
        case .threeQuarters: return "3/4 屏"
        case .full: return "满屏"
        }
    }
}

struct DanmakuSettings: SettingsGroup {
    var enabled: Bool = true
    /// 0.1 … 1.0
    var opacity: Double = 0.85
    /// Multiplier on the base font size, 0.5 … 2.0
    var fontScale: Double = 1.0
    var bold: Bool = true
    /// Outline width in points, 0 … 3
    var strokeWidth: Double = 1.0
    var area: DanmakuArea = .half
    /// Seconds a scrolling danmaku takes to cross the screen (smaller = faster), 3 … 16
    var scrollDuration: Double = 7.0
    /// Seconds top/bottom danmaku stay, 2 … 10
    var fixedDuration: Double = 4.0
    var hideScroll: Bool = false
    var hideTop: Bool = false
    var hideBottom: Bool = false
    var hideColorful: Bool = false
    var hideAdvanced: Bool = true
    /// Merge identical danmaku sent within a short window.
    var mergeDuplicates: Bool = true
    /// Official "智能云屏蔽" level (DanmakuElem.weight threshold), 0 … 10
    var cloudBlockLevel: Int = 0
    /// Maximum danmaku on screen at once (0 = unlimited).
    var maxOnScreen: Int = 0
    /// Plain keywords, or `/regex/`.
    var blockedKeywords: [String] = []
    /// Sender midHash values.
    var blockedUsers: [String] = []
    /// Allow scrolling danmaku to overlap when tracks are full (dense mode).
    var allowOverlap: Bool = false
}
