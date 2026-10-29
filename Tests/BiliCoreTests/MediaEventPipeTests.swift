import XCTest
@testable import BiliCore

final class MediaEventPipeTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func bytes(_ s: String) -> MediaFetchEvent { .data(Data(s.utf8)) }

    func testOrderingAndNormalEnd() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: ["content-length": "6"]))
        pipe.push(bytes("ab"))
        pipe.push(bytes("cd"))
        pipe.push(bytes("ef"))
        pipe.finish()
        var seen: [String] = []
        for try await e in pipe.makeStream() {
            switch e {
            case .head(let s, _): seen.append("head\(s)")
            case .data(let d): seen.append(String(decoding: d, as: UTF8.self))
            }
        }
        XCTAssertEqual(seen, ["head206", "ab", "cd", "ef"])
        XCTAssertEqual(cancels.value, 0, "a normally finished stream must not report cancellation")
    }

    func testErrorIsThrownAfterBufferedData() async {
        let pipe = MediaEventPipe()
        pipe.push(.head(status: 206, headers: [:]))
        pipe.push(bytes("partial"))
        pipe.finish(throwing: MediaFetchError.connectionClosed)
        pipe.finish() // ignored
        var got = Data()
        do {
            for try await e in pipe.makeStream() { if case .data(let d) = e { got.append(d) } }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MediaFetchError, .connectionClosed)
        }
        XCTAssertEqual(got, Data("partial".utf8))
    }

    func testBackPressureSignalsDemandOnce() async throws {
        let pipe = MediaEventPipe(highWaterBytes: 10)
        let demand = Counter()
        pipe.setHandlers(onDemand: { demand.bump() }, onCancel: {})
        XCTAssertTrue(pipe.push(.head(status: 206, headers: [:])))
        XCTAssertTrue(pipe.push(bytes("123456")))     // 6 < 10
        XCTAssertFalse(pipe.push(bytes("789012")))    // 12 >= 10 → pause
        XCTAssertFalse(pipe.push(bytes("3")))         // still buffered, never dropped
        XCTAssertEqual(pipe.bufferedByteCount, 13)
        var it = pipe.makeStream().makeAsyncIterator()
        _ = try await it.next()                       // head: 13 still buffered
        XCTAssertEqual(demand.value, 0)
        _ = try await it.next()                       // 7 < 10 → demand
        XCTAssertEqual(demand.value, 1)
        _ = try await it.next()
        XCTAssertEqual(demand.value, 1, "demand fires once per pause")
        guard case .data(let last)? = try await it.next() else { return XCTFail("missing data") }
        XCTAssertEqual(last, Data("3".utf8))
        XCTAssertTrue(pipe.push(bytes("x")))
        pipe.finish()
        _ = try await it.next()
        let end = try await it.next()
        XCTAssertNil(end)
    }

    func testDirectHandoffToWaitingConsumer() async throws {
        let pipe = MediaEventPipe(highWaterBytes: 4)
        let demand = Counter()
        pipe.setHandlers(onDemand: { demand.bump() }, onCancel: {})
        let stream = pipe.makeStream()
        let consumer = Task { () -> Int in
            var n = 0
            for try await e in stream {
                if case .data(let d) = e { n += d.count }
                if n % 7 == 0 { await Task.yield() }
            }
            return n
        }
        var demandsSeen = 0
        var pauses = 0
        for i in 0 ..< 50 {
            // `false` = buffered but over the high-water mark: a well-behaved producer waits for onDemand.
            if !pipe.push(.data(Data(repeating: UInt8(i), count: 3))) {
                pauses += 1
                while demand.value == demandsSeen { try await Task.sleep(nanoseconds: 1_000_000) }
                demandsSeen = demand.value
            }
            XCTAssertLessThanOrEqual(pipe.bufferedByteCount, 4 + 3)
        }
        pipe.finish()
        let n = try await consumer.value
        XCTAssertEqual(n, 150)
        XCTAssertEqual(demand.value, pauses)
    }

    func testTaskCancellationWhileWaiting() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: [:]))
        let stream = pipe.makeStream()
        let consumer = Task { () -> String in
            do {
                for try await _ in stream {}
                return "ended"
            } catch {
                return "\(error)"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        let result = await consumer.value
        XCTAssertEqual(result, "\(MediaFetchError.cancelled)")
        XCTAssertEqual(cancels.value, 1)
        XCTAssertTrue(pipe.isCancelled)
        XCTAssertFalse(pipe.push(bytes("late")))
    }

    func testAlreadyCancelledConsumerEndsAndNotifies() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        let stream = pipe.makeStream()
        let consumer = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            var n = 0
            do { for try await _ in stream { n += 1 } } catch { n = -1 }
            return n
        }
        consumer.cancel()
        let n = await consumer.value
        XCTAssertTrue(n == 0 || n == -1, "a cancelled consumer sees the end or .cancelled, got \(n)")
        // The stream (and its token) are gone once the task finished.
        for _ in 0 ..< 100 where cancels.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(cancels.value, 1)
    }

    func testBreakingOutOfLoopReleasesAndNotifies() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: [:]))
        pipe.push(bytes("a"))
        func consumeOne() async throws {
            for try await _ in pipe.makeStream() { break }
        }
        try await consumeOne()
        XCTAssertEqual(cancels.value, 1)
        XCTAssertTrue(pipe.isCancelled)
    }

    /// A threaded producer that honours `push == false` by waiting for `onDemand`, against a consumer that stalls at
    /// random: every byte arrives once, in order, and neither side hangs.
    func testThreadedProducerHonouringDemandLosesNothing() async throws {
        for round in 0 ..< 20 {
            let pipe = MediaEventPipe(highWaterBytes: 64)
            let demand = DispatchSemaphore(value: 0)
            pipe.setHandlers(onDemand: { demand.signal() }, onCancel: {})
            let total = 3000
            DispatchQueue.global().async {
                var seed = UInt64(round + 1)
                var sent = 0
                pipe.push(.head(status: 206, headers: [:]))
                while sent < total {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = min(total - sent, Int(seed >> 59) + 1) // 1…32 bytes
                    let chunk = Data((sent ..< sent + n).map { UInt8(truncatingIfNeeded: $0) })
                    sent += n
                    if !pipe.push(.data(chunk)) { demand.wait() }
                }
                pipe.finish()
            }
            var got = Data()
            var stalls = 0
            for try await e in pipe.makeStream() {
                if case .data(let d) = e { got.append(d) }
                stalls += 1
                if stalls % 97 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            XCTAssertEqual(got, Data((0 ..< total).map { UInt8(truncatingIfNeeded: $0) }), "round \(round)")
        }
    }

    func testFinishAfterCancelAndPushAfterFinishAreIgnored() async throws {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        pipe.push(.head(status: 206, headers: [:]))
        pipe.cancel()
        pipe.cancel()
        pipe.finish(throwing: MediaFetchError.connectionClosed)
        XCTAssertFalse(pipe.push(bytes("x")))
        XCTAssertEqual(cancels.value, 1)
        XCTAssertEqual(pipe.bufferedByteCount, 0)
        var it = pipe.makeStream().makeAsyncIterator()
        do {
            _ = try await it.next()
            XCTFail("a cancelled pipe must not deliver")
        } catch {
            XCTAssertEqual(error as? MediaFetchError, .cancelled)
        }
    }

    func testDroppedStreamNotifies() {
        let pipe = MediaEventPipe()
        let cancels = Counter()
        pipe.setHandlers(onDemand: {}, onCancel: { cancels.bump() })
        do { _ = pipe.makeStream() }
        XCTAssertEqual(cancels.value, 1)
    }
}
