import Foundation

// Port of Bilibili-thread-ripper `createAutoConcurrency` (idm-downloader.js, MIT, 2026.10.7.1+) — 自动线程数
// (BTR spec §8), with lemon's `cacheFull` ending the startup boost and a device cap on the ladder.
//
// The thread count climbs a ladder (8 → 64) on every sign that the download does not keep up with playback
// (a stall; a low buffer that stops growing while bytes arrive; a connection waiting too long for its first byte
// while every slot is busy). Every step up is a trial: 10 s later the throughput must have grown, otherwise it goes
// back and that level rests 90 s. HTTP 412/429 steps back and caps everything above for 180 s. Each start opens with
// at least 16 threads and steps back down once ≥ 15 s are buffered (or the player's cache is full).

final class AutoConcurrencyController: AutoConcurrencySignals, @unchecked Sendable {
    static let shared = AutoConcurrencyController()

    static let defaultLadder = [8, 12, 16, 24, 32, 48, 64]
    static let startupLevel = 2
    static let startupComfortSeconds = 15.0
    static let startupMaxMs = 30_000.0
    static let stepCooldownMs = 2500.0
    static let trialMs = 10_000.0
    static let windowMs = 5000.0
    static let bucketMs = 250.0
    static let restMs = 90_000.0
    static let pushbackRestMs = 180_000.0
    static let lowBufferSeconds = 6.0
    static let pressureMs = 1000.0
    static let activityMs = 1500.0

    struct Change: Equatable {
        var threads: Int
        var previous: Int
        var reason: String
    }

    struct Rest: Equatable {
        var threads: Int
        var hard: Bool
        var forMs: Double
    }

    struct TrialInfo: Equatable {
        var from: Int
        var threads: Int
        var ageMs: Double
        var baselineBps: Double
        var stalled: Bool
    }

    struct StartupInfo: Equatable {
        var base: Int
        var forMs: Double
    }

    struct Status: Equatable {
        var threads: Int
        var level: Int
        var reason: String
        var steps: Int
        var throughputBps: Double
        var saturation: Double
        var buckets: Int
        var resting: [Rest]
        var trial: TrialInfo?
        var startup: StartupInfo?
    }

    private struct Trial {
        var from: Int
        var level: Int
        var at: Double
        var baseline: Double
        var stalled: Bool
    }

    private struct RestEntry {
        var until: Double
        var hard: Bool
    }

    /// The usable ladder (the default one capped by `maxThreads`).
    let ladder: [Int]
    private let clock: MonotonicClock
    private let lock = NSLock()

    private var level = 0
    private var changedAt: Double = 0
    private var reasonText = "起步"
    private var steps = 0
    private var trial: Trial?
    private var resting: [Int: RestEntry] = [:]
    private var buckets: [(at: Double, bytes: Double)] = []
    private var lastActivityAt = -Double.infinity
    private var saturated = false
    private var saturatedSince: Double = 0
    private var saturatedSpans: [(from: Double, to: Double)] = []
    private var aheadSamples: [(at: Double, ahead: Double)] = []
    private var pressureSince: Double = 0
    private var startup: (base: Int, until: Double)?
    /// Highest usable level index (device cap, see `setThreadCap`).
    private var topLevel: Int
    private var listeners: [Int: (Change) -> Void] = [:]
    private var nextListenerID = 0
    private var pending: [Change] = []

    init(clock: MonotonicClock = SystemClock.shared, ladder: [Int] = AutoConcurrencyController.defaultLadder,
         maxThreads: Int = 64) {
        let capped = ladder.filter { $0 > 0 && $0 <= maxThreads }
        self.ladder = capped.isEmpty ? [max(1, min(maxThreads, ladder.first ?? 8))] : capped
        self.clock = clock
        topLevel = self.ladder.count - 1
    }

    // MARK: Reading

    var threads: Int {
        lock.lock()
        defer { lock.unlock() }
        return ladder[level]
    }

    /// The reason of the last change ("播放卡了一下", "缓冲跟不上播放", …).
    var reason: String {
        lock.lock()
        defer { lock.unlock() }
        return reasonText
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        let at = clock.nowMs()
        let rests = resting.keys.sorted().compactMap { lvl -> Rest? in
            guard let r = resting[lvl], r.until > at else { return nil }
            return Rest(threads: ladder[lvl], hard: r.hard, forMs: (r.until - at).rounded())
        }
        let t = trial.map {
            TrialInfo(from: ladder[$0.from], threads: ladder[$0.level], ageMs: (at - $0.at).rounded(),
                      baselineBps: $0.baseline.rounded(), stalled: $0.stalled)
        }
        let s = startup.map { StartupInfo(base: ladder[$0.base], forMs: ($0.until - at).rounded()) }
        return Status(threads: ladder[level], level: level, reason: reasonText, steps: steps,
                      throughputBps: throughputLocked(at).rounded(), saturation: (saturationLocked(at) * 100).rounded() / 100,
                      buckets: buckets.count, resting: rests, trial: t, startup: s)
    }

    /// `listener` is called (outside the controller's lock) whenever the thread count changes. Returns an
    /// unsubscribe closure.
    @discardableResult
    func subscribe(_ listener: @escaping (Change) -> Void) -> () -> Void {
        lock.lock()
        let id = nextListenerID
        nextListenerID += 1
        listeners[id] = listener
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners[id] = nil
            self.lock.unlock()
        }
    }

    // MARK: Signals (AutoConcurrencySignals)

    func newSession() { startSession() }

    func stall() { _ = signalStall() }

    func buffer(ahead: Double, playing: Bool, cacheFull: Bool) {
        _ = signalBuffer(ahead: ahead, playing: playing, cacheFull: cacheFull)
    }

    // MARK: Signals (testable forms)

    /// The player stalled: more threads at once (a strong signal: may skip a level resting after a fruitless trial).
    @discardableResult
    func signalStall(_ reason: String = "播放卡了一下") -> Bool {
        run {
            if trial != nil { trial?.stalled = true }
            return stepUpLocked(reason, strong: true)
        }
    }

    /// Buffer ahead of the playhead, a few times a second while an item is active.
    @discardableResult
    func signalBuffer(ahead: Double, playing: Bool, cacheFull: Bool = false) -> Bool {
        run {
            let at = clock.nowMs()
            aheadSamples.append((at, ahead))
            while let first = aheadSamples.first, at - first.at > Self.pressureMs + Self.bucketMs { aheadSamples.removeFirst() }
            // The start: once well ahead, one step back down per cooldown towards the level before the start.
            if let start = startup, at >= start.until {
                startup = nil
            } else if let start = startup, ahead >= Self.startupComfortSeconds || cacheFull,
                      at - changedAt >= Self.stepCooldownMs {
                if level > start.base {
                    setLevelLocked(level - 1, "开头已经跟上，线程数降到 \(ladder[level - 1])", trial: nil)
                }
                if level <= start.base { startup = nil }
            }
            let earlier = aheadSamples.first { at - $0.at >= Self.pressureMs }
            let downloading = at - lastActivityAt < Self.activityMs
            let pressed: Bool
            if let earlier {
                pressed = playing && downloading && ahead < Self.lowBufferSeconds && ahead <= earlier.ahead + 0.05
            } else {
                pressed = false
            }
            if !pressed {
                pressureSince = 0
                return false
            }
            if pressureSince == 0 {
                pressureSince = at
                return false
            }
            if at - pressureSince < Self.pressureMs { return false }
            pressureSince = 0
            return stepUpLocked("缓冲跟不上播放", strong: false)
        }
    }

    /// A new item, or a seek outside the buffered ranges: the start runs with ≥ 16 threads.
    func startSession() {
        run {
            let at = clock.nowMs()
            aheadSamples.removeAll()
            pressureSince = 0
            trial = nil
            buckets.removeAll()
            saturatedSpans.removeAll()
            if saturated { saturatedSince = at }
            let base = startup?.base ?? level
            let target = startupLevelLocked(at)
            if target > level { setLevelLocked(target, "开头先用 \(ladder[target]) 线程", trial: nil) }
            startup = level > base ? (base, at + Self.startupMaxMs) : nil
            return ()
        }
    }

    /// A piece arrived whole (winner only; a hedge loser is not delivery).
    func delivered(_ bytes: Int) {
        run {
            let at = clock.nowMs()
            if let last = buckets.last, at - last.at < Self.bucketMs {
                buckets[buckets.count - 1].bytes += Double(bytes)
            } else {
                buckets.append((at, Double(bytes)))
            }
            pruneBucketsLocked(at)
            judgeTrialLocked(at)
            return ()
        }
    }

    /// Bytes are flowing on some connection right now (each body chunk).
    func activity() {
        lock.lock()
        lastActivityAt = clock.nowMs()
        lock.unlock()
    }

    /// The connection pool's state whenever it changes.
    func demand(active: Int, limit: Int, queued: Int) {
        lock.lock()
        let at = clock.nowMs()
        let sat = active >= limit && queued > 0
        if sat != saturated {
            if saturated { saturatedSpans.append((saturatedSince, at)) }
            saturated = sat
            saturatedSince = at
            _ = saturationLocked(at)
        }
        lock.unlock()
    }

    /// An attempt timed out with 0 bytes: a climb only while the connections are saturated.
    @discardableResult
    func slow() -> Bool {
        run {
            saturationLocked(clock.nowMs()) >= 0.6 ? stepUpLocked("连接排队等太久", strong: false) : false
        }
    }

    /// HTTP 412 / 429: back one level, and nothing climbs past this level for 180 s.
    @discardableResult
    func pushback(status: Int) -> Bool {
        run {
            stepDownLocked(max(0, level - 1), restLevel: level, reason: "服务器返回 \(status)",
                           restMs: Self.pushbackRestMs, hard: true)
        }
    }

    /// Device cap (e.g. 32 on iPhone): levels above it are never used; a higher current level steps down at once.
    func setThreadCap(_ maxThreads: Int) {
        run {
            var top = 0
            for (i, t) in ladder.enumerated() where t <= maxThreads { top = i }
            guard top != topLevel else { return () }
            topLevel = top
            if level > top { setLevelLocked(top, "线程上限 \(ladder[top])", trial: nil) }
            if let s = startup, s.base > top { startup = (top, s.until) }
            return ()
        }
    }

    /// Back to the first start (8 threads, nothing learnt).
    func reset() {
        lock.lock()
        level = 0
        changedAt = 0
        reasonText = "起步"
        steps = 0
        trial = nil
        resting.removeAll()
        buckets.removeAll()
        lastActivityAt = -Double.infinity
        saturated = false
        saturatedSince = 0
        saturatedSpans.removeAll()
        aheadSamples.removeAll()
        pressureSince = 0
        startup = nil
        lock.unlock()
    }

    // MARK: Internals (lock held)

    /// Runs `body` under the lock, then notifies listeners of the changes it made (outside the lock).
    private func run<T>(_ body: () -> T) -> T {
        lock.lock()
        let result = body()
        let changes = pending
        pending.removeAll()
        let ls = changes.isEmpty ? [] : Array(listeners.values)
        lock.unlock()
        for change in changes {
            for l in ls { l(change) }
        }
        return result
    }

    private func pruneBucketsLocked(_ at: Double) {
        while let first = buckets.first, at - first.at > Self.windowMs { buckets.removeFirst() }
    }

    /// Bytes per second over the window, from completed pieces only.
    private func throughputLocked(_ at: Double) -> Double {
        pruneBucketsLocked(at)
        guard let first = buckets.first, let last = buckets.last else { return 0 }
        let bytes = buckets.reduce(0) { $0 + $1.bytes }
        return bytes * 1000 / max(1000, last.at - first.at + Self.bucketMs)
    }

    /// Share of the window during which every slot was busy and requests were queued.
    private func saturationLocked(_ at: Double) -> Double {
        let from = at - Self.windowMs
        saturatedSpans.removeAll { $0.to <= from }
        var busy = saturatedSpans.reduce(0) { $0 + max(0, $1.to - max($1.from, from)) }
        if saturated { busy += max(0, at - max(saturatedSince, from)) }
        return min(1, busy / Self.windowMs)
    }

    private func restingLocked(_ lvl: Int, _ at: Double) -> RestEntry? {
        guard let r = resting[lvl] else { return nil }
        if r.until <= at {
            resting[lvl] = nil
            return nil
        }
        return r
    }

    private func setLevelLocked(_ newLevel: Int, _ reason: String, trial newTrial: Trial?) {
        let previous = ladder[level]
        level = newLevel
        changedAt = clock.nowMs()
        reasonText = reason
        steps += 1
        trial = newTrial
        pressureSince = 0
        pending.append(Change(threads: ladder[level], previous: previous, reason: reason))
    }

    /// Up one level. A level resting after a refusal caps the climb; one resting after a fruitless trial is skipped
    /// only by a strong signal (a stall).
    private func stepUpLocked(_ reason: String, strong: Bool) -> Bool {
        let at = clock.nowMs()
        if at - changedAt < Self.stepCooldownMs { return false }
        if restingLocked(level, at)?.hard == true { return false }
        var next = level + 1
        while next <= topLevel {
            guard let rest = restingLocked(next, at) else { break }
            if rest.hard || !strong { return false }
            next += 1
        }
        if next > topLevel { return false }
        setLevelLocked(next, reason, trial: Trial(from: level, level: next, at: at, baseline: throughputLocked(at), stalled: false))
        // Not keeping up even with the start's threads: the start ends at this level.
        startup = nil
        return true
    }

    /// How high a start may go: up to 16 threads, never onto or past a level the server refused.
    private func startupLevelLocked(_ at: Double) -> Int {
        if restingLocked(level, at)?.hard == true { return level }
        var lvl = level
        while lvl < min(Self.startupLevel, topLevel) && restingLocked(lvl + 1, at)?.hard != true { lvl += 1 }
        return lvl
    }

    private func stepDownLocked(_ target: Int, restLevel: Int, reason: String, restMs: Double, hard: Bool) -> Bool {
        resting[restLevel] = RestEntry(until: clock.nowMs() + restMs, hard: hard)
        if target >= level { return false }
        setLevelLocked(target, reason, trial: nil)
        return true
    }

    /// A step up has had its 10 s: without a gain while saturated it goes back to where it started.
    private func judgeTrialLocked(_ at: Double) {
        guard let t = trial, at - t.at >= Self.trialMs else { return }
        trial = nil
        if t.stalled || saturationLocked(at) < 0.6 || t.baseline <= 0 { return }
        if throughputLocked(at) < t.baseline {
            _ = stepDownLocked(t.from, restLevel: t.level, reason: "\(ladder[t.level]) 线程没有比 \(ladder[t.from]) 线程更快",
                               restMs: Self.restMs, hard: false)
        }
    }
}
