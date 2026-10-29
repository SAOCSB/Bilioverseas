import Foundation
import AVFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end self test used by CI in the iOS Simulator. Inactive unless the app is launched with
/// `-BiliSmokeTest` (optionally `-BiliSmokeBVID BV…`). It exercises the real Bilibili APIs, the
/// local BTR proxy (playlists + an accelerated segment download) and the real player UI, and writes
/// `Documents/smoke-report.json` (also logged with the prefix `SMOKE`).
@MainActor
enum SmokeTest {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-BiliSmokeTest")

    /// Explicit test video (`-BiliSmokeBVID`); otherwise candidates come from the popular feed, which is
    /// always playable from wherever the test runs (fixed BVs can be region-hidden and answer -404).
    static var explicitBVID: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-BiliSmokeBVID"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    /// Set by `PlayerController.load` while the smoke test runs, so the UI playback can be inspected.
    static weak var activePlayer: PlayerController?

    private static var report: [String: Any] = [:]
    private static var started = false

    static func start(router: TabRouter) {
        guard isEnabled, !started else { return }
        started = true
        Task { await run(router: router) }
    }

    // MARK: - Steps

    private static func run(router: TabRouter) async {
        record("startedAt", ISO8601DateFormatter().string(from: Date()))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        record("loggedIn", BiliHTTP.shared.isLoggedIn)
        record("buvid3", BiliHTTP.shared.cookie(named: "buvid3") != nil)

        await step("feed.recommend") {
            let page = try await FeedAPI.recommend(cursor: nil)
            let filtered = page.items.filter(FeedFilter.liveFilter(scope: .recommend))
            return ["count": page.items.count, "afterFilter": filtered.count,
                    "ads": page.items.filter { $0.kind == .ad }.count,
                    "titles": Array(filtered.prefix(3).map(\.title))]
        }
        var candidates: [String] = explicitBVID.map { [$0] } ?? []
        await step("feed.popular") {
            let page = try await FeedAPI.popular(page: 1)
            // Short-ish ordinary videos make the playback check quick and representative.
            let picks = page.items.filter { $0.kind == .video && !$0.bvid.isEmpty && $0.duration > 0 && $0.duration < 1200 }
            candidates += picks.prefix(3).map(\.bvid)
            return ["count": page.items.count, "candidates": candidates]
        }
        await step("search.hotWords") {
            let words = try await SearchAPI.hotWords()
            return ["count": words.count, "first": words.first?.showName ?? ""]
        }

        var detail: VideoDetail?
        for bvid in candidates where detail == nil {
            await step("video.detail.\(bvid)") {
                let d = try await VideoAPI.detail(VideoRef(bvid: bvid))
                detail = d
                return ["title": d.title, "aid": d.aid, "cid": d.cid, "pages": d.pages.count, "duration": d.duration]
            }
        }
        guard let detail else { finish(); return }
        record("bvid", detail.bvid)

        var info: PlayInfo?
        await step("video.playInfo") {
            let p = try await VideoAPI.playInfo(aid: detail.aid, bvid: detail.bvid, cid: detail.cid, qn: 80)
            info = p
            return ["dash": p.isDash, "videos": p.videos.map { "\($0.id)/\($0.codecFamily)" },
                    "audios": p.audios.map(\.id), "qualities": p.qualities.map(\.qn), "duration": p.duration]
        }
        await step("danmaku.segment1") {
            let reply = try await DanmakuService.fetchSegment(cid: detail.cid, aid: detail.aid, segmentIndex: 1)
            return ["count": reply.items.count, "closed": reply.isClosed]
        }
        await step("smartSkip.analyze") {
            let ctx = SmartSkipVideoContext(aid: detail.aid, bvid: detail.bvid, cid: detail.cid, page: 1,
                                            duration: Double(detail.duration), title: detail.title, desc: detail.desc)
            let segments = await SmartSkipAnalyzer.shared.analyze(ctx)
            return ["segments": segments.map { "\(Int($0.start))-\(Int($0.end)) \($0.requiresConfirmation ? "manual" : "auto")" }]
        }
        if let info, info.isDash {
            await step("engine.proxy") { try await engineCheck(info: info, detail: detail) }
        }

        // Real UI playback through the player.
        router.push(.video(VideoRef(aid: detail.aid, bvid: detail.bvid, cid: detail.cid, title: detail.title)))
        for second in [15, 30, 45] {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            recordPlayer(label: "player.t\(second)")
        }
        finish()
    }

    /// Prepares a proxy session headlessly, fetches the playlists and one accelerated media segment.
    private static func engineCheck(info: PlayInfo, detail: VideoDetail) async throws -> [String: Any] {
        guard let video = info.videos.filter({ $0.codecFamily == "avc" && $0.id <= 64 }).max(by: { $0.id < $1.id })
                ?? info.videos.last else { throw BiliError.emptyData }
        let audio = info.audios.first
        let t0 = Date()
        let session = try await AccelerationEngine.shared.prepare(PlaybackRequest(
            routeKey: "\(detail.bvid):smoke", video: video, audio: audio, duration: info.duration,
            accelerate: true, allowHDR: false))
        defer { session.close() }
        let prepareMs = Int(Date().timeIntervalSince(t0) * 1000)
        let master = try await fetchText(session.url)
        let variant = try await fetchText(session.url.deletingLastPathComponent().appendingPathComponent("v.m3u8"))
        var result: [String: Any] = [
            "prepareMs": prepareMs, "video": "\(video.id)/\(video.codecs)", "audio": audio?.id ?? 0,
            "masterLines": master.split(separator: "\n").count,
            "variantSegments": variant.components(separatedBy: "#EXTINF").count - 1,
        ]
        // Download the first two media segments through the proxy (BTR path).
        let ranges = variant.split(separator: "\n").compactMap { line -> (Int64, Int64)? in
            guard line.hasPrefix("#EXT-X-BYTERANGE:") else { return nil }
            let parts = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@")
            guard parts.count == 2, let len = Int64(parts[0]), let off = Int64(parts[1]) else { return nil }
            return (off, off + len - 1)
        }
        var bytes = 0
        let t1 = Date()
        for (start, end) in ranges.prefix(2) {
            var req = URLRequest(url: session.url.deletingLastPathComponent().appendingPathComponent("v.m4s"))
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206, Int64(data.count) == end - start + 1 else {
                throw BiliError.other("segment HTTP \(status), \(data.count) bytes for \(start)-\(end)")
            }
            bytes += data.count
        }
        let secs = max(0.001, Date().timeIntervalSince(t1))
        let stats = session.stats
        result["segmentBytes"] = bytes
        result["segmentMBps"] = Double(bytes) / secs / 1_048_576
        result["threads"] = stats.threads
        result["accelerated"] = stats.accelerated
        result["fallback"] = stats.fallbackActive
        result["nodes"] = stats.nodes.map { "\($0.host) \($0.state.rawValue) \(Int($0.bytesPerSecond / 1024))KB/s" }
        return result
    }

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw BiliError.other("playlist fetch failed: \(url.lastPathComponent)") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func recordPlayer(label: String) {
        guard let p = activePlayer else { record(label, ["error": "no active player"]); return }
        var entry: [String: Any] = [
            "status": "\(p.status)", "currentTime": p.currentTime, "duration": p.duration,
            "firstFrame": p.hasFirstFrame, "accelerated": p.isAccelerated, "progressive": p.isProgressive,
            "quality": p.currentQuality, "codec": p.currentCodecFamily,
            "danmakuEnabled": AppSettings.shared.danmaku.enabled,
        ]
        if let s = p.sessionStats {
            entry["threads"] = s.threads
            entry["MBps"] = s.bytesPerSecond / 1_048_576
            entry["cachedAhead"] = s.cachedAheadSeconds
            entry["totalMB"] = Double(s.totalBytes) / 1_048_576
            entry["hedgedMB"] = Double(s.hedgedBytes) / 1_048_576
            entry["fallback"] = s.fallbackActive
            entry["nodes"] = s.nodes.map { "\($0.host) \($0.state.rawValue)" }
        }
        record(label, entry)
    }

    // MARK: - Reporting

    private static func step(_ name: String, _ body: () async throws -> [String: Any]) async {
        let t0 = Date()
        do {
            var value = try await body()
            value["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
            value["ok"] = true
            record(name, value)
        } catch {
            record(name, ["ok": false, "error": "\(error.localizedDescription) [\(error)]",
                          "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }
    }

    private static func record(_ key: String, _ value: Any) {
        report[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            NSLog("SMOKE %@", line)
        }
        write()
    }

    private static func finish() {
        record("finishedAt", ISO8601DateFormatter().string(from: Date()))
        record("done", true)
    }

    private static func write() {
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: dir.appendingPathComponent("smoke-report.json"), options: .atomic)
    }
}
