import Foundation

// One run of one offline task: resolve the CDN URLs (playurl), probe the file, then fetch every missing byte range
// with the BTR downloader — multi-CDN host swap, parallel pieces over many connections, hedging, ban list — with
// `lanes` ranges in flight, writing the bytes at their offsets in `video.mp4.part`. Cancelling the run (pause,
// delete, app going to background) keeps everything written so far; the next run fetches only what is missing.

/// What the CDN serves for a task (resolved again on every run and when the signed URLs are about to expire).
struct OfflineSource: Equatable {
    /// `durl[0]` url + backup urls, https.
    var urls: [String]
    /// The qn the server returned and its title ("1080P 高清").
    var quality: Int = 0
    var qualityTitle: String = ""
}

enum OfflineDownloadError: LocalizedError, Equatable {
    /// No single-file stream for this video (e.g. a multi-segment or DRM response).
    case noSource
    /// The CDN reports another size than the one of the part on disk, in the middle of a run.
    case sourceChanged
    case diskFull
    case writeFailed(String)
    case incomplete
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .noSource: return "该视频暂不支持缓存"
        case .sourceChanged: return "视频文件已更新，请重新缓存"
        case .diskFull: return "存储空间不足"
        case .writeFailed: return "写入缓存文件失败"
        case .incomplete: return "缓存未完成，请重试"
        case .fileMissing: return "缓存文件已丢失，请重新缓存"
        }
    }
}

/// Knobs of one run (tests shrink them).
struct OfflineJobConfig {
    /// BTR threads of a download when the acceleration setting is 自动.
    static let defaultThreads = 16

    var chunkBytes: Int64 = OfflineRangePlanner.defaultChunkBytes
    /// Ranges in flight at once. They share the downloader's connections, so the slow tail of one range does not
    /// leave the others idle.
    var lanes = 2
    /// Failed attempts of one chunk before the task fails (an attempt that wrote bytes resets the count).
    var attemptsPerChunk = 4
    /// false (加速 off): one connection to Bilibili's own URLs (`downloadDirect`), as the player does.
    var accelerated = true
    var retryPauseMs: Double = 1000
    var progressIntervalMs: Double = 500
    /// Signed URLs are refreshed this long before their `deadline=`.
    var refreshLeadSeconds: Double = URLRefreshPolicy.leadSeconds
}

struct OfflineJobProgress: Equatable {
    var written: OfflineRangeSet
    var total: Int64
    var bytesPerSecond: Double
}

enum OfflineJobOutcome {
    case completed(OfflineJobProgress)
    case cancelled(OfflineJobProgress)
    case failed(Error, OfflineJobProgress)
}

// MARK: - File

/// Positional writes into the partial file; several lanes write at once, each at its own offsets.
final class OfflineFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
                throw OfflineDownloadError.writeFailed("create")
            }
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Current length of the file.
    func size() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let end = try? handle.seekToEnd() else { return 0 }
        return Int64(end)
    }

    func write(_ data: Data, at offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            throw Self.mapped(error)
        }
    }

    func truncate(to size: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        do {
            try handle.truncate(atOffset: UInt64(max(0, size)))
        } catch {
            throw Self.mapped(error)
        }
    }

    func synchronize() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { try? handle.synchronize() }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    /// ENOSPC / `NSFileWriteOutOfSpaceError` → `.diskFull`, anything else → `.writeFailed`.
    static func mapped(_ error: Error) -> OfflineDownloadError {
        if let e = error as? OfflineDownloadError { return e }
        var current: NSError? = error as NSError
        while let ns = current {
            if (ns.domain == NSPOSIXErrorDomain && ns.code == 28) || (ns.domain == NSCocoaErrorDomain && ns.code == 640) {
                return .diskFull
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .writeFailed((error as NSError).localizedDescription)
    }
}

// MARK: - Job

final class OfflineDownloadJob: @unchecked Sendable {
    let taskID: String
    private let fileURL: URL
    private let config: OfflineJobConfig
    private let downloader: BTRDownloading
    private let resolve: () async throws -> OfflineSource
    private let clock: MonotonicClock
    private let wallClock: () -> Double

    private let lock = NSLock()
    private var written: OfflineRangeSet
    private var total: Int64
    /// What this run wrote (all of it comes from the file the probe saw).
    private var writtenThisRun = OfflineRangeSet()
    private var bytesThisRun: Int64 = 0
    private var lastSample: (at: Double, bytes: Int64)?
    private var smoothedSpeed: Double = 0

    init(taskID: String, fileURL: URL, written: OfflineRangeSet, total: Int64, config: OfflineJobConfig,
         downloader: BTRDownloading, clock: MonotonicClock = SystemClock.shared,
         wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 },
         resolve: @escaping () async throws -> OfflineSource) {
        self.taskID = taskID
        self.fileURL = fileURL
        self.written = written
        self.total = total
        self.config = config
        self.downloader = downloader
        self.clock = clock
        self.wallClock = wallClock
        self.resolve = resolve
    }

    /// Runs until the file is complete, the run is cancelled or a chunk keeps failing. `onSource` reports the
    /// resolved quality; `onProgress` fires every `progressIntervalMs` from a background task.
    func run(onSource: @escaping (OfflineSource) -> Void = { _ in },
             onProgress: @escaping (OfflineJobProgress) -> Void = { _ in }) async -> OfflineJobOutcome {
        let writer: OfflineFileWriter
        do {
            writer = try OfflineFileWriter(url: fileURL)
        } catch {
            return .failed(error, progress())
        }
        defer {
            writer.synchronize()
            writer.close()
            downloader.cancelAll()
        }
        // Bytes the manifest records but the file no longer holds (removed or truncated) are fetched again.
        keepOnly(fileSize: writer.size())
        let interval = config.progressIntervalMs
        let ticker = Task { [weak self] in
            while true {
                do { try await btrSleep(ms: interval) } catch { return }
                guard let self else { return }
                onProgress(self.progress(sampling: true))
            }
        }
        defer { ticker.cancel() }
        do {
            try await download(writer: writer, onSource: onSource)
            writer.synchronize()
            return .completed(progress())
        } catch {
            if Task.isCancelled || error.btrIsCancellation { return .cancelled(progress()) }
            return .failed(error, progress())
        }
    }

    private func download(writer: OfflineFileWriter, onSource: (OfflineSource) -> Void) async throws {
        let source = try await resolve()
        guard !source.urls.isEmpty else { throw OfflineDownloadError.noSource }
        onSource(source)
        let refresher = OfflineURLRefresher(source: source, leadSeconds: config.refreshLeadSeconds,
                                            wallClock: wallClock, resolve: resolve)
        let track = downloader.makeTrack(kind: .video, urls: source.urls, routeKey: "offline:\(taskID)")

        // 1. Probe: the CDN's file size (a size other than the one the stored bytes belong to = a new file).
        try await probe(track: track, writer: writer, refresher: refresher)
        let known = progress()
        guard known.total > 0 else { throw OfflineDownloadError.incomplete }

        // 2. Everything still missing, `lanes` ranges at a time over the downloader's shared connections.
        let chunks = OfflineRangePlanner.chunks(missing: known.written.missing(total: known.total),
                                                chunkBytes: config.chunkBytes)
        let queue = OfflineChunkQueue(chunks)
        let lanes = max(1, min(config.lanes, chunks.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<lanes {
                group.addTask {
                    while let chunk = queue.next() {
                        try await self.fetch(chunk, track: track, writer: writer, refresher: refresher)
                    }
                }
            }
            try await group.waitForAll()
        }
        let done = progress()
        guard done.written.covers(total: done.total) else { throw OfflineDownloadError.incomplete }
        // A longer file left over from a bigger earlier version.
        if writer.size() > done.total { try writer.truncate(to: done.total) }
    }

    /// The metadata race over the head of the file; fixes the file size.
    private func probe(track: BTRTrackHandle, writer: OfflineFileWriter, refresher: OfflineURLRefresher) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            await refresher.refreshIfExpiring(track)
            do {
                // A file shorter than the probe is clipped by the CDN, which the metadata race accepts.
                let fileTotal = try await transfer(OfflineRangePlanner.probeRange, kind: .meta, direct: false,
                                                   track: track, writer: writer)
                try adopt(fileTotal: fileTotal, probing: true)
                return
            } catch {
                failures += 1
                try await recover(from: error, failures: failures, track: track, refresher: refresher)
            }
        }
    }

    /// Downloads what is missing of `chunk`. From the second failure in a row without progress on, it uses one
    /// plain connection to Bilibili's own URLs (the player's fallback).
    private func fetch(_ chunk: ByteRange, track: BTRTrackHandle, writer: OfflineFileWriter,
                       refresher: OfflineURLRefresher) async throws {
        var failures = 0
        var direct = !config.accelerated
        while let range = missingPart(of: chunk) {
            try Task.checkCancellation()
            await refresher.refreshIfExpiring(track)
            let before = writtenBytes(in: chunk)
            do {
                let fileTotal = try await transfer(range, kind: .ordinary, direct: direct, track: track, writer: writer)
                try adopt(fileTotal: fileTotal, probing: false)
            } catch {
                failures = writtenBytes(in: chunk) > before ? 0 : failures + 1
                if failures >= 2 { direct = true }
                try await recover(from: error, failures: failures, track: track, refresher: refresher)
            }
        }
    }

    /// After a failed attempt: rethrows cancellation, local errors and a failure past the attempt budget; otherwise
    /// pauses (longer each time) and fetches fresh URLs — a refused or expired signed URL is the usual cause.
    private func recover(from error: Error, failures: Int, track: BTRTrackHandle,
                         refresher: OfflineURLRefresher) async throws {
        if Task.isCancelled || error.btrIsCancellation { throw CancellationError() }
        if error is OfflineDownloadError { throw error }
        guard failures < config.attemptsPerChunk else { throw error }
        try await btrSleep(ms: config.retryPauseMs * Double(max(1, failures)))
        await refresher.refresh(track)
    }

    private func transfer(_ range: ByteRange, kind: BTRRangeKind, direct: Bool, track: BTRTrackHandle,
                          writer: OfflineFileWriter) async throws -> Int64 {
        let cursor = OfflineWriteCursor(range.start)
        let sink: (Data) async throws -> Void = { [weak self] data in
            guard let self else { throw CancellationError() }
            try self.store(data, cursor: cursor, limit: range.end, writer: writer)
        }
        if direct {
            return try await downloader.downloadDirect(range, track: track, onBytes: sink)
        }
        let priority = kind == .meta ? BTRConstants.startupPriority : 100
        return try await downloader.download(range, track: track, kind: kind, priority: priority, deadline: nil,
                                             onBytes: sink)
    }

    // MARK: State (lock-protected; only synchronous functions take the lock)

    private func store(_ data: Data, cursor: OfflineWriteCursor, limit: Int64, writer: OfflineFileWriter) throws {
        let offset = cursor.value
        guard !data.isEmpty, offset <= limit else { return }
        let usable = Int(min(Int64(data.count), limit - offset + 1))
        try writer.write(usable == data.count ? data : data.prefix(usable), at: offset)
        cursor.value = offset + Int64(usable)
        let r = ByteRange(start: offset, end: offset + Int64(usable) - 1)
        lock.lock()
        written.insert(r)
        writtenThisRun.insert(r)
        bytesThisRun += Int64(usable)
        lock.unlock()
    }

    /// Fixes the file size. In the probe a new size restarts the file with only the bytes of this run; later it
    /// cannot differ (the BTR track rejects responses with another total), and if it does the run fails.
    private func adopt(fileTotal: Int64, probing: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileTotal != total else { return }
        guard probing else { throw OfflineDownloadError.sourceChanged }
        if total > 0 { written = writtenThisRun.clipped(to: fileTotal) }
        total = fileTotal
        written = written.clipped(to: fileTotal)
    }

    private func missingPart(of chunk: ByteRange) -> ByteRange? {
        lock.lock()
        defer { lock.unlock() }
        return written.missing(in: chunk).first
    }

    private func writtenBytes(in chunk: ByteRange) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return chunk.length - written.missing(in: chunk).reduce(0) { $0 + $1.length }
    }

    private func keepOnly(fileSize: Int64) {
        lock.lock()
        written = written.clipped(to: fileSize)
        lock.unlock()
    }

    /// Snapshot; `sampling` also updates the smoothed speed (bytes written per second, 0.6 / 0.4 EWMA).
    func progress(sampling: Bool = false) -> OfflineJobProgress {
        lock.lock()
        defer { lock.unlock() }
        if sampling {
            let now = clock.nowMs()
            if let last = lastSample, now > last.at {
                let bps = Double(bytesThisRun - last.bytes) * 1000 / (now - last.at)
                smoothedSpeed = smoothedSpeed > 0 ? smoothedSpeed * 0.6 + bps * 0.4 : bps
            }
            lastSample = (now, bytesThisRun)
        }
        return OfflineJobProgress(written: written, total: total, bytesPerSecond: smoothedSpeed)
    }
}

/// Next offset of one transfer (its `onBytes` calls are sequential).
final class OfflineWriteCursor: @unchecked Sendable {
    var value: Int64
    init(_ value: Int64) { self.value = value }
}

/// The chunks of a run, taken one at a time by the lanes.
final class OfflineChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [ByteRange]
    private var index = 0

    init(_ chunks: [ByteRange]) {
        self.chunks = chunks
    }

    func next() -> ByteRange? {
        lock.lock()
        defer { lock.unlock() }
        guard index < chunks.count else { return nil }
        index += 1
        return chunks[index - 1]
    }
}

/// Fresh signed URLs from playurl for a running job: shortly before `deadline=`, and after a failed attempt.
/// Coalesced (one request at a time, at most one per 15 s); a failed refresh keeps the old URLs.
actor OfflineURLRefresher {
    static let minimumGapSeconds: Double = 15

    private let resolve: () async throws -> OfflineSource
    private let wallClock: () -> Double
    private let leadSeconds: Double
    private var deadline: Double?
    private var lastAttempt: Double?
    private var inFlight: Task<OfflineSource?, Never>?

    init(source: OfflineSource, leadSeconds: Double, wallClock: @escaping () -> Double,
         resolve: @escaping () async throws -> OfflineSource) {
        self.resolve = resolve
        self.wallClock = wallClock
        self.leadSeconds = leadSeconds
        deadline = source.urls.compactMap(URLRefreshPolicy.deadline(of:)).min()
    }

    func refreshIfExpiring(_ track: BTRTrackHandle) async {
        guard let deadline, wallClock() >= deadline - leadSeconds else { return }
        await refresh(track)
    }

    func refresh(_ track: BTRTrackHandle) async {
        if let inFlight {
            _ = await inFlight.value
            return
        }
        let now = wallClock()
        if let last = lastAttempt, now - last < Self.minimumGapSeconds { return }
        lastAttempt = now
        let resolve = self.resolve
        let task = Task<OfflineSource?, Never> { try? await resolve() }
        inFlight = task
        let fresh = await task.value
        inFlight = nil
        guard let fresh, !fresh.urls.isEmpty else { return }
        deadline = fresh.urls.compactMap(URLRefreshPolicy.deadline(of:)).min()
        track.updateURLs(fresh.urls)
    }
}
