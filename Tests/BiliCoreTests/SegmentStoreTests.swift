import XCTest
@testable import BiliCore

final class SegmentStoreTests: XCTestCase {
    private func makeStore(_ file: EngineSyntheticMP4.File, downloader: EngineFakeDownloader,
                           budget: Int64 = 1 << 30, accelerate: Bool = true, forward: Double = 60,
                           clock: EngineTestClock = EngineTestClock()) throws -> SegmentStore {
        let indexData = file.data.subdata(in: Int(file.indexRange.start)..<Int(file.indexRange.end + 1))
        let sidx = try SidxParser.parse(indexData, absoluteStart: file.indexRange.start)
        let meta = ByteRange(start: 0, end: file.indexRange.end)
        let handle = downloader.makeTrack(kind: .video, urls: ["https://upos-sz-mirrorali.bilivideo.com/v.m4s"],
                                          routeKey: "BVtest:p1")
        let track = SegmentStoreTrack(kind: .video, handle: handle, total: Int64(file.data.count),
                                      pinned: [PinnedBytes(range: meta, data: file.data.subdata(in: 0..<Int(meta.end + 1)))],
                                      segments: sidx.segments, accelerate: accelerate)
        return SegmentStore(tracks: [track], downloader: downloader, clock: clock, budgetBytes: budget,
                            forwardSeconds: { forward })
    }

    private func slice(_ file: EngineSyntheticMP4.File, _ range: ByteRange) -> Data {
        file.data.subdata(in: Int(range.start)..<Int(range.end + 1))
    }

    private func calls(_ d: EngineFakeDownloader, _ range: ByteRange) -> [EngineFakeDownloader.Call] {
        d.calls.filter { $0.range == range }
    }

    func testJoinInFlightNeverDownloadsTwice() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [100_000, 80_000, 70_000], durations: [2000, 2000, 2000])
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let store = try makeStore(file, downloader: downloader)
        let seg = file.segments[1]
        let inner = ByteRange(start: seg.start + 10, end: seg.end - 10)
        let r1 = try XCTUnwrap(store.reader(kind: .video, range: seg))
        let r2 = try XCTUnwrap(store.reader(kind: .video, range: inner))
        let a = Task { try await engineDrain(r1) }
        let one = await engineEventually { store.debugInflight(.video)[1] == 1 }
        XCTAssertTrue(one)
        let b = Task { try await engineDrain(r2) }
        let joined = await engineEventually { store.debugInflight(.video)[1] == 2 }
        XCTAssertTrue(joined, "the second request attaches to the running download")
        gate.open()
        let bytesA = try await a.value
        let bytesB = try await b.value
        XCTAssertEqual(bytesA, slice(file, seg))
        XCTAssertEqual(bytesB, slice(file, inner))
        XCTAssertEqual(calls(downloader, seg).count, 1)
        XCTAssertEqual(downloader.calls.count, 1)
        XCTAssertEqual(calls(downloader, seg).first?.rangeKind, .startup, "first range after start")
        XCTAssertEqual(calls(downloader, seg).first?.priority, 120)
        XCTAssertEqual(store.debugCachedIndices(.video), [1])
        // Later requests come from memory.
        let r3 = try XCTUnwrap(store.reader(kind: .video, range: seg))
        let bytesC = try await engineDrain(r3)
        XCTAssertEqual(bytesC, slice(file, seg))
        XCTAssertEqual(downloader.calls.count, 1)
        store.close()
    }

    func testRequestJoinsPrefetchStartedByPlanner() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [100_000, 90_000, 80_000], durations: [2000, 2000, 2000])
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let store = try makeStore(file, downloader: downloader)
        store.updatePlayback(time: 0, rate: 1, playing: false, bufferedAhead: 0, cacheFull: false)
        let prefetched = await engineEventually { store.debugInflight(.video)[0] != nil }
        XCTAssertTrue(prefetched, "planner starts the startup segment")
        let called = await engineEventually { !self.calls(downloader, file.segments[0]).isEmpty }
        XCTAssertTrue(called)
        XCTAssertEqual(calls(downloader, file.segments[0]).first?.rangeKind, .startup)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[0]))
        let task = Task { try await engineDrain(reader) }
        let joined = await engineEventually { store.debugInflight(.video)[0] == 1 }
        XCTAssertTrue(joined)
        gate.open()
        let bytes = try await task.value
        XCTAssertEqual(bytes, slice(file, file.segments[0]))
        XCTAssertEqual(calls(downloader, file.segments[0]).count, 1)
        store.close()
    }

    func testWholeFileFromPinnedSegmentsAndTrailingGap() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [70_000, 66_000, 90_000], durations: [2000, 2000, 1000],
                                           trailing: 500)
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let store = try makeStore(file, downloader: downloader)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: ByteRange(start: 0, end: Int64(file.data.count) - 1)))
        let bytes = try await engineDrain(reader)
        XCTAssertEqual(bytes, file.data)
        // A reader ends with its last byte; the download's bookkeeping (cache insert) follows right after.
        let allCached = await engineEventually { store.debugCachedIndices(.video) == [0, 1, 2] }
        XCTAssertTrue(allCached, "\(store.debugCachedIndices(.video))")
        // The trailing box is fetched once as an uncached range.
        let trailing = ByteRange(start: file.segments[2].end + 1, end: Int64(file.data.count) - 1)
        XCTAssertEqual(calls(downloader, trailing).count, 1)
        XCTAssertEqual(calls(downloader, trailing).first?.rangeKind, .meta)
        // The init range comes from memory.
        let initReader = try XCTUnwrap(store.reader(kind: .video, range: file.initRange))
        let initBytes = try await engineDrain(initReader)
        XCTAssertEqual(initBytes, slice(file, file.initRange))
        XCTAssertNil(store.reader(kind: .video, range: ByteRange(start: 0, end: Int64(file.data.count))))
        XCTAssertNil(store.reader(kind: .audio, range: ByteRange(start: 0, end: 1)))
        store.close()
    }

    func testEvictionBehindPlayheadFirstThenFarthestAhead() throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 100_000, count: 10),
                                           durations: Array(repeating: 20_000, count: 10))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        downloader.gate = EngineAsyncGate() // never opens: planner downloads stay pending
        let store = try makeStore(file, downloader: downloader, budget: 350_000)
        store.seek(to: 100, outsideBuffer: true)
        let blob = Data(count: 100_000)
        for i in [0, 1, 2] { store.debugInsert(.video, index: i, data: blob) }
        XCTAssertEqual(store.debugCachedIndices(.video), [0, 1, 2])
        store.debugInsert(.video, index: 9, data: blob)
        XCTAssertEqual(store.debugCachedIndices(.video), [1, 2, 9], "oldest segment behind playhead − 30 s goes first")
        store.debugInsert(.video, index: 8, data: blob)
        store.debugInsert(.video, index: 6, data: blob)
        XCTAssertEqual(store.debugCachedIndices(.video), [6, 8, 9])
        store.debugInsert(.video, index: 7, data: blob)
        XCTAssertEqual(store.debugCachedIndices(.video), [6, 7, 8], "then the farthest ahead")
        store.debugInsert(.video, index: 5, data: blob)
        store.debugInsert(.video, index: 4, data: blob)
        XCTAssertEqual(store.debugCachedIndices(.video), [4, 5, 6])
        XCTAssertEqual(store.cachedByteCount, 300_000)
        XCTAssertTrue(store.isCached(at: 105))
        XCTAssertFalse(store.isCached(at: 150))
        XCTAssertEqual(store.cachedAheadSeconds(), 40, accuracy: 0.001)
        store.close()
    }

    /// Regression: with a budget smaller than "30 s behind + forward", eviction kept segments AVPlayer had already
    /// played and dropped the farthest ahead — the segment AVPlayer had just requested — while the planner counted
    /// the played bytes as unreclaimable and stopped prefetching. Played segments must go first, and the segment
    /// being read must survive its own completion.
    func testTightBudgetEvictsPlayedSegmentsAndKeepsPrefetching() async throws {
        let n = 40
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 100_000, count: n),
                                           durations: Array(repeating: 2000, count: n))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let clock = EngineTestClock()
        let store = try makeStore(file, downloader: downloader, budget: 450_000, forward: 20, clock: clock)
        var prefetchHits = 0
        for i in 0..<(n - 1) {
            store.updatePlayback(time: Double(i) * 2, rate: 1, playing: true, bufferedAhead: 2, cacheFull: false)
            // AVPlayer asks for the segment after the playing one, once.
            let k = i + 1
            if store.debugCachedIndices(.video).contains(k) || store.debugInflight(.video)[k] != nil { prefetchHits += 1 }
            let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[k]))
            let bytes = try await engineDrain(reader)
            XCTAssertEqual(bytes, slice(file, file.segments[k]))
            // The reader can finish before the fetch task has filed the segment into the cache.
            let filed = await engineEventually { store.debugInflight(.video)[k] == nil }
            XCTAssertTrue(filed)
            XCTAssertTrue(store.debugCachedIndices(.video).contains(k), "segment \(k) AVPlayer just read was evicted")
            XCTAssertLessThanOrEqual(store.cachedByteCount, 450_000 + 100_000)
            clock.advance(ms: 2000)
        }
        let settled = await engineEventually { store.debugInflight(.video).isEmpty }
        XCTAssertTrue(settled)
        var downloads: [ByteRange: Int] = [:]
        for call in downloader.calls { downloads[call.range, default: 0] += 1 }
        XCTAssertTrue(downloads.values.allSatisfy { $0 == 1 }, "re-downloaded: \(downloads.filter { $0.value > 1 })")
        XCTAssertGreaterThan(prefetchHits, (n - 1) * 3 / 4, "prefetch starved: \(prefetchHits) hits")
        store.close()
    }

    func testPerRequestFallbackAndSuspensionAfterSixFailures() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 90_000, count: 8),
                                           durations: Array(repeating: 2000, count: 8))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        downloader.acceleratedFailures = 100
        downloader.failAfterBytes = 20_000
        let store = try makeStore(file, downloader: downloader)
        for i in 0..<6 {
            let seg = file.segments[i]
            let reader = try XCTUnwrap(store.reader(kind: .video, range: seg))
            let bytes = try await engineDrain(reader)
            XCTAssertEqual(bytes, slice(file, seg), "segment \(i)")
            let direct = downloader.calls.last
            XCTAssertEqual(direct?.direct, true)
            XCTAssertEqual(direct?.range, ByteRange(start: seg.start + 20_000, end: seg.end), "resumes after the verified prefix")
        }
        let six = await engineEventually { store.debugConsecutiveFailures(.video) == 6 }
        XCTAssertTrue(six)
        XCTAssertTrue(store.fallbackActive)
        XCTAssertFalse(store.isAccelerating)
        let before = downloader.calls.count
        let seg = file.segments[6]
        let reader = try XCTUnwrap(store.reader(kind: .video, range: seg))
        let bytes = try await engineDrain(reader)
        XCTAssertEqual(bytes, slice(file, seg))
        XCTAssertEqual(Array(downloader.calls[before...]),
                       [EngineFakeDownloader.Call(kind: .video, range: seg, rangeKind: nil, priority: nil)],
                       "acceleration suspended for the track: plain download only")
        store.close()
    }

    /// BTR §11.6 re-take: a suspended track probes the accelerated path again every 30 s (one job); a failed
    /// probe keeps it suspended, a successful one resumes acceleration.
    func testSuspendedTrackProbesAccelerationAgainEveryThirtySeconds() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 90_000, count: 10),
                                           durations: Array(repeating: 2000, count: 10))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        downloader.acceleratedFailures = 7   // six suspend the track, then the first probe fails too
        downloader.failAfterBytes = 0
        let clock = EngineTestClock()
        let store = try makeStore(file, downloader: downloader, clock: clock)
        func read(_ i: Int) async throws -> ArraySlice<EngineFakeDownloader.Call> {
            let before = downloader.calls.count
            let seg = file.segments[i]
            let bytes = try await engineDrain(try XCTUnwrap(store.reader(kind: .video, range: seg)))
            XCTAssertEqual(bytes, slice(file, seg), "segment \(i)")
            return downloader.calls[before...]
        }
        for i in 0..<6 { _ = try await read(i) }
        let six = await engineEventually { store.debugConsecutiveFailures(.video) == 6 }
        XCTAssertTrue(six)
        let suspended = try await read(6)
        XCTAssertEqual(suspended.map(\.direct), [true], "suspended: plain only")

        clock.advance(ms: 30_000)
        let failedProbe = try await read(7)
        XCTAssertEqual(failedProbe.map(\.direct), [false, true], "probe, then the per-request fallback")
        XCTAssertTrue(store.fallbackActive, "a failed probe keeps the track suspended")
        let waiting = try await read(8)
        XCTAssertEqual(waiting.map(\.direct), [true], "the next probe waits another period")

        clock.advance(ms: 30_000)
        let probe = try await read(9)
        XCTAssertEqual(probe.map(\.direct), [false], "the probe succeeds")
        let resumed = await engineEventually { store.debugConsecutiveFailures(.video) == 0 }
        XCTAssertTrue(resumed)
        XCTAssertTrue(store.isAccelerating)
        XCTAssertFalse(store.fallbackActive)
        store.close()
    }

    func testAcceleratedSuccessResetsFailureCount() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 90_000, count: 4),
                                           durations: Array(repeating: 2000, count: 4))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        downloader.acceleratedFailures = 2
        downloader.failAfterBytes = 0
        let store = try makeStore(file, downloader: downloader)
        for i in 0..<3 {
            let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[i]))
            _ = try await engineDrain(reader)
        }
        let reset = await engineEventually { store.debugConsecutiveFailures(.video) == 0 }
        XCTAssertTrue(reset, "\(store.debugConsecutiveFailures(.video))")
        XCTAssertTrue(store.isAccelerating)
        store.close()
    }

    func testAccelerationOffUsesDirectOnly() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [90_000, 90_000], durations: [2000, 2000])
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let store = try makeStore(file, downloader: downloader, accelerate: false)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[1]))
        let bytes = try await engineDrain(reader)
        XCTAssertEqual(bytes, slice(file, file.segments[1]))
        XCTAssertTrue(downloader.calls.allSatisfy(\.direct))
        XCTAssertFalse(store.isAccelerating)
        XCTAssertFalse(store.fallbackActive)
        store.close()
    }

    func testDisconnectCancelsUnreadDownloadBeforePlayheadKnown() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [90_000, 90_000, 90_000], durations: [2000, 2000, 2000])
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let store = try makeStore(file, downloader: downloader)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[2]))
        let task = Task { try await engineDrain(reader) }
        let waiting = await engineEventually { gate.waitingCount == 1 }
        XCTAssertTrue(waiting)
        reader.cancel()
        task.cancel()
        let cancelled = await engineEventually { downloader.cancelledCalls.contains { $0.range == file.segments[2] } }
        XCTAssertTrue(cancelled)
        let empty = await engineEventually { store.debugInflight(.video).isEmpty }
        XCTAssertTrue(empty)
        do {
            _ = try await task.value
            XCTFail("reader must not complete")
        } catch {}
        store.close()
    }

    func testOrphanNearPlayheadKeepsDownloadingUntilSeekAway() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 70_000, count: 60),
                                           durations: Array(repeating: 10_000, count: 60))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let store = try makeStore(file, downloader: downloader)
        store.updatePlayback(time: 0, rate: 1, playing: true, bufferedAhead: 0, cacheFull: false)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[5]))
        let task = Task { try await engineDrain(reader) }
        let attached = await engineEventually { store.debugInflight(.video)[5] == 1 }
        XCTAssertTrue(attached)
        reader.cancel()
        task.cancel()
        let detached = await engineEventually { store.debugInflight(.video)[5] == 0 }
        XCTAssertTrue(detached, "still wanted near the playhead: kept")
        store.seek(to: 500, outsideBuffer: true)
        let gone = await engineEventually {
            downloader.cancelledCalls.contains { $0.range == file.segments[5] }
                && downloader.cancelledCalls.contains { $0.range == file.segments[0] }
        }
        XCTAssertTrue(gone, "a seek far away cancels the old position's downloads")
        let restarted = await engineEventually {
            store.debugInflight(.video)[50] != nil && !self.calls(downloader, file.segments[50]).isEmpty
        }
        XCTAssertTrue(restarted, "startup segment of the new position")
        XCTAssertEqual(calls(downloader, file.segments[50]).first?.rangeKind, .startup)
        store.close()
    }

    func testWarmEndMakesContiguousRangesOrdinary() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: Array(repeating: 100_000, count: 20),
                                           durations: Array(repeating: 2000, count: 20))
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let store = try makeStore(file, downloader: downloader)
        for i in [3, 4] {
            let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[i]))
            _ = try await engineDrain(reader)
        }
        XCTAssertEqual(calls(downloader, file.segments[3]).first?.rangeKind, .startup)
        XCTAssertEqual(calls(downloader, file.segments[4]).first?.rangeKind, .ordinary)
        XCTAssertEqual(calls(downloader, file.segments[4]).first?.priority, 70)
        // A jump elsewhere starts over.
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[12]))
        _ = try await engineDrain(reader)
        XCTAssertEqual(calls(downloader, file.segments[12]).first?.rangeKind, .startup)
        store.close()
    }

    func testCloseFailsPendingReaders() async throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [90_000, 90_000], durations: [2000, 2000])
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let gate = EngineAsyncGate()
        downloader.gate = gate
        let store = try makeStore(file, downloader: downloader)
        let reader = try XCTUnwrap(store.reader(kind: .video, range: file.segments[0]))
        let task = Task { try await engineDrain(reader) }
        let waiting = await engineEventually { gate.waitingCount == 1 }
        XCTAssertTrue(waiting)
        store.close()
        do {
            _ = try await task.value
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MediaProxyError, .sessionClosed)
        }
        let afterClose = try XCTUnwrap(store.reader(kind: .video, range: file.segments[1]))
        do {
            _ = try await engineDrain(afterClose)
            XCTFail("expected failure")
        } catch {}
    }

    /// Regression: `SegmentFetch.append` used to yield to subscribers while holding the fetch lock. Yielding resumes a
    /// reader suspended in `next()`, which waits for that task's runtime status lock; a concurrent `Task.cancel()` of
    /// the same reader (AVPlayer dropping the socket) holds that lock while running `onTermination`, which takes the
    /// fetch lock → deadlock (and then the store lock and the main thread's `updatePlayback`).
    /// Synchronous test: producer and canceller run on their own threads, so a deadlock fails instead of hanging.
    func testCancellingReaderWhileBytesArriveDoesNotDeadlock() {
        let rounds = 300
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<rounds {
                let fetch = SegmentFetch(key: SegmentKey(kind: .video, index: 0),
                                         range: ByteRange(start: 0, end: 50_000_000))
                let subscription = fetch.subscribe(onEnd: {})
                let consumer = Task {
                    for try await _ in subscription.stream {}
                }
                let producing = DispatchSemaphore(value: 0)
                let stop = EngineStopFlag()
                DispatchQueue.global().async {
                    let chunk = Data(repeating: 7, count: 64)
                    while !stop.isSet && fetch.append(chunk) {}
                    producing.signal()
                }
                usleep(UInt32.random(in: 0..<300))
                consumer.cancel()
                stop.set()
                producing.wait()
                fetch.finish()
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "reader cancellation deadlocked with append")
    }

    func testDefaultBudget() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(SegmentStore.defaultBudgetBytes(physicalMemory: 2 * gb), 128 << 20)
        XCTAssertEqual(SegmentStore.defaultBudgetBytes(physicalMemory: 8 * gb), 256 << 20)
        XCTAssertEqual(SegmentStore.defaultBudgetBytes(physicalMemory: gb / 2), 64 << 20)
    }

    func testPieceDecomposition() throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [1000, 2000], durations: [1000, 1000], trailing: 100)
        let downloader = EngineFakeDownloader(files: [.video: file.data])
        let store = try makeStore(file, downloader: downloader)
        _ = store
        let indexData = file.data.subdata(in: Int(file.indexRange.start)..<Int(file.indexRange.end + 1))
        let sidx = try SidxParser.parse(indexData, absoluteStart: file.indexRange.start)
        let spec = SegmentStoreTrack(kind: .video, handle: EngineFakeTrack(kind: .video, urls: []),
                                     total: Int64(file.data.count),
                                     pinned: [PinnedBytes(range: ByteRange(start: 0, end: file.indexRange.end),
                                                          data: file.data.prefix(Int(file.indexRange.end + 1)))],
                                     segments: sidx.segments, accelerate: true)
        let s0 = file.segments[0]
        let pieces = SegmentStore.pieces(for: ByteRange(start: file.indexRange.end - 1, end: Int64(file.data.count) - 1),
                                         spec: spec)
        XCTAssertEqual(pieces.count, 4)
        guard case let .bytes(_, lower, upper) = pieces[0] else { return XCTFail() }
        XCTAssertEqual(upper - lower, 2)
        guard case let .segment(index, unitStart, need) = pieces[1] else { return XCTFail() }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(unitStart, s0.start)
        XCTAssertEqual(need, s0)
        guard case .segment(1, _, _) = pieces[2] else { return XCTFail() }
        guard case let .gap(gap) = pieces[3] else { return XCTFail() }
        XCTAssertEqual(gap, ByteRange(start: file.segments[1].end + 1, end: Int64(file.data.count) - 1))
    }
}
