import AVFoundation
import Combine
import SwiftUI

/// The player of one 短视频 item: the DASH streams through the local proxy, as in the main player, on a single
/// connection unless 「竖屏视频禁用加速」 is off. They start faster than the html5 MP4, which is rarely watched and often has
/// to come from further away the first time. That MP4 remains the fallback, through the proxy and then straight from the
/// CDN. It feeds the engine session the signals the main player does (see the wiring notes in AccelerationEngine.swift).
/// The feed keeps the current item and its neighbours prepared so a swipe starts at once; the video loops like the
/// official app's.
@MainActor
final class ShortVideoPlayback: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    let item: ShortVideoItem
    let player = AVPlayer()
    /// The danmaku over this video. It lives here, not in the page: cells are reused and rebuilt.
    let danmaku = DanmakuOverlayView(frame: .zero)
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPlaying = false
    /// Waiting for data while it should be playing.
    @Published private(set) var isBuffering = false
    /// Seconds.
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double
    /// What the progress bar shows.
    let timeline = PlayerTimeline()
    /// The long-press 倍速 is active.
    @Published private(set) var isFastForward = false

    private var session: PlaybackSession?
    /// Whether the stream was loaded for acceleration.
    private var usesAcceleration = false
    /// AVPlayer refused the DASH item, a codec it cannot play for instance, which only shows once it has it: the MP4.
    private var dashFailed = false
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var observers: Set<AnyCancellable> = []
    /// Observers of the current AVPlayerItem, dropped with it.
    private var itemObservers: Set<AnyCancellable> = []
    /// Where a rebuilt item resumes.
    private var resumeAt: Double?
    private var wantsPlay = false
    private var startedPlaying = false
    private var seeking = false
    /// Furthest position reached, for the watch-history heartbeat.
    private var furthest: Double = 0
    private var reportedHistory = false

    init(item: ShortVideoItem) {
        self.item = item
        duration = Double(item.duration)
        timeline.reset(duration: duration)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        danmaku.isFullscreen = true
        // Swiping through videos: a toast for each one whose uploader closed danmaku would only get in the way.
        danmaku.onClosedByUploader = {}
        danmaku.configure { [weak self] in
            guard let self else { return (time: 0, rate: 1, isPlaying: false) }
            return (time: self.player.currentTime().seconds, rate: self.player.rate,
                    isPlaying: self.player.timeControlStatus == .playing)
        }
        observePlayer()
    }

    // MARK: Control

    /// Resolves the stream and installs the item, paused. Safe to call repeatedly.
    func prepare() {
        switch phase {
        case .idle, .failed: break
        case .loading, .ready: return
        }
        phase = .loading
        loadTask = Task { [weak self] in await self?.load() }
    }

    func play() {
        wantsPlay = true
        reportedHistory = false
        if rebuildIfEndpointLost() { return }
        prepare()
        if phase == .ready { player.playImmediately(atRate: isFastForward ? fastRate : 1) }
    }

    /// The engine dropped this session (it keeps four; another page took the slot) or its listener changed port
    /// after the background: the item's URL is dead, so start over where it was. Only when it should play.
    private func rebuildIfEndpointLost() -> Bool {
        guard let session, !session.isEndpointValid else { return false }
        resumeAt = position > 1 ? position : nil
        teardown()
        prepare()
        return true
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func togglePlay() {
        if wantsPlay { pause() } else { play() }
    }

    var isPaused: Bool { !wantsPlay }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds))
        guard player.currentItem != nil else {
            // Dragged while it is still loading: it starts there (`install`).
            resumeAt = target
            position = target
            timeline.update(time: target, duration: duration, buffered: 0)
            return
        }
        session?.playerWillSeek(to: target, outsideBuffer: !isBuffered(target))
        seeking = true
        position = target
        timeline.update(time: target, duration: duration, buffered: timeline.snapshot.buffered)
        danmaku.seek(to: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
    }

    /// Long-press 倍速 (the player setting's speed, 2× by default).
    func setFastForward(_ on: Bool) {
        isFastForward = on
        if wantsPlay, phase == .ready { player.rate = on ? fastRate : 1 }
    }

    /// The long-press 倍速 as it plays. HLS goes above 2× only with I-frame playlists, as in `PlayerController.playerRate`.
    var fastSpeed: Double {
        let speed = max(1.25, AppSettings.shared.player.longPressSpeed)
        return speed > 2 && session?.isHLS == true && player.currentItem?.canPlayFastForward != true ? 2 : speed
    }

    private var fastRate: Float { Float(fastSpeed) }

    /// 重试: loads again and goes on where it was, or where it was dragged to while it loaded.
    func retry() {
        if resumeAt == nil, position > 1 { resumeAt = position }
        dashFailed = false
        teardown()
        play()
    }

    private var wantsAcceleration: Bool {
        AppSettings.shared.acceleration.accelerates(pgc: false, vertical: item.isPortrait)
    }

    /// 启用海外加速 / 竖屏视频禁用加速 changed: loads again on the matching path, from where it is.
    func accelerationChanged() {
        guard phase != .idle, wantsAcceleration != usesAcceleration else { return }
        if resumeAt == nil, position > 1 { resumeAt = position }
        teardown()
        prepare()
    }

    /// Stops everything and releases the stream; `prepare()` starts over.
    func close() {
        reportHistoryIfNeeded()
        wantsPlay = false
        resumeAt = nil
        teardown()
    }

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        itemObservers.removeAll()
        player.replaceCurrentItem(with: nil)
        session?.close()
        session = nil
        startedPlaying = false
        if phase != .idle { phase = .idle }
    }

    /// Records how far this video was watched (when 「记录观看历史」 is on), once per viewing.
    func reportHistoryIfNeeded() {
        guard !reportedHistory, furthest >= 1, AppSettings.shared.general.reportHistory, BiliHTTP.shared.isLoggedIn,
              let cid = resolvedCid else { return }
        reportedHistory = true
        let played = Int(furthest.rounded())
        let (aid, bvid) = (item.aid, item.bvid)
        Task.detached { try? await VideoAPI.heartbeat(aid: aid, bvid: bvid, cid: cid, playedTime: played) }
    }

    // MARK: Loading

    /// The video's cid, once `load` knows it (the feed does not always say).
    private(set) var resolvedCid: Int64?

    private func load() async {
        do {
            var cid = item.cid
            if cid == 0 {
                cid = try await VideoAPI.detail(item.videoRef).cid
            }
            resolvedCid = cid
            let (aid, bvid) = (item.aid, item.bvid)
            let qn = min(AppSettings.shared.player.preferredQuality, VideoQuality.q1080.rawValue)
            let accelerate = wantsAcceleration
            usesAcceleration = accelerate
            let routeKey = (bvid.isEmpty ? "av\(aid)" : bvid) + ":short"
            if !dashFailed, let dash = await prepareDash(cid: cid, qn: qn, routeKey: routeKey, accelerate: accelerate) {
                if Task.isCancelled {
                    dash.session.close()
                    return
                }
                if dash.duration > 0 { duration = dash.duration }
                danmaku.load(cid: cid, aid: aid, duration: duration)
                session = dash.session
                install(AVPlayerItem(asset: AVURLAsset(url: dash.session.url)))
                return
            }
            let info = try await VideoAPI.progressivePlayInfo(aid: aid, bvid: bvid, cid: cid, qn: qn)
            try Task.checkCancellation()
            guard let segment = info.durl.first else { throw BiliError.other("视频资源不存在") }
            if info.duration > 0 { duration = info.duration }
            danmaku.load(cid: cid, aid: aid, duration: duration)

            let refresher = AccelerationEngine.progressiveRefresher(for: segment) {
                try await VideoAPI.progressivePlayInfo(aid: aid, bvid: bvid, cid: cid, qn: qn).durl
            }
            var made: PlaybackSession?
            for attempt in accelerate ? [true, false] : [false] {
                made = try? await AccelerationEngine.shared.prepareProgressive(
                    routeKey: routeKey, segment: segment, accelerate: attempt, refreshURLs: refresher)
                if made != nil || Task.isCancelled { break }
            }
            if Task.isCancelled {
                made?.close()
                return
            }
            let asset: AVURLAsset
            if let made {
                session = made
                asset = AVURLAsset(url: made.url)
            } else {
                // The proxy cannot serve it: straight from the CDN, which checks Referer / User-Agent.
                guard let url = URL(string: segment.url.biliHTTPS) else { throw BiliError.other("视频地址无效") }
                let headers = ["Referer": "https://www.bilibili.com/", "User-Agent": BiliHTTP.webUserAgent]
                asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }
            install(AVPlayerItem(asset: asset))
        } catch {
            if Task.isCancelled || ListMapping.isCancellation(error) { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "加载失败")
        }
    }

    /// nil: no usable DASH answer or session, which the MP4 path below may still be able to play.
    private func prepareDash(cid: Int64, qn: Int, routeKey: String, accelerate: Bool)
    async -> (session: PlaybackSession, duration: Double)? {
        let (aid, bvid) = (item.aid, item.bvid)
        let player = AppSettings.shared.player
        let hdr = player.allowHDR && PlayerDeviceSupport.hdrEligible
        let constraints = PlayerStreamConstraints(preferredQuality: qn, codec: player.preferredCodec,
                                                  av1Supported: PlayerDeviceSupport.av1HardwareDecode, hdrAllowed: hdr,
                                                  preferLossless: false, forceNormalAudio: true)
        guard let info = try? await VideoAPI.playInfo(aid: aid, bvid: bvid, cid: cid, qn: qn), info.isDash, !info.isDRM,
              let picked = PlayerStreamPicker.choose(info, constraints) else { return nil }
        let refresher = PlayerStreamPicker.makeRefresher(aid: aid, bvid: bvid, cid: cid, epId: 0, seasonId: 0, choice: picked)
        for attempt in accelerate ? [true, false] : [false] {
            let request = PlaybackRequest(routeKey: routeKey, video: picked.video, audio: picked.audio,
                                          duration: info.duration, accelerate: attempt, allowHDR: hdr,
                                          refreshURLs: refresher)
            if let made = try? await AccelerationEngine.shared.prepare(request) {
                return (made, info.duration)
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private func install(_ playerItem: AVPlayerItem) {
        playerItem.preferredForwardBufferDuration = max(5, AppSettings.shared.acceleration.forwardBufferSeconds)
        itemObservers.removeAll()
        observeItem(playerItem)
        player.replaceCurrentItem(with: playerItem)
        phase = .ready
        if let resumeAt {
            self.resumeAt = nil
            seek(to: resumeAt)
        }
        if wantsPlay { player.playImmediately(atRate: isFastForward ? fastRate : 1) }
    }

    // MARK: Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &observers)
        // A call or Siri pauses the player behind our back: show it as paused, so one tap resumes.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.began.rawValue { self?.wantsPlay = false }
            }
            .store(in: &observers)
    }

    private func observeItem(_ playerItem: AVPlayerItem) {
        let center = NotificationCenter.default
        center.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.loop() }
            .store(in: &itemObservers)
        center.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.session?.playerDidStall() }
            .store(in: &itemObservers)
        playerItem.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playerItem] status in
                guard status == .failed, let self, playerItem === self.player.currentItem else { return }
                self.itemFailed(message: playerItem?.error?.localizedDescription)
            }
            .store(in: &itemObservers)
        playerItem.publisher(for: \.duration)
            .receive(on: RunLoop.main)
            .sink { [weak self] d in
                guard let self, d.isNumeric, d.seconds > 0 else { return }
                self.duration = d.seconds
                self.timeline.update(time: self.position, duration: d.seconds, buffered: self.timeline.snapshot.buffered)
            }
            .store(in: &itemObservers)
    }

    private func itemFailed(message: String?) {
        guard let session, session.isHLS, session.isEndpointValid, !dashFailed else {
            phase = .failed(message ?? "播放失败")
            return
        }
        dashFailed = true
        if resumeAt == nil, position > 1 { resumeAt = position }
        teardown()
        prepare()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if wantsPlay, rebuildIfEndpointLost() { return }
        if !seeking { position = seconds }
        if isPlaying { furthest = max(furthest, seconds) }
        guard let current = player.currentItem else { return }
        let ahead = bufferedAhead(at: seconds, in: current)
        timeline.update(time: position, duration: duration, buffered: seconds + ahead)
        guard let session else { return }
        session.update(time: seconds, rate: Double(player.rate), playing: isPlaying && !seeking,
                       bufferedAhead: ahead, cacheFull: ahead >= current.preferredForwardBufferDuration - 1)
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status == .playing
        isBuffering = wantsPlay && status == .waitingToPlayAtSpecifiedRate
        danmaku.playbackStateDidChange()
        if status == .playing { startedPlaying = true }
        if status == .waitingToPlayAtSpecifiedRate, startedPlaying, !seeking,
           player.reasonForWaitingToPlay == .toMinimizeStalls {
            session?.playerDidStall()
        }
    }

    private func loop() {
        reportHistoryIfNeeded()
        reportedHistory = false
        furthest = 0
        session?.playerWillSeek(to: 0, outsideBuffer: !isBuffered(0))
        player.seek(to: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsPlay else { return }
                self.player.playImmediately(atRate: self.isFastForward ? self.fastRate : 1)
            }
        }
    }

    private func bufferedAhead(at time: Double, in item: AVPlayerItem) -> Double {
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds, end = (range.start + range.duration).seconds
            if time >= start - 0.5, time <= end { return max(0, end - time) }
        }
        return 0
    }

    private func isBuffered(_ time: Double) -> Bool {
        guard let current = player.currentItem else { return false }
        return current.loadedTimeRanges.contains { value in
            let r = value.timeRangeValue
            return time >= r.start.seconds && time <= (r.start + r.duration).seconds
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}

/// Puts a playback's danmaku over its video.
struct ShortVideoDanmakuLayer: UIViewRepresentable {
    let danmaku: DanmakuOverlayView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        // The page's playback can be replaced while the cell stays: the old overlay must not stay in the window.
        for view in host.subviews where view !== danmaku { view.removeFromSuperview() }
        guard danmaku.superview !== host else { return }
        danmaku.removeFromSuperview()
        danmaku.frame = host.bounds
        danmaku.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(danmaku)
    }
}

/// An `AVPlayerLayer` for SwiftUI that reports when the first frame is on screen (the cover is
/// shown until then).
struct ShortVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill: Bool
    @Binding var readyForDisplay: Bool

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.onReadyChange = { ready in
            DispatchQueue.main.async { readyForDisplay = ready }
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onReadyChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                self?.onReadyChange?(layer.isReadyForDisplay)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
