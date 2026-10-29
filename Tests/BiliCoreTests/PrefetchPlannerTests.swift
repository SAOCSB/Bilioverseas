import XCTest
@testable import BiliCore

final class PrefetchPlannerTests: XCTestCase {
    typealias Planner = PrefetchPlanner

    /// `count` segments of `seconds` each, 1 MB apiece.
    private func segments(_ count: Int, seconds: Double = 2, bytes: Int64 = 1_000_000) -> [SidxSegment] {
        (0..<count).map { i in
            SidxSegment(index: i, byteRange: ByteRange(start: 1000 + Int64(i) * bytes, end: 1000 + Int64(i + 1) * bytes - 1),
                        startTime: Double(i) * seconds, duration: seconds)
        }
    }

    private func input(time: Double = 0, buffered: Double = 0, cacheFull: Bool = false, forward: Double = 60,
                       budget: Int64 = 1 << 40, used: Int64 = 0, tracks: [Planner.TrackInput],
                       now: Double = 1000) -> Planner.Input {
        Planner.Input(nowMs: now, time: time, bufferedAhead: buffered, cacheFull: cacheFull, forwardSeconds: forward,
                      budgetBytes: budget, usedBytes: used, evictableBytes: 0, tracks: tracks)
    }

    private func started(_ planner: inout Planner, at time: Double, video: [SidxSegment], audio: [SidxSegment]) {
        planner.reset(time: time, nowMs: 1000, tracks: [(.video, video), (.audio, audio)])
        let vi = SidxIndex.segmentIndex(in: video, at: time)
        let ai = SidxIndex.segmentIndex(in: audio, at: time)
        planner.noteCompleted(kind: .video, index: vi, bytes: video[vi].byteRange.length, nowMs: 2000)
        planner.noteCompleted(kind: .audio, index: ai, bytes: audio[ai].byteRange.length, nowMs: 2000)
    }

    func testUnarmedNeverPrefetchesAndDropsUnreadDownloads() {
        var planner = Planner()
        let plan = planner.plan(input(tracks: [.init(kind: .video, segments: segments(10), inflight: [3: false, 4: true])]))
        XCTAssertEqual(plan.starts, [])
        XCTAssertEqual(plan.cancels, [Planner.Cancel(kind: .video, index: 3)])
    }

    func testStartupSegmentThenFollowup() {
        let v = segments(30)
        let a = segments(30)
        var planner = Planner()
        planner.reset(time: 10, nowMs: 1000, tracks: [(.video, v), (.audio, a)])
        let first = planner.plan(input(time: 10, tracks: [.init(kind: .video, segments: v), .init(kind: .audio, segments: a)]))
        XCTAssertEqual(first.starts, [
            .init(kind: .video, index: 5, priority: 120, rangeKind: .startup),
            .init(kind: .audio, index: 5, priority: 120, rangeKind: .startup),
        ])
        XCTAssertTrue(planner.isStartup(kind: .video, index: 5))
        // Both startup segments on their way → the first follow-up per track at 70, and nothing more yet.
        let second = planner.plan(input(time: 10, tracks: [.init(kind: .video, segments: v, inflight: [5: false]),
                                                           .init(kind: .audio, segments: a, inflight: [5: true])]))
        XCTAssertEqual(second.starts, [
            .init(kind: .video, index: 6, priority: 70, rangeKind: .ordinary),
            .init(kind: .audio, index: 6, priority: 70, rangeKind: .ordinary),
        ])
        XCTAssertEqual(second.cancels, [])
        let third = planner.plan(input(time: 10, tracks: [.init(kind: .video, segments: v, inflight: [5: false, 6: false]),
                                                          .init(kind: .audio, segments: a, inflight: [5: true, 6: false])]))
        XCTAssertEqual(third.starts, [])
    }

    func testStartupTargetMeasuredOnce() {
        let v = segments(10, seconds: 2, bytes: 500_000)
        let a = segments(10, seconds: 2, bytes: 100_000)
        var planner = Planner(videoHeight: 1080)
        planner.reset(time: 0, nowMs: 0, tracks: [(.video, v), (.audio, a)])
        planner.noteCompleted(kind: .video, index: 0, bytes: 500_000, nowMs: 500)
        XCTAssertNil(planner.startupTargetSeconds)
        // 600 KB in 1 s against 300 KB/s needed → ratio 2 → 4 s.
        planner.noteCompleted(kind: .audio, index: 0, bytes: 100_000, nowMs: 1000)
        XCTAssertEqual(planner.startupTargetSeconds, 4)
        planner.reset(time: 10, nowMs: 5000, tracks: [(.video, v), (.audio, a)])
        planner.noteCompleted(kind: .video, index: 5, bytes: 500_000, nowMs: 100_000)
        planner.noteCompleted(kind: .audio, index: 5, bytes: 100_000, nowMs: 100_000)
        XCTAssertEqual(planner.startupTargetSeconds, 4, "measured once per session")
        XCTAssertEqual(Planner.startupTarget(throughput: 10, required: 1, videoHeight: 0), 2.5)
        XCTAssertEqual(Planner.startupTarget(throughput: 1.3, required: 1, videoHeight: 0), 6)
        XCTAssertEqual(Planner.startupTarget(throughput: 1, required: 1, videoHeight: 0), 8)
        XCTAssertEqual(Planner.startupTarget(throughput: 1.5, required: 1, videoHeight: 2160), 8)
        XCTAssertEqual(Planner.startupTarget(throughput: 0, required: 0, videoHeight: 0), 6)
    }

    func testWindowAndPrioritiesOnceStarted() {
        let v = segments(30)
        let a = segments(30)
        var planner = Planner()
        started(&planner, at: 0, video: v, audio: a)
        let plan = planner.plan(input(time: 0.5, tracks: [.init(kind: .video, segments: v, cached: [0]),
                                                          .init(kind: .audio, segments: a, cached: [0])]))
        XCTAssertEqual(plan.starts, [
            // video window 3 from the first uncached segment: follow-up 70, then 55 - 5·offset
            .init(kind: .video, index: 1, priority: 70, rangeKind: .ordinary),
            .init(kind: .video, index: 2, priority: 50, rangeKind: .ordinary),
            .init(kind: .video, index: 3, priority: 45, rangeKind: .ordinary),
            // audio window 4
            .init(kind: .audio, index: 1, priority: 70, rangeKind: .ordinary),
            .init(kind: .audio, index: 2, priority: 50, rangeKind: .ordinary),
            .init(kind: .audio, index: 3, priority: 45, rangeKind: .ordinary),
            .init(kind: .audio, index: 4, priority: 40, rangeKind: .ordinary),
        ])
        // Further on: the window starts after what AVPlayer already buffered; in-flight segments hold their slot.
        let later = planner.plan(input(time: 20, buffered: 6, tracks: [
            .init(kind: .video, segments: v, inflight: [13: true]),
            .init(kind: .audio, segments: a, cached: [13, 15]),
        ]))
        XCTAssertEqual(later.starts, [
            .init(kind: .video, index: 14, priority: 50, rangeKind: .ordinary),
            .init(kind: .video, index: 15, priority: 45, rangeKind: .ordinary),
            .init(kind: .audio, index: 14, priority: 55, rangeKind: .ordinary),
            .init(kind: .audio, index: 16, priority: 45, rangeKind: .ordinary),
            .init(kind: .audio, index: 17, priority: 40, rangeKind: .ordinary),
        ])
        XCTAssertEqual(Planner.windowPriority(offset: 10), 30)
    }

    func testReservePriorityWhenAVPlayerBufferIsFull() {
        let v = segments(30)
        var planner = Planner()
        planner.reset(time: 0, nowMs: 1000, tracks: [(.video, v)])
        planner.noteCompleted(kind: .video, index: 0, bytes: 1, nowMs: 1000)
        let plan = planner.plan(input(time: 0, buffered: 20, cacheFull: true,
                                      tracks: [.init(kind: .video, segments: v, inflight: [1: false])]))
        XCTAssertEqual(plan.starts.map(\.priority), [20, 20, 20])
        XCTAssertEqual(plan.starts.map(\.index), [10, 11, 12])
    }

    func testForwardLimitAndBudget() {
        let v = segments(30)
        var planner = Planner()
        planner.reset(time: 0, nowMs: 1000, tracks: [(.video, v)])
        planner.noteCompleted(kind: .video, index: 0, bytes: 1, nowMs: 1000)
        var plan = planner.plan(input(time: 0, forward: 4, tracks: [.init(kind: .video, segments: v, cached: [0])]))
        XCTAssertEqual(plan.starts.map(\.index), [1], "segment 2 starts at 4 s = the forward limit")
        planner = Planner()
        planner.reset(time: 0, nowMs: 1000, tracks: [(.video, v)])
        planner.noteCompleted(kind: .video, index: 0, bytes: 1, nowMs: 1000)
        plan = planner.plan(input(time: 0, budget: 3_500_000, used: 1_000_000,
                                  tracks: [.init(kind: .video, segments: v, cached: [0])]))
        XCTAssertEqual(plan.starts.map(\.index), [1, 2], "a third MB would exceed the budget")
    }

    func testSeekCancelsFarUnreadPrefetchesOnly() {
        let v = segments(300)
        var planner = Planner()
        started(&planner, at: 20, video: v, audio: segments(300))
        planner.reset(time: 300, nowMs: 5000, tracks: [(.video, v)])
        let plan = planner.plan(input(time: 300, tracks: [
            .init(kind: .video, segments: v, inflight: [10: false, 11: false, 12: true, 150: false, 160: false]),
        ], now: 5000))
        XCTAssertEqual(plan.cancels, [.init(kind: .video, index: 10), .init(kind: .video, index: 11)])
        // 150 (300 s) is the new startup segment and already in flight (160 at 320 s is inside the window), so the
        // first follow-up goes out.
        XCTAssertEqual(plan.starts, [.init(kind: .video, index: 151, priority: 70, rangeKind: .ordinary)])
        let fresh = planner.plan(input(time: 300, tracks: [.init(kind: .video, segments: v, inflight: [12: true])],
                                       now: 5000))
        XCTAssertEqual(fresh.starts, [.init(kind: .video, index: 150, priority: 120, rangeKind: .startup)])
        // Far ahead of the window also goes: forward 60 + 30 → 150 + 45 segments.
        let ahead = planner.plan(input(time: 300, tracks: [.init(kind: .video, segments: v, inflight: [150: false, 196: false])],
                                       now: 5000))
        XCTAssertEqual(ahead.cancels, [.init(kind: .video, index: 196)])
    }

    func testStartupDoneWhenAVPlayerAlreadyBufferedOrTimedOut() {
        let v = segments(30)
        var planner = Planner()
        planner.reset(time: 0, nowMs: 1000, tracks: [(.video, v)])
        _ = planner.plan(input(time: 0, buffered: 3, tracks: [.init(kind: .video, segments: v)]))
        XCTAssertTrue(planner.isStarted(.video))
        planner.reset(time: 10, nowMs: 1000, tracks: [(.video, v)])
        _ = planner.plan(input(time: 10, tracks: [.init(kind: .video, segments: v, inflight: [5: true])], now: 22_000))
        XCTAssertTrue(planner.isStarted(.video))
    }

    func testRecentlyFailedSegmentIsNotPrefetched() {
        let v = segments(30)
        var planner = Planner()
        planner.reset(time: 0, nowMs: 1000, tracks: [(.video, v)])
        let plan = planner.plan(input(time: 0, tracks: [.init(kind: .video, segments: v, failedAtMs: [0: 900])], now: 1000))
        XCTAssertEqual(plan.starts, [])
        let retry = planner.plan(input(time: 0, tracks: [.init(kind: .video, segments: v, failedAtMs: [0: 900])], now: 4000))
        XCTAssertEqual(retry.starts.map(\.index), [0])
    }

    func testSmallRangesUseMetaKind() {
        XCTAssertEqual(Planner.rangeKind(length: 64 * 1024, startup: true), .meta)
        XCTAssertEqual(Planner.rangeKind(length: 64 * 1024 + 1, startup: true), .startup)
        XCTAssertEqual(Planner.rangeKind(length: 1 << 20, startup: false), .ordinary)
    }
}
