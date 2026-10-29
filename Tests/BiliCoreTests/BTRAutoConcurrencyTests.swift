import XCTest
@testable import BiliCore

/// Ports of Bilibili-thread-ripper `dev/auto-concurrency-test.js` against a manual clock.
final class BTRAutoConcurrencyTests: XCTestCase {
    private final class Harness {
        let clock = BTRManualClock(100_000)
        let auto: AutoConcurrencyController
        private let lock = NSLock()
        private var _changes: [AutoConcurrencyController.Change] = []
        var changes: [AutoConcurrencyController.Change] {
            lock.lock()
            defer { lock.unlock() }
            return _changes
        }

        init(maxThreads: Int = 64) {
            auto = AutoConcurrencyController(clock: clock, maxThreads: maxThreads)
            auto.subscribe { [weak self] change in
                guard let self else { return }
                self.lock.lock()
                self._changes.append(change)
                self.lock.unlock()
            }
        }

        /// Steady delivery at `bps` with every slot busy, for `ms`.
        func flow(_ bps: Double, _ ms: Double) {
            auto.demand(active: 8, limit: 8, queued: 3)
            var t = 0.0
            while t < ms {
                clock.advance(250)
                auto.activity()
                auto.delivered(Int(bps / 4))
                t += 250
            }
        }

        func feed(_ ahead: Double, _ ms: Double, activity: Bool = true, cacheFull: Bool = false) {
            var t = 0.0
            while t < ms {
                clock.advance(250)
                if activity { auto.activity() }
                auto.signalBuffer(ahead: ahead, playing: true, cacheFull: cacheFull)
                t += 250
            }
        }
    }

    func testLadder() {
        let h = Harness()
        XCTAssertEqual(h.auto.ladder, [8, 12, 16, 24, 32, 48, 64])
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertEqual(AutoConcurrencyController(clock: h.clock, maxThreads: 32).ladder, [8, 12, 16, 24, 32])
    }

    func testStallsClimbOnceperCooldownUpTo64() {
        let h = Harness()
        h.clock.advance(5000)
        XCTAssertTrue(h.auto.signalStall())
        XCTAssertEqual(h.auto.threads, 12)
        XCTAssertFalse(h.auto.signalStall(), "a second stall right after is the same stall")
        h.clock.advance(3000)
        XCTAssertTrue(h.auto.signalStall())
        XCTAssertEqual(h.auto.threads, 16)
        h.clock.advance(3000); h.auto.stall(); h.clock.advance(3000); h.auto.stall()
        XCTAssertEqual(h.auto.threads, 32)
        h.clock.advance(3000); h.auto.stall(); h.clock.advance(3000); h.auto.stall()
        XCTAssertEqual(h.auto.threads, 64)
        h.clock.advance(3000)
        XCTAssertFalse(h.auto.signalStall())
        XCTAssertEqual(h.auto.threads, 64)
        XCTAssertEqual(h.changes.map(\.threads), [12, 16, 24, 32, 48, 64])
        XCTAssertEqual(h.changes.first?.previous, 8)
        XCTAssertEqual(h.changes.first?.reason, "播放卡了一下")
    }

    func testFruitlessTrialGoesBackAndRests() {
        let h = Harness()
        h.clock.advance(5000)
        h.flow(1e6, 5000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 12)
        h.flow(0.95e6, 11000)
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertTrue(h.changes.last!.reason.contains("12 线程没有比 8 线程更快"))
        XCTAssertEqual(h.auto.status().resting.map { [$0.threads, $0.hard ? 1 : 0] }, [[12, 0]])
        h.clock.advance(3000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 16, "12 rests after a fruitless trial; a stall may skip it")
        h.flow(0.9e6, 11000)
        XCTAssertEqual(h.auto.threads, 8, "back to the level the trial started from")
        XCTAssertTrue(h.changes.last!.reason.contains("16 线程没有比 8 线程更快"))
        h.clock.advance(3000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 24)
        h.flow(1.5e6, 11000)
        XCTAssertEqual(h.auto.threads, 24, "a step that delivers more is kept")
    }

    func testTrialNotJudgedWithoutDemandOrAfterAnotherStall() {
        let h = Harness()
        h.clock.advance(5000)
        h.flow(1e6, 5000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 12)
        h.auto.demand(active: 2, limit: 12, queued: 0)
        for _ in 0..<44 {
            h.clock.advance(250)
            h.auto.activity()
            h.auto.delivered(Int(1e6 / 8))
        }
        XCTAssertEqual(h.auto.threads, 12, "idle connections prove nothing")
        let s = Harness()
        s.clock.advance(5000)
        s.flow(1e6, 5000)
        s.auto.stall()
        s.clock.advance(3000)
        s.auto.stall()
        s.flow(0.9e6, 11000)
        XCTAssertEqual(s.auto.threads, 12, "16 brought nothing over 12; 12 itself was never judged")
        XCTAssertEqual(s.auto.status().resting.map(\.threads), [16])
    }

    func testSaturationIsMeasuredByTime() {
        let h = Harness()
        h.auto.demand(active: 8, limit: 8, queued: 4)
        h.clock.advance(6000)
        XCTAssertEqual(h.auto.status().saturation, 1)
        h.auto.demand(active: 3, limit: 8, queued: 0)
        h.clock.advance(2500)
        XCTAssertEqual(h.auto.status().saturation, 0.5)
    }

    func testBufferPressure() {
        let h = Harness()
        h.clock.advance(5000)
        func run(_ aheads: [Double], playing: Bool = true) -> Bool {
            var stepped = false
            for ahead in aheads {
                h.clock.advance(250)
                h.auto.activity()
                if h.auto.signalBuffer(ahead: ahead, playing: playing) { stepped = true }
            }
            return stepped
        }
        XCTAssertFalse(run([4, 4.2, 4.4, 4.6, 4.8, 5, 5.2, 5.4, 5.6, 5.8]), "growing: the download outpaces playback")
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertTrue(run([4, 3.9, 3.8, 3.7, 3.6, 3.5, 3.4, 3.3, 3.2, 3.1]))
        XCTAssertEqual(h.auto.threads, 12)
        h.clock.advance(3000)
        XCTAssertFalse(run([20, 19, 18, 17, 16, 15, 14, 13, 12, 11]), "20 s ahead is comfortable")
        XCTAssertFalse(run([4, 4, 4, 4, 4, 4, 4, 4, 4, 4], playing: false), "paused counts for nothing")
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 16, "a new session opens with 16 threads")
        h.clock.advance(3000)
        XCTAssertFalse(run([4, 4, 4, 4]), "under a second of samples: no verdict")
        XCTAssertTrue(run([4, 4, 4, 4, 4]))
        XCTAssertEqual(h.auto.threads, 24)
    }

    func testPushbackRestsHardForThreeMinutes() {
        let h = Harness()
        h.clock.advance(5000); h.auto.stall(); h.clock.advance(3000); h.auto.stall()
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertTrue(h.auto.pushback(status: 412))
        XCTAssertEqual(h.auto.threads, 12)
        XCTAssertEqual(h.changes.last?.reason, "服务器返回 412")
        h.clock.advance(3000)
        XCTAssertFalse(h.auto.signalStall(), "16 was refused: a stall does not jump over it")
        XCTAssertEqual(h.auto.threads, 12)
        h.clock.advance(180_001)
        XCTAssertTrue(h.auto.signalStall())
        XCTAssertEqual(h.auto.threads, 16, "after the rest the climb resumes")
        h.auto.pushback(status: 429)
        h.auto.pushback(status: 429)
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertFalse(h.auto.pushback(status: 412), "8 is the floor")
        h.clock.advance(3000)
        XCTAssertFalse(h.auto.signalStall(), "refused at the floor: no climb for the rest either")
        h.clock.advance(180_001)
        XCTAssertTrue(h.auto.signalStall())
    }

    func testNewSessionDropsTrialKeepsRests() {
        let h = Harness()
        h.clock.advance(5000)
        h.flow(1e6, 5000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 12)
        h.auto.newSession()
        XCTAssertNil(h.auto.status().trial)
        XCTAssertEqual(h.auto.threads, 16)
        h.flow(0.5e6, 11000)
        XCTAssertEqual(h.auto.threads, 16, "no trial left to judge")
        h.auto.pushback(status: 412)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 12, "a start does not climb onto a refused level")
        XCTAssertEqual(h.auto.status().resting.map { [$0.threads, $0.hard ? 1 : 0] }, [[16, 1]], "rests survive a new session")
    }

    func testStartupBoostAndComedown() {
        let h = Harness()
        h.clock.advance(5000)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertEqual(h.changes.last?.reason, "开头先用 16 线程")
        XCTAssertEqual(h.auto.status().startup?.base, 8)
        h.feed(9, 4000)
        XCTAssertEqual(h.auto.threads, 16, "9 s ahead is not well ahead yet")
        h.feed(16, 250)
        XCTAssertEqual(h.auto.threads, 12, "well ahead: one step down")
        h.feed(16, 1000)
        XCTAssertEqual(h.auto.threads, 12, "one step per cooldown")
        h.feed(16, 2000)
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertEqual(h.changes.last?.reason, "开头已经跟上，线程数降到 8")
        XCTAssertNil(h.auto.status().startup)
        h.feed(30, 5000)
        XCTAssertEqual(h.auto.threads, 8, "the usual rules never step down on their own")
    }

    func testFullPlayerCacheAlsoEndsTheStart() {
        // lemon: a full cache below 15 s ahead counts as caught up.
        let h = Harness()
        h.clock.advance(5000)
        h.auto.newSession()
        h.feed(9, 3000, cacheFull: true)
        XCTAssertEqual(h.auto.threads, 12)
        h.feed(9, 2500, cacheFull: true)
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertNil(h.auto.status().startup)
    }

    func testStallDuringStartClimbsAndEndsIt() {
        let h = Harness()
        h.clock.advance(5000)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertFalse(h.auto.signalStall(), "within the cooldown of the start's own step")
        h.clock.advance(2600)
        XCTAssertTrue(h.auto.signalStall())
        XCTAssertEqual(h.auto.threads, 24)
        XCTAssertNil(h.auto.status().startup)
        h.feed(20, 5000, activity: false)
        XCTAssertEqual(h.auto.threads, 24, "the usual rules decide now")
    }

    func testStartThatNeverCatchesUpKeepsItsCount() {
        let h = Harness()
        h.clock.advance(5000)
        h.auto.newSession()
        var ahead = 6.0
        var t = 0.0
        while t < 31_000 {
            h.clock.advance(250)
            h.auto.activity()
            ahead += 0.02
            h.auto.signalBuffer(ahead: ahead, playing: true)
            t += 250
        }
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertNil(h.auto.status().startup)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertNil(h.auto.status().startup, "16 is the level now: nothing to come back down to")
        h.feed(20, 5000, activity: false)
        XCTAssertEqual(h.auto.threads, 16)
    }

    func testSeekDuringStartKeepsTheBase() {
        let h = Harness()
        h.clock.advance(5000)
        h.auto.newSession()
        h.clock.advance(1000)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 16)
        XCTAssertEqual(h.auto.status().startup?.base, 8)
        h.feed(20, 6000, activity: false)
        XCTAssertEqual(h.auto.threads, 8)
    }

    func testStartNeverClimbsOntoARefusedLevel() {
        let h = Harness()
        h.clock.advance(5000)
        h.auto.stall()
        XCTAssertEqual(h.auto.threads, 12)
        h.auto.pushback(status: 429)
        XCTAssertEqual(h.auto.threads, 8)
        h.auto.newSession()
        XCTAssertEqual(h.auto.threads, 8)
        XCTAssertNil(h.auto.status().startup)
    }

    func testDeliveryBucketsAreBounded() {
        let h = Harness()
        for _ in 0..<20_000 {
            h.clock.advance(250)
            h.auto.delivered(1000)
        }
        XCTAssertLessThanOrEqual(h.auto.status().buckets, 22)
    }

    func testSlowClimbsOnlyWhenSaturated() {
        let h = Harness()
        h.clock.advance(5000)
        XCTAssertFalse(h.auto.slow())
        h.auto.demand(active: 8, limit: 8, queued: 2)
        h.clock.advance(3500)
        XCTAssertTrue(h.auto.slow())
        XCTAssertEqual(h.auto.threads, 12)
        XCTAssertEqual(h.auto.reason, "连接排队等太久")
    }

    func testDeviceCap() {
        let h = Harness()
        h.clock.advance(5000)
        for _ in 0..<6 {
            h.auto.stall()
            h.clock.advance(3000)
        }
        XCTAssertEqual(h.auto.threads, 64)
        h.auto.setThreadCap(32)
        XCTAssertEqual(h.auto.threads, 32)
        h.clock.advance(3000)
        XCTAssertFalse(h.auto.signalStall(), "no level above the cap")
        let capped = Harness(maxThreads: 24)
        capped.clock.advance(5000)
        for _ in 0..<6 {
            capped.auto.stall()
            capped.clock.advance(3000)
        }
        XCTAssertEqual(capped.auto.threads, 24)
    }
}
