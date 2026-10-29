import Foundation
import AVFoundation
import AVKit
import Combine
import CoreMedia
import UIKit
import VideoToolbox

// The video player (contract: scratchpad CONTRACT-player.md).
//
// One reused AVPlayer per page. Every AVPlayerItem plays a local HLS (or progressive MP4) URL served by a
// `PlaybackSession` of `AccelerationEngine.shared` (BTR multi-connection download, or single connection when
// acceleration is off). This file holds the contract types and the playback core: load → playurl → stream pick →
// session → item, play intent, seeks, status, the bounded fallback ladder, quality / audio / codec switching,
// speed and hold-to-speed-up, and fullscreen. Side features live in PlayerController+Features.swift, the system
// integration (PiP, background, interruptions, Now Playing) in PlayerController+System.swift.

// MARK: - Contract types

/// What to play. Built by the detail page from VideoDetail / VideoPart / UgcEpisode / PGCEpisode.
struct PlaybackItem: Equatable {
    var aid: Int64
    var bvid: String
    var cid: Int64
    var epId: Int64 = 0            // non-zero → PGC (bangumi) playurl path
    var seasonId: Int64 = 0
    var title: String              // video / season title
    var subtitle: String = ""      // part ("P2 xxx") or episode title
    var cover: String = ""
    var ownerName: String = ""
    var ownerMid: Int64 = 0
    var duration: Double = 0       // seconds if known (0 = unknown)
    var desc: String = ""          // used by SmartSkip
    var chapters: [VideoChapter]? = nil
    var startTime: Double? = nil   // explicit start (e.g. history progress); nil → resume from server progress if enabled
    var isVertical: Bool = false   // portrait video (dimension.height > width, rotate handled)
}

enum PlayerStatus: Equatable {
    case idle, loading, playing, paused, buffering, ended
    case failed(String)
}

// MARK: - Player support types

enum PlayerDeviceSupport {
    /// `'av01'` FourCC (`kCMVideoCodecType_AV1`), spelled out so it does not depend on the SDK constant.
    private static let av1CodecType: CMVideoCodecType = 0x6176_3031
    static let av1HardwareDecode: Bool = VTIsHardwareDecodeSupported(av1CodecType)
    static var hdrEligible: Bool { AVPlayer.eligibleForHDRPlayback }
}

/// One row of the 画质 menu.
struct PlayerQualityEntry: Identifiable, Hashable {
    let qn: Int
    let title: String
    let playable: Bool
    /// 「大会员」 / 「登录」 / 「HDR」 … for greyed entries.
    let badge: String?
    var id: Int { qn }

    /// "1080P 高清" → "1080P" (bottom-bar label).
    var shortTitle: String {
        let first = title.split(separator: " ").first.map(String.init) ?? title
        return first.isEmpty ? title : first
    }
}

struct PlayerAudioEntry: Identifiable, Hashable {
    let id: Int
    let title: String
}

/// The 「跳过广告」 prompt currently shown.
struct PlayerSkipPrompt: Equatable {
    let segment: AdSegment
    let remaining: Double
}

/// 画面比例.
enum PlayerAspectMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch, ratio16x9, ratio4x3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "自适应"
        case .fill: return "填充"
        case .stretch: return "拉伸"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        }
    }
}

/// 定时关闭.
enum PlayerSleepTimer: Equatable {
    case off
    case minutes(Int)
    case endOfEpisode
}

enum PlayerSeekOrigin {
    case user, smartSkip, startup
}

enum PlayerInstallReason {
    case initial, switchStreams, fallback, endpoint, retry
}

enum PlayerFallbackStep: Hashable {
    case avc, direct, lowerQuality
}

enum PlayerLoadError: LocalizedError {
    case unsupportedCodec
    case noStream

    var errorDescription: String? {
        switch self {
        case .unsupportedCodec: return "当前设备不支持该视频的编码格式"
        case .noStream: return "没有可播放的视频流"
        }
    }
}

struct PlayerTimelineSnapshot: Equatable {
    var time: Double = 0
    var duration: Double = 0
    /// End of the buffered range containing `time`.
    var buffered: Double = 0
}

/// 4 Hz playback clock for the progress bar / time labels (kept apart from `PlayerController` so the detail page
/// does not re-render at that rate).
@MainActor
final class PlayerTimeline: ObservableObject {
    @Published private(set) var snapshot = PlayerTimelineSnapshot()

    func update(time: Double, duration: Double, buffered: Double) {
        let next = PlayerTimelineSnapshot(time: time.isFinite ? max(0, time) : 0,
                                          duration: duration.isFinite ? max(0, duration) : 0,
                                          buffered: buffered.isFinite ? max(0, buffered) : 0)
        if next != snapshot { snapshot = next }
    }

    func reset(duration: Double) {
        update(time: 0, duration: duration, buffered: 0)
    }
}

/// Owns things that must be cleaned up from a nonisolated `deinit`.
final class PlayerObserverBag {
    var timer: Timer?
    var itemTokens: [NSObjectProtocol] = []

    func removeItemTokens() {
        for token in itemTokens { NotificationCenter.default.removeObserver(token) }
        itemTokens = []
    }

    deinit {
        timer?.invalidate()
        for token in itemTokens { NotificationCenter.default.removeObserver(token) }
    }
}

// MARK: - Controller

@MainActor
final class PlayerController: ObservableObject {
    // MARK: Contract

    @Published private(set) var item: PlaybackItem?
    @Published private(set) var status: PlayerStatus = .idle
    /// Seconds; published about once per second (the controls use `timeline` for 4 Hz updates).
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isFullscreen = false
    /// Called when playback reaches the end (after SmartSkip etc.). The detail page decides auto-next.
    var onEnded: (() -> Void)?

    /// Optional: when set, the fullscreen bar shows 「下一集」 and the lock screen offers "next track".
    var onNext: (() -> Void)? {
        didSet { hasNext = onNext != nil }
    }
    @Published private(set) var hasNext = false

    // MARK: Stream & menu state

    @Published private(set) var qualityEntries: [PlayerQualityEntry] = []
    @Published private(set) var currentQuality = 0
    @Published private(set) var audioEntries: [PlayerAudioEntry] = []
    @Published private(set) var currentAudioId: Int?
    @Published private(set) var codecFamilies: [String] = []
    @Published private(set) var currentCodecFamily = ""
    /// Speed chosen in the 倍速 menu (session only, starts at 「默认播放速度」).
    @Published private(set) var rate: Double = 1
    /// Hold-to-speed-up active (长按倍速).
    @Published private(set) var isBoosting = false
    @Published private(set) var boostRate: Double = 2
    @Published private(set) var isVerticalVideo = false
    /// The video layer showed its first frame (the cover is hidden from then on).
    @Published private(set) var hasFirstFrame = false
    @Published private(set) var isAccelerated = false
    @Published private(set) var isProgressive = false
    /// 「正在切换至 1080P 高清…」 while a quality / audio / codec switch prepares.
    @Published private(set) var transientMessage: String?
    @Published var aspectMode: PlayerAspectMode = .fit {
        didSet { surface.aspectMode = aspectMode }
    }

    // MARK: Feature state (PlayerController+Features.swift / +System.swift)

    @Published var chapters: [VideoChapter] = []
    @Published var subtitleTracks: [SubtitleTrack] = []
    @Published var selectedSubtitleId: Int64?
    @Published var subtitleText: String?
    @Published var adSegments: [AdSegment] = []
    @Published var skipPrompt: PlayerSkipPrompt?
    @Published var pgcClips: [PGCClipInfo] = []
    @Published var clipPrompt: PGCClipInfo?
    @Published var resumeChipTime: Double?
    @Published var onlineCount: String?
    @Published var stats: AccelerationStats?
    @Published var networkSpeed: Double = 0
    @Published var sleepTimer: PlayerSleepTimer = .off
    @Published var sleepRemaining: Double?
    @Published var videoShot: VideoShotInfo?
    @Published var isPiPActive = false
    @Published var isPiPPossible = false

    // MARK: Owned objects

    let timeline = PlayerTimeline()
    let overlay = PlayerOverlayModel()
    let player: AVPlayer
    let surface: PlayerSurfaceView
    let heartbeat = HeartbeatReporter()
    let bag = PlayerObserverBag()
    let appRelay = PlayerAppEventRelay()
    let pipCoordinator = PlayerPiPCoordinator()

    // MARK: Feature storage (internal for the extension files)

    var loadGeneration = 0
    var sideTask: Task<Void, Never>?
    var smartSkipTask: Task<Void, Never>?
    var subtitleTask: Task<Void, Never>?
    var videoShotTask: Task<Void, Never>?
    var onlineTask: Task<Void, Never>?
    var resumeChipTask: Task<Void, Never>?
    var subtitleLines: [SubtitleLine] = []
    var subtitleCache: [Int64: [SubtitleLine]] = [:]
    var subtitleFetches: [Int64: Task<[SubtitleLine], Never>] = [:]
    var tracker: SmartSkipTracker?
    var dismissedClips: Set<String> = []
    var playInfo: PlayInfo?
    var extra: PlayerExtraInfo?
    var sleepDeadline: Date?
    var lastOnlineFetch: Date?
    var originalBrightness: CGFloat?
    var pip: AVPictureInPictureController?
    var pipPossibleObservation: NSKeyValueObservation?
    var stopAfterPiP = false
    var pausedByBackground = false
    var pausedByInterruption = false
    var lastExternalPauseAt: Double?
    var backgroundTask: Task<Void, Never>?
    var orientationTask: Task<Void, Never>?
    var containerVisible = false
    var generatingOrientation = false

    // MARK: Core storage

    private var streamGeneration = 0
    private var loadTask: Task<Void, Never>?
    /// Strong reference: the engine tracks sessions weakly (releasing it closes the token).
    private var session: PlaybackSession?
    private var playerItem: AVPlayerItem?
    private var choice: PlayerStreamChoice?
    private var playInfoFetchedAt: Date?
    private var manualQuality: Int?
    private var manualAudio: Int?
    private var codecOverride: VideoCodecPreference?
    private var forceAVC = false
    private var forceNormalAudio = false
    private var forceDirect = false
    private var fallbackSteps: Set<PlayerFallbackStep> = []
    /// The user's play intent (survives rebuilds; AVPlayer's own state is paused during them).
    private(set) var wantsToPlay = false
    private var itemReady = false
    private(set) var startupDone = false
    private(set) var isSeeking = false
    private var seekTarget: Double = 0
    private var seekToken = 0
    private var pendingStartTime: Double?
    private(set) var lastKnownPosition: Double = 0
    private var heartbeatStarted = false
    private var waitingSince: Double?
    private var stallReported = false
    private var endpointRebuildPending = false
    private var pendingSwitchToast: String?
    private var switchRevert: (quality: Int?, audio: Int?, codec: VideoCodecPreference?, forceAVC: Bool)?
    private var tickCount = 0
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var layerObservation: NSKeyValueObservation?
    private let fullscreenPresenter = PlayerFullscreenPresenter()
    private var fullscreenByRotation = false
    private var autoExitTask: Task<Void, Never>?

    init() {
        let avPlayer = AVPlayer()
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        // AirPlay video would hand 127.0.0.1 URLs to the receiver; audio routes / mirroring still work.
        avPlayer.allowsExternalPlayback = false
        player = avPlayer
        surface = PlayerSurfaceView(frame: .zero)
        let speed = AppSettings.shared.player.defaultSpeed
        rate = speed.isFinite && speed > 0 ? min(max(speed, 0.25), 4) : 1

        surface.attach(controller: self)
        overlay.isPlayingProvider = { [weak self] in self?.isPlayIntentActive ?? false }
        appRelay.owner = self
        pipCoordinator.owner = self
        observePlayer()
        setupPiP()
    }

    // MARK: Derived state

    /// The clock the UI, danmaku and engine use: the seek target while seeking, the start position while an item
    /// is starting, the player clock otherwise.
    func displayTime() -> Double {
        if isSeeking { return seekTarget }
        if !startupDone { return pendingStartTime ?? lastKnownPosition }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : lastKnownPosition
    }

    var isActuallyPlaying: Bool {
        startupDone && !isSeeking && player.timeControlStatus == .playing
    }

    /// The user wants playback and it is (about to be) running.
    var isPlayIntentActive: Bool {
        wantsToPlay && (status == .playing || status == .buffering)
    }

    var effectiveRate: Double { isBoosting ? boostRate : rate }

    var forwardBufferSeconds: Double { max(5, AppSettings.shared.acceleration.forwardBufferSeconds) }

    /// Live statistics of the current proxy session.
    var sessionStats: AccelerationStats? { session?.stats }

    /// The stream that is playing (for the stats overlay).
    var currentStreamDescription: String {
        guard let choice else { return isProgressive ? "MP4" : "" }
        var parts = [VideoQuality.title(for: choice.video.id), PlayerStreamPicker.codecTitle(choice.video.codecFamily)]
        if choice.video.width > 0 { parts.append("\(choice.video.width)×\(choice.video.height)") }
        if let audio = choice.audio { parts.append(DashStream.audioTitle(audio.id)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Contract API

    func load(_ newItem: PlaybackItem) {
        if let current = item, current == newItem {
            switch status {
            case .idle, .failed: break
            default: return
            }
        }
        autoExitTask?.cancel()
        teardown(reportHeartbeat: true)
        item = newItem
        isVerticalVideo = newItem.isVertical
        duration = max(0, newItem.duration)
        currentTime = 0
        lastKnownPosition = 0
        timeline.reset(duration: duration)
        status = .loading
        wantsToPlay = AppSettings.shared.player.autoPlay
        hasFirstFrame = false
        surface.danmaku.load(cid: newItem.cid, aid: newItem.aid, duration: newItem.duration)
        surface.reattachPlayerIfNeeded()
        overlay.prepareForNewItem()
        startTicking()
        let gen = loadGeneration
        loadTask = Task { [weak self] in await self?.performInitialLoad(newItem, generation: gen) }
        sideTask = Task { [weak self] in await self?.loadSideData(newItem, generation: gen) }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    func play() {
        guard item != nil else { return }
        switch status {
        case .failed:
            retry()
            return
        case .ended:
            wantsToPlay = true
            pausedByBackground = false
            pausedByInterruption = false
            performSeek(to: 0, origin: .user)
            startPlayback()
            return
        default:
            break
        }
        wantsToPlay = true
        pausedByBackground = false
        pausedByInterruption = false
        guard startupDone else {
            if status == .paused { status = .loading }
            return
        }
        startPlayback()
    }

    func pause() {
        wantsToPlay = false
        pausedByBackground = false
        pausedByInterruption = false
        if isBoosting {
            isBoosting = false
            applyRate()
        }
        player.pause()
        if startupDone {
            switch status {
            case .ended, .failed, .idle: break
            default: status = .paused
            }
        }
        if startupDone { heartbeat.tick(position: displayTime(), isPlaying: false) }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    func togglePlay() {
        switch status {
        case .ended, .failed: play()
        default: wantsToPlay ? pause() : play()
        }
    }

    func seek(to seconds: Double) {
        performSeek(to: seconds, origin: .user)
    }

    func seek(by delta: Double) {
        performSeek(to: displayTime() + delta, origin: .user)
    }

    func enterFullscreen() {
        enterFullscreen(byRotation: false, deviceOrientation: nil)
    }

    func exitFullscreen() {
        guard isFullscreen else { return }
        overlay.unlock()
        fullscreenByRotation = false
        isFullscreen = false
        surface.danmaku.isFullscreen = false
        overlay.fullscreenChanged()
        fullscreenPresenter.dismiss()
    }

    /// Stop & release. While Picture in Picture runs the player keeps going (kept alive) and stops when PiP ends.
    func stop() {
        if isPiPActive || pipCoordinator.isStarting || pipCoordinator.isActive {
            stopAfterPiP = true
            PlayerPiPKeeper.retain(self)
            return
        }
        performStop()
    }

    func performStop() {
        stopAfterPiP = false
        autoExitTask?.cancel()
        if isFullscreen { exitFullscreen() }
        teardown(reportHeartbeat: true)
        item = nil
        status = .idle
        currentTime = 0
        duration = 0
        wantsToPlay = false
        hasFirstFrame = false
        timeline.reset(duration: 0)
        stopTicking()
        surface.danmaku.load(cid: 0, aid: 0, duration: 0)
        PlayerNowPlayingCenter.shared.release(self)
        restoreBrightness()
        overlay.reset()
        containerVisible = false
        stopOrientationObserving()
        PlayerPiPKeeper.release(self)
    }

    /// 重试 / 重载视频.
    func retry() {
        guard let current = item else { return }
        guard playInfo != nil else {
            load(current)
            wantsToPlay = true
            return
        }
        wantsToPlay = true
        fallbackSteps = []
        forceAVC = false
        forceNormalAudio = false
        forceDirect = false
        status = .loading
        rebuild(position: lastKnownPosition, reason: .retry)
    }

    // MARK: Speed

    func setRate(_ newRate: Double) {
        guard newRate.isFinite, newRate > 0 else { return }
        rate = min(max(newRate, 0.25), 4)
        applyRate()
    }

    /// Long-press start: only while playing. Returns whether the boost started.
    @discardableResult
    func beginBoost() -> Bool {
        let s = AppSettings.shared.player
        guard s.longPressSpeedEnabled, !isBoosting, status == .playing else { return false }
        boostRate = min(max(s.longPressSpeed, 0.5), 4)
        isBoosting = true
        applyRate()
        return true
    }

    /// Long-press end: the speed set before the press is restored.
    func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        applyRate()
    }

    private func applyRate() {
        let r = Float(effectiveRate)
        player.defaultRate = r
        if player.rate != 0 { player.rate = r }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    // MARK: Quality / audio / codec

    func selectQuality(_ qn: Int) {
        guard let entry = qualityEntries.first(where: { $0.qn == qn }) else { return }
        guard entry.playable else {
            switch entry.badge {
            case "登录": ToastCenter.shared.show("该画质需要登录后观看")
            case "HDR": ToastCenter.shared.show("当前设备或设置不支持 HDR，可在「播放设置」中开启")
            case "不支持": ToastCenter.shared.show("当前设备不支持该画质的编码格式")
            default: ToastCenter.shared.show("该画质需要大会员")
            }
            return
        }
        AppSettings.shared.player.preferredQuality = qn
        guard qn != currentQuality, !isProgressive else { return }
        beginSwitch(message: "正在切换至 \(entry.title)…", toast: "画质已变为：\(entry.title)")
        manualQuality = qn
        forceAVC = false
        fallbackSteps.subtract([.avc, .lowerQuality])
        rebuild(position: nil, reason: .switchStreams)
    }

    func selectAudio(_ id: Int) {
        guard id != currentAudioId, !isProgressive else { return }
        let title = DashStream.audioTitle(id)
        beginSwitch(message: "正在切换音质…", toast: "音质已切换为：\(title)")
        manualAudio = id
        forceNormalAudio = false
        rebuild(position: nil, reason: .switchStreams)
    }

    func selectCodec(_ family: String) {
        guard family != currentCodecFamily, !isProgressive,
              let preference = PlayerStreamPicker.codecPreference(forFamily: family) else { return }
        beginSwitch(message: "正在切换解码格式…", toast: "解码格式已切换为：\(PlayerStreamPicker.codecTitle(family))")
        codecOverride = preference
        forceAVC = family == "avc"
        manualQuality = manualQuality ?? (currentQuality > 0 ? currentQuality : nil)
        rebuild(position: nil, reason: .switchStreams)
    }

    private func beginSwitch(message: String, toast: String) {
        if switchRevert == nil {
            switchRevert = (manualQuality, manualAudio, codecOverride, forceAVC)
        }
        transientMessage = message
        pendingSwitchToast = toast
    }

    private func constraints() -> PlayerStreamConstraints {
        let p = AppSettings.shared.player
        return PlayerStreamConstraints(preferredQuality: p.preferredQuality,
                                       codec: codecOverride ?? p.preferredCodec,
                                       av1Supported: PlayerDeviceSupport.av1HardwareDecode,
                                       hdrAllowed: p.allowHDR && PlayerDeviceSupport.hdrEligible,
                                       preferLossless: p.preferLosslessAudio,
                                       manualQuality: manualQuality, manualAudio: manualAudio,
                                       forceAVC: forceAVC, forceNormalAudio: forceNormalAudio)
    }

    private func refreshStreamMenus() {
        guard let info = playInfo else {
            qualityEntries = []
            audioEntries = []
            codecFamilies = []
            return
        }
        var c = constraints()
        c.manualQuality = nil
        c.forceAVC = false
        let playable = Set(PlayerStreamPicker.playableVideos(info, c).map(\.id))
        let streamIds = Set(info.videos.map(\.id))
        var options = info.qualities
        for id in streamIds where !options.contains(where: { $0.qn == id }) {
            options.append(QualityOption(qn: id, title: VideoQuality.title(for: id)))
        }
        options.sort { $0.qn > $1.qn }
        let loggedIn = BiliHTTP.shared.isLoggedIn
        if isProgressive {
            let current = info.quality
            qualityEntries = options.map { o in
                PlayerQualityEntry(qn: o.qn, title: o.title, playable: o.qn == current,
                                   badge: o.qn == current ? nil : (o.needLogin && !loggedIn ? "登录" : "大会员"))
            }
            currentQuality = current
        } else {
            qualityEntries = options.map { o in
                let ok = playable.contains(o.qn)
                var badge: String?
                if !ok {
                    if !streamIds.contains(o.qn) {
                        badge = o.needLogin && !loggedIn ? "登录" : "大会员"
                    } else if PlayerStreamPicker.hdrQualities.contains(o.qn) {
                        badge = "HDR"
                    } else {
                        badge = "不支持"
                    }
                }
                return PlayerQualityEntry(qn: o.qn, title: o.title, playable: ok, badge: badge)
            }
            currentQuality = choice?.video.id ?? info.quality
        }
        audioEntries = PlayerStreamPicker.allAudios(info).map { PlayerAudioEntry(id: $0.id, title: DashStream.audioTitle($0.id)) }
        currentAudioId = choice?.audio?.id
        codecFamilies = isProgressive ? [] : PlayerStreamPicker.codecFamilies(at: currentQuality, info, c)
        currentCodecFamily = choice?.video.codecFamily ?? ""
    }

    // MARK: Loading

    private func performInitialLoad(_ target: PlaybackItem, generation gen: Int) async {
        let quality = AppSettings.shared.player.preferredQuality
        let info: PlayInfo
        do {
            info = try await PlayerStreamPicker.fetchPlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid,
                                                              epId: target.epId, seasonId: target.seasonId,
                                                              quality: quality)
        } catch {
            guard gen == loadGeneration, !Task.isCancelled else { return }
            if error is CancellationError { return }
            if let b = error as? BiliError, b == .cancelled { return }
            fail(Self.describe(error))
            return
        }
        guard gen == loadGeneration, !Task.isCancelled else { return }
        if info.isDRM {
            fail("该内容受版权保护（DRM），暂不支持播放")
            return
        }
        playInfo = info
        playInfoFetchedAt = Date()
        if info.duration > 0 {
            duration = info.duration
            timeline.update(time: timeline.snapshot.time, duration: info.duration, buffered: 0)
        }
        if target.epId > 0 { pgcClips = info.clips }
        if info.isPreview {
            ToastCenter.shared.show("当前为试看片段，开通大会员可观看完整版", duration: 3)
        } else if info.isTrial, target.epId == 0 {
            ToastCenter.shared.show("试看中，充电后可观看完整视频", duration: 3)
        }
        let start = resolveStartPosition(target, info)
        lastKnownPosition = start
        if start > 0 {
            timeline.update(time: start, duration: duration, buffered: 0)
            currentTime = start
            showResumeChip(at: start)
        }
        await installStreams(position: start, generation: streamGeneration, reason: .initial)
    }

    /// `startTime` (explicit, 0 = from the beginning) > server progress (same cid, not within 5 s of the end).
    private func resolveStartPosition(_ target: PlaybackItem, _ info: PlayInfo) -> Double {
        let total = info.duration > 0 ? info.duration : target.duration
        func usable(_ t: Double) -> Bool { t.isFinite && t > 0 && (total <= 0 || t < total - 5) }
        if let explicit = target.startTime { return usable(explicit) ? explicit : 0 }
        guard AppSettings.shared.player.resumeProgress else { return 0 }
        let sameCid = info.lastPlayCid == target.cid || (info.lastPlayCid == 0 && target.epId > 0)
        return sameCid && usable(info.lastPlayTime) ? info.lastPlayTime : 0
    }

    /// Picks streams, prepares a session (accelerated → direct → progressive) and installs a new item.
    private func installStreams(position: Double?, generation sgen: Int, reason: PlayerInstallReason) async {
        guard let target = item, var info = playInfo else { return }
        let lgen = loadGeneration
        func current() -> Bool { sgen == streamGeneration && lgen == loadGeneration && !Task.isCancelled }

        // Signed URLs expire after a while: refresh an old playurl answer before a rebuild.
        if reason != .initial, let fetchedAt = playInfoFetchedAt, Date().timeIntervalSince(fetchedAt) > 20 * 60 {
            let fresh = try? await PlayerStreamPicker.fetchPlayInfo(aid: target.aid, bvid: target.bvid,
                                                                    cid: target.cid, epId: target.epId,
                                                                    seasonId: target.seasonId,
                                                                    quality: AppSettings.shared.player.preferredQuality)
            guard current() else { return }
            if let fresh, !fresh.isDRM, fresh.isDash || !fresh.durl.isEmpty {
                info = fresh
                playInfo = fresh
                playInfoFetchedAt = Date()
            }
        }

        let settings = AppSettings.shared
        let pgc = target.epId > 0
        let wantAccel = settings.acceleration.enabled && (!pgc || settings.acceleration.accelerateBangumi) && !forceDirect
        let allowHDR = settings.player.allowHDR && PlayerDeviceSupport.hdrEligible
        let total = info.duration > 0 ? info.duration : target.duration
        let attempts: [Bool] = wantAccel ? [true, false] : [false]
        let routeKey = PlayerStreamPicker.routeKey(aid: target.aid, bvid: target.bvid, cid: target.cid, epId: target.epId)
        var lastError: Error?

        if info.isDash {
            if let picked = PlayerStreamPicker.choose(info, constraints()) {
                for accelerate in attempts {
                    do {
                        let request = PlaybackRequest(
                            routeKey: routeKey, video: picked.video, audio: picked.audio, duration: total,
                            accelerate: accelerate, allowHDR: allowHDR,
                            refreshURLs: PlayerStreamPicker.makeRefresher(aid: target.aid, bvid: target.bvid,
                                                                          cid: target.cid, epId: target.epId,
                                                                          seasonId: target.seasonId, choice: picked))
                        let made = try await AccelerationEngine.shared.prepare(request)
                        guard current() else {
                            made.close()
                            return
                        }
                        if wantAccel && !accelerate {
                            forceDirect = true
                            fallbackSteps.insert(.direct)
                        }
                        install(made, choice: picked, accelerated: accelerate, progressive: false,
                                position: position, generation: sgen)
                        return
                    } catch {
                        guard current(), !(error is CancellationError) else { return }
                        lastError = error
                    }
                }
            } else {
                lastError = PlayerLoadError.unsupportedCodec
            }
        }

        if let segment = info.durl.first {
            if info.durl.count > 1, reason == .initial {
                ToastCenter.shared.show("该视频为分段视频，目前只能播放第一段")
            }
            for accelerate in attempts {
                do {
                    let made = try await AccelerationEngine.shared.prepareProgressive(routeKey: routeKey, segment: segment,
                                                                                      accelerate: accelerate)
                    guard current() else {
                        made.close()
                        return
                    }
                    if wantAccel && !accelerate {
                        forceDirect = true
                        fallbackSteps.insert(.direct)
                    }
                    install(made, choice: nil, accelerated: accelerate, progressive: true, position: position,
                            generation: sgen)
                    return
                } catch {
                    guard current(), !(error is CancellationError) else { return }
                    lastError = error
                }
            }
        }

        guard current() else { return }
        if reason == .switchStreams, startupDone {
            // The previous item is still playing: keep it and undo the menu choice.
            if let revert = switchRevert {
                manualQuality = revert.quality
                manualAudio = revert.audio
                codecOverride = revert.codec
                forceAVC = revert.forceAVC
            }
            switchRevert = nil
            transientMessage = nil
            pendingSwitchToast = nil
            refreshStreamMenus()
            ToastCenter.shared.show("切换失败：\(Self.describe(lastError ?? PlayerLoadError.noStream))")
            return
        }
        fail(Self.describe(lastError ?? PlayerLoadError.noStream))
    }

    private func install(_ newSession: PlaybackSession, choice picked: PlayerStreamChoice?, accelerated: Bool,
                         progressive: Bool, position: Double?, generation sgen: Int) {
        let start = max(0, position ?? displayTime())
        let initial = !heartbeatStarted
        removeItemObservers()
        startupDone = false
        itemReady = false
        isSeeking = false
        seekToken += 1
        // The new item must not start from 0 before the start seek.
        player.pause()
        pendingStartTime = start > 0.5 ? start : nil
        lastKnownPosition = start
        waitingSince = ProcessInfo.processInfo.systemUptime
        stallReported = false
        endpointRebuildPending = false

        let old = session
        session = newSession
        choice = picked
        isAccelerated = accelerated
        isProgressive = progressive
        refreshStreamMenus()
        switch status {
        case .ended:
            status = .paused
        case .failed:
            status = .loading
        default:
            if initial || !hasFirstFrame {
                status = .loading
            } else {
                status = wantsToPlay ? .buffering : .paused
            }
        }

        let asset = AVURLAsset(url: newSession.url)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = forwardBufferSeconds
        newItem.preferredPeakBitRate = 0
        newItem.audioTimePitchAlgorithm = .timeDomain
        if start > 0.5 { newSession.playerWillSeek(to: start, outsideBuffer: true) }
        playerItem = newItem
        observeItem(newItem, generation: sgen)
        player.replaceCurrentItem(with: newItem)
        old?.close()
        if !initial { tracker?.replaceSegments(adSegments) }
    }

    /// Rebuilds the item (same video) at `position` (nil = the current time), keeping the play intent.
    private func rebuild(position: Double?, reason: PlayerInstallReason) {
        guard item != nil, playInfo != nil else { return }
        streamGeneration += 1
        loadTask?.cancel()
        let sgen = streamGeneration
        loadTask = Task { [weak self] in
            await self?.installStreams(position: position, generation: sgen, reason: reason)
        }
    }

    private func teardown(reportHeartbeat: Bool) {
        loadGeneration += 1
        streamGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        sideTask?.cancel()
        sideTask = nil
        cancelFeatureTasks()
        if reportHeartbeat, heartbeatStarted { heartbeat.stop(position: lastKnownPosition) }
        heartbeatStarted = false
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        session?.close()
        session = nil
        playerItem = nil
        playInfo = nil
        extra = nil
        choice = nil
        playInfoFetchedAt = nil
        manualQuality = nil
        manualAudio = nil
        codecOverride = nil
        forceAVC = false
        forceNormalAudio = false
        forceDirect = false
        fallbackSteps = []
        itemReady = false
        startupDone = false
        isSeeking = false
        seekToken += 1
        pendingStartTime = nil
        waitingSince = nil
        stallReported = false
        endpointRebuildPending = false
        pendingSwitchToast = nil
        switchRevert = nil
        transientMessage = nil
        isBoosting = false
        player.defaultRate = Float(rate)
        qualityEntries = []
        audioEntries = []
        codecFamilies = []
        currentQuality = 0
        currentAudioId = nil
        currentCodecFamily = ""
        isAccelerated = false
        isProgressive = false
        resetFeatureState()
    }

    private func fail(_ message: String) {
        status = .failed(message)
        wantsToPlay = false
        isBoosting = false
        player.pause()
        transientMessage = nil
        skipPrompt = nil
        overlay.showControls()
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
        let ns = error as NSError
        return ns.localizedDescription.isEmpty ? "播放失败" : ns.localizedDescription
    }

    // MARK: Item observation

    private func observePlayer() {
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.timeControlChanged() }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.timeControlChanged() }
            },
        ]
        layerObservation = surface.videoView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.layerReadinessChanged() }
        }
    }

    private func layerReadinessChanged() {
        if surface.videoView.playerLayer.isReadyForDisplay, item != nil, !hasFirstFrame { hasFirstFrame = true }
    }

    private func observeItem(_ observed: AVPlayerItem, generation sgen: Int) {
        itemObservations = [
            observed.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged(generation: sgen) }
            },
        ]
        let nc = NotificationCenter.default
        bag.itemTokens = [
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: observed, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.itemDidPlayToEnd(generation: sgen) }
            },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: observed, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription
                Task { @MainActor [weak self] in self?.itemFailed(message: message, generation: sgen) }
            },
            nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: observed, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.itemStalled(generation: sgen) }
            },
        ]
    }

    private func removeItemObservers() {
        for o in itemObservations { o.invalidate() }
        itemObservations = []
        bag.removeItemTokens()
    }

    private func itemStatusChanged(generation sgen: Int) {
        guard sgen == streamGeneration, let observed = playerItem else { return }
        switch observed.status {
        case .readyToPlay:
            guard !itemReady else { return }
            itemReady = true
            refreshDurationFromItem()
            if let start = pendingStartTime {
                pendingStartTime = nil
                performSeek(to: start, origin: .startup)
            } else {
                finishStartup()
            }
        case .failed:
            handleFailure(message: observed.error.map { ($0 as NSError).localizedDescription })
        default:
            break
        }
    }

    private func itemFailed(message: String?, generation sgen: Int) {
        guard sgen == streamGeneration else { return }
        handleFailure(message: message)
    }

    private func itemStalled(generation sgen: Int) {
        guard sgen == streamGeneration, startupDone, wantsToPlay, !isSeeking, !stallReported else { return }
        stallReported = true
        session?.playerDidStall()
    }

    private func refreshDurationFromItem() {
        guard let observed = playerItem else { return }
        let d = observed.duration.seconds
        if d.isFinite, d > 0, abs(d - duration) > 0.01 {
            duration = d
        }
    }

    private func finishStartup() {
        guard itemReady, !startupDone, let target = item else { return }
        startupDone = true
        waitingSince = nil
        lastKnownPosition = displayTime()
        if !heartbeatStarted {
            heartbeatStarted = true
            heartbeat.start(heartbeatContext(target), position: lastKnownPosition)
        }
        if wantsToPlay {
            startPlayback()
        } else {
            status = .paused
        }
        if let toast = pendingSwitchToast {
            ToastCenter.shared.show(toast)
            pendingSwitchToast = nil
        }
        transientMessage = nil
        switchRevert = nil
        smartSkipTick(time: lastKnownPosition, playing: wantsToPlay)
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    private func heartbeatContext(_ target: PlaybackItem) -> HeartbeatContext {
        let total = duration > 0 ? duration : target.duration
        if target.epId > 0 {
            return HeartbeatContext(aid: target.aid, bvid: target.bvid, cid: target.cid, epId: target.epId,
                                    seasonId: target.seasonId, type: 4, duration: total)
        }
        return .ugc(aid: target.aid, bvid: target.bvid, cid: target.cid, duration: total)
    }

    private func startPlayback() {
        guard player.currentItem != nil else { return }
        let r = Float(effectiveRate)
        player.defaultRate = r
        player.play()
        if player.rate != r { player.rate = r }
        syncStatus()
        PlayerNowPlayingCenter.shared.claim(self)
    }

    private var isNearEnd: Bool {
        duration > 0 && displayTime() >= duration - 0.6
    }

    private func timeControlChanged() {
        guard let observed = player.currentItem, observed === playerItem else { return }
        let tcs = player.timeControlStatus
        let now = ProcessInfo.processInfo.systemUptime
        if startupDone {
            switch tcs {
            case .playing:
                waitingSince = nil
                stallReported = false
                if !wantsToPlay { wantsToPlay = true }   // started from PiP / lock screen / headphones
            case .waitingToPlayAtSpecifiedRate:
                if waitingSince == nil { waitingSince = now }
                if !wantsToPlay, player.rate > 0 { wantsToPlay = true }
                if player.reasonForWaitingToPlay == .toMinimizeStalls, wantsToPlay, !isSeeking, !stallReported {
                    stallReported = true
                    session?.playerDidStall()
                }
            case .paused:
                waitingSince = nil
                if wantsToPlay, !isSeeking, status != .ended, !isNearEnd {
                    // Paused by the system (route change, interruption, PiP / Control Center button).
                    wantsToPlay = false
                    lastExternalPauseAt = now
                }
                if isBoosting {
                    isBoosting = false
                    applyRate()
                }
            @unknown default:
                break
            }
        }
        syncStatus()
        surface.danmaku.playbackStateDidChange()
        if startupDone {
            heartbeat.tick(position: displayTime(), isPlaying: tcs == .playing)
            smartSkipTick(time: displayTime(), playing: tcs == .playing)
        }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    private func syncStatus() {
        guard item != nil, startupDone else { return }
        switch status {
        case .ended, .failed, .idle: return
        default: break
        }
        let next: PlayerStatus
        switch player.timeControlStatus {
        case .playing: next = .playing
        case .waitingToPlayAtSpecifiedRate: next = .buffering
        case .paused: next = wantsToPlay ? .buffering : .paused
        @unknown default: next = status
        }
        if next != status {
            status = next
            overlay.playbackStateChanged(playing: next == .playing)
        }
    }

    private func handleFailure(message: String?) {
        guard item != nil, let info = playInfo else {
            fail(message.map { "播放失败：\($0)" } ?? "播放失败")
            return
        }
        let position = lastKnownPosition
        let c = constraints()
        if !fallbackSteps.contains(.avc), let current = choice {
            let needsAVC = current.video.codecFamily != "avc"
                && PlayerStreamPicker.hasAVC(atOrBelow: current.video.id, info, c)
            let needsNormalAudio = PlayerStreamPicker.isSpecialAudio(current.audio)
            if needsAVC || needsNormalAudio {
                fallbackSteps.insert(.avc)
                if needsAVC { forceAVC = true }
                if needsNormalAudio { forceNormalAudio = true }
                beginFallback()
                rebuild(position: position, reason: .fallback)
                return
            }
        }
        if !fallbackSteps.contains(.direct), isAccelerated {
            fallbackSteps.insert(.direct)
            forceDirect = true
            beginFallback()
            rebuild(position: position, reason: .fallback)
            return
        }
        if !fallbackSteps.contains(.lowerQuality), let current = choice,
           let lower = PlayerStreamPicker.nextLowerQuality(below: current.video.id, info, c) {
            fallbackSteps.insert(.lowerQuality)
            manualQuality = lower
            beginFallback()
            rebuild(position: position, reason: .fallback)
            return
        }
        fail(message.map { "播放失败：\($0)" } ?? "播放失败")
    }

    private func beginFallback() {
        switchRevert = nil
        pendingSwitchToast = nil
        transientMessage = nil
        if case .failed = status { return }
        status = hasFirstFrame ? .buffering : .loading
    }

    private func itemDidPlayToEnd(generation sgen: Int) {
        guard sgen == streamGeneration, startupDone else { return }
        let end = duration > 0 ? duration : displayTime()
        lastKnownPosition = end
        currentTime = end
        timeline.update(time: end, duration: duration, buffered: end)
        status = .ended
        wantsToPlay = false
        if isBoosting {
            isBoosting = false
            applyRate()
        }
        heartbeat.finished(position: end)
        skipPrompt = nil
        clipPrompt = nil
        overlay.playbackEnded()
        PlayerNowPlayingCenter.shared.playbackChanged(self)
        if sleepTimer == .endOfEpisode {
            sleepTimer = .off
            sleepRemaining = nil
            ToastCenter.shared.show("定时时间已到，已暂停")
            scheduleAutoExitFullscreen()
            return
        }
        onEnded?()
        scheduleAutoExitFullscreen()
    }

    /// 「自动退出全屏」 when nothing new was loaded after the end.
    private func scheduleAutoExitFullscreen() {
        guard isFullscreen else { return }
        autoExitTask?.cancel()
        autoExitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, self.status == .ended else { return }
            self.exitFullscreen()
        }
    }

    // MARK: Seeking

    func performSeek(to raw: Double, origin: PlayerSeekOrigin) {
        guard raw.isFinite, item != nil else { return }
        let total = duration
        var target = max(0, raw)
        if total > 0 { target = min(target, total) }
        guard itemReady, let observed = playerItem, player.currentItem === observed else {
            // Not ready yet: becomes the start position.
            pendingStartTime = target
            lastKnownPosition = target
            currentTime = target
            timeline.update(time: target, duration: total, buffered: 0)
            return
        }
        if status == .ended, total <= 0 || target < total - 0.5 {
            status = wantsToPlay ? .buffering : .paused
        }
        let outside = !Self.isBuffered(target, in: observed)
        session?.playerWillSeek(to: target, outsideBuffer: outside)
        seekToken += 1
        let token = seekToken
        isSeeking = true
        seekTarget = target
        lastKnownPosition = target
        currentTime = target
        timeline.update(time: target, duration: total, buffered: timeline.snapshot.buffered)
        if origin != .startup {
            surface.danmaku.seek(to: target)
            heartbeat.seeked(to: target)
            tracker?.didSeek(to: target)
            if origin == .user { skipPrompt = nil }
        }
        updateSubtitle(at: target)
        let time = CMTime(seconds: target, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in self?.seekFinished(token: token, finished: finished) }
        }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    private func seekFinished(token: Int, finished: Bool) {
        guard token == seekToken else { return }
        isSeeking = false
        lastKnownPosition = displayTime()
        if !startupDone {
            finishStartup()
            return
        }
        syncStatus()
        surface.danmaku.playbackStateDidChange()
    }

    private static func isBuffered(_ t: Double, in observed: AVPlayerItem) -> Bool {
        for value in observed.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = r.start.seconds
            let end = start + r.duration.seconds
            if start.isFinite, end.isFinite, t >= start, t <= end { return true }
        }
        return false
    }

    /// (end of the range containing `t`, seconds buffered ahead of `t`).
    private static func bufferInfo(at t: Double, in observed: AVPlayerItem) -> (end: Double, ahead: Double) {
        for value in observed.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = r.start.seconds
            let end = start + r.duration.seconds
            guard start.isFinite, end.isFinite else { continue }
            if t >= start - 0.5, t <= end { return (end, max(0, end - t)) }
        }
        return (t, 0)
    }

    // MARK: Tick (4 Hz)

    private func startTicking() {
        guard bag.timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        bag.timer = timer
    }

    private func stopTicking() {
        bag.timer?.invalidate()
        bag.timer = nil
    }

    private func tick() {
        guard item != nil else { return }
        tickCount &+= 1
        let t = displayTime()
        if itemReady { refreshDurationFromItem() }
        var ahead: Double = 0
        var bufferedEnd = t
        if itemReady, let observed = playerItem {
            (bufferedEnd, ahead) = Self.bufferInfo(at: t, in: observed)
        }
        timeline.update(time: t, duration: duration, buffered: bufferedEnd)
        if Int(t) != Int(currentTime) || abs(t - currentTime) >= 1 { currentTime = t }
        if startupDone, !isSeeking { lastKnownPosition = t }
        let playing = isActuallyPlaying

        if let session {
            if !session.isEndpointValid {
                if !endpointRebuildPending, playInfo != nil {
                    endpointRebuildPending = true
                    rebuild(position: nil, reason: .endpoint)
                }
            } else {
                let forward = playerItem?.preferredForwardBufferDuration ?? forwardBufferSeconds
                let r = player.rate > 0 ? Double(player.rate) : effectiveRate
                session.update(time: t, rate: r, playing: playing, bufferedAhead: ahead,
                               cacheFull: ahead >= forward - 1)
            }
        }
        smartSkipTick(time: t, playing: playing)
        clipTick(time: t)
        updateSubtitle(at: t)
        runWatchdog()
        if tickCount % 4 == 0 { secondTick(time: t, playing: playing) }
    }

    private func secondTick(time t: Double, playing: Bool) {
        if startupDone { heartbeat.tick(position: t, isPlaying: playing) }
        refreshStats()
        sleepTimerTick()
        onlineCountTick()
        syncPiPSettings()
    }

    /// Accelerated playback waiting ≥ 60 s (monotonic) while it should play → one fallback to direct.
    private func runWatchdog() {
        guard isAccelerated, wantsToPlay, !fallbackSteps.contains(.direct), let since = waitingSince else { return }
        let stuck = !startupDone || status == .buffering
        guard stuck, ProcessInfo.processInfo.systemUptime - since >= 60 else { return }
        fallbackSteps.insert(.direct)
        forceDirect = true
        waitingSince = nil
        ToastCenter.shared.show("加速线路长时间缓冲，已切换为直连")
        rebuild(position: nil, reason: .fallback)
    }

    // MARK: Fullscreen

    func enterFullscreen(byRotation: Bool, deviceOrientation: UIDeviceOrientation?) {
        guard !isFullscreen, item != nil else { return }
        autoExitTask?.cancel()
        let mask: UIInterfaceOrientationMask
        let orientation: UIInterfaceOrientation
        let rotateTo: UIInterfaceOrientationMask
        if isVerticalVideo {
            mask = .portrait
            orientation = .portrait
            rotateTo = .portrait
        } else {
            // Device landscapeRight (home button left) = interface landscapeLeft.
            let device = deviceOrientation ?? UIDevice.current.orientation
            if device == .landscapeRight {
                orientation = .landscapeLeft
                rotateTo = .landscapeLeft
            } else {
                orientation = .landscapeRight
                rotateTo = .landscapeRight
            }
            mask = .landscape
        }
        fullscreenByRotation = byRotation
        OrientationManager.shared.lock(mask, rotateTo: rotateTo)
        isFullscreen = true
        surface.danmaku.isFullscreen = true
        overlay.fullscreenChanged()
        if !fullscreenPresenter.present(self, mask: mask, orientation: orientation) {
            isFullscreen = false
            fullscreenByRotation = false
            surface.danmaku.isFullscreen = false
            overlay.fullscreenChanged()
            OrientationManager.shared.restorePortrait()
        }
    }

    /// Back in fullscreen: unlock first if locked, otherwise exit fullscreen.
    func fullscreenBack() {
        if overlay.isLocked {
            overlay.toggleLock()
        } else {
            exitFullscreen()
        }
    }

    func toggleFullscreen() {
        isFullscreen ? exitFullscreen() : enterFullscreen()
    }

    // MARK: Container visibility & rotation

    func containerDidAppear() {
        containerVisible = true
        startOrientationObserving()
        if item != nil { startTicking() }
    }

    func containerDidDisappear() {
        // The fullscreen presentation hides the inline container: not a real disappearance.
        guard !isFullscreen else { return }
        containerVisible = false
        stopOrientationObserving()
    }

    func startOrientationObserving() {
        guard !generatingOrientation else { return }
        generatingOrientation = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    func stopOrientationObserving() {
        orientationTask?.cancel()
        guard generatingOrientation, !isFullscreen else { return }
        generatingOrientation = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// From `PlayerAppEventRelay` (UIDevice.orientationDidChangeNotification).
    func deviceOrientationChanged() {
        guard generatingOrientation else { return }
        orientationTask?.cancel()
        let orientation = UIDevice.current.orientation
        orientationTask = Task { [weak self] in
            // Ignore passing orientations while the phone is being turned.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, UIDevice.current.orientation == orientation else { return }
            self.applyDeviceOrientation(orientation)
        }
    }

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        guard AppSettings.shared.player.autoFullscreenOnRotate, !overlay.isLocked, item != nil,
              UIApplication.shared.applicationState == .active, !isPiPActive else { return }
        if case .failed = status { return }
        if isFullscreen {
            if orientation == .portrait, fullscreenByRotation, !isVerticalVideo { exitFullscreen() }
        } else if containerVisible, orientation.isLandscape, !isVerticalVideo, overlay.sheet == nil,
                  !PlayerFullscreenPresenter.isModalPresented() {
            enterFullscreen(byRotation: true, deviceOrientation: orientation)
        }
    }
}
