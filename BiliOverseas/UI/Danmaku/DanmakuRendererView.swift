import UIKit
import Combine

/// Pre-rendered danmaku bitmap (text with outline), cached by content and style.
final class DanmakuTextBitmap: NSObject {
    let image: CGImage
    /// Size in points.
    let size: CGSize
    init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// One danmaku on screen.
private final class DanmakuSprite {
    let item: DanmakuItem
    let placement: DanmakuPlacement
    let layer: CALayer
    let size: CGSize

    init(item: DanmakuItem, placement: DanmakuPlacement, layer: CALayer, size: CGSize) {
        self.item = item
        self.placement = placement
        self.layer = layer
        self.size = size
    }
}

/// One mode-7 danmaku on screen: positioned and animated by its `DanmakuAdvancedSpec`, outside the track layout.
private final class DanmakuSpecialSprite {
    let item: DanmakuItem
    let spec: DanmakuAdvancedSpec
    let layer: CALayer

    init(item: DanmakuItem, spec: DanmakuAdvancedSpec, layer: CALayer) {
        self.item = item
        self.spec = spec
        self.layer = layer
    }
}

/// A tapped danmaku (`DanmakuOverlayView.suspendDanmaku(at:)`): the item and its frame in the overlay.
struct DanmakuOverlayHit {
    let item: DanmakuItem
    let frame: CGRect
}

/// 点赞 state of one danmaku as far as this session knows (the segment data has the count, not whether the user
/// liked it).
struct DanmakuLikeState: Equatable {
    var liked: Bool
    var count: Int64
}

/// Breaks the CADisplayLink → target retain cycle. The link runs on the main run loop.
@MainActor
private final class DanmakuDisplayLinkProxy: NSObject {
    weak var owner: DanmakuOverlayView?

    init(owner: DanmakuOverlayView) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        if let owner {
            owner.displayLinkFired(link)
        } else {
            link.invalidate()
        }
    }
}

/// Time-driven danmaku overlay. Put it above the video (same frame as the player), call
/// `configure(timeProvider:)` with a closure that reads the player clock, then `load(cid:aid:duration:)`.
///
/// Every frame a CADisplayLink reads the video time, emits the danmaku whose time has been
/// reached, lays them out with `DanmakuLayoutEngine` and positions each one (a reusable CALayer
/// whose contents is a pre-rendered CGImage) as a pure function of video time. So pausing stops
/// motion, seeking clears and re-flows the screen, and 2× playback moves danmaku 2× faster.
/// Settings follow `AppSettings.shared.danmaku` automatically (`apply(_:)` can also be called).
/// Mode-7 「高级弹幕」 are drawn as positioned, moving / fading bitmaps (`DanmakuAdvancedSpec`); code (8) and
/// BAS (9) danmaku are never shown.
/// The view never receives touches; the player hit-tests taps with `suspendDanmaku(at:)` (「点击弹幕」), which
/// also freezes the hit item until `resume()`.
final class DanmakuOverlayView: UIView {
    typealias TimeProvider = () -> (time: Double, rate: Float, isPlaying: Bool)

    // MARK: Public state

    /// Fullscreen uses 「全屏字体大小」 (default ×1.2).
    var isFullscreen: Bool = false {
        didSet { if oldValue != isFullscreen { styleDidChange() } }
    }

    /// Called once per video when the server reports the uploader closed danmaku (state == 1).
    /// When nil, the toast 「UP主已关闭弹幕」 is shown instead.
    var onClosedByUploader: (() -> Void)?

    /// The uploader closed danmaku for the loaded video (pass to `DanmakuSendSheet(isClosed:)`).
    private(set) var isClosedByUploader = false

    /// Danmaku currently on screen (for 「弹幕列表」).
    var visibleItems: [DanmakuItem] { sprites.map(\.item) + specials.map(\.item) }

    var onScreenCount: Int { sprites.count + specials.count }

    /// Called when the item frozen by `suspendDanmaku(at:)` leaves the screen anyway (seek, re-layout, new video,
    /// filter change, danmaku hidden): the tap bubble must go with it.
    var onSuspendedLost: (() -> Void)?

    /// An item is frozen by `suspendDanmaku(at:)`.
    var hasSuspendedDanmaku: Bool { suspended != nil }

    /// Space above the first track.
    static let topInset: CGFloat = 4
    /// Extra spacing kept between consecutive scroll danmaku of a track.
    static let scrollGap: Double = 6
    /// Mode-7 danmaku older than this are not brought back by a re-flow (seek) even when still alive.
    static let maxSpecialLifetime: Double = 30

    // MARK: Private state

    private var timeProvider: TimeProvider?
    private var settings: DanmakuSettings
    private var filter: DanmakuFilter
    private var engine = DanmakuLayoutEngine(config: DanmakuLayoutConfig())
    private var selfMidHash: String?

    private var loader: DanmakuSegmentLoader?
    private var generation = 0
    private var loadedCid: Int64 = 0
    private var rawSegments: [Int: [DanmakuItem]] = [:]
    private var segments: [Int: [DanmakuItem]] = [:]
    private var requestedSegments: Set<Int> = []
    private var retryAfter: [Int: CFTimeInterval] = [:]
    private var localItems: [DanmakuItem] = []
    private var nextLocalID: Int64 = -1
    private var closedNotified = false

    private var sprites: [DanmakuSprite] = []
    private var specials: [DanmakuSpecialSprite] = []
    /// Parsed mode-7 content (nil = not a usable array), by content.
    private var specCache: [String: DanmakuAdvancedSpec?] = [:]
    /// Frozen by a tap (「点击弹幕」): not moved and not expired until `resume()`.
    private var suspended: DanmakuSprite?
    private var likeStates: [Int64: DanmakuLikeState] = [:]
    private var activeIDs: Set<Int64> = []
    private var layerPool: [CALayer] = []
    private let bitmapCache = NSCache<NSString, DanmakuTextBitmap>()
    private var widthCache: [String: CGFloat] = [:]
    private var mainFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    private var countFont = UIFont.systemFont(ofSize: 11, weight: .semibold)

    private var displayLink: CADisplayLink?
    private enum LinkMode { case playing, paused, idle }
    private var linkMode: LinkMode?
    private var userVisible = true
    private var isInBackground = false
    private var wasActive = false

    /// Last raw time reported by the provider and the wall time it last changed.
    private var lastRawTime: Double?
    private var lastRawWall: CFTimeInterval = 0
    /// Wall time and play state of the previous frame (forward-jump detection right after a pause).
    private var lastFrameWall: CFTimeInterval = 0
    private var lastFramePlaying = false
    /// Video time the screen currently shows.
    private var renderTime: Double = 0
    /// Danmaku with `time <= lastEmitTime` have been considered for display.
    private var lastEmitTime: Double = 0
    private var lastSegmentCheckWall: CFTimeInterval = 0
    private var prefetchAfterSeek = true
    private var pendingSeekTarget: Double?
    private var pendingSeekDeadline: CFTimeInterval = 0
    private var lastLayoutSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var settingsCancellable: AnyCancellable?

    // MARK: Init

    override init(frame: CGRect) {
        settings = AppSettings.shared.danmaku
        filter = DanmakuFilter(settings: AppSettings.shared.danmaku)
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        settings = AppSettings.shared.danmaku
        filter = DanmakuFilter(settings: AppSettings.shared.danmaku)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        bitmapCache.countLimit = 500
        // A 3× bitmap of a long danmaku is several hundred KB: bound the bytes, not only the count.
        bitmapCache.totalCostLimit = DanmakuOverlayView.bitmapCacheBytes
        layer.opacity = Float(min(max(settings.opacity, 0), 1))
        rebuildFonts()
        isHidden = !(userVisible && settings.enabled)
        settingsCancellable = AppSettings.shared.$danmaku
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.apply(value) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        // The display link only holds the proxy, which invalidates the link once we are gone.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API

    /// The closure is called every frame on the main thread; it should be cheap
    /// (e.g. `player.currentTime().seconds`, `player.rate`, `player.timeControlStatus == .playing`).
    func configure(timeProvider: @escaping () -> (time: Double, rate: Float, isPlaying: Bool)) {
        self.timeProvider = timeProvider
        lastRawTime = nil
        updateActiveState()
    }

    /// Starts loading danmaku for a video part. Calling it again with another cid resets everything.
    func load(cid: Int64, aid: Int64, duration: Double) {
        if cid == loadedCid, let current = loader, current.aid == aid { return }
        if let old = loader { Task { await old.cancelAll() } }
        generation += 1
        loadedCid = cid
        removeAllSprites()
        engine.reset()
        rawSegments.removeAll()
        segments.removeAll()
        requestedSegments.removeAll()
        retryAfter.removeAll()
        localItems.removeAll()
        likeStates.removeAll()
        closedNotified = false
        isClosedByUploader = false
        selfMidHash = BiliHTTP.shared.mid.map { DanmakuHash.midHash(mid: $0) }
        filter = DanmakuFilter(settings: settings, selfMidHash: selfMidHash)
        loader = cid > 0 ? DanmakuSegmentLoader(cid: cid, aid: aid, duration: duration) : nil
        lastRawTime = nil
        renderTime = 0
        lastEmitTime = 0
        prefetchAfterSeek = true
        updateActiveState()
    }

    /// Uses an already available list (offline cache, local file) instead of the network.
    func load(items: [DanmakuItem], duration: Double) {
        if let old = loader { Task { await old.cancelAll() } }
        loader = nil
        generation += 1
        loadedCid = 0
        removeAllSprites()
        engine.reset()
        selfMidHash = BiliHTTP.shared.mid.map { DanmakuHash.midHash(mid: $0) }
        filter = DanmakuFilter(settings: settings, selfMidHash: selfMidHash)
        rawSegments = Dictionary(grouping: items.sorted { $0.time < $1.time }) { DanmakuSegment.index(for: $0.time) }
        segments = rawSegments.mapValues { filter.apply($0) }
        requestedSegments.removeAll()
        retryAfter.removeAll()
        localItems.removeAll()
        likeStates.removeAll()
        closedNotified = false
        isClosedByUploader = false
        lastRawTime = nil
        prefetchAfterSeek = true
        updateActiveState()
    }

    /// Removes every danmaku from the screen (loaded data is kept).
    func clear() {
        removeAllSprites()
        engine.reset()
        lastEmitTime = renderTime
    }

    /// Call right after seeking the player: clears the screen and re-flows danmaku at `time`.
    func seek(to time: Double) {
        let t = time.isFinite ? max(0, time) : 0
        pendingSeekTarget = t
        pendingSeekDeadline = CACurrentMediaTime() + 1.0
        jump(to: t, wall: CACurrentMediaTime())
    }

    func apply(_ newSettings: DanmakuSettings) {
        let old = settings
        guard newSettings != old else { return }
        settings = newSettings
        layer.opacity = Float(min(max(newSettings.opacity, 0), 1))

        if DanmakuFilter.filterFieldsChanged(old, newSettings) {
            filter = DanmakuFilter(settings: newSettings, selfMidHash: selfMidHash)
            for (index, raw) in rawSegments { segments[index] = filter.apply(raw) }
            if newSettings.hideScroll && !old.hideScroll { engine.clear(kind: .scroll) }
            if newSettings.hideTop && !old.hideTop { engine.clear(kind: .top) }
            if newSettings.hideBottom && !old.hideBottom { engine.clear(kind: .bottom) }
            removeSprites { !self.filter.shouldShow($0.item) }
            removeSpecials { !self.filter.shouldShow($0.item) }
        }

        let styleChanged = old.fontScale != newSettings.fontScale
            || old.fontScaleFullscreen != newSettings.fontScaleFullscreen
            || old.fontWeight != newSettings.fontWeight
            || old.strokeWidth != newSettings.strokeWidth
            || old.lineHeight != newSettings.lineHeight
            || old.showVipColorful != newSettings.showVipColorful
        if styleChanged {
            styleDidChange()
        } else if engine.reconfigure(makeLayoutConfig()) {
            reflow(at: renderTime)
        }
        updateActiveState()
    }

    /// Temporary show/hide (e.g. the player's danmaku button or PiP) on top of 「弹幕开关」.
    func setVisible(_ visible: Bool) {
        guard visible != userVisible else { return }
        userVisible = visible
        updateActiveState()
    }

    /// Shows a danmaku the user just sent, immediately, with a border. It is kept so it shows
    /// again after seeking back.
    func insertLocal(_ item: DanmakuItem) {
        var it = item
        it.isSelf = true
        if it.id == 0 {
            it.id = nextLocalID
            nextLocalID -= 1
        }
        it.time = renderTime
        let idx = localItems.firstIndex { $0.time > it.time } ?? localItems.count
        localItems.insert(it, at: idx)
        guard isRenderingActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = spawn(it, now: renderTime)
        CATransaction.commit()
        setLinkMode(.paused)
    }

    /// Hit test for tap-on-danmaku, in this view's coordinates (features.md §8.6): the row is the track under the
    /// point, then static items first and scroll items newest first by their x range (a few points of slack).
    /// Mode-7 danmaku are decorations spread over the picture and are never hit.
    func danmaku(at point: CGPoint) -> DanmakuItem? { sprite(at: point)?.item }

    /// 「点击弹幕」 touch-down: freezes the danmaku under `point` (drawn on top, not moving, not expiring) and
    /// returns it, or nil when there is none. Only one item is frozen at a time; `resume()` lets it go on.
    func suspendDanmaku(at point: CGPoint) -> DanmakuOverlayHit? {
        resume()
        guard let hit = sprite(at: point) else { return nil }
        suspended = hit
        hit.layer.zPosition = 3
        return DanmakuOverlayHit(item: hit.item, frame: hit.layer.frame)
    }

    /// Releases the frozen danmaku; from the next frame on it is where it would be by now (or gone if its time is
    /// over).
    func resume() {
        guard let s = suspended else { return }
        suspended = nil
        s.layer.zPosition = baseZPosition(s.item, kind: s.placement.kind)
    }

    private func sprite(at point: CGPoint) -> DanmakuSprite? {
        guard engine.trackCount > 0 else { return nil }
        let trackH = CGFloat(engine.config.trackHeight)
        func isHit(_ s: DanmakuSprite) -> Bool {
            let top = CGFloat(engine.config.trackY(s.placement.track))
            let frame = s.layer.frame
            return point.y >= top && point.y < top + trackH && point.x >= frame.minX - 6 && point.x <= frame.maxX + 6
        }
        if let s = sprites.last(where: { $0.placement.kind != .scroll && isHit($0) }) { return s }
        return sprites.last(where: { $0.placement.kind == .scroll && isHit($0) })
    }

    // MARK: Interaction state (点赞 / 撤回)

    func likeState(of item: DanmakuItem) -> DanmakuLikeState {
        likeStates[item.id] ?? DanmakuLikeState(liked: false, count: max(0, item.likeCount))
    }

    func setLikeState(_ state: DanmakuLikeState, for id: Int64) {
        guard id != 0 else { return }
        likeStates[id] = state
    }

    /// Drops a danmaku everywhere (after 撤回): screen, loaded segments and own local items.
    func removeDanmaku(id: Int64) {
        guard id != 0 else { return }
        for (index, list) in rawSegments where list.contains(where: { $0.id == id }) {
            rawSegments[index] = list.filter { $0.id != id }
        }
        for (index, list) in segments where list.contains(where: { $0.id == id }) {
            segments[index] = list.filter { $0.id != id }
        }
        localItems.removeAll { $0.id == id }
        removeSprites { $0.item.id == id }
        removeSpecials { $0.item.id == id }
    }

    /// 「弹幕列表」: what is on screen plus every danmaku (as filtered for display, own ones included) that
    /// appeared in the `window` seconds before `time`, newest first. Code / BAS danmaku are left out.
    func recentItems(before time: Double, window: Double) -> [DanmakuItem] {
        let t = time.isFinite ? max(0, time) : renderTime
        var out = collect(after: t - max(window, 0), upTo: t + 0.05).filter { $0.kind != .advanced || $0.mode == 7 }
        var seen = Set(out.compactMap { $0.id != 0 ? $0.id : nil })
        for item in visibleItems where item.id == 0 || !seen.contains(item.id) {
            out.append(item)
            if item.id != 0 { seen.insert(item.id) }
        }
        return out.sorted { $0.time > $1.time }
    }

    /// Wakes the renderer immediately after play/pause (otherwise noticed within ~0.2 s).
    func playbackStateDidChange() {
        if let link = displayLink { displayLinkFired(link) }
    }

    // MARK: View lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let scale = max(traitCollection.displayScale, 1)
            if scale != pixelScale { styleDidChange() }
            if displayLink == nil {
                let link = CADisplayLink(target: DanmakuDisplayLinkProxy(owner: self),
                                         selector: #selector(DanmakuDisplayLinkProxy.tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
                linkMode = nil
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
            linkMode = nil
        }
        updateActiveState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        if engine.reconfigure(makeLayoutConfig()) { reflow(at: renderTime) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale { styleDidChange() }
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
        updateActiveState()
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        updateActiveState()
    }

    // MARK: Activity

    private var isRenderingActive: Bool {
        userVisible && settings.enabled && window != nil && !isInBackground && timeProvider != nil
    }

    private func updateActiveState() {
        isHidden = !(userVisible && settings.enabled)
        let active = isRenderingActive
        if active != wasActive {
            wasActive = active
            if active {
                lastRawTime = nil   // the next frame re-flows at the current time
            } else {
                removeAllSprites()
                engine.reset()
            }
        }
        displayLink?.isPaused = !active
    }

    private func setLinkMode(_ mode: LinkMode) {
        guard mode != linkMode, let link = displayLink else { return }
        linkMode = mode
        switch mode {
        case .playing: link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        case .paused: link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
        case .idle: link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8, preferred: 5)
        }
    }

    // MARK: Frame loop

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard isRenderingActive, let provider = timeProvider else { return }
        let state = provider()
        let wall = CACurrentMediaTime()
        var raw = state.time.isFinite ? max(0, state.time) : 0
        let playing = state.isPlaying
        let rate = state.rate > 0 ? Double(state.rate) : 1

        // After an explicit seek the player may still report the old time for a moment.
        if let target = pendingSeekTarget {
            if abs(raw - target) < 1.0 || wall > pendingSeekDeadline {
                pendingSeekTarget = nil
            } else {
                raw = target
            }
        }

        if let last = lastRawTime {
            // The clock stood still while paused: on the first playing frame it can only have
            // advanced by one frame interval, not by the whole pause (that hid seek+play jumps).
            let since = lastFramePlaying ? wall - lastRawWall : wall - lastFrameWall
            let expected = playing ? max(0, since) * rate : 0
            if raw < last - 0.3 || raw > last + expected + 1.0 {
                jump(to: raw, wall: wall)
            }
        } else {
            jump(to: raw, wall: wall)
        }
        lastFrameWall = wall
        lastFramePlaying = playing

        var now: Double
        if raw != lastRawTime {
            lastRawTime = raw
            lastRawWall = wall
            now = raw
        } else if playing {
            // Coarse or stale clock: extrapolate a little.
            now = raw + min(wall - lastRawWall, 0.5) * rate
        } else {
            now = raw
        }
        if playing, now < renderTime, renderTime - now < 0.3 { now = renderTime }
        renderTime = now

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playing {
            emit(after: lastEmitTime, upTo: now)
            lastEmitTime = max(lastEmitTime, now)
        }
        updateSprites(at: now)
        CATransaction.commit()

        requestSegmentsIfNeeded(force: false)
        setLinkMode(playing ? .playing : (sprites.isEmpty ? .idle : .paused))
    }

    /// Discontinuity (seek, resume from background, first frame): clear and re-flow.
    private func jump(to t: Double, wall: CFTimeInterval) {
        lastRawTime = t
        lastRawWall = wall
        renderTime = t
        prefetchAfterSeek = true
        reflow(at: t)
        requestSegmentsIfNeeded(force: true)
    }

    /// Longest time a danmaku can stay on screen.
    private var maxLifetime: Double {
        let d = min(max(settings.scrollDuration, 1), 50)
        let scrollLife = settings.scrollFixedVelocity ? d * 2.5 : d
        return max(scrollLife, min(max(settings.fixedDuration, 1), 50))
    }

    /// Rebuilds the screen as it should look at `t`: replays the layout of every danmaku that
    /// appeared in the last `maxLifetime` seconds and shows the ones still alive.
    private func reflow(at t: Double) {
        removeAllSprites()
        engine.reset()
        lastEmitTime = t
        guard isRenderingActive, engine.trackCount > 0 else { return }
        var candidates = collect(after: t - maxLifetime, upTo: t)
        // Mode-7 danmaku may live longer than any track item.
        if maxLifetime < DanmakuOverlayView.maxSpecialLifetime {
            let older = collect(after: t - DanmakuOverlayView.maxSpecialLifetime, upTo: t - maxLifetime)
            candidates.insert(contentsOf: older.lazy.filter { $0.kind == .advanced }, at: 0)
        }
        guard !candidates.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in candidates { _ = spawn(item, now: t) }
        updateSprites(at: t)
        CATransaction.commit()
    }

    private func emit(after a: Double, upTo b: Double) {
        guard b > a else { return }
        for item in collect(after: max(a, b - 2), upTo: b) { _ = spawn(item, now: b) }
    }

    /// Filtered danmaku (and own local ones) with `a < time <= b`, sorted by time.
    private func collect(after a: Double, upTo b: Double) -> [DanmakuItem] {
        guard b > a else { return [] }
        var out: [DanmakuItem] = []
        let first = DanmakuSegment.index(for: max(0, a))
        let last = DanmakuSegment.index(for: b)
        if last >= first {
            for s in first...last {
                if let list = segments[s] { DanmakuOverlayView.append(from: list, after: a, upTo: b, into: &out) }
            }
        }
        if !localItems.isEmpty {
            let before = out.count
            DanmakuOverlayView.append(from: localItems, after: a, upTo: b, into: &out)
            if out.count != before { out.sort { $0.time < $1.time } }
        }
        return out
    }

    private static func append(from list: [DanmakuItem], after a: Double, upTo b: Double, into out: inout [DanmakuItem]) {
        var lo = 0
        var hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].time <= a { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < list.count, list[i].time <= b {
            out.append(list[i])
            i += 1
        }
    }

    /// Lays out one danmaku (evaluated at its own time) and shows it if it is still alive at `now`.
    @discardableResult
    private func spawn(_ item: DanmakuItem, now: Double) -> Bool {
        guard item.id == 0 || !activeIDs.contains(item.id) else { return false }
        if item.kind == .advanced { return spawnSpecial(item, now: now) }
        if settings.maxOnScreen > 0, sprites.count >= settings.maxOnScreen, !item.isSelf { return false }
        let kind: DanmakuTrackKind
        switch item.kind {
        case .top: kind = .top
        case .bottom: kind = .bottom
        default: kind = .scroll
        }
        let width = itemWidth(for: item)
        // Checked before `place`: an item whose bitmap cannot be rendered must not reserve a lane.
        guard width > 0, width < DanmakuOverlayView.maxBitmapWidth,
              let placement = engine.place(kind: kind, width: Double(width), at: item.time, isSelf: item.isSelf),
              !placement.isExpired(at: now)
        else { return false }
        guard let bitmap = bitmap(for: item) else { return false }
        let l = dequeueLayer()
        l.contents = bitmap.image
        l.contentsScale = CGFloat(bitmap.image.width) / max(bitmap.size.width, 1)
        l.bounds = CGRect(origin: .zero, size: bitmap.size)
        l.zPosition = baseZPosition(item, kind: placement.kind)
        let sprite = DanmakuSprite(item: item, placement: placement, layer: l, size: bitmap.size)
        position(sprite, at: now)
        sprites.append(sprite)
        if item.id != 0 { activeIDs.insert(item.id) }
        return true
    }

    private func baseZPosition(_ item: DanmakuItem, kind: DanmakuTrackKind) -> CGFloat {
        item.isSelf ? 2 : (kind == .scroll ? 0 : 1)
    }

    /// Mode 7 (「高级弹幕」): a positioned bitmap animated by its spec. Modes 8 / 9 are never shown.
    private func spawnSpecial(_ item: DanmakuItem, now: Double) -> Bool {
        guard item.mode == 7, let spec = advancedSpec(for: item), bounds.width > 0, bounds.height > 0 else { return false }
        let elapsed = now - item.time
        guard elapsed > -0.5, elapsed < spec.duration, let bitmap = specialBitmap(for: item, spec: spec) else { return false }
        let l = dequeueLayer()
        l.contents = bitmap.image
        l.contentsScale = CGFloat(bitmap.image.width) / max(bitmap.size.width, 1)
        // (x, y) is the text's top-left corner, also the rotation origin.
        l.anchorPoint = .zero
        l.bounds = CGRect(origin: .zero, size: bitmap.size)
        l.zPosition = 0.5
        l.transform = DanmakuOverlayView.specialTransform(spec)
        let sprite = DanmakuSpecialSprite(item: item, spec: spec, layer: l)
        positionSpecial(sprite, at: now)
        specials.append(sprite)
        if item.id != 0 { activeIDs.insert(item.id) }
        return true
    }

    private func advancedSpec(for item: DanmakuItem) -> DanmakuAdvancedSpec? {
        if let cached = specCache[item.content] { return cached }
        let spec = DanmakuAdvancedSpec.parse(item.content)
        if specCache.count > 2000 { specCache.removeAll() }
        specCache[item.content] = .some(spec)
        return spec
    }

    private static func specialTransform(_ spec: DanmakuAdvancedSpec) -> CATransform3D {
        var t = CATransform3DIdentity
        if spec.rotateY != 0 {
            t.m34 = -1 / 600
            t = CATransform3DRotate(t, CGFloat(spec.rotateY * .pi / 180), 0, 1, 0)
        }
        if spec.rotateZ != 0 { t = CATransform3DRotate(t, CGFloat(spec.rotateZ * .pi / 180), 0, 0, 1) }
        return t
    }

    private func updateSprites(at t: Double) {
        if !sprites.isEmpty {
            var expired = false
            for s in sprites where s !== suspended {
                if s.placement.isExpired(at: t) || t < s.placement.startTime - 0.5 {
                    expired = true
                } else {
                    position(s, at: t)
                }
            }
            if expired {
                removeSprites { $0 !== self.suspended && ($0.placement.isExpired(at: t) || t < $0.placement.startTime - 0.5) }
            }
        }
        if !specials.isEmpty {
            var expired = false
            for s in specials {
                let elapsed = t - s.item.time
                if elapsed >= s.spec.duration || elapsed < -0.5 {
                    expired = true
                } else {
                    positionSpecial(s, at: t)
                }
            }
            if expired {
                removeSpecials { t - $0.item.time >= $0.spec.duration || t - $0.item.time < -0.5 }
            }
        }
    }

    private func position(_ s: DanmakuSprite, at t: Double) {
        let scale = pixelScale
        let trackY = CGFloat(engine.config.trackY(s.placement.track))
        let trackH = CGFloat(engine.config.trackHeight)
        let x = CGFloat(s.placement.x(at: t))
        let y = trackY + (trackH - s.size.height) / 2
        let px = ((x + s.size.width / 2) * scale).rounded() / scale
        let py = ((y + s.size.height / 2) * scale).rounded() / scale
        s.layer.position = CGPoint(x: px, y: py)
    }

    private func positionSpecial(_ s: DanmakuSpecialSprite, at t: Double) {
        let elapsed = max(0, t - s.item.time)
        let p = s.spec.position(at: elapsed)
        let scale = pixelScale
        let x = (CGFloat(p.x) * bounds.width * scale).rounded() / scale
        let y = (CGFloat(p.y) * bounds.height * scale).rounded() / scale
        s.layer.position = CGPoint(x: x, y: y)
        s.layer.opacity = Float(s.spec.alpha(at: elapsed))
    }

    // MARK: Sprites & layers

    private func removeSprites(where shouldRemove: (DanmakuSprite) -> Bool) {
        guard !sprites.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var kept: [DanmakuSprite] = []
        kept.reserveCapacity(sprites.count)
        var lostSuspended = false
        for s in sprites {
            if shouldRemove(s) {
                recycle(s.layer)
                activeIDs.remove(s.item.id)
                if s === suspended {
                    suspended = nil
                    lostSuspended = true
                }
            } else {
                kept.append(s)
            }
        }
        sprites = kept
        CATransaction.commit()
        if lostSuspended { onSuspendedLost?() }
    }

    private func removeSpecials(where shouldRemove: (DanmakuSpecialSprite) -> Bool) {
        guard !specials.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var kept: [DanmakuSpecialSprite] = []
        for s in specials {
            if shouldRemove(s) {
                recycle(s.layer)
                activeIDs.remove(s.item.id)
            } else {
                kept.append(s)
            }
        }
        specials = kept
        CATransaction.commit()
    }

    private func removeAllSprites() {
        removeSprites { _ in true }
        removeSpecials { _ in true }
        activeIDs.removeAll()
    }

    private func dequeueLayer() -> CALayer {
        if let l = layerPool.popLast() {
            l.isHidden = false
            // A mode-7 sprite may have used it.
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.transform = CATransform3DIdentity
            l.opacity = 1
            return l
        }
        let l = CALayer()
        l.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "zPosition": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
            "anchorPoint": NSNull(), "transform": NSNull(),
        ]
        l.contentsGravity = .resize
        l.isOpaque = false
        layer.addSublayer(l)
        return l
    }

    private func recycle(_ l: CALayer) {
        l.contents = nil
        l.isHidden = true
        if layerPool.count < 256 {
            layerPool.append(l)
        } else {
            l.removeFromSuperlayer()
        }
    }

    // MARK: Segments

    private func requestSegmentsIfNeeded(force: Bool) {
        guard let loader, isRenderingActive else { return }
        let wall = CACurrentMediaTime()
        if !force, wall - lastSegmentCheckWall < 0.5 { return }
        lastSegmentCheckWall = wall
        let needed = loader.segmentsToLoad(time: renderTime, afterSeek: prefetchAfterSeek)
        prefetchAfterSeek = false
        let gen = generation
        for index in needed where segments[index] == nil && !requestedSegments.contains(index) {
            if let until = retryAfter[index], wall < until { continue }
            requestedSegments.insert(index)
            Task { [weak self] in
                let items = await loader.load(segment: index)
                let closed = await loader.isClosed
                self?.didLoad(segment: index, items: items, closed: closed, generation: gen)
            }
        }
    }

    private func didLoad(segment index: Int, items: [DanmakuItem]?, closed: Bool, generation gen: Int) {
        guard gen == generation else { return }
        requestedSegments.remove(index)
        if closed, !closedNotified {
            closedNotified = true
            isClosedByUploader = true
            if let callback = onClosedByUploader {
                callback()
            } else {
                ToastCenter.shared.show("UP主已关闭弹幕")
            }
        }
        guard let items else {
            retryAfter[index] = CACurrentMediaTime() + 5
            return
        }
        retryAfter[index] = nil
        rawSegments[index] = items
        segments[index] = filter.apply(items)
        // Danmaku of this segment that should already be on screen: re-flow.
        let range = DanmakuSegment.range(of: index)
        if range.lowerBound <= lastEmitTime, range.upperBound > lastEmitTime - maxLifetime {
            reflow(at: renderTime)
        }
    }

    // MARK: Text rendering

    private func styleDidChange() {
        pixelScale = max(traitCollection.displayScale, 1)
        rebuildFonts()
        bitmapCache.removeAllObjects()
        widthCache.removeAll()
        engine.reconfigure(makeLayoutConfig())
        reflow(at: renderTime)
    }

    private var fontSize: CGFloat { CGFloat(settings.resolvedFontSize(fullscreen: isFullscreen)) }

    private var strokeWidth: CGFloat { CGFloat(min(max(settings.strokeWidth, 0), 5)) }

    private func rebuildFonts() {
        let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let w = weights[min(max(settings.fontWeight, 0), weights.count - 1)]
        mainFont = UIFont.systemFont(ofSize: fontSize, weight: w)
        countFont = UIFont.systemFont(ofSize: max(8, fontSize * 0.75), weight: w)
    }

    private func makeLayoutConfig() -> DanmakuLayoutConfig {
        var c = DanmakuLayoutConfig()
        c.viewWidth = Double(bounds.width)
        c.viewHeight = Double(bounds.height)
        c.areaFraction = settings.area.rawValue
        c.trackHeight = max(1, Double(fontSize) * min(max(settings.lineHeight, 1), 3))
        c.topInset = Double(DanmakuOverlayView.topInset)
        c.scrollDuration = min(max(settings.scrollDuration, 1), 50)
        c.staticDuration = min(max(settings.fixedDuration, 1), 50)
        c.fixedVelocity = settings.scrollFixedVelocity
        c.allowOverlap = settings.allowOverlap
        c.static2Scroll = settings.static2Scroll && !settings.hideScroll
        c.minGap = DanmakuOverlayView.scrollGap
        return c
    }

    private static let maxContentLength = 150
    /// Widest bitmap rendered (points); wider items are dropped before they take a lane.
    private static let maxBitmapWidth: CGFloat = 6000
    private static let bitmapCacheBytes = 24 * 1024 * 1024
    /// Largest mode-7 bitmap in pixels (16 MB).
    private static let maxSpecialPixels: CGFloat = 4_000_000

    private func shownContent(_ item: DanmakuItem) -> String {
        let flat = item.content.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.count > DanmakuOverlayView.maxContentLength
            ? String(flat.prefix(DanmakuOverlayView.maxContentLength)) + "…" : flat
    }

    private func cacheKey(_ item: DanmakuItem) -> String {
        let vip = settings.showVipColorful && item.isVipGradient
        return "\(item.isSelf ? 1 : 0)\(vip ? 1 : 0)|\(item.color)|\(item.count)|\(item.content)"
    }

    private func attributedText(_ item: DanmakuItem, attributes: (UIFont) -> [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: shownContent(item), attributes: attributes(mainFont))
        if item.count > 1 {
            s.append(NSAttributedString(string: " ×\(item.count)", attributes: attributes(countFont)))
        }
        return s
    }

    private func itemSize(textSize: CGSize, isSelf: Bool) -> CGSize {
        let extra: CGFloat = isSelf ? 4 : 0
        return CGSize(width: ceil(textSize.width + strokeWidth + extra), height: ceil(textSize.height + strokeWidth))
    }

    private func itemWidth(for item: DanmakuItem) -> CGFloat {
        let key = cacheKey(item)
        if let b = bitmapCache.object(forKey: key as NSString) { return b.size.width }
        if let w = widthCache[key] { return w }
        let text = attributedText(item) { [.font: $0] }
        let w = itemSize(textSize: text.size(), isSelf: item.isSelf).width
        if widthCache.count > 4000 { widthCache.removeAll() }
        widthCache[key] = w
        return w
    }

    private static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private static func isDark(_ rgb: UInt32) -> Bool {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 50
    }

    private static let selfBorderColor = UIColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1)
    private static let vipGradientColors: [CGColor] = [
        UIColor(red: 0xF2 / 255.0, green: 0x50 / 255.0, blue: 0x9E / 255.0, alpha: 1).cgColor,
        UIColor(red: 0x30 / 255.0, green: 0x8B / 255.0, blue: 0xCD / 255.0, alpha: 1).cgColor,
    ]

    /// Renders (or returns the cached) bitmap: outline pass, optional VIP gradient on the outline,
    /// fill pass, and a green border for own danmaku.
    private func bitmap(for item: DanmakuItem) -> DanmakuTextBitmap? {
        let key = cacheKey(item) as NSString
        if let cached = bitmapCache.object(forKey: key) { return cached }

        let fill = DanmakuOverlayView.color(item.color)
        let strokeColor: UIColor = DanmakuOverlayView.isDark(item.color)
            ? UIColor(white: 1, alpha: 0.85) : UIColor(white: 0, alpha: 0.9)
        let stroke = strokeWidth
        let fillText = attributedText(item) { [.font: $0, .foregroundColor: fill] }
        let size = itemSize(textSize: fillText.size(), isSelf: item.isSelf)
        guard size.width >= 1, size.height >= 1, size.width < DanmakuOverlayView.maxBitmapWidth else { return nil }
        let vip = settings.showVipColorful && item.isVipGradient

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(traitCollection.displayScale, 1)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let origin = CGPoint(x: stroke / 2 + (item.isSelf ? 2 : 0), y: stroke / 2)
            if stroke > 0 {
                cg.setLineJoin(.round)
                let strokeText = attributedText(item) { font in
                    [.font: font, .foregroundColor: strokeColor, .strokeColor: strokeColor,
                     .strokeWidth: NSNumber(value: Double(stroke / max(font.pointSize, 1) * 100))]
                }
                strokeText.draw(at: origin)
                if vip, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                  colors: DanmakuOverlayView.vipGradientColors as CFArray,
                                                  locations: [0, 1]) {
                    cg.saveGState()
                    cg.setBlendMode(.sourceIn)
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                          options: [])
                    cg.restoreGState()
                }
            }
            fillText.draw(at: origin)
            if item.isSelf {
                cg.setStrokeColor(DanmakuOverlayView.selfBorderColor.cgColor)
                cg.setLineWidth(1)
                cg.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        let bitmap = DanmakuTextBitmap(image: cgImage, size: size)
        bitmapCache.setObject(bitmap, forKey: key, cost: cgImage.width * cgImage.height * 4)
        return bitmap
    }

    /// Mode-7 bitmap: multi-line text, the item's size scaled from the 682 × 438 reference player to this view, an
    /// outline only when the spec asks for one. The user's font settings do not apply (the layout is the author's).
    private func specialBitmap(for item: DanmakuItem, spec: DanmakuAdvancedSpec) -> DanmakuTextBitmap? {
        let scale = min(bounds.width / CGFloat(DanmakuAdvancedSpec.referenceWidth),
                        bounds.height / CGFloat(DanmakuAdvancedSpec.referenceHeight))
        let pointSize = min(max(CGFloat(min(max(item.fontSize, 12), 64)) * scale, 6), 96)
        let stroke: CGFloat = spec.hasStroke ? max(1, strokeWidth) : 0
        let key = "adv|\(Int((pointSize * 2).rounded()))|\(stroke)|\(item.color)|\(spec.text)" as NSString
        if let cached = bitmapCache.object(forKey: key) { return cached }

        let font = UIFont.systemFont(ofSize: pointSize, weight: .medium)
        let fill = DanmakuOverlayView.color(item.color)
        let strokeColor: UIColor = DanmakuOverlayView.isDark(item.color)
            ? UIColor(white: 1, alpha: 0.85) : UIColor(white: 0, alpha: 0.9)
        let fillText = NSAttributedString(string: spec.text, attributes: [.font: font, .foregroundColor: fill])
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin]
        let textRect = fillText.boundingRect(with: CGSize(width: DanmakuOverlayView.maxBitmapWidth, height: 2000),
                                             options: options, context: nil)
        let size = CGSize(width: ceil(textRect.width + stroke), height: ceil(textRect.height + stroke))
        guard size.width >= 1, size.height >= 1, size.width < DanmakuOverlayView.maxBitmapWidth, size.height < 2000
        else { return nil }

        let format = UIGraphicsImageRendererFormat()
        // Mode-7 text has no length cap: a long multi-line one at 3× would need hundreds of MB, so past
        // `maxSpecialPixels` it is rendered at a lower resolution.
        format.scale = min(max(traitCollection.displayScale, 1),
                           sqrt(DanmakuOverlayView.maxSpecialPixels / (size.width * size.height)))
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let rect = CGRect(x: stroke / 2, y: stroke / 2, width: textRect.width, height: textRect.height)
            if stroke > 0 {
                ctx.cgContext.setLineJoin(.round)
                let strokeText = NSAttributedString(string: spec.text, attributes: [
                    .font: font, .foregroundColor: strokeColor, .strokeColor: strokeColor,
                    .strokeWidth: NSNumber(value: Double(stroke / max(font.pointSize, 1) * 100)),
                ])
                strokeText.draw(with: rect, options: options, context: nil)
            }
            fillText.draw(with: rect, options: options, context: nil)
        }
        guard let cgImage = image.cgImage else { return nil }
        let bitmap = DanmakuTextBitmap(image: cgImage, size: size)
        bitmapCache.setObject(bitmap, forKey: key, cost: cgImage.width * cgImage.height * 4)
        return bitmap
    }
}
