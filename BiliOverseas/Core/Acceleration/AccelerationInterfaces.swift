import Foundation

// Contracts between the three parts of the BTR acceleration module:
//
//   MediaHTTPClient  (H1MediaClient.swift / URLSessionMediaClient.swift)  — raw upstream HTTP/1.1 range GETs
//        ▲
//   BTRDownloader    (BTR*.swift)  — port of Bilibili-thread-ripper: CDN resolver, ban list, SWRR assignment,
//        ▲                           piece planning, hedging, resume, auto-concurrency
//   AccelerationEngine (Engine*.swift, LocalProxyServer.swift, HLS*.swift, Sidx*.swift)
//                                  — localhost HTTP server for AVPlayer, DASH(sidx) → HLS, segment cache,
//                                    prefetch scheduler, signed-URL refresh, player signals, fallback.
//
// Only the types in this file are shared; each part keeps everything else internal to its files.

// MARK: - Primitives

/// Inclusive byte range.
struct ByteRange: Hashable, CustomStringConvertible {
    var start: Int64
    var end: Int64

    init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    /// Parses `"123-456"` (playurl `segment_base` values). Requires `end >= start >= 0`.
    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let s = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let e = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              s >= 0, e >= s else { return nil }
        start = s
        end = e
    }

    var length: Int64 { end - start + 1 }
    var description: String { "\(start)-\(end)" }

    func contains(_ other: ByteRange) -> Bool { other.start >= start && other.end <= end }
}

/// Monotonic milliseconds (not wall clock). Injectable for tests.
protocol MonotonicClock: AnyObject {
    func nowMs() -> Double
}

final class SystemClock: MonotonicClock {
    static let shared = SystemClock()
    func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
}

// MARK: - Upstream HTTP client

enum MediaFetchEvent {
    /// Status line + response headers (keys lower-cased). Always the first event, exactly once.
    case head(status: Int, headers: [String: String])
    /// Body bytes, in order.
    case data(Data)
}

enum MediaFetchError: Error, Equatable {
    case invalidURL
    case connectFailed(String)
    case tls(String)
    case malformedResponse(String)
    /// Peer closed before the declared body length arrived.
    case connectionClosed
    case cancelled
}

/// Performs single-connection range GETs against Bilibili CDNs.
///
/// Requirements (see BTR spec §12 and proxy-ports spec §6.3):
/// - Each in-flight request uses its OWN TCP connection (HTTP/1.1, TLS ALPN pinned to `http/1.1`), so N requests
///   really are N connections — HTTP/2 multiplexing/coalescing would defeat multi-connection acceleration.
/// - Sends `Range: bytes=a-b`, `User-Agent` (desktop Chrome), `Referer: https://www.bilibili.com/`,
///   `Origin: https://www.bilibili.com`, `Accept: */*`, `Accept-Encoding: identity`, `Connection: keep-alive`.
///   Never sends cookies.
/// - Completed responses return their connection to a per-host keep-alive pool; cancelled / failed / partially read
///   connections are closed, never reused.
/// - No timeouts beyond a generous connect/backstop timeout (30 s): the downloader implements BTR's
///   first-byte (5.5 s), stall (4 s) and attempt (15 s) timers and cancels the consuming task.
protocol MediaHTTPClient: AnyObject {
    /// Starts the request immediately. Terminating the stream (consumer cancelled or stopped iterating) cancels it.
    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error>
    /// Optionally warm up TLS connections to these hosts (BTR "preconnect").
    func preconnect(hosts: [String])
    /// Close idle pooled connections (e.g. when the app goes to background).
    func closeIdleConnections()
    /// Currently open TCP connections (busy + idle), for diagnostics.
    var openConnectionCount: Int { get }
}

// MARK: - BTR downloader

/// Snapshot of the user's acceleration settings, read on every range (settings apply live, BTR §3).
struct BTRConfig: Equatable {
    var mode: CDNMode = .mainland
    var customHosts: [String] = []
    var autoConcurrency: Bool = true
    /// Manual thread count (one of 4/8/16/32/64/128) used when `autoConcurrency` is false.
    var concurrency: Int = 16
    /// Upper bound of the auto ladder on this device (iPhone: 32; iPad: 64).
    var maxAutoThreads: Int = 32

    init() {}

    init(settings: AccelerationSettings, maxAutoThreads: Int) {
        mode = settings.cdnMode
        customHosts = settings.customHosts
        autoConcurrency = settings.autoConcurrency
        concurrency = settings.manualConcurrency
        self.maxAutoThreads = maxAutoThreads
    }
}

/// How a range is downloaded (BTR §7.6–7.8, §10 "startup heuristic").
enum BTRRangeKind {
    /// init / sidx: whole-range race over ≤ 3 startup candidates (0 / 120 / 300 ms stagger), priority 220.
    case meta
    /// First media range after start / seek / retry: 64 KiB head probe raced over up to 8 URLs, then proven nodes.
    case startup
    /// Contiguous follow-up ranges: speed-weighted pieces with deadline-aware hedging.
    case ordinary
}

struct CDNNodeStatus: Hashable {
    enum State: String { case healthy, blocked, banned, untested }
    var host: String
    var state: State
    /// Bytes per second (0 = unmeasured).
    var bytesPerSecond: Double
}

struct BTRStats {
    var threads: Int = 0
    var activeConnections: Int = 0
    var queuedRequests: Int = 0
    /// Recent aggregate download speed in bytes/s.
    var bytesPerSecond: Double = 0
    /// Last auto-concurrency decision ("缓冲跟不上播放" …).
    var autoReason: String = ""
    var nodes: [CDNNodeStatus] = []
    var totalBytes: Int64 = 0
    var hedgedBytes: Int64 = 0
}

/// One media file (a DASH representation) inside a downloader. Holds the per-track CDN resolver.
protocol BTRTrackHandle: AnyObject {
    var kind: MediaKind { get }
    /// File size learnt from the first verified `Content-Range` (nil before).
    var total: Int64? { get }
    /// Swap in freshly signed URLs (expiry refresh, BTR §11.5). Speed history is kept (keyed by host+path).
    func updateURLs(_ urls: [String])
    func nodeStatus() -> [CDNNodeStatus]
}

/// Player → auto-concurrency signals (BTR §8 iOS mapping). One app-wide controller.
protocol AutoConcurrencySignals: AnyObject {
    var threads: Int { get }
    /// New item, or a seek outside the buffered ranges.
    func newSession()
    /// Playback stalled waiting for data (not decoder-bound, not during seek/startup).
    func stall()
    /// Called ≥ 4×/s while an item is active. `ahead` = buffered seconds ahead of the playhead.
    func buffer(ahead: Double, playing: Bool, cacheFull: Bool)
}

/// The BTR downloader. One instance per playback session; all tracks of the session share its connection budget
/// ("slots") and one ban list per `routeKey`.
protocol BTRDownloading: AnyObject {
    /// `urls` = playurl baseUrl + backupUrls (raw, unrewritten). `routeKey` identifies the video+part (ban-list scope).
    func makeTrack(kind: MediaKind, urls: [String], routeKey: String) -> BTRTrackHandle

    /// Downloads `range` of `track`.
    /// - Verified bytes (every byte from a 206 whose Content-Range matched exactly and whose total equals the track
    ///   total) are passed to `onBytes` strictly in file order, as early as possible (partial pieces stream from the
    ///   replica with the most bytes, like lemon's `_Feed`). `onBytes` applies back-pressure by suspending.
    /// - `deadline` returns the monotonic time (ms, `SystemClock`) by which the range must be complete for smooth
    ///   playback, re-read on every check; nil = no deadline.
    /// - Returns the file total. Throws when every candidate failed; cancelling the calling task aborts all requests.
    func download(
        _ range: ByteRange,
        track: BTRTrackHandle,
        kind: BTRRangeKind,
        priority: Int,
        deadline: (() -> Double?)?,
        onBytes: @escaping (Data) async throws -> Void
    ) async throws -> Int64

    /// Single-connection plain download (acceleration off / fallback): first working URL in order, with resume.
    func downloadDirect(
        _ range: ByteRange,
        track: BTRTrackHandle,
        onBytes: @escaping (Data) async throws -> Void
    ) async throws -> Int64

    var stats: BTRStats { get }
    /// Abort every request of this downloader (session closed).
    func cancelAll()
}
