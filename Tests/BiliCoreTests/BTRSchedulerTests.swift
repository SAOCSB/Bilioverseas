import XCTest
@testable import BiliCore

final class BTRSchedulerTests: XCTestCase {
    /// Records the order in which waiters were granted.
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var slots: [BTRSlot] = []
        func add(_ s: String, _ slot: BTRSlot) {
            lock.lock()
            items.append(s)
            slots.append(slot)
            lock.unlock()
        }
        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
        func releaseFirst() {
            lock.lock()
            let s = slots.isEmpty ? nil : slots.removeFirst()
            lock.unlock()
            s?.release()
        }
        func releaseAll() {
            lock.lock()
            let all = slots
            slots.removeAll()
            lock.unlock()
            all.forEach { $0.release() }
        }
    }

    private func waitUntil(_ timeout: Double = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// Fills `pool` with `n` held slots.
    private func hold(_ pool: BTRSlotPool, _ n: Int, lane: BTRSlotLane = .normal) async throws -> [BTRSlot] {
        var slots: [BTRSlot] = []
        for _ in 0..<n { slots.append(try await pool.acquire(priority: 0, queueClass: .critical, lane: lane)) }
        return slots
    }

    private func enqueue(_ pool: BTRSlotPool, _ order: Order, _ name: String, priority: Double, queueClass: BTRQueueClass,
                         lane: BTRSlotLane = .normal, deadline: (() -> Double)? = nil, ages: Bool = false) -> Task<Void, Never> {
        Task {
            if let slot = try? await pool.acquire(priority: priority, queueClass: queueClass, lane: lane, deadline: deadline, ages: ages) {
                order.add(name, slot)
            }
        }
    }

    func testClassBeatsPriorityDeadlineAndAging() async throws {
        let clock = BTRManualClock()
        let pool = BTRSlotPool(limit: 2, clock: clock) // normal limit 1
        let held = try await hold(pool, 1)
        let order = Order()
        let t1 = enqueue(pool, order, "ordinary-overdue", priority: 500, queueClass: .ordinary, deadline: { 0 }, ages: true)
        let t2 = enqueue(pool, order, "startup", priority: 100, queueClass: .startup)
        let t3 = enqueue(pool, order, "critical", priority: 0, queueClass: .critical)
        await waitUntil { pool.snapshot.queued == 3 }
        clock.advance(60_000) // aging would add 1333
        held[0].release()
        await waitUntil { order.names.count == 1 }
        order.releaseFirst()
        await waitUntil { order.names.count == 2 }
        order.releaseFirst()
        await waitUntil { order.names.count == 3 }
        XCTAssertEqual(order.names, ["critical", "startup", "ordinary-overdue"])
        order.releaseAll()
        _ = await (t1.value, t2.value, t3.value)
        XCTAssertEqual(pool.snapshot.active, 0)
    }

    func testDeadlineUrgencyAndAging() async throws {
        let clock = BTRManualClock()
        let pool = BTRSlotPool(limit: 2, clock: clock)
        let held = try await hold(pool, 1)
        let order = Order()
        let now = clock.nowMs()
        // Overdue (+12) priority 50 beats prefetch priority 60 without a deadline.
        let a = enqueue(pool, order, "prefetch60", priority: 60, queueClass: .ordinary)
        let b = enqueue(pool, order, "overdue50", priority: 50, queueClass: .ordinary, deadline: { now })
        await waitUntil { pool.snapshot.queued == 2 }
        held[0].release()
        await waitUntil { order.names.count == 1 }
        XCTAssertEqual(order.names, ["overdue50"])
        // A request with a deadline that waited 1.5 s goes before a newer one of slightly higher priority.
        let c = enqueue(pool, order, "old40", priority: 40, queueClass: .ordinary, deadline: { now + 30_000 }, ages: true)
        await waitUntil { pool.snapshot.queued == 2 }
        clock.advance(1500)
        let d = enqueue(pool, order, "fresh50", priority: 50, queueClass: .ordinary, deadline: { now + 31_500 }, ages: true)
        await waitUntil { pool.snapshot.queued == 3 }
        order.releaseFirst()
        await waitUntil { order.names.count == 2 }
        XCTAssertEqual(order.names[1], "old40", "40 + 1500 × 20/900 ≈ 73 > 60 and 50")
        order.releaseFirst()
        await waitUntil { order.names.count == 3 }
        XCTAssertEqual(order.names[2], "prefetch60")
        order.releaseFirst()
        await waitUntil { order.names.count == 4 }
        XCTAssertEqual(order.names[3], "fresh50")
        order.releaseAll()
        _ = await (a.value, b.value, c.value, d.value)
    }

    func testFIFOWithinEqualRank() async throws {
        let pool = BTRSlotPool(limit: 2, clock: BTRManualClock())
        let held = try await hold(pool, 1)
        let order = Order()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<4 {
            tasks.append(enqueue(pool, order, "w\(i)", priority: 10, queueClass: .ordinary))
            await waitUntil { pool.snapshot.queued == i + 1 }
        }
        held[0].release()
        for n in 1...4 {
            await waitUntil { order.names.count == n }
            order.releaseFirst()
        }
        XCTAssertEqual(order.names, ["w0", "w1", "w2", "w3"])
        for t in tasks { await t.value }
    }

    func testRescueLaneStaysFreeForCopies() async throws {
        let pool = BTRSlotPool(limit: 8, clock: BTRManualClock())
        let normals = try await hold(pool, 7)
        XCTAssertEqual(pool.snapshot.normalActive, 7)
        let order = Order()
        let blocked = enqueue(pool, order, "normal", priority: 1000, queueClass: .critical)
        await waitUntil { pool.snapshot.queued == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(order.names, [], "the eighth slot is not for first copies")
        let copy = enqueue(pool, order, "copy", priority: 0, queueClass: .ordinary, lane: .rescue)
        await waitUntil { order.names.count == 1 }
        XCTAssertEqual(order.names, ["copy"])
        XCTAssertEqual(pool.snapshot.active, 8)
        normals[0].release()
        await waitUntil { order.names.count == 2 }
        XCTAssertEqual(order.names, ["copy", "normal"])
        normals.forEach { $0.release() }
        order.releaseAll()
        _ = await (blocked.value, copy.value)
        XCTAssertEqual(pool.snapshot, BTRSlotPool.Snapshot(limit: 8, normalLimit: 7, active: 0, normalActive: 0, queued: 0))
    }

    func testLiveLimitChangeAndDemandReports() async throws {
        let lock = NSLock()
        var last: (Int, Int, Int) = (0, 0, 0)
        let pool = BTRSlotPool(limit: 2, clock: BTRManualClock(), onChange: { a, l, q in
            lock.lock(); last = (a, l, q); lock.unlock()
        })
        let held = try await hold(pool, 1)
        let order = Order()
        let tasks = (0..<3).map { enqueue(pool, order, "w\($0)", priority: 0, queueClass: .ordinary) }
        let reported = { () -> [Int] in lock.lock(); defer { lock.unlock() }; return [last.0, last.1, last.2] }
        await waitUntil { reported() == [1, 2, 3] }
        XCTAssertEqual(reported(), [1, 2, 3], "demand(active, limit, queued) after every change")
        pool.setLimit(8) // normal limit 7
        await waitUntil { order.names.count == 3 }
        XCTAssertEqual(pool.snapshot.active, 4)
        await waitUntil { reported() == [4, 8, 0] }
        XCTAssertEqual(reported(), [4, 8, 0])
        pool.setLimit(1)
        XCTAssertEqual(pool.snapshot.limit, 1)
        held[0].release()
        order.releaseAll()
        for t in tasks { await t.value }
        XCTAssertEqual(pool.snapshot.active, 0)
        pool.setLimit(0)
        XCTAssertEqual(pool.snapshot.limit, 1, "clamped to 1…512")
        pool.setLimit(10_000)
        XCTAssertEqual(pool.snapshot.limit, 512)
    }

    func testCancellationRemovesWaitersAndNeverLeaksSlots() async throws {
        let pool = BTRSlotPool(limit: 4, clock: BTRManualClock())
        // Already cancelled: throws at once.
        let early = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await pool.acquire(priority: 0, queueClass: .ordinary)) == nil
        }
        let earlyThrew = await early.value
        XCTAssertTrue(earlyThrew)
        let held = try await hold(pool, 3)
        let waiter = Task { try await pool.acquire(priority: 0, queueClass: .ordinary) }
        await waitUntil { pool.snapshot.queued == 1 }
        waiter.cancel()
        let result = await waiter.result
        if case .success = result { XCTFail("a cancelled waiter must not get a slot") }
        XCTAssertEqual(pool.snapshot.queued, 0)
        held.forEach { $0.release() }
        XCTAssertEqual(pool.snapshot.active, 0)
        // Stress: grants racing with cancellation.
        let stress = BTRSlotPool(limit: 3, clock: BTRManualClock())
        var tasks: [Task<Void, Never>] = []
        for i in 0..<300 {
            let t = Task {
                guard let slot = try? await stress.acquire(priority: Double(i % 7), queueClass: i % 3 == 0 ? .startup : .ordinary,
                                                           lane: i % 5 == 0 ? .rescue : .normal) else { return }
                try? await Task.sleep(nanoseconds: UInt64((i % 4) * 200_000))
                slot.release()
            }
            tasks.append(t)
            if i % 2 == 0 { t.cancel() }
        }
        for t in tasks { await t.value }
        XCTAssertEqual(stress.snapshot.active, 0, "no slot leaked")
        XCTAssertEqual(stress.snapshot.normalActive, 0)
        XCTAssertEqual(stress.snapshot.queued, 0)
    }

    func testCloseFailsWaiters() async throws {
        let pool = BTRSlotPool(limit: 1, clock: BTRManualClock())
        let held = try await hold(pool, 1)
        let waiter = Task { try await pool.acquire(priority: 0, queueClass: .ordinary) }
        await waitUntil { pool.snapshot.queued == 1 }
        pool.close()
        let result = await waiter.result
        if case .success = result { XCTFail("closed pool grants nothing") }
        do {
            _ = try await pool.acquire(priority: 0, queueClass: .critical)
            XCTFail("closed pool grants nothing")
        } catch {}
        held[0].release()
        held[0].release() // idempotent
        XCTAssertEqual(pool.snapshot.active, 0)
    }
}
