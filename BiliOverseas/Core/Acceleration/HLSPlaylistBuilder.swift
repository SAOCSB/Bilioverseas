import Foundation

// DASH representation (+ parsed sidx) → HLS text for AVPlayer (avplayer-hls spec §4, re-implemented).
//
// Master: ONE video variant (the stream the player chose) and at most ONE audio rendition. Segments are byte
// ranges of the local proxy's `v.m4s` / `a.m4s` files. URIs are relative, so the text does not depend on the port.

enum HLSPlaylistBuilder {
    static let mpegURLContentType = "application/vnd.apple.mpegurl"

    /// Attribute values of the video `EXT-X-STREAM-INF` line derived from the representation.
    struct VideoAttributes: Equatable {
        var codecs: String
        var supplementalCodecs: String?
        /// `SDR`, `PQ` or `HLG`.
        var videoRange: String
        /// Formatted with three decimals.
        var frameRate: String
    }

    /// Codec / HDR / Dolby Vision mapping (avplayer-hls §4.2 table):
    /// - `avc1.*`, `hev1.*`, `hvc1.*`, `av01.*` → verbatim (no hev1→hvc1 rewrite), SDR;
    /// - qn 125 (HDR10) → verbatim, PQ, FRAME-RATE capped at 30;
    /// - `dvh1.08.07` / `dvh1.08.03` (DV 8.4, HLG base) → `hvc1.2.4.L153.b0` + SUPPLEMENTAL-CODECS `…/db4h`, HLG;
    /// - `dvh1.08.06` (DV 8.1, HDR10 base) → `hvc1.2.4.L150` + SUPPLEMENTAL-CODECS `…/db1p`, PQ;
    /// - `dvh1.05.*` (DV 5, no compatible base layer) → verbatim, PQ;
    /// - any other codec on qn 126 → verbatim, HLG.
    /// FRAME-RATE: playurl value (25 when missing), ≥ 60 → 60.
    /// `allowDolbyVision == false` drops SUPPLEMENTAL-CODECS so only the HEVC base layer is used.
    static func videoAttributes(for stream: DashStream, allowDolbyVision: Bool = true) -> VideoAttributes {
        let isDolby = stream.id == 126
        let isHDR10 = stream.id == 125
        var range = (isDolby || isHDR10) ? "HLG" : "SDR"
        var codecs = stream.codecs
        var supplemental: String?
        var frameRate = stream.frameRate.isFinite && stream.frameRate > 0 ? stream.frameRate : 25
        if isHDR10 {
            range = "PQ"
            if frameRate > 30 { frameRate = 30 }
        }
        let lower = stream.codecs.lowercased()
        if lower == "dvh1.08.07" || lower == "dvh1.08.03" {
            supplemental = stream.codecs + "/db4h"
            codecs = "hvc1.2.4.L153.b0"
            range = "HLG"
        } else if lower == "dvh1.08.06" {
            supplemental = stream.codecs + "/db1p"
            codecs = "hvc1.2.4.L150"
            range = "PQ"
        } else if lower.hasPrefix("dvh1.05") || lower.hasPrefix("dvhe.05") {
            range = "PQ"
        }
        if frameRate >= 60 { frameRate = 60 }
        if !allowDolbyVision { supplemental = nil }
        return VideoAttributes(codecs: codecs, supplementalCodecs: supplemental, videoRange: range,
                               frameRate: decimal3(frameRate))
    }

    /// DASH `bandwidth` is an average; HLS `BANDWIDTH` is the segment peak. Bilibili segments peak at ≈ 1.5 × the
    /// average — declaring the average makes CoreMedia log -12318 ("Segment exceeds specified bandwidth") on every
    /// segment and drives ABR from a wrong estimate (avplayer-hls §4.2, §16.1).
    static func peakBandwidth(forAverage average: Int) -> Int { Int(Double(average) * 1.5) }

    /// Average bit rate from the index when playurl gave none.
    static func estimatedBandwidth(segments: [SidxSegment]) -> Int {
        let bytes = segments.reduce(Int64(0)) { $0 + $1.byteRange.length }
        let seconds = segments.reduce(0.0) { $0 + $1.duration }
        guard seconds > 0 else { return 0 }
        return Int(Double(bytes) * 8 / seconds)
    }

    /// The master playlist.
    /// - Parameters:
    ///   - averageBandwidth: overrides `video.bandwidth` (use `estimatedBandwidth` when playurl had 0).
    ///   - audio: nil → a video-only master (no `AUDIO` group).
    static func masterPlaylist(video: DashStream, videoURI: String, audio: DashStream?, audioURI: String?,
                               averageBandwidth: Int? = nil, allowDolbyVision: Bool = true) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n\n"
        let hasAudio = audio != nil && audioURI != nil
        if let audio, let audioURI {
            let kbps = audio.bandwidth / 1000
            let name = kbps > 0 ? "音轨 (\(kbps)kbps)" : "音轨"
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name)\",LANGUAGE=\"zh\","
                + "DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioURI)\"\n"
        }
        let average = max(1, averageBandwidth ?? video.bandwidth)
        var parts: [String] = []
        if hasAudio { parts.append("AUDIO=\"audio\"") }
        if isAudioRepresentation(video) {
            // 听视频: the only track is an audio representation, so no video attributes (RESOLUTION / FRAME-RATE /
            // VIDEO-RANGE would declare a video rendition that is not there).
            if !video.codecs.isEmpty { parts.append("CODECS=\"\(video.codecs)\"") }
            parts.append("BANDWIDTH=\(peakBandwidth(forAverage: average))")
            parts.append("AVERAGE-BANDWIDTH=\(average)")
            text += "#EXT-X-STREAM-INF:" + parts.joined(separator: ",") + "\n" + videoURI + "\n"
            return text
        }
        let attributes = videoAttributes(for: video, allowDolbyVision: allowDolbyVision)
        if !attributes.codecs.isEmpty { parts.append("CODECS=\"\(attributes.codecs)\"") }
        if let supplemental = attributes.supplementalCodecs { parts.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"") }
        if video.width > 0 && video.height > 0 { parts.append("RESOLUTION=\(video.width)x\(video.height)") }
        parts.append("FRAME-RATE=\(attributes.frameRate)")
        parts.append("BANDWIDTH=\(peakBandwidth(forAverage: average))")
        parts.append("AVERAGE-BANDWIDTH=\(average)")
        parts.append("VIDEO-RANGE=\(attributes.videoRange)")
        text += "#EXT-X-STREAM-INF:" + parts.joined(separator: ",") + "\n" + videoURI + "\n"
        return text
    }

    /// An audio DASH representation (MIME `audio/…`, or an audio codec such as mp4a / ec-3 / fLaC).
    static func isAudioRepresentation(_ stream: DashStream) -> Bool {
        if stream.mimeType.lowercased().hasPrefix("audio") { return true }
        let codecs = stream.codecs.lowercased()
        return ["mp4a", "ec-3", "ac-3", "flac", "opus"].contains { codecs.hasPrefix($0) }
    }

    /// A VOD media playlist over one fMP4 file: `EXT-X-MAP` = the init range, one byte-range segment per sidx
    /// reference. `TARGETDURATION = floor(max EXTINF) + 1` so it is ≥ every rounded EXTINF.
    static func mediaPlaylist(initRange: ByteRange, segments: [SidxSegment], uri: String) -> String {
        let maxDuration = segments.map(\.duration).max() ?? 0
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        text += "#EXT-X-TARGETDURATION:\(Int(maxDuration.rounded(.down)) + 1)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        text += "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(initRange.length)@\(initRange.start)\"\n"
        for segment in segments {
            text += "#EXTINF:\(decimal3(segment.duration)),\n"
            text += "#EXT-X-BYTERANGE:\(segment.byteRange.length)@\(segment.byteRange.start)\n"
            text += uri + "\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    /// `x` with exactly three decimals, independent of the locale ("5.005", "3.200", "60.000").
    static func decimal3(_ x: Double) -> String {
        guard x.isFinite else { return "0.000" }
        let negative = x < 0
        let thousandths = Int64((abs(x) * 1000).rounded())
        let fraction = thousandths % 1000
        let pad = fraction < 10 ? "00" : fraction < 100 ? "0" : ""
        return (negative && thousandths > 0 ? "-" : "") + "\(thousandths / 1000).\(pad)\(fraction)"
    }
}
