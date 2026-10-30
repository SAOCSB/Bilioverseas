import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Video-side Bilibili API: detail, playurl (UGC + PGC), player side data, subtitles, related,
/// interactions (like / coin / triple / favourite / watch later), heartbeat, online count, PGC season.
///
/// Every `parse…` function is pure (JSON → model) so it can be unit-tested without the network.
enum VideoAPI {
    private static var http: BiliHTTP { BiliHTTP.shared }
    private static let api = BiliHost.api

    /// The highest `qn` code; requesting it makes the server return every tier it allows.
    static let topQualityCode = 129
    /// fnval = DASH | HDR | 4K | Dolby audio | Dolby Vision | 8K | AV1.
    static let dashFnval = 4048

    // MARK: - Errors

    enum ErrorContext { case video, pgc }

    /// Readable Chinese text for well-known business codes, nil if the server message should be used.
    static func friendlyMessage(code: Int, context: ErrorContext = .video) -> String? {
        switch code {
        case -404: return context == .pgc ? "该剧集不存在或已下架" : "视频不存在或已被删除"
        case 62002: return "稿件不可见"
        case 62004: return "稿件审核中，暂时无法观看"
        case 62012: return "该稿件仅UP主自己可见"
        case 87008: return "该视频为充电专属视频，充电后才能观看"
        case -10403: return context == .pgc ? "该番剧在当前地区不可播放" : "该视频在当前地区不可观看"
        case -111: return "登录状态校验失败，请重新登录"
        case 65004: return "取消点赞失败"
        case 65006: return "已经点过赞了"
        case 65005: return "还没有点过踩"
        case 65007: return "已经点过踩了"
        case 34002: return "不能给自己投币哦"
        case 34003: return "投币数量不正确"
        case 34004: return "投币间隔太短，请稍后再试"
        case 34005: return "已达到投币上限"
        case -104: return "硬币余额不足"
        case 11201: return "已经收藏过了"
        case 11202: return "已经取消收藏了"
        case 11203: return "收藏夹已满"
        case 90001: return "稍后再看列表已满"
        case 90003: return "稿件已失效"
        default: return nil
        }
    }

    /// Maps `BiliError.api` codes to readable messages (keeps the code for program logic).
    static func mapError(_ error: Error, context: ErrorContext = .video) -> Error {
        guard let e = error as? BiliError, case .api(let code, let msg) = e else { return error }
        if let friendly = friendlyMessage(code: code, context: context) { return BiliError.api(code: code, message: friendly) }
        if context == .pgc, isRegionMessage(msg) { return BiliError.api(code: code, message: "该番剧在当前地区不可播放") }
        return error
    }

    static func isRegionLocked(_ error: Error) -> Bool {
        guard let e = error as? BiliError, case .api(let code, let msg) = e else { return false }
        return code == -10403 || isRegionMessage(msg)
    }

    private static func isRegionMessage(_ msg: String) -> Bool {
        msg.contains("地区") || msg.contains("区域")
    }

    /// Errors after which an alternative endpoint is worth trying (not auth / content errors).
    private static func isEndpointFailure(_ error: Error) -> Bool {
        guard let e = error as? BiliError else { return true }
        switch e {
        case .http, .decoding, .emptyData, .other: return true
        case .api(let code, _): return [-400, -403, -404, -352, -412, -500, -503].contains(code)
        default: return false
        }
    }

    // MARK: - Detail

    /// `/x/web-interface/wbi/view` (WBI), falling back to the unsigned `/x/web-interface/view`.
    static func detail(_ ref: VideoRef) async throws -> VideoDetail {
        var q: [String: Any] = [:]
        if !ref.bvid.isEmpty { q["bvid"] = ref.bvid } else if ref.aid > 0 { q["aid"] = ref.aid } else {
            throw BiliError.other("缺少视频 ID")
        }
        do {
            let data = try await http.api(api + "/x/web-interface/wbi/view", query: q, sign: .wbi)
            return try validatedDetail(data)
        } catch BiliError.cancelled {
            throw BiliError.cancelled
        } catch let e as BiliError where isDefinitiveContentError(e) {
            throw mapError(e)
        } catch {
            do {
                let data = try await http.api(api + "/x/web-interface/view", query: q)
                return try validatedDetail(data)
            } catch {
                throw mapError(error)
            }
        }
    }

    static func parseDetail(_ data: JSON) -> VideoDetail { VideoDetail(json: data) }

    /// Content errors that another endpoint would answer the same way.
    private static func isDefinitiveContentError(_ e: BiliError) -> Bool {
        guard let code = e.apiCode else { return false }
        return [-404, 62002, 62004, 62012, 87008, -10403].contains(code)
    }

    private static func validatedDetail(_ data: JSON) throws -> VideoDetail {
        let d = VideoDetail(json: data)
        guard d.aid != 0 || !d.bvid.isEmpty else { throw BiliError.emptyData }
        return d
    }

    /// `/x/player/pagelist` (aid/bvid → parts).
    static func pageList(aid: Int64, bvid: String) async throws -> [VideoPart] {
        var q: [String: Any] = [:]
        if !bvid.isEmpty { q["bvid"] = bvid } else { q["aid"] = aid }
        let data = try await http.api(api + "/x/player/pagelist", query: q)
        return data.arrayValue.map(VideoPart.init(json:))
    }

    /// `/x/web-interface/view/detail/tag` → tag names.
    static func tags(aid: Int64 = 0, bvid: String, cid: Int64 = 0) async throws -> [String] {
        var q: [String: Any] = [:]
        if !bvid.isEmpty { q["bvid"] = bvid } else { q["aid"] = aid }
        if cid > 0 { q["cid"] = cid }
        let data = try await http.api(api + "/x/web-interface/view/detail/tag", query: q)
        return parseTags(data)
    }

    static func parseTags(_ data: JSON) -> [String] {
        data.arrayValue.map { $0["tag_name"].stringValue }.filter { !$0.isEmpty }
    }

    // MARK: - UGC playurl

    /// UGC playurl (`/x/player/wbi/playurl`, DASH fnval 4048).
    ///
    /// `preferHigher == true` (default) requests the top code (129) so the server returns every tier
    /// the account may play, then makes one extra request for the highest tier the server skipped
    /// (see spec §3.2). `qn` is used verbatim when `preferHigher` is false. Pick the stream on the
    /// client from `videos` (sorted by qn descending).
    static func playInfo(aid: Int64, bvid: String, cid: Int64, qn: Int, preferHigher: Bool = true) async throws -> PlayInfo {
        let requestQn = preferHigher ? max(qn, topQualityCode) : qn
        let fetch: (Int) async throws -> PlayInfo = { q in
            try await ugcPlayURL(aid: aid, bvid: bvid, cid: cid, qn: q)
        }
        var info: PlayInfo
        do { info = try await fetch(requestQn) } catch { throw mapError(error) }
        if preferHigher { info = await supplementMissingQuality(info, fetch: fetch) }
        guard info.isDash || !info.durl.isEmpty else { throw BiliError.other("视频资源不存在") }
        return info
    }

    /// Progressive MP4 (`fnval=1`, html5 platform: one file, ≤ 1080P) — the player's last resort, which AVPlayer
    /// plays straight from the CDN when the local proxy cannot serve it.
    static func progressivePlayInfo(aid: Int64, bvid: String, cid: Int64, qn: Int) async throws -> PlayInfo {
        var q: [String: Any] = ["cid": cid, "qn": min(qn, 80), "fnval": 1, "fnver": 0, "platform": "html5",
                                "high_quality": 1]
        if !bvid.isEmpty { q["bvid"] = bvid }
        if aid > 0 { q["avid"] = aid }
        if !http.isLoggedIn { q["try_look"] = 1 }
        let info: PlayInfo
        do {
            let data = try await http.api(api + "/x/player/wbi/playurl",
                                          query: BiliRisk.merged(q, BiliRisk.playurlParams()), sign: .wbi)
            info = parsePlayInfo(data)
        } catch {
            throw mapError(error)
        }
        guard !info.durl.isEmpty else { throw BiliError.other("视频资源不存在") }
        return info
    }

    static func ugcPlayQuery(aid: Int64, bvid: String, cid: Int64, qn: Int, epId: Int64 = 0, seasonId: Int64 = 0,
                             loggedIn: Bool) -> [String: Any] {
        var q: [String: Any] = ["cid": cid, "qn": qn, "fnval": dashFnval, "fnver": 0, "fourk": 1]
        if !bvid.isEmpty { q["bvid"] = bvid }
        if aid > 0 { q["avid"] = aid }
        if epId > 0 { q["ep_id"] = epId }
        if seasonId > 0 { q["season_id"] = seasonId }
        if !loggedIn { q["try_look"] = 1 }
        return BiliRisk.merged(q, BiliRisk.playurlParams())
    }

    private static func ugcPlayURL(aid: Int64, bvid: String, cid: Int64, qn: Int, epId: Int64 = 0, seasonId: Int64 = 0) async throws -> PlayInfo {
        let q = ugcPlayQuery(aid: aid, bvid: bvid, cid: cid, qn: qn, epId: epId, seasonId: seasonId, loggedIn: http.isLoggedIn)
        let data = try await http.api(api + "/x/player/wbi/playurl", query: q, sign: .wbi)
        return parsePlayInfo(data)
    }

    /// Makes one more request for the highest tier missing below the top returned stream and merges it.
    static func supplementMissingQuality(_ info: PlayInfo, fetch: (Int) async throws -> PlayInfo) async -> PlayInfo {
        guard let missing = missingQualityBelowHighest(info), let extra = try? await fetch(missing) else { return info }
        var merged = info
        merged.videos = mergeVideoStreams(info.videos, extra.videos)
        return merged
    }

    /// Highest `support_formats` qn below the best returned stream that has no stream of its own.
    static func missingQualityBelowHighest(_ info: PlayInfo) -> Int? {
        guard let highest = info.videos.map(\.id).max() else { return nil }
        let present = Set(info.videos.map(\.id))
        return info.qualities.map(\.qn).filter { $0 < highest && !present.contains($0) }.max()
    }

    /// Dedupe by (qn, codecid) — first occurrence wins — and sort by qn descending.
    static func mergeVideoStreams(_ a: [DashStream], _ b: [DashStream]) -> [DashStream] {
        var seen = Set<String>()
        var out: [DashStream] = []
        for s in a + b where seen.insert("\(s.id)/\(s.codecId)/\(s.codecFamily)").inserted { out.append(s) }
        return sortVideoStreams(out)
    }

    // MARK: Playurl parsing

    /// Parses a PlayUrl object (`data` for UGC, `data.video_info` / `result` for PGC).
    static func parsePlayInfo(_ data: JSON) -> PlayInfo {
        var info = PlayInfo()
        let acceptQuality = data["accept_quality"].arrayValue.compactMap { $0.int }
        let acceptDesc = data["accept_description"].arrayValue.map { $0.stringValue }
        info.acceptDescriptions = acceptDesc
        info.isTrial = acceptDesc.contains { $0.contains("试看") }
        info.qualities = parseQualities(support: data["support_formats"].arrayValue,
                                        acceptQuality: acceptQuality, acceptDesc: acceptDesc)
        let dash = data["dash"]
        if dash.exists {
            info.videos = sortVideoStreams(listOrSingle(dash["video"]).compactMap { parseDashStream($0, kind: .video) })
            info.audios = sortAudioStreams(listOrSingle(dash["audio"]).compactMap { parseDashStream($0, kind: .audio) })
            info.dolbyAudios = sortAudioStreams(listOrSingle(dash[path: "dolby.audio"]).compactMap { parseDashStream($0, kind: .audio) })
            info.flacAudios = sortAudioStreams(listOrSingle(dash[path: "flac.audio"]).compactMap { parseDashStream($0, kind: .audio) })
            info.duration = dash["duration"].doubleValue
        }
        info.durl = data["durl"].arrayValue.enumerated().compactMap { parseDurl($1, index: $0) }
        if info.duration <= 0 { info.duration = data["timelength"].doubleValue / 1000 }
        if info.duration <= 0, !info.durl.isEmpty {
            info.duration = Double(info.durl.reduce(0) { $0 + $1.lengthMs }) / 1000
        }
        info.quality = data["quality"].int ?? info.videos.first?.id ?? 0
        if info.qualities.isEmpty {
            var seen = Set<Int>()
            info.qualities = info.videos.compactMap { v in
                seen.insert(v.id).inserted ? QualityOption(qn: v.id, title: VideoQuality.title(for: v.id)) : nil
            }
            if info.qualities.isEmpty, info.quality > 0 {
                info.qualities = [QualityOption(qn: info.quality, title: VideoQuality.title(for: info.quality))]
            }
        }
        let lastMs = data["last_play_time"].doubleValue
        info.lastPlayTime = lastMs > 0 ? lastMs / 1000 : 0
        info.lastPlayCid = data["last_play_cid"].int64Value
        info.isDRM = data["is_drm"].boolValue
        info.isPreview = data["is_preview"].boolValue
        info.clips = data["clip_info_list"].arrayValue.compactMap { c in
            let start = c["start"].doubleValue, end = c["end"].doubleValue
            guard end > start else { return nil }
            return PGCClipInfo(start: start, end: end, rawType: c["clipType"].string ?? c["clip_type"].stringValue)
        }
        return info
    }

    static func parseQualities(support: [JSON], acceptQuality: [Int], acceptDesc: [String]) -> [QualityOption] {
        var out: [QualityOption] = []
        var seen = Set<Int>()
        for f in support {
            let qn = f["quality"].intValue
            guard qn > 0, seen.insert(qn).inserted else { continue }
            var title = f["new_description"].stringValue
            if title.isEmpty { title = f["display_desc"].stringValue }
            if title.isEmpty, let i = acceptQuality.firstIndex(of: qn), i < acceptDesc.count { title = acceptDesc[i] }
            if title.isEmpty { title = VideoQuality.title(for: qn) }
            out.append(QualityOption(qn: qn, title: title,
                                     codecs: f["codecs"].arrayValue.compactMap { $0.string },
                                     needLogin: f["need_login"].boolValue,
                                     needVip: f["need_vip"].boolValue))
        }
        if out.isEmpty {
            for (i, qn) in acceptQuality.enumerated() where qn > 0 && seen.insert(qn).inserted {
                let desc = i < acceptDesc.count ? acceptDesc[i] : ""
                out.append(QualityOption(qn: qn, title: desc.isEmpty ? VideoQuality.title(for: qn) : desc))
            }
        }
        return out.sorted { $0.qn > $1.qn }
    }

    /// One DASH representation; accepts camelCase, snake_case and `SegmentBase` key variants.
    static func parseDashStream(_ j: JSON, kind: MediaKind) -> DashStream? {
        let url = firstString(j, ["baseUrl", "base_url", "BaseURL", "url"])
        guard !url.isEmpty else { return nil }
        var s = DashStream(kind: kind, id: j["id"].intValue, baseURL: url)
        s.backupURLs = firstArray(j, ["backupUrl", "backup_url", "BackupURL"])
            .compactMap { $0.string }.filter { !$0.isEmpty && $0 != url }
        s.bandwidth = j["bandwidth"].int ?? j["bandWidth"].intValue
        s.mimeType = firstString(j, ["mimeType", "mime_type"])
        s.codecs = j["codecs"].stringValue
        s.codecId = j["codecid"].int ?? j["codec_id"].intValue
        s.width = j["width"].intValue
        s.height = j["height"].intValue
        s.frameRate = parseFrameRate(j["frameRate"].exists ? j["frameRate"] : j["frame_rate"])
        let seg = firstExisting(j, ["segment_base", "SegmentBase", "segmentBase"])
        s.initRange = firstString(seg, ["initialization", "Initialization"])
        s.indexRange = firstString(seg, ["index_range", "indexRange", "IndexRange"])
        return s
    }

    /// "30" / "29.412" / "30000/1001" / 30 → fps.
    static func parseFrameRate(_ j: JSON) -> Double {
        if case .string(let s) = j {
            let parts = s.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let n = parts[0], let d = parts[1], d != 0 { return n / d }
            return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return j.doubleValue
    }

    static func parseDurl(_ j: JSON, index: Int) -> ProgressiveSegment? {
        let url = j["url"].stringValue
        guard !url.isEmpty else { return nil }
        return ProgressiveSegment(order: j["order"].int ?? index + 1, url: url,
                                  backupURLs: firstArray(j, ["backup_url", "backupUrl"]).compactMap { $0.string }.filter { !$0.isEmpty },
                                  lengthMs: j["length"].intValue, size: j["size"].int64Value)
    }

    /// Sorted by qn descending, server order kept within a qn.
    static func sortVideoStreams(_ s: [DashStream]) -> [DashStream] {
        s.enumerated().sorted { a, b in
            a.element.id != b.element.id ? a.element.id > b.element.id : a.offset < b.offset
        }.map(\.element)
    }

    /// PiliPlus-style audio rank: Hi-Res 60, Dolby 50, 192K 40, 132K 30, 64K 20.
    static func audioRank(_ id: Int) -> Int {
        switch id {
        case 30251: return 60
        case 30250, 30255: return 50
        case 30280: return 40
        case 30232: return 30
        case 30216: return 20
        default: return 0
        }
    }

    static func sortAudioStreams(_ s: [DashStream]) -> [DashStream] {
        s.sorted { a, b in
            let ra = audioRank(a.id), rb = audioRank(b.id)
            return ra != rb ? ra > rb : a.bandwidth > b.bandwidth
        }
    }

    private static func listOrSingle(_ j: JSON) -> [JSON] {
        if let a = j.array { return a }
        if j.object != nil { return [j] }
        return []
    }

    private static func firstString(_ j: JSON, _ keys: [String]) -> String {
        for k in keys { if let s = j[k].string, !s.isEmpty { return s } }
        return ""
    }

    private static func firstArray(_ j: JSON, _ keys: [String]) -> [JSON] {
        for k in keys { if let a = j[k].array { return a } }
        return []
    }

    private static func firstExisting(_ j: JSON, _ keys: [String]) -> JSON {
        for k in keys where j[k].exists { return j[k] }
        return .null
    }

    // MARK: - PGC playurl

    /// PGC (bangumi / movie …) playurl.
    ///
    /// Logged out: UGC endpoint with `ep_id`/`season_id` + `try_look` (needs `aid` or `bvid`), then
    /// `POST /ogv/player/playview`, then `GET /pgc/player/web/playurl`. Logged in: playview first.
    /// A region lock anywhere becomes "该番剧在当前地区不可播放" (code -10403). Check `isDRM` (do not play)
    /// and `isPreview` (trial clip only) on the result.
    static func pgcPlayInfo(epId: Int64, cid: Int64, qn: Int, aid: Int64 = 0, bvid: String = "",
                            seasonId: Int64 = 0, preferHigher: Bool = true) async throws -> PlayInfo {
        let requestQn = preferHigher ? max(qn, topQualityCode) : qn
        let ugc: (Int) async throws -> PlayInfo = { q in
            try await ugcPlayURL(aid: aid, bvid: bvid, cid: cid, qn: q, epId: epId, seasonId: seasonId)
        }
        let playview: (Int) async throws -> PlayInfo = { q in try await pgcPlayView(epId: epId, seasonId: seasonId, qn: q) }
        let legacy: (Int) async throws -> PlayInfo = { q in try await pgcLegacyPlayURL(epId: epId, cid: cid, qn: q) }
        let hasArchiveId = aid > 0 || !bvid.isEmpty
        var attempts: [(Int) async throws -> PlayInfo] = []
        if http.isLoggedIn {
            attempts = [playview, legacy]
            if hasArchiveId { attempts.append(ugc) }
        } else {
            if hasArchiveId { attempts.append(ugc) }
            attempts += [playview, legacy]
        }
        var errors: [Error] = []
        for attempt in attempts {
            do {
                var info = try await attempt(requestQn)
                guard info.isDash || !info.durl.isEmpty else { throw BiliError.other("该剧集暂无可播放的资源") }
                if preferHigher { info = await supplementMissingQuality(info, fetch: attempt) }
                return info
            } catch BiliError.cancelled {
                throw BiliError.cancelled
            } catch {
                errors.append(error)
            }
        }
        throw preferredPGCError(errors)
    }

    /// Region lock > business error with a message > anything else.
    static func preferredPGCError(_ errors: [Error]) -> Error {
        if errors.contains(where: isRegionLocked) {
            return BiliError.api(code: -10403, message: "该番剧在当前地区不可播放")
        }
        let business = errors.first { e in
            guard let b = e as? BiliError, case .api(let code, _) = b else { return false }
            return ![-352, -412, -403, -400].contains(code)
        }
        return mapError(business ?? errors.first ?? BiliError.other("该剧集暂时无法播放"), context: .pgc)
    }

    private static func pgcPlayView(epId: Int64, seasonId: Int64, qn: Int) async throws -> PlayInfo {
        var query: [String: String] = [
            "x-bili-locale-json": #"{"c_locale":{"language":"zh-Hans"},"always_translate":false}"#,
            "x-bili-device-req-json": #"{"platform":"web","device":"pc","spmid":"666.25","mobi_app":"web_cn"}"#,
        ]
        if let csrf = http.csrf { query["csrf"] = csrf }
        let videoIndex: [String: Any] = [
            "bvid": NSNull(),
            "cid": NSNull(),
            "ogv_season_id": seasonId > 0 ? NSNumber(value: seasonId) as Any : NSNull() as Any,
            "ogv_episode_id": NSNumber(value: epId),
        ]
        let videoParam: [String: Any] = ["qn": qn]
        let playerParam: [String: Any] = ["fnver": 0, "fnval": dashFnval, "drm_tech_type": 0, "app_id": 100]
        let body: [String: Any] = [
            "scene": "normal",
            "video_index": videoIndex,
            "video_param": videoParam,
            "player_param": playerParam,
        ]
        let root = try await postJSON(api + "/ogv/player/playview", query: query, body: body, signWbi: true,
                                      referer: "https://www.bilibili.com/bangumi/play/ep\(epId)")
        return try parsePGCPlayView(try BiliHTTP.unwrap(root))
    }

    /// `/ogv/player/playview` → `data`. Throws the `not_playable_reason` when there is no video.
    static func parsePGCPlayView(_ data: JSON) throws -> PlayInfo {
        let vi = data["video_info"]
        guard vi.exists, vi["dash"].exists || !vi["durl"].arrayValue.isEmpty else {
            let reason = data["not_playable_reason"]
            let code = reason["code"].intValue
            let msg = reason["message"].string ?? reason["msg"].stringValue
            throw BiliError.api(code: code != 0 ? code : -404, message: msg.isEmpty ? "该剧集暂时无法播放" : msg)
        }
        var info = parsePlayInfo(vi)
        let wp = data["watch_progress"]
        let raw = wp["current_watch_progress"].double ?? wp["current_progress"].doubleValue
        if raw > 0 { info.lastPlayTime = normalizeProgress(raw, duration: info.duration) }
        if data["is_drm"].boolValue { info.isDRM = true }
        if data["is_preview"].boolValue { info.isPreview = true }
        return info
    }

    /// `watch_progress` unit is unverified (PiliPlus treats it as ms): values larger than the
    /// duration in seconds are taken as ms.
    static func normalizeProgress(_ raw: Double, duration: Double) -> Double {
        if duration > 0 { return raw > duration + 5 ? raw / 1000 : raw }
        return raw / 1000
    }

    private static func pgcLegacyPlayURL(epId: Int64, cid: Int64, qn: Int) async throws -> PlayInfo {
        var q: [String: Any] = ["ep_id": epId, "qn": qn, "fnval": dashFnval, "fnver": 0, "fourk": 1,
                                "from_client": "BROWSER", "drm_tech_type": 0]
        if cid > 0 { q["cid"] = cid }
        let result = try await http.api(api + "/pgc/player/web/playurl", query: q,
                                        headers: ["Referer": "https://www.bilibili.com/bangumi/play/ep\(epId)"])
        return parsePGCLegacyResult(result)
    }

    /// `/pgc/player/web/playurl` → `result` (or the v2 shape `result.video_info`).
    static func parsePGCLegacyResult(_ result: JSON) -> PlayInfo {
        var info = result["video_info"].exists ? parsePlayInfo(result["video_info"]) : parsePlayInfo(result)
        if result["is_drm"].boolValue { info.isDRM = true }
        if result["is_preview"].boolValue { info.isPreview = true }
        return info
    }

    /// JSON-body POST (BiliHTTP only encodes forms). WBI signs the query; retried once on -352/-403.
    static func postJSON(_ url: String, query: [String: String], body: [String: Any], signWbi: Bool,
                         referer: String = "https://www.bilibili.com/") async throws -> JSON {
        var root = try await postJSONOnce(url, query: query, body: body, signWbi: signWbi, referer: referer)
        if signWbi, [-352, -403].contains(root["code"].intValue) {
            await http.wbi.invalidate()
            root = try await postJSONOnce(url, query: query, body: body, signWbi: signWbi, referer: referer)
        }
        return root
    }

    private static func postJSONOnce(_ url: String, query: [String: String], body: [String: Any], signWbi: Bool,
                                     referer: String) async throws -> JSON {
        let params = signWbi ? try await http.wbi.sign(query) : query
        guard var comps = URLComponents(string: url) else { throw BiliError.invalidURL(url) }
        if !params.isEmpty { comps.percentEncodedQuery = BiliHTTP.encodeQuery(params, sorted: true) }
        guard let finalURL = comps.url else { throw BiliError.invalidURL(url) }
        var req = URLRequest(url: finalURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(BiliHost.www, forHTTPHeaderField: "Origin")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            let (d, resp) = try await http.session.data(for: req)
            guard let h = resp as? HTTPURLResponse else { throw BiliError.other("非 HTTP 响应") }
            guard (200..<300).contains(h.statusCode) else { throw BiliError.http(status: h.statusCode) }
            data = d
        } catch let e as URLError where e.code == .cancelled {
            throw BiliError.cancelled
        } catch is CancellationError {
            throw BiliError.cancelled
        }
        do { return try JSON(data: data) } catch {
            throw BiliError.decoding(String(data: data.prefix(200), encoding: .utf8) ?? "non-utf8")
        }
    }

    // MARK: - Player side data (subtitles, chapters, resume)

    /// `/x/player/wbi/v2` (WBI). Subtitles are usually empty for anonymous users.
    static func playerExtra(aid: Int64, cid: Int64, bvid: String = "", epId: Int64 = 0, seasonId: Int64 = 0) async throws -> PlayerExtraInfo {
        var q: [String: Any] = ["cid": cid]
        if aid > 0 { q["aid"] = aid }
        if !bvid.isEmpty { q["bvid"] = bvid }
        if epId > 0 { q["ep_id"] = epId }
        if seasonId > 0 { q["season_id"] = seasonId }
        let data = try await http.api(api + "/x/player/wbi/v2", query: q, sign: .wbi)
        return parsePlayerExtra(data)
    }

    static func parsePlayerExtra(_ data: JSON) -> PlayerExtraInfo {
        var info = PlayerExtraInfo()
        let tracks = data[path: "subtitle.subtitles"].arrayValue.enumerated().compactMap { parseSubtitleTrack($1, index: $0) }
        info.subtitles = sortSubtitles(tracks)
        let points = data["view_points"].arrayValue
        // SmartSkip reads them raw (same mapping as `SmartSkipDataLoader.parsePlayerInfo`).
        info.viewPoints = points.map { p in
            VideoChapter(from: p["from"].double ?? .nan, to: p["to"].double ?? .nan, title: p["content"].stringValue)
        }
        if points.first?["type"].intValue == 2 {
            info.chapters = points.compactMap { p in
                let from = p["from"].doubleValue, to = p["to"].doubleValue
                guard to >= from else { return nil }
                return VideoChapter(from: from, to: to, title: p["content"].stringValue)
            }
        }
        let lastMs = data["last_play_time"].doubleValue
        info.lastPlayTime = lastMs > 0 ? lastMs / 1000 : 0
        info.lastPlayCid = data["last_play_cid"].int64Value
        info.needLoginSubtitle = data["need_login_subtitle"].boolValue
        if let n = data["online_count"].int, n > 0 { info.onlineHint = "\(n)人在看" }
        info.steinGraphVersion = data[path: "interaction.graph_version"].int64Value
        if data["is_ugc_pay_preview"].boolValue {
            let t = data["preview_toast"].stringValue
            info.previewToast = t.isEmpty ? "试看中，充电后可观看完整视频" : t
        }
        return info
    }

    static func parseSubtitleTrack(_ j: JSON, index: Int = 0) -> SubtitleTrack? {
        var url = j["subtitle_url"].stringValue
        if url.isEmpty { url = j["subtitle_url_v2"].stringValue }
        guard !url.isEmpty else { return nil }
        let lan = j["lan"].stringValue
        let isAI = lan.hasPrefix("ai-") || j["type"].intValue == 1
        var doc = j["lan_doc"].stringValue
        if doc.isEmpty { doc = lan }
        if isAI, !doc.uppercased().contains("AI") { doc += "（AI）" }
        let id = j["id"].int64 ?? Int64(j["id_str"].stringValue) ?? Int64(index + 1)
        return SubtitleTrack(id: id, lan: lan, lanDoc: doc, url: normalizedSubtitleURL(url), isAI: isAI)
    }

    /// `//aisubtitle.hdslb.com/…` → `https://aisubtitle.hdslb.com/…`.
    static func normalizedSubtitleURL(_ url: String) -> String {
        let u = url.trimmingCharacters(in: .whitespaces)
        if u.hasPrefix("//") { return "https:" + u }
        if u.hasPrefix("http://") { return "https://" + u.dropFirst(7) }
        if !u.hasPrefix("https://"), !u.isEmpty { return "https://" + u }
        return u
    }

    /// Chinese first, then human-made before AI; otherwise server order.
    static func sortSubtitles(_ tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        tracks.enumerated().sorted { a, b in
            let ka = (a.element.lan.lowercased().contains("zh") ? 0 : 1, a.element.isAI ? 1 : 0, a.offset)
            let kb = (b.element.lan.lowercased().contains("zh") ? 0 : 1, b.element.isAI ? 1 : 0, b.offset)
            return ka < kb
        }.map(\.element)
    }

    /// Downloads a subtitle JSON body (`body[]{from,to,content}`). No cookies reach hdslb.com.
    static func subtitleLines(url: String) async throws -> [SubtitleLine] {
        let root = try await http.json(normalizedSubtitleURL(url))
        return parseSubtitleBody(root)
    }

    static func parseSubtitleBody(_ root: JSON) -> [SubtitleLine] {
        root["body"].arrayValue.compactMap { l -> SubtitleLine? in
            let content = l["content"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let from = l["from"].doubleValue
            return SubtitleLine(from: from, to: max(from, l["to"].doubleValue), content: content)
        }.sorted { $0.from < $1.from }
    }

    // MARK: - Related / relation

    /// `/x/web-interface/archive/related` → cards.
    static func related(aid: Int64, bvid: String) async throws -> [VideoCard] {
        var q: [String: Any] = [:]
        if !bvid.isEmpty { q["bvid"] = bvid } else { q["aid"] = aid }
        let data = try await http.api(api + "/x/web-interface/archive/related", query: q)
        return parseRelated(data)
    }

    static func parseRelated(_ data: JSON) -> [VideoCard] {
        data.arrayValue.compactMap(VideoDetailCardMapper.archive)
    }

    /// `/x/web-interface/archive/relation`. Returns an empty state when logged out.
    static func relation(aid: Int64, bvid: String) async throws -> VideoRelation {
        guard http.isLoggedIn else { return VideoRelation() }
        var q: [String: Any] = [:]
        if aid > 0 { q["aid"] = aid }
        if !bvid.isEmpty { q["bvid"] = bvid }
        let data = try await http.api(api + "/x/web-interface/archive/relation", query: q)
        return VideoRelation(json: data)
    }

    // MARK: - Like / coin / triple (web cookie endpoints)

    /// `/x/web-interface/archive/like` (like = 1, cancel = 2). Also works with a PGC episode's aid.
    static func like(aid: Int64, like: Bool) async throws {
        _ = try await write(api + "/x/web-interface/archive/like", form: ["aid": aid, "like": like ? 1 : 2])
    }

    /// `/x/web-interface/coin/add`. `count` is clamped to 1…2 (reposts allow 1). Returns whether it also liked.
    @discardableResult
    static func coin(aid: Int64, count: Int, alsoLike: Bool) async throws -> Bool {
        let data = try await write(api + "/x/web-interface/coin/add",
                                   form: ["aid": aid, "multiply": min(max(count, 1), 2), "select_like": alsoLike ? 1 : 0])
        return data["like"].boolValue
    }

    /// 一键三连 (`/x/web-interface/archive/like/triple`).
    static func triple(aid: Int64, bvid: String = "") async throws -> (like: Bool, coin: Bool, fav: Bool) {
        let bv = bvid.isEmpty ? BVConverter.av2bv(aid) : bvid
        let data = try await write(api + "/x/web-interface/archive/like/triple", form: [
            "aid": aid, "eab_x": 2, "ramval": 0, "source": "web_normal", "ga": 1,
            "spmid": "333.788.0.0", "statistics": #"{"appId":100,"platform":5}"#,
        ], headers: ["Referer": "https://www.bilibili.com/video/\(bv)", "Origin": BiliHost.www])
        return parseTriple(data)
    }

    static func parseTriple(_ data: JSON) -> (like: Bool, coin: Bool, fav: Bool) {
        (data["like"].boolValue, data["coin"].boolValue, data["fav"].boolValue || data["favorite"].boolValue)
    }

    // MARK: - Dislike (app endpoint)

    static let dislikeNeedsTVLoginMessage = "点踩需要 TV 扫码登录"

    /// 点踩 / 取消点踩: `POST app /x/v2/view/dislike`, app-signed with the TV QR login's `access_key` (there is
    /// no web cookie variant; without the token it throws `dislikeNeedsTVLoginMessage`). Also works with a PGC
    /// episode's aid.
    static func dislike(aid: Int64, dislike: Bool) async throws {
        guard let auth = AuthService.shared.appAuth else { throw BiliError.other(dislikeNeedsTVLoginMessage) }
        do {
            _ = try await http.api(BiliHost.app + "/x/v2/view/dislike", method: "POST",
                                   form: dislikeForm(aid: aid, dislike: dislike, auth: auth.params), sign: .app(auth.key))
        } catch {
            if AuthService.isRejectedAppToken(error), let token = auth.params["access_key"] {
                AuthService.shared.dropAppToken(ifToken: token)
                throw BiliError.other(AuthService.appTokenRejectedMessage)
            }
            throw mapError(error)
        }
    }

    /// Unsigned form of `dislike`: `dislike` 0 = 点踩, 1 = 取消.
    static func dislikeForm(aid: Int64, dislike: Bool, auth: [String: String]) -> [String: Any] {
        var form: [String: Any] = ["aid": aid, "dislike": dislike ? 0 : 1]
        for (k, v) in auth { form[k] = v }
        return form
    }

    /// PGC like/coin/favourite state of an episode (`/pgc/season/episode/community`).
    static func pgcEpisodeRelation(epId: Int64) async throws -> VideoRelation {
        guard http.isLoggedIn else { return VideoRelation() }
        let data = try await http.api(api + "/pgc/season/episode/community", query: ["ep_id": epId])
        return VideoRelation(pgcJSON: data)
    }

    /// PGC 一键三连 (`/pgc/season/episode/like/triple`).
    static func pgcTriple(epId: Int64, seasonId: Int64 = 0) async throws -> (like: Bool, coin: Bool, fav: Bool) {
        let referer = seasonId > 0 ? "https://www.bilibili.com/bangumi/play/ss\(seasonId)"
                                   : "https://www.bilibili.com/bangumi/play/ep\(epId)"
        let data = try await write(api + "/pgc/season/episode/like/triple", form: ["ep_id": epId],
                                   headers: ["Referer": referer, "Origin": BiliHost.www], context: .pgc)
        return (data["like"].boolValue, data["coin"].boolValue || data["coin_number"].intValue > 0, data["favorite"].boolValue)
    }

    // MARK: - Favourites

    /// Own folders with the membership state of `aid` (or a PGC `ep_id` with `resourceType: 24`).
    static func favFolders(forAid aid: Int64, resourceType: Int = 2) async throws -> [FavFolderState] {
        guard let mid = http.mid, http.isLoggedIn else { throw BiliError.notLoggedIn }
        let data = try await http.api(api + "/x/v3/fav/folder/created/list-all",
                                      query: ["type": resourceType, "rid": aid, "up_mid": mid])
        return parseFavFolders(data)
    }

    static func parseFavFolders(_ data: JSON) -> [FavFolderState] {
        data["list"].arrayValue.enumerated().map { FavFolderState(json: $1, index: $0) }
    }

    /// Adds to / removes from folders. Resource is `aid:2` for UGC, `ep_id:24` for PGC.
    static func updateFav(aid: Int64, add: [Int64], remove: [Int64], resourceType: Int = 2) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        let addIds = add.map { String($0) }.joined(separator: ",")
        let delIds = remove.map { String($0) }.joined(separator: ",")
        do {
            _ = try await write(api + "/x/v3/fav/resource/batch-deal", form: [
                "resources": "\(aid):\(resourceType)", "add_media_ids": addIds, "del_media_ids": delIds, "platform": "web",
            ])
        } catch let e where isEndpointFailure(e) {
            _ = try await write(api + "/x/v3/fav/resource/deal", form: [
                "rid": aid, "type": resourceType, "add_media_ids": addIds, "del_media_ids": delIds, "platform": "web",
            ])
        }
    }

    // MARK: - Watch later

    static func addToWatchLater(aid: Int64) async throws {
        _ = try await write(api + "/x/v2/history/toview/add", form: ["aid": aid])
    }

    static func removeFromWatchLater(aid: Int64) async throws {
        do {
            _ = try await write(api + "/x/v2/history/toview/v2/dels", form: ["resources": String(aid)])
        } catch let e where isEndpointFailure(e) {
            _ = try await write(api + "/x/v2/history/toview/del", form: ["aid": aid])
        }
    }

    // MARK: - Heartbeat (history)

    /// `/x/click-interface/web/heartbeat`. `playedTime` in seconds, -1 = finished. `type` 3 UGC, 4 PGC,
    /// 10 PUGV. Silently does nothing when logged out (the server would reject it anyway).
    static func heartbeat(aid: Int64, bvid: String, cid: Int64, epId: Int64 = 0, seasonId: Int64 = 0,
                          playedTime: Int, realPlayedTime: Int = 0, type: Int = 3, subType: Int = 0,
                          startTs: Int64 = 0) async throws {
        guard http.isLoggedIn else { return }
        let form = heartbeatForm(aid: aid, bvid: bvid, cid: cid, epId: epId, seasonId: seasonId, playedTime: playedTime,
                                 realPlayedTime: realPlayedTime, type: type, subType: subType, startTs: startTs)
        _ = try await http.post(api + "/x/click-interface/web/heartbeat", form: form)
    }

    static func heartbeatForm(aid: Int64, bvid: String, cid: Int64, epId: Int64, seasonId: Int64, playedTime: Int,
                              realPlayedTime: Int, type: Int, subType: Int, startTs: Int64) -> [String: Any] {
        var f: [String: Any] = ["cid": cid, "played_time": playedTime, "type": type]
        if type == 10 || bvid.isEmpty { f["aid"] = aid } else { f["bvid"] = bvid }
        if epId > 0 { f["epid"] = epId }
        if seasonId > 0 { f["sid"] = seasonId }
        if subType > 0 { f["sub_type"] = subType }
        if realPlayedTime > 0 { f["real_played_time"] = realPlayedTime }
        if startTs > 0 { f["start_ts"] = startTs }
        return f
    }

    // MARK: - Online count / seek thumbnails

    /// `/x/player/online/total` → e.g. "1000+" (nil when unknown).
    static func onlineCount(aid: Int64, cid: Int64, bvid: String = "") async throws -> String? {
        var q: [String: Any] = ["aid": aid, "cid": cid]
        if !bvid.isEmpty { q["bvid"] = bvid }
        let data = try await http.api(api + "/x/player/online/total", query: q)
        return parseOnlineTotal(data)
    }

    static func parseOnlineTotal(_ data: JSON) -> String? {
        for key in ["total", "count"] {
            let s = data[key].stringValue
            if !s.isEmpty, s != "0" { return s }
        }
        return nil
    }

    /// `/x/player/videoshot` sprite sheets for seek previews.
    static func videoshot(aid: Int64, bvid: String, cid: Int64) async throws -> VideoShotInfo {
        var q: [String: Any] = ["cid": cid, "index": 1]
        if !bvid.isEmpty { q["bvid"] = bvid } else { q["aid"] = aid }
        let bv = bvid.isEmpty ? BVConverter.av2bv(aid) : bvid
        let data = try await http.api(api + "/x/player/videoshot", query: q,
                                      headers: ["Referer": "https://www.bilibili.com/video/\(bv)"])
        return parseVideoShot(data)
    }

    static func parseVideoShot(_ data: JSON) -> VideoShotInfo {
        var s = VideoShotInfo()
        s.images = data["image"].arrayValue.compactMap { $0.string?.biliHTTPS }.filter { !$0.isEmpty }
        s.index = data["index"].arrayValue.map { $0.doubleValue }
        s.columns = data["img_x_len"].int ?? 10
        s.rows = data["img_y_len"].int ?? 10
        s.tileWidth = data["img_x_size"].int ?? 160
        s.tileHeight = data["img_y_size"].int ?? 90
        return s
    }

    // MARK: - PGC season

    /// `/pgc/view/web/season` (`result`). Pass either id; `epId` wins when both are set.
    static func pgcSeason(seasonId: Int64?, epId: Int64?) async throws -> PGCSeason {
        var q: [String: Any] = [:]
        if let epId, epId > 0 { q["ep_id"] = epId } else if let seasonId, seasonId > 0 { q["season_id"] = seasonId } else {
            throw BiliError.other("缺少番剧 ID")
        }
        do {
            let result = try await http.api(api + "/pgc/view/web/season", query: q)
            let season = parsePGCSeason(result)
            guard season.seasonId != 0 || !season.allEpisodes.isEmpty else { throw BiliError.emptyData }
            return season
        } catch {
            throw mapError(error, context: .pgc)
        }
    }

    static func parsePGCSeason(_ result: JSON) -> PGCSeason { PGCSeason(json: result) }

    /// 追番 / 取消追番. Returns the server toast.
    @discardableResult
    static func pgcFollow(seasonId: Int64, follow: Bool) async throws -> String {
        let path = follow ? "/pgc/web/follow/add" : "/pgc/web/follow/del"
        let data = try await write(api + path, form: ["season_id": seasonId], context: .pgc)
        let toast = data["toast"].stringValue
        return toast.isEmpty ? (follow ? "追番成功" : "已取消追番") : toast
    }

    // MARK: - Helpers

    /// Cookie-authenticated form POST with `csrf`; maps business codes to readable errors.
    private static func write(_ url: String, form: [String: Any], headers: [String: String] = [:],
                              context: ErrorContext = .video) async throws -> JSON {
        do {
            if headers.isEmpty { return try await http.post(url, form: form) }
            guard let csrf = http.csrf else { throw BiliError.notLoggedIn }
            var f = form
            f["csrf"] = csrf
            return try await http.api(url, method: "POST", form: f, headers: headers)
        } catch {
            throw mapError(error, context: context)
        }
    }
}

// MARK: - Heartbeat reporter

/// What is being played, for heartbeat reports.
struct HeartbeatContext: Hashable {
    var aid: Int64
    var bvid: String
    var cid: Int64
    var epId: Int64 = 0
    var seasonId: Int64 = 0
    /// 3 = UGC, 4 = PGC, 10 = PUGV.
    var type: Int = 3
    /// PGC season type (1 番剧, 2 电影 …), 0 = omit.
    var subType: Int = 0
    /// Total length in seconds (0 if unknown); used to decide whether playback really finished.
    var duration: Double = 0

    init(aid: Int64, bvid: String, cid: Int64, epId: Int64 = 0, seasonId: Int64 = 0, type: Int = 3,
         subType: Int = 0, duration: Double = 0) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.epId = epId
        self.seasonId = seasonId
        self.type = type
        self.subType = subType
        self.duration = duration
    }

    static func ugc(aid: Int64, bvid: String, cid: Int64, duration: Double = 0) -> HeartbeatContext {
        HeartbeatContext(aid: aid, bvid: bvid, cid: cid, duration: duration)
    }

    static func pgc(episode: PGCEpisode, seasonId: Int64, seasonType: Int, duration: Double = 0) -> HeartbeatContext {
        HeartbeatContext(aid: episode.aid, bvid: episode.bvid, cid: episode.cid, epId: episode.epId, seasonId: seasonId,
                         type: 4, subType: seasonType, duration: duration > 0 ? duration : Double(episode.duration))
    }
}

struct HeartbeatPayload: Hashable {
    var context: HeartbeatContext
    /// Seconds, -1 = finished.
    var playedTime: Int
    var realPlayedTime: Int
    var startTs: Int64
}

/// Drives `/x/click-interface/web/heartbeat` from player callbacks (PiliPlus semantics):
/// - `tick(position:isPlaying:)` once per second: reports every 5 s of playback, and on a
///   play/pause change when ≥ 2 s passed since the last report;
/// - `seeked(to:)` moves the baseline without reporting;
/// - `finished()` reports -1 only when the position is within ~1 s of the end;
/// - `stop()` (leaving / switching part) reports the current position (or -1 at the end).
/// Never reports position 0, when logged out, or when 记录观看历史 (`general.reportHistory`) is off.
final class HeartbeatReporter: @unchecked Sendable {
    typealias Sender = (HeartbeatPayload) async -> Void

    private let lock = NSLock()
    private var context: HeartbeatContext?
    private var lastSent = 0
    private var lastPlaying = false
    private var lastPosition: Double = 0
    private var realPlayed: Double = 0
    private var lastTickAt: Date?
    private var startTs: Int64 = 0
    private var finishedSent = false
    private var lastReported: Int?
    private let sender: Sender
    private let isAllowed: () -> Bool
    private let now: () -> Date
    /// Called synchronously with every payload right before it is sent (tests / debugging).
    var observer: ((HeartbeatPayload) -> Void)?

    init(isAllowed: @escaping () -> Bool = HeartbeatReporter.defaultAllowed,
         now: @escaping () -> Date = { Date() },
         sender: Sender? = nil) {
        self.isAllowed = isAllowed
        self.now = now
        self.sender = sender ?? { p in
            try? await VideoAPI.heartbeat(aid: p.context.aid, bvid: p.context.bvid, cid: p.context.cid,
                                          epId: p.context.epId, seasonId: p.context.seasonId,
                                          playedTime: p.playedTime, realPlayedTime: p.realPlayedTime,
                                          type: p.context.type, subType: p.context.subType, startTs: p.startTs)
        }
    }

    static func defaultAllowed() -> Bool {
        AppSettings.shared.general.reportHistory && BiliHTTP.shared.isLoggedIn
    }

    /// AVPlayer reports NaN (item not ready) or ±∞ (indefinite time); `Int(_:)` traps on those.
    private static func finitePosition(_ p: Double?) -> Double? {
        guard let p, p.isFinite else { return nil }
        return min(max(0, p), 1e9)
    }

    /// Begins a new source. Any previous source is stopped (and reported) first.
    func start(_ context: HeartbeatContext, position: Double = 0) {
        stop()
        let position = HeartbeatReporter.finitePosition(position) ?? 0
        lock.lock()
        self.context = context
        lastSent = Int(position)
        lastPosition = position
        lastPlaying = false
        realPlayed = 0
        lastTickAt = nil
        startTs = Int64(now().timeIntervalSince1970)
        finishedSent = false
        lastReported = nil
        lock.unlock()
    }

    /// Call about once per second with the current position.
    func tick(position rawPosition: Double, isPlaying: Bool) {
        guard let position = HeartbeatReporter.finitePosition(rawPosition) else { return }
        lock.lock()
        guard context != nil else { lock.unlock(); return }
        let t = now()
        if lastPlaying, let last = lastTickAt { realPlayed += min(max(t.timeIntervalSince(last), 0), 3) }
        lastTickAt = t
        lastPosition = position
        let pos = Int(max(0, position))
        if pos < lastSent { lastSent = pos } // jumped backwards without seeked(to:)
        var report: Int?
        if isPlaying != lastPlaying {
            lastPlaying = isPlaying
            if pos - lastSent >= 2 { report = pos }
        } else if isPlaying, pos - lastSent >= 5 {
            report = pos
        }
        if isPlaying { finishedSent = false }
        let payload = report.flatMap { makePayload(playedTime: $0) }
        if let r = report, payload != nil { lastSent = r }
        lock.unlock()
        dispatch(payload)
    }

    /// A seek moves the baseline without reporting.
    func seeked(to rawPosition: Double) {
        guard let position = HeartbeatReporter.finitePosition(rawPosition) else { return }
        lock.lock()
        lastSent = Int(position)
        lastPosition = position
        lock.unlock()
    }

    /// Playback reached the end (AVPlayerItemDidPlayToEndTime).
    func finished(position: Double? = nil) {
        let position = HeartbeatReporter.finitePosition(position)
        lock.lock()
        guard let ctx = context else { lock.unlock(); return }
        let p = position ?? lastPosition
        lastPosition = p
        let ended = ctx.duration <= 0 || ctx.duration - p <= 1.5
        let payload = makePayload(playedTime: ended ? -1 : Int(p))
        if payload != nil {
            finishedSent = ended
            lastSent = Int(p)
        }
        lastPlaying = false
        lock.unlock()
        dispatch(payload)
    }

    /// Leaving the page / switching part or episode: reports the final position.
    func stop(position: Double? = nil) {
        let position = HeartbeatReporter.finitePosition(position)
        lock.lock()
        guard let ctx = context else { lock.unlock(); return }
        let p = position ?? lastPosition
        var payload: HeartbeatPayload?
        if !(finishedSent && abs(p - lastPosition) < 1) {
            let ended = ctx.duration > 0 && ctx.duration - p <= 1
            let value = ended ? -1 : Int(p)
            if value != lastReported { payload = makePayload(playedTime: value) }
        }
        context = nil
        lock.unlock()
        dispatch(payload)
    }

    /// Must be called with the lock held.
    private func makePayload(playedTime: Int) -> HeartbeatPayload? {
        guard let ctx = context, playedTime != 0, isAllowed() else { return nil }
        lastReported = playedTime
        return HeartbeatPayload(context: ctx, playedTime: playedTime, realPlayedTime: Int(realPlayed), startTs: startTs)
    }

    private func dispatch(_ payload: HeartbeatPayload?) {
        guard let payload else { return }
        observer?(payload)
        let send = sender
        Task { await send(payload) }
    }
}
