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
    /// 「竖屏视频禁用加速」. Short vertical videos need a quick start more than throughput, and measured from the UK they
    /// start two to three times faster on a single connection to the address playurl gives.
    var verticalVideosDirect: Bool = true
    /// Reserved: BTR's live-stream switch. Live acceleration is not implemented (live rooms play straight from the
    /// CDN) and nothing reads this; it stays so stored settings keep decoding. The settings row shows 「暂未支持」.
    var accelerateLive: Bool = false
    /// Seconds of media AVPlayer should try to keep buffered ahead.
    var forwardBufferSeconds: Double = 60

    /// Whether a video of this kind goes through the BTR downloader.
    func accelerates(pgc: Bool, vertical: Bool) -> Bool {
        enabled && (!pgc || accelerateBangumi) && !(vertical && verticalVideosDirect)
    }
}

/// In-video sponsor-segment skipping (owned by Core/SmartSkip).
enum SmartSkipMode: String, Codable, CaseIterable, Identifiable {
    case auto, manual
    var id: String { rawValue }
    var title: String { self == .auto ? "自动跳过" : "手动（显示跳过按钮）" }
}

/// 「空降助手」 per-category skip type (features.md §11.3, PiliPlus `SkipType`).
enum SponsorBlockSkipType: String, Codable, CaseIterable, Identifiable {
    /// Skipped every time playback reaches it.
    case alwaysSkip
    /// Skipped once per video; re-entering it offers the button.
    case skipOnce
    /// Only the 「跳过: {短标题}」 button.
    case skipManually
    /// Only the coloured strip on the progress bar.
    case showOnly
    /// Neither skipped nor drawn.
    case disable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alwaysSkip: return "总是跳过"
        case .skipOnce: return "跳过一次"
        case .skipManually: return "手动跳过"
        case .showOnly: return "仅显示"
        case .disable: return "禁用"
        }
    }
}

struct SmartSkipSettings: SettingsGroup {
    var enabled: Bool = true
    /// `.auto` skips only trusted segments by itself; everything else shows the 「跳过广告」 prompt.
    var mode: SmartSkipMode = .auto
    /// How long the 「跳过广告」 prompt stays (seconds of playback; pauses while paused / touched).
    var countdownSeconds: Int = 5
    /// Show the 「已跳过广告」 toast (with 「撤销」) after an automatic skip.
    var showToast: Bool = true
    /// 「本地识别」: the on-device BiliSmartSkip detectors (chapters, description, danmaku, subtitles).
    var localDetection: Bool = true
    /// 「空降助手」: community segments from BilibiliSponsorBlock, merged with the local result
    /// (features.md §11.1 / §13 `enableSponsorBlock`, OURS default on). Both sources sit under `enabled`.
    var sponsorBlockEnabled: Bool = true
    /// 「服务器地址」 (§13 `blockServer`).
    var sponsorBlockServer: String = SmartSkipSettings.defaultSponsorBlockServer
    /// Category raw value (`sponsor`, `intro` …) → skip type. A missing category means 跳过一次 (§11.3).
    var sponsorBlockSkipTypes: [String: SponsorBlockSkipType] = [:]
    /// 「最短片段时长」 seconds (§13 `blockLimit`): shorter segments are only shown, never skipped.
    var sponsorBlockMinDuration: Double = 0

    /// Valid range for `countdownSeconds` in the settings screen.
    static let countdownRange = 3...15
    static let defaultSponsorBlockServer = "https://www.bsbsb.top"
    /// Valid range for `sponsorBlockMinDuration` in the settings screen.
    static let sponsorBlockMinDurationRange: ClosedRange<Double> = 0...30
}

/// Feed filtering incl. "block ad videos" (owned by Core/Filter).
struct FeedFilterSettings: SettingsGroup {
    /// Remove ad / commercial cards (goto=ad, business_info, 创作推广 …) from feeds.
    var blockAdCards: Bool = true
    /// Also hide normal videos that look like paid promotions (恰饭/商单 keywords, cooperation flags,
    /// goods-attached dynamics). Heuristic, so off by default — see `FeedPromotionDetector`.
    var blockPromotedVideos: Bool = false
    /// Hide live-room cards mixed into the home recommend feed (on by default: features.md §10.1
    /// "OURS" drops live from the feed unless the user opts in).
    var blockLiveCards: Bool = true
    /// Hide bangumi / film / course cards mixed into the home recommend feed.
    var blockPGCCards: Bool = false
    /// Title keywords: plain text (case-insensitive substring), or `/regex/` (case-insensitive).
    var blockedKeywords: [String] = []
    /// UP names (exact, case-insensitive) or mids (`12345`, `UID:12345`) to hide.
    var blockedUploaders: [String] = []
    /// Hide videos shorter than this many seconds (0 = off). Unknown durations are never hidden.
    var minDuration: Int = 0
    /// Hide videos whose likes / views is below this percentage (0 = off; PiliPlus 0…4 %).
    /// Only applied when both counts are known (> 0), i.e. mostly web recommend / popular / ranking.
    var minLikeRatio: Int = 0
    /// Hide videos with fewer plays than this (0 = off; PiliPlus 50 / 100 / 500 / 1000). Only when known.
    var minPlayCount: Int = 0
    /// Never filter videos from UPs you follow (explicitly blocked UPs and ad cards excepted).
    var exemptFollowed: Bool = true
    /// Also apply the user rules (keywords, UPs, 恰饭, duration, likes, plays) to popular, ranking,
    /// search and related lists. Off = home recommend only. Ad-card blocking ignores this switch.
    var applyToAllLists: Bool = true
    /// 「分区屏蔽」: zone names (`tname`, e.g. 鬼畜调教) in the `blockedKeywords` format. Only lists whose
    /// cards carry a zone use it: home recommend (app feed), 热门 and 排行.
    var blockedZones: [String] = []
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
    /// 「弹幕开关」
    var enabled: Bool = true
    /// 「不透明度」 applied to the whole danmaku layer, 0 … 1 (step 0.01).
    var opacity: Double = 1.0
    /// 「字体大小」 multiplier on the 15 pt base font, 0.5 … 2.5.
    var fontScale: Double = 1.0
    /// 「全屏字体大小」 multiplier used while the player is fullscreen, 0.5 … 2.5.
    var fontScaleFullscreen: Double = 1.2
    /// 「字体粗细」 index 0 … 8 = w100 … w900 (UI shows index + 1). Default 5 = w600.
    var fontWeight: Int = 5
    /// Convenience switch over `fontWeight` (on = semibold or heavier). Not persisted on its own.
    var bold: Bool {
        get { fontWeight >= 5 }
        set { fontWeight = newValue ? max(fontWeight, 5) : min(fontWeight, 3) }
    }
    /// 「描边粗细」 black outline width in points, 0 … 5 (step 0.5).
    var strokeWidth: Double = 1.5
    /// 「弹幕行高」 track height = font size × lineHeight, 1.0 … 3.0.
    var lineHeight: Double = 1.6
    /// 「显示区域」 fraction of the player height used by danmaku tracks.
    var area: DanmakuArea = .half
    /// 「滚动弹幕时长」 seconds a scrolling danmaku takes to cross the screen (smaller = faster), 1 … 50.
    var scrollDuration: Double = 7.0
    /// 「静态弹幕时长」 seconds top/bottom danmaku stay, 1 … 50.
    var fixedDuration: Double = 4.0
    var hideScroll: Bool = false
    var hideTop: Bool = false
    var hideBottom: Bool = false
    /// 「彩色」 block: hides every non-white danmaku (incl. VIP gradient ones).
    var hideColorful: Bool = false
    /// 「高级」 block: mode 7 (positioned, moving text; see `DanmakuAdvancedSpec`). Modes 8 (code) and 9 (BAS)
    /// count as advanced too but are never rendered.
    var hideAdvanced: Bool = false
    /// 「合并重复弹幕」 identical (normalised) content within `mergeWindow` seconds shows once with a count.
    var mergeDuplicates: Bool = false
    /// Merge window in seconds, measured from the first occurrence.
    var mergeWindow: Double = 20
    /// Official "智能云屏蔽" level: drop danmaku whose `weight` is below it, 0 (off) … 11.
    var cloudBlockLevel: Int = 0
    /// Maximum danmaku on screen at once (0 = unlimited).
    var maxOnScreen: Int = 0
    /// Plain keywords (case-insensitive substring), or `/regex/` (case-insensitive).
    var blockedKeywords: [String] = []
    /// Sender midHash values (`crc32(uid)` lower-case hex, as in `DanmakuElem.mid_hash`).
    var blockedUsers: [String] = []
    /// Optional display label (usually the UID the user typed) for each blocked midHash.
    var blockedUserLabels: [String: String] = [:]
    /// 「海量弹幕」: when every track is busy, overlap scrolling danmaku instead of dropping them.
    var allowOverlap: Bool = false
    /// 「固定转滚动」: top/bottom danmaku that cannot be placed (or are wider than the view) scroll instead.
    var static2Scroll: Bool = false
    /// 「滚动弹幕固定速度」: every scrolling danmaku moves at `viewWidth / scrollDuration`.
    var scrollFixedVelocity: Bool = false
    /// 「显示会员彩色弹幕」: VIP gradient danmaku get a gradient outline.
    var showVipColorful: Bool = true
    /// 「启用点击弹幕」: tapping a danmaku freezes it and shows 点赞 / 复制 / 举报 / 屏蔽 (features.md §8.6).
    var tapToInteract: Bool = true
    /// Account rule id (`x/dm/filter/user`) of each keyword / `/regex/` rule that is also stored on the server, so
    /// deleting it here deletes it there.
    var cloudRuleIds: [String: Int64] = [:]
    /// Account rule id of each blocked midHash that is also stored on the server.
    var cloudUserRuleIds: [String: Int64] = [:]
    /// mid of the account `cloudRuleIds` / `cloudUserRuleIds` belong to (0 = none yet).
    var cloudRulesMid: Int64 = 0
}
