import Foundation

// The connection budget of one downloader (= one playback session; video and audio share it). Port of BTR's
// `Semaphore` priority queue (idm-downloader.js, MIT, spec §7.2) combined with lemon's session-wide normal / rescue
// lanes (proxy-ports §3.3):
//
// - `limit` slots in total; first copies ("normal" lane) may hold at most `normalLimit` of them, so hedge copies
//   (rescue lane) always find a slot even when every primary is stuck.
// - Waiters are served by class (CRITICAL init/index/head probe → STARTUP pieces → ORDINARY), then by rank =
//   priority + deadline urgency (overdue +12, ≤ 750 ms +9, ≤ 2 s +6) + aging (+20 per 0.9 s, ORDINARY entries with a
//   finite deadline only), then FIFO. Deadlines are re-read at every drain.
// - Cancellation removes a waiter; a grant that races with cancellation is released at once (no slot leaks).

enum BTRQueueClass: Int, Comparable {
    case critical = 0, startup = 1, ordinary = 2
    static func < (a: BTRQueueClass, b: BTRQueueClass) -> Bool { a.rawValue < b.rawValue }
}

enum BTRSlotLane {
    /// First copies: limited to `normalLimit` slots.
    case normal
    /// Hedge copies: may take any free slot.
    case rescue
}

/// A granted connection slot. `release()` is idempotent.
final class BTRSlot: @unchecked Sendable {
    let lane: BTRSlotLane
    private weak var pool: BTRSlotPool?
    private let lock = NSLock()
    private var released = false

    init(pool: BTRSlotPool, lane: BTRSlotLane) {
        self.pool = pool
        self.lane = lane
    }

    func release() {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        pool?.releaseSlot(lane)
    }

    deinit { release() }
}

final class BTRSlotPool: @unchecked Sendable {
    struct Snapshot: Equatable {
        var limit: Int
        var normalLimit: Int
        var active: Int
        var normalActive: Int
        var queued: Int
    }

    private final class Waiter {
        let priority: Double
        let queueClass: BTRQueueClass
        let lane: BTRSlotLane
        let deadline: (() -> Double)?
        let ages: Bool
        var queuedAt: Double = 0
        var sequence = 0
        var continuation: CheckedContinuation<BTRSlot, Error>?
        var cancelled = false

        init(priority: Double, queueClass: BTRQueueClass, lane: BTRSlotLane, deadline: (() -> Double)?, ages: Bool) {
            self.priority = priority
            self.queueClass = queueClass
            self.lane = lane
            self.deadline = deadline
            self.ages = ages
        }
    }

    /// lemon `_normalLimit`: `c − clamp(ceil(c/8), 1, c−1)`, 1 when c = 1. c = 8 → 7, 16 → 14, 64 → 56.
    static func normalLimit(for c: Int) -> Int {
        if c <= 1 { return 1 }
        let reserve = min(max(Int((Double(c) / 8).rounded(.up)), 1), c - 1)
        return c - reserve
    }

    private let clock: MonotonicClock
    private let lock = NSLock()
    private var limit: Int
    private var active = 0
    private var normalActive = 0
    private var queue: [Waiter] = []
    private var sequence = 0
    private var closed = false
    private var draining = false
    private var drainAgain = false
    private let onChange: ((Int, Int, Int) -> Void)?

    /// `onChange(active, limit, queued)` after every change (serialized, outside the lock) — feeds
    /// `AutoConcurrencyController.demand`.
    init(limit: Int, clock: MonotonicClock = SystemClock.shared, onChange: ((Int, Int, Int) -> Void)? = nil) {
        self.limit = max(1, min(512, limit))
        self.clock = clock
        self.onChange = onChange
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(limit: limit, normalLimit: Self.normalLimit(for: limit), active: active,
                        normalActive: normalActive, queued: queue.count)
    }

    /// Live limit change (auto-concurrency, settings); clamped to 1…512.
    func setLimit(_ newLimit: Int) {
        lock.lock()
        let clamped = max(1, min(512, newLimit))
        let changed = clamped != limit
        limit = clamped
        lock.unlock()
        if changed { drain() }
    }

    /// Waits for a slot. Throws `CancellationError` if the task is cancelled (before or while queued) or the pool
    /// is closed. `deadline` returns monotonic ms (`.infinity` = none) and is re-read at every drain; it must not
    /// block.
    func acquire(priority: Double, queueClass: BTRQueueClass, lane: BTRSlotLane = .normal,
                 deadline: (() -> Double)? = nil, ages: Bool = false) async throws -> BTRSlot {
        let waiter = Waiter(priority: priority, queueClass: queueClass, lane: lane, deadline: deadline, ages: ages)
        let slot: BTRSlot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BTRSlot, Error>) in
                lock.lock()
                if closed || waiter.cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter.continuation = continuation
                waiter.sequence = sequence
                sequence += 1
                waiter.queuedAt = clock.nowMs()
                queue.append(waiter)
                lock.unlock()
                drain()
            }
        } onCancel: {
            self.cancelWaiter(waiter)
        }
        // A grant that raced with cancellation goes straight back.
        if Task.isCancelled {
            slot.release()
            throw CancellationError()
        }
        return slot
    }

    /// Fails every waiter and refuses new ones (session closed). Granted slots stay valid until released.
    func close() {
        lock.lock()
        closed = true
        let waiters = queue
        queue.removeAll()
        let conts = waiters.compactMap { w -> CheckedContinuation<BTRSlot, Error>? in
            w.cancelled = true
            let c = w.continuation
            w.continuation = nil
            return c
        }
        lock.unlock()
        for c in conts { c.resume(throwing: CancellationError()) }
        drain()
    }

    fileprivate func releaseSlot(_ lane: BTRSlotLane) {
        lock.lock()
        active = max(0, active - 1)
        if lane == .normal { normalActive = max(0, normalActive - 1) }
        lock.unlock()
        drain()
    }

    private func cancelWaiter(_ waiter: Waiter) {
        lock.lock()
        waiter.cancelled = true
        var continuation: CheckedContinuation<BTRSlot, Error>?
        if let index = queue.firstIndex(where: { $0 === waiter }) {
            queue.remove(at: index)
            continuation = waiter.continuation
            waiter.continuation = nil
        }
        lock.unlock()
        if let continuation {
            continuation.resume(throwing: CancellationError())
            drain()
        }
    }

    private func urgency(_ waiter: Waiter, now: Double) -> Double {
        guard let deadline = waiter.deadline else { return 0 }
        let at = deadline()
        guard at.isFinite else { return 0 }
        let remaining = at - now
        if remaining <= 0 { return 12 }
        if remaining <= 750 { return 9 }
        if remaining <= 2000 { return 6 }
        return 0
    }

    private func rank(_ waiter: Waiter, now: Double) -> Double {
        waiter.priority + urgency(waiter, now: now)
            + (waiter.ages ? max(0, now - waiter.queuedAt) * BTRConstants.queueAgingPerMs : 0)
    }

    /// One drainer at a time; concurrent requests are coalesced into another pass. Deadline closures are called
    /// without holding the lock.
    private func drain() {
        lock.lock()
        if draining {
            drainAgain = true
            lock.unlock()
            return
        }
        draining = true
        while true {
            drainAgain = false
            var grants: [(CheckedContinuation<BTRSlot, Error>, BTRSlot)] = []
            if active < limit && !queue.isEmpty {
                let entries = queue
                let now = clock.nowMs()
                lock.unlock()
                let ranked = entries.map { ($0, rank($0, now: now)) }.sorted { a, b in
                    if a.0.queueClass != b.0.queueClass { return a.0.queueClass < b.0.queueClass }
                    if a.1 != b.1 { return a.1 > b.1 }
                    return a.0.sequence < b.0.sequence
                }
                lock.lock()
                let normalLimit = Self.normalLimit(for: limit)
                for (waiter, _) in ranked {
                    if active >= limit { break }
                    if waiter.cancelled || waiter.continuation == nil { continue }
                    if waiter.lane == .normal && normalActive >= normalLimit { continue }
                    guard let index = queue.firstIndex(where: { $0 === waiter }) else { continue }
                    queue.remove(at: index)
                    active += 1
                    if waiter.lane == .normal { normalActive += 1 }
                    if let c = waiter.continuation {
                        grants.append((c, BTRSlot(pool: self, lane: waiter.lane)))
                    }
                    waiter.continuation = nil
                }
            }
            let snap = (active, limit, queue.count)
            lock.unlock()
            for (continuation, slot) in grants { continuation.resume(returning: slot) }
            onChange?(snap.0, snap.1, snap.2)
            lock.lock()
            if !drainAgain {
                draining = false
                lock.unlock()
                return
            }
        }
    }
}
