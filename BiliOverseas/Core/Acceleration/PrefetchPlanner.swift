import Foundation

// Prefetch policy for the local proxy (BTR native-mse-player "全接管" scheduler, btr-core §9, adapted to AVPlayer):
// AVPlayer owns its buffer and requests segments itself; the planner keeps the next few segments in flight ahead of
// those requests so they hit the proxy's cache / an in-flight download instead of starting cold.
//
// Pure value type: the caller (SegmentStore) feeds it a snapshot and applies the plan.
//
// - Startup (after the first playhead report, and after every seek outside AVPlayer's buffer): only the startup
//   segment (priority 120, `.startup` range kind) per track; once every track's startup segment is scheduled the
//   first follow-up goes at priority 70. A track counts as started when its startup segment completed (or is
//   cached, or AVPlayer already buffered past it, or 20 s passed).
// - Started tracks keep a positional window of 3 (video) / 4 (audio) segments from the first segment AVPlayer has
//   not buffered yet, priorities 55 − 5·offset (≥ 30), 20 ("reserve") while AVPlayer reports its own buffer full,
//   up to `forwardSeconds` ahead of the playhead and within the cache budget.
// - Fetches nobody reads any more are cancelled when they leave [playhead − 5 s, playhead + forward + 30 s).
// - Startup buffer target (btr-core §9.3) is measured once, when the first startup segments complete.

struct PrefetchPlanner {
    static let videoWindow = 3
    static let audioWindow = 4
    static let startupPriority = 120
    static let followupPriority = 70
    static let reservePriority = 20
    static let keepBehindSeconds = 5.0
    static let keepBeyondSeconds = 30.0
    /// A segment whose download failed is not prefetched again for this long (AVPlayer may still ask for it).
    static let failureRetryMs = 3_000.0
    static let startupProtectionMs = 20_000.0
    /// Ranges this small are downloaded as one raced request (`.meta`), like BTR desktop's small-request rule.
    static let smallRangeBytes: Int64 = 64 * 1024

    struct TrackInput {
        var kind: MediaKind
        var segments: [SidxSegment]
        var cached: Set<Int> = []
        /// In-flight segment downloads → whether a client request is reading it.
        var inflight: [Int: Bool] = [:]
        /// Monotonic ms of the last failed download per segment.
        var failedAtMs: [Int: Double] = [:]
    }

    struct Input {
        var nowMs: Double
        /// Playhead (seconds).
        var time: Double
        /// AVPlayer's buffered seconds ahead of the playhead.
        var bufferedAhead: Double = 0
        /// AVPlayer stopped loading because its own forward buffer is full.
        var cacheFull: Bool = false
        var forwardSeconds: Double
        var budgetBytes: Int64
        /// Cached + in-flight bytes.
        var usedBytes: Int64 = 0
        /// Cached bytes behind `time − 30 s` (evicted first, so they do not block prefetching).
        var evictableBytes: Int64 = 0
        var tracks: [TrackInput]
    }

    struct Start: Equatable {
        var kind: MediaKind
        var index: Int
        var priority: Int
        var rangeKind: BTRRangeKind
    }

    struct Cancel: Hashable {
        var kind: MediaKind
        var index: Int
    }

    struct Plan: Equatable {
        var starts: [Start] = []
        var cancels: [Cancel] = []
    }

    struct TrackPhase: Equatable {
        var startupIndex: Int
        var startupDone = false
        var followupLaunched = false
        var startupBytes: Int64 = 0
        /// Bytes per second the startup segment plays at (length / duration).
        var mediaBytesPerSecond: Double = 0
    }

    private(set) var phases: [MediaKind: TrackPhase] = [:]
    private(set) var startupStartedAtMs: Double = 0
    /// Seconds AVPlayer should have ahead before (re)starting, measured once per session (2.5 … 10).
    private(set) var startupTargetSeconds: Double?
    /// Video height, for the 4K rule of the startup target.
    var videoHeight: Int = 0

    init(videoHeight: Int = 0) {
        self.videoHeight = videoHeight
    }

    /// False until the first `reset` (the playhead is unknown before the player reports it).
    var isArmed: Bool { !phases.isEmpty }

    /// Start of playback or a seek outside the buffered data: every track starts over at `time`.
    mutating func reset(time: Double, nowMs: Double, tracks: [(kind: MediaKind, segments: [SidxSegment])]) {
        phases = [:]
        for track in tracks where !track.segments.isEmpty {
            let index = SidxIndex.segmentIndex(in: track.segments, at: time)
            let segment = track.segments[index]
            phases[track.kind] = TrackPhase(
                startupIndex: index,
                mediaBytesPerSecond: segment.duration > 0 ? Double(segment.byteRange.length) / segment.duration : 0)
        }
        startupStartedAtMs = nowMs
    }

    func isStartup(kind: MediaKind, index: Int) -> Bool {
        guard let phase = phases[kind] else { return false }
        return !phase.startupDone && phase.startupIndex == index
    }

    func isStarted(_ kind: MediaKind) -> Bool { phases[kind]?.startupDone ?? false }

    /// A segment download completed (any origin).
    mutating func noteCompleted(kind: MediaKind, index: Int, bytes: Int64, nowMs: Double) {
        guard var phase = phases[kind], !phase.startupDone, phase.startupIndex == index else { return }
        phase.startupDone = true
        phase.startupBytes = bytes
        phases[kind] = phase
        measureStartupTargetIfReady(nowMs: nowMs)
    }

    /// btr-core §9.3: compares the startup throughput with the bytes per second playback needs.
    private mutating func measureStartupTargetIfReady(nowMs: Double) {
        guard startupTargetSeconds == nil, !phases.isEmpty, phases.values.allSatisfy(\.startupDone) else { return }
        let elapsed = max(0.25, (nowMs - startupStartedAtMs) / 1000)
        let bytes = phases.values.reduce(Int64(0)) { $0 + $1.startupBytes }
        let throughput = Double(bytes) / elapsed
        let required = phases.values.reduce(0.0) { $0 + $1.mediaBytesPerSecond }
        startupTargetSeconds = Self.startupTarget(throughput: throughput, required: required, videoHeight: videoHeight)
    }

    static func startupTarget(throughput: Double, required: Double, videoHeight: Int) -> Double {
        let ratio = required > 0 ? throughput / required : 0
        var target: Double = ratio >= 3 ? 2.5 : ratio >= 1.8 ? 4 : ratio >= 1.25 ? 6 : ratio > 0 ? 8 : 6
        if videoHeight >= 2160 && ratio < 1.8 { target = max(target, 8) }
        return min(10, max(2.5, target))
    }

    /// Range kind of a download (`.startup` only for the first range after start / seek / retry).
    static func rangeKind(length: Int64, startup: Bool) -> BTRRangeKind {
        if length <= smallRangeBytes { return .meta }
        return startup ? .startup : .ordinary
    }

    static func windowPriority(offset: Int) -> Int { max(30, 55 - 5 * offset) }

    static func windowSize(_ kind: MediaKind) -> Int { kind == .video ? videoWindow : audioWindow }

    mutating func plan(_ input: Input) -> Plan {
        var plan = Plan()
        guard isArmed else {
            // Playhead unknown: never prefetch, and drop downloads nobody reads.
            for track in input.tracks {
                for (index, reading) in track.inflight where !reading {
                    plan.cancels.append(Cancel(kind: track.kind, index: index))
                }
            }
            plan.cancels.sort { ($0.kind.rawValue, $0.index) < ($1.kind.rawValue, $1.index) }
            return plan
        }
        let time = input.time
        let forward = max(0, input.forwardSeconds)

        // 1. Cancel unread downloads far from the playhead.
        var cancelled = Set<Cancel>()
        for track in input.tracks {
            for (index, reading) in track.inflight where !reading && index < track.segments.count {
                let segment = track.segments[index]
                if segment.endTime <= time - Self.keepBehindSeconds
                    || segment.startTime >= time + forward + Self.keepBeyondSeconds {
                    cancelled.insert(Cancel(kind: track.kind, index: index))
                }
            }
        }
        plan.cancels = cancelled.sorted { ($0.kind.rawValue, $0.index) < ($1.kind.rawValue, $1.index) }

        // 2. Startup bookkeeping: a track whose startup segment AVPlayer already has (or that has waited long
        //    enough) is started even if the proxy never downloaded that segment itself.
        for track in input.tracks {
            guard var phase = phases[track.kind], !phase.startupDone,
                  phase.startupIndex < track.segments.count else { continue }
            let segment = track.segments[phase.startupIndex]
            if track.cached.contains(phase.startupIndex)
                || time + max(0, input.bufferedAhead) >= segment.endTime
                || input.nowMs - startupStartedAtMs >= Self.startupProtectionMs {
                phase.startupDone = true
                phases[track.kind] = phase
            }
        }
        let allStartupScheduled = input.tracks.allSatisfy { track in
            guard let phase = phases[track.kind] else { return true }
            return phase.startupDone || track.cached.contains(phase.startupIndex)
                || track.inflight[phase.startupIndex] != nil
        }

        // 3. Windows.
        var used = max(0, input.usedBytes - input.evictableBytes)
        for track in input.tracks {
            guard var phase = phases[track.kind], !track.segments.isEmpty else { continue }
            let segments = track.segments
            let started = phase.startupDone
            let window = started ? Self.windowSize(track.kind) : 1
            func busy(_ index: Int) -> Bool { track.cached.contains(index) || track.inflight[index] != nil }
            func recentlyFailed(_ index: Int) -> Bool {
                guard let at = track.failedAtMs[index] else { return false }
                return input.nowMs - at < Self.failureRetryMs
            }

            var next = started
                ? SidxIndex.segmentIndex(in: segments, at: time + max(0, input.bufferedAhead))
                : phase.startupIndex
            while next < segments.count && track.cached.contains(next) { next += 1 }

            var offset = 0
            var index = next
            while index < segments.count && offset < window {
                defer {
                    index += 1
                    offset += 1
                }
                let segment = segments[index]
                let isStartup = !started && index == phase.startupIndex
                if !isStartup && segment.startTime - time >= forward { break }
                if index == phase.startupIndex + 1 && busy(index) { phase.followupLaunched = true }
                if busy(index) || recentlyFailed(index) { continue }
                if !isStartup && used + segment.byteRange.length > input.budgetBytes { break }
                let priority: Int
                if isStartup {
                    priority = Self.startupPriority
                } else if index == phase.startupIndex + 1 && !phase.followupLaunched {
                    priority = Self.followupPriority
                    phase.followupLaunched = true
                } else if input.cacheFull {
                    priority = Self.reservePriority
                } else {
                    priority = Self.windowPriority(offset: offset)
                }
                plan.starts.append(Start(kind: track.kind, index: index, priority: priority,
                                         rangeKind: Self.rangeKind(length: segment.byteRange.length, startup: isStartup)))
                used += segment.byteRange.length
            }

            // First follow-up once every track's startup segment is on its way (BTR maybeStartStartupPrefetch).
            if !started && allStartupScheduled && !phase.followupLaunched {
                let followup = phase.startupIndex + 1
                if followup < segments.count {
                    let segment = segments[followup]
                    if busy(followup) {
                        phase.followupLaunched = true
                    } else if !recentlyFailed(followup) && segment.startTime - time < max(forward, 1)
                                && used + segment.byteRange.length <= input.budgetBytes {
                        plan.starts.append(Start(kind: track.kind, index: followup, priority: Self.followupPriority,
                                                 rangeKind: Self.rangeKind(length: segment.byteRange.length,
                                                                           startup: false)))
                        used += segment.byteRange.length
                        phase.followupLaunched = true
                    }
                } else {
                    phase.followupLaunched = true
                }
            }
            phases[track.kind] = phase
        }
        return plan
    }
}
