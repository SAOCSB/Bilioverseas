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
    /// Play the next part / episode / related video automatically.
    var autoNext: Bool = true
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
}
