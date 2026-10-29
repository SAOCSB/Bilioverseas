import Foundation

// Stream selection for the video player (pure logic, Foundation only).
//
// Video: the highest qn ≤ the preferred (or manually chosen) quality among the streams this device can play
// (AV1 only with hardware decode, HDR / Dolby Vision only when allowed and the display is HDR-eligible), then the
// codec by preference (HEVC → AVC → AV1 by default), then the highest bandwidth. Audio: Hi-Res / Dolby when
// 「无损音质」 is on, otherwise the best normal track (192K > 132K > 64K).

/// The video + audio representations of one AVPlayerItem.
struct PlayerStreamChoice: Equatable {
    var video: DashStream
    var audio: DashStream?
}

/// Everything the picker needs to know about the user's preferences, the device and the fallback state.
struct PlayerStreamConstraints: Equatable {
    var preferredQuality: Int
    var codec: VideoCodecPreference
    /// `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)`.
    var av1Supported: Bool
    /// `allowHDR && AVPlayer.eligibleForHDRPlayback`.
    var hdrAllowed: Bool
    var preferLossless: Bool
    /// Quality picked in the 画质 menu (or by the fallback ladder): used exactly when available.
    var manualQuality: Int? = nil
    /// Audio id picked in the 音质 menu.
    var manualAudio: Int? = nil
    /// Fallback step: only H.264 streams.
    var forceAVC: Bool = false
    /// Fallback step: no Dolby / FLAC audio.
    var forceNormalAudio: Bool = false
}

enum PlayerStreamPicker {
    /// HDR10 (125), Dolby Vision (126), HDR Vivid (129).
    static let hdrQualities: Set<Int> = [125, 126, 129]

    static func isHDR(_ s: DashStream) -> Bool {
        let c = s.codecs.lowercased()
        return hdrQualities.contains(s.id) || c.hasPrefix("dvh1") || c.hasPrefix("dvhe") || c.hasPrefix("dav1")
    }

    static func isSpecialAudio(_ s: DashStream?) -> Bool {
        guard let s else { return false }
        return s.isDolbyAudio || s.isFlacAudio
    }

    /// Streams the device can decode under the current constraints (manual choices ignored).
    static func playableVideos(_ info: PlayInfo, _ c: PlayerStreamConstraints) -> [DashStream] {
        info.videos.filter { v in
            if !c.hdrAllowed && isHDR(v) { return false }
            switch v.codecFamily {
            case "avc": return true
            case "av1": return c.av1Supported && !c.forceAVC
            default: return !c.forceAVC
            }
        }
    }

    /// Codec families in order of preference.
    static func codecOrder(_ preference: VideoCodecPreference, av1Supported: Bool) -> [String] {
        var order: [String]
        switch preference {
        case .avc: order = ["avc", "hevc", "other", "av1"]
        case .hevc: order = ["hevc", "avc", "other", "av1"]
        case .av1: order = av1Supported ? ["av1", "hevc", "avc", "other"] : ["hevc", "avc", "other", "av1"]
        }
        return order
    }

    /// The quality to play: the manual one when available, else the highest ≤ the limit, else the lowest available.
    static func targetQuality(available: [Int], _ c: PlayerStreamConstraints) -> Int? {
        let qns = Set(available)
        guard !qns.isEmpty else { return nil }
        if let manual = c.manualQuality, qns.contains(manual) { return manual }
        let limit = c.manualQuality ?? c.preferredQuality
        if let below = qns.filter({ $0 <= limit }).max() { return below }
        return qns.min()
    }

    static func pickVideo(_ info: PlayInfo, _ c: PlayerStreamConstraints) -> DashStream? {
        let candidates = playableVideos(info, c)
        guard let target = targetQuality(available: candidates.map(\.id), c) else { return nil }
        let order = codecOrder(c.codec, av1Supported: c.av1Supported)
        func rank(_ s: DashStream) -> Int { order.firstIndex(of: s.codecFamily) ?? order.count }
        return candidates.filter { $0.id == target }.min { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.bandwidth > b.bandwidth
        }
    }

    /// Every audio track offered (normal, Dolby, FLAC), unique by id, best first.
    static func allAudios(_ info: PlayInfo) -> [DashStream] {
        var seen = Set<Int>()
        return (info.flacAudios + info.dolbyAudios + info.audios).filter { seen.insert($0.id).inserted }
    }

    static func pickAudio(_ info: PlayInfo, _ c: PlayerStreamConstraints) -> DashStream? {
        let all = allAudios(info)
        if let id = c.manualAudio, let s = all.first(where: { $0.id == id }),
           !(c.forceNormalAudio && isSpecialAudio(s)) {
            return s
        }
        if c.preferLossless && !c.forceNormalAudio {
            if let f = info.flacAudios.first { return f }
            if let d = info.dolbyAudios.first { return d }
        }
        if let normal = info.audios.first(where: { !isSpecialAudio($0) }) ?? info.audios.first { return normal }
        return c.forceNormalAudio ? nil : (info.dolbyAudios.first ?? info.flacAudios.first)
    }

    static func choose(_ info: PlayInfo, _ c: PlayerStreamConstraints) -> PlayerStreamChoice? {
        guard let video = pickVideo(info, c) else { return nil }
        return PlayerStreamChoice(video: video, audio: pickAudio(info, c))
    }

    /// The highest playable quality strictly below `qn` (fallback ladder step "lower quality").
    static func nextLowerQuality(below qn: Int, _ info: PlayInfo, _ c: PlayerStreamConstraints) -> Int? {
        playableVideos(info, c).map(\.id).filter { $0 < qn }.max()
    }

    /// An H.264 stream exists at or below `qn` (fallback ladder step "AVC").
    static func hasAVC(atOrBelow qn: Int, _ info: PlayInfo, _ c: PlayerStreamConstraints) -> Bool {
        var relaxed = c
        relaxed.forceAVC = true
        return playableVideos(info, relaxed).contains { $0.id <= qn }
    }

    /// Codec families available at `qn`, in display order.
    static func codecFamilies(at qn: Int, _ info: PlayInfo, _ c: PlayerStreamConstraints) -> [String] {
        var relaxed = c
        relaxed.forceAVC = false
        let present = Set(playableVideos(info, relaxed).filter { $0.id == qn }.map(\.codecFamily))
        return ["hevc", "avc", "av1", "other"].filter { present.contains($0) }
    }

    static func codecTitle(_ family: String) -> String {
        switch family {
        case "avc": return "AVC"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        default: return "杜比视界"
        }
    }

    static func codecPreference(forFamily family: String) -> VideoCodecPreference? {
        switch family {
        case "avc": return .avc
        case "hevc": return .hevc
        case "av1": return .av1
        default: return nil
        }
    }

    // MARK: Route key & URL refresh

    /// Ban-list scope for the BTR downloader: "BV…:p<cid>" (UGC) or "ep<id>" (PGC).
    static func routeKey(aid: Int64, bvid: String, cid: Int64, epId: Int64) -> String {
        if epId > 0 { return "ep\(epId)" }
        let base = bvid.isEmpty ? "av\(aid)" : bvid
        return "\(base):p\(cid)"
    }

    /// Re-fetches playurl (UGC or PGC) for the given ids.
    static func fetchPlayInfo(aid: Int64, bvid: String, cid: Int64, epId: Int64, seasonId: Int64,
                              quality: Int) async throws -> PlayInfo {
        if epId > 0 {
            return try await VideoAPI.pgcPlayInfo(epId: epId, cid: cid, qn: quality, aid: aid, bvid: bvid,
                                                  seasonId: seasonId)
        }
        return try await VideoAPI.playInfo(aid: aid, bvid: bvid, cid: cid, qn: quality)
    }

    /// `PlaybackRequest.refreshURLs`: fresh signed URLs for the SAME representations (same qn, codec and audio id).
    static func makeRefresher(aid: Int64, bvid: String, cid: Int64, epId: Int64, seasonId: Int64,
                              choice: PlayerStreamChoice) -> () async throws -> (video: DashStream, audio: DashStream?) {
        let videoId = choice.video.id
        let videoCodecId = choice.video.codecId
        let videoFamily = choice.video.codecFamily
        let videoCodecs = choice.video.codecs
        let audioId = choice.audio?.id
        return {
            let info = try await PlayerStreamPicker.fetchPlayInfo(aid: aid, bvid: bvid, cid: cid, epId: epId,
                                                                  seasonId: seasonId, quality: max(videoId, 80))
            let sameQuality = info.videos.filter { $0.id == videoId && $0.codecFamily == videoFamily }
            guard let video = sameQuality.first(where: { $0.codecs == videoCodecs && $0.codecId == videoCodecId })
                ?? sameQuality.first(where: { $0.codecId == videoCodecId })
                ?? sameQuality.first
            else { throw AccelerationEngineError.noAllowedURL }
            var audio: DashStream?
            if let audioId {
                audio = PlayerStreamPicker.allAudios(info).first { $0.id == audioId }
                if audio == nil { throw AccelerationEngineError.noAllowedURL }
            }
            return (video: video, audio: audio)
        }
    }

    /// `refreshURLs` of a 听视频 session, whose only track (passed as `video`) is the audio representation `audio`.
    static func makeAudioOnlyRefresher(aid: Int64, bvid: String, cid: Int64, epId: Int64, seasonId: Int64,
                                       audio: DashStream) -> () async throws -> (video: DashStream, audio: DashStream?) {
        let audioId = audio.id
        return {
            let info = try await PlayerStreamPicker.fetchPlayInfo(aid: aid, bvid: bvid, cid: cid, epId: epId,
                                                                  seasonId: seasonId, quality: 80)
            guard let fresh = PlayerStreamPicker.allAudios(info).first(where: { $0.id == audioId }) else {
                throw AccelerationEngineError.noAllowedURL
            }
            return (video: fresh, audio: nil)
        }
    }
}
