import Foundation

enum MediaKind: String, Hashable, Codable {
    case video, audio
}

/// One DASH representation from playurl (`data.dash.video[]` / `audio[]` / `dolby.audio[]` /
/// `flac.audio[]`, or PGC `result.video_info.dash...`). Field names follow the web API; parsers
/// must accept both camelCase and snake_case variants.
struct DashStream: Hashable {
    var kind: MediaKind
    /// Video: `qn` (16/32/64/80/112/116/120/125/126/127). Audio: 30216/30232/30280, Dolby 30250, Hi-Res 30251.
    var id: Int
    var baseURL: String
    var backupURLs: [String] = []
    /// Bits per second.
    var bandwidth: Int = 0
    var mimeType: String = ""
    /// e.g. "avc1.640032", "hev1.1.6.L150.90", "av01.0.13M.08.0.110.01.01.01.0", "mp4a.40.2", "ec-3", "fLaC".
    var codecs: String = ""
    /// 7 = AVC, 12 = HEVC, 13 = AV1 (0 for audio).
    var codecId: Int = 0
    var width: Int = 0
    var height: Int = 0
    var frameRate: Double = 0
    /// `segment_base.initialization`, e.g. "0-927".
    var initRange: String = ""
    /// `segment_base.index_range`, e.g. "928-3011".
    var indexRange: String = ""

    var allURLs: [String] { [baseURL] + backupURLs.filter { $0 != baseURL } }

    var isDolbyAudio: Bool { kind == .audio && (id == 30250 || id == 30255 || codecs.hasPrefix("ec-3") || codecs.hasPrefix("ac-3")) }
    var isFlacAudio: Bool { kind == .audio && (id == 30251 || codecs.lowercased().hasPrefix("flac")) }

    var codecFamily: String {
        let c = codecs.lowercased()
        if c.hasPrefix("av01") || codecId == 13 { return "av1" }
        if c.hasPrefix("hev1") || c.hasPrefix("hvc1") || codecId == 12 { return "hevc" }
        if c.hasPrefix("avc1") || codecId == 7 { return "avc" }
        return kind == .audio ? "audio" : "other"
    }

    /// Human label for audio ids.
    static func audioTitle(_ id: Int) -> String {
        switch id {
        case 30216: return "64K"
        case 30232: return "132K"
        case 30280: return "192K"
        case 30250, 30255: return "杜比全景声"
        case 30251: return "Hi-Res 无损"
        default: return "\(id)"
        }
    }
}

/// A non-DASH (`durl`) progressive segment.
struct ProgressiveSegment: Hashable {
    var order: Int
    var url: String
    var backupURLs: [String] = []
    /// Milliseconds.
    var lengthMs: Int = 0
    var size: Int64 = 0
}

struct QualityOption: Hashable, Identifiable {
    var qn: Int
    var title: String
    /// Codecs the server offers for this quality (`support_formats[].codecs`).
    var codecs: [String] = []
    var needLogin: Bool = false
    var needVip: Bool = false
    var id: Int { qn }
}

/// Parsed playurl response (UGC or PGC).
struct PlayInfo {
    /// The quality the server actually returned as default (`data.quality`).
    var quality: Int = 0
    var qualities: [QualityOption] = []
    var videos: [DashStream] = []
    var audios: [DashStream] = []
    var dolbyAudios: [DashStream] = []
    var flacAudios: [DashStream] = []
    /// Seconds (`dash.duration`, or `timelength / 1000`).
    var duration: Double = 0
    /// Fallback when there is no DASH.
    var durl: [ProgressiveSegment] = []
    /// Server-side resume point in seconds (`last_play_time / 1000`), 0 if none.
    var lastPlayTime: Double = 0
    var lastPlayCid: Int64 = 0
    /// PGC: preview-only episode (试看) / DRM protected.
    var isPreview: Bool = false
    var isDRM: Bool = false
    /// UGC charging video that only offers a trial clip (`accept_description` contains "试看").
    var isTrial: Bool = false
    /// PGC opening / ending markers (`video_info.clip_info_list`), seconds.
    var clips: [PGCClipInfo] = []
    /// `accept_description[]` verbatim (parallel to `accept_quality`).
    var acceptDescriptions: [String] = []

    var isDash: Bool { !videos.isEmpty }
}

/// A chapter / view point (`view_points` from player/wbi/v2).
struct VideoChapter: Hashable {
    var from: Double
    var to: Double
    var title: String
}

/// One subtitle track (`data.subtitle.subtitles[]` from player/wbi/v2).
struct SubtitleTrack: Hashable, Identifiable {
    var id: Int64
    var lan: String
    var lanDoc: String
    /// Full https URL to the JSON body.
    var url: String
    var isAI: Bool
}

/// A parsed subtitle line.
struct SubtitleLine: Hashable {
    var from: Double
    var to: Double
    var content: String
}
