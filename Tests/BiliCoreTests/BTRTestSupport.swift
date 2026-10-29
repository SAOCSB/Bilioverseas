import Foundation
import XCTest
@testable import BiliCore

/// Manually advanced monotonic clock.
final class BTRManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double

    init(_ start: Double = 100_000) { now = start }

    func nowMs() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(_ ms: Double) {
        lock.lock()
        now += ms
        lock.unlock()
    }
}

/// `https://<host>/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&os=x` (BTR test fixture).
func btrMediaURL(_ host: String, file: String = "1-1-30080") -> String {
    "https://\(host)/upgcxcode/00/00/1/\(file).m4s?deadline=1&os=x"
}

func btrHosts(_ urls: [String]) -> [String] { urls.map { URLComponents(string: $0)?.host ?? "" } }

/// Byte pattern of the fake file: byte i = i % 251.
func btrPattern(_ start: Int64, _ length: Int) -> Data {
    var d = Data(count: length)
    d.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<length { p[i] = UInt8((start + Int64(i)) % 251) }
    }
    return d
}

/// In-memory CDN: every host serves the same file (pattern bytes) unless told otherwise.
final class FakeMediaClient: MediaHTTPClient, @unchecked Sendable {
    enum Behavior {
        /// 206, whole body at once (after `headDelayMs`).
        case ok
        /// 206 with the body in `chunk`-byte steps every `intervalMs`.
        case trickle(chunk: Int, intervalMs: Double)
        /// Status code, empty body.
        case status(Int)
        /// 200 with the whole file, ignoring Range.
        case ignoreRange
        /// 206 claiming a range one byte off.
        case wrongRange
        /// 206 whose body stops after `bytes` and then fails.
        case truncated(bytes: Int)
        /// 206 whose body is longer than the Content-Range.
        case oversized
        /// 206 reporting another file total.
        case otherTotal
        /// Headers only after `ms`.
        case slowHead(ms: Double)
        /// Never answers.
        case hang
        /// The first `count` requests answer `status`, then ok.
        case failFirst(count: Int, status: Int)
    }

    struct Request: Equatable {
        var host: String
        var url: String
        var range: ByteRange
        var at: Double
    }

    let total: Int64
    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var log: [Request] = []
    private var perHostCount: [String: Int] = [:]
    var defaultBehavior: Behavior = .ok
    var headDelayMs: Double = 0

    init(total: Int64 = 8 * 1024 * 1024) { self.total = total }

    func set(_ host: String, _ behavior: Behavior) {
        lock.lock()
        behaviors[host] = behavior
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func count(_ host: String) -> Int { requests.filter { $0.host == host }.count }

    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error> {
        let host = url.host ?? ""
        lock.lock()
        log.append(Request(host: host, url: url.absoluteString, range: range, at: SystemClock.shared.nowMs()))
        let n = (perHostCount[host] ?? 0) + 1
        perHostCount[host] = n
        var behavior = behaviors[host] ?? defaultBehavior
        if case let .failFirst(count, status) = behavior { behavior = n <= count ? .status(status) : .ok }
        lock.unlock()
        let total = self.total
        let headDelay = headDelayMs
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let length = Int(range.end - range.start + 1)
                    let cr = ["content-range": "bytes \(range.start)-\(range.end)/\(total)"]
                    if headDelay > 0 { try await Task.sleep(nanoseconds: UInt64(headDelay * 1_000_000)) }
                    switch behavior {
                    case .ok, .failFirst:
                        continuation.yield(.head(status: 206, headers: cr))
                        continuation.yield(.data(btrPattern(range.start, length)))
                    case let .trickle(chunk, interval):
                        continuation.yield(.head(status: 206, headers: cr))
                        var sent = 0
                        while sent < length {
                            let n = min(chunk, length - sent)
                            continuation.yield(.data(btrPattern(range.start + Int64(sent), n)))
                            sent += n
                            if sent < length { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000)) }
                        }
                    case let .status(s):
                        continuation.yield(.head(status: s, headers: [:]))
                    case .ignoreRange:
                        continuation.yield(.head(status: 200, headers: ["content-length": "\(total)"]))
                        continuation.yield(.data(btrPattern(0, min(Int(total), 256 * 1024))))
                    case .wrongRange:
                        continuation.yield(.head(status: 206, headers: ["content-range": "bytes \(range.start + 1)-\(range.end)/\(total)"]))
                        continuation.yield(.data(btrPattern(range.start + 1, length - 1)))
                    case let .truncated(bytes):
                        continuation.yield(.head(status: 206, headers: cr))
                        continuation.yield(.data(btrPattern(range.start, min(bytes, length))))
                        throw MediaFetchError.connectionClosed
                    case .oversized:
                        continuation.yield(.head(status: 206, headers: cr))
                        continuation.yield(.data(btrPattern(range.start, length + 100)))
                    case .otherTotal:
                        continuation.yield(.head(status: 206, headers: ["content-range": "bytes \(range.start)-\(range.end)/\(total + 1)"]))
                        continuation.yield(.data(btrPattern(range.start, length)))
                    case let .slowHead(ms):
                        try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
                        continuation.yield(.head(status: 206, headers: cr))
                        continuation.yield(.data(btrPattern(range.start, length)))
                    case .hang:
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? MediaFetchError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func preconnect(hosts: [String]) {}
    func closeIdleConnections() {}
    var openConnectionCount: Int { 0 }
}

/// Collects `onBytes` deliveries.
final class BTRByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var calls: [(at: Double, count: Int)] = []

    func add(_ d: Data) {
        lock.lock()
        data.append(d)
        calls.append((SystemClock.shared.nowMs(), d.count))
        lock.unlock()
    }

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    var deliveries: [(at: Double, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
