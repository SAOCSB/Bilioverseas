import Foundation

// The playback acceleration engine used by the player: one loopback HTTP listener for the app, and one
// `PlaybackSession` per AVPlayerItem. A session turns a Bilibili DASH pair (video + audio fMP4 with sidx) into a
// local HLS stream (`/<token>/master.m3u8`), or proxies a progressive MP4 (`/<token>/p.mp4`), and serves every media
// byte through its own BTR downloader (multi-CDN, multi-connection) — or, with acceleration off, through the same
// downloader's single-connection path. AVPlayer never talks to the CDN.
//
// Everything here is Foundation-only (Linux-testable with a fake server / downloader). The concrete Network-based
// pieces (LocalProxyServer, H1MediaClient …) are wired in `Dependencies.live` at the bottom, under
// `#if canImport(Network)`.
//
// Player wiring (AVPlayer → engine):
// - App launch: `AccelerationEngine.maxAutoThreads = isPad ? 64 : 32`, then `AccelerationEngine.shared.startIfNeeded()`;
//   `willEnterForeground` → `applicationWillEnterForeground()`, `didEnterBackground` → `applicationDidEnterBackground()`.
// - New item / quality change: close the previous session, `let s = try await engine.prepare(request)` (or
//   `prepareProgressive`), `AVURLAsset(url: s.url)` — no custom headers needed — and keep `s` alive with the item.
//   On a thrown error retry once with `accelerate: false`, then fall back to the progressive path / show the error.
//   Pass `refreshURLs` (DASH: `PlaybackRequest.refreshURLs`; durl: `progressiveRefresher`) so expiring signed URLs
//   are renewed in place.
// - Settings: `AppSettings.acceleration` posts `AppSettings.accelerationDidChange` on every change; the engine copies
//   it into its thread-safe snapshot right away, so a change made while nothing plays applies to the next session.
// - `preferredForwardBufferDuration = settings.forwardBufferSeconds`.
// - 0.25 s periodic time observer → `s.update(time:rate:playing:bufferedAhead:cacheFull:)`: bufferedAhead = end of
//   the `loadedTimeRanges` entry containing currentTime − currentTime; playing = `timeControlStatus == .playing`
//   and not seeking; cacheFull = bufferedAhead ≥ preferredForwardBufferDuration − 1.
// - `timeControlStatus == .waitingToPlayAtSpecifiedRate` with `reasonForWaitingToPlay == .toMinimizeStalls` after
//   playback started (not while seeking / starting), or `AVPlayerItemPlaybackStalled` → `s.playerDidStall()`.
// - Before every `seek(to:)` → `s.playerWillSeek(to:outsideBuffer:)` (outsideBuffer = no loadedTimeRange contains it).
// - Item replaced / player closed → `s.close()`. Stats overlay: `s.stats` (1 Hz is plenty).
// - `s.isEndpointValid == false` (the listener had to change port) → rebuild the item at the current time.

// MARK: - Public API types

struct PlaybackRequest {
    /// Ban-list scope, e.g. "BV1xx411c7mD:p1" or "ep12345".
    var routeKey: String
    var video: DashStream
    var audio: DashStream?
    /// Seconds (playurl `dash.duration`).
    var duration: Double
    /// false → single-connection `downloadDirect` through the proxy.
    var accelerate: Bool
    /// false → Dolby Vision 8.x is announced as its HEVC base layer only (no SUPPLEMENTAL-CODECS).
    var allowHDR: Bool
    /// Fresh signed URLs for the same representations (URL expiry, or every node failing).
    var refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))?

    init(routeKey: String, video: DashStream, audio: DashStream?, duration: Double, accelerate: Bool,
         allowHDR: Bool, refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))? = nil) {
        self.routeKey = routeKey
        self.video = video
        self.audio = audio
        self.duration = duration
        self.accelerate = accelerate
        self.allowHDR = allowHDR
        self.refreshURLs = refreshURLs
    }
}

/// Snapshot for the in-player statistics overlay.
struct AccelerationStats {
    var accelerated: Bool = false
    var threads: Int = 0
    var activeConnections: Int = 0
    var bytesPerSecond: Double = 0
    var autoReason: String = ""
    var nodes: [CDNNodeStatus] = []
    var cachedAheadSeconds: Double = 0
    var totalBytes: Int64 = 0
    var hedgedBytes: Int64 = 0
    var fallbackActive: Bool = false
}

enum AccelerationEngineError: LocalizedError, Equatable {
    case serverUnavailable
    case noAllowedURL
    case unsupportedFormat(String)
    case metadata(String)
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .serverUnavailable: return "本地播放服务启动失败"
        case .noAllowedURL: return "没有可用的 B 站视频地址"
        case .unsupportedFormat(let f): return "系统播放器不支持该视频格式（\(f)）"
        case .metadata(let m): return "读取视频索引失败：\(m)"
        case .timeout: return "加载视频索引超时"
        case .closed: return "播放会话已关闭"
        }
    }
}

// MARK: - Engine

final class AccelerationEngine: LocalProxyRequestHandler {
    struct Dependencies {
        var makeServer: (LocalProxyRequestHandler) -> LocalProxyServing
        /// The normal upstream client (H1MediaClient).
        var makePrimaryClient: () -> MediaHTTPClient
        /// Used when `forceURLSessionTransport` is set or the primary keeps failing TLS (URLSessionMediaClient).
        var makeFallbackClient: () -> MediaHTTPClient
        var makeDownloader: (_ config: @escaping () -> BTRConfig, _ client: MediaHTTPClient) -> BTRDownloading
        var auto: AutoConcurrencySignals?
        /// Live settings (read on the main thread when possible, see `refreshSettings`).
        var settings: () -> AccelerationSettings
        /// Posted (on the main thread) whenever those settings change: the engine re-reads them at once instead of
        /// waiting for the next playing session's tick.
        var settingsDidChange: Notification.Name? = nil
        var clock: MonotonicClock = SystemClock.shared
        /// Epoch seconds (URL `deadline=` comparison).
        var wallClock: () -> Double = { Date().timeIntervalSince1970 }
        var cacheBudgetBytes: Int64 = SegmentStore.defaultBudgetBytes()
        /// Upper bound for loading init + sidx of a session.
        var metadataTimeout: TimeInterval = 10
        var serverReadyTimeout: TimeInterval = 3
        /// URL-expiry check cadence of every session.
        var refreshCheckInterval: TimeInterval = 5
        var maxSessions = 4
    }

    private static let staticLock = NSLock()
    private static var maxAutoThreadsValue = 32
    private static var forceURLSessionValue = false

    /// Top of the auto-concurrency ladder on this device. The app sets 64 on iPad (Core cannot see UIDevice).
    static var maxAutoThreads: Int {
        get {
            staticLock.lock()
            defer { staticLock.unlock() }
            return maxAutoThreadsValue
        }
        set {
            staticLock.lock()
            maxAutoThreadsValue = max(4, min(128, newValue))
            staticLock.unlock()
        }
    }

    /// Use the URLSession transport instead of the HTTP/1.1 NWConnection client (diagnostics / workaround).
    static var forceURLSessionTransport: Bool {
        get {
            staticLock.lock()
            defer { staticLock.unlock() }
            return forceURLSessionValue
        }
        set {
            staticLock.lock()
            forceURLSessionValue = newValue
            staticLock.unlock()
        }
    }

    let dependencies: Dependencies
    private let settingsBox: EngineSettingsBox
    private var server: LocalProxyServing!
    private let lock = NSLock()
    private var sessions: [String: EngineWeakSession] = [:]
    private var sessionOrder: [String] = []
    private var clientSwitch: EngineMediaClientSwitch?
    private var settingsObserver: NSObjectProtocol?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        settingsBox = EngineSettingsBox(dependencies.settings())
        server = dependencies.makeServer(self)
        server.onPortChange = { [weak self] port in self?.portChanged(port) }
        if let name = dependencies.settingsDidChange {
            // Delivered synchronously on the posting (main) thread, where reading the settings is safe.
            settingsObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in self?.refreshSettings()
            }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    // MARK: App lifecycle

    /// Idempotent; starts the loopback listener (call at app launch).
    func startIfNeeded() {
        server.start()
    }

    func applicationWillEnterForeground() {
        refreshSettings()
        server.ensureListening()
    }

    func applicationDidEnterBackground() {
        lock.lock()
        let client = clientSwitch
        lock.unlock()
        client?.closeIdleConnections()
    }

    /// Drops cached segments behind the playheads.
    func applicationDidReceiveMemoryWarning() {
        for session in liveSessions() { session.store.trimCache() }
    }

    /// The listener's current port (0 when down).
    var port: UInt16 { server.port }

    // MARK: Settings

    /// Re-reads the live settings into the thread-safe snapshot the downloaders and planners read.
    func refreshSettings() { settingsBox.value = dependencies.settings() }

    func refreshSettingsIfOnMainThread() {
        if Thread.isMainThread { refreshSettings() }
    }

    var currentSettings: AccelerationSettings { settingsBox.value }

    private func makeConfigProvider() -> () -> BTRConfig {
        let box = settingsBox
        return { BTRConfig(settings: box.value, maxAutoThreads: AccelerationEngine.maxAutoThreads) }
    }

    private func mediaClient() -> MediaHTTPClient {
        lock.lock()
        defer { lock.unlock() }
        if let clientSwitch {
            if Self.forceURLSessionTransport { clientSwitch.switchToFallback() }
            return clientSwitch
        }
        let made = EngineMediaClientSwitch(makePrimary: dependencies.makePrimaryClient,
                                           makeFallback: dependencies.makeFallbackClient,
                                           useFallback: Self.forceURLSessionTransport)
        clientSwitch = made
        return made
    }

    // MARK: Sessions

    /// DASH → local HLS. Loads init + sidx of both tracks (in parallel) before returning, so the playlists and
    /// file totals are final when AVPlayer asks. Throws `AccelerationEngineError` (the player falls back).
    func prepare(_ request: PlaybackRequest) async throws -> PlaybackSession {
        startIfNeeded()
        let port = try await readyPort()
        let videoURLs = EngineMediaURLPolicy.allowed(request.video.allURLs)
        guard !videoURLs.isEmpty else { throw AccelerationEngineError.noAllowedURL }
        var audioURLs: [String] = []
        if let audio = request.audio {
            audioURLs = EngineMediaURLPolicy.allowed(audio.allURLs)
            guard !audioURLs.isEmpty else { throw AccelerationEngineError.noAllowedURL }
        }

        let token = Self.makeToken()
        let downloader = dependencies.makeDownloader(makeConfigProvider(), mediaClient())
        let videoHandle = downloader.makeTrack(kind: .video, urls: videoURLs, routeKey: request.routeKey)
        let audioHandle = request.audio == nil ? nil
            : downloader.makeTrack(kind: .audio, urls: audioURLs, routeKey: request.routeKey)
        let accelerate = request.accelerate

        let metas: (video: EngineTrackMeta, audio: EngineTrackMeta?)
        do {
            let video = request.video
            let audio = request.audio
            metas = try await withEngineTimeout(seconds: dependencies.metadataTimeout) {
                async let v = EngineMetaLoader.load(stream: video, handle: videoHandle, downloader: downloader,
                                                    accelerate: accelerate)
                async let a = EngineMetaLoader.loadOptional(stream: audio, handle: audioHandle,
                                                            downloader: downloader, accelerate: accelerate)
                return (video: try await v, audio: try await a)
            }
            try Task.checkCancellation()
        } catch {
            downloader.cancelAll()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let e = error as? AccelerationEngineError { throw e }
            if let e = error as? SidxParseError { throw AccelerationEngineError.metadata(e.description) }
            throw AccelerationEngineError.metadata(Self.describe(error))
        }

        var playlists: [String: Data] = [:]
        playlists["v.m3u8"] = Data(HLSPlaylistBuilder.mediaPlaylist(initRange: metas.video.initRange,
                                                                     segments: metas.video.segments,
                                                                     uri: "v.m4s").utf8)
        if let audioMeta = metas.audio {
            playlists["a.m3u8"] = Data(HLSPlaylistBuilder.mediaPlaylist(initRange: audioMeta.initRange,
                                                                         segments: audioMeta.segments,
                                                                         uri: "a.m4s").utf8)
        }
        let average = request.video.bandwidth > 0
            ? request.video.bandwidth : HLSPlaylistBuilder.estimatedBandwidth(segments: metas.video.segments)
        playlists["master.m3u8"] = Data(HLSPlaylistBuilder.masterPlaylist(
            video: request.video, videoURI: "v.m3u8",
            audio: metas.audio == nil ? nil : request.audio, audioURI: metas.audio == nil ? nil : "a.m3u8",
            averageBandwidth: average, allowDolbyVision: request.allowHDR).utf8)

        var tracks = [SegmentStoreTrack(kind: .video, handle: videoHandle, total: metas.video.total,
                                        pinned: metas.video.pinned, segments: metas.video.segments,
                                        accelerate: accelerate)]
        var handles: [EngineSessionTrack] = [EngineSessionTrack(kind: .video, handle: videoHandle,
                                                                stream: request.video)]
        if let audioMeta = metas.audio, let audioHandle, let audio = request.audio {
            tracks.append(SegmentStoreTrack(kind: .audio, handle: audioHandle, total: audioMeta.total,
                                            pinned: audioMeta.pinned, segments: audioMeta.segments,
                                            accelerate: accelerate))
            handles.append(EngineSessionTrack(kind: .audio, handle: audioHandle, stream: audio))
        }
        return makeSession(token: token, port: port, entry: "master.m3u8", isHLS: true, tracks: tracks,
                           handles: handles, playlists: playlists,
                           routes: ["v.m4s": .video, "a.m4s": .audio],
                           contentTypes: [.video: "video/mp4", .audio: "audio/mp4"],
                           downloader: downloader, accelerate: accelerate, videoHeight: request.video.height,
                           refreshURLs: request.refreshURLs)
    }

    /// A progressive (durl) MP4 through the proxy as `/<token>/p.mp4` (not HLS). `refreshURLs` renews the signed
    /// URLs of the same file (see `progressiveRefresher`); the session swaps them in like a DASH session does.
    func prepareProgressive(routeKey: String, segment: ProgressiveSegment, accelerate: Bool,
                            refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))? = nil)
    async throws -> PlaybackSession {
        startIfNeeded()
        let candidates = [segment.url] + segment.backupURLs.filter { $0 != segment.url }
        if candidates.allSatisfy({ (URLComponents(string: $0)?.path ?? "").lowercased().hasSuffix(".flv") }) {
            throw AccelerationEngineError.unsupportedFormat("FLV")
        }
        let urls = EngineMediaURLPolicy.allowed(candidates).filter {
            !(URLComponents(string: $0)?.path ?? "").lowercased().hasSuffix(".flv")
        }
        guard !urls.isEmpty else { throw AccelerationEngineError.noAllowedURL }
        let port = try await readyPort()
        let token = Self.makeToken()
        let downloader = dependencies.makeDownloader(makeConfigProvider(), mediaClient())
        let handle = downloader.makeTrack(kind: .video, urls: urls, routeKey: routeKey)

        let head: (data: Data, total: Int64)
        do {
            let headLength: Int64 = segment.size > 0 ? min(64 * 1024, segment.size) : 64 * 1024
            head = try await withEngineTimeout(seconds: dependencies.metadataTimeout) {
                try await EngineMetaLoader.fetch(ByteRange(start: 0, end: headLength - 1), handle: handle,
                                                 downloader: downloader, accelerate: accelerate)
            }
            try Task.checkCancellation()
        } catch {
            downloader.cancelAll()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let e = error as? AccelerationEngineError { throw e }
            throw AccelerationEngineError.metadata(Self.describe(error))
        }
        let total = head.total
        let pinned = PinnedBytes(range: ByteRange(start: 0, end: Int64(head.data.count) - 1), data: head.data)
        let duration = segment.lengthMs > 0 ? Double(segment.lengthMs) / 1000 : 0
        let units = Self.progressiveUnits(total: total, from: Int64(head.data.count), duration: duration)
        let track = SegmentStoreTrack(kind: .video, handle: handle, total: total, pinned: [pinned], segments: units,
                                      accelerate: accelerate)
        let stream = DashStream(kind: .video, id: 0, baseURL: segment.url, backupURLs: segment.backupURLs)
        return makeSession(token: token, port: port, entry: "p.mp4", isHLS: false, tracks: [track],
                           handles: [EngineSessionTrack(kind: .video, handle: handle, stream: stream)],
                           playlists: [:], routes: ["p.mp4": .video], contentTypes: [.video: "video/mp4"],
                           downloader: downloader, accelerate: accelerate, videoHeight: 0, refreshURLs: refreshURLs)
    }

    /// `prepareProgressive(refreshURLs:)` from a playurl re-fetch: picks the durl entry serving the same file as
    /// `segment` (same URL path; refreshes only ever swap URLs of the same path) as a `DashStream`.
    static func progressiveRefresher(for segment: ProgressiveSegment,
                                     fetch: @escaping () async throws -> [ProgressiveSegment])
    -> () async throws -> (video: DashStream, audio: DashStream?) {
        let wanted = URLComponents(string: segment.url)?.path ?? ""
        return {
            guard !wanted.isEmpty, let fresh = matchingSegment(path: wanted, in: try await fetch()) else {
                throw AccelerationEngineError.noAllowedURL
            }
            return (video: DashStream(kind: .video, id: 0, baseURL: fresh.url, backupURLs: fresh.backupURLs), audio: nil)
        }
    }

    /// The entry whose primary (or, reordered to the front, one backup) URL has `path`.
    static func matchingSegment(path: String, in segments: [ProgressiveSegment]) -> ProgressiveSegment? {
        for candidate in segments {
            let urls = [candidate.url] + candidate.backupURLs
            guard let hit = urls.first(where: { URLComponents(string: $0)?.path == path }) else { continue }
            var result = candidate
            result.url = hit
            result.backupURLs = urls.filter { $0 != hit }
            return result
        }
        return nil
    }

    /// Fixed 2 MiB units after the pinned head, with times estimated from the byte position.
    static func progressiveUnits(total: Int64, from start: Int64, duration: Double,
                                 unitBytes: Int64 = 2 << 20) -> [SidxSegment] {
        guard total > start else { return [] }
        let seconds = duration > 0 ? duration : Double(total) / 250_000 // ~2 Mbps guess
        var units: [SidxSegment] = []
        var cursor = start
        while cursor < total {
            let end = min(total - 1, cursor + unitBytes - 1)
            let t0 = Double(cursor) / Double(total) * seconds
            let t1 = Double(end + 1) / Double(total) * seconds
            units.append(SidxSegment(index: units.count, byteRange: ByteRange(start: cursor, end: end),
                                     startTime: t0, duration: t1 - t0))
            cursor = end + 1
        }
        return units
    }

    private func makeSession(token: String, port: UInt16, entry: String, isHLS: Bool, tracks: [SegmentStoreTrack],
                             handles: [EngineSessionTrack], playlists: [String: Data], routes: [String: MediaKind],
                             contentTypes: [MediaKind: String], downloader: BTRDownloading, accelerate: Bool,
                             videoHeight: Int,
                             refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))?)
    -> PlaybackSession {
        let box = settingsBox
        let relay = EngineSessionRelay()
        let store = SegmentStore(tracks: tracks, downloader: downloader, clock: dependencies.clock,
                                 budgetBytes: dependencies.cacheBudgetBytes, videoHeight: videoHeight,
                                 forwardSeconds: { max(10, box.value.forwardBufferSeconds) },
                                 accelerationAllowed: { box.value.enabled },
                                 onHardFailure: { relay.session?.noteHardFailure() })
        let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(entry)")!
        let session = PlaybackSession(id: token, url: url, isHLS: isHLS, port: port, engine: self, store: store,
                                      downloader: downloader, tracks: handles, playlists: playlists, routes: routes,
                                      contentTypes: contentTypes, accelerate: accelerate, auto: dependencies.auto,
                                      clock: dependencies.clock, wallClock: dependencies.wallClock,
                                      refreshURLs: refreshURLs, refreshInterval: dependencies.refreshCheckInterval)
        relay.session = session
        var evicted: [PlaybackSession] = []
        // Strong references taken under the lock are released only after it: a session whose owner dropped it
        // meanwhile must not deinit (→ close → unregister → this lock) while the lock is held.
        var retained: [PlaybackSession] = []
        lock.lock()
        sessions[token] = EngineWeakSession(session)
        var order: [String] = []
        for existing in sessionOrder + [token] {
            if let live = sessions[existing]?.session {
                retained.append(live)
                order.append(existing)
            } else {
                sessions[existing] = nil
            }
        }
        while order.count > dependencies.maxSessions {
            let oldest = order.removeFirst()
            if let s = sessions.removeValue(forKey: oldest)?.session { evicted.append(s) }
        }
        sessionOrder = order
        lock.unlock()
        retained.removeAll()
        for old in evicted { old.close() }
        if accelerate { dependencies.auto?.newSession() }
        session.startRefreshLoop()
        return session
    }

    private func readyPort() async throws -> UInt16 {
        do {
            let port = try await server.waitUntilReady(timeout: dependencies.serverReadyTimeout)
            guard port > 0 else { throw AccelerationEngineError.serverUnavailable }
            return port
        } catch {
            if error is CancellationError { throw error }
            throw AccelerationEngineError.serverUnavailable
        }
    }

    func unregister(_ token: String) {
        lock.lock()
        sessions[token] = nil
        sessionOrder.removeAll { $0 == token }
        lock.unlock()
    }

    func session(forToken token: String) -> PlaybackSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[token]?.session
    }

    private func liveSessions() -> [PlaybackSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.compactMap(\.session)
    }

    private func portChanged(_ port: UInt16) {
        for session in liveSessions() where session.port != port { session.markEndpointInvalid() }
    }

    // MARK: LocalProxyRequestHandler

    func handle(_ request: ProxyHTTPRequest) async -> LocalProxyResponse {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, let session = session(forToken: String(parts[0])) else { return .notFound }
        return await session.respond(to: request, name: String(parts[1]))
    }

    // MARK: Helpers

    /// 24 random bytes (system CSPRNG) as 48 lowercase hex characters.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24).map { _ in
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            return (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }.joined()
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

// MARK: - Session

/// One AVPlayerItem's proxy session. Keep a strong reference for as long as the item uses `url`; `close()` (or
/// releasing the last reference) cancels every download and makes the token answer 404.
final class PlaybackSession {
    let id: String
    /// master.m3u8 (HLS) or p.mp4 (progressive).
    let url: URL
    let isHLS: Bool
    let port: UInt16

    let store: SegmentStore
    private weak var engine: AccelerationEngine?
    private let downloader: BTRDownloading
    private let tracks: [EngineSessionTrack]
    private let playlists: [String: Data]
    private let routes: [String: MediaKind]
    private let contentTypes: [MediaKind: String]
    private let accelerate: Bool
    private let auto: AutoConcurrencySignals?
    private let clock: MonotonicClock
    private let wallClock: () -> Double
    private let refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))?
    private let refreshInterval: TimeInterval

    private let lock = NSLock()
    private var closed = false
    private var endpointValid = true
    private var lastBufferedAhead: Double = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshing = false
    private var urgentRefresh = false
    private var lastRefreshAttemptMs: Double?
    private var refreshFailures = 0
    private var streams: [MediaKind: DashStream] = [:]

    init(id: String, url: URL, isHLS: Bool, port: UInt16, engine: AccelerationEngine, store: SegmentStore,
         downloader: BTRDownloading, tracks: [EngineSessionTrack], playlists: [String: Data],
         routes: [String: MediaKind], contentTypes: [MediaKind: String], accelerate: Bool,
         auto: AutoConcurrencySignals?, clock: MonotonicClock, wallClock: @escaping () -> Double,
         refreshURLs: (() async throws -> (video: DashStream, audio: DashStream?))?, refreshInterval: TimeInterval) {
        self.id = id
        self.url = url
        self.isHLS = isHLS
        self.port = port
        self.engine = engine
        self.store = store
        self.downloader = downloader
        self.tracks = tracks
        self.playlists = playlists
        self.routes = routes
        self.contentTypes = contentTypes
        self.accelerate = accelerate
        self.auto = auto
        self.clock = clock
        self.wallClock = wallClock
        self.refreshURLs = refreshURLs
        self.refreshInterval = refreshInterval
        for track in tracks { streams[track.kind] = track.stream }
    }

    deinit {
        close()
    }

    // MARK: Player signals

    /// Call ≥ 4×/s while the item is active (a 0.25 s periodic time observer).
    /// - Parameters:
    ///   - bufferedAhead: end of the `loadedTimeRanges` entry containing `time`, minus `time` (0 if none).
    ///   - playing: `timeControlStatus == .playing` and not seeking / restarting.
    ///   - cacheFull: AVPlayer stopped loading because its forward buffer is full
    ///     (`bufferedAhead >= preferredForwardBufferDuration − 1`).
    func update(time: Double, rate: Double, playing: Bool, bufferedAhead: Double, cacheFull: Bool) {
        guard !isClosed else { return }
        engine?.refreshSettingsIfOnMainThread()
        store.updatePlayback(time: time, rate: rate, playing: playing, bufferedAhead: bufferedAhead,
                             cacheFull: cacheFull)
        lock.lock()
        lastBufferedAhead = bufferedAhead
        lock.unlock()
        if store.isAccelerating { auto?.buffer(ahead: bufferedAhead, playing: playing, cacheFull: cacheFull) }
    }

    /// Playback waits for data while it should be playing (not during a seek or the initial start).
    func playerDidStall() {
        guard !isClosed, store.isAccelerating else { return }
        // With this much already buffered AVPlayer waits for its decoder, not for data (BTR #58).
        let recovery = min(10, max(6, (store.startupTargetSeconds ?? 6) + 2))
        lock.lock()
        let ahead = lastBufferedAhead
        lock.unlock()
        guard ahead < recovery else { return }
        auto?.stall()
    }

    /// Call right before `seek(to:)`. `outsideBuffer` = the target is not inside `loadedTimeRanges`.
    func playerWillSeek(to time: Double, outsideBuffer: Bool) {
        guard !isClosed else { return }
        let cached = store.isCached(at: time)
        store.seek(to: time, outsideBuffer: outsideBuffer)
        if outsideBuffer && !cached && store.isAccelerating { auto?.newSession() }
    }

    var stats: AccelerationStats {
        let b = downloader.stats
        var nodes = b.nodes
        if nodes.isEmpty { nodes = tracks.flatMap { $0.handle.nodeStatus() } }
        return AccelerationStats(accelerated: accelerate && store.isAccelerating, threads: b.threads,
                                 activeConnections: b.activeConnections, bytesPerSecond: b.bytesPerSecond,
                                 autoReason: b.autoReason, nodes: nodes, cachedAheadSeconds: store.cachedAheadSeconds(),
                                 totalBytes: b.totalBytes, hedgedBytes: b.hedgedBytes,
                                 fallbackActive: store.fallbackActive)
    }

    /// Seconds AVPlayer should have buffered before starting / resuming, measured once (nil until measured).
    var startupTargetSeconds: Double? { store.startupTargetSeconds }

    /// False once the listener had to move to another port (rebuild the item with a new session).
    var isEndpointValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return endpointValid && !closed
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Cancels everything; the token answers 404 afterwards. Idempotent.
    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let task = refreshTask
        refreshTask = nil
        lock.unlock()
        engine?.unregister(id)
        task?.cancel()
        store.close()
        downloader.cancelAll()
    }

    func markEndpointInvalid() {
        lock.lock()
        endpointValid = false
        lock.unlock()
    }

    // MARK: HTTP

    func respond(to request: ProxyHTTPRequest, name: String) async -> LocalProxyResponse {
        guard !isClosed else { return .notFound }
        let method = request.method.uppercased()
        if let playlist = playlists[name] {
            guard method == "GET" || method == "HEAD" else { return .methodNotAllowed }
            let headers = [("Content-Type", HLSPlaylistBuilder.mpegURLContentType),
                           ("Content-Length", "\(playlist.count)"), ("Cache-Control", "no-cache")]
            return LocalProxyResponse(status: 200, headers: headers, body: method == "HEAD" ? .none : .data(playlist),
                                      contentLength: Int64(playlist.count))
        }
        guard let kind = routes[name], let total = store.total(of: kind) else { return .notFound }
        guard method == "GET" || method == "HEAD" else { return .methodNotAllowed }
        let raw = request.header("range")?.trimmingCharacters(in: .whitespaces)
        let rangeHeader = (raw?.isEmpty ?? true) ? nil : raw
        guard let range = HTTPRangeSpec.resolve(rangeHeader, total: total) else {
            return .rangeNotSatisfiable(total: total)
        }
        var headers: [(String, String)] = [("Content-Type", contentTypes[kind] ?? "video/mp4"),
                                           ("Accept-Ranges", "bytes"), ("Content-Length", "\(range.length)")]
        let status = rangeHeader == nil ? 200 : 206
        if status == 206 { headers.append(("Content-Range", "bytes \(range.start)-\(range.end)/\(total)")) }
        if method == "HEAD" {
            return LocalProxyResponse(status: status, headers: headers, body: .none, contentLength: range.length)
        }
        guard let reader = store.reader(kind: kind, range: range) else { return .badGateway }
        do {
            // Headers go out with the first verified bytes (immediately when they come from memory), so a range
            // that fails before any byte still becomes a clean 502.
            guard let first = try await reader.nextChunk() else {
                reader.cancel()
                return .badGateway
            }
            return LocalProxyResponse(status: status, headers: headers,
                                      body: .stream(EnginePrefetchedBody(first: first, rest: reader)),
                                      contentLength: range.length)
        } catch {
            reader.cancel()
            return .badGateway
        }
    }

    // MARK: URL expiry (btr-core §11.4–11.5)

    func startRefreshLoop() {
        guard refreshURLs != nil else { return }
        let interval = refreshInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                await self.refreshIfDue()
            }
        }
        lock.lock()
        if closed {
            lock.unlock()
            task.cancel()
            return
        }
        refreshTask = task
        lock.unlock()
    }

    /// Earliest `deadline=` (epoch seconds) among the session's current URLs.
    var urlDeadline: Double? {
        lock.lock()
        defer { lock.unlock() }
        return Self.deadline(of: Array(streams.values))
    }

    private static func deadline(of streams: [DashStream]) -> Double? {
        streams.compactMap { URLRefreshPolicy.deadline(of: $0.baseURL) }.min()
    }

    /// A range failed on every path: ask for fresh URLs at the next opportunity (respecting the backoff).
    func noteHardFailure() {
        lock.lock()
        let wanted = refreshURLs != nil && !closed
        if wanted { urgentRefresh = true }
        lock.unlock()
        if wanted {
            Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.refreshIfDue()
            }
        }
    }

    /// Refreshes the signed URLs when due: 120 s before the earliest `deadline`, or after a hard failure, with the
    /// 45/90/180/300 s backoff. New URLs are swapped into the existing tracks (`updateURLs`), never a new session.
    func refreshIfDue() async {
        guard let refresh = refreshURLs else { return }
        guard let oldDeadline = beginRefresh(nowMs: clock.nowMs(), nowSeconds: wallClock()) else { return }
        var applied: Double?
        do {
            let fresh = try await withEngineTimeout(seconds: 15) { try await refresh() }
            applied = apply(fresh)
        } catch {
            applied = nil
        }
        endRefresh(applied: applied, oldDeadline: oldDeadline)
    }

    /// Claims the refresh slot when one is due; returns the current earliest deadline (inner nil = none), or nil
    /// when no refresh should start now.
    private func beginRefresh(nowMs: Double, nowSeconds: Double) -> Double?? {
        lock.lock()
        defer { lock.unlock() }
        let oldDeadline = Self.deadline(of: Array(streams.values))
        guard !closed, !refreshing,
              URLRefreshPolicy.isDue(nowSeconds: nowSeconds, deadline: oldDeadline, urgent: urgentRefresh,
                                     nowMs: nowMs, lastAttemptMs: lastRefreshAttemptMs, failures: refreshFailures)
        else { return nil }
        refreshing = true
        urgentRefresh = false
        lastRefreshAttemptMs = nowMs
        return .some(oldDeadline)
    }

    /// Same deadline again (or a failure) backs off further: 45 → 90 → 180 → 300 s.
    private func endRefresh(applied: Double?, oldDeadline: Double?) {
        lock.lock()
        defer { lock.unlock() }
        refreshing = false
        if let newDeadline = applied, oldDeadline == nil || newDeadline > (oldDeadline ?? 0) {
            refreshFailures = 0
        } else {
            refreshFailures += 1
        }
    }

    /// Swaps in the fresh URLs of the SAME files (same URL path); returns the new earliest deadline
    /// (`.infinity` when the URLs carry none), nil when nothing was applied.
    private func apply(_ fresh: (video: DashStream, audio: DashStream?)) -> Double? {
        var candidates: [(EngineSessionTrack, DashStream)] = []
        for track in tracks {
            let next = track.kind == .video ? fresh.video : fresh.audio
            guard let next else { continue }
            candidates.append((track, next))
        }
        var appliedAny = false
        var deadlines: [Double] = []
        for (track, next) in candidates {
            lock.lock()
            let current = streams[track.kind]
            lock.unlock()
            guard let current, Self.samePath(current.baseURL, next.baseURL) else { continue }
            let currentDeadline = URLRefreshPolicy.deadline(of: current.baseURL)
            let nextDeadline = URLRefreshPolicy.deadline(of: next.baseURL)
            // An older playurl answer must never overwrite newer addresses (btr-core §11.3).
            if let c = currentDeadline, let n = nextDeadline, n < c { continue }
            let urls = EngineMediaURLPolicy.allowed(next.allURLs)
            guard !urls.isEmpty else { continue }
            track.handle.updateURLs(urls)
            lock.lock()
            var updated = current
            updated.baseURL = next.baseURL
            updated.backupURLs = next.backupURLs
            streams[track.kind] = updated
            lock.unlock()
            appliedAny = true
            deadlines.append(nextDeadline ?? .infinity)
        }
        return appliedAny ? (deadlines.min() ?? .infinity) : nil
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        guard let pa = URLComponents(string: a)?.path, let pb = URLComponents(string: b)?.path else { return false }
        return !pa.isEmpty && pa == pb
    }
}

// MARK: - Support types

struct EngineSessionTrack {
    var kind: MediaKind
    var handle: BTRTrackHandle
    var stream: DashStream
}

final class EngineWeakSession {
    weak var session: PlaybackSession?
    init(_ session: PlaybackSession) { self.session = session }
}

/// Late binding from the store's failure callback to its session.
final class EngineSessionRelay {
    weak var session: PlaybackSession?
}

final class EngineSettingsBox {
    private let lock = NSLock()
    private var stored: AccelerationSettings

    init(_ value: AccelerationSettings) { stored = value }

    var value: AccelerationSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// The first chunk (already awaited before the head was sent), then the reader.
final class EnginePrefetchedBody: LocalProxyBodySource {
    private var first: Data?
    private let rest: LocalProxyBodySource

    init(first: Data, rest: LocalProxyBodySource) {
        self.first = first
        self.rest = rest
    }

    func nextChunk() async throws -> Data? {
        if let chunk = first {
            first = nil
            return chunk
        }
        return try await rest.nextChunk()
    }

    func cancel() { rest.cancel() }
}

/// BTR media URL whitelist (btr-core §2): https, a Bilibili media host, a media file path. Signed URLs never go to
/// any other host.
enum EngineMediaURLPolicy {
    static let hostSuffixes = ["bilivideo.com", "bilivideo.cn", "bilivideo.net", "akamaized.net", "szbdyd.com",
                               "hdslb.com", "xycdn.com", "mountaintoys.cn", "nexusedgeio.com", "ahdohpiechei.com"]
    static let pathSuffixes = [".m4s", ".mp4", ".flv"]

    static func isAllowed(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        let hostOK = hostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        let path = components.path.lowercased()
        return hostOK && pathSuffixes.contains { path.hasSuffix($0) }
    }

    /// Allowed URLs, de-duplicated, order kept.
    static func allowed(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { isAllowed($0) && seen.insert($0).inserted }
    }
}

/// btr-core §11.4: refresh signed URLs 120 s before `deadline=`; min gap 45 s · 2^min(failures, 3) (≤ 300 s).
enum URLRefreshPolicy {
    static let leadSeconds: Double = 120

    static func deadline(of url: String) -> Double? {
        guard let items = URLComponents(string: url)?.queryItems,
              let raw = items.first(where: { $0.name == "deadline" })?.value,
              let value = Double(raw), value > 0 else { return nil }
        return value
    }

    static func backoffMs(failures: Int) -> Double {
        min(300_000, 45_000 * pow(2, Double(min(max(0, failures), 3))))
    }

    static func isDue(nowSeconds: Double, deadline: Double?, urgent: Bool, nowMs: Double, lastAttemptMs: Double?,
                      failures: Int) -> Bool {
        if let last = lastAttemptMs, nowMs - last < backoffMs(failures: failures) { return false }
        if urgent { return true }
        guard let deadline else { return false }
        return nowSeconds >= deadline - leadSeconds
    }
}

/// Upstream client used by every downloader: the HTTP/1.1 client, switching (for the rest of the app run) to the
/// URLSession transport when forced or when the primary failed TLS 6 times in a row without any success.
final class EngineMediaClientSwitch: MediaHTTPClient, @unchecked Sendable {
    static let tlsFailureLimit = 6

    private let lock = NSLock()
    private let makePrimary: () -> MediaHTTPClient
    private let makeFallback: () -> MediaHTTPClient
    private var primary: MediaHTTPClient?
    private var fallback: MediaHTTPClient?
    private var usingFallback: Bool
    private var consecutiveTLSFailures = 0

    init(makePrimary: @escaping () -> MediaHTTPClient, makeFallback: @escaping () -> MediaHTTPClient,
         useFallback: Bool = false) {
        self.makePrimary = makePrimary
        self.makeFallback = makeFallback
        usingFallback = useFallback
    }

    var isUsingFallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingFallback
    }

    func switchToFallback() {
        lock.lock()
        usingFallback = true
        let old = primary
        lock.unlock()
        old?.closeIdleConnections()
    }

    private func current() -> (client: MediaHTTPClient, watched: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if usingFallback {
            if fallback == nil { fallback = makeFallback() }
            return (fallback!, false)
        }
        if primary == nil { primary = makePrimary() }
        return (primary!, true)
    }

    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error> {
        let (client, watched) = current()
        let upstream = client.get(url, range: range, highPriority: highPriority)
        guard watched else { return upstream }
        // Holds only the upstream ITERATOR: releasing this stream releases it, which the clients treat as the
        // consumer going away (they cancel the request), exactly as if the caller had used `upstream` directly.
        let box = EngineIteratorBox(upstream.makeAsyncIterator())
        return AsyncThrowingStream<MediaFetchEvent, Error>(unfolding: { [weak self] in
            do {
                let event = try await box.next()
                if case .head = event { self?.noteSuccess() }
                return event
            } catch {
                if let fetchError = error as? MediaFetchError, case .tls = fetchError { self?.noteTLSFailure() }
                throw error
            }
        })
    }

    func preconnect(hosts: [String]) { current().client.preconnect(hosts: hosts) }

    func closeIdleConnections() {
        lock.lock()
        let clients = [primary, fallback].compactMap { $0 }
        lock.unlock()
        for client in clients { client.closeIdleConnections() }
    }

    var openConnectionCount: Int {
        lock.lock()
        let clients = [primary, fallback].compactMap { $0 }
        lock.unlock()
        return clients.reduce(0) { $0 + $1.openConnectionCount }
    }

    private func noteSuccess() {
        lock.lock()
        consecutiveTLSFailures = 0
        lock.unlock()
    }

    private func noteTLSFailure() {
        lock.lock()
        consecutiveTLSFailures += 1
        let flip = !usingFallback && consecutiveTLSFailures >= Self.tlsFailureLimit
        lock.unlock()
        if flip { switchToFallback() }
    }
}

final class EngineIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<MediaFetchEvent, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<MediaFetchEvent, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> MediaFetchEvent? {
        try await iterator.next()
    }
}

/// Collects `onBytes` deliveries.
final class EngineByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(buffer.count)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Init + index of one representation, learnt before the playlists are published.
struct EngineTrackMeta {
    var total: Int64
    var initRange: ByteRange
    /// Bytes kept in memory (init … index end).
    var pinned: [PinnedBytes]
    var segments: [SidxSegment]
}

enum EngineMetaLoader {
    static let metaPriority = 220
    /// When playurl had no `segment_base`: read this much of the head and look for the sidx (nish's 256 KiB).
    static let headProbeBytes: Int64 = 256 * 1024
    static let maxHeadBytes: Int64 = 4 << 20

    static func loadOptional(stream: DashStream?, handle: BTRTrackHandle?, downloader: BTRDownloading,
                             accelerate: Bool) async throws -> EngineTrackMeta? {
        guard let stream, let handle else { return nil }
        return try await load(stream: stream, handle: handle, downloader: downloader, accelerate: accelerate)
    }

    /// One `.meta` download of `initStart … indexEnd` when the two ranges touch (the normal Bilibili layout), two
    /// parallel ones otherwise; without `segment_base`, the sidx is located by walking the head's boxes.
    static func load(stream: DashStream, handle: BTRTrackHandle, downloader: BTRDownloading,
                     accelerate: Bool) async throws -> EngineTrackMeta {
        if let initRange = ByteRange(string: stream.initRange), let indexRange = ByteRange(string: stream.indexRange) {
            let pinned: [PinnedBytes]
            let total: Int64
            let indexData: Data
            if indexRange.start >= initRange.start && indexRange.start <= initRange.end + 1 {
                let meta = ByteRange(start: initRange.start, end: max(initRange.end, indexRange.end))
                let fetched = try await fetch(meta, handle: handle, downloader: downloader, accelerate: accelerate)
                guard Int64(fetched.data.count) == meta.length else {
                    throw AccelerationEngineError.metadata("文件比索引范围短")
                }
                total = fetched.total
                pinned = [PinnedBytes(range: meta, data: fetched.data)]
                let from = Int(indexRange.start - meta.start)
                indexData = fetched.data.subdata(in: from..<(from + Int(indexRange.length)))
            } else {
                async let initPart = fetch(initRange, handle: handle, downloader: downloader, accelerate: accelerate)
                async let indexPart = fetch(indexRange, handle: handle, downloader: downloader, accelerate: accelerate)
                let i = try await initPart
                let x = try await indexPart
                guard i.total == x.total else { throw MediaProxyError.totalMismatch(expected: i.total, got: x.total) }
                guard Int64(i.data.count) == initRange.length, Int64(x.data.count) == indexRange.length else {
                    throw AccelerationEngineError.metadata("文件比索引范围短")
                }
                total = i.total
                pinned = [PinnedBytes(range: initRange, data: i.data), PinnedBytes(range: indexRange, data: x.data)]
                indexData = x.data
            }
            let sidx = try SidxParser.parse(indexData, absoluteStart: indexRange.start)
            try validate(sidx, total: total, initRange: initRange)
            return EngineTrackMeta(total: total, initRange: initRange, pinned: pinned, segments: sidx.segments)
        }

        // No segment_base: learn the total from a small probe, then read the head until the sidx is complete.
        var probe = try await fetch(ByteRange(start: 0, end: 4095), handle: handle, downloader: downloader,
                                    accelerate: accelerate)
        let total = probe.total
        var head = probe.data
        let limit = min(total, maxHeadBytes)
        var wanted = min(headProbeBytes, total)
        while true {
            if Int64(head.count) < wanted {
                probe = try await fetch(ByteRange(start: Int64(head.count), end: wanted - 1), handle: handle,
                                        downloader: downloader, accelerate: accelerate)
                guard probe.total == total else { throw MediaProxyError.totalMismatch(expected: total, got: probe.total) }
                head.append(probe.data)
            }
            switch SidxParser.locate(in: head) {
            case let .found(initRange, indexRange):
                let indexData = head.subdata(in: Int(indexRange.start)..<Int(indexRange.end + 1))
                let sidx = try SidxParser.parse(indexData, absoluteStart: indexRange.start)
                try validate(sidx, total: total, initRange: initRange)
                let pinnedData = head.prefix(Int(indexRange.end + 1))
                return EngineTrackMeta(total: total, initRange: initRange,
                                       pinned: [PinnedBytes(range: ByteRange(start: 0, end: indexRange.end),
                                                            data: Data(pinnedData))],
                                       segments: sidx.segments)
            case .needMore(let minimum):
                guard minimum <= limit, minimum > Int64(head.count) else { throw SidxParseError.notFound }
                wanted = min(limit, max(minimum, Int64(head.count) * 2))
            case .notFound:
                throw SidxParseError.notFound
            }
        }
    }

    static func validate(_ sidx: SidxIndex, total: Int64, initRange: ByteRange) throws {
        guard let media = sidx.mediaRange else { throw SidxParseError.invalid("没有分段") }
        guard initRange.end < total, media.end < total else { throw SidxParseError.invalid("分段超出文件长度") }
        guard media.start > initRange.end else { throw SidxParseError.invalid("分段与初始化段重叠") }
    }

    /// One metadata range (`.meta` race when accelerating, falling back to the plain path for the rest).
    /// The accelerated path may clip at the end of a short file; the returned data then ends at `total − 1`.
    static func fetch(_ range: ByteRange, handle: BTRTrackHandle, downloader: BTRDownloading,
                      accelerate: Bool) async throws -> (data: Data, total: Int64) {
        let sink = EngineByteSink()
        let total: Int64
        if accelerate {
            do {
                total = try await downloader.download(range, track: handle, kind: .meta, priority: metaPriority,
                                                      deadline: nil, onBytes: { sink.append($0) })
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let received = sink.count
                total = try await downloader.downloadDirect(ByteRange(start: range.start + received, end: range.end),
                                                            track: handle, onBytes: { sink.append($0) })
            }
        } else {
            total = try await downloader.downloadDirect(range, track: handle, onBytes: { sink.append($0) })
        }
        let data = sink.data
        let expected = min(range.length, max(0, total - range.start))
        guard expected > 0, Int64(data.count) == expected else {
            throw MediaProxyError.truncated(expected: expected, received: Int64(data.count))
        }
        return (data, total)
    }
}

/// Runs `operation`, throwing `AccelerationEngineError.timeout` after `seconds` (the operation is cancelled).
func withEngineTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw AccelerationEngineError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

// MARK: - Live wiring (Apple platforms)

#if canImport(Network)
extension AccelerationEngine.Dependencies {
    /// LocalProxyServer + H1MediaClient (fallback URLSessionMediaClient) + BTRDownloader + the app-wide
    /// AutoConcurrencyController; settings from `AppSettings.shared.acceleration`.
    static var live: AccelerationEngine.Dependencies {
        AccelerationEngine.Dependencies(
            makeServer: { LocalProxyServer(handler: $0) },
            makePrimaryClient: { H1MediaClient() },
            makeFallbackClient: { URLSessionMediaClient() },
            makeDownloader: { config, client in
                BTRDownloader(config: config, client: client, auto: AutoConcurrencyController.shared)
            },
            auto: AutoConcurrencyController.shared,
            settings: { AppSettings.shared.acceleration },
            settingsDidChange: AppSettings.accelerationDidChange)
    }
}

extension AccelerationEngine {
    static let shared = AccelerationEngine(dependencies: .live)
}
#endif
