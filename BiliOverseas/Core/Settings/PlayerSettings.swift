import Foundation

/// Bilibili `qn` quality ids.
enum VideoQuality: Int, Codable, CaseIterable, Identifiable {
    case q240 = 6
    case q360 = 16
    case q480 = 32
    case q720 = 64
    case q720p60 = 74
    case q1080 = 80
    case q1080plus = 112
    case q1080p60 = 116
    case q4k = 120
    case hdr = 125
    case dolby = 126
    case q8k = 127

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .q240: return "240P 极速"
        case .q360: return "360P 流畅"
        case .q480: return "480P 清晰"
        case .q720: return "720P 高清"
        case .q720p60: return "720P60 高帧率"
        case .q1080: return "1080P 高清"
        case .q1080plus: return "1080P+ 高码率"
        case .q1080p60: return "1080P60 高帧率"
        case .q4k: return "4K 超清"
        case .hdr: return "HDR 真彩色"
        case .dolby: return "杜比视界"
        case .q8k: return "8K 超高清"
        }
    }

    static func title(for qn: Int) -> String {
        VideoQuality(rawValue: qn)?.title ?? "\(qn)"
    }
}

/// DASH `codecid`: 7 = AVC, 12 = HEVC, 13 = AV1.
enum VideoCodecPreference: String, Codable, CaseIterable, Identifiable {
    case avc, hevc, av1
    var id: String { rawValue }
    var codecId: Int {
        switch self {
        case .avc: return 7
        case .hevc: return 12
        case .av1: return 13
        }
    }
    var title: String {
        switch self {
        case .avc: return "H.264 / AVC（兼容性最好）"
        case .hevc: return "H.265 / HEVC（省流量）"
        case .av1: return "AV1（仅新设备硬解）"
        }
    }
}

enum DoubleTapAction: String, Codable, CaseIterable, Identifiable {
    case playPause, seek
    var id: String { rawValue }
    var title: String { self == .playPause ? "播放/暂停" : "左右快退/快进" }
}

/// 「播放顺序」: what happens when a video plays to its end.
enum PlayRepeat: String, Codable, CaseIterable, Identifiable {
    /// 播完暂停.
    case pause
    /// 顺序播放: next part / 合集 / episode; stop at the end of the list.
    case listOrder
    /// 单个循环.
    case singleCycle
    /// 列表循环: like `listOrder`, then back to the first item (a single video replays itself).
    case listCycle
    /// 自动连播: like `listOrder`, then the first related video.
    case autoPlayRelated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pause: return "播完暂停"
        case .listOrder: return "顺序播放"
        case .singleCycle: return "单个循环"
        case .listCycle: return "列表循环"
        case .autoPlayRelated: return "自动连播"
        }
    }
    /// One line for the settings footer / the in-player menu.
    var explanation: String {
        switch self {
        case .pause: return "播完后暂停。"
        case .listOrder: return "依次播放分P、合集或剧集，播完列表后停止。"
        case .singleCycle: return "循环播放当前视频。"
        case .listCycle: return "依次播放分P、合集或剧集，播完后从第一个重新开始。"
        case .autoPlayRelated: return "依次播放分P、合集或剧集，之后自动播放相关推荐。"
        }
    }
}

/// 「番剧片头/片尾跳过类型」 for the PGC `clip_info_list` (SponsorBlock-style skip types).
enum PGCClipSkipType: String, Codable, CaseIterable, Identifiable {
    case always, skipOnce, manual, showOnly, disabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return "总是跳过"
        case .skipOnce: return "跳过一次"
        case .manual: return "手动跳过"
        case .showOnly: return "仅显示"
        case .disabled: return "禁用"
        }
    }
}

/// 「底部细进度条」: the 2 pt progress line drawn while the player controls are hidden.
enum ThinProgressMode: String, Codable, CaseIterable, Identifiable {
    case always, hiddenInFullscreen, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return "始终显示"
        case .hiddenInFullscreen: return "全屏时隐藏"
        case .never: return "不显示"
        }
    }

    /// Whether the line is drawn (while the controls are hidden) in this presentation.
    func shows(fullscreen: Bool) -> Bool {
        switch self {
        case .always: return true
        case .hiddenInFullscreen: return !fullscreen
        case .never: return false
        }
    }
}

struct PlayerSettings: SettingsGroup {
    /// Preferred `qn`; the highest available quality not above this is chosen.
    var preferredQuality: Int = VideoQuality.q1080.rawValue
    var preferredCodec: VideoCodecPreference = .hevc
    /// Allow HDR / Dolby Vision streams when the device supports them.
    var allowHDR: Bool = false
    /// Prefer Dolby Atmos / Hi-Res FLAC audio when available.
    var preferLosslessAudio: Bool = false
    var defaultSpeed: Double = 1.0
    /// Hold-to-speed-up (长按倍速).
    var longPressSpeedEnabled: Bool = true
    var longPressSpeed: Double = 2.0
    var doubleTapAction: DoubleTapAction = .playPause
    /// Seconds for double-tap seek / arrow buttons.
    var seekStep: Double = 10
    var autoPlay: Bool = true
    /// Play the next part / episode / related video automatically (the older 「自动连播」 switch; `playRepeat`
    /// keeps it in sync, so it reads as "advance at the end").
    var autoNext: Bool = true
    /// Stored 「播放顺序」. nil until the user picks one: saves from before it existed follow `autoNext`.
    var playRepeatChoice: PlayRepeat? = nil
    var backgroundPlay: Bool = true
    var autoPiP: Bool = false
    /// Resume from the server-side history progress.
    var resumeProgress: Bool = true
    var showSubtitles: Bool = true
    /// Rotate to landscape fullscreen automatically for horizontal videos.
    var autoFullscreenOnRotate: Bool = true
    /// Speeds offered in the speed menu.
    var speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0]
    /// Show the BTR acceleration statistics overlay in the player.
    var showAccelerationStats: Bool = false
    /// 「快速收藏」: tapping 收藏 on the video page favourites into the default folder; long press opens the picker.
    var quickFavorite: Bool = false
    /// 「番剧片头/片尾跳过类型」 (default 跳过一次, features.md §11.1).
    var pgcSkipType: PGCClipSkipType = .skipOnce
    /// 「底部细进度条」 while the controls are hidden; by default not over a fullscreen video.
    var thinProgressMode: ThinProgressMode = .hiddenInFullscreen
    /// 「左右侧滑动调节亮度/音量」 (features.md §1.6).
    var slideVolumeBrightness: Bool = true
    /// 「中间滑动进入/退出全屏」 (features.md §1.6).
    var slideFullscreen: Bool = true
    /// 「滑动快进/快退时长」: seconds a full-width horizontal swipe seeks (features.md §1.5).
    var slideSeekSeconds: Double = 90
    /// 「画面比例」 as a `PlayerAspectMode` raw value, kept across videos (features.md §3.6).
    var aspectMode: String = "fit"
    /// 「字幕设置」 (features.md §3.7): 字体大小 / 全屏字体大小 multipliers of the 16 pt base, 0.5 … 2.5.
    var subtitleFontScale: Double = 1.0
    var subtitleFontScaleFullscreen: Double = 1.5
    /// 字体粗细 index 0 … 8 = w100 … w900 (UI shows index + 1).
    var subtitleFontWeight: Int = 5
    /// 描边粗细 0 … 5, drawn only when the background is fully transparent.
    var subtitleStrokeWidth: Double = 2.0
    /// 左右边距 0 … 100 and 底部边距 0 … 200 points (the bottom one is raised above visible controls).
    var subtitlePaddingH: Double = 24
    var subtitleBottomPadding: Double = 24
    /// 背景不透明度 of the black box, 0 … 1.
    var subtitleBgOpacity: Double = 0.67

    /// 「播放顺序」 (`autoNext` on → 自动连播, off → 播完暂停 until a mode is chosen).
    var playRepeat: PlayRepeat {
        get { playRepeatChoice ?? (autoNext ? .autoPlayRelated : .pause) }
        set {
            playRepeatChoice = newValue
            autoNext = newValue != .pause
        }
    }
}
