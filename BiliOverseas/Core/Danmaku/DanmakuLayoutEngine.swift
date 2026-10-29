import Foundation

/// Where a danmaku lives on screen.
enum DanmakuTrackKind: Equatable, Sendable {
    case scroll, top, bottom
}

/// Geometry and behaviour inputs for `DanmakuLayoutEngine`. All lengths in points, times in
/// video seconds.
struct DanmakuLayoutConfig: Equatable, Sendable {
    var viewWidth: Double = 0
    /// Height of the whole danmaku layer (the player).
    var viewHeight: Double = 0
    /// Fraction of the (inset) layer height used by tracks, 0.1 … 1.0.
    var areaFraction: Double = 0.5
    /// Track height (≈ font size × line height).
    var trackHeight: Double = 24
    /// Space above the first track.
    var topInset: Double = 4
    /// Seconds a scroll danmaku needs to cross the view (variable speed: travel `W + w`).
    var scrollDuration: Double = 7
    /// Seconds a top/bottom danmaku stays.
    var staticDuration: Double = 4
    /// 「滚动弹幕固定速度」: every scroll item moves at `W / scrollDuration`.
    var fixedVelocity: Bool = false
    /// 「海量弹幕」: overlap on the least-recently-used track instead of dropping.
    var allowOverlap: Bool = false
    /// 「固定转滚动」: unplaceable or too-wide static items become scroll items.
    var static2Scroll: Bool = false
    /// Extra horizontal spacing kept between consecutive scroll items in a track.
    var minGap: Double = 0

    /// `floor(H × area / h)`; one less at 100 % to leave room for subtitles; at least one when a
    /// track fits at all.
    var trackCount: Int {
        guard trackHeight > 0, viewHeight.isFinite, viewHeight > 0 else { return 0 }
        let usable = max(0, viewHeight - topInset)
        let area = min(max(areaFraction, 0), 1)
        var n = Int((usable * area / trackHeight + 1e-9).rounded(.down))
        if area >= 0.999 { n -= 1 }
        if n < 1 { n = usable >= trackHeight ? 1 : 0 }
        return n
    }

    /// Top y of a track.
    func trackY(_ track: Int) -> Double { topInset + Double(track) * trackHeight }

    /// Horizontal speed in points per second of a scroll item of `width`.
    func scrollVelocity(width: Double) -> Double {
        let d = max(scrollDuration, 0.1)
        return fixedVelocity ? viewWidth / d : (viewWidth + width) / d
    }
}

/// One placement decision.
struct DanmakuPlacement: Equatable, Sendable {
    let kind: DanmakuTrackKind
    let track: Int
    /// Video time the item enters (its `time`).
    let startTime: Double
    let width: Double
    /// Scroll: x at `startTime` (the view width). Static: the centred x.
    let originX: Double
    /// Points per second (0 for static).
    let velocity: Double
    /// Video time at which the item has fully left / expires.
    let endTime: Double
    /// Placed on top of another item (海量弹幕 or own danmaku without a free track).
    let overlapped: Bool

    /// `x(t) = W − (t − t0) × v`, which for variable speed is `W − (t − t0)/D × (W + w)`.
    func x(at t: Double) -> Double {
        kind == .scroll ? originX - (t - startTime) * velocity : originX
    }

    func isExpired(at t: Double) -> Bool { t >= endTime }
}

/// Deterministic track assignment (no randomness, no clocks): the same sequence of `place` calls
/// always produces the same placements. Positions are pure functions of video time, so the
/// renderer can evaluate them every frame, pausing stops motion and 2× playback moves 2× faster.
struct DanmakuLayoutEngine {
    private(set) var config: DanmakuLayoutConfig
    private(set) var trackCount: Int
    /// Last scroll item per track.
    private var scrollLanes: [DanmakuPlacement?]
    /// Current static item per track (shared by top and bottom, like the reference renderer).
    private var staticLanes: [DanmakuPlacement?]
    /// Monotonic placement counter per scroll track, for least-recently-used selection.
    private var scrollLastUse: [Int]
    private var useCounter = 0

    init(config: DanmakuLayoutConfig) {
        self.config = config
        trackCount = config.trackCount
        scrollLanes = Array(repeating: nil, count: trackCount)
        staticLanes = Array(repeating: nil, count: trackCount)
        scrollLastUse = Array(repeating: -1, count: trackCount)
    }

    /// Applies a new configuration. Returns true when the geometry changed (track count, track
    /// height, inset or width): lanes are reset and the caller should re-flow what is on screen.
    @discardableResult
    mutating func reconfigure(_ newConfig: DanmakuLayoutConfig) -> Bool {
        let geometryChanged = newConfig.trackCount != trackCount
            || newConfig.viewWidth != config.viewWidth
            || newConfig.trackHeight != config.trackHeight
            || newConfig.topInset != config.topInset
        config = newConfig
        if geometryChanged {
            trackCount = newConfig.trackCount
            reset()
        }
        return geometryChanged
    }

    /// Forgets every placement (seek / clear).
    mutating func reset() {
        scrollLanes = Array(repeating: nil, count: trackCount)
        staticLanes = Array(repeating: nil, count: trackCount)
        scrollLastUse = Array(repeating: -1, count: trackCount)
        useCounter = 0
    }

    /// Frees the lanes of one kind (e.g. when the user hides that type).
    mutating func clear(kind: DanmakuTrackKind) {
        switch kind {
        case .scroll:
            scrollLanes = Array(repeating: nil, count: trackCount)
        case .top, .bottom:
            for i in staticLanes.indices where staticLanes[i]?.kind == kind { staticLanes[i] = nil }
        }
    }

    /// Decides the track for an item of `width` that appears at video time `t`.
    /// Returns nil when it must be dropped.
    mutating func place(kind: DanmakuTrackKind, width: Double, at t: Double, isSelf: Bool = false) -> DanmakuPlacement? {
        guard trackCount > 0, config.viewWidth > 0, width.isFinite, t.isFinite else { return nil }
        switch kind {
        case .scroll:
            return placeScroll(width: width, at: t, isSelf: isSelf)
        case .top, .bottom:
            if config.static2Scroll, width > config.viewWidth {
                return placeScroll(width: width, at: t, isSelf: isSelf)
            }
            if let p = placeStatic(kind: kind, width: width, at: t, isSelf: false) { return p }
            if config.static2Scroll, let p = placeScroll(width: width, at: t, isSelf: isSelf) { return p }
            return isSelf ? placeStatic(kind: kind, width: width, at: t, isSelf: true) : nil
        }
    }

    // MARK: Scroll

    private mutating func placeScroll(width: Double, at t: Double, isSelf: Bool) -> DanmakuPlacement? {
        let v = config.scrollVelocity(width: width)
        guard v > 0 else { return nil }
        for i in 0..<trackCount {
            if DanmakuLayoutEngine.canFollow(scrollLanes[i], newWidth: width, newVelocity: v, at: t,
                                             viewWidth: config.viewWidth, gap: config.minGap) {
                return commitScroll(track: i, width: width, velocity: v, at: t, overlapped: false)
            }
        }
        if isSelf {
            return commitScroll(track: 0, width: width, velocity: v, at: t, overlapped: true)
        }
        if config.allowOverlap {
            var best = 0
            for i in 1..<max(trackCount, 1) where scrollLastUse[i] < scrollLastUse[best] { best = i }
            return commitScroll(track: best, width: width, velocity: v, at: t, overlapped: true)
        }
        return nil
    }

    private mutating func commitScroll(track: Int, width: Double, velocity: Double, at t: Double,
                                       overlapped: Bool) -> DanmakuPlacement {
        let w = config.viewWidth
        let p = DanmakuPlacement(kind: .scroll, track: track, startTime: t, width: width, originX: w,
                                 velocity: velocity, endTime: t + (w + width) / velocity, overlapped: overlapped)
        scrollLanes[track] = p
        scrollLastUse[track] = useCounter
        useCounter += 1
        return p
    }

    /// The catch-up rule against the track's last item `last` (evaluated at time `t`):
    /// (a) `last` has fully entered: `x + w + gap ≤ W`;
    /// (b) if the new item is faster, it must not reach `last`'s tail before that tail leaves the
    ///     screen: `(W − gap) × v_last ≥ (x + w) × v_new` — with variable speed and no gap this is
    ///     the reference `(x + w) × w_new ≤ W × (W − x)`.
    static func canFollow(_ last: DanmakuPlacement?, newWidth: Double, newVelocity: Double, at t: Double,
                          viewWidth W: Double, gap: Double = 0) -> Bool {
        guard let last, !last.isExpired(at: t) else { return true }
        let tail = last.x(at: t) + last.width
        if tail <= 0 { return true }
        if tail + gap > W { return false }
        if newVelocity > last.velocity {
            if (W - gap) * last.velocity < tail * newVelocity { return false }
        }
        return true
    }

    // MARK: Static

    private mutating func placeStatic(kind: DanmakuTrackKind, width: Double, at t: Double,
                                      isSelf: Bool) -> DanmakuPlacement? {
        let order: [Int] = kind == .bottom ? Array((0..<trackCount).reversed()) : Array(0..<trackCount)
        var chosen: Int?
        for i in order {
            if let cur = staticLanes[i], !cur.isExpired(at: t) { continue }
            chosen = i
            break
        }
        let overlapped = chosen == nil
        if chosen == nil {
            guard isSelf, let first = order.first else { return nil }
            chosen = first
        }
        guard let track = chosen else { return nil }
        let p = DanmakuPlacement(kind: kind, track: track, startTime: t, width: width,
                                 originX: (config.viewWidth - width) / 2, velocity: 0,
                                 endTime: t + max(config.staticDuration, 0.1), overlapped: overlapped)
        staticLanes[track] = p
        return p
    }
}
