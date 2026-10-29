import Foundation

// Per-session media core of the local proxy:
//
// - a table per track (pinned init/index bytes + the sidx segment list),
// - an in-memory cache of completed segments with a byte budget (evicts segments behind playhead − 30 s first,
//   then the farthest ahead; btr-core §9.7 / §13.3),
// - in-flight segment downloads that late readers JOIN: a client request for a segment that is being prefetched
//   attaches to that download and streams its bytes as they arrive — a segment is never downloaded twice at once,
// - fetch execution through the BTR downloader: `.startup` only for start / seek / retry ranges (btr-core §10
//   "warmEnd"), deadlines from the playhead, per-request fallback to `downloadDirect`, and acceleration suspended
//   for a track after 6 consecutive accelerated failures (btr-core §10 / §1.6 FAILURE_LIMIT),
// - the PrefetchPlanner, re-run on every playhead report, completion and reader detach.
//
// Thread-safety: one NSLock guards the mutable state. Streams are never yielded to / finished while that lock is
// held (their termination handlers call back into the store).

/// Bytes of a track that live in memory for the whole session (init + sidx, or a progressive file's head).
struct PinnedBytes: Hashable {
    var range: ByteRange
    var data: Data
}

/// Static description of one file served by a session.
struct SegmentStoreTrack {
    var kind: MediaKind
    var handle: BTRTrackHandle
    var total: Int64
    var pinned: [PinnedBytes]
    /// Media units in file order (sidx segments; fixed-size chunks with estimated times for progressive files).
    var segments: [SidxSegment]
    /// false → every download is a single-connection `downloadDirect`.
    var accelerate: Bool
}

struct SegmentKey: Hashable {
    var kind: MediaKind
    var index: Int
}

enum MediaProxyError: Error, Equatable, LocalizedError {
    case sessionClosed
    case truncated(expected: Int64, received: Int64)
    case totalMismatch(expected: Int64, got: Int64)

    var errorDescription: String? {
        switch self {
        case .sessionClosed: return "播放会话已关闭"
        case .truncated(let e, let r): return "视频数据不完整（\(r)/\(e)）"
        case .totalMismatch(let e, let g): return "CDN 返回的文件长度不一致（\(g)，应为 \(e)）"
        }
    }
}

// MARK: - In-flight download

/// One running download whose bytes are kept (for the cache and for late joiners) and fanned out to readers.
final class SegmentFetch {
    enum State {
        case running, finished, failed(Error)
    }

    /// nil for uncached ad-hoc ranges.
    let key: SegmentKey?
    let range: ByteRange
    private let lock = NSLock()
    private var buffer = Data()
    private var state: State = .running
    private var cancelledFlag = false
    private var subscribers: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var nextSubscriber = 0

    init(key: SegmentKey?, range: ByteRange) {
        self.key = key
        self.range = range
        buffer.reserveCapacity(Int(min(range.length, 32 << 20)))
    }

    var receivedCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(buffer.count)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .running = state { return true }
        return false
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Appends verified bytes (in file order). Returns false once cancelled / finished (the producer should stop).
    @discardableResult
    func append(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard case .running = state, !cancelledFlag else { return false }
        let room = range.length - Int64(buffer.count)
        guard room > 0 else { return true }
        let piece: Data
        if Int64(chunk.count) > room {
            piece = Data(chunk.prefix(Int(room)))
        } else {
            piece = chunk.startIndex == 0 ? chunk : Data(chunk)
        }
        buffer.append(piece)
        for continuation in subscribers.values { continuation.yield(piece) }
        return true
    }

    func markCancelled() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard case .running = state else {
            lock.unlock()
            return
        }
        state = .finished
        let subs = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for continuation in subs { continuation.finish() }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard case .running = state else {
            lock.unlock()
            return
        }
        state = .failed(error)
        let subs = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for continuation in subs { continuation.finish(throwing: error) }
    }

    /// A stream of the fetch's bytes from its first byte: what already arrived, then the rest as it arrives.
    /// `onEnd` runs exactly once, when the stream terminates (finished, failed, cancelled by the reader).
    /// Must not be called while holding a lock that `onEnd` takes.
    func subscribe(onEnd: @escaping () -> Void) -> SegmentSubscription {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { captured = $0 }
        let continuation = captured!
        lock.lock()
        let id = nextSubscriber
        nextSubscriber += 1
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
            onEnd()
        }
        lock.lock()
        if !buffer.isEmpty { continuation.yield(buffer) }
        switch state {
        case .running:
            subscribers[id] = continuation
            lock.unlock()
        case .finished:
            lock.unlock()
            continuation.finish()
        case .failed(let error):
            lock.unlock()
            continuation.finish(throwing: error)
        }
        return SegmentSubscription(stream: stream, continuation: continuation, fetch: self)
    }

    private func removeSubscriber(_ id: Int) {
        lock.lock()
        subscribers[id] = nil
        lock.unlock()
    }
}

/// A reader's attachment to a `SegmentFetch`.
final class SegmentSubscription {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    /// Keeps the bytes alive while the reader works through them.
    let fetch: SegmentFetch

    init(stream: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation,
         fetch: SegmentFetch) {
        self.stream = stream
        self.continuation = continuation
        self.fetch = fetch
    }

    /// Detach (idempotent). The download itself keeps running unless the planner cancels it.
    func cancel() { continuation.finish() }
}

// MARK: - Store

final class SegmentStore {
    static let failureLimit = 6
    static let warmThresholdBytes: Int64 = 64 * 1024
    static let readerStartupPriority = 120
    static let readerPriority = 70

    /// min(256 MB, physical memory / 16), at least 64 MB.
    static func defaultBudgetBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        let mb: Int64 = 1 << 20
        let byMemory = Int64(clamping: physicalMemory / 16)
        return max(64 * mb, min(256 * mb, byMemory))
    }

    enum Origin {
        case reader, prefetch
    }

    enum UnitSource {
        case bytes(Data)
        case stream(SegmentSubscription)
        case closed
    }

    private final class TrackState {
        let spec: SegmentStoreTrack
        var cache: [Int: Data] = [:]
        var warmEnd: Int64?
        var consecutiveFailures = 0
        var failedAtMs: [Int: Double] = [:]
        init(_ spec: SegmentStoreTrack) { self.spec = spec }
        var segments: [SidxSegment] { spec.segments }
    }

    private struct Inflight {
        let fetch: SegmentFetch
        let task: Task<Void, Never>
        var readers: Int
        let origin: Origin
    }

    private struct FetchJob {
        let fetch: SegmentFetch
        let kind: MediaKind
        let handle: BTRTrackHandle
        let priority: Int
        let rangeKind: BTRRangeKind
        let accelerated: Bool
        let segmentStart: Double?
        let total: Int64
    }

    struct Playhead {
        var time: Double = 0
        var rate: Double = 1
        var playing = false
        var bufferedAhead: Double = 0
        var cacheFull = false
        var updatedAtMs: Double = 0

        func current(at nowMs: Double) -> Double {
            guard playing, rate != 0 else { return time }
            return time + min(1, max(0, (nowMs - updatedAtMs) / 1000)) * rate
        }
    }

    let budgetBytes: Int64
    private let downloader: BTRDownloading
    private let clock: MonotonicClock
    private let forwardSeconds: () -> Double
    private let accelerationAllowed: () -> Bool
    private let onHardFailure: (() -> Void)?
    private let tracks: [MediaKind: TrackState]
    private let order: [MediaKind]
    private let lock = NSLock()
    private var inflight: [SegmentKey: Inflight] = [:]
    private var gapFetches: [ObjectIdentifier: (fetch: SegmentFetch, task: Task<Void, Never>)] = [:]
    private var cachedBytes: Int64 = 0
    private var playhead = Playhead()
    private var planner: PrefetchPlanner
    private var closed = false

    init(tracks specs: [SegmentStoreTrack], downloader: BTRDownloading, clock: MonotonicClock = SystemClock.shared,
         budgetBytes: Int64 = SegmentStore.defaultBudgetBytes(), videoHeight: Int = 0,
         forwardSeconds: @escaping () -> Double, accelerationAllowed: @escaping () -> Bool = { true },
         onHardFailure: (() -> Void)? = nil) {
        var table: [MediaKind: TrackState] = [:]
        var order: [MediaKind] = []
        for spec in specs where table[spec.kind] == nil {
            table[spec.kind] = TrackState(spec)
            order.append(spec.kind)
        }
        tracks = table
        self.order = order
        self.downloader = downloader
        self.clock = clock
        self.budgetBytes = budgetBytes
        self.forwardSeconds = forwardSeconds
        self.accelerationAllowed = accelerationAllowed
        self.onHardFailure = onHardFailure
        planner = PrefetchPlanner(videoHeight: videoHeight)
    }

    // MARK: Track info

    var kinds: [MediaKind] { order }

    func total(of kind: MediaKind) -> Int64? { tracks[kind]?.spec.total }

    func segments(of kind: MediaKind) -> [SidxSegment] { tracks[kind]?.segments ?? [] }

    /// Some track asked for acceleration but runs on the plain path after repeated failures.
    var fallbackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracks.values.contains { $0.spec.accelerate && $0.consecutiveFailures >= Self.failureLimit }
    }

    /// At least one track currently downloads through the accelerated path.
    var isAccelerating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracks.values.contains { useAcceleratedLocked($0) }
    }

    var startupTargetSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return planner.startupTargetSeconds
    }

    // MARK: Player state

    func updatePlayback(time: Double, rate: Double, playing: Bool, bufferedAhead: Double, cacheFull: Bool) {
        let now = clock.nowMs()
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        playhead = Playhead(time: time.isFinite ? max(0, time) : 0, rate: rate.isFinite ? rate : 1,
                            playing: playing, bufferedAhead: bufferedAhead.isFinite ? max(0, bufferedAhead) : 0,
                            cacheFull: cacheFull, updatedAtMs: now)
        if !planner.isArmed { planner.reset(time: playhead.time, nowMs: now, tracks: segmentListsLocked()) }
        evictLocked(now: now)
        let cancels = replanLocked(now: now)
        lock.unlock()
        for task in cancels { task.cancel() }
    }

    /// The player is about to seek. Outside AVPlayer's buffer → a new startup at `time` (startup range kind again,
    /// far prefetches cancelled); inside → only the playhead moves.
    func seek(to time: Double, outsideBuffer: Bool) {
        let now = clock.nowMs()
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        playhead.time = time.isFinite ? max(0, time) : 0
        playhead.updatedAtMs = now
        if outsideBuffer {
            playhead.bufferedAhead = 0
            playhead.cacheFull = false
        }
        if outsideBuffer || !planner.isArmed {
            planner.reset(time: playhead.time, nowMs: now, tracks: segmentListsLocked())
            for track in tracks.values { track.warmEnd = nil }
        }
        let cancels = replanLocked(now: now)
        lock.unlock()
        for task in cancels { task.cancel() }
    }

    /// Every track has the segment playing at `time` in the cache.
    func isCached(at time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for track in tracks.values where !track.segments.isEmpty {
            let index = SidxIndex.segmentIndex(in: track.segments, at: time)
            if track.cache[index] == nil { return false }
        }
        return true
    }

    /// Seconds of contiguous cached media from the playhead (minimum over the tracks).
    func cachedAheadSeconds() -> Double {
        let now = clock.nowMs()
        lock.lock()
        defer { lock.unlock() }
        let time = playhead.current(at: now)
        var result = Double.infinity
        for track in tracks.values where !track.segments.isEmpty {
            var index = SidxIndex.segmentIndex(in: track.segments, at: time)
            var end = time
            while index < track.segments.count, track.cache[index] != nil {
                end = track.segments[index].endTime
                index += 1
            }
            result = min(result, max(0, end - time))
        }
        return result.isFinite ? result : 0
    }

    var cachedByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return cachedBytes
    }

    /// Drops cached segments behind the playhead (memory warning).
    func trimCache() {
        let now = clock.nowMs()
        lock.lock()
        let time = playhead.current(at: now)
        for track in tracks.values {
            for (index, data) in track.cache where track.segments[index].endTime < time {
                track.cache[index] = nil
                cachedBytes -= Int64(data.count)
            }
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let entries = Array(inflight.values)
        inflight = [:]
        let gaps = Array(gapFetches.values)
        gapFetches = [:]
        for track in tracks.values { track.cache = [:] }
        cachedBytes = 0
        lock.unlock()
        for entry in entries {
            entry.fetch.markCancelled()
            entry.task.cancel()
            entry.fetch.fail(MediaProxyError.sessionClosed)
        }
        for gap in gaps {
            gap.fetch.markCancelled()
            gap.task.cancel()
            gap.fetch.fail(MediaProxyError.sessionClosed)
        }
    }

    // MARK: Reading

    /// A body source for `range` (closed, inside the file) of `kind`; nil for an unknown track.
    func reader(kind: MediaKind, range: ByteRange) -> MediaRangeReader? {
        guard let track = tracks[kind], range.start >= 0, range.end < track.spec.total, range.end >= range.start
        else { return nil }
        return MediaRangeReader(store: self, kind: kind, pieces: Self.pieces(for: range, spec: track.spec))
    }

    /// Splits a requested range into pinned bytes, (parts of) segments and uncovered gaps.
    static func pieces(for range: ByteRange, spec: SegmentStoreTrack) -> [MediaRangeReader.Piece] {
        let pinned = spec.pinned.sorted { $0.range.start < $1.range.start }
        let segments = spec.segments
        var pieces: [MediaRangeReader.Piece] = []
        var cursor = range.start
        while cursor <= range.end {
            if let p = pinned.first(where: { $0.range.start <= cursor && cursor <= $0.range.end }) {
                let end = min(p.range.end, range.end)
                pieces.append(.bytes(p.data, lower: Int(cursor - p.range.start), upper: Int(end - p.range.start) + 1))
                cursor = end + 1
                continue
            }
            if let index = SidxIndex.segmentIndex(in: segments, containingByte: cursor) {
                let segment = segments[index]
                let end = min(segment.byteRange.end, range.end)
                pieces.append(.segment(index: index, unitStart: segment.byteRange.start,
                                       need: ByteRange(start: cursor, end: end)))
                cursor = end + 1
                continue
            }
            var next = range.end + 1
            for p in pinned where p.range.start > cursor { next = min(next, p.range.start) }
            if let first = firstSegment(startingAfter: cursor, in: segments) { next = min(next, first) }
            let end = min(range.end, next - 1)
            pieces.append(.gap(ByteRange(start: cursor, end: end)))
            cursor = end + 1
        }
        return pieces
    }

    private static func firstSegment(startingAfter offset: Int64, in segments: [SidxSegment]) -> Int64? {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].byteRange.start > offset { high = middle } else { low = middle + 1 }
        }
        return low < segments.count ? segments[low].byteRange.start : nil
    }

    /// Cached bytes, or a subscription to the (joined or newly started) download of segment `index`.
    func openSegment(kind: MediaKind, index: Int) -> UnitSource {
        lock.lock()
        guard !closed, let track = tracks[kind], index >= 0, index < track.segments.count else {
            lock.unlock()
            return .closed
        }
        if let data = track.cache[index] {
            lock.unlock()
            return .bytes(data)
        }
        let key = SegmentKey(kind: kind, index: index)
        var entry = inflight[key]
        if entry == nil {
            let (rangeKind, priority) = readerKindLocked(track, index: index)
            entry = launchLocked(key, priority: priority, rangeKind: rangeKind, origin: .reader)
        }
        guard var attached = entry else {
            lock.unlock()
            return .closed
        }
        attached.readers += 1
        inflight[key] = attached
        let fetch = attached.fetch
        lock.unlock()
        let subscription = fetch.subscribe(onEnd: { [weak self] in self?.readerDetached(key: key, fetch: fetch) })
        return .stream(subscription)
    }

    /// An uncached download of bytes no pinned range or segment covers (e.g. boxes after the last segment).
    func openGap(kind: MediaKind, range: ByteRange) -> UnitSource {
        lock.lock()
        guard !closed, let track = tracks[kind] else {
            lock.unlock()
            return .closed
        }
        let startup = track.warmEnd != range.start
        let fetch = SegmentFetch(key: nil, range: range)
        let job = FetchJob(fetch: fetch, kind: kind, handle: track.spec.handle,
                           priority: startup ? Self.readerStartupPriority : Self.readerPriority,
                           rangeKind: PrefetchPlanner.rangeKind(length: range.length, startup: startup),
                           accelerated: useAcceleratedLocked(track), segmentStart: nil, total: track.spec.total)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(job)
        }
        gapFetches[ObjectIdentifier(fetch)] = (fetch, task)
        lock.unlock()
        let subscription = fetch.subscribe(onEnd: { [weak self] in self?.gapDetached(fetch) })
        return .stream(subscription)
    }

    // MARK: Test / diagnostics hooks

    func debugCachedIndices(_ kind: MediaKind) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return tracks[kind].map { Array($0.cache.keys).sorted() } ?? []
    }

    /// In-flight segment index → number of attached readers.
    func debugInflight(_ kind: MediaKind) -> [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        var out: [Int: Int] = [:]
        for (key, entry) in inflight where key.kind == kind { out[key.index] = entry.readers }
        return out
    }

    func debugConsecutiveFailures(_ kind: MediaKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tracks[kind]?.consecutiveFailures ?? 0
    }

    /// Inserts bytes as if downloaded (tests).
    func debugInsert(_ kind: MediaKind, index: Int, data: Data) {
        let now = clock.nowMs()
        lock.lock()
        if let track = tracks[kind], track.cache[index] == nil {
            track.cache[index] = data
            cachedBytes += Int64(data.count)
            evictLocked(now: now)
        }
        lock.unlock()
    }

    // MARK: Internals (call with `lock` held unless noted)

    private func segmentListsLocked() -> [(kind: MediaKind, segments: [SidxSegment])] {
        order.compactMap { kind in tracks[kind].map { (kind: kind, segments: $0.segments) } }
    }

    private func useAcceleratedLocked(_ track: TrackState) -> Bool {
        track.spec.accelerate && track.consecutiveFailures < Self.failureLimit && accelerationAllowed()
    }

    /// Range kind + priority for a download a client request is waiting for.
    private func readerKindLocked(_ track: TrackState, index: Int) -> (BTRRangeKind, Int) {
        let segment = track.segments[index]
        let kind = track.spec.kind
        var startup: Bool
        if track.failedAtMs[index] != nil || planner.isStartup(kind: kind, index: index) {
            startup = true
        } else {
            let previous = index - 1
            let warm = (previous >= 0 && (track.cache[previous] != nil
                                            || inflight[SegmentKey(kind: kind, index: previous)] != nil))
                || track.warmEnd == segment.byteRange.start
            startup = !warm
        }
        return (PrefetchPlanner.rangeKind(length: segment.byteRange.length, startup: startup),
                startup ? Self.readerStartupPriority : Self.readerPriority)
    }

    @discardableResult
    private func launchLocked(_ key: SegmentKey, priority: Int, rangeKind: BTRRangeKind, origin: Origin) -> Inflight? {
        guard !closed, let track = tracks[key.kind], key.index >= 0, key.index < track.segments.count else { return nil }
        let segment = track.segments[key.index]
        let fetch = SegmentFetch(key: key, range: segment.byteRange)
        let job = FetchJob(fetch: fetch, kind: key.kind, handle: track.spec.handle, priority: priority,
                           rangeKind: rangeKind, accelerated: useAcceleratedLocked(track),
                           segmentStart: segment.startTime, total: track.spec.total)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(job)
        }
        let entry = Inflight(fetch: fetch, task: task, readers: 0, origin: origin)
        inflight[key] = entry
        return entry
    }

    private func replanLocked(now: Double) -> [Task<Void, Never>] {
        guard !closed else { return [] }
        let time = playhead.current(at: now)
        var inputs: [PrefetchPlanner.TrackInput] = []
        var used = cachedBytes
        var evictable: Int64 = 0
        for kind in order {
            guard let track = tracks[kind] else { continue }
            var reading: [Int: Bool] = [:]
            for (key, entry) in inflight where key.kind == kind {
                reading[key.index] = entry.readers > 0
                used += entry.fetch.range.length
            }
            for (index, data) in track.cache where track.segments[index].endTime < time - 30 {
                evictable += Int64(data.count)
            }
            inputs.append(PrefetchPlanner.TrackInput(kind: kind, segments: track.segments,
                                                     cached: Set(track.cache.keys), inflight: reading,
                                                     failedAtMs: track.failedAtMs))
        }
        let input = PrefetchPlanner.Input(nowMs: now, time: time, bufferedAhead: playhead.bufferedAhead,
                                          cacheFull: playhead.cacheFull, forwardSeconds: forwardSeconds(),
                                          budgetBytes: budgetBytes, usedBytes: used, evictableBytes: evictable,
                                          tracks: inputs)
        let plan = planner.plan(input)
        var cancelled: [Task<Void, Never>] = []
        for cancel in plan.cancels {
            let key = SegmentKey(kind: cancel.kind, index: cancel.index)
            // A fetch that already holds every byte is about to complete (its reader ended with the last byte):
            // let it land in the cache instead of throwing the bytes away.
            guard let entry = inflight[key], entry.readers == 0,
                  entry.fetch.receivedCount < entry.fetch.range.length else { continue }
            inflight[key] = nil
            entry.fetch.markCancelled()
            cancelled.append(entry.task)
        }
        for start in plan.starts {
            let key = SegmentKey(kind: start.kind, index: start.index)
            guard inflight[key] == nil, tracks[start.kind]?.cache[start.index] == nil else { continue }
            launchLocked(key, priority: start.priority, rangeKind: start.rangeKind, origin: .prefetch)
        }
        return cancelled
    }

    /// Over budget: drop segments that ended before playhead − 30 s (oldest first), then the farthest ahead.
    private func evictLocked(now: Double) {
        guard cachedBytes > budgetBytes else { return }
        let time = playhead.current(at: now)
        struct Candidate {
            var kind: MediaKind
            var index: Int
            var start: Double
            var end: Double
        }
        var behind: [Candidate] = []
        var rest: [Candidate] = []
        for (kind, track) in tracks {
            for index in track.cache.keys {
                let segment = track.segments[index]
                let candidate = Candidate(kind: kind, index: index, start: segment.startTime, end: segment.endTime)
                if segment.endTime < time - 30 { behind.append(candidate) } else { rest.append(candidate) }
            }
        }
        behind.sort { ($0.end, $0.kind.rawValue) < ($1.end, $1.kind.rawValue) }
        rest.sort { ($0.start, $0.kind.rawValue) > ($1.start, $1.kind.rawValue) }
        for candidate in behind + rest {
            guard cachedBytes > budgetBytes else { break }
            if let track = tracks[candidate.kind], let data = track.cache.removeValue(forKey: candidate.index) {
                cachedBytes -= Int64(data.count)
            }
        }
    }

    // MARK: Fetch execution (no lock held)

    private func run(_ job: FetchJob) async {
        let fetch = job.fetch
        let onBytes: (Data) async throws -> Void = { chunk in
            if Task.isCancelled || !fetch.append(chunk) { throw CancellationError() }
        }
        let deadline: (() -> Double?)? = job.segmentStart.map { start in
            { [weak self] in self?.deadlineMs(segmentStart: start) }
        }
        do {
            let total: Int64
            if job.accelerated {
                do {
                    total = try await downloader.download(fetch.range, track: job.handle, kind: job.rangeKind,
                                                          priority: job.priority, deadline: deadline, onBytes: onBytes)
                    noteAcceleratedOutcome(job.kind, success: true)
                } catch {
                    if Task.isCancelled || fetch.isCancelled || error is CancellationError { throw CancellationError() }
                    noteAcceleratedOutcome(job.kind, success: false)
                    // Per-request fallback: the plain single-connection path resumes after the verified prefix.
                    let received = fetch.receivedCount
                    if received >= fetch.range.length {
                        total = job.total
                    } else {
                        total = try await downloader.downloadDirect(
                            ByteRange(start: fetch.range.start + received, end: fetch.range.end),
                            track: job.handle, onBytes: onBytes)
                    }
                }
            } else {
                total = try await downloader.downloadDirect(fetch.range, track: job.handle, onBytes: onBytes)
            }
            let received = fetch.receivedCount
            guard received == fetch.range.length else {
                throw MediaProxyError.truncated(expected: fetch.range.length, received: received)
            }
            guard total == job.total else { throw MediaProxyError.totalMismatch(expected: job.total, got: total) }
            completed(job)
        } catch {
            failed(job, error: error)
        }
    }

    private func deadlineMs(segmentStart: Double) -> Double? {
        let now = clock.nowMs()
        lock.lock()
        let head = playhead
        let armed = planner.isArmed
        lock.unlock()
        let current = armed ? head.current(at: now) : 0
        let rate = max(0.25, head.rate == 0 ? 1 : abs(head.rate))
        return now + max(0, (segmentStart - current) * 1000 / rate)
    }

    private func noteAcceleratedOutcome(_ kind: MediaKind, success: Bool) {
        lock.lock()
        if let track = tracks[kind] {
            track.consecutiveFailures = success ? 0 : track.consecutiveFailures + 1
        }
        lock.unlock()
    }

    private func completed(_ job: FetchJob) {
        let now = clock.nowMs()
        let fetch = job.fetch
        let data = fetch.data
        lock.lock()
        if let key = fetch.key {
            if let entry = inflight[key], entry.fetch === fetch {
                inflight[key] = nil
                if !closed, let track = tracks[key.kind], track.cache[key.index] == nil {
                    track.cache[key.index] = data
                    cachedBytes += Int64(data.count)
                }
            }
            tracks[key.kind]?.failedAtMs[key.index] = nil
            planner.noteCompleted(kind: key.kind, index: key.index, bytes: Int64(data.count), nowMs: now)
        } else {
            gapFetches[ObjectIdentifier(fetch)] = nil
        }
        if let track = tracks[job.kind], track.warmEnd != nil || fetch.range.length > Self.warmThresholdBytes {
            track.warmEnd = fetch.range.end + 1
        }
        evictLocked(now: now)
        let cancels = replanLocked(now: now)
        lock.unlock()
        fetch.finish()
        for task in cancels { task.cancel() }
    }

    private func failed(_ job: FetchJob, error: Error) {
        let now = clock.nowMs()
        let fetch = job.fetch
        lock.lock()
        let cancelled = closed || fetch.isCancelled || error is CancellationError
        if let key = fetch.key {
            if let entry = inflight[key], entry.fetch === fetch { inflight[key] = nil }
            if !cancelled { tracks[key.kind]?.failedAtMs[key.index] = now }
        } else {
            gapFetches[ObjectIdentifier(fetch)] = nil
        }
        if !cancelled { tracks[job.kind]?.warmEnd = nil }
        let cancels = cancelled ? [] : replanLocked(now: now)
        lock.unlock()
        fetch.fail(cancelled ? CancellationError() : error)
        for task in cancels { task.cancel() }
        if !cancelled { onHardFailure?() }
    }

    private func readerDetached(key: SegmentKey, fetch: SegmentFetch) {
        let now = clock.nowMs()
        lock.lock()
        if var entry = inflight[key], entry.fetch === fetch {
            entry.readers = max(0, entry.readers - 1)
            inflight[key] = entry
        }
        let cancels = replanLocked(now: now)
        lock.unlock()
        for task in cancels { task.cancel() }
    }

    private func gapDetached(_ fetch: SegmentFetch) {
        lock.lock()
        let entry = gapFetches.removeValue(forKey: ObjectIdentifier(fetch))
        lock.unlock()
        if let entry, entry.fetch.isRunning {
            entry.fetch.markCancelled()
            entry.task.cancel()
        }
    }
}

// MARK: - Reader

/// Produces the bytes of one client range in order: pinned bytes, cached segments, joined downloads and gaps.
final class MediaRangeReader: LocalProxyBodySource {
    enum Piece {
        /// `data[lower..<upper]` (offsets from `data.startIndex`).
        case bytes(Data, lower: Int, upper: Int)
        /// Bytes `need` of the segment whose first byte is at file offset `unitStart`.
        case segment(index: Int, unitStart: Int64, need: ByteRange)
        /// Bytes no segment or pinned range covers.
        case gap(ByteRange)
    }

    static let maxChunk = 256 * 1024

    private final class Active {
        let subscription: SegmentSubscription
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        var cursor: Int64
        let need: ByteRange

        init(subscription: SegmentSubscription, cursor: Int64, need: ByteRange) {
            self.subscription = subscription
            iterator = subscription.stream.makeAsyncIterator()
            self.cursor = cursor
            self.need = need
        }
    }

    let kind: MediaKind
    let pieces: [Piece]
    private let store: SegmentStore
    private var position = 0
    private var pending: Data?
    private var pendingLower = 0
    private var pendingUpper = 0
    private let lock = NSLock()
    private var active: Active?
    private var cancelled = false

    init(store: SegmentStore, kind: MediaKind, pieces: [Piece]) {
        self.store = store
        self.kind = kind
        self.pieces = pieces
    }

    deinit {
        active?.subscription.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = active
        active = nil
        lock.unlock()
        current?.subscription.cancel()
    }

    private func setActive(_ value: Active) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            value.subscription.cancel()
            throw CancellationError()
        }
        active = value
        lock.unlock()
    }

    private func currentActive() -> Active? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func endActive() {
        lock.lock()
        let current = active
        active = nil
        lock.unlock()
        current?.subscription.cancel()
    }

    private func setPending(_ data: Data, lower: Int, upper: Int) {
        pending = data
        pendingLower = lower
        pendingUpper = upper
    }

    func nextChunk() async throws -> Data? {
        while true {
            if isCancelled || Task.isCancelled { throw CancellationError() }
            if let data = pending {
                if pendingLower < pendingUpper {
                    let count = min(Self.maxChunk, pendingUpper - pendingLower)
                    let start = data.startIndex + pendingLower
                    let out = (pendingLower == 0 && count == data.count) ? data : data.subdata(in: start..<(start + count))
                    pendingLower += count
                    if pendingLower >= pendingUpper { pending = nil }
                    return out
                }
                pending = nil
            }
            if let current = currentActive() {
                guard let chunk = try await current.iterator.next() else {
                    if isCancelled || Task.isCancelled { throw CancellationError() }
                    let reached = current.cursor
                    endActive()
                    if reached <= current.need.end {
                        throw MediaProxyError.truncated(expected: current.need.length,
                                                        received: max(0, reached - current.need.start))
                    }
                    position += 1
                    continue
                }
                let chunkStart = current.cursor
                current.cursor += Int64(chunk.count)
                let lower = max(chunkStart, current.need.start)
                let upper = min(current.cursor - 1, current.need.end)
                if current.cursor > current.need.end {
                    endActive()
                    position += 1
                }
                if upper >= lower {
                    let from = Int(lower - chunkStart)
                    setPending(chunk, lower: from, upper: from + Int(upper - lower + 1))
                }
                continue
            }
            guard position < pieces.count else { return nil }
            switch pieces[position] {
            case let .bytes(data, lower, upper):
                position += 1
                setPending(data, lower: lower, upper: upper)
            case let .segment(index, unitStart, need):
                switch store.openSegment(kind: kind, index: index) {
                case .bytes(let data):
                    let lower = Int(need.start - unitStart)
                    let upper = lower + Int(need.length)
                    guard lower >= 0, upper <= data.count else {
                        throw MediaProxyError.truncated(expected: need.length, received: Int64(data.count))
                    }
                    position += 1
                    setPending(data, lower: lower, upper: upper)
                case .stream(let subscription):
                    try setActive(Active(subscription: subscription, cursor: unitStart, need: need))
                case .closed:
                    throw MediaProxyError.sessionClosed
                }
            case let .gap(range):
                switch store.openGap(kind: kind, range: range) {
                case .stream(let subscription):
                    try setActive(Active(subscription: subscription, cursor: range.start, need: range))
                case .bytes(let data):
                    position += 1
                    setPending(data, lower: 0, upper: min(data.count, Int(range.length)))
                case .closed:
                    throw MediaProxyError.sessionClosed
                }
            }
        }
    }
}
