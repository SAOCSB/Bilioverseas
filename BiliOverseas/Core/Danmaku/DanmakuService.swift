import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Danmaku network API: segment download (protobuf, with XML fallback), sending, cloud block rules.
enum DanmakuService {
    static let wbiSegmentURL = BiliHost.api + "/x/v2/dm/wbi/web/seg.so"
    static let webSegmentURL = BiliHost.api + "/x/v2/dm/web/seg.so"
    static let legacyXMLURL = BiliHost.api + "/x/v1/dm/list.so"
    static let postURL = BiliHost.api + "/x/v2/dm/post"
    static let filterURL = BiliHost.api + "/x/dm/filter/user"
    static let filterAddURL = BiliHost.api + "/x/dm/filter/user/add"

    /// Downloads one 6-minute segment (`segmentIndex` is 1-based). Tries the WBI-signed web
    /// endpoint, then the unsigned one; the whole chain is retried once. A 304 or an empty body
    /// means "no danmaku in this segment" and returns an empty reply.
    static func fetchSegment(cid: Int64, aid: Int64, segmentIndex: Int) async throws -> DanmakuSegmentReply {
        var lastError: Error = BiliError.emptyData
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            try Task.checkCancellation()
            var query: [String: Any] = ["type": 1, "oid": cid, "segment_index": segmentIndex]
            if aid > 0 { query["pid"] = aid }
            var wbiQuery = query
            wbiQuery["web_location"] = 1315873
            do {
                return try await fetchProtobuf(wbiSegmentURL, query: wbiQuery, sign: .wbi)
            } catch let e as BiliError where e == .cancelled {
                throw e
            } catch {
                lastError = error
            }
            do {
                return try await fetchProtobuf(webSegmentURL, query: query, sign: .none)
            } catch let e as BiliError where e == .cancelled {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchProtobuf(_ url: String, query: [String: Any], sign: SignMode) async throws -> DanmakuSegmentReply {
        let data: Data
        do {
            (data, _) = try await BiliHTTP.shared.data(url, query: query, sign: sign,
                                                       headers: ["Accept": "application/octet-stream, */*"])
        } catch BiliError.http(status: 304) {
            return .empty
        }
        do {
            return try DanmakuProtobuf.decodeSegmentReply(data)
        } catch {
            throw BiliError.decoding("danmaku segment")
        }
    }

    /// Legacy all-in-one XML (`x/v1/dm/list.so`), used when the protobuf endpoints fail.
    static func fetchLegacyXML(cid: Int64) async throws -> [DanmakuItem] {
        let (data, _) = try await BiliHTTP.shared.data(legacyXMLURL, query: ["oid": cid])
        if let items = DanmakuXMLDecoder.decode(data) { return items }
        #if canImport(Darwin)
        // list.so is served raw-deflate (`Content-Encoding: deflate`); if the transport handed the
        // body over still compressed, inflate it (NSData's `.zlib` is raw DEFLATE).
        if let inflated = try? (data as NSData).decompressed(using: .zlib) as Data,
           let items = DanmakuXMLDecoder.decode(inflated) {
            return items
        }
        #endif
        throw BiliError.decoding("danmaku xml")
    }

    /// Sends a danmaku (`POST x/v2/dm/post`). Returns the new dmid (0 if the server omitted it).
    /// `time` is the video position in seconds; `mode` 1 scroll / 4 bottom / 5 top; `fontSize` 25 or 18.
    static func sendDanmaku(aid: Int64, cid: Int64, text: String, time: Double, color: UInt32,
                            mode: Int, fontSize: Int) async throws -> Int64 {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { throw BiliError.other("弹幕内容不能为空") }
        guard BiliHTTP.shared.isLoggedIn else { throw BiliError.notLoggedIn }
        let progress = Int64((max(0, time.isFinite ? time : 0) * 1000).rounded())
        var form: [String: Any] = [
            "type": 1,
            "oid": cid,
            "msg": String(msg.prefix(100)),
            "progress": progress,
            "color": Int64(color & 0xFFFFFF),
            "fontsize": fontSize,
            "pool": 0,
            "mode": mode,
            "rnd": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "plat": 1,
        ]
        if aid > 0 { form["aid"] = aid }
        let data = try await BiliHTTP.shared.post(postURL, form: form)
        return data["dmid"].int64 ?? Int64(data["dmid_str"].stringValue) ?? 0
    }

    /// The account's server-side block rules (`x/dm/filter/user`). type 0 keyword, 1 regex, 2 user.
    static func fetchCloudRules() async throws -> [DanmakuCloudRule] {
        let data = try await BiliHTTP.shared.api(filterURL)
        return data["rule"].arrayValue.compactMap { j in
            let filter = j["filter"].stringValue
            guard !filter.isEmpty else { return nil }
            return DanmakuCloudRule(id: j["id"].int64Value, type: j["type"].intValue, filter: filter)
        }
    }

    /// Adds a server-side block rule. Returns the stored rule.
    @discardableResult
    static func addCloudRule(type: Int, filter: String) async throws -> DanmakuCloudRule {
        let data = try await BiliHTTP.shared.post(filterAddURL, form: ["type": type, "filter": filter])
        return DanmakuCloudRule(id: data["id"].int64Value, type: data["type"].int ?? type,
                                filter: data["filter"].string ?? filter)
    }
}

/// One account block rule from `x/dm/filter/user`.
struct DanmakuCloudRule: Equatable, Sendable {
    var id: Int64
    /// 0 keyword, 1 regex, 2 user (midHash).
    var type: Int
    var filter: String

    /// The rule in local `DanmakuSettings` form: keyword, `/regex/`, or a midHash.
    var localKeyword: String? {
        switch type {
        case 0: return filter
        case 1: return filter.hasPrefix("/") && filter.hasSuffix("/") && filter.count >= 2 ? filter : "/\(filter)/"
        default: return nil
        }
    }

    /// Merges rules into the local lists, skipping duplicates.
    static func merge(_ rules: [DanmakuCloudRule], into settings: inout DanmakuSettings) -> Int {
        var added = 0
        for rule in rules {
            if rule.type == 2 {
                let hash = rule.filter.lowercased()
                if !settings.blockedUsers.contains(hash) { settings.blockedUsers.append(hash); added += 1 }
            } else if let kw = rule.localKeyword, !settings.blockedKeywords.contains(kw) {
                settings.blockedKeywords.append(kw)
                added += 1
            }
        }
        return added
    }
}

/// Parses the legacy XML danmaku list:
/// `<i><d p="time,mode,size,color,ctime,pool,midHash,dmid,weight">text</d>…</i>`.
final class DanmakuXMLDecoder: NSObject, XMLParserDelegate {
    private var items: [DanmakuItem] = []
    private var currentP: String?
    private var text = ""
    private var sawRoot = false
    private var sawAnyElement = false

    /// nil when the body is not a danmaku XML document.
    static func decode(_ data: Data) -> [DanmakuItem]? {
        guard !data.isEmpty else { return nil }
        let decoder = DanmakuXMLDecoder()
        let parser = XMLParser(data: data)
        parser.delegate = decoder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        guard decoder.sawRoot, ok || !decoder.items.isEmpty else { return nil }
        return decoder.items.sorted { $0.time < $1.time }
    }

    /// Parses one `p` attribute plus text.
    static func item(p: String, text: String) -> DanmakuItem? {
        let f = p.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, let time = Double(f[0]), time.isFinite, !text.isEmpty else { return nil }
        var item = DanmakuItem(id: 0, time: max(0, (time * 1000).rounded() / 1000), content: text)
        item.mode = Int(f[1]) ?? 1
        item.fontSize = Int(f[2]) ?? 25
        item.color = UInt32(truncatingIfNeeded: Int64(f[3]) ?? 0xFFFFFF) & 0xFFFFFF
        if f.count > 4 { item.ctime = Int64(f[4]) ?? 0 }
        if f.count > 5 { item.pool = Int(f[5]) ?? 0 }
        if f.count > 6 { item.midHash = f[6] }
        if f.count > 7 { item.id = Int64(f[7]) ?? 0 }
        if f.count > 8 { item.weight = Int(f[8]) ?? 0 }
        return item
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if !sawAnyElement {
            sawAnyElement = true
            sawRoot = elementName == "i"
        }
        if elementName == "d" {
            currentP = attributeDict["p"] ?? ""
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentP != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "d", let p = currentP {
            if let item = DanmakuXMLDecoder.item(p: p, text: text) { items.append(item) }
            currentP = nil
            text = ""
        }
    }
}

/// Loads danmaku segments for one video and caches them. Thread-safe (actor).
///
/// Call `segmentsToLoad(time:duration:afterSeek:)` to know which segments matter for a playback
/// position (current; next when within 30 s of its end; previous after a seek near the start of a
/// segment), then `load(segment:)` for each. Results are cached; a failed segment returns nil and
/// can be retried later. If the protobuf endpoints fail, the legacy XML list is fetched once and
/// sliced into segments.
actor DanmakuSegmentLoader {
    typealias SegmentFetcher = @Sendable (_ segmentIndex: Int) async throws -> DanmakuSegmentReply
    typealias AllFetcher = @Sendable () async throws -> [DanmakuItem]

    static let lookahead: Double = 30

    nonisolated let cid: Int64
    nonisolated let aid: Int64
    nonisolated let duration: Double

    private let fetchSegment: SegmentFetcher
    private let fetchAll: AllFetcher?
    private var cache: [Int: [DanmakuItem]] = [:]
    private var inFlight: [Int: Task<DanmakuSegmentReply?, Never>] = [:]
    private var fallbackTask: Task<[DanmakuItem]?, Never>?
    private var fallbackItems: [DanmakuItem]?
    /// Bumped by `cancelAll()`: waiters from before it report a failure instead of caching or
    /// falling back to the XML list.
    private var epoch = 0
    private(set) var isClosed = false

    init(cid: Int64, aid: Int64, duration: Double,
         fetchSegment: SegmentFetcher? = nil, fetchAll: AllFetcher? = nil, useXMLFallback: Bool = true) {
        self.cid = cid
        self.aid = aid
        self.duration = duration
        if let fetchSegment {
            self.fetchSegment = fetchSegment
        } else {
            self.fetchSegment = { index in
                try await DanmakuService.fetchSegment(cid: cid, aid: aid, segmentIndex: index)
            }
        }
        if let fetchAll {
            self.fetchAll = fetchAll
        } else if useXMLFallback, fetchSegment == nil {
            self.fetchAll = { try await DanmakuService.fetchLegacyXML(cid: cid) }
        } else {
            self.fetchAll = nil
        }
    }

    /// Which segments (1-based) are relevant for `time`, most important first.
    nonisolated static func segmentsToLoad(time: Double, duration: Double, afterSeek: Bool,
                                           lookahead: Double = DanmakuSegmentLoader.lookahead) -> [Int] {
        let t = max(0, time.isFinite ? time : 0)
        let index = DanmakuSegment.index(for: t)
        var out = [index]
        let offset = t - DanmakuSegment.range(of: index).lowerBound
        let hasNext = duration <= 0 || DanmakuSegment.range(of: index).upperBound < duration
        if DanmakuSegment.duration - offset <= lookahead, hasNext { out.append(index + 1) }
        if afterSeek, index > 1, offset < lookahead { out.append(index - 1) }
        return out
    }

    nonisolated func segmentsToLoad(time: Double, afterSeek: Bool) -> [Int] {
        DanmakuSegmentLoader.segmentsToLoad(time: time, duration: duration, afterSeek: afterSeek)
    }

    func isLoaded(_ segment: Int) -> Bool { cache[segment] != nil }

    func cachedItems(segment: Int) -> [DanmakuItem]? { cache[segment] }

    /// Every loaded item, sorted by time.
    func allLoadedItems() -> [DanmakuItem] {
        cache.keys.sorted().flatMap { cache[$0] ?? [] }
    }

    /// Loaded items with `from < time <= to`, sorted.
    func items(from: Double, to: Double) -> [DanmakuItem] {
        guard to > from else { return [] }
        let first = DanmakuSegment.index(for: max(0, from))
        // `index(for:)` maps a non-finite time to 1; an open-ended window ends at the last loaded segment.
        let last = to.isFinite ? DanmakuSegment.index(for: to) : (cache.keys.max() ?? first)
        guard last >= first else { return [] }
        var out: [DanmakuItem] = []
        for s in first...last {
            guard let list = cache[s] else { continue }
            out.append(contentsOf: list.lazy.filter { $0.time > from && $0.time <= to })
        }
        return out
    }

    /// Loads (or returns the cached) items of a segment, sorted by time. nil = failed (retry later).
    func load(segment index: Int) async -> [DanmakuItem]? {
        guard index >= 1 else { return [] }
        if let cached = cache[index] { return cached }
        let startEpoch = epoch
        let task: Task<DanmakuSegmentReply?, Never>
        if let existing = inFlight[index] {
            task = existing
        } else {
            let fetch = fetchSegment
            task = Task { try? await fetch(index) }
            inFlight[index] = task
        }
        let reply = await task.value
        // Actor reentrancy: after `cancelAll()` a newer request may own this slot — keep it.
        if inFlight[index] == task { inFlight[index] = nil }
        if let cached = cache[index] { return cached }
        // Cancelled while waiting: a failure, never a reason to download the whole XML list.
        guard startEpoch == epoch else { return nil }
        if let reply {
            if reply.isClosed { isClosed = true }
            let sorted = reply.items.sorted { $0.time < $1.time }
            cache[index] = sorted
            return sorted
        }
        guard let all = await loadFallback() else { return nil }
        let range = DanmakuSegment.range(of: index)
        let slice = all.filter { range.contains($0.time) }
        cache[index] = slice
        return slice
    }

    private func loadFallback() async -> [DanmakuItem]? {
        if let fallbackItems { return fallbackItems }
        guard let fetchAll else { return nil }
        let startEpoch = epoch
        let task: Task<[DanmakuItem]?, Never>
        if let existing = fallbackTask {
            task = existing
        } else {
            task = Task { try? await fetchAll() }
            fallbackTask = task
        }
        let result = await task.value
        if fallbackTask == task { fallbackTask = nil }
        if let fallbackItems { return fallbackItems }
        guard startEpoch == epoch else { return nil }
        if let result {
            let sorted = result.sorted { $0.time < $1.time }
            fallbackItems = sorted
            return sorted
        }
        return nil
    }

    /// Cancels in-flight requests (e.g. when the player switches video). Their waiters get nil
    /// (nothing is cached and the XML fallback is not started); later loads work normally.
    func cancelAll() {
        epoch += 1
        for t in inFlight.values { t.cancel() }
        inFlight.removeAll()
        fallbackTask?.cancel()
        fallbackTask = nil
    }
}
