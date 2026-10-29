import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Combine

/// AVPlayer wrapper for a live room: HLS with the Bilibili CDN headers, CDN fallback (each URL is a
/// different host), stall recovery, mute and Picture in Picture.
@MainActor
final class LivePlayerController: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    let player = AVPlayer()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var isMuted = false
    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPPossible = false
    /// Index into `urls` of the line (CDN) being played.
    @Published private(set) var urlIndex = 0
    @Published private(set) var urls: [String] = []

    /// Every URL failed; the owner usually requests fresh (short-lived) URLs.
    var onExhausted: (() -> Void)?
    /// Playback actually started (the owner resets its retry budget).
    var onPlaying: (() -> Void)?

    /// The user wants playback (false after 暂停 / stop).
    @Published private(set) var wantsPlay = false

    private var generation = 0
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var itemCancellables = Set<AnyCancellable>()
    private var appCancellables = Set<AnyCancellable>()
    private var watchdog: Task<Void, Never>?
    private var notPlayingSince: Date?
    private var pausedAt: Date?
    private var backgroundedAt: Date?
    private var isInBackground = false
    private var pip: AVPictureInPictureController?
    private weak var pipLayer: AVPlayerLayer?
    private let pipDelegate = LivePiPDelegate()

    static var supportsPiP: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.timeControlChanged() }
        }
        pipDelegate.onActiveChange = { [weak self] active in
            Task { @MainActor [weak self] in self?.isPiPActive = active }
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.didEnterBackground() }
            }
            .store(in: &appCancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.willEnterForeground() }
            }
            .store(in: &appCancellables)
    }

    // MARK: Playback

    /// Plays `urls` (best first), starting at `index`.
    func play(urls: [String], from index: Int = 0) {
        self.urls = urls
        urlIndex = min(max(index, 0), max(urls.count - 1, 0))
        wantsPlay = true
        pausedAt = nil
        startCurrent()
    }

    /// 线路: replays another CDN URL of the same stream.
    func switchLine(_ index: Int) {
        guard urls.indices.contains(index) else { return }
        urlIndex = index
        wantsPlay = true
        pausedAt = nil
        startCurrent()
    }

    func togglePlay() {
        if wantsPlay { pause() } else { resume() }
    }

    func pause() {
        wantsPlay = false
        pausedAt = Date()
        player.pause()
        if phase == .playing || phase == .loading { phase = .paused }
        isBuffering = false
    }

    /// Resumes; after a longer pause the stream restarts at the live edge with a fresh item.
    func resume() {
        guard !urls.isEmpty else { return }
        wantsPlay = true
        let stale = pausedAt.map { Date().timeIntervalSince($0) > 8 } ?? false
        pausedAt = nil
        if stale || player.currentItem == nil || player.currentItem?.status == .failed {
            if urlIndex >= urls.count { urlIndex = 0 }
            startCurrent()
        } else {
            player.play()
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    func stop() {
        generation += 1
        wantsPlay = false
        watchdog?.cancel()
        watchdog = nil
        itemCancellables.removeAll()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isBuffering = false
        phase = .idle
    }

    private func startCurrent() {
        generation += 1
        let gen = generation
        itemCancellables.removeAll()
        statusObservation = nil
        notPlayingSince = nil
        guard urls.indices.contains(urlIndex), let url = URL(string: urls[urlIndex]) else {
            watchdog?.cancel()
            watchdog = nil
            player.replaceCurrentItem(with: nil)
            isBuffering = false
            phase = .failed("播放失败")
            onExhausted?()
            return
        }
        phase = .loading
        isBuffering = true
        // Bilibili's live CDN rejects requests without the web Referer / UA.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": LiveAPI.playerHeaders])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(generation: gen) }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemDidPlayToEndTime] {
            // Failure, or the playlist ended (stream cut): try the next line.
            center.publisher(for: name, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.advance(generation: gen) }
                }
                .store(in: &itemCancellables)
        }
        center.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.stalled(generation: gen) }
            }
            .store(in: &itemCancellables)

        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        if wantsPlay { player.play() }
        startWatchdog(generation: gen)
    }

    private func itemStatusChanged(generation gen: Int) {
        guard gen == generation, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if wantsPlay { player.play() }
        case .failed:
            advance(generation: gen)
        default:
            break
        }
    }

    private func advance(generation gen: Int) {
        guard gen == generation else { return }
        urlIndex += 1
        startCurrent()
    }

    private func stalled(generation gen: Int) {
        guard gen == generation, wantsPlay else { return }
        isBuffering = true
    }

    private func timeControlChanged() {
        switch player.timeControlStatus {
        case .playing:
            isBuffering = false
            notPlayingSince = nil
            if phase != .playing {
                phase = .playing
                onPlaying?()
            }
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        case .paused:
            // With automaticallyWaitsToMinimizeStalling = false a dry buffer pauses the player;
            // the watchdog resumes it.
            isBuffering = wantsPlay && player.currentItem != nil
            if !wantsPlay, phase == .playing || phase == .loading { phase = .paused }
        @unknown default:
            break
        }
    }

    private func startWatchdog(generation gen: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self?.watchdogTick(generation: gen) == true else { return }
            }
        }
    }

    /// Once per second: resumes after a stall, and moves to the next line after 15 s without
    /// playback. Returns false to stop the loop.
    private func watchdogTick(generation gen: Int) -> Bool {
        guard gen == generation else { return false }
        guard wantsPlay, !(isInBackground && !isPiPActive) else {
            notPlayingSince = nil
            return true
        }
        if player.timeControlStatus == .playing {
            notPlayingSince = nil
            return true
        }
        let now = Date()
        let since = notPlayingSince ?? now
        notPlayingSince = since
        if player.currentItem?.status == .readyToPlay, player.rate == 0 { player.play() }
        if now.timeIntervalSince(since) > 15 {
            notPlayingSince = nil
            advance(generation: gen)
            return false
        }
        return true
    }

    private func didEnterBackground() {
        isInBackground = true
        backgroundedAt = Date()
    }

    private func willEnterForeground() {
        isInBackground = false
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        notPlayingSince = nil
        guard wantsPlay, !isPiPActive, !urls.isEmpty else { return }
        if away > 8 || player.currentItem == nil {
            if urlIndex >= urls.count { urlIndex = 0 }
            startCurrent()
        } else {
            player.play()
        }
    }

    // MARK: Picture in Picture

    /// Called by `LivePlayerSurface` with its layer; (re)creates the PiP controller for it.
    func attach(layer: AVPlayerLayer) {
        guard LivePlayerController.supportsPiP, layer !== pipLayer else { return }
        pipLayer = layer
        pipPossibleObservation = nil
        pip?.delegate = nil
        let controller: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: layer)
        pip = controller
        guard let controller else { return }
        controller.delegate = pipDelegate
        controller.canStartPictureInPictureAutomaticallyFromInline = AppSettings.shared.player.autoPiP
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPiPPossible() }
        }
    }

    private func refreshPiPPossible() {
        isPiPPossible = pip?.isPictureInPicturePossible ?? false
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }
}

final class LivePiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    var onActiveChange: ((Bool) -> Void)?

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        onActiveChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - Surface

final class LivePlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The `AVPlayerLayer` host.
struct LivePlayerSurface: UIViewRepresentable {
    let controller: LivePlayerController

    func makeUIView(context: Context) -> LivePlayerLayerUIView {
        let view = LivePlayerLayerUIView()
        view.backgroundColor = .black
        // Taps go to the SwiftUI controls overlay.
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = controller.player
        controller.attach(layer: view.playerLayer)
        return view
    }

    func updateUIView(_ view: LivePlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== controller.player { view.playerLayer.player = controller.player }
        controller.attach(layer: view.playerLayer)
    }
}

// MARK: - Scrolling danmaku overlay

/// Right-to-left live danmaku over the player (UIKit labels, constant speed per screen so a lane
/// never overlaps; dropped when every lane is busy). Follows the 弹幕设置 opacity / size / area.
struct LiveDanmakuOverlay: UIViewRepresentable {
    let feed: PassthroughSubject<LiveDanmakuMessage, Never>
    var isFullscreen: Bool

    final class Coordinator {
        var cancellable: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LiveDanmakuOverlayUIView {
        let view = LiveDanmakuOverlayUIView(frame: .zero)
        view.isFullscreen = isFullscreen
        context.coordinator.cancellable = feed
            .receive(on: DispatchQueue.main)
            .sink { [weak view] message in view?.shoot(message) }
        return view
    }

    func updateUIView(_ view: LiveDanmakuOverlayUIView, context: Context) {
        view.isFullscreen = isFullscreen
    }

    static func dismantleUIView(_ view: LiveDanmakuOverlayUIView, coordinator: Coordinator) {
        coordinator.cancellable = nil
        view.clear()
    }
}

final class LiveDanmakuOverlayUIView: UIView {
    var isFullscreen = false

    private var laneFreeAt: [CFTimeInterval] = []
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            clear()
        }
    }

    func clear() {
        for v in subviews {
            v.layer.removeAllAnimations()
            v.removeFromSuperview()
        }
        laneFreeAt = []
    }

    func shoot(_ message: LiveDanmakuMessage) {
        let s = AppSettings.shared.danmaku
        guard s.enabled, !s.hideScroll, window != nil, bounds.width > 40, bounds.height > 20 else { return }
        if s.hideColorful && (message.color & 0xFFFFFF) != 0xFFFFFF { return }
        if subviews.count >= 80 { return }

        let fontSize = CGFloat(15 * (isFullscreen ? s.fontScaleFullscreen : s.fontScale))
        let font = UIFont.systemFont(ofSize: max(10, fontSize), weight: s.fontWeight >= 5 ? .semibold : .regular)
        let laneHeight = ceil(font.lineHeight * CGFloat(max(1.0, min(s.lineHeight, 3.0))))
        let lanes = max(1, Int(bounds.height * CGFloat(s.area.rawValue) / laneHeight))
        if laneFreeAt.count != lanes { laneFreeAt = Array(repeating: 0, count: lanes) }
        let now = CACurrentMediaTime()
        guard let lane = laneFreeAt.indices.first(where: { laneFreeAt[$0] <= now }) else { return }

        let text = message.kind == .superChat ? "【醒目留言】\(message.text)" : message.text
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: message.kind == .superChat ? UIColor.systemYellow : LiveDanmakuOverlayUIView.color(message.color),
            .strokeColor: UIColor.black.withAlphaComponent(0.85),
            .strokeWidth: -2.5,
        ])
        label.sizeToFit()
        let width = label.bounds.width
        let height = label.bounds.height
        let duration = max(3.0, s.scrollDuration)
        let speed = bounds.width / CGFloat(duration)
        let travel = bounds.width + width
        label.frame = CGRect(x: bounds.width, y: CGFloat(lane) * laneHeight + (laneHeight - height) / 2,
                             width: width, height: height)
        label.alpha = CGFloat(min(max(s.opacity, 0.1), 1))
        addSubview(label)
        laneFreeAt[lane] = now + CFTimeInterval((width + 24) / speed)
        UIView.animate(withDuration: TimeInterval(travel / speed), delay: 0,
                       options: [.curveLinear, .beginFromCurrentState],
                       animations: { label.frame.origin.x = -width },
                       completion: { _ in label.removeFromSuperview() })
    }

    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
