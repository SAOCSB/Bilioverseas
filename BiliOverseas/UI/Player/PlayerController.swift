import Foundation
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
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
/// A swipe on a vertical video: on to the next one (finger up), or back to the one before.
enum PlayerVideoSwipe {
    case next, previous
}

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
    /// A downloaded file (离线缓存): AVPlayer plays it directly — no playurl, heartbeat or proxy, and no quality /
    /// codec / CDN menus. Danmaku and SmartSkip still load when online (failures are ignored).
    var localFileURL: URL? = nil
}

/// One entry of the in-player 「选集」 list (parts, 合集 episodes or PGC episodes), supplied by the detail page.
struct PlayerEpisodeEntry: Identifiable, Equatable {
    /// Opaque to the player and handed back through `onSelectEpisode`. Parts use `partID(cid:)`, which the
    /// 「上次看到第N P」 chip looks up.
    let id: String
    let title: String
    var badge: String? = nil
    var isCurrent = false

    static func partID(cid: Int64) -> String { "p\(cid)" }
}

/// The fullscreen 点赞 / 投币 / 收藏 / 分享 row (features.md §2.2), supplied by the detail page, and what the
/// vertical-video screen shows beside it (`VerticalVideoViews.swift`), where the 短视频 feed supplies it too.
struct PlayerFullscreenActions: Equatable {
    var liked = false
    var coined = false
    var favored = false
    var likeCount: Int64 = 0
    var commentCount: Int64 = 0
    var coinCount: Int64 = 0
    var favoriteCount: Int64 = 0
    var shareCount: Int64 = 0
    var viewCount: Int64 = 0
    var shareURL: URL?
    var shareTitle = ""
    var ownerName = ""
    var ownerFace = ""
    var ownerFans: Int64 = 0
    var following = false
    /// There is an uploader, and it is not the viewer.
    var canFollow = false
    var onLike: () -> Void = {}
    /// Long press on 点赞: 一键三连.
    var onTriple: () -> Void = {}
    var onComments: () -> Void = {}
    var onCoin: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onFollow: () -> Void = {}
    var onUploader: () -> Void = {}

    /// The displayed state only (the closures always target the page that built them).
    static func == (a: PlayerFullscreenActions, b: PlayerFullscreenActions) -> Bool {
        a.liked == b.liked && a.coined == b.coined && a.favored == b.favored && a.likeCount == b.likeCount
            && a.commentCount == b.commentCount && a.coinCount == b.coinCount && a.favoriteCount == b.favoriteCount
            && a.shareCount == b.shareCount && a.viewCount == b.viewCount && a.shareURL == b.shareURL
            && a.shareTitle == b.shareTitle && a.ownerName == b.ownerName && a.ownerFace == b.ownerFace
            && a.ownerFans == b.ownerFans && a.following == b.following && a.canFollow == b.canFollow
    }
}

/// 「上次看到第N P，点击跳转」: the account's history is on another part of this video.
struct PlayerResumePartPrompt: Equatable {
    let entryID: String
    let page: Int
    let time: Double
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
    /// `retake`: acceleration tried again after a fallback to direct (installed only if it prepares).
    case initial, switchStreams, fallback, endpoint, retry, retake
}

enum PlayerFallbackStep: Hashable {
    /// `noProxy`: the CDN's progressive MP4 played by AVPlayer itself (the local proxy could not serve).
    case avc, direct, noProxy, lowerQuality
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
    /// Which stage holds the video surface. It follows `isFullscreen` with the fullscreen controller on screen: the
    /// video goes over as that controller is about to show, and comes back once the screen has turned back
    /// (`PlayerFullscreenPresenter`). The danmaku take the size of the stage they are in.
    @Published private(set) var surfaceInFullscreen = false {
        didSet {
            surface.danmaku.isFullscreen = surfaceInFullscreen
            if !surfaceInFullscreen {
                surface.danmakuTopInset = 0
                fullscreenStageIsVertical = false
            }
        }
    }
    /// Called when playback reaches the end (after SmartSkip etc.). The detail page decides auto-next.
    var onEnded: (() -> Void)?
    /// Asked at the end: the page would only replay this item (列表循环 with nothing else to play), so it loops
    /// here like 单个循环 (no `onEnded`, the screen lock stays).
    var loopsAtEnd: (() -> Bool)?

    /// Optional: when set, the fullscreen bar shows 「下一集」 and the lock screen offers "next track".
    var onNext: (() -> Void)? {
        didSet { hasNext = onNext != nil }
    }
    @Published private(set) var hasNext = false

    /// Set by a page that can move on from a vertical video (not offline files): the cover of the video a swipe would
    /// go to, nil when there is none (yet).
    var videoSwipeCover: ((PlayerVideoSwipe) -> String?)?
    /// The page switches to that video in place. It ends with `load`, or with `videoSwipeFailed` when it cannot.
    var onVideoSwipe: ((PlayerVideoSwipe) -> Void)?
    /// A swipe is under way: the picture is moving, or the video it goes to is on its way. What is drawn with the
    /// picture (cover, subtitles, loading) steps aside until then.
    @Published private(set) var isVideoSwipeActive = false
    /// The swipe has been decided; the page is switching and no new one starts.
    private(set) var isSwitchingBySwipe = false
    private var playAfterFailedSwipe = false
    private var controlsBeforeSwipe = false
    /// The item playing came from a swipe: a position it was given is the one it was left at, nothing to point out.
    private var itemCameFromSwipe = false

    /// Optional: when set, the fullscreen bar shows 「上一集」 and the lock screen offers "previous track".
    var onPrevious: (() -> Void)? {
        didSet { hasPrevious = onPrevious != nil }
    }
    @Published private(set) var hasPrevious = false

    /// In-player 「选集」 (shown with more than one entry). Set by the page whenever the list or the current item
    /// changes (assign only on change: the page observes this controller).
    @Published var episodeEntries: [PlayerEpisodeEntry] = []
    /// The page switches to that entry; `startTime` nil = its usual resume rules.
    var onSelectEpisode: ((_ id: String, _ startTime: Double?) -> Void)?

    /// Fullscreen 点赞 / 投币 / 收藏 / 分享 row (nil = hidden).
    @Published var fullscreenActions: PlayerFullscreenActions?
    /// Content of `PlayerSheet.page` (see `presentPageSheet`).
    private(set) var pageSheet: (id: String, content: AnyView)?
    /// The page's observer that keeps `fullscreenActions` current (lives as long as the player).
    var pageObservation: AnyCancellable?
    /// The page's navigation stack: search from the vertical-video screen (nil = no such button).
    weak var pageRouter: TabRouter? {
        didSet {
            guard pageRouter !== oldValue else { return }
            pagePathObservation = pageRouter?.$path.sink { [weak self] path in self?.pagePathChanged(count: path.count) }
        }
    }
    private var pagePathObservation: AnyCancellable?
    private var fullscreenStageIsVertical = false
    /// How deep the page's stack stood when fullscreen began.
    private var fullscreenPathCount = 0
    /// Fullscreen gave way to a page opened from it (search, the uploader …), and comes back with the player's page.
    var refullscreenWhenPageReturns = false

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
    /// 「听视频」 chosen (kept for the next items of this page).
    @Published private(set) var audioOnly = false
    /// The audio representation the current item plays alone (nil = a normal item with picture).
    @Published private(set) var audioOnlyStream: DashStream?
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
    @Published var resumePartPrompt: PlayerResumePartPrompt?
    /// player/wbi/v2 says the subtitles need a login (and none came): 「字幕（登录后可用）」.
    @Published var subtitlesNeedLogin = false
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
    var resumePartTask: Task<Void, Never>?
    /// Archives whose 「上次看到第N P」 chip was offered (once per page and video).
    var resumePartOfferedAids: Set<Int64> = []
    /// player/wbi/v2 answered (or failed) for this video: SmartSkip may start from the tick when turned on later.
    var sideDataLoaded = false
    /// PGC clips skipped automatically (「跳过一次」).
    var autoSkippedClips: Set<String> = []
    /// The first clip check after the start ran (a start inside a clip skips it at once).
    var clipStartChecked = false
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
    /// Skip the local proxy entirely (see `installDirectProgressive`).
    private var forceNoProxy = false
    private var fallbackSteps: Set<PlayerFallbackStep> = []
    /// The user's play intent (survives rebuilds; AVPlayer's own state is paused during them).
    @Published private(set) var wantsToPlay = false
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
    /// A `rebuild` is preparing its new item (reset when it installs or gives up).
    private var rebuildPending = false
    private var pendingSwitchToast: String?
    /// An acceleration switch was flipped when it could not be acted on (`accelerationSwitchesChanged`).
    private var accelerationSwitchPending = false
    /// Whether the switches wanted acceleration for this item when its stream was last chosen. It can differ from
    /// `isAccelerated`, which says what it got: a video that fell back to direct wants it still.
    private var accelerationWanted: Bool?
    private var switchRevert: (quality: Int?, audio: Int?, codec: VideoCodecPreference?, forceAVC: Bool)?
    private var tickCount = 0
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var layerObservation: NSKeyValueObservation?
    private let fullscreenPresenter = PlayerFullscreenPresenter()
    private var fullscreenByRotation = false
    private var autoExitTask: Task<Void, Never>?
    /// The inline container disappeared (a page was pushed over this one) and has not reappeared yet.
    private var containerHidden = false
    /// Play intent held back while the container is hidden; `play()` runs when it reappears.
    private var resumeOnContainerAppear = false
    /// 启用海外加速 / 剧集加速 switched while a video plays (applied by rebuilding it).
    private var accelerationObservation: AnyCancellable?
    /// Automatic re-take of acceleration after a fallback to direct (`scheduleRetake`).
    private var retakeTask: Task<Void, Never>?
    private var retakeAttempts = 0
    private var retakeWindowStart: Double?
    private static let retakeDelays: [Double] = [4, 8, 16]
    private static let retakeWindow: Double = 120

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
        // `@Published` emits before the value is stored: hop once so the handler reads the new settings.
        accelerationObservation = AppSettings.shared.$acceleration
            .map { [$0.enabled, $0.accelerateBangumi, $0.verticalVideosDirect] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.accelerationSwitchesChanged() }
            }
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
        if let audio = audioOnlyStream { return "听视频 · " + DashStream.audioTitle(audio.id) }
        guard let choice else { return isProgressive ? "MP4" : "" }
        var parts = [VideoQuality.title(for: choice.video.id), PlayerStreamPicker.codecTitle(choice.video.codecFamily)]
        if choice.video.width > 0 { parts.append("\(choice.video.width)×\(choice.video.height)") }
        if let audio = choice.audio { parts.append(DashStream.audioTitle(audio.id)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Contract API

    func load(_ newItem: PlaybackItem) {
        if SmokeTest.isEnabled { SmokeTest.activePlayer = self }
        if let current = item, current == newItem {
            switch status {
            case .idle, .failed: break
            default:
                videoSwipeFailed()
                return
            }
        }
        let swiped = isSwitchingBySwipe
        itemCameFromSwipe = swiped
        // Auto-next (or another part tapped while playing) keeps playing even with 「自动播放」 off, and so does a
        // swipe from a paused video (the swipe itself paused it).
        let continuing = item != nil && (wantsToPlay || status == .ended || swiped)
        autoExitTask?.cancel()
        teardown(reportHeartbeat: true)
        item = newItem
        isVerticalVideo = newItem.isVertical
        aspectMode = .stored(forVertical: newItem.isVertical)
        duration = max(0, newItem.duration)
        currentTime = 0
        lastKnownPosition = 0
        timeline.reset(duration: duration)
        status = .loading
        wantsToPlay = AppSettings.shared.player.autoPlay || continuing
        // Without 后台播放, in the background (the app left during a swipe): it starts once the app is back.
        if pausedByBackground { wantsToPlay = false }
        if wantsToPlay, containerHidden, !isPiPBusy {
            // Loaded while another page covers this one (e.g. the detail request finished late): start when visible.
            wantsToPlay = false
            resumeOnContainerAppear = true
        }
        hasFirstFrame = false
        surface.danmaku.load(cid: newItem.cid, aid: newItem.aid, duration: newItem.duration)
        // Re-attaching the layer in the background (auto-next during background play) would get the new item
        // paused by the system (QA1668); `appWillEnterForeground` re-attaches it.
        if UIApplication.shared.applicationState != .background { surface.reattachPlayerIfNeeded() }
        overlay.prepareForNewItem()
        if swiped {
            // Swiping through videos: the controls would cover each one for its first seconds.
            overlay.hideControls()
            endVideoSwipe()
            surface.finishVideoSwipe()
        }
        startTicking()
        let gen = loadGeneration
        loadTask = Task { [weak self] in await self?.performInitialLoad(newItem, generation: gen) }
        sideTask = Task { [weak self] in await self?.loadSideData(newItem, generation: gen) }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
    }

    func play() {
        guard item != nil else { return }
        if isSwitchingBySwipe {
            // The old video stays silent behind the cover: this only decides what happens if the switch fails.
            playAfterFailedSwipe = true
            return
        }
        if case .failed = status {
            retry()
            return
        }
        let replay = status == .ended
        wantsToPlay = true
        pausedByBackground = false
        pausedByInterruption = false
        resumeOnContainerAppear = false
        if replay {
            performSeek(to: 0, origin: .user)
            // With a lost endpoint the seek became a rebuild, which starts playback itself.
            if !isEndpointLost { startPlayback() }
            applyPendingAccelerationSwitch()
            return
        }
        if isEndpointLost {
            // The proxy session died while this page was idle: rebuild instead of playing a dead item.
            if status == .paused { status = hasFirstFrame ? .buffering : .loading }
            rebuildForLostEndpoint(position: lastKnownPosition)
            return
        }
        guard startupDone else {
            if status == .paused { status = hasFirstFrame ? .buffering : .loading }
            return
        }
        startPlayback()
    }

    func pause() {
        if isSwitchingBySwipe { playAfterFailedSwipe = false }
        wantsToPlay = false
        pausedByBackground = false
        pausedByInterruption = false
        resumeOnContainerAppear = false
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
        if isSwitchingBySwipe {
            playAfterFailedSwipe.toggle()
            return
        }
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
        overlay.fullscreenChanged()
        fullscreenPresenter.dismiss { [weak self] in
            // Back inline before the fade, also when fullscreen was entered again meanwhile: the page then shows
            // the current picture until the new fullscreen controller takes it (`willPresent`).
            self?.surfaceInFullscreen = false
        }
    }

    // MARK: Vertical-video screen

    /// The official app's screen for a vertical video (`VerticalVideoViews.swift`) is up: such a video fullscreen,
    /// standing up. `PlayerStageView` decides, and only it can: it knows the window's shape.
    var isOnVerticalScreen: Bool { isFullscreen && fullscreenStageIsVertical }

    /// The fullscreen stage came on that screen, or left it.
    func fullscreenStageChanged(verticalScreen: Bool) {
        guard isFullscreen else { return }
        fullscreenStageIsVertical = verticalScreen
        // That screen has no lock button: the lock of an earlier video in another shape must not stay on.
        if verticalScreen { overlay.unlock() }
        fullscreenPresenter.setShowsStatusBar(verticalScreen)
        surface.danmakuTopInset = verticalScreen ? VerticalVideoMetrics.topBarHeight : 0
        surface.setNeedsLayout()
    }

    /// A page was opened from fullscreen, and SwiftUI holds the push back for as long as fullscreen covers the stack.
    private func pagePathChanged(count: Int) {
        guard isOnVerticalScreen, count > fullscreenPathCount else { return }
        refullscreenWhenPageReturns = true
        exitFullscreen()
    }

    /// A double tap on that screen: 点赞, as on the 短视频 feed, never 取消点赞.
    func verticalScreenDoubleTap(at location: CGPoint) {
        guard let actions = fullscreenActions else {
            togglePlay()
            return
        }
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        overlay.showLikeBurst(at: location)
        if !actions.liked { actions.onLike() }
    }

    // MARK: Swiping between vertical videos

    /// Up and down swipes on this vertical video go to the next and previous one, in place (「竖屏视频进入短视频」).
    /// Not for bangumi episodes, and not while the video plays in Picture in Picture.
    var canSwipeVideos: Bool {
        videoSwipeCover != nil && isVerticalVideo && item?.epId == 0 && !isPiPActive
            && AppSettings.shared.general.portraitOpensShortVideo
    }

    /// The finger moved: `offset` from where it started (negative is up, towards the next video).
    func videoSwipeMoved(offset: CGFloat) {
        if !isVideoSwipeActive {
            isVideoSwipeActive = true
            controlsBeforeSwipe = overlay.controlsVisible
            overlay.hideControls()
            surface.beginVideoSwipe(leavingCover: hasFirstFrame ? nil : item?.cover)
        }
        surface.moveVideoSwipe(offset: offset, targetCover: videoSwipeCover?(offset < 0 ? .next : .previous))
    }

    /// The finger lifted (offset and velocity 0: the gesture was cancelled). Far or fast enough goes to that video,
    /// anything else springs back, and so does a flick back the other way, however far it had gone.
    func videoSwipeEnded(offset: CGFloat, velocity: CGFloat) {
        guard isVideoSwipeActive else { return }
        let swipe: PlayerVideoSwipe = offset < 0 ? .next : .previous
        let fast = abs(velocity) > 600
        let flickedBack = fast && (velocity < 0) != (offset < 0)
        let far = !flickedBack && (fast || abs(offset) > max(surface.bounds.height, 1) * 0.2)
        guard far, let cover = videoSwipeCover?(swipe) else {
            if far { ToastCenter.shared.show(swipe == .next ? "下一个视频还在加载，稍后再滑" : "已经是第一个了") }
            surface.cancelVideoSwipe()
            endVideoSwipe()
            if controlsBeforeSwipe { overlay.showControls() }
            return
        }
        let wasPlaying = wantsToPlay
        pause()
        isSwitchingBySwipe = true
        playAfterFailedSwipe = wasPlaying
        surface.commitVideoSwipe(toNext: swipe == .next, targetCover: cover) { [weak self] in
            guard let self, self.isSwitchingBySwipe else { return }
            self.onVideoSwipe?(swipe)
        }
    }

    /// The page goes on by itself to the video a swipe would go to (this one ended): it comes up the same way.
    func beginAutomaticVideoSwipe() {
        isSwitchingBySwipe = true
        playAfterFailedSwipe = false
        controlsBeforeSwipe = overlay.controlsVisible
    }

    /// The page could not switch: back to the video that was showing, as it was.
    func videoSwipeFailed() {
        guard isSwitchingBySwipe else { return }
        let resume = playAfterFailedSwipe
        endVideoSwipe()
        surface.cancelVideoSwipe()
        if controlsBeforeSwipe { overlay.showControls() }
        if !resume {
            // It counted as playing when the app left (`appDidEnterBackground`), for the video that did not come.
            pausedByBackground = false
            backgroundTask?.cancel()
        } else if isCoveredByPage {
            // Goes on with its page, not when the app is back.
            pausedByBackground = false
            resumeOnContainerAppear = true
        } else if pausedByBackground {
            // Goes on when the app is back (`appWillEnterForeground`).
        } else {
            play()
        }
    }

    private func endVideoSwipe() {
        isSwitchingBySwipe = false
        isVideoSwipeActive = false
    }

    /// Stop & release. While Picture in Picture runs the player keeps going (kept alive) and stops when PiP ends.
    func stop() {
        if isPiPBusy {
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
        endVideoSwipe()
        surface.finishVideoSwipe()
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
            if current.localFileURL != nil, !isFailed {
                // A downloaded file has no playurl to refetch, and `load` of the playing item would do nothing:
                // open the file again where it is now.
                let position = lastKnownPosition
                status = .idle
                load(current)
                pendingStartTime = position
            } else {
                load(current)
            }
            wantsToPlay = true
            return
        }
        wantsToPlay = true
        fallbackSteps = []
        forceAVC = false
        forceNormalAudio = false
        forceDirect = false
        forceNoProxy = false
        resetRetake()
        status = .loading
        rebuild(position: lastKnownPosition, reason: .retry)
    }

    // MARK: Page integration

    /// A 「选集」 row (or the 分P resume chip): the page loads that entry.
    func selectEpisode(_ id: String, startTime: Double? = nil) {
        guard let entry = episodeEntries.first(where: { $0.id == id }), !entry.isCurrent || startTime != nil else { return }
        onSelectEpisode?(id, startTime)
    }

    /// Presents a sheet the page builds (投币 / 收藏 from the fullscreen action row) over the active stage.
    func presentPageSheet(id: String, content: AnyView) {
        pageSheet = (id, content)
        overlay.panel = nil
        overlay.sheet = .page(id)
    }

    // MARK: 听视频

    /// Only DASH answers have a separate audio track, served by the proxy (not for local files). It must be
    /// the normal AAC one `audioOnlyTrack` plays: a video with only Dolby / FLAC audio would fail to start.
    var supportsAudioOnly: Bool {
        guard item?.localFileURL == nil, !forceNoProxy, let info = playInfo else { return false }
        return info.isDash && audioOnlyTrack(info) != nil
    }

    /// 「听视频」: rebuilds the item at the current position with only the audio track (saves the video bandwidth),
    /// or with the picture again.
    func setAudioOnly(_ on: Bool) {
        guard on != audioOnly, playInfo != nil, item?.localFileURL == nil else { return }
        if on, !supportsAudioOnly {
            ToastCenter.shared.show("该视频暂不支持听视频")
            return
        }
        audioOnly = on
        beginSwitch(message: on ? "正在切换至听视频…" : "正在恢复视频画面…", toast: on ? "已开启听视频" : "已关闭听视频")
        rebuild(position: nil, reason: .switchStreams)
    }

    /// The normal AAC track (Dolby / FLAC stay with the picture): the menu choice when it is one.
    private func audioOnlyTrack(_ info: PlayInfo) -> DashStream? {
        var c = constraints()
        c.forceNormalAudio = true
        return PlayerStreamPicker.pickAudio(info, c)
    }

    // MARK: Acceleration switches & re-take

    /// 启用海外加速 / 剧集加速 / 竖屏视频禁用加速 changed: the playing item is rebuilt on the matching path (btr-core §3).
    /// Later if it is not on screen (it would open a session and show its toasts over the page on top), its path was
    /// chosen before the flip, or it has ended: see `applyPendingAccelerationSwitch`.
    private func accelerationSwitchesChanged() {
        guard let target = item, target.localFileURL == nil, playInfo != nil else { return }
        guard !isCoveredByPage, startupDone, !rebuildPending, status != .ended else {
            accelerationSwitchPending = true
            return
        }
        switch status {
        case .failed, .idle: return
        default: break
        }
        let want = AppSettings.shared.acceleration.accelerates(pgc: target.epId != 0, vertical: target.isVertical)
        // A flip that does not concern this video: one that fell back to direct stays there.
        guard want != accelerationWanted else { return }
        accelerationWanted = want
        guard want != isAccelerated else { return }
        if want {
            // A manual switch gives acceleration a fresh chance (also after an earlier fallback).
            forceDirect = false
            forceNoProxy = false
            fallbackSteps.subtract([.direct, .noProxy])
            resetRetake()
        }
        beginSwitch(message: want ? "正在开启加速…" : "正在关闭加速…", toast: want ? "已开启加速" : "已关闭加速")
        rebuild(position: nil, reason: .switchStreams)
    }

    /// A flip that had to wait: its moment has come. Cleared first, so a switch that fails cannot go round again.
    private func applyPendingAccelerationSwitch() {
        guard accelerationSwitchPending else { return }
        accelerationSwitchPending = false
        accelerationSwitchesChanged()
    }

    /// Fell back to direct because of acceleration (prepare failure, item failure or the buffering watchdog).
    private func noteDirectFallback() {
        forceDirect = true
        fallbackSteps.insert(.direct)
        scheduleRetake()
    }

    private func resetRetake() {
        retakeTask?.cancel()
        retakeTask = nil
        retakeAttempts = 0
        retakeWindowStart = nil
    }

    private enum RetakeDecision { case wait, go, stop }

    /// BTR §11.6 step 4: after a fallback to direct, acceleration is re-taken automatically, at most 3 times per
    /// item: 4 s / 8 s / 16 s after the fallback and within 120 s of the first one. An attempt waits until the
    /// video plays with buffer to spare, and its item replaces the direct one only once the accelerated session
    /// prepared (`PlayerInstallReason.retake`), so a failed attempt is not noticeable.
    private func scheduleRetake() {
        guard retakeTask == nil, retakeAttempts < Self.retakeDelays.count, item?.localFileURL == nil else { return }
        let windowStart = retakeWindowStart ?? ProcessInfo.processInfo.systemUptime
        retakeWindowStart = windowStart
        let delay = Self.retakeDelays[retakeAttempts]
        let lgen = loadGeneration
        retakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                guard let decision = self?.retakeDecision(windowStart: windowStart, generation: lgen) else { return }
                switch decision {
                case .wait:
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                case .go:
                    self?.performRetake()
                    return
                case .stop:
                    self?.retakeTask = nil
                    return
                }
            }
        }
    }

    private func retakeDecision(windowStart: Double, generation lgen: Int) -> RetakeDecision {
        guard lgen == loadGeneration, forceDirect, !forceNoProxy, let target = item else { return .stop }
        guard AppSettings.shared.acceleration.accelerates(pgc: target.epId != 0, vertical: target.isVertical),
              ProcessInfo.processInfo.systemUptime - windowStart <= Self.retakeWindow else { return .stop }
        // Never during a stall, a seek or another rebuild: a healthy direct playback is not interrupted. The
        // fallback's own direct rebuild may still be preparing (the failed accelerated item is installed until then).
        guard status == .playing, startupDone, !isSeeking, !rebuildPending, let observed = playerItem else { return .wait }
        guard !isAccelerated else { return .stop }
        let t = displayTime()
        let ahead = Self.bufferInfo(at: t, in: observed).ahead
        let left = duration > 0 ? max(0, duration - t) : .infinity
        // Not in the last seconds (wall clock): nothing left to gain, and the item could end while the session
        // prepares (up to the engine's 10 s metadata timeout).
        guard left / max(1, effectiveRate) >= 15 else { return .wait }
        return ahead >= 10 ? .go : .wait
    }

    private func performRetake() {
        retakeTask = nil
        retakeAttempts += 1
        rebuild(position: nil, reason: .retake)
    }

    // MARK: Speed

    func setRate(_ newRate: Double) {
        guard newRate.isFinite, newRate > 0 else { return }
        rate = min(max(newRate, 0.25), 4)
        applyRate()
        if Double(playerRate) < rate - 0.001 { ToastCenter.shared.show("当前视频最高支持 2 倍速播放") }
    }

    /// The rate handed to AVPlayer. HLS plays above 2× only with I-frame playlists (`canPlayFastForward`), which
    /// the proxy's playlists do not have; progressive MP4 may go up to 4×.
    var playerRate: Float {
        var r = effectiveRate
        if r > 2, session?.isHLS ?? false, !(playerItem?.canPlayFastForward ?? false) { r = 2 }
        return Float(r)
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
        let r = playerRate
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
        ToastCenter.shared.show(message)
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
        if let audio = audioOnlyStream {
            // 听视频: no picture to choose (turning it off brings the menus back).
            qualityEntries = []
            audioEntries = []
            codecFamilies = []
            currentQuality = 0
            currentAudioId = audio.id
            currentCodecFamily = ""
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
        if let file = target.localFileURL {
            // Like the playurl path: a load replaced before this task ran must not install its file.
            guard gen == loadGeneration, !Task.isCancelled else { return }
            installLocalFile(file, target: target)
            return
        }
        let quality = AppSettings.shared.player.preferredQuality
        let info: PlayInfo
        do {
            info = try await PlayerStreamPicker.fetchPlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid,
                                                              epId: target.epId, seasonId: target.seasonId,
                                                              quality: quality)
        } catch {
            // Still the current load: even a cancellation we did not ask for must not leave the status at .loading.
            guard gen == loadGeneration, !Task.isCancelled else { return }
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
        // A seek issued while playurl was loading (e.g. a chapter tap) wins over the resume position.
        let userStart = pendingStartTime
        let start = userStart ?? resolveStartPosition(target, info)
        lastKnownPosition = start
        if start > 0 {
            timeline.update(time: start, duration: duration, buffered: 0)
            currentTime = start
            if userStart == nil, !(itemCameFromSwipe && target.startTime != nil) { showResumeChip(at: start) }
        }
        if userStart == nil, target.startTime == nil, AppSettings.shared.player.resumeProgress,
           info.lastPlayCid > 0, info.lastPlayCid != target.cid {
            offerResumePart(aid: target.aid, cid: info.lastPlayCid, time: info.lastPlayTime)
        }
        await installStreams(position: start, generation: streamGeneration, reason: .initial)
    }

    /// Contract 1 (离线缓存): the downloaded file straight into AVPlayer, from `startTime` when it is usable.
    private func installLocalFile(_ file: URL, target: PlaybackItem) {
        let total = target.duration
        var start = pendingStartTime ?? 0
        if pendingStartTime == nil, let t = target.startTime, t.isFinite, t > 0, total <= 0 || t < total - 5 {
            start = t
            showResumeChip(at: t)
        }
        lastKnownPosition = start
        if start > 0 {
            timeline.update(time: start, duration: duration, buffered: 0)
            currentTime = start
        }
        installItem(url: file, session: nil, assetOptions: nil, choice: nil, accelerated: false, progressive: true,
                    position: start, generation: streamGeneration)
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
        let retake = reason == .retake
        let accelerationOn = settings.acceleration.accelerates(pgc: pgc, vertical: target.isVertical)
        accelerationWanted = accelerationOn
        let wantAccel = accelerationOn && (!forceDirect || retake)
        let allowHDR = settings.player.allowHDR && PlayerDeviceSupport.hdrEligible
        let total = info.duration > 0 ? info.duration : target.duration
        // A re-take installs only an accelerated session (the direct item keeps playing otherwise).
        let attempts: [Bool] = retake ? (accelerationOn ? [true] : []) : (wantAccel ? [true, false] : [false])
        let routeKey = PlayerStreamPicker.routeKey(aid: target.aid, bvid: target.bvid, cid: target.cid, epId: target.epId)
        var lastError: Error?
        // 听视频 needs a DASH audio track and the proxy.
        if audioOnly, !info.isDash || forceNoProxy { audioOnly = false }

        /// A session prepared and is about to be installed.
        func prepared(accelerated: Bool) {
            if retake {
                forceDirect = false
                fallbackSteps.remove(.direct)
                ToastCenter.shared.show("加速线路已恢复")
            } else if wantAccel && !accelerated {
                noteDirectFallback()
            }
        }

        if audioOnly {
            if let audio = audioOnlyTrack(info) {
                for accelerate in attempts {
                    do {
                        // 听视频: the audio representation is the session's only track (an audio-only variant).
                        let request = PlaybackRequest(
                            routeKey: routeKey, video: audio, audio: nil, duration: total, accelerate: accelerate,
                            allowHDR: false,
                            refreshURLs: PlayerStreamPicker.makeAudioOnlyRefresher(aid: target.aid, bvid: target.bvid,
                                                                                  cid: target.cid, epId: target.epId,
                                                                                  seasonId: target.seasonId,
                                                                                  audio: audio))
                        let made = try await AccelerationEngine.shared.prepare(request)
                        guard current() else {
                            made.close()
                            return
                        }
                        prepared(accelerated: accelerate)
                        install(made, choice: nil, audioOnly: audio, accelerated: accelerate, progressive: false,
                                position: position, generation: sgen)
                        return
                    } catch {
                        guard current() else { return }
                        lastError = error
                    }
                }
            }
            if !retake {
                if reason == .switchStreams, startupDone {
                    // The previous item keeps playing: the one with picture, or the 听视频 item itself (an
                    // acceleration switch while listening).
                    audioOnly = audioOnlyStream != nil
                    ToastCenter.shared.show(audioOnly ? "切换失败：\(Self.describe(lastError ?? PlayerLoadError.noStream))"
                                                      : "听视频启动失败，已恢复视频画面")
                    switchRevert = nil
                    transientMessage = nil
                    pendingSwitchToast = nil
                    keepCurrentItem()
                    return
                }
                audioOnly = false
                ToastCenter.shared.show("听视频启动失败，已恢复视频画面")
            }
        }

        if !audioOnly, info.isDash, !forceNoProxy {
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
                        prepared(accelerated: accelerate)
                        install(made, choice: picked, accelerated: accelerate, progressive: false,
                                position: position, generation: sgen)
                        return
                    } catch {
                        // Still current: a stray CancellationError is just another failed attempt (never a stuck .loading).
                        guard current() else { return }
                        lastError = error
                    }
                }
            } else {
                lastError = PlayerLoadError.unsupportedCodec
            }
        }

        var durl = info.durl
        var wholeFile = false
        let progressiveQn = manualQuality ?? settings.player.preferredQuality
        if !audioOnly, !forceNoProxy, durl.count > 1, !pgc {
            // A segmented (FLV-era) answer: the html5 platform normally returns the whole file as one MP4.
            let whole = try? await VideoAPI.progressivePlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid,
                                                                qn: progressiveQn)
            guard current() else { return }
            if let whole, whole.durl.count == 1 {
                durl = whole.durl
                wholeFile = true
            }
        }
        if !audioOnly, !forceNoProxy, let segment = durl.first {
            if durl.count > 1, reason == .initial {
                ToastCenter.shared.show("该视频为分段视频，目前只能播放第一段")
            }
            // Renews the signed URLs of the same file in place (a long pause must not end in 403s).
            let fromHTML5 = wholeFile
            let refresher = AccelerationEngine.progressiveRefresher(for: segment) {
                if fromHTML5 {
                    return try await VideoAPI.progressivePlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid,
                                                                  qn: progressiveQn).durl
                }
                return try await PlayerStreamPicker.fetchPlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid,
                                                                  epId: target.epId, seasonId: target.seasonId,
                                                                  quality: progressiveQn).durl
            }
            for accelerate in attempts {
                do {
                    let made = try await AccelerationEngine.shared.prepareProgressive(routeKey: routeKey, segment: segment,
                                                                                      accelerate: accelerate,
                                                                                      refreshURLs: refresher)
                    guard current() else {
                        made.close()
                        return
                    }
                    prepared(accelerated: accelerate)
                    install(made, choice: nil, accelerated: accelerate, progressive: true, position: position,
                            generation: sgen)
                    return
                } catch {
                    guard current() else { return }
                    lastError = error
                }
            }
        }

        if retake {
            // The accelerated session did not prepare: the direct item keeps playing (a later attempt may follow).
            guard current() else { return }
            scheduleRetake()
            keepCurrentItem()
            return
        }

        // No usable proxy session (or the proxy already failed this item): the CDN's MP4 without the proxy.
        if target.epId == 0, forceNoProxy || reason != .switchStreams {
            do {
                if try await installDirectProgressive(target: target, position: position, generation: sgen,
                                                      current: current) { return }
            } catch {
                guard current() else { return }
                lastError = lastError ?? error
            }
        }

        guard current() else { return }
        rebuildPending = false
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
            // 听视频 follows the item that keeps playing.
            audioOnly = audioOnlyStream != nil
            // An acceleration switch cleared this, for an item that stays without the proxy.
            if session == nil {
                forceNoProxy = true
                fallbackSteps.formUnion([.direct, .noProxy])
            }
            refreshStreamMenus()
            ToastCenter.shared.show("切换失败：\(Self.describe(lastError ?? PlayerLoadError.noStream))")
            keepCurrentItem()
            return
        }
        fail(Self.describe(lastError ?? PlayerLoadError.noStream))
    }

    /// Last resort without the local proxy: the html5 progressive MP4 straight from the CDN, with the Referer /
    /// User-Agent the CDN checks. Not accelerated and at most 1080P, but it plays when the proxy cannot serve.
    /// Returns true when the attempt is over for this caller (installed, or superseded meanwhile).
    private func installDirectProgressive(target: PlaybackItem, position: Double?, generation sgen: Int,
                                          current: () -> Bool) async throws -> Bool {
        let qn = manualQuality ?? AppSettings.shared.player.preferredQuality
        let info = try await VideoAPI.progressivePlayInfo(aid: target.aid, bvid: target.bvid, cid: target.cid, qn: qn)
        guard current() else { return true }
        guard let segment = info.durl.first, let url = URL(string: segment.url.biliHTTPS) else {
            throw PlayerLoadError.noStream
        }
        // Announced when it replaces a proxy item (or there was none yet), not on every direct rebuild.
        if session != nil || playerItem == nil { ToastCenter.shared.show("加速通道不可用，已改为直连播放") }
        forceNoProxy = true
        fallbackSteps.formUnion([.direct, .noProxy])
        let headers = ["Referer": "https://www.bilibili.com/", "User-Agent": BiliHTTP.webUserAgent]
        installItem(url: url, session: nil, assetOptions: ["AVURLAssetHTTPHeaderFieldsKey": headers], choice: nil,
                    accelerated: false, progressive: true, position: position, generation: sgen)
        return true
    }

    private func install(_ newSession: PlaybackSession, choice picked: PlayerStreamChoice?,
                         audioOnly audio: DashStream? = nil, accelerated: Bool,
                         progressive: Bool, position: Double?, generation sgen: Int) {
        installItem(url: newSession.url, session: newSession, assetOptions: nil, choice: picked, audioOnly: audio,
                    accelerated: accelerated, progressive: progressive, position: position, generation: sgen)
    }

    /// `session` nil: a URL AVPlayer loads itself (no proxy). `audio`: the 听视频 track the item plays alone.
    private func installItem(url: URL, session newSession: PlaybackSession?, assetOptions: [String: Any]?,
                             choice picked: PlayerStreamChoice?, audioOnly audio: DashStream? = nil,
                             accelerated: Bool, progressive: Bool,
                             position: Double?, generation sgen: Int) {
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
        rebuildPending = false

        let old = session
        session = newSession
        choice = picked
        if audioOnlyStream != audio { audioOnlyStream = audio }
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

        let asset = AVURLAsset(url: url, options: assetOptions)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = forwardBufferSeconds
        newItem.preferredPeakBitRate = 0
        newItem.audioTimePitchAlgorithm = .timeDomain
        if start > 0.5 { newSession?.playerWillSeek(to: start, outsideBuffer: true) }
        playerItem = newItem
        // `play()` from the PiP window / headphones uses `defaultRate`: keep it within what this item can do.
        player.defaultRate = playerRate
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
        rebuildPending = true
        let sgen = streamGeneration
        loadTask = Task { [weak self] in
            await self?.installStreams(position: position, generation: sgen, reason: reason)
        }
    }

    /// A rebuild gave up and the item that was playing stays (failed menu switch, 听视频 start, re-take). `rebuild`
    /// moved `streamGeneration` on, so the item's observers would ignore its end (auto-next, 单个循环), failures
    /// (the fallback ladder) and stalls from now on: bind them to the current generation, and catch up on what the
    /// item reported while the rebuild prepared.
    private func keepCurrentItem() {
        rebuildPending = false
        guard let observed = playerItem, player.currentItem === observed else { return }
        removeItemObservers()
        observeItem(observed, generation: streamGeneration)
        guard !isFailed else { return }
        switch observed.status {
        case .failed:
            handleFailure(message: observed.error.map { ($0 as NSError).localizedDescription })
        case .readyToPlay where !itemReady:
            itemStatusChanged(generation: streamGeneration)
        default:
            // Played to its end meanwhile (the end notification was dropped): `timeControlChanged` kept the intent.
            if startupDone, wantsToPlay, !isSeeking, status != .ended, isNearEnd, player.timeControlStatus == .paused {
                itemDidPlayToEnd(generation: streamGeneration)
            }
        }
        applyPendingAccelerationSwitch()
    }

    /// The item's proxy session can no longer serve it: the listener moved to another port, or the engine closed
    /// the session to stay under its session cap (another page opened a newer one).
    private var isEndpointLost: Bool {
        guard let session else { return false }
        return !session.isEndpointValid
    }

    /// Rebuilds at `position` (nil = now) after `isEndpointLost`, without touching the fallback ladder.
    /// Callers rebuild an engine-closed session only when this page wants to play: an idle page rebuilding at once
    /// would evict the next-oldest page's session, which would rebuild and evict the next one, forever.
    private func rebuildForLostEndpoint(position: Double?) {
        // A rebuild already preparing brings a new session anyway.
        guard !rebuildPending else { return }
        rebuild(position: position, reason: .endpoint)
    }

    /// Rebuild a lost endpoint right away (else on the next play / seek): when this page wants to play, or after a
    /// port change on the visible page. Never for an engine-closed session of an idle page (see above).
    private func shouldRebuildLostEndpointNow(_ lost: PlaybackSession) -> Bool {
        wantsToPlay || (!lost.isClosed && !containerHidden)
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
        forceNoProxy = false
        fallbackSteps = []
        itemReady = false
        startupDone = false
        isSeeking = false
        seekToken += 1
        pendingStartTime = nil
        waitingSince = nil
        stallReported = false
        rebuildPending = false
        resumeOnContainerAppear = false
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
        audioOnlyStream = nil
        accelerationSwitchPending = false
        accelerationWanted = nil
        resetRetake()
        resetFeatureState()
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
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
        if error is CancellationError || (error as? BiliError) == .cancelled { return "加载被中断，请重试" }
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
        // A local file (离线缓存) reports no watch history.
        if !heartbeatStarted, target.localFileURL == nil {
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
        applyPendingAccelerationSwitch()
        smartSkipTick(time: lastKnownPosition, playing: isActuallyPlaying)
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
        let r = playerRate
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
                if !wantsToPlay {
                    // Started from the PiP window / headphones: this player now owns playback.
                    wantsToPlay = true
                    PlayerNowPlayingCenter.shared.claim(self)
                }
            case .waitingToPlayAtSpecifiedRate:
                if waitingSince == nil { waitingSince = now }
                if !wantsToPlay, player.rate > 0 {
                    wantsToPlay = true
                    PlayerNowPlayingCenter.shared.claim(self)
                }
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
        if let session, !session.isEndpointValid {
            // Not the stream's fault: no fallback step. An idle page whose session the engine closed waits for
            // play() (see rebuildForLostEndpoint) instead of showing a spinner forever.
            if shouldRebuildLostEndpointNow(session) {
                rebuildForLostEndpoint(position: lastKnownPosition)
            } else if !startupDone, status == .loading || status == .buffering {
                status = .paused
            }
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
            noteDirectFallback()
            beginFallback()
            rebuild(position: position, reason: .fallback)
            return
        }
        if audioOnlyStream != nil {
            // The audio-only item failed on the direct path too: back to the normal ladder with picture.
            audioOnly = false
            ToastCenter.shared.show("听视频播放失败，已恢复视频画面")
            beginFallback()
            rebuild(position: position, reason: .fallback)
            return
        }
        if !fallbackSteps.contains(.noProxy), session != nil, item?.epId == 0 {
            // Even the proxy's unaccelerated item failed (e.g. the loopback connection itself breaks): play the
            // CDN's MP4 without the proxy before trying lower qualities through it.
            fallbackSteps.insert(.noProxy)
            forceNoProxy = true
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
        // 单个循环 replays right away (below): not an end for the controls or the screen lock.
        let loops = sleepTimer != .endOfEpisode
            && (AppSettings.shared.player.playRepeat == .singleCycle || loopsAtEnd?() == true)
        if !loops { overlay.playbackEnded() }
        PlayerNowPlayingCenter.shared.playbackChanged(self)
        if sleepTimer == .endOfEpisode {
            sleepTimer = .off
            sleepRemaining = nil
            ToastCenter.shared.show("定时时间已到，已暂停")
            scheduleAutoExitFullscreen()
            return
        }
        if loops {
            // 单个循环 (here, so it also works without a page, e.g. offline files).
            play()
            return
        }
        onEnded?()
        // Swiping through vertical videos: the end of one is no reason to leave fullscreen.
        if !canSwipeVideos { scheduleAutoExitFullscreen() }
    }

    /// 「自动退出全屏」 when nothing new was loaded after the end.
    private func scheduleAutoExitFullscreen() {
        guard isFullscreen else { return }
        autoExitTask?.cancel()
        autoExitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // Not from under a sheet: leaving fullscreen closes it, with whatever is being typed there. Once it has
            // gone, what comes next gets the same time to load.
            var waited = false
            while let self, !Task.isCancelled, self.status == .ended, self.overlay.sheet != nil {
                waited = true
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if waited { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            guard let self, !Task.isCancelled, self.status == .ended, self.overlay.sheet == nil else { return }
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
        if isEndpointLost, origin != .startup {
            // The item's proxy session is gone, so seeking it would only fail: rebuild at the target, which
            // `displayTime()` shows meanwhile (`install` ends the pseudo seek).
            seekToken += 1
            isSeeking = true
            seekTarget = target
            // No stale audio from the old buffer meanwhile (the play intent is kept; not an external pause).
            player.pause()
            lastKnownPosition = target
            currentTime = target
            timeline.update(time: target, duration: total, buffered: 0)
            surface.danmaku.seek(to: target)
            heartbeat.seeked(to: target)
            tracker?.didSeek(to: target)
            if origin == .user { skipPrompt = nil }
            updateSubtitle(at: target)
            rebuild(position: target, reason: .endpoint)
            PlayerNowPlayingCenter.shared.playbackChanged(self)
            return
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
        // The layer's readiness KVO only reports changes; if it stayed true across an item replacement the cover
        // would never hide. Once the new item is ready and positioned, a ready layer shows its frame.
        if !hasFirstFrame, startupDone { layerReadinessChanged() }

        if let session {
            if !session.isEndpointValid {
                // A failed or ended player waits for the user.
                if shouldRebuildLostEndpointNow(session), !isFailed, status != .ended {
                    rebuildForLostEndpoint(position: nil)
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
        noteDirectFallback()
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
        if isVerticalVideo {
            mask = .portrait
            orientation = .portrait
        } else {
            // Device landscapeRight (home button left) = interface landscapeLeft.
            let device = deviceOrientation ?? UIDevice.current.orientation
            orientation = device == .landscapeRight ? .landscapeLeft : .landscapeRight
            mask = .landscape
        }
        fullscreenByRotation = byRotation
        fullscreenPathCount = pageRouter?.path.count ?? 0
        refullscreenWhenPageReturns = false
        isFullscreen = true
        overlay.fullscreenChanged()
        // Out of the way while the player fades in and the screen turns (the presenter turns it once the player is
        // on screen); back once it stands still.
        overlay.hideControls()
        let shown: () -> Void = { [weak self] in
            guard let self, self.isFullscreen else { return }
            self.overlay.showControls()
        }
        let takeSurface: () -> Void = { [weak self] in self?.surfaceInFullscreen = true }
        let stage = PlayerStageView(controller: self, overlay: overlay, role: .fullscreen)
        if !fullscreenPresenter.present(stage, mask: mask, orientation: orientation, showsStatusBar: isVerticalVideo,
                                        willPresent: takeSurface, onShown: shown) {
            isFullscreen = false
            surfaceInFullscreen = false
            fullscreenByRotation = false
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
        containerHidden = false
        startOrientationObserving()
        if item != nil { startTicking() }
        if resumeOnContainerAppear {
            resumeOnContainerAppear = false
            if item != nil { play() }
        }
        applyPendingAccelerationSwitch()
    }

    func containerDidDisappear() {
        // The fullscreen presentation hides the inline container: not a real disappearance.
        guard !isFullscreen else { return }
        containerVisible = false
        containerHidden = true
        stopOrientationObserving()
        // The detail page pauses a playing / buffering player when a page is pushed over it; one still loading
        // would start playing hidden once ready. Hold its intent until the page is back (or `stop()` comes).
        if wantsToPlay, item != nil, status != .playing, status != .buffering, !isPiPBusy {
            wantsToPlay = false
            resumeOnContainerAppear = true
        }
    }

    /// Picture in Picture is running or starting (the player must keep going without the page).
    var isPiPBusy: Bool { isPiPActive || pipCoordinator.isActive || pipCoordinator.isStarting }

    /// Another page covers this player's page, and it is not going on in Picture in Picture.
    var isCoveredByPage: Bool { containerHidden && !isPiPBusy }

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
        // Rotation rules are phone-only (an iPad rotates its whole UI freely).
        guard UIDevice.current.userInterfaceIdiom == .phone,
              AppSettings.shared.player.autoFullscreenOnRotate, !overlay.isLocked, item != nil,
              UIApplication.shared.applicationState == .active, !isPiPActive else { return }
        if case .failed = status { return }
        if isFullscreen {
            // Not while a sheet is open over the fullscreen player (e.g. typing in 发弹幕): exiting would close it.
            if orientation == .portrait, fullscreenByRotation, !isVerticalVideo, overlay.sheet == nil { exitFullscreen() }
        } else if containerVisible, orientation.isLandscape, !isVerticalVideo, overlay.sheet == nil,
                  fullscreenPresenter.isLeaving || !PlayerFullscreenPresenter.isModalPresented() {
            // Still leaving (turned back the other way meanwhile): shown again once that is done. Dropped, it
            // would not come back, as the phone stays landscape.
            enterFullscreen(byRotation: true, deviceOrientation: orientation)
        }
    }
}
