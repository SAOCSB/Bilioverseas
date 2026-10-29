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
/// The view never receives touches; use `danmaku(at:)` for tap-on-danmaku hit testing.
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
    var visibleItems: [DanmakuItem] { sprites.map(\.item) }

    var onScreenCount: Int { sprites.count }

    /// Space above the first track.
    static let topInset: CGFloat = 4
    /// Extra spacing kept between consecutive scroll danmaku of a track.
    static let scrollGap: Double = 6

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

    /// Hit test for tap-on-danmaku, in this view's coordinates: static items first, then scroll
    /// items newest first.
    func danmaku(at point: CGPoint) -> DanmakuItem? {
        for s in sprites.reversed() where s.placement.kind != .scroll && s.layer.frame.contains(point) { return s.item }
        for s in sprites.reversed() where s.placement.kind == .scroll && s.layer.frame.contains(point) { return s.item }
        return nil
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
        let candidates = collect(after: t - maxLifetime, upTo: t)
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
        guard item.kind != .advanced, item.id == 0 || !activeIDs.contains(item.id) else { return false }
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
        l.zPosition = item.isSelf ? 2 : (placement.kind == .scroll ? 0 : 1)
        let sprite = DanmakuSprite(item: item, placement: placement, layer: l, size: bitmap.size)
        position(sprite, at: now)
        sprites.append(sprite)
        if item.id != 0 { activeIDs.insert(item.id) }
        return true
    }

    private func updateSprites(at t: Double) {
        guard !sprites.isEmpty else { return }
        var expired = false
        for s in sprites {
            if s.placement.isExpired(at: t) || t < s.placement.startTime - 0.5 {
                expired = true
            } else {
                position(s, at: t)
            }
        }
        if expired {
            removeSprites { $0.placement.isExpired(at: t) || t < $0.placement.startTime - 0.5 }
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

    // MARK: Sprites & layers

    private func removeSprites(where shouldRemove: (DanmakuSprite) -> Bool) {
        guard !sprites.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var kept: [DanmakuSprite] = []
        kept.reserveCapacity(sprites.count)
        for s in sprites {
            if shouldRemove(s) {
                recycle(s.layer)
                activeIDs.remove(s.item.id)
            } else {
                kept.append(s)
            }
        }
        sprites = kept
        CATransaction.commit()
    }

    private func removeAllSprites() {
        removeSprites { _ in true }
        activeIDs.removeAll()
    }

    private func dequeueLayer() -> CALayer {
        if let l = layerPool.popLast() {
            l.isHidden = false
            return l
        }
        let l = CALayer()
        l.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "zPosition": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
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
}
