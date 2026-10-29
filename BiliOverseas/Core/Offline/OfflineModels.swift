import Foundation

// 离线缓存 (offline download) data model: the persisted task list, the byte ranges of each file already on disk and
// the plan of what is still missing. Everything here is pure and Codable, so the manifest round-trips in unit tests.
//
// What is downloaded: the html5 progressive MP4 (`VideoAPI.progressivePlayInfo`, one file, ≤ 1080P), which AVPlayer
// plays from the sandbox without the local proxy (PlaybackItem.localFileURL).

enum OfflineTaskState: String, Codable, Hashable {
    /// Queued; starts when a download slot is free (also: interrupted by a relaunch or the app going to background).
    case waiting
    case downloading
    /// Paused by the user; stays until 继续.
    case paused
    /// Gave up after its retries; 重试 queues it again.
    case failed
    case completed
}

/// Closed byte span `[start, end]` as stored in the manifest.
struct OfflineSpan: Codable, Hashable {
    var start: Int64
    var end: Int64
    var length: Int64 { end - start + 1 }
}

/// The bytes of one file already written to disk: sorted, non-overlapping spans, adjacent spans merged. A paused or
/// interrupted download resumes by fetching only `missing(total:)`.
struct OfflineRangeSet: Codable, Hashable {
    private(set) var spans: [OfflineSpan] = []

    init() {}

    init(_ ranges: [ByteRange]) {
        for r in ranges { insert(r) }
    }

    var isEmpty: Bool { spans.isEmpty }

    var byteCount: Int64 { spans.reduce(0) { $0 + $1.length } }

    /// Bytes inside `[0, total)`.
    func byteCount(within total: Int64) -> Int64 {
        guard total > 0 else { return 0 }
        return spans.reduce(0) { sum, s in
            guard s.start < total else { return sum }
            return sum + (min(s.end, total - 1) - s.start + 1)
        }
    }

    mutating func insert(_ range: ByteRange) {
        guard range.start >= 0, range.end >= range.start else { return }
        var start = range.start, end = range.end
        var out: [OfflineSpan] = []
        out.reserveCapacity(spans.count + 1)
        var placed = false
        for s in spans {
            if s.end + 1 < start {
                out.append(s)
            } else if end + 1 < s.start {
                if !placed {
                    out.append(OfflineSpan(start: start, end: end))
                    placed = true
                }
                out.append(s)
            } else {
                // Overlapping or adjacent: merge into the pending span.
                start = min(start, s.start)
                end = max(end, s.end)
            }
        }
        if !placed { out.append(OfflineSpan(start: start, end: end)) }
        spans = out
    }

    /// The parts of `range` not covered yet, in file order.
    func missing(in range: ByteRange) -> [ByteRange] {
        guard range.start >= 0, range.end >= range.start else { return [] }
        var out: [ByteRange] = []
        var cursor = range.start
        for s in spans {
            if s.end < cursor { continue }
            if s.start > range.end { break }
            if s.start > cursor { out.append(ByteRange(start: cursor, end: s.start - 1)) }
            cursor = s.end + 1
            if cursor > range.end { return out }
        }
        if cursor <= range.end { out.append(ByteRange(start: cursor, end: range.end)) }
        return out
    }

    /// The parts of the file `[0, total)` not covered yet.
    func missing(total: Int64) -> [ByteRange] {
        guard total > 0 else { return [] }
        return missing(in: ByteRange(start: 0, end: total - 1))
    }

    func covers(total: Int64) -> Bool { total > 0 && missing(total: total).isEmpty }

    /// Only the bytes inside `[0, size)` (e.g. the length of the file actually found on disk).
    func clipped(to size: Int64) -> OfflineRangeSet {
        var out = OfflineRangeSet()
        guard size > 0 else { return out }
        for s in spans where s.start < size {
            out.insert(ByteRange(start: s.start, end: min(s.end, size - 1)))
        }
        return out
    }
}

/// Splits what is missing into the work units the parallel lanes take one at a time.
enum OfflineRangePlanner {
    /// One unit: a BTR range the downloader spreads over its connections (≈ 14 pieces of ≈ 600 KiB with 16 threads).
    static let defaultChunkBytes: Int64 = 8 * 1024 * 1024
    static let minimumChunkBytes: Int64 = 64 * 1024
    /// First request of every run, always at the head of the file (inside any real file, so a stale size never makes
    /// it ask past the end, which CDNs refuse and the ban list would count): learns / checks the file size and
    /// warms the CDN measurements. Costs at most 64 KiB again per resumed run.
    static let probeRange = ByteRange(start: 0, end: 64 * 1024 - 1)

    /// Each missing range cut into chunks of at most `chunkBytes`, in file order. A tail shorter than a quarter
    /// chunk joins the chunk before it, so no tiny last request is made.
    static func chunks(missing: [ByteRange], chunkBytes: Int64 = defaultChunkBytes) -> [ByteRange] {
        let size = max(minimumChunkBytes, chunkBytes)
        var out: [ByteRange] = []
        for r in missing where r.end >= r.start {
            var start = r.start
            while start <= r.end {
                var end = min(r.end, start + size - 1)
                if r.end - end < size / 4 { end = r.end }
                out.append(ByteRange(start: start, end: end))
                start = end + 1
            }
        }
        return out
    }
}

// MARK: - Task

/// One cached video part. Persisted in the manifest; `written` / `totalBytes` let a download resume where it stopped.
struct OfflineTask: Codable, Hashable, Identifiable {
    var id: String
    var aid: Int64
    var bvid: String
    var cid: Int64
    var title: String
    var cover: String = ""
    var ownerName: String = ""
    var ownerMid: Int64 = 0
    /// Seconds.
    var duration: Double = 0
    var isVertical: Bool = false
    /// 1-based part number and name (`VideoPart.page` / `.part`), and how many parts the archive had.
    var page: Int = 1
    var partTitle: String = ""
    var partCount: Int = 1
    /// The qn the user picked, and the one the server actually returned (≤ 80 on the html5 platform).
    var requestedQuality: Int = 80
    var quality: Int = 0
    var qualityTitle: String = ""
    var state: OfflineTaskState = .waiting
    /// File size in bytes (0 = not known yet).
    var totalBytes: Int64 = 0
    var written = OfflineRangeSet()
    var errorMessage: String?
    var createdAt = Date()
    var completedAt: Date?
    /// Local playback position for 继续播放 (seconds, 0 = from the start).
    var lastPosition: Double = 0

    init(aid: Int64, bvid: String, cid: Int64, title: String) {
        id = OfflineTask.makeID(aid: aid, bvid: bvid, cid: cid)
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
    }

    /// `BV1xx411c7mD_123456` (`av170001_123456` without a BV id); safe as a directory name.
    static func makeID(aid: Int64, bvid: String, cid: Int64) -> String {
        let video = bvid.isEmpty ? "av\(aid)" : bvid
        let safe: String.UnicodeScalarView = video.unicodeScalars.filter {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }
        return "\(String(safe))_\(cid)"
    }

    var isCompleted: Bool { state == .completed }

    /// Bytes on disk.
    var receivedBytes: Int64 {
        if state == .completed { return totalBytes }
        return totalBytes > 0 ? written.byteCount(within: totalBytes) : written.byteCount
    }

    /// 0 … 1 (0 while the size is unknown).
    var progress: Double {
        if state == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    /// "P2 第二集" for multi-part archives, "" otherwise.
    var displayPart: String {
        guard partCount > 1 else { return "" }
        return partTitle.isEmpty ? "P\(page)" : "P\(page) \(partTitle)"
    }

    /// The online video page of this part.
    var videoRef: VideoRef {
        VideoRef(aid: aid, bvid: bvid, cid: cid, title: title, cover: cover)
    }

    /// Where 继续播放 starts: the saved position unless it is at the very start or end.
    var resumePosition: Double {
        guard lastPosition >= 5 else { return 0 }
        if duration > 0, lastPosition >= duration - 5 { return 0 }
        return lastPosition
    }

    // Lenient decoding: fields added later default instead of failing the whole manifest.
    enum CodingKeys: String, CodingKey {
        case id, aid, bvid, cid, title, cover, ownerName, ownerMid, duration, isVertical, page, partTitle, partCount
        case requestedQuality, quality, qualityTitle, state, totalBytes, written, errorMessage, createdAt, completedAt
        case lastPosition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = try c.decodeIfPresent(Int64.self, forKey: .aid) ?? 0
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        cid = try c.decode(Int64.self, forKey: .cid)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? OfflineTask.makeID(aid: aid, bvid: bvid, cid: cid)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? ""
        ownerMid = try c.decodeIfPresent(Int64.self, forKey: .ownerMid) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        isVertical = try c.decodeIfPresent(Bool.self, forKey: .isVertical) ?? false
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        partTitle = try c.decodeIfPresent(String.self, forKey: .partTitle) ?? ""
        partCount = try c.decodeIfPresent(Int.self, forKey: .partCount) ?? 1
        requestedQuality = try c.decodeIfPresent(Int.self, forKey: .requestedQuality) ?? 80
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? 0
        qualityTitle = try c.decodeIfPresent(String.self, forKey: .qualityTitle) ?? ""
        // An unknown state (written by a newer build) becomes waiting rather than dropping the task.
        let rawState = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        state = OfflineTaskState(rawValue: rawState) ?? .waiting
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        written = (try? c.decodeIfPresent(OfflineRangeSet.self, forKey: .written)) ?? OfflineRangeSet()
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        lastPosition = try c.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
    }
}

// MARK: - Manifest

/// `tasks.json`: the whole task list, rewritten atomically on every change.
struct OfflineManifest: Codable {
    static let currentVersion = 1

    var version: Int = OfflineManifest.currentVersion
    var tasks: [OfflineTask]

    /// One unreadable entry is dropped instead of the whole list.
    private struct LenientTask: Decodable {
        let value: OfflineTask?
        init(from decoder: Decoder) throws {
            value = try? OfflineTask(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case version, tasks }

    init(tasks: [OfflineTask]) {
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? OfflineManifest.currentVersion
        tasks = (try c.decodeIfPresent([LenientTask].self, forKey: .tasks) ?? []).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(tasks, forKey: .tasks)
    }

    static func encode(_ tasks: [OfflineTask]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(OfflineManifest(tasks: tasks))
    }

    /// Tasks of a manifest file; [] for a missing or corrupt file. Duplicate ids keep the first entry.
    static func decode(_ data: Data) -> [OfflineTask] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let manifest = try? decoder.decode(OfflineManifest.self, from: data) else { return [] }
        var seen = Set<String>()
        return manifest.tasks.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Storage layout

/// `Application Support/Offline/`: `tasks.json` plus one directory per task holding `video.mp4` (`video.mp4.part`
/// while downloading). Excluded from iCloud backup.
struct OfflineStorageLayout {
    let root: URL

    static let manifestName = "tasks.json"
    static let videoName = "video.mp4"
    static let partialSuffix = ".part"

    init(root: URL) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Offline", isDirectory: true)
    }

    var manifestURL: URL { root.appendingPathComponent(Self.manifestName) }

    func directory(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func videoURL(for id: String) -> URL { directory(for: id).appendingPathComponent(Self.videoName) }

    func partialURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent(Self.videoName + Self.partialSuffix)
    }
}
