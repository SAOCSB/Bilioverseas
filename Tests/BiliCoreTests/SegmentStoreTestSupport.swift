import Foundation
@testable import BiliCore

// Fakes shared by the engine tests (SidxParser / HLS / SegmentStore / PrefetchPlanner / AccelerationEngine /
// LocalProxyServer). Names are prefixed `Engine` to stay unique in the test target.

final class EngineTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ start: Double = 1_000_000) { value = start }

    func nowMs() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(ms: Double) {
        lock.lock()
        value += ms
        lock.unlock()
    }
}

/// An async gate: `wait()` suspends until `open()` (cancellable).
final class EngineAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        for w in all { w.resume() }
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    c.resume()
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = c
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            let w = self.waiters.removeValue(forKey: id)
            self.lock.unlock()
            w?.resume(throwing: CancellationError())
        }
    }
}

final class EngineFakeTrack: BTRTrackHandle, @unchecked Sendable {
    let kind: MediaKind
    private let lock = NSLock()
    private var storedURLs: [String]
    private var storedTotal: Int64?
    private(set) var updateCount = 0

    init(kind: MediaKind, urls: [String]) {
        self.kind = kind
        storedURLs = urls
    }

    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }

    var total: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return storedTotal
    }

    func setTotal(_ t: Int64) {
        lock.lock()
        storedTotal = t
        lock.unlock()
    }

    func updateURLs(_ urls: [String]) {
        lock.lock()
        storedURLs = urls
        updateCount += 1
        lock.unlock()
    }

    func nodeStatus() -> [CDNNodeStatus] {
        urls.compactMap { URLComponents(string: $0)?.host }.map {
            CDNNodeStatus(host: $0, state: .untested, bytesPerSecond: 0)
        }
    }
}

struct EngineFakeError: Error, Equatable {
    var message = "fake failure"
}

/// Serves byte ranges of in-memory files, recording every call.
final class EngineFakeDownloader: BTRDownloading, @unchecked Sendable {
    struct Call: Equatable {
        var kind: MediaKind
        var range: ByteRange
        /// nil for `downloadDirect`.
        var rangeKind: BTRRangeKind?
        var priority: Int?
        var direct: Bool { rangeKind == nil }
    }

    private let lock = NSLock()
    private var files: [MediaKind: Data]
    private var recorded: [Call] = []
    private var cancelled: [Call] = []
    private var tracks: [EngineFakeTrack] = []
    private var cancelAllCalls = 0
    /// Accelerated calls left that fail after `failAfterBytes` bytes.
    var acceleratedFailures = 0
    var directFailures = 0
    var failAfterBytes = 0
    var chunkSize = 16 * 1024
    /// Calls matching this wait on `gate` before delivering bytes.
    var gate: EngineAsyncGate?
    var gated: ((Call) -> Bool)?

    init(files: [MediaKind: Data]) {
        self.files = files
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var cancelledCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var cancelAllCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelAllCalls
    }

    var madeTracks: [EngineFakeTrack] {
        lock.lock()
        defer { lock.unlock() }
        return tracks
    }

    func makeTrack(kind: MediaKind, urls: [String], routeKey: String) -> BTRTrackHandle {
        let track = EngineFakeTrack(kind: kind, urls: urls)
        lock.lock()
        tracks.append(track)
        lock.unlock()
        return track
    }

    func download(_ range: ByteRange, track: BTRTrackHandle, kind: BTRRangeKind, priority: Int,
                  deadline: (() -> Double?)?, onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let call = Call(kind: track.kind, range: range, rangeKind: kind, priority: priority)
        lock.lock()
        recorded.append(call)
        let fail = acceleratedFailures > 0
        if fail { acceleratedFailures -= 1 }
        lock.unlock()
        return try await serve(call, track: track, fail: fail, clip: kind == .meta, onBytes: onBytes)
    }

    func downloadDirect(_ range: ByteRange, track: BTRTrackHandle,
                        onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        let call = Call(kind: track.kind, range: range, rangeKind: nil, priority: nil)
        lock.lock()
        recorded.append(call)
        let fail = directFailures > 0
        if fail { directFailures -= 1 }
        lock.unlock()
        return try await serve(call, track: track, fail: fail, clip: false, onBytes: onBytes)
    }

    private func serve(_ call: Call, track: BTRTrackHandle, fail: Bool, clip: Bool,
                       onBytes: @escaping (Data) async throws -> Void) async throws -> Int64 {
        do {
            if let gate, gated?(call) ?? true { try await gate.wait() }
            lock.lock()
            let file = files[call.kind] ?? Data()
            let failAfter = failAfterBytes
            let size = chunkSize
            lock.unlock()
            let total = Int64(file.count)
            var end = call.range.end
            if end >= total {
                guard clip, call.range.start < total else { throw EngineFakeError(message: "416") }
                end = total - 1
            }
            (track as? EngineFakeTrack)?.setTotal(total)
            var offset = call.range.start
            var delivered = 0
            while offset <= end {
                try Task.checkCancellation()
                if fail && delivered >= failAfter { throw EngineFakeError() }
                var n = min(Int64(size), end - offset + 1)
                if fail { n = min(n, Int64(failAfter - delivered)) }
                let chunk = file.subdata(in: Int(offset)..<Int(offset + n))
                try await onBytes(chunk)
                offset += n
                delivered += Int(n)
                await Task.yield()
            }
            if fail { throw EngineFakeError() }
            return total
        } catch {
            if error is CancellationError || Task.isCancelled {
                lock.lock()
                cancelled.append(call)
                lock.unlock()
                throw CancellationError()
            }
            throw error
        }
    }

    var stats: BTRStats {
        var s = BTRStats()
        s.threads = 8
        s.totalBytes = 1234
        return s
    }

    func cancelAll() {
        lock.lock()
        cancelAllCalls += 1
        lock.unlock()
    }
}

final class EngineFakeAuto: AutoConcurrencySignals, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var threads: Int { 16 }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name] ?? 0
    }

    private func bump(_ name: String) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    func newSession() { bump("newSession") }
    func stall() { bump("stall") }
    func buffer(ahead: Double, playing: Bool, cacheFull: Bool) { bump("buffer") }
}

final class EngineFakeServer: LocalProxyServing {
    var port: UInt16 = 54321
    var onPortChange: ((UInt16) -> Void)?
    private(set) var startCount = 0
    private(set) var ensureCount = 0
    func start() { startCount += 1 }
    func waitUntilReady(timeout: TimeInterval) async throws -> UInt16 { port }
    func ensureListening() { ensureCount += 1 }
    func stop() {}
}

final class EngineFakeMediaClient: MediaHTTPClient, @unchecked Sendable {
    let name: String
    var events: [MediaFetchEvent] = []
    var error: Error?
    private(set) var getCount = 0
    private(set) var idleCloses = 0

    init(name: String) { self.name = name }

    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error> {
        getCount += 1
        let events = self.events
        let error = self.error
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
    }

    func preconnect(hosts: [String]) {}
    func closeIdleConnections() { idleCloses += 1 }
    var openConnectionCount: Int { 0 }
}

/// A synthetic fragmented-MP4-shaped file: ftyp + moov + sidx + media segments (deterministic bytes).
enum EngineSyntheticMP4 {
    struct File {
        var data: Data
        var initRange: ByteRange
        var indexRange: ByteRange
        var segments: [ByteRange]
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }

    struct Reference {
        var size: UInt32
        var duration: UInt32
        var type: UInt32 = 0
    }

    /// A sidx box. `boxSize` pads the box (trailing bytes inside it); `largesize` uses the 64-bit size form.
    static func sidxBox(version: UInt8 = 0, timescale: UInt32, earliest: UInt64 = 0, firstOffset: UInt64 = 0,
                        references: [Reference], largesize: Bool = false, boxSize: Int? = nil) -> Data {
        var body: [UInt8] = [version, 0, 0, 0]
        body += be32(1) // reference_ID
        body += be32(timescale)
        if version == 0 {
            body += be32(UInt32(earliest)) + be32(UInt32(firstOffset))
        } else {
            body += be64(earliest) + be64(firstOffset)
        }
        body += be16(0) + be16(UInt16(references.count))
        for r in references {
            body += be32(r.type << 31 | r.size)
            body += be32(r.duration)
            body += be32(0x9000_0000)
        }
        let header = largesize ? 16 : 8
        let size = max(boxSize ?? 0, header + body.count)
        body += [UInt8](repeating: 0, count: size - header - body.count)
        var out: [UInt8] = largesize ? be32(1) + Array("sidx".utf8) + be64(UInt64(size))
                                     : be32(UInt32(size)) + Array("sidx".utf8)
        out += body
        return Data(out)
    }

    static func box(_ type: String, size: Int) -> Data {
        var out = be32(UInt32(size)) + Array(type.utf8)
        out += (0..<(size - 8)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        return Data(out)
    }

    static func make(segmentSizes: [Int], durations: [UInt32], timescale: UInt32 = 1000, version: UInt8 = 0,
                     moovSize: Int = 1000, trailing: Int = 0, seed: Int = 1) -> File {
        var data = Data()
        data.append(box("ftyp", size: 24))
        data.append(box("moov", size: moovSize))
        let initRange = ByteRange(start: 0, end: Int64(data.count) - 1)
        let refs = zip(segmentSizes, durations).map { Reference(size: UInt32($0), duration: $1) }
        let sidx = sidxBox(version: version, timescale: timescale, references: refs)
        let indexStart = Int64(data.count)
        data.append(sidx)
        let indexRange = ByteRange(start: indexStart, end: Int64(data.count) - 1)
        var segments: [ByteRange] = []
        for size in segmentSizes {
            let start = Int64(data.count)
            data.append(pattern(count: size, offset: Int(start), seed: seed))
            segments.append(ByteRange(start: start, end: Int64(data.count) - 1))
        }
        if trailing > 0 { data.append(box("free", size: trailing)) }
        return File(data: data, initRange: initRange, indexRange: indexRange, segments: segments)
    }

    /// Deterministic bytes (fast in debug builds).
    static func pattern(count: Int, offset: Int = 0, seed: Int = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBufferPointer { buffer in
            var value = UInt8(truncatingIfNeeded: offset &* 31 &+ seed)
            for i in 0..<count {
                buffer[i] = value
                value = value &+ 31
            }
        }
        return Data(bytes)
    }

    /// A DashStream describing `file` on a whitelisted Bilibili host.
    static func stream(_ kind: MediaKind, file: File, id: Int = 80, codecs: String = "avc1.640032",
                       bandwidth: Int = 2_000_000, host: String = "upos-sz-mirrorali.bilivideo.com",
                       deadline: Int? = nil) -> DashStream {
        let query = deadline.map { "?deadline=\($0)&os=x" } ?? "?os=x"
        let name = kind == .video ? "1-1-100026.m4s" : "1-1-30280.m4s"
        return DashStream(kind: kind, id: id, baseURL: "https://\(host)/upgcxcode/00/00/1/\(name)\(query)",
                          backupURLs: ["https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/00/00/1/\(name)\(query)"],
                          bandwidth: bandwidth, mimeType: kind == .video ? "video/mp4" : "audio/mp4",
                          codecs: kind == .video ? codecs : "mp4a.40.2", codecId: kind == .video ? 7 : 0,
                          width: kind == .video ? 1920 : 0, height: kind == .video ? 1080 : 0,
                          frameRate: kind == .video ? 29.412 : 0,
                          initRange: file.initRange.description, indexRange: file.indexRange.description)
    }
}

/// Polls `condition` until true or `timeout` seconds pass.
func engineEventually(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Drains a body source into one Data.
func engineDrain(_ source: LocalProxyBodySource) async throws -> Data {
    var out = Data()
    while let chunk = try await source.nextChunk() { out.append(chunk) }
    return out
}
