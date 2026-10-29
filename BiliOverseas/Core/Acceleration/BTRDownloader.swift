import Foundation

// Port of Bilibili-thread-ripper `src/idm-downloader.js` `createDownloader` (MIT; BTR spec §7) with the native-proxy
// lessons of the lemon PiliPlus port (proxy-ports §3): one session-wide slot pool with normal / rescue lanes,
// partial pieces streamed in order from the replica with the most verified bytes, a 256 KiB audio piece floor, and
// the "first byte still pending" hedge rule.
//
// Shape of one `download`:
//   range ─┬─ .meta     → whole-range race over ≤ 3 startup candidates (0 / 120 / 300 ms), priority 220
//          ├─ .startup  → 64 KiB head probe raced over ≤ 8 URLs, then pieces on proven nodes
//          └─ .ordinary → speed-weighted pieces (SWRR) with deadline-aware hedging
//   piece  → ≤ 3 rounds × pairs (first copy + one hedge copy) over ≤ 8 candidates, resume from verified prefix
//   attempt→ slot → GET Range → 206 + exact Content-Range + consistent total + exact length, timers 5.5 / 4 / 15 s
//
// Every byte handed to `onBytes` comes from a 206 whose Content-Range matched the request exactly and whose total
// equals the track's total; bytes go out strictly in file order, never past the range.

/// Timing knobs (spec defaults). Tests shrink them; the app uses `.standard`.
struct BTRTuning {
    var firstByteTimeoutMs = BTRConstants.firstByteTimeoutMs
    var stallTimeoutMs = BTRConstants.stallTimeoutMs
    var attemptTimeoutMs = BTRConstants.attemptTimeoutMs
    /// Maximum / unmeasured hedge delay.
    var hedgeDelayMs = BTRConstants.hedgeDelayMs
    var roundPauseBaseMs: Double = 500
    var pieceRetryWindowMs = BTRConstants.pieceRetryWindowMs
    var hedgePollMs = BTRConstants.hedgePollMs
    var metaStaggerMs = BTRConstants.metaStaggerMs
    /// Without a deadline BTR hedges after a fixed delay. `true` uses lemon's pace-aware `hedgeDue` (no deadline
    /// term) instead, which lemon measured to save ~30 % duplicate traffic on slow overseas links.
    var pacedHedgeWithoutDeadline = false

    static let standard = BTRTuning()
}

// MARK: - Shared measurement

/// What one connection typically delivers (connectionBps), how long a piece takes (pieceMs) and how long response
/// headers take (headMs). EWMA 0.7 / 0.3; only transfers ≥ 48 KiB count for speed.
final class BTRMeter: @unchecked Sendable {
    struct Values {
        var connectionBps: Double = 0
        var pieceMs: Double = 0
        var headMs: Double = 0
    }

    private let lock = NSLock()
    private var v = Values()

    var values: Values {
        lock.lock()
        defer { lock.unlock() }
        return v
    }

    func record(bytes: Int, elapsedMs: Double) {
        guard bytes >= BTRConstants.speedSampleMinBytes, elapsedMs > 0 else { return }
        let bps = Double(bytes) * 1000 / elapsedMs
        lock.lock()
        v.connectionBps = v.connectionBps > 0 ? v.connectionBps * 0.7 + bps * 0.3 : bps
        v.pieceMs = v.pieceMs > 0 ? v.pieceMs * 0.7 + elapsedMs * 0.3 : elapsedMs
        lock.unlock()
    }

    func recordHead(ms: Double) {
        guard ms >= 0 else { return }
        lock.lock()
        v.headMs = v.headMs > 0 ? v.headMs * 0.7 + ms * 0.3 : ms
        lock.unlock()
    }

    /// `clamp(1.5 × pieceMs, 250, maxMs)`, `maxMs` (900) until measured.
    func hedgeDelayMs(maxMs: Double) -> Double {
        let p = values.pieceMs
        return p > 0 ? max(250, min(maxMs, (p * 1.5).rounded())) : maxMs
    }

    /// ~0.6 s of one connection, 64 KiB … 1 MiB, and still ≥ min(max(4, hosts), limit) pieces per range.
    func adaptiveMinChunk(rangeLength: Int64, pieceLimit: Int, hostCount: Int) -> Int {
        let bps = values.connectionBps
        guard bps > 0 else { return BTRConstants.minChunkBytes }
        let unit = Double(64 * 1024)
        let target = Int((bps * 0.6 / unit).rounded(.down) * unit)
        let divisor = Int64(max(1, min(max(4, hostCount), pieceLimit)))
        let spread = Int((rangeLength + divisor - 1) / divisor)
        return max(BTRConstants.minChunkBytes, min(BTRConstants.maxChunkBytes, target, spread))
    }
}

/// Body bytes received, for `BTRStats`.
final class BTRTrafficMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [(at: Double, bytes: Int)] = []
    private var total: Int64 = 0
    private var hedged: Int64 = 0
    static let windowMs: Double = 2000

    func record(_ bytes: Int, hedge: Bool, at: Double) {
        lock.lock()
        total += Int64(bytes)
        if hedge { hedged += Int64(bytes) }
        if let last = buckets.last, at - last.at < 250 {
            buckets[buckets.count - 1].bytes += bytes
        } else {
            buckets.append((at, bytes))
        }
        while let first = buckets.first, at - first.at > Self.windowMs { buckets.removeFirst() }
        lock.unlock()
    }

    func snapshot(at: Double) -> (bps: Double, total: Int64, hedged: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let recent = buckets.filter { at - $0.at <= Self.windowMs }.reduce(0) { $0 + $1.bytes }
        return (Double(recent) * 1000 / Self.windowMs, total, hedged)
    }
}

// MARK: - Track

/// One DASH representation of a session: its URLs (swapped in place on refresh), its file total and its resolver.
final class BTRTrack: BTRTrackHandle, @unchecked Sendable {
    private final class URLBox: @unchecked Sendable {
        let lock = NSLock()
        var urls: [String]
        init(_ urls: [String]) { self.urls = urls }
        func get() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    let kind: MediaKind
    let routeKey: String
    let resolver: BTRResolver
    private let box: URLBox
    private let lock = NSLock()
    private var knownTotal: Int64?

    init(kind: MediaKind, urls: [String], routeKey: String, bans: BTRBanList?, mode: @escaping () -> CDNMode,
         customHosts: @escaping () -> [String], clock: MonotonicClock) {
        self.kind = kind
        self.routeKey = routeKey
        let box = URLBox(urls)
        self.box = box
        resolver = BTRResolver(urls: { box.get() }, mode: mode, customHosts: customHosts, bans: bans, clock: clock)
    }

    var total: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return knownTotal
    }

    /// The playurl URLs as currently known (baseUrl first).
    var urls: [String] { box.get() }

    func updateURLs(_ urls: [String]) {
        box.lock.lock()
        box.urls = urls
        box.lock.unlock()
    }

    func nodeStatus() -> [CDNNodeStatus] { resolver.status() }

    /// Fixes the file total on the first verified response. Returns the conflicting known total on a mismatch.
    func establishTotal(_ total: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        if let known = knownTotal { return known == total ? nil : known }
        knownTotal = total
        return nil
    }

    /// Plain single-connection order: Bilibili's own URLs (allowed ones first); the resolver's list if none is usable.
    func directCandidates() -> [String] {
        let originals = urls.compactMap(BTRCDN.safeMediaURL).btrDeduped()
        guard !originals.isEmpty else { return resolver.urls() }
        let allowed = originals.filter(resolver.allows)
        return allowed + originals.filter { !allowed.contains($0) }
    }
}

// MARK: - Piece buffers and ordered delivery

/// The longest verified contiguous prefix of one piece, fed by every replica (first copy, hedge copy, retries).
/// All replicas carry verified bytes of the same file at the same offsets, so the furthest one wins (lemon `_Feed`).
/// It is also the resume base: a later attempt asks only for what is missing.
final class BTRPieceBuffer: @unchecked Sendable {
    let piece: BTRPiece
    private let lock = NSLock()
    private var data = Data()
    private var count = 0
    private var dropped = false
    private let onGrow: (() -> Void)?

    init(piece: BTRPiece, onGrow: (() -> Void)? = nil) {
        self.piece = piece
        self.onGrow = onGrow
    }

    var verifiedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Bytes `chunk` at `offset` (within the piece) from a verified response. Only what extends the prefix is kept.
    func offer(_ chunk: Data, at offset: Int) {
        lock.lock()
        let end = min(offset + chunk.count, piece.length)
        guard offset <= count, end > count, !dropped else {
            lock.unlock()
            return
        }
        if data.isEmpty && count == 0 { data.reserveCapacity(piece.length) }
        let skip = count - offset
        let from = chunk.startIndex + skip
        data.append(chunk[from..<(from + (end - count))])
        count = end
        lock.unlock()
        onGrow?()
    }

    /// Resume point for a new attempt: the prefix if it is ≥ `minBytes` and the piece is not complete, else 0.
    func resumeBase(minBytes: Int) -> Int {
        let c = verifiedCount
        return c >= minBytes && c < piece.length ? c : 0
    }

    /// Copy of the verified bytes `[from, verifiedCount)`.
    func read(from: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !dropped, from < count else { return nil }
        let s = data.startIndex
        return Data(data[(s + from)..<(s + count)])
    }

    func bytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(data)
    }

    /// Frees the storage once delivered; the count stays.
    func dropStorage() {
        lock.lock()
        dropped = true
        data = Data()
        lock.unlock()
    }
}

/// The pieces of one range in file order, with fail-fast error state and a single delivery waiter.
final class BTRRangeFeed: @unchecked Sendable {
    enum Step {
        case bytes(Data)
        case advance
        case wait(Int)
        case failed(Error)
        case finished
    }

    private struct Entry {
        let buffer: BTRPieceBuffer
        var done = false
        var total: Int64?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var finalized = false
    private var failure: Error?
    private var version = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func add(_ pieces: [BTRPiece]) -> [BTRPieceBuffer] {
        let buffers = pieces.map { BTRPieceBuffer(piece: $0, onGrow: { [weak self] in self?.notify() }) }
        lock.lock()
        entries.append(contentsOf: buffers.map { Entry(buffer: $0) })
        lock.unlock()
        notify()
        return buffers
    }

    func finalize() {
        lock.lock()
        finalized = true
        lock.unlock()
        notify()
    }

    func complete(_ position: Int, total: Int64) {
        lock.lock()
        if position < entries.count {
            entries[position].done = true
            entries[position].total = total
        }
        lock.unlock()
        notify()
    }

    func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        notify()
    }

    func notify() {
        lock.lock()
        version &+= 1
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume()
    }

    /// What the deliverer should do next for the piece at `position`, `offset` bytes into it.
    func step(position: Int, offset: Int) -> Step {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failed(failure) }
        let v = version
        if position >= entries.count { return finalized ? .finished : .wait(v) }
        let entry = entries[position]
        let available = entry.buffer.verifiedCount
        if available > offset, let data = entry.buffer.read(from: offset) { return .bytes(data) }
        if entry.done {
            if offset >= entry.buffer.piece.length { return .advance }
            return .failed(BTRError.lengthMismatch(received: available, expected: entry.buffer.piece.length))
        }
        return .wait(v)
    }

    /// Suspends until something changes after `version` (or the task is cancelled).
    func wait(since v: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if version != v || Task.isCancelled {
                    lock.unlock()
                    c.resume()
                    return
                }
                let old = waiter
                waiter = c
                lock.unlock()
                old?.resume()
            }
        } onCancel: {
            self.notify()
        }
    }

    func release(_ position: Int) {
        lock.lock()
        let buffer = position < entries.count ? entries[position].buffer : nil
        lock.unlock()
        buffer?.dropStorage()
    }

    /// The file total every piece agreed on.
    func verifiedTotal() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let totals = entries.compactMap(\.total)
        guard let first = totals.first else { throw failure ?? BTRError.noCandidates }
        if totals.contains(where: { $0 != first }) { throw BTRError.totalsDiffer }
        return first
    }
}

// MARK: - Attempt / pair state

/// One attempt's progress, shared with the hedge logic and the watchdog.
final class BTRAttemptContext: @unchecked Sendable {
    let startedAt: Double
    /// Bytes asked for (the part after the resume base).
    let length: Int
    let base: Int
    private let lock = NSLock()
    private var receivedBytes = 0
    private var seenBytes = 0
    private var seenAt: Double
    private var headAt: Double?
    private var firstChunkAt: Double?
    private var lastActivityAt: Double
    private var consumerBusy = false

    init(startedAt: Double, length: Int, base: Int) {
        self.startedAt = startedAt
        self.length = length
        self.base = base
        seenAt = startedAt
        lastActivityAt = startedAt
    }

    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    func markHead(_ now: Double) {
        lock.lock()
        headAt = now
        lastActivityAt = now
        lock.unlock()
    }

    func recordChunk(total received: Int, now: Double) {
        lock.lock()
        receivedBytes = received
        if firstChunkAt == nil { firstChunkAt = now }
        lastActivityAt = now
        lock.unlock()
    }

    /// While the consumer applies back-pressure (direct downloads), the stall timer does not run.
    func setConsumerBusy(_ busy: Bool, now: Double) {
        lock.lock()
        consumerBusy = busy
        if !busy { lastActivityAt = now }
        lock.unlock()
    }

    /// For hedgeDue: time running, bytes so far, when they last changed (updated here, as in BTR).
    func observe(_ now: Double) -> (ran: Double, got: Int, seenAt: Double, firstChunkAt: Double?, lastChunkAt: Double) {
        lock.lock()
        defer { lock.unlock() }
        if receivedBytes != seenBytes {
            seenBytes = receivedBytes
            seenAt = now
        }
        return (now - startedAt, receivedBytes, seenAt, firstChunkAt, lastActivityAt)
    }

    /// Earliest timer expiry and the error it raises.
    func nextDeadline(_ tuning: BTRTuning, attemptCap: Bool) -> (at: Double, error: BTRError) {
        lock.lock()
        defer { lock.unlock() }
        var at = attemptCap ? startedAt + tuning.attemptTimeoutMs : Double.infinity
        var error = BTRError.attemptTimeout
        if headAt == nil {
            let fb = startedAt + tuning.firstByteTimeoutMs
            if fb < at { at = fb; error = .firstByteTimeout }
        } else if !consumerBusy {
            let stall = lastActivityAt + tuning.stallTimeoutMs
            if stall < at { at = stall; error = .stallTimeout }
        }
        return (at, error)
    }
}

/// State of a pair shared between the first copy (child task) and the pair controller.
final class BTRPairShared: @unchecked Sendable {
    private let lock = NSLock()
    private var firstContext: BTRAttemptContext?
    private var straggler = false
    private var deficitSamples = 0

    var first: BTRAttemptContext? {
        lock.lock()
        defer { lock.unlock() }
        return firstContext
    }

    var firstStartedAt: Double { first?.startedAt ?? 0 }

    var isStraggler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return straggler
    }

    func setFirst(_ ctx: BTRAttemptContext) {
        lock.lock()
        firstContext = ctx
        lock.unlock()
    }

    func recordDeficit(_ deficit: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        deficitSamples = deficit ? deficitSamples + 1 : 0
        return deficitSamples
    }

    func markStraggler() {
        lock.lock()
        straggler = true
        lock.unlock()
    }
}

/// Per-range budget of early hedges (`createEarlyHedge`): straggler copies, and "stale measurement" copies (≥ 1).
final class BTREarlyHedge: @unchecked Sendable {
    private let lock = NSLock()
    private var progressRemaining: Int
    private var staleRemaining: Int

    init(limit: Int) {
        progressRemaining = max(0, limit)
        staleRemaining = max(1, limit)
    }

    func claimProgress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard progressRemaining > 0 else { return false }
        progressRemaining -= 1
        return true
    }

    func claimStale() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard staleRemaining > 0 else { return false }
        staleRemaining -= 1
        return true
    }
}

/// `onBytes` (the player side) failed: not a CDN failure, ends the download.
struct BTRConsumerError: Error {
    let underlying: Error
}

private final class BTRFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

private final class BTRCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64 = 0
    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return v
    }

    func add(_ n: Int) {
        lock.lock()
        v += Int64(n)
        lock.unlock()
    }
}

private final class BTROperation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int64, Error>?
    private var cancelled = false

    func attach(_ t: Task<Int64, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            t.cancel()
            return
        }
        task = t
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

// MARK: - Downloader

final class BTRDownloader: BTRDownloading, @unchecked Sendable {
    enum PieceMode {
        case ordinary, startup, probe
    }

    struct AttemptSuccess {
        var url: String
        var total: Int64
        /// Bytes received by this attempt (after its resume base; clipped for metadata).
        var length: Int
    }

    private enum PairEvent {
        case finished(Int, Result<AttemptSuccess, Error>)
        case tick
    }

    private struct Settings {
        var concurrency: Int
        var autoOn: Bool
    }

    private let configProvider: () -> BTRConfig
    private let client: MediaHTTPClient
    private let auto: AutoConcurrencyController?
    private let clock: MonotonicClock
    let tuning: BTRTuning
    let pool: BTRSlotPool
    let assigner = BTRAssigner()
    let meter = BTRMeter()
    private let traffic = BTRTrafficMeter()
    private let autoFlag = BTRFlag()
    private let lock = NSLock()
    private var tracks: [BTRTrack] = []
    private var routes = Set<String>()
    private let banRegistry: BTRBanRegistry
    private var banHandler: ((_ host: String, _ kind: BTRBanKind) -> Void)?
    private var operations: [ObjectIdentifier: BTROperation] = [:]
    private var cancelled = false
    private var unsubscribe: (() -> Void)?

    /// Called when the ban list of one of this downloader's routes drops a node or an address (for user notices:
    /// "已停用这个 CDN 节点 — {host} 两次没有返回任何数据，这个视频接下来不再使用它。").
    var onBan: ((_ host: String, _ kind: BTRBanKind) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return banHandler }
        set { lock.lock(); banHandler = newValue; lock.unlock() }
    }

    /// `bans`: where ban lists live (one per route, kept across sessions of the same video).
    init(config: @escaping () -> BTRConfig, client: MediaHTTPClient, auto: AutoConcurrencyController?,
         clock: MonotonicClock = SystemClock.shared, tuning: BTRTuning = .standard, bans: BTRBanRegistry = .shared) {
        configProvider = config
        self.client = client
        self.auto = auto
        self.clock = clock
        self.tuning = tuning
        banRegistry = bans
        let flag = autoFlag
        let initial = Self.resolve(config(), auto: auto, flag: flag)
        pool = BTRSlotPool(limit: initial.concurrency, clock: clock, onChange: { [weak auto] active, limit, queued in
            if flag.value { auto?.demand(active: active, limit: limit, queued: queued) }
        })
        // Every downloader follows the controller's level at once.
        unsubscribe = auto?.subscribe { [weak self] _ in self?.applyLimit() }
        bans.observe(self) { [weak self] route, host, kind in
            guard let self else { return }
            self.lock.lock()
            let mine = self.routes.contains(route)
            let handler = self.banHandler
            self.lock.unlock()
            if mine { handler?(host, kind) }
        }
    }

    deinit {
        unsubscribe?()
        pool.close()
    }

    private static func resolve(_ c: BTRConfig, auto: AutoConcurrencyController?, flag: BTRFlag) -> Settings {
        if c.autoConcurrency, let auto {
            let cap = max(1, c.maxAutoThreads)
            auto.setThreadCap(cap)
            flag.value = true
            return Settings(concurrency: max(1, min(auto.threads, cap)), autoOn: true)
        }
        flag.value = false
        return Settings(concurrency: max(1, min(128, c.concurrency)), autoOn: false)
    }

    private func settings() -> Settings { Self.resolve(configProvider(), auto: auto, flag: autoFlag) }

    /// Re-reads the thread count (settings / auto-concurrency) and applies it to the slot pool.
    func applyLimit() { pool.setLimit(settings().concurrency) }

    // MARK: Tracks

    func makeTrack(kind: MediaKind, urls: [String], routeKey: String) -> BTRTrackHandle {
        let bans = banRegistry.banList(for: routeKey)
        lock.lock()
        routes.insert(routeKey)
        lock.unlock()
        let provider = configProvider
        let track = BTRTrack(kind: kind, urls: urls, routeKey: routeKey, bans: bans, mode: { provider().mode },
                             customHosts: { provider().customHosts }, clock: clock)
        lock.lock()
        tracks.append(track)
        lock.unlock()
        return track
    }

    /// The ban list shared by the tracks of `routeKey` (diagnostics / tests).
    func banList(routeKey: String) -> BTRBanList? {
        lock.lock()
        let known = routes.contains(routeKey)
        lock.unlock()
        return known ? banRegistry.banList(for: routeKey) : nil
    }

    // MARK: BTRDownloading

    func download(_ range: ByteRange, track handle: BTRTrackHandle, kind: BTRRangeKind, priority: Int,
                  deadline: (() -> Double?)?, onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        guard let track = handle as? BTRTrack else { throw BTRError.foreignTrack }
        guard range.start >= 0, range.end >= range.start else { throw BTRError.rangeRejected(status: 416) }
        let deadlineFn: (() -> Double)? = deadline.map { d in { d() ?? .infinity } }
        return try await runOperation {
            switch kind {
            case .meta:
                return try await self.downloadMeta(range, track: track, onBytes: onBytes)
            case .startup:
                return try await self.downloadStartup(range, track: track, deadline: deadlineFn, onBytes: onBytes)
            case .ordinary:
                return try await self.downloadOrdinary(range, track: track, basePriority: Double(priority),
                                                       deadline: deadlineFn, onBytes: onBytes)
            }
        }
    }

    func downloadDirect(_ range: ByteRange, track handle: BTRTrackHandle,
                        onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        guard let track = handle as? BTRTrack else { throw BTRError.foreignTrack }
        guard range.start >= 0, range.end >= range.start else { throw BTRError.rangeRejected(status: 416) }
        return try await runOperation { try await self.direct(range, track: track, onBytes: onBytes) }
    }

    var stats: BTRStats {
        let snap = pool.snapshot
        let t = traffic.snapshot(at: clock.nowMs())
        var s = BTRStats()
        s.threads = snap.limit
        s.activeConnections = snap.active
        s.queuedRequests = snap.queued
        s.bytesPerSecond = t.bps
        s.totalBytes = t.total
        s.hedgedBytes = t.hedged
        if autoFlag.value, let auto { s.autoReason = auto.reason }
        lock.lock()
        let all = tracks
        lock.unlock()
        // One row per host: banned > blocked > healthy > untested, fastest measurement.
        let rank: [CDNNodeStatus.State: Int] = [.banned: 0, .blocked: 1, .healthy: 2, .untested: 3]
        var byHost: [String: CDNNodeStatus] = [:]
        var order: [String] = []
        for track in all {
            for node in track.nodeStatus() {
                if var existing = byHost[node.host] {
                    if (rank[node.state] ?? 3) < (rank[existing.state] ?? 3) { existing.state = node.state }
                    existing.bytesPerSecond = max(existing.bytesPerSecond, node.bytesPerSecond)
                    byHost[node.host] = existing
                } else {
                    byHost[node.host] = node
                    order.append(node.host)
                }
            }
        }
        s.nodes = order.compactMap { byHost[$0] }
        return s
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let ops = Array(operations.values)
        lock.unlock()
        for op in ops { op.cancel() }
        pool.close()
    }

    /// Runs `body` in its own task so `cancelAll()` can abort it; cancelling the caller cancels it too.
    private func runOperation(_ body: @escaping () async throws -> Int64) async throws -> Int64 {
        let op = BTROperation()
        let id = ObjectIdentifier(op)
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        operations[id] = op
        lock.unlock()
        defer {
            lock.lock()
            operations[id] = nil
            lock.unlock()
        }
        let task = Task { try await body() }
        op.attach(task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Range kinds

    /// init / index (§7.8): the whole range, raced over ≤ 3 startup candidates at 0 / 120 / 300 ms, priority 220,
    /// CRITICAL. A file shorter than the range is accepted when the CDN clips at its end.
    private func downloadMeta(_ range: ByteRange, track: BTRTrack,
                              onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let s = settings()
        pool.setLimit(s.concurrency)
        let piece = BTRPiece(index: 0, start: range.start, end: range.end)
        let startedAt = clock.nowMs()
        var lastError: Error?
        for round in 0..<BTRConstants.pieceRounds {
            if round > 0 {
                if clock.nowMs() - startedAt > tuning.pieceRetryWindowMs { break }
                try await btrSleep(ms: BTRConstants.roundPauseMs(round, baseMs: tuning.roundPauseBaseMs))
            }
            var candidates = Array(track.resolver.startupCandidates().btrDeduped().prefix(BTRConstants.metaRaceWidth))
            if candidates.isEmpty && round > 0 {
                candidates = Array(track.resolver.ordered(round).prefix(BTRConstants.metaRaceWidth))
            }
            if candidates.isEmpty { break }
            switch await metaRace(piece, candidates: candidates, track: track, autoOn: s.autoOn) {
            case .success(let won):
                try await onBytes(won.data)
                return won.total
            case .failure(let error):
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError ?? BTRError.noCandidates
    }

    private func metaRace(_ piece: BTRPiece, candidates: [String], track: BTRTrack,
                          autoOn: Bool) async -> Result<(data: Data, total: Int64), Error> {
        let stagger = tuning.metaStaggerMs
        return await withTaskGroup(of: (Int, Result<(data: Data, total: Int64), Error>).self) { group in
            for (i, url) in candidates.enumerated() {
                let delay = i < stagger.count ? stagger[i] : (stagger.last ?? 300)
                group.addTask {
                    do {
                        try await btrSleep(ms: delay)
                        let buffer = BTRPieceBuffer(piece: piece)
                        let r = try await self.attempt(
                            url: url, track: track, priority: Double(BTRConstants.startupPriority), queueClass: .critical,
                            lane: i > 0 ? .rescue : .normal, deadline: nil, isCopy: i > 0, clip: true, attemptCap: true,
                            autoOn: autoOn, begin: { (piece.range, 0) },
                            sink: { data, offset in buffer.offer(data, at: Int(offset - piece.start)) })
                        return (i, .success((buffer.bytes(), r.total)))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var errors: [Int: Error] = [:]
            while let (i, result) = await group.next() {
                switch result {
                case .success(let won):
                    group.cancelAll()
                    return .success(won)
                case .failure(let error):
                    errors[i] = error
                }
            }
            return .failure(errors.max(by: { $0.key < $1.key })?.value ?? BTRError.noCandidates)
        }
    }

    /// First media range after a start / seek / retry (§7.7): a 64 KiB head raced over ≤ 8 URLs at once, then the
    /// rest on the probe's winner and nodes with a measurement only.
    private func downloadStartup(_ range: ByteRange, track: BTRTrack, deadline: (() -> Double)?,
                                 onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let s = settings()
        pool.setLimit(s.concurrency)
        let resolver = track.resolver
        let candidates = resolver.rangeCandidates().btrDeduped()
        let headLength = min(range.length, Int64(BTRConstants.minChunkBytes))
        let head = BTRPiece(index: 0, start: range.start, end: range.start + headLength - 1)
        let feed = BTRRangeFeed()
        let headBuffer = feed.add([head])[0]
        return try await stream(feed, onBytes: onBytes) {
            defer { feed.finalize() }
            guard let headURL = await self.runPiece(
                position: 0, piece: head, buffer: headBuffer, feed: feed, track: track, preferred: candidates,
                mode: .probe, priority: Double(BTRConstants.startupPriority), deadline: deadline, earlyHedge: nil,
                autoOn: s.autoOn) else { return }
            if head.end >= range.end { return }
            let c = s.concurrency
            let eighth = (c + 7) / 8
            let rescueReserve = max(1, min(16, eighth))
            let mediaBudget = max(1, c - rescueReserve)
            let audioBudget = max(1, min(mediaBudget, eighth))
            let pieceBudget = track.kind == .audio ? audioBudget : max(1, mediaBudget - audioBudget)
            var minChunk = self.meter.adaptiveMinChunk(rangeLength: range.end - head.end, pieceLimit: pieceBudget,
                                                       hostCount: candidates.count)
            if track.kind == .audio { minChunk = max(minChunk, BTRConstants.audioPieceFloorBytes) }
            let pieces = BTRRangeCore.splitRange(start: head.end + 1, end: range.end, concurrency: pieceBudget,
                                                 minChunkBytes: minChunk)
                .map { BTRPiece(index: $0.index + 1, start: $0.start, end: $0.end) }
            // A node whose probe never finished would hold up the start: only the winner and measured nodes.
            let proven = candidates.filter { $0 == headURL || resolver.speed($0) > 0 }
            let primaries = self.assigner.assignPrimaries(proven.isEmpty ? [headURL] : proven, source: resolver,
                                                          count: pieces.count)
            let fallback = [headURL] + candidates.filter { $0 != headURL }
            let early = BTREarlyHedge(limit: rescueReserve)
            let buffers = feed.add(pieces)
            feed.finalize()
            await withTaskGroup(of: Void.self) { group in
                for (i, piece) in pieces.enumerated() {
                    let preferred = BTRAssigner.preferredFor(i < primaries.count ? primaries[i] : nil, fallback)
                    group.addTask {
                        _ = await self.runPiece(position: i + 1, piece: piece, buffer: buffers[i], feed: feed, track: track,
                                                preferred: preferred, mode: .startup,
                                                priority: Double(120 - min(30, piece.index)), deadline: deadline,
                                                earlyHedge: early, autoOn: s.autoOn)
                    }
                }
            }
        }
    }

    /// Contiguous follow-up range (§7.6).
    private func downloadOrdinary(_ range: ByteRange, track: BTRTrack, basePriority: Double, deadline: (() -> Double)?,
                                  onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let s = settings()
        pool.setLimit(s.concurrency)
        let resolver = track.resolver
        let length = range.length
        // < 128 KiB: one piece (desktop maxConcurrency 1), its node picked in turns (desktop `inTurns`).
        let single = length < BTRConstants.singlePieceBelowBytes
        let preferred = single ? assigner.inTurnsCandidates(resolver) : resolver.rangeCandidates().btrDeduped()
        let effective = single ? 1 : s.concurrency
        // Soft reserve: idle slots for hedges of stalled pieces.
        let rescueReserve = effective >= 8 ? min(8, max(1, (effective + 7) / 8)) : 0
        let pieceConcurrency = max(1, effective - rescueReserve)
        var minChunk = meter.adaptiveMinChunk(rangeLength: length, pieceLimit: pieceConcurrency, hostCount: preferred.count)
        if track.kind == .audio { minChunk = max(minChunk, BTRConstants.audioPieceFloorBytes) }
        let pieces = BTRRangeCore.splitRange(start: range.start, end: range.end, concurrency: pieceConcurrency,
                                             minChunkBytes: minChunk)
        let primaries = assigner.assignPrimaries(preferred, source: resolver, count: pieces.count)
        let early = BTREarlyHedge(limit: rescueReserve)
        let feed = BTRRangeFeed()
        let buffers = feed.add(pieces)
        feed.finalize()
        return try await stream(feed, onBytes: onBytes) {
            await withTaskGroup(of: Void.self) { group in
                for (i, piece) in pieces.enumerated() {
                    let piecePreferred = BTRAssigner.preferredFor(i < primaries.count ? primaries[i] : nil, preferred)
                    group.addTask {
                        _ = await self.runPiece(position: i, piece: piece, buffer: buffers[i], feed: feed, track: track,
                                                preferred: piecePreferred, mode: .ordinary,
                                                priority: basePriority - Double(min(20, piece.index)), deadline: deadline,
                                                earlyHedge: early, autoOn: s.autoOn)
                    }
                }
            }
        }
    }

    /// Single connection over Bilibili's own URLs in order, resuming where a failed attempt stopped; same strict
    /// 206 validation; bytes go to `onBytes` as they arrive.
    private func direct(_ range: ByteRange, track: BTRTrack,
                        onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let s = settings()
        pool.setLimit(s.concurrency)
        let delivered = BTRCounter()
        var lastError: Error?
        var round = 0
        while round < BTRConstants.pieceRounds {
            if round > 0 { try await btrSleep(ms: BTRConstants.roundPauseMs(round, baseMs: tuning.roundPauseBaseMs)) }
            var progressed = false
            for url in track.directCandidates() {
                try Task.checkCancellation()
                let before = delivered.value
                let offset = range.start + before
                do {
                    let r = try await attempt(
                        url: url, track: track, priority: 150, queueClass: .startup, lane: .normal, deadline: nil,
                        isCopy: false, clip: false, attemptCap: false, autoOn: s.autoOn,
                        begin: { (ByteRange(start: offset, end: range.end), 0) },
                        sink: { data, _ in
                            do { try await onBytes(data) } catch { throw BTRConsumerError(underlying: error) }
                            delivered.add(data.count)
                        })
                    return r.total
                } catch let e as BTRConsumerError {
                    throw e.underlying
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    lastError = error
                    if delivered.value > before { progressed = true }
                }
            }
            round = progressed ? 0 : round + 1
        }
        throw lastError ?? BTRError.noCandidates
    }

    // MARK: Streaming

    /// Runs `producer` (the piece downloads) while delivering the feed in order; fails fast on any piece failure.
    private func stream(_ feed: BTRRangeFeed, onBytes: @escaping (Data) async throws -> Void,
                        producer: @escaping () async -> Void) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await producer() }
            try await self.deliver(feed, onBytes: onBytes)
            try await group.waitForAll()
        }
        return try feed.verifiedTotal()
    }

    private func deliver(_ feed: BTRRangeFeed, onBytes: (Data) async throws -> Void) async throws {
        var position = 0
        var offset = 0
        while true {
            try Task.checkCancellation()
            switch feed.step(position: position, offset: offset) {
            case .bytes(let data):
                try await onBytes(data)
                offset += data.count
            case .advance:
                feed.release(position)
                position += 1
                offset = 0
            case .wait(let v):
                await feed.wait(since: v)
            case .failed(let error):
                throw error
            case .finished:
                return
            }
        }
    }

    /// Downloads one piece into its buffer and records the outcome in the feed. Returns the winning URL.
    private func runPiece(position: Int, piece: BTRPiece, buffer: BTRPieceBuffer, feed: BTRRangeFeed, track: BTRTrack,
                          preferred: [String], mode: PieceMode, priority: Double, deadline: (() -> Double)?,
                          earlyHedge: BTREarlyHedge?, autoOn: Bool) async -> String? {
        do {
            let r = try await downloadPiece(piece, buffer: buffer, track: track, preferred: preferred, mode: mode,
                                            priority: priority, deadline: deadline, earlyHedge: earlyHedge, autoOn: autoOn)
            feed.complete(position, total: r.total)
            return r.url
        } catch {
            feed.fail(error)
            return nil
        }
    }

    // MARK: Piece (§7.4)

    func pieceCandidates(_ piece: BTRPiece, resolver: BTRResolver, preferred: [String], round: Int) -> [String] {
        let offset = preferred.isEmpty ? 0 : round % preferred.count
        let rotated = Array(preferred[offset...] + preferred[..<offset])
        let rotatedSet = Set(rotated)
        let rescue = resolver.rescueCandidates().filter { !rotatedSet.contains($0) }
        let restList = Array(rotated.dropFirst()) + rescue
        var speeds: [String: Double] = [:]
        for url in restList where speeds[url] == nil { speeds[url] = resolver.speed(url) }
        // Copies go to the fastest known nodes wherever they were listed.
        let rest = restList.btrStableSorted { (speeds[$0] ?? 0) > (speeds[$1] ?? 0) }
        var candidates = rotated.isEmpty ? rest : [rotated[0]] + rest
        var seen = Set(candidates)
        for url in resolver.ordered(piece.index) where !seen.contains(url) {
            candidates.append(url)
            seen.insert(url)
        }
        return candidates
    }

    private func downloadPiece(_ piece: BTRPiece, buffer: BTRPieceBuffer, track: BTRTrack, preferred: [String],
                               mode: PieceMode, priority: Double, deadline: (() -> Double)?,
                               earlyHedge: BTREarlyHedge?, autoOn: Bool) async throws -> AttemptSuccess {
        let hasDeadline = deadline.map { $0().isFinite } ?? false
        let resolver = track.resolver
        let startedAt = clock.nowMs()
        var lastError: Error?
        for round in 0..<BTRConstants.pieceRounds {
            if round > 0 {
                if clock.nowMs() - startedAt > tuning.pieceRetryWindowMs { break }
                try await btrSleep(ms: BTRConstants.roundPauseMs(round, baseMs: tuning.roundPauseBaseMs))
            }
            // Health and bans have changed since the last round: rebuilt each time.
            let candidates = pieceCandidates(piece, resolver: resolver, preferred: preferred, round: round)
            let limit = min(BTRConstants.maxPieceCandidates, candidates.count)
            let width = mode == .probe ? limit : 2
            var tried = Set<String>()
            while tried.count < limit {
                try Task.checkCancellation()
                // A node banned while this piece waited is skipped, unless only banned ones are left.
                let untried = candidates.filter { !tried.contains($0) }
                let open = untried.filter(resolver.allows)
                let pair = Array((open.isEmpty ? untried : open).prefix(width))
                if pair.isEmpty { break }
                tried.formUnion(pair)
                let outcome = await runPair(pair, piece: piece, buffer: buffer, track: track, mode: mode,
                                            priority: priority, deadline: deadline, hasDeadline: hasDeadline,
                                            earlyHedge: earlyHedge, autoOn: autoOn)
                switch outcome {
                case .success(let r):
                    if autoOn { auto?.delivered(piece.length) }
                    return r
                case .failure(let error):
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    lastError = error
                }
            }
        }
        throw lastError ?? BTRError.noCandidates
    }

    /// One pair (or, in probe mode, ≤ 8 attempts at once): the first copy now, the copy when the hedge condition
    /// fires; the first verified success wins and cancels the rest.
    private func runPair(_ pair: [String], piece: BTRPiece, buffer: BTRPieceBuffer, track: BTRTrack, mode: PieceMode,
                         priority: Double, deadline: (() -> Double)?, hasDeadline: Bool, earlyHedge: BTREarlyHedge?,
                         autoOn: Bool) async -> Result<AttemptSuccess, Error> {
        let probe = mode == .probe
        let startup = mode != .ordinary
        let queueClass: BTRQueueClass = probe ? .critical : startup ? .startup : .ordinary
        let shared = BTRPairShared()
        let askedAt = clock.nowMs()
        let measured = meter.hedgeDelayMs(maxMs: tuning.hedgeDelayMs)
        let delay = probe ? 0 : startup ? min(hasDeadline ? 200 : 250, measured) : measured
        let resolver = track.resolver
        let deadlineNow: () -> Double = { deadline?() ?? .infinity }
        let paced = !hasDeadline && tuning.pacedHedgeWithoutDeadline
        let resumeMin = BTRConstants.resumeMinBytes

        return await withTaskGroup(of: PairEvent.self, returning: Result<AttemptSuccess, Error>.self) { group in
            var launched = [Bool](repeating: false, count: pair.count)
            var errors = [Error?](repeating: nil, count: pair.count)
            var finished = 0
            var firstFailed = false
            var stragglerSeen = false
            var stragglerGoAt: Double?
            var ticking = false

            func launch(_ i: Int) {
                launched[i] = true
                let url = pair[i]
                let isCopy = i > 0
                group.addTask {
                    do {
                        let r = try await self.attempt(
                            url: url, track: track, priority: priority + (isCopy ? Double(BTRConstants.hedgeCopyPriorityBonus) : 0),
                            queueClass: queueClass, lane: isCopy ? .rescue : .normal, deadline: deadline, isCopy: isCopy,
                            clip: false, attemptCap: true, autoOn: autoOn,
                            begin: {
                                // Resume from the longest verified prefix known when the request really starts:
                                // a failed attempt's, or what the running first copy has received by now.
                                let base = buffer.resumeBase(minBytes: resumeMin)
                                return (ByteRange(start: piece.start + Int64(base), end: piece.end), base)
                            },
                            sink: { data, offset in buffer.offer(data, at: Int(offset - piece.start)) },
                            onBegin: isCopy ? nil : { ctx in shared.setFirst(ctx) },
                            onProgress: (!isCopy && hasDeadline) ? { ctx in
                                self.observeFirst(ctx, shared: shared, deadline: deadlineNow)
                            } : nil)
                        return .finished(i, .success(r))
                    } catch {
                        return .finished(i, .failure(error))
                    }
                }
            }

            launch(0)
            if probe && pair.count > 1 {
                for i in 1..<pair.count { launch(i) }
            }

            while true {
                if Task.isCancelled {
                    group.cancelAll()
                    return .failure(CancellationError())
                }
                if let i = launched.firstIndex(of: false) {
                    let now = clock.nowMs()
                    var go = firstFailed // refused at once (e.g. 403): no idle hedge delay
                    if !go, let at = stragglerGoAt {
                        go = now >= at
                    } else if !go {
                        if hasDeadline && !probe {
                            // Decided once the first copy holds a connection.
                            if let first = shared.first,
                               hedgeDue(first, delayMs: delay, deadlineAt: deadlineNow(), copyBps: resolver.speed(pair[i]),
                                        rescue: earlyHedge) {
                                go = true
                            }
                        } else if paced {
                            if let first = shared.first, pacedHedgeDue(first, delayMs: delay, copyBps: resolver.speed(pair[i])) {
                                go = true
                            }
                        } else if now - askedAt >= delay {
                            // Fixed delay, counted from when the piece asked (queue time included).
                            go = true
                        }
                        if !go && !stragglerSeen && !probe && shared.isStraggler {
                            stragglerSeen = true
                            if earlyHedge?.claimProgress() == true {
                                let grace = max(0, 250 - (now - shared.firstStartedAt))
                                stragglerGoAt = now + grace
                                go = grace <= 0
                            }
                        }
                    }
                    if go {
                        launch(i)
                        continue
                    }
                    if !ticking {
                        let wait: Double
                        if let at = stragglerGoAt {
                            wait = max(1, at - now)
                        } else if (hasDeadline && !probe) || paced {
                            wait = tuning.hedgePollMs
                        } else {
                            wait = max(1, askedAt + delay - now)
                        }
                        ticking = true
                        group.addTask {
                            try? await btrSleep(ms: wait)
                            return .tick
                        }
                    }
                }
                guard let event = await group.next() else {
                    return .failure(errors.compactMap { $0 }.last ?? BTRError.noCandidates)
                }
                switch event {
                case .tick:
                    ticking = false
                case .finished(_, .success(let r)):
                    group.cancelAll()
                    return .success(r)
                case .finished(let i, .failure(let error)):
                    errors[i] = error
                    finished += 1
                    if i == 0 { firstFailed = true }
                    if finished == pair.count {
                        group.cancelAll()
                        return .failure(errors.compactMap { $0 }.last ?? error)
                    }
                }
            }
        }
    }

    /// BTR `hedgeDue` (verbatim), with lemon's rule for a first copy still waiting for its first byte.
    func hedgeDue(_ first: BTRAttemptContext, delayMs: Double, deadlineAt: Double, copyBps: Double,
                  rescue: BTREarlyHedge?) -> Bool {
        let now = clock.nowMs()
        let o = first.observe(now)
        if o.ran < delayMs { return false }
        let m = meter.values
        if o.got == 0 {
            // lemon: heads queue on busy links; with both sides measured, wait 1.5× the usual time to headers.
            if copyBps > 0, m.connectionBps > 0, m.headMs > 0 { return o.ran >= m.headMs * 1.5 }
            return true
        }
        if now - o.seenAt >= delayMs { return true } // stopped for a whole delay
        let rate = Double(o.got) * 1000 / o.ran
        let finishAt = now + Double(max(0, first.length - o.got)) * 1000 / rate
        if finishAt <= deadlineAt - BTRConstants.hedgeSlackMs { return false } // on time with 1.5 s spare
        if copyBps > rate * BTRConstants.hedgeFaster { return true }
        if !(m.connectionBps > 0) || rate < m.connectionBps * BTRConstants.hedgePace { return true }
        if !(copyBps > 0) { return true }
        return finishAt > deadlineAt && (rescue?.claimStale() ?? false)
    }

    /// lemon `_hedgeDue` (no deadline term), used without a deadline when `pacedHedgeWithoutDeadline` is set.
    func pacedHedgeDue(_ first: BTRAttemptContext, delayMs: Double, copyBps: Double) -> Bool {
        let now = clock.nowMs()
        let o = first.observe(now)
        if o.ran < delayMs { return false }
        let m = meter.values
        if copyBps == 0 || m.connectionBps == 0 { return true }
        if o.got == 0 { return o.ran >= m.headMs * 1.5 }
        if now - o.lastChunkAt >= delayMs { return true }
        guard let firstChunkAt = o.firstChunkAt else { return true }
        let moving = now - firstChunkAt
        if moving < delayMs { return false }
        let rate = Double(o.got) * 1000 / moving
        return copyBps > rate * BTRConstants.hedgeFaster || rate < m.connectionBps * BTRConstants.hedgePace
    }

    /// Straggler detection on the first copy's progress (only with a deadline).
    private func observeFirst(_ ctx: BTRAttemptContext, shared: BTRPairShared, deadline: () -> Double) {
        let now = clock.nowMs()
        let received = ctx.received
        let elapsed = max(1, now - ctx.startedAt)
        let bps = Double(received) * 1000 / elapsed
        guard bps > 0 else { return }
        let etaMs = (Double(max(0, ctx.length - received)) * 1000 / bps).rounded()
        let deadlineAt = deadline()
        let finite = deadlineAt.isFinite
        let remaining = deadlineAt - now
        let missesDeadline = finite && etaMs >= max(0, remaining)
        let connection = meter.values.connectionBps
        let slowerThanPeers = connection > 0 && bps < connection * 0.5 && etaMs >= 500
        let deficits = shared.recordDeficit(finite && etaMs - remaining >= 250)
        if finite && ((missesDeadline && slowerThanPeers) || deficits >= 2) { shared.markStraggler() }
    }

    // MARK: Attempt (§7.3)

    /// slot → begin (resume base, after the grant) → GET → strict validation → feedback. Always releases the slot
    /// and cancels the HTTP stream on every exit.
    private func attempt(url: String, track: BTRTrack, priority: Double, queueClass: BTRQueueClass, lane: BTRSlotLane,
                         deadline: (() -> Double)?, isCopy: Bool, clip: Bool, attemptCap: Bool, autoOn: Bool,
                         begin: () -> (part: ByteRange, base: Int),
                         sink: @escaping (Data, Int64) async throws -> Void,
                         onBegin: ((BTRAttemptContext) -> Void)? = nil,
                         onProgress: ((BTRAttemptContext) -> Void)? = nil) async throws -> AttemptSuccess {
        let ages = queueClass == .ordinary && (deadline?().isFinite ?? false)
        let slot = try await pool.acquire(priority: priority, queueClass: queueClass, lane: lane, deadline: deadline, ages: ages)
        defer { slot.release() }
        try Task.checkCancellation()
        let plan = begin()
        let ctx = BTRAttemptContext(startedAt: clock.nowMs(), length: Int(plan.part.length), base: plan.base)
        onBegin?(ctx)
        let resolver = track.resolver
        do {
            guard let requestURL = URL(string: url) else { throw BTRError.transport("invalid URL") }
            let result = try await transfer(requestURL, part: plan.part, ctx: ctx, track: track, clip: clip,
                                            attemptCap: attemptCap, autoOn: autoOn, isCopy: isCopy, priority: priority,
                                            sink: sink, onProgress: onProgress)
            let elapsed = max(1, clock.nowMs() - ctx.startedAt)
            meter.record(bytes: result.length, elapsedMs: elapsed)
            // The node answered either way; only a large enough transfer says how fast it is.
            resolver.success(url, bps: result.length >= BTRConstants.speedSampleMinBytes
                                 ? Double(result.length) * 1000 / elapsed : 0)
            return AttemptSuccess(url: url, total: result.total, length: result.length)
        } catch let e as BTRConsumerError {
            throw e
        } catch {
            let received = ctx.received
            let cancelled = error is CancellationError || (Task.isCancelled && error.btrIsCancellation)
            // A copy that lost the race was cut off, not broken: what it received measures its node.
            if cancelled && received >= BTRConstants.speedSampleMinBytes {
                resolver.sample(url, bps: Double(received) * 1000 / max(1, clock.nowMs() - ctx.startedAt))
            }
            if !cancelled { resolver.failure(url, error: error, receivedBytes: received) }
            if autoOn, let auto {
                let status = error.btrStatus
                if status == 412 || status == 429 {
                    auto.pushback(status: status)
                } else if !cancelled && error.btrIsTimeout && received == 0 {
                    auto.slow()
                }
            }
            throw cancelled ? CancellationError() : error
        }
    }

    /// The HTTP transfer with its watchdog (first byte / stall / attempt timers). Ending the group cancels the
    /// stream consumer, which terminates the client's request.
    private func transfer(_ url: URL, part: ByteRange, ctx: BTRAttemptContext, track: BTRTrack, clip: Bool,
                          attemptCap: Bool, autoOn: Bool, isCopy: Bool, priority: Double,
                          sink: @escaping (Data, Int64) async throws -> Void,
                          onProgress: ((BTRAttemptContext) -> Void)?) async throws -> (total: Int64, length: Int) {
        try await withThrowingTaskGroup(of: (total: Int64, length: Int)?.self) { group in
            group.addTask {
                try await self.consume(url, part: part, ctx: ctx, track: track, clip: clip, autoOn: autoOn,
                                       isCopy: isCopy, priority: priority, sink: sink, onProgress: onProgress)
            }
            group.addTask {
                try await self.watchdog(ctx, attemptCap: attemptCap)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
            }
            throw CancellationError()
        }
    }

    private func watchdog(_ ctx: BTRAttemptContext, attemptCap: Bool) async throws {
        while true {
            let now = clock.nowMs()
            let next = ctx.nextDeadline(tuning, attemptCap: attemptCap)
            if now >= next.at { throw next.error }
            try await btrSleep(ms: min(next.at - now, 1000) + 0.5)
        }
    }

    private func consume(_ url: URL, part: ByteRange, ctx: BTRAttemptContext, track: BTRTrack, clip: Bool, autoOn: Bool,
                         isCopy: Bool, priority: Double, sink: @escaping (Data, Int64) async throws -> Void,
                         onProgress: ((BTRAttemptContext) -> Void)?) async throws -> (total: Int64, length: Int) {
        let stream = client.get(url, range: part, highPriority: priority >= 100)
        var expected = Int(part.length)
        var total: Int64 = 0
        var gotHead = false
        var received = 0
        do {
            for try await event in stream {
                switch event {
                case let .head(status, headers):
                    if gotHead { throw BTRError.transport("duplicate response head") }
                    let now = clock.nowMs()
                    ctx.markHead(now)
                    meter.recordHead(ms: now - ctx.startedAt)
                    // 206 with a Content-Range matching the request exactly; 200 full-body answers fail too.
                    guard status == 206, let cr = BTRRangeCore.parseContentRange(headers["content-range"]),
                          let crTotal = cr.total, cr.start == part.start else {
                        throw BTRError.rangeRejected(status: status)
                    }
                    if cr.end != part.end {
                        // Metadata only: a file shorter than the request, clipped at its end.
                        guard clip, cr.end == crTotal - 1, cr.end < part.end else {
                            throw BTRError.rangeRejected(status: status)
                        }
                        expected = Int(cr.length)
                    }
                    if let known = track.establishTotal(crTotal) {
                        throw BTRError.inconsistentTotal(expected: known, got: crTotal)
                    }
                    total = crTotal
                    gotHead = true
                case let .data(chunk):
                    guard gotHead else { throw BTRError.transport("body before response head") }
                    if chunk.isEmpty { continue }
                    if received + chunk.count > expected { throw BTRError.oversized }
                    let offset = part.start + Int64(received)
                    received += chunk.count
                    let now = clock.nowMs()
                    ctx.recordChunk(total: received, now: now)
                    traffic.record(chunk.count, hedge: isCopy, at: now)
                    if autoOn { auto?.activity() }
                    ctx.setConsumerBusy(true, now: now)
                    try await sink(chunk, offset)
                    ctx.setConsumerBusy(false, now: clock.nowMs())
                    onProgress?(ctx)
                }
            }
        } catch let e as BTRConsumerError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is BTRError { throw error }
            if let fetch = error as? MediaFetchError {
                throw BTRError.transport(fetch == .cancelled ? "cancelled" : "\(fetch)")
            }
            throw BTRError.transport("\(error)")
        }
        // A cancelled consumer sees the stream end: never take that for a complete body.
        if Task.isCancelled { throw CancellationError() }
        guard gotHead else { throw BTRError.transport("no response") }
        guard received == expected else { throw BTRError.lengthMismatch(received: received, expected: expected) }
        return (total, expected)
    }
}
