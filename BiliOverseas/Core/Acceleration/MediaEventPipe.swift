import Foundation

/// Single-consumer bridge from a push-based producer (network callbacks) to the
/// `AsyncThrowingStream<MediaFetchEvent, Error>` returned by `MediaHTTPClient.get`, with demand-driven
/// back-pressure that never drops data.
///
/// Why not `AsyncThrowingStream.makeStream`: its continuation never tells the producer how much the consumer has
/// taken (`.unbounded` buffers without limit; the bounded policies drop). Here the stream is built with
/// `AsyncThrowingStream(unfolding:)`, so every consumer `next()` is a pull we observe:
/// - `push` returns `false` once `highWaterBytes` of body data are buffered; the producer must then stop reading
///   until `onDemand` fires (exactly once per pause, after the consumer drained below the mark).
/// - The consumer going away — its task cancelled while waiting in `next()`, or the stream and its iterator released
///   (loop exited by `break`/`throw`) — fires `onCancel` once (unless the producer had already finished), so the
///   producer can close the connection.
///
/// Ordering: events come out exactly in push order; a producer error is thrown only after every event pushed
/// before it was delivered. After the end (nil) or an error, `next()` returns nil.
final class MediaEventPipe: @unchecked Sendable {
    static let defaultHighWaterBytes = 1 << 20

    let highWaterBytes: Int

    private let lock = NSLock()
    private var buffer: [MediaFetchEvent] = []
    private var bufferedBytes = 0
    private var waiter: CheckedContinuation<MediaFetchEvent?, Error>?
    /// The producer called `finish` (or the consumer cancelled).
    private var finished = false
    /// Error to throw once the buffer is drained (delivered once).
    private var failure: Error?
    private var consumerGone = false
    private var producerPaused = false
    private var onDemand: (() -> Void)?
    private var onCancel: (() -> Void)?

    init(highWaterBytes: Int = MediaEventPipe.defaultHighWaterBytes) {
        self.highWaterBytes = max(1, highWaterBytes)
    }

    /// Install the producer callbacks (before handing out the stream). Both are called outside the pipe's lock,
    /// on the consumer's thread.
    func setHandlers(onDemand: @escaping () -> Void, onCancel: @escaping () -> Void) {
        lock.lock()
        self.onDemand = onDemand
        self.onCancel = onCancel
        lock.unlock()
    }

    // MARK: Producer side

    /// Queues `event` (or hands it straight to a waiting consumer). Returns `false` when the consumer is behind —
    /// the producer should stop reading until `onDemand` — or gone / finished (the event was discarded).
    @discardableResult
    func push(_ event: MediaFetchEvent) -> Bool {
        lock.lock()
        if finished || consumerGone {
            lock.unlock()
            return false
        }
        if let w = waiter {
            // A waiter only exists while the buffer is empty.
            waiter = nil
            lock.unlock()
            w.resume(returning: event)
            return true
        }
        buffer.append(event)
        bufferedBytes += Self.byteCount(event)
        let more = bufferedBytes < highWaterBytes
        if !more { producerPaused = true }
        lock.unlock()
        return more
    }

    /// Ends the stream after the buffered events: normally (`nil`) or by throwing `error`. Later calls are ignored.
    func finish(throwing error: Error? = nil) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        producerPaused = false
        var w: CheckedContinuation<MediaFetchEvent?, Error>?
        if buffer.isEmpty, let ww = waiter {
            waiter = nil
            w = ww
        } else {
            failure = error
        }
        onDemand = nil
        lock.unlock()
        if let w {
            if let error { w.resume(throwing: error) } else { w.resume(returning: nil) }
        }
    }

    /// The consumer went away (task cancelled or stream released).
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumerGone
    }

    /// Body bytes buffered and not yet taken by the consumer (diagnostics / tests).
    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferedBytes
    }

    // MARK: Consumer side

    func makeStream() -> AsyncThrowingStream<MediaFetchEvent, Error> {
        let token = ConsumerToken(self)
        return AsyncThrowingStream<MediaFetchEvent, Error>(unfolding: {
            try await token.pipe.next()
        })
    }

    func next() async throws -> MediaFetchEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MediaFetchEvent?, Error>) in
                self.dequeue(into: cont)
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Consumer gave up: drop buffered events, fail a pending `next()` with `MediaFetchError.cancelled`, and tell the
    /// producer (unless it had already finished).
    func cancel() {
        lock.lock()
        if consumerGone {
            lock.unlock()
            return
        }
        consumerGone = true
        buffer.removeAll()
        bufferedBytes = 0
        let w = waiter
        waiter = nil
        let notify = finished ? nil : onCancel
        finished = true
        failure = nil
        onCancel = nil
        onDemand = nil
        lock.unlock()
        w?.resume(throwing: MediaFetchError.cancelled)
        notify?()
    }

    private func dequeue(into cont: CheckedContinuation<MediaFetchEvent?, Error>) {
        lock.lock()
        if consumerGone {
            lock.unlock()
            cont.resume(throwing: MediaFetchError.cancelled)
            return
        }
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            bufferedBytes -= Self.byteCount(event)
            let demand = takeDemandLocked()
            lock.unlock()
            cont.resume(returning: event)
            demand?()
            return
        }
        if finished {
            let error = failure
            failure = nil
            lock.unlock()
            if let error { cont.resume(throwing: error) } else { cont.resume(returning: nil) }
            return
        }
        if waiter != nil {
            // Two concurrent next() calls (two iterators of one stream): not supported.
            lock.unlock()
            cont.resume(throwing: MediaFetchError.cancelled)
            return
        }
        waiter = cont
        let demand = takeDemandLocked()
        lock.unlock()
        demand?()
    }

    private func takeDemandLocked() -> (() -> Void)? {
        guard producerPaused, bufferedBytes < highWaterBytes, !finished, !consumerGone else { return nil }
        producerPaused = false
        return onDemand
    }

    private static func byteCount(_ event: MediaFetchEvent) -> Int {
        if case .data(let d) = event { return d.count }
        return 0
    }

    /// Owned only by the stream's unfolding closure: released with the stream + iterator → consumer is gone.
    private final class ConsumerToken: @unchecked Sendable {
        let pipe: MediaEventPipe
        init(_ pipe: MediaEventPipe) { self.pipe = pipe }
        deinit { pipe.cancel() }
    }
}
