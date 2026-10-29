import Foundation
import Combine

// 离线缓存 manager: the persisted task queue (FIFO, one download at a time by default), pause / resume / retry /
// delete, storage usage and the app lifecycle (downloads stop while the app is in the background and continue when
// it returns, from the bytes already on disk). The UI binds to it as an ObservableObject; the app-wide instance
// (`OfflineDownloadManager.shared`, live wiring) is defined in UI/Offline.

@MainActor
final class OfflineDownloadManager: ObservableObject {
    struct Dependencies {
        var layout: OfflineStorageLayout
        /// playurl → the file's URLs (and the quality the server returned).
        var resolveSource: (OfflineTask) async throws -> OfflineSource
        /// A fresh BTR downloader for every run.
        var makeDownloader: (_ config: @escaping () -> BTRConfig) -> BTRDownloading
        /// Live acceleration settings: CDN mode, custom hosts, threads, 加速 on / off.
        var settings: () -> AccelerationSettings
        var job = OfflineJobConfig()
        var maxActiveTasks = 1
        /// Progress is written to the manifest at most this often (state changes immediately).
        var persistIntervalMs: Double = 3000
        var clock: MonotonicClock = SystemClock.shared
        var now: () -> Date = { Date() }
    }

    /// Every task, in queue order (oldest first).
    @Published private(set) var tasks: [OfflineTask] = []
    /// Bytes per second of the running downloads, by task id.
    @Published private(set) var speeds: [String: Double] = [:]
    /// Free space on the device (nil when unknown), refreshed by `refreshStorage()`.
    @Published private(set) var freeDiskBytes: Int64?

    let dependencies: Dependencies
    private var active: [String: OfflineActiveRun] = [:]
    /// Runs of deleted tasks that are still winding down: a task queued again under the same id waits for them (one
    /// writer per file).
    private var draining: [String: OfflineActiveRun] = [:]
    /// The app is in the background: nothing starts until `resumeAfterSuspend()`.
    private var suspended = false
    private var lastPersistMs = -Double.infinity
    /// Restarts from zero after the file changed on the server, per task (at most one per app run).
    private var restarts: [String: Int] = [:]
    private let io = DispatchQueue(label: "bili.offline.io", qos: .utility)

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        let layout = dependencies.layout
        OfflineStorageIO.prepareRoot(layout.root)
        var loaded = OfflineStorageIO.readTasks(layout)
        for i in loaded.indices {
            switch loaded[i].state {
            case .downloading:
                // Interrupted by the app being killed: continue where the file stopped.
                loaded[i].state = .waiting
            case .completed where !FileManager.default.fileExists(atPath: layout.videoURL(for: loaded[i].id).path):
                loaded[i].state = .failed
                loaded[i].errorMessage = OfflineDownloadError.fileMissing.errorDescription
                loaded[i].written = OfflineRangeSet()
                loaded[i].totalBytes = 0
                loaded[i].completedAt = nil
            default:
                break
            }
        }
        tasks = loaded
        // Synchronously, before anything is queued: a new task may reuse the directory name of an orphan.
        OfflineStorageIO.removeOrphans(layout, keeping: Set(loaded.map(\.id)))
        refreshStorage()
        schedule()
    }

    // MARK: Queries

    /// 正在缓存: everything not completed, queue order.
    var pendingTasks: [OfflineTask] { tasks.filter { !$0.isCompleted } }

    /// 已缓存: newest first.
    var completedTasks: [OfflineTask] {
        tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    func task(id: String) -> OfflineTask? { tasks.first { $0.id == id } }

    func task(aid: Int64, bvid: String, cid: Int64) -> OfflineTask? {
        task(id: OfflineTask.makeID(aid: aid, bvid: bvid, cid: cid))
    }

    /// The finished file of a completed task (nil while downloading or when the file is gone).
    func localFileURL(for task: OfflineTask) -> URL? {
        guard task.isCompleted else { return nil }
        let url = dependencies.layout.videoURL(for: task.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A run of this task is still going (it may be winding down after 暂停).
    func isActive(_ id: String) -> Bool { active[id] != nil || draining[id] != nil }

    /// Bytes the cache takes on disk.
    var usedBytes: Int64 { tasks.reduce(0) { $0 + $1.receivedBytes } }

    /// No pending task is downloading or waiting (全部开始 instead of 全部暂停).
    var isAllPaused: Bool {
        pendingTasks.allSatisfy { $0.state == .paused || $0.state == .failed }
    }

    func refreshStorage() {
        freeDiskBytes = OfflineStorageIO.availableCapacity(at: dependencies.layout.root)
    }

    // MARK: Commands

    /// Queues new tasks. A task already in the list is not added again (a paused / failed one is resumed).
    /// Returns how many were added.
    @discardableResult
    func enqueue(_ new: [OfflineTask]) -> Int {
        var added = 0
        for var task in new {
            if let i = index(of: task.id) {
                if tasks[i].state == .paused || tasks[i].state == .failed {
                    tasks[i].state = .waiting
                    tasks[i].errorMessage = nil
                }
                continue
            }
            task.state = .waiting
            task.written = OfflineRangeSet()
            task.totalBytes = 0
            task.errorMessage = nil
            task.completedAt = nil
            task.lastPosition = 0
            task.createdAt = dependencies.now()
            tasks.append(task)
            added += 1
        }
        persist(force: true)
        schedule()
        return added
    }

    func pause(_ id: String) {
        guard let i = index(of: id), tasks[i].state == .waiting || tasks[i].state == .downloading else { return }
        tasks[i].state = .paused
        speeds[id] = nil
        active[id]?.cancel()
        persist(force: true)
        schedule()
    }

    /// 继续 / 重试.
    func resume(_ id: String) {
        guard let i = index(of: id), tasks[i].state == .paused || tasks[i].state == .failed else { return }
        tasks[i].state = .waiting
        tasks[i].errorMessage = nil
        persist(force: true)
        schedule()
    }

    /// Tap on a pending row: pause what runs or waits, resume what is paused or failed.
    func toggle(_ id: String) {
        guard let task = task(id: id) else { return }
        switch task.state {
        case .waiting, .downloading: pause(id)
        case .paused, .failed: resume(id)
        case .completed: break
        }
    }

    func pauseAll() {
        for task in pendingTasks where task.state == .waiting || task.state == .downloading {
            if let i = index(of: task.id) { tasks[i].state = .paused }
            speeds[task.id] = nil
            active[task.id]?.cancel()
        }
        persist(force: true)
    }

    func resumeAll() {
        for task in pendingTasks where task.state == .paused || task.state == .failed {
            if let i = index(of: task.id) {
                tasks[i].state = .waiting
                tasks[i].errorMessage = nil
            }
        }
        persist(force: true)
        schedule()
    }

    /// Removes the tasks and their files (a running download is stopped first).
    func delete(_ ids: [String]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        tasks.removeAll { doomed.contains($0.id) }
        for id in doomed {
            if let run = active.removeValue(forKey: id) {
                run.cancel()
                draining[id] = run
            }
            speeds[id] = nil
            removeFiles(id)
        }
        persist(force: true)
        schedule()
        refreshStorage()
    }

    /// Where 继续播放 starts next time.
    func savePosition(_ id: String, seconds: Double) {
        guard let i = index(of: id), seconds.isFinite else { return }
        let value = max(0, seconds)
        guard abs(tasks[i].lastPosition - value) >= 1 else { return }
        tasks[i].lastPosition = value
        persist(force: true)
    }

    // MARK: App lifecycle

    /// The app went to the background: running downloads stop (their bytes stay) and wait for the foreground.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (id, run) in active {
            if let i = index(of: id), tasks[i].state == .downloading { tasks[i].state = .waiting }
            speeds[id] = nil
            run.cancel()
        }
        persist(force: true)
    }

    /// The app is in the foreground again.
    func resumeAfterSuspend() {
        guard suspended else { return }
        suspended = false
        refreshStorage()
        schedule()
    }

    /// Blocks until queued manifest writes are done (tests, app termination).
    func flush() {
        io.sync {}
    }

    // MARK: Queue

    private func index(of id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    private func schedule() {
        guard !suspended else { return }
        for task in tasks where task.state == .waiting && active[task.id] == nil && draining[task.id] == nil {
            guard active.count < max(1, dependencies.maxActiveTasks) else { return }
            start(task.id)
        }
    }

    private func start(_ id: String) {
        guard let i = index(of: id) else { return }
        tasks[i].state = .downloading
        tasks[i].errorMessage = nil
        let snapshot = tasks[i]
        let settings = dependencies.settings()
        var config = dependencies.job
        config.accelerated = settings.enabled
        let downloader = dependencies.makeDownloader(Self.fixedConfig(Self.btrConfig(settings)))
        let job = OfflineDownloadJob(taskID: id, fileURL: dependencies.layout.partialURL(for: id),
                                     written: snapshot.written, total: snapshot.totalBytes, config: config,
                                     downloader: downloader, clock: dependencies.clock,
                                     resolve: Self.boundResolver(dependencies.resolveSource, task: snapshot))
        let run = OfflineActiveRun(job: job)
        active[id] = run
        // Detached: the job and its callbacks run off the main actor; results hop back to it.
        run.task = Task.detached(priority: .utility) { [weak self] in
            let outcome = await job.run(
                onSource: { source in
                    Task { @MainActor [weak self] in self?.runReported(id, job, source: source) }
                },
                onProgress: { progress in
                    Task { @MainActor [weak self] in self?.runReported(id, job, progress: progress) }
                })
            await self?.runFinished(id, job: job, outcome: outcome)
        }
        persist(force: true)
    }

    private func runReported(_ id: String, _ job: OfflineDownloadJob, source: OfflineSource) {
        guard active[id]?.job === job, let i = index(of: id), source.quality > 0 else { return }
        tasks[i].quality = source.quality
        tasks[i].qualityTitle = source.qualityTitle
    }

    private func runReported(_ id: String, _ job: OfflineDownloadJob, progress: OfflineJobProgress) {
        guard active[id]?.job === job, let i = index(of: id), tasks[i].state == .downloading else { return }
        tasks[i].written = progress.written
        tasks[i].totalBytes = progress.total
        speeds[id] = progress.bytesPerSecond
        persist(force: false)
    }

    private func runFinished(_ id: String, job: OfflineDownloadJob, outcome: OfflineJobOutcome) {
        if draining[id]?.job === job {
            // Deleted while it ran: it may have recreated the directory (unless the task was queued again).
            draining[id] = nil
            if index(of: id) == nil { removeFiles(id) }
            schedule()
            return
        }
        guard active[id]?.job === job else { return }
        active[id] = nil
        speeds[id] = nil
        guard let i = index(of: id) else {
            removeFiles(id)
            schedule()
            return
        }
        switch outcome {
        case .completed(let p):
            do {
                try OfflineStorageIO.finalize(dependencies.layout, id: id)
                tasks[i].state = .completed
                tasks[i].totalBytes = p.total
                tasks[i].written = OfflineRangeSet([ByteRange(start: 0, end: p.total - 1)])
                tasks[i].completedAt = dependencies.now()
                tasks[i].errorMessage = nil
            } catch {
                apply(p, at: i)
                tasks[i].state = .failed
                tasks[i].errorMessage = Self.message(for: OfflineFileWriter.mapped(error))
            }
            refreshStorage()
        case .cancelled(let p):
            apply(p, at: i)
            if tasks[i].state == .downloading { tasks[i].state = suspended ? .waiting : .paused }
        case .failed(let error, let p):
            apply(p, at: i)
            if (error as? OfflineDownloadError) == .sourceChanged, restarts[id, default: 0] < 1 {
                // A new file on the server: start it over once.
                restarts[id, default: 0] += 1
                tasks[i].written = OfflineRangeSet()
                tasks[i].totalBytes = 0
                if tasks[i].state == .downloading { tasks[i].state = .waiting }
            } else if tasks[i].state == .downloading {
                tasks[i].state = .failed
                tasks[i].errorMessage = Self.message(for: error)
            }
        }
        persist(force: true)
        schedule()
    }

    private func apply(_ progress: OfflineJobProgress, at i: Int) {
        tasks[i].written = progress.written
        tasks[i].totalBytes = progress.total
    }

    // MARK: Persistence

    private func persist(force: Bool) {
        let nowMs = dependencies.clock.nowMs()
        guard force || nowMs - lastPersistMs >= dependencies.persistIntervalMs else { return }
        lastPersistMs = nowMs
        let snapshot = tasks
        let layout = dependencies.layout
        io.async { OfflineStorageIO.writeTasks(snapshot, layout: layout) }
    }

    /// Synchronous (an unlink, even for a large file), so a task queued again right away never loses its new file.
    private func removeFiles(_ id: String) {
        try? FileManager.default.removeItem(at: dependencies.layout.directory(for: id))
    }

    // MARK: Helpers

    /// The user's CDN mode, custom hosts and 加速 switch, with a fixed thread count: `OfflineJobConfig.defaultThreads`
    /// for 自动 (the auto ladder follows the player's buffer, which a download does not have), else the manual one.
    nonisolated static func btrConfig(_ settings: AccelerationSettings) -> BTRConfig {
        var config = BTRConfig(settings: settings, maxAutoThreads: 32)
        config.autoConcurrency = false
        config.concurrency = settings.autoConcurrency
            ? OfflineJobConfig.defaultThreads : min(64, max(4, settings.manualConcurrency))
        return config
    }

    // Built outside the main actor so the closures are not main-actor isolated (the job calls them off it).
    private nonisolated static func fixedConfig(_ config: BTRConfig) -> () -> BTRConfig {
        { config }
    }

    private nonisolated static func boundResolver(_ resolve: @escaping (OfflineTask) async throws -> OfflineSource,
                                                  task: OfflineTask) -> () async throws -> OfflineSource {
        { try await resolve(task) }
    }

    /// The text of a failed task's 「缓存失败：…」 line.
    nonisolated static func message(for error: Error) -> String {
        if let e = error as? OfflineDownloadError { return e.errorDescription ?? "缓存失败" }
        if let e = error as? BTRError { return e.description }
        if error is MediaFetchError { return "网络连接失败" }
        if let e = error as? LocalizedError, let text = e.errorDescription, !text.isEmpty { return text }
        return error.localizedDescription
    }
}

/// One running download (main actor bookkeeping).
@MainActor
final class OfflineActiveRun {
    let job: OfflineDownloadJob
    var task: Task<Void, Never>?

    init(job: OfflineDownloadJob) {
        self.job = job
    }

    func cancel() { task?.cancel() }
}

// MARK: - Files

/// File system side of the cache (called on the manager's IO queue or at launch).
enum OfflineStorageIO {
    static func prepareRoot(_ root: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if canImport(Darwin)
        // Videos can be downloaded again: keep them out of iCloud / computer backups.
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    static func readTasks(_ layout: OfflineStorageLayout) -> [OfflineTask] {
        guard let data = try? Data(contentsOf: layout.manifestURL) else { return [] }
        return OfflineManifest.decode(data)
    }

    static func writeTasks(_ tasks: [OfflineTask], layout: OfflineStorageLayout) {
        guard let data = try? OfflineManifest.encode(tasks) else { return }
        prepareRoot(layout.root)
        try? data.write(to: layout.manifestURL, options: .atomic)
    }

    /// `video.mp4.part` → `video.mp4`.
    static func finalize(_ layout: OfflineStorageLayout, id: String) throws {
        let fm = FileManager.default
        let partial = layout.partialURL(for: id)
        let final = layout.videoURL(for: id)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: partial, to: final)
    }

    /// Task directories no task refers to (a crash during a delete).
    static func removeOrphans(_ layout: OfflineStorageLayout, keeping ids: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: layout.root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != OfflineStorageLayout.manifestName {
            let name = entry.lastPathComponent
            if !ids.contains(name), !name.hasPrefix(".") { try? fm.removeItem(at: entry) }
        }
    }

    /// Free space for user-initiated data ("important usage"), nil when unknown.
    static func availableCapacity(at url: URL) -> Int64? {
        #if canImport(Darwin)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        guard let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }
}

// MARK: - Source

/// The html5 progressive MP4 (one file, ≤ 1080P) — what AVPlayer can play straight from the sandbox.
enum OfflineProgressiveSource {
    static func resolve(_ task: OfflineTask) async throws -> OfflineSource {
        let info = try await VideoAPI.progressivePlayInfo(aid: task.aid, bvid: task.bvid, cid: task.cid,
                                                          qn: task.requestedQuality)
        return try source(from: info)
    }

    /// Only a single-segment response is a playable file (segments of an old split upload cannot be joined).
    static func source(from info: PlayInfo) throws -> OfflineSource {
        guard info.durl.count == 1, let segment = info.durl.first else { throw OfflineDownloadError.noSource }
        let urls = ([segment.url] + segment.backupURLs).map(\.biliHTTPS).filter { !$0.isEmpty }.btrDeduped()
        guard !urls.isEmpty else { throw OfflineDownloadError.noSource }
        let quality = info.quality
        let title = info.qualities.first { $0.qn == quality }?.title ?? VideoQuality.title(for: quality)
        return OfflineSource(urls: urls, quality: quality, qualityTitle: quality > 0 ? title : "")
    }

    /// The qualities offered in the 缓存 sheet: what playurl lists, at most 1080P (the html5 file's ceiling).
    static func cacheQualities(from info: PlayInfo) -> [QualityOption] {
        let limited = info.qualities.filter { $0.qn <= maxQuality && $0.qn > 0 }
        return limited.isEmpty ? fallbackQualities : limited
    }

    static let maxQuality = VideoQuality.q1080.rawValue

    /// When playurl cannot be asked: 1080P / 720P / 480P / 360P.
    static var fallbackQualities: [QualityOption] {
        [VideoQuality.q1080, .q720, .q480, .q360].map { QualityOption(qn: $0.rawValue, title: $0.title) }
    }

    /// The tier to preselect: the highest offered at or below `preferred`, else the lowest offered.
    static func defaultQuality(_ options: [QualityOption], preferred: Int) -> Int {
        let sorted = options.map(\.qn).sorted(by: >)
        return sorted.first { $0 <= preferred } ?? sorted.last ?? maxQuality
    }
}
