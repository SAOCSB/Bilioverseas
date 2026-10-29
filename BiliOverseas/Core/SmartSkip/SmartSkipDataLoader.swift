// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. Port of `scr/api.js` @ master 3ce86fa (v2.1.0): same endpoints, parameters, fallbacks
// and failure semantics (metadata → view API; chapters + subtitle tracks → player API; subtitle
// body without cookies; danmaku protobuf segments, 2 in flight, stop on 401/403/412/429, then the
// public XML as the only fallback). Data the player already holds can be supplied in
// `SmartSkipVideoContext` so nothing is fetched twice. Part of BiliOverseas (GPL-2.0-or-later).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Context

/// What the player knows about the video. Every optional piece left `nil` is fetched by
/// `SmartSkipDataLoader.complete(_:)`; pass `[]` to mean "known to be empty" (no request).
struct SmartSkipVideoContext {
    var aid: Int64 = 0
    var bvid: String
    /// The CURRENT part's cid. `0` → resolved through the view API (never P1's cid for P2).
    var cid: Int64
    /// 1-based part number (used only when `cid` must be resolved).
    var page: Int = 1
    /// The current part's duration in seconds (view API `pages[].duration` is what upstream
    /// uses); `0` = unknown.
    var duration: Double
    var title: String
    var desc: String
    /// Raw `view_points` (do not filter by `type`).
    var chapters: [VideoChapter]? = nil
    /// `data.subtitle.subtitles` of player/wbi/v2 (used only when `subtitleLines` is nil).
    var subtitleTracks: [SubtitleTrack]? = nil
    /// Body rows of the zh-CN / ai-zh (else first) track.
    var subtitleLines: [SubtitleLine]? = nil
    /// The WHOLE video's danmaku. Leave nil if only some segments are loaded.
    var danmaku: [SmartSkipDanmaku]? = nil

    init(aid: Int64 = 0, bvid: String, cid: Int64, page: Int = 1, duration: Double, title: String, desc: String,
         chapters: [VideoChapter]? = nil, subtitleTracks: [SubtitleTrack]? = nil,
         subtitleLines: [SubtitleLine]? = nil, danmaku: [SmartSkipDanmaku]? = nil) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.page = page
        self.duration = duration
        self.title = title
        self.desc = desc
        self.chapters = chapters
        self.subtitleTracks = subtitleTracks
        self.subtitleLines = subtitleLines
        self.danmaku = danmaku
    }

    /// The detector input (danmaku stably sorted by time, like `fetchDanmakuWithTime`).
    var inputs: SmartSkipInputs {
        SmartSkipInputs(bvid: bvid, cid: cid, duration: duration, title: title, desc: desc,
                        chapters: chapters ?? [],
                        danmaku: SmartSkipJS.stableSorted(danmaku ?? []) { $0.time - $1.time },
                        subtitles: subtitleLines ?? [])
    }
}

/// `normalizeVideoInfo` result.
struct SmartSkipVideoInfo: Equatable {
    var cid: Int64
    var title: String
    var desc: String
    /// `0` = unknown.
    var duration: Double
}

/// `fetchPlayerInfo` result.
struct SmartSkipPlayerInfo: Equatable {
    var viewPoints: [VideoChapter] = []
    var subtitles: [SubtitleTrack] = []
}

// MARK: - Transport

/// `credentials: 'include' | 'omit'` of `fetch`.
enum SmartSkipCredentials: Equatable {
    case include
    case omit
}

/// GET transport (`fetchBiliData`). Implementations must throw `BiliError.http(status:)` for a
/// non-2xx response BEFORE reading/parsing the body, and must not retry.
protocol SmartSkipTransport {
    func get(_ url: String, query: [String: String], credentials: SmartSkipCredentials, wbi: Bool) async throws -> Data
}

/// Production transport: `.include` goes through `BiliHTTP.shared` (account cookies, web
/// UA/Referer, WBI when asked); `.omit` uses a cookie-less ephemeral session.
struct SmartSkipBiliTransport: SmartSkipTransport {
    static let timeout: TimeInterval = 10

    private static let anonymousSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }()

    init() {}

    func get(_ url: String, query: [String: String], credentials: SmartSkipCredentials, wbi: Bool) async throws -> Data {
        switch credentials {
        case .include:
            let (data, _) = try await BiliHTTP.shared.data(url, query: query, sign: wbi ? .wbi : .none, timeout: Self.timeout)
            return data
        case .omit:
            guard var comps = URLComponents(string: url) else { throw BiliError.invalidURL(url) }
            if !query.isEmpty {
                let existing = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
                comps.percentEncodedQuery = existing + BiliHTTP.encodeQuery(query, sorted: true)
            }
            guard let finalURL = comps.url else { throw BiliError.invalidURL(url) }
            var req = URLRequest(url: finalURL, timeoutInterval: Self.timeout)
            req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            do {
                let (data, resp) = try await Self.anonymousSession.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw BiliError.other("非 HTTP 响应") }
                guard (200..<300).contains(http.statusCode) else { throw BiliError.http(status: http.statusCode) }
                return data
            } catch let e as URLError where e.code == .cancelled {
                throw BiliError.cancelled
            }
        }
    }
}

// MARK: - Loader

struct SmartSkipDataLoader {
    var transport: SmartSkipTransport

    init(transport: SmartSkipTransport = SmartSkipBiliTransport()) {
        self.transport = transport
    }

    /// Statuses that stop scheduling further danmaku segments.
    static let blockingStatuses: Set<Int> = [401, 403, 412, 429]

    static func httpStatus(of error: Error) -> Int? {
        if case .http(let status)? = error as? BiliError { return status }
        return nil
    }

    // MARK: Pipeline data (the network half of `getSkipSegment` / `getSkipSegments`)

    /// Fills every missing piece of `context`, mirroring the upstream order: metadata first
    /// (only when `cid` is unknown), then player info and danmaku concurrently
    /// (`Promise.all`), then the chosen subtitle body. Returns `nil` when no cid can be resolved
    /// (upstream then detects nothing).
    func complete(_ context: SmartSkipVideoContext) async -> SmartSkipVideoContext? {
        var c = context
        if c.cid <= 0 {
            guard let info = await fetchVideoInfo(bvid: c.bvid, aid: c.aid, pageNumber: c.page) else { return nil }
            c.cid = info.cid
            if c.title.isEmpty { c.title = info.title }
            if c.desc.isEmpty { c.desc = info.desc }
            c.duration = info.duration
        }
        guard c.cid > 0 else { return nil }
        let needsPlayerInfo = c.chapters == nil || (c.subtitleLines == nil && c.subtitleTracks == nil)
        let needsDanmaku = c.danmaku == nil
        let (bvid, aid, cid, duration) = (c.bvid, c.aid, c.cid, c.duration)
        async let playerInfo: SmartSkipPlayerInfo? = needsPlayerInfo ? fetchPlayerInfo(bvid: bvid, aid: aid, cid: cid) : nil
        async let danmaku: [SmartSkipDanmaku]? = needsDanmaku ? fetchDanmakuWithTime(cid: cid, duration: duration) : nil
        let (player, fetchedDanmaku) = await (playerInfo, danmaku)
        if c.chapters == nil { c.chapters = player?.viewPoints ?? [] }
        if c.subtitleTracks == nil { c.subtitleTracks = player?.subtitles ?? [] }
        if let fetchedDanmaku { c.danmaku = fetchedDanmaku }
        if c.subtitleLines == nil {
            if let chosen = Self.chooseSubtitleTrack(c.subtitleTracks ?? []) {
                c.subtitleLines = await fetchSubtitleBody(chosen.url)
            } else {
                c.subtitleLines = []
            }
        }
        return c
    }

    // MARK: api.js

    /// `getVideoPage()` validation: a non-positive page → 1.
    static func validPage(_ page: Int) -> Int { page > 0 ? page : 1 }

    /// `normalizeVideoInfo(data, bvid, pageNumber)`: never reuses P1's cid or the total
    /// duration for another part; rejects stale (other-bvid) data.
    static func normalizeVideoInfo(_ data: JSON, bvid: String, pageNumber: Int) -> SmartSkipVideoInfo? {
        guard data.exists, case .string(let dataBvid) = data["bvid"], dataBvid == bvid else { return nil }
        let pages = data["pages"].array ?? []
        var page: JSON?
        for item in pages {
            if item.isNull { return nil }       // JS: `null.page` throws → fetchVideoInfo → null
            if SmartSkipJS.number(item["page"]) == Double(pageNumber) { page = item; break }
        }
        if page == nil && (!pages.isEmpty || pageNumber != 1) { return nil }
        let cid = SmartSkipJS.number(page?["cid"] ?? data["cid"])
        guard SmartSkipJS.isSafeInteger(cid), cid > 0 else { return nil }
        let duration = SmartSkipJS.number(page?["duration"] ?? data["duration"])
        return SmartSkipVideoInfo(
            cid: Int64(cid),
            title: jsString(data["title"]),
            desc: jsString(data["desc"]),
            duration: duration.isFinite && duration > 0 ? duration : 0)
    }

    /// `typeof v === 'string' ? v : ''`.
    private static func jsString(_ v: JSON) -> String {
        if case .string(let s) = v { return s }
        return ""
    }

    /// `fetchVideoInfo(bvid, pageNumber)`: `GET /x/web-interface/view?bvid=` (cookies included).
    func fetchVideoInfo(bvid: String, aid: Int64 = 0, pageNumber: Int = 1) async -> SmartSkipVideoInfo? {
        let page = Self.validPage(pageNumber)
        do {
            let query = bvid.isEmpty ? ["aid": String(aid)] : ["bvid": bvid]
            let data = try await transport.get("\(BiliHost.api)/x/web-interface/view", query: query, credentials: .include, wbi: false)
            let json = try JSON(data: data)
            guard json["code"] == .int(0) else { throw BiliError.api(code: json["code"].intValue, message: json["message"].stringValue) }
            let expected = bvid.isEmpty ? json["data"]["bvid"].stringValue : bvid
            return Self.normalizeVideoInfo(json["data"], bvid: expected, pageNumber: page)
        } catch {
            SmartSkipUtils.log("fetchVideoInfo failed:", error)
            return nil
        }
    }

    /// `fetchPlayerInfo(bvid, cid)`: chapters + subtitle track list from `/x/player/wbi/v2`
    /// (WBI-signed like the web player; cookies included). Any failure → empty lists.
    func fetchPlayerInfo(bvid: String, aid: Int64 = 0, cid: Int64) async -> SmartSkipPlayerInfo {
        do {
            var query = ["cid": String(cid)]
            if bvid.isEmpty { query["aid"] = String(aid) } else { query["bvid"] = bvid }
            let data = try await transport.get("\(BiliHost.api)/x/player/wbi/v2", query: query, credentials: .include, wbi: true)
            let json = try JSON(data: data)
            guard json["code"] == .int(0), json["data"].exists else {
                throw BiliError.api(code: json["code"].intValue, message: json["message"].stringValue)
            }
            return Self.parsePlayerInfo(json["data"])
        } catch {
            SmartSkipUtils.log("fetchPlayerInfo failed:", error)
            return SmartSkipPlayerInfo()
        }
    }

    /// Maps `data.view_points[]` / `data.subtitle.subtitles[]` (missing times stay invalid: NaN).
    static func parsePlayerInfo(_ data: JSON) -> SmartSkipPlayerInfo {
        let viewPoints = (data["view_points"].array ?? []).map { vp in
            VideoChapter(from: vp["from"].double ?? .nan, to: vp["to"].double ?? .nan, title: vp["content"].stringValue)
        }
        let tracks = (data["subtitle"]["subtitles"].array ?? []).map { s -> SubtitleTrack in
            let lan = s["lan"].stringValue
            return SubtitleTrack(id: s["id"].int64Value, lan: lan, lanDoc: s["lan_doc"].stringValue,
                                 url: s["subtitle_url"].stringValue,
                                 isAI: lan.hasPrefix("ai-") || s["type"].intValue == 1)
        }
        return SmartSkipPlayerInfo(viewPoints: viewPoints, subtitles: tracks)
    }

    /// `tracks.find(s => s.lan === 'zh-CN' || s.lan === 'ai-zh') || tracks[0]`.
    static func chooseSubtitleTrack(_ tracks: [SubtitleTrack]) -> SubtitleTrack? {
        tracks.first { $0.lan == "zh-CN" || $0.lan == "ai-zh" } ?? tracks.first
    }

    /// `fetchSubtitleBody(subtitleUrl)`: protocol-relative URLs get `https:`; NO cookies. Any
    /// failure (incl. the empty AI-subtitle URL of logged-out users) → `[]`.
    func fetchSubtitleBody(_ subtitleUrl: String) async -> [SubtitleLine] {
        do {
            let url = subtitleUrl.hasPrefix("//") ? "https:" + subtitleUrl : subtitleUrl
            guard URL(string: url)?.scheme != nil else { throw BiliError.invalidURL(url) }
            let data = try await transport.get(url, query: [:], credentials: .omit, wbi: false)
            return Self.parseSubtitleBody(try JSON(data: data))
        } catch {
            SmartSkipUtils.log("fetchSubtitleBody failed:", error)
            return []
        }
    }

    static func parseSubtitleBody(_ json: JSON) -> [SubtitleLine] {
        (json["body"].array ?? []).map { row in
            SubtitleLine(from: row["from"].double ?? .nan, to: row["to"].double ?? .nan, content: row["content"].stringValue)
        }
    }

    // MARK: Protobuf danmaku decoder (no external dependency)

    struct ProtoError: Error {}

    /// `decodeDanmakuProto(buffer)`: `DmSegMobileReply { repeated DanmakuElem elems = 1 }`,
    /// `DanmakuElem { int32 progress = 2 (ms); string content = 7 }`. JS 32-bit varint semantics
    /// (`|=`, `<<` mod 32) are reproduced; any out-of-range length throws (the whole segment is
    /// lost, like upstream). Empty contents are dropped.
    static func decodeDanmakuProto(_ data: Data) throws -> [SmartSkipDanmaku] {
        let buffer = [UInt8](data)
        var results: [SmartSkipDanmaku] = []
        var offset = 0

        func readVarint(_ pos: inout Int, _ limit: Int) -> Int32 {
            var result: UInt32 = 0
            var shift: UInt32 = 0
            while pos < limit {
                let byte = buffer[pos]
                pos += 1
                result |= UInt32(byte & 0x7F) << (shift & 31)
                if byte & 0x80 == 0 { return Int32(bitPattern: result) }
                shift += 7
            }
            return Int32(bitPattern: result)
        }

        func decodeDanmakuElem(base: Int, length: Int) throws -> (progress: Int32, content: String) {
            var elem: (progress: Int32, content: String) = (0, "")
            var pos = 0
            func readElemVarint() -> Int32 {
                var p = base + pos
                let v = readVarint(&p, base + length)
                pos = p - base
                return v
            }
            while pos < length {
                let tag = readElemVarint()
                let fieldNum = UInt32(bitPattern: tag) >> 3
                let wireType = tag & 0x7
                if wireType == 0 {
                    let val = readElemVarint()
                    if fieldNum == 2 { elem.progress = val }
                } else if wireType == 2 {
                    let len = Int(readElemVarint())
                    if fieldNum == 7 {
                        // JS: Uint8Array over the WHOLE buffer → bounds are the whole buffer's.
                        let start = base + pos
                        guard len >= 0, start + len <= buffer.count else { throw ProtoError() }
                        var text = String(decoding: buffer[start..<(start + len)], as: UTF8.self)
                        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // TextDecoder strips a BOM
                        elem.content = text
                    }
                    guard len >= 0 else { throw ProtoError() }
                    pos += len
                } else if wireType == 5 {
                    pos += 4
                } else if wireType == 1 {
                    pos += 8
                } else {
                    break
                }
            }
            return elem
        }

        while offset < buffer.count {
            let tag = readVarint(&offset, buffer.count)
            let fieldNum = UInt32(bitPattern: tag) >> 3
            let wireType = tag & 0x7
            if wireType == 2 {
                let len = Int(readVarint(&offset, buffer.count))
                guard len >= 0, offset + len <= buffer.count else { throw ProtoError() }
                let base = offset
                offset += len
                if fieldNum == 1 {
                    let elem = try decodeDanmakuElem(base: base, length: len)
                    if !elem.content.isEmpty {
                        results.append(SmartSkipDanmaku(time: Double(elem.progress) / 1000, textContent: elem.content))
                    }
                }
            } else if wireType == 0 {
                _ = readVarint(&offset, buffer.count)
            } else if wireType == 5 {
                offset += 4
            } else if wireType == 1 {
                offset += 8
            } else {
                break
            }
        }
        return results
    }

    /// `fetchDanmakuSegment(cid, segmentIndex)`: `GET /x/v2/dm/web/seg.so` (cookies included).
    func fetchDanmakuSegment(cid: Int64, segmentIndex: Int) async throws -> [SmartSkipDanmaku] {
        let data = try await transport.get("\(BiliHost.api)/x/v2/dm/web/seg.so",
                                           query: ["type": "1", "oid": String(cid), "segment_index": String(segmentIndex)],
                                           credentials: .include, wbi: false)
        return try Self.decodeDanmakuProto(data)
    }

    /// Shared worker state of `fetchDanmakuWithTime` (shared counter, `blocked` flag, rows in
    /// completion order).
    private actor DanmakuPool {
        let segmentCount: Int
        var nextSegment = 1
        var blocked = false
        var rows: [SmartSkipDanmaku] = []
        init(segmentCount: Int) { self.segmentCount = segmentCount }
        func take() -> Int? {
            guard !blocked, nextSegment <= segmentCount else { return nil }
            defer { nextSegment += 1 }
            return nextSegment
        }
        func add(_ new: [SmartSkipDanmaku]) { rows += new }
        func block() { blocked = true }
    }

    /// `fetchDanmakuWithTime(cid, duration)`: 6-minute protobuf segments (600 s assumed when the
    /// duration is unknown), at most 2 in flight; 401/403/412/429 stop scheduling new requests
    /// (in-flight results still count). Rows are stably sorted by time. Only if protobuf yields
    /// nothing at all, the public XML (`comment.bilibili.com/{cid}.xml`, no cookies) is tried;
    /// any XML failure → `[]`.
    func fetchDanmakuWithTime(cid: Int64, duration: Double) async -> [SmartSkipDanmaku] {
        let segmentCount = Int(((duration.isFinite && duration > 0 ? duration : 600) / 360).rounded(.up))
        let pool = DanmakuPool(segmentCount: segmentCount)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(2, segmentCount) {
                group.addTask {
                    while !Task.isCancelled, let index = await pool.take() {
                        do {
                            await pool.add(try await fetchDanmakuSegment(cid: cid, segmentIndex: index))
                        } catch {
                            // Keep successful segments, cap concurrency, and stop scheduling
                            // requests when the server asks us to stop.
                            if let status = Self.httpStatus(of: error), Self.blockingStatuses.contains(status) { await pool.block() }
                            SmartSkipUtils.log("danmaku segment \(index) failed:", error)
                        }
                    }
                }
            }
        }
        let danmaku = await pool.rows
        if !danmaku.isEmpty {
            SmartSkipUtils.log("danmaku fetched via protobuf: \(danmaku.count) (\(segmentCount) segments)")
            return SmartSkipJS.stableSorted(danmaku) { $0.time - $1.time }
        }
        do {
            // The public XML CDN does not need a login.
            let data = try await transport.get("\(BiliHost.comment)/\(cid).xml", query: [:], credentials: .omit, wbi: false)
            let fallback = try Self.parseDanmakuXML(data)
            SmartSkipUtils.log("danmaku fetched via XML fallback: \(fallback.count)")
            return fallback
        } catch {
            SmartSkipUtils.log("danmaku unavailable; continuing with other sources:", error)
            return []
        }
    }

    // MARK: XML danmaku

    struct XMLError: Error {}

    /// Parses `<i><d p="time,mode,...">text</d>…</i>`: only `p[0]` (JS `parseFloat`) and the
    /// element's text are used; rows must have a finite time ≥ 0 and non-empty text; stably
    /// sorted by time. A parse error or a root other than `<i>` throws. If the body is still
    /// raw-deflate compressed (risk R4), it is inflated first (Apple platforms).
    static func parseDanmakuXML(_ data: Data) throws -> [SmartSkipDanmaku] {
        if let rows = try? parseDanmakuXMLDocument(data) { return rows }
        #if canImport(Darwin)
        if let inflated = try? (data as NSData).decompressed(using: .zlib) as Data, let rows = try? parseDanmakuXMLDocument(inflated) {
            return rows
        }
        #endif
        throw XMLError()
    }

    private static func parseDanmakuXMLDocument(_ data: Data) throws -> [SmartSkipDanmaku] {
        let delegate = SmartSkipDanmakuXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        guard ok, !delegate.failed, delegate.depth == 0, delegate.rootName == "i" else { throw XMLError() }
        let rows = delegate.rows.map { row in
            SmartSkipDanmaku(time: SmartSkipJS.parseFloat(row.p.components(separatedBy: ",")[0]), textContent: row.text)
        }.filter { $0.time.isFinite && $0.time >= 0 && !$0.textContent.isEmpty }
        return SmartSkipJS.stableSorted(rows) { $0.time - $1.time }
    }
}

/// Collects `<d>` elements in document order with their `textContent`.
private final class SmartSkipDanmakuXMLDelegate: NSObject, XMLParserDelegate {
    var rootName: String?
    var rows: [(p: String, text: String)] = []
    /// Open elements; must be 0 after a well-formed document.
    private(set) var depth = 0
    /// Set on any parse error (Linux' XMLParser does not always report it through `parse()`).
    private(set) var failed = false
    private var stack: [String] = []
    private var open: [Int] = []   // indices into `rows` of the currently open <d> elements

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if rootName == nil { rootName = elementName } else if depth == 0 { failed = true }   // second root
        depth += 1
        stack.append(elementName)
        if elementName == "d" {
            rows.append((attributeDict["p"] ?? "", ""))
            open.append(rows.count - 1)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.last != elementName { failed = true }
        if !stack.isEmpty { stack.removeLast() }
        depth -= 1
        if elementName == "d", !open.isEmpty { open.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for i in open { rows[i].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let string = String(decoding: CDATABlock, as: UTF8.self)
        for i in open { rows[i].text += string }
    }
}
