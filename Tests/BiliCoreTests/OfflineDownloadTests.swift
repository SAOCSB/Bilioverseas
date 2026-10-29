import XCTest
@testable import BiliCore

// 离线缓存: range bookkeeping, planning, manifest coding, the download job (real BTRDownloader over the in-memory
// FakeMediaClient CDN, files in a temporary directory) and the manager's queue / pause / resume / relaunch.

private let offlineHostA = "upos-sz-mirrorali.bilivideo.com"
private let offlineHostB = "upos-sz-mirrorhw.bilivideo.com"
private let KiB: Int64 = 1024
private let MiB: Int64 = 1024 * 1024

private func span(_ start: Int64, _ end: Int64) -> ByteRange { ByteRange(start: start, end: end) }

/// `.mp4` URL of the fake file; `deadline=` far in the future unless given.
private func offlineURL(_ host: String, deadline: Double = 4_000_000_000) -> String {
    "https://\(host)/upgcxcode/00/00/1/1-1-80.mp4?deadline=\(Int(deadline))&os=x"
}

private func offlineTuning() -> BTRTuning {
    var t = BTRTuning()
    t.firstByteTimeoutMs = 1500
    t.stallTimeoutMs = 1000
    t.attemptTimeoutMs = 5000
    t.hedgeDelayMs = 300
    t.roundPauseBaseMs = 20
    t.hedgePollMs = 10
    return t
}

private func offlineBTRConfig(concurrency: Int = 6) -> BTRConfig {
    var c = BTRConfig()
    c.mode = .custom
    c.customHosts = [offlineHostA, offlineHostB]
    c.autoConcurrency = false
    c.concurrency = concurrency
    return c
}

private func offlineJobConfig() -> OfflineJobConfig {
    var c = OfflineJobConfig()
    c.chunkBytes = 512 * KiB
    c.lanes = 2
    c.retryPauseMs = 10
    c.progressIntervalMs = 20
    return c
}

private func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Counts resolutions; returns the fake file's URLs.
private final class OfflineSourceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var urls: [String]
    var failing = false

    init(urls: [String] = [offlineURL(offlineHostA)]) { self.urls = urls }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func resolve() throws -> OfflineSource {
        lock.lock()
        calls += 1
        let fail = failing
        let list = urls
        lock.unlock()
        if fail { throw OfflineDownloadError.noSource }
        return OfflineSource(urls: list, quality: 80, qualityTitle: "1080P 高清")
    }
}

private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
}

final class OfflineRangeTests: XCTestCase {
    func testInsertMergesOverlappingAndAdjacentSpans() {
        var set = OfflineRangeSet()
        set.insert(span(100, 199))
        set.insert(span(300, 399))
        set.insert(span(0, 49))
        XCTAssertEqual(set.spans.map(\.start), [0, 100, 300])
        set.insert(span(200, 299)) // bridges 100-199 and 300-399 (adjacent on both sides)
        XCTAssertEqual(set.spans, [OfflineSpan(start: 0, end: 49), OfflineSpan(start: 100, end: 399)])
        set.insert(span(40, 120))
        XCTAssertEqual(set.spans, [OfflineSpan(start: 0, end: 399)])
        set.insert(span(10, 20))
        XCTAssertEqual(set.byteCount, 400)
        set.insert(ByteRange(start: 5, end: 4)) // inverted: ignored
        XCTAssertEqual(set.spans.count, 1)
    }

    func testMissingRangesAndCoverage() {
        let set = OfflineRangeSet([span(0, 99), span(200, 299), span(1000, 1999)])
        XCTAssertEqual(set.missing(total: 1500), [span(100, 199), span(300, 999)])
        XCTAssertEqual(set.missing(total: 3000), [span(100, 199), span(300, 999), span(2000, 2999)])
        XCTAssertEqual(set.missing(in: span(50, 250)), [span(100, 199)])
        XCTAssertEqual(set.missing(in: span(250, 260)), [])
        XCTAssertEqual(OfflineRangeSet().missing(total: 10), [span(0, 9)])
        XCTAssertEqual(set.byteCount(within: 1500), 100 + 100 + 500)
        XCTAssertFalse(set.covers(total: 2000))
        XCTAssertTrue(OfflineRangeSet([span(0, 1999)]).covers(total: 2000))
        XCTAssertFalse(OfflineRangeSet().covers(total: 0))
        XCTAssertEqual(set.clipped(to: 250).spans, [OfflineSpan(start: 0, end: 99), OfflineSpan(start: 200, end: 249)])
        XCTAssertTrue(set.clipped(to: 0).isEmpty)
    }

    func testChunksSplitMissingRangesAndFoldShortTails() {
        let chunks = OfflineRangePlanner.chunks(missing: [span(0, 10 * MiB - 1)], chunkBytes: 4 * MiB)
        XCTAssertEqual(chunks, [span(0, 4 * MiB - 1), span(4 * MiB, 8 * MiB - 1), span(8 * MiB, 10 * MiB - 1)])
        // A tail under a quarter chunk joins the chunk before it.
        let folded = OfflineRangePlanner.chunks(missing: [span(0, 4 * MiB + 100)], chunkBytes: 4 * MiB)
        XCTAssertEqual(folded, [span(0, 4 * MiB + 100)])
        let several = OfflineRangePlanner.chunks(missing: [span(10, 19), span(100, 6 * MiB)], chunkBytes: 4 * MiB)
        XCTAssertEqual(several.first, span(10, 19))
        XCTAssertEqual(several.count, 3)
        XCTAssertEqual(several.reduce(Int64(0)) { $0 + $1.length }, 10 + (6 * MiB - 100 + 1))
        // Tiny chunk sizes are raised to the minimum.
        XCTAssertEqual(OfflineRangePlanner.chunks(missing: [span(0, 128 * KiB - 1)], chunkBytes: 1).count, 2)
    }

    func testProbeIsTheHeadOfTheFile() {
        XCTAssertEqual(OfflineRangePlanner.probeRange, span(0, 64 * KiB - 1))
    }
}

final class OfflineModelTests: XCTestCase {
    func testTaskIdentityAndDisplay() {
        XCTAssertEqual(OfflineTask.makeID(aid: 1, bvid: "BV1xx411c7mD", cid: 99), "BV1xx411c7mD_99")
        XCTAssertEqual(OfflineTask.makeID(aid: 170001, bvid: "", cid: 5), "av170001_5")
        XCTAssertEqual(OfflineTask.makeID(aid: 1, bvid: "../BV1", cid: 2), "BV1_2", "never a path")
        var task = OfflineTask(aid: 1, bvid: "BV1xx411c7mD", cid: 99, title: "标题")
        XCTAssertEqual(task.displayPart, "")
        task.partCount = 3
        task.page = 2
        XCTAssertEqual(task.displayPart, "P2")
        task.partTitle = "第二集"
        XCTAssertEqual(task.displayPart, "P2 第二集")
        task.totalBytes = 1000
        task.written = OfflineRangeSet([span(0, 249)])
        XCTAssertEqual(task.receivedBytes, 250)
        XCTAssertEqual(task.progress, 0.25, accuracy: 1e-9)
        task.state = .completed
        XCTAssertEqual(task.progress, 1)
        task.duration = 600
        task.lastPosition = 3
        XCTAssertEqual(task.resumePosition, 0)
        task.lastPosition = 120
        XCTAssertEqual(task.resumePosition, 120)
        task.lastPosition = 598
        XCTAssertEqual(task.resumePosition, 0, "the end restarts from the beginning")
        XCTAssertEqual(task.videoRef.cid, 99)
    }

    func testTaskFromTheVideoPage() {
        var detail = VideoDetail()
        detail.aid = 9
        detail.bvid = "BV1xx411c7mD"
        detail.cid = 100
        detail.title = "上下集"
        detail.cover = "https://i0.hdslb.com/bfs/archive/a.jpg"
        detail.owner = UserBrief(mid: 5, name: "UP主")
        detail.duration = 900
        var second = VideoPart(cid: 200, page: 2, part: "下集", duration: 450)
        second.width = 1080
        second.height = 1920
        detail.pages = [VideoPart(cid: 100, page: 1, part: "上集", duration: 450), second]
        let task = OfflineTask(detail: detail, part: second, quality: 64, qualityTitle: "720P 高清")
        XCTAssertEqual(task.id, "BV1xx411c7mD_200")
        XCTAssertEqual(task.cid, 200)
        XCTAssertEqual(task.displayPart, "P2 下集")
        XCTAssertEqual(task.duration, 450)
        XCTAssertTrue(task.isVertical)
        XCTAssertEqual(task.ownerName, "UP主")
        XCTAssertEqual(task.requestedQuality, 64)
        XCTAssertEqual(task.qualityTitle, "720P 高清")
        XCTAssertEqual(task.state, .waiting)
        // A single-part video without a pages list.
        detail.pages = []
        let single = OfflineTask(detail: detail, part: VideoPart(cid: 0), quality: 80)
        XCTAssertEqual(single.cid, 100)
        XCTAssertEqual(single.duration, 900)
        XCTAssertEqual(single.displayPart, "")
    }

    func testManifestRoundTrip() throws {
        var task = OfflineTask(aid: 7, bvid: "BV1ab411c7mD", cid: 8, title: "视频")
        task.state = .paused
        task.totalBytes = 5000
        task.written = OfflineRangeSet([span(0, 999), span(2000, 2999)])
        task.qualityTitle = "1080P 高清"
        task.completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        task.createdAt = Date(timeIntervalSince1970: 1_690_000_000)
        let data = try OfflineManifest.encode([task])
        let back = OfflineManifest.decode(data)
        XCTAssertEqual(back, [task])
    }

    func testManifestDecodingIsLenient() {
        let json = """
        {"version": 1, "tasks": [
          {"id": "BV1a_1", "aid": 1, "bvid": "BV1a", "cid": 1, "title": "旧版本", "state": "downloading"},
          {"aid": 2, "bvid": "BV1b", "cid": 2, "state": "teleporting", "totalBytes": 10,
           "written": {"spans": [{"start": 0, "end": 4}]}},
          {"title": "no cid: dropped"},
          {"id": "BV1a_1", "aid": 1, "bvid": "BV1a", "cid": 1, "title": "duplicate"}
        ]}
        """
        let tasks = OfflineManifest.decode(Data(json.utf8))
        XCTAssertEqual(tasks.map(\.id), ["BV1a_1", "BV1b_2"])
        XCTAssertEqual(tasks[0].title, "旧版本")
        XCTAssertEqual(tasks[0].state, .downloading)
        XCTAssertEqual(tasks[0].requestedQuality, 80)
        XCTAssertEqual(tasks[1].state, .waiting, "an unknown state waits")
        XCTAssertEqual(tasks[1].receivedBytes, 5)
        XCTAssertEqual(OfflineManifest.decode(Data("not json".utf8)), [])
    }

    func testProgressiveSourceNeedsOneSegment() throws {
        var info = PlayInfo()
        info.quality = 64
        info.qualities = [QualityOption(qn: 80, title: "1080P 高清"), QualityOption(qn: 64, title: "720P 高清")]
        info.durl = [ProgressiveSegment(order: 1, url: "http://cn-hk.bilivideo.com/a.mp4?x=1",
                                        backupURLs: ["https://upos-sz-mirrorcos.bilivideo.com/a.mp4?x=1",
                                                     "https://cn-hk.bilivideo.com/a.mp4?x=1"],
                                        lengthMs: 1000, size: 123)]
        let source = try OfflineProgressiveSource.source(from: info)
        XCTAssertEqual(source.urls, ["https://cn-hk.bilivideo.com/a.mp4?x=1",
                                     "https://upos-sz-mirrorcos.bilivideo.com/a.mp4?x=1"])
        XCTAssertEqual(source.quality, 64)
        XCTAssertEqual(source.qualityTitle, "720P 高清")
        info.durl.append(ProgressiveSegment(order: 2, url: "https://cn-hk.bilivideo.com/b.mp4"))
        XCTAssertThrowsError(try OfflineProgressiveSource.source(from: info)) {
            XCTAssertEqual($0 as? OfflineDownloadError, .noSource)
        }
        XCTAssertThrowsError(try OfflineProgressiveSource.source(from: PlayInfo()))
    }

    func testCacheQualitiesAreCappedAt1080P() {
        var info = PlayInfo()
        info.qualities = [120, 116, 80, 64, 32].map { QualityOption(qn: $0, title: "\($0)") }
        XCTAssertEqual(OfflineProgressiveSource.cacheQualities(from: info).map(\.qn), [80, 64, 32])
        XCTAssertEqual(OfflineProgressiveSource.cacheQualities(from: PlayInfo()).map(\.qn), [80, 64, 32, 16])
        let options = [80, 64, 32].map { QualityOption(qn: $0, title: "") }
        XCTAssertEqual(OfflineProgressiveSource.defaultQuality(options, preferred: 116), 80)
        XCTAssertEqual(OfflineProgressiveSource.defaultQuality(options, preferred: 74), 64)
        XCTAssertEqual(OfflineProgressiveSource.defaultQuality(options, preferred: 16), 32)
    }

    func testBTRConfigUsesFixedThreads() {
        var settings = AccelerationSettings()
        settings.cdnMode = .overseas
        settings.autoConcurrency = true
        var config = OfflineDownloadManager.btrConfig(settings)
        XCTAssertFalse(config.autoConcurrency)
        XCTAssertEqual(config.concurrency, OfflineJobConfig.defaultThreads)
        XCTAssertEqual(config.mode, .overseas)
        settings.autoConcurrency = false
        settings.manualConcurrency = 128
        config = OfflineDownloadManager.btrConfig(settings)
        XCTAssertEqual(config.concurrency, 64)
    }

    func testWriterMapsOutOfSpace() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 28)
        XCTAssertEqual(OfflineFileWriter.mapped(posix), .diskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(OfflineFileWriter.mapped(wrapped), .diskFull)
        if case .writeFailed = OfflineFileWriter.mapped(NSError(domain: NSCocoaErrorDomain, code: 512)) {} else {
            XCTFail("other errors are write failures")
        }
    }
}

final class OfflineJobTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = makeTempRoot()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeJob(_ client: FakeMediaClient, written: OfflineRangeSet = OfflineRangeSet(), total: Int64 = 0,
                         source: OfflineSourceCounter = OfflineSourceCounter(), config: OfflineJobConfig = offlineJobConfig(),
                         wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 }) -> OfflineDownloadJob {
        let downloader = BTRDownloader(config: { offlineBTRConfig() }, client: client, auto: nil, tuning: offlineTuning(),
                                       bans: BTRBanRegistry())
        return OfflineDownloadJob(taskID: "BV1test_1", fileURL: root.appendingPathComponent("video.mp4.part"),
                                  written: written, total: total, config: config, downloader: downloader,
                                  wallClock: wallClock, resolve: { try source.resolve() })
    }

    private var fileBytes: Data { (try? Data(contentsOf: root.appendingPathComponent("video.mp4.part"))) ?? Data() }

    func testDownloadsTheWholeFileOverSeveralConnections() async throws {
        let client = FakeMediaClient(total: 3 * MiB + 12345)
        var reported: OfflineSource?
        let outcome = await makeJob(client).run(onSource: { reported = $0 })
        guard case .completed(let p) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(p.total, client.total)
        XCTAssertTrue(p.written.covers(total: client.total))
        XCTAssertEqual(fileBytes, btrPattern(0, Int(client.total)))
        XCTAssertEqual(reported?.qualityTitle, "1080P 高清")
        XCTAssertEqual(Set(client.requests.map(\.host)), [offlineHostA, offlineHostB], "spread over the CDN nodes")
        XCTAssertGreaterThan(client.peakInFlight, 1, "parallel range requests")
    }

    func testResumesFromTheBytesOnDisk() async throws {
        let client = FakeMediaClient(total: 2 * MiB)
        // A previous run left 0..<700 KiB and 1.2 MiB..<1.5 MiB on disk.
        let first = span(0, 700 * KiB - 1), second = span(1200 * KiB, 1500 * KiB - 1)
        let file = root.appendingPathComponent("video.mp4.part")
        var partial = Data(count: Int(second.end + 1))
        partial.replaceSubrange(Int(first.start)...Int(first.end), with: btrPattern(first.start, Int(first.length)))
        partial.replaceSubrange(Int(second.start)...Int(second.end), with: btrPattern(second.start, Int(second.length)))
        try partial.write(to: file)
        let outcome = await makeJob(client, written: OfflineRangeSet([first, second]), total: client.total).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(client.total)))
        // Besides the 64 KiB head probe, nothing already on disk is asked for again.
        let probe = OfflineRangePlanner.probeRange
        for request in client.requests where request.range != probe {
            XCTAssertFalse(first.contains(ByteRange(start: request.range.start, end: request.range.start)),
                           "re-requested \(request.range)")
            XCTAssertFalse(second.contains(ByteRange(start: request.range.start, end: request.range.start)),
                           "re-requested \(request.range)")
        }
        let fetched = client.requests.reduce(Int64(0)) { $0 + $1.range.length }
        XCTAssertLessThan(fetched, client.total, "only the missing bytes (plus hedges)")
    }

    func testCancelKeepsProgressAndTheNextRunFinishes() async throws {
        let client = FakeMediaClient(total: 2 * MiB)
        client.defaultBehavior = .trickle(chunk: 8 * Int(KiB), intervalMs: 5)
        let job = makeJob(client)
        let progress = OfflineProgressBox()
        let run = Task { await job.run(onProgress: { progress.set($0) }) }
        await waitUntil { (progress.value?.written.byteCount ?? 0) > 256 * KiB }
        run.cancel()
        let outcome = await run.value
        guard case .cancelled(let p) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(p.written.byteCount, 0)
        XCTAssertLessThan(p.written.byteCount, client.total)
        XCTAssertEqual(p.total, client.total)
        // What the run recorded is really on disk.
        let disk = fileBytes
        for s in p.written.spans {
            XCTAssertEqual(disk.subdata(in: Int(s.start)..<Int(s.end + 1)), btrPattern(s.start, Int(s.length)))
        }
        client.defaultBehavior = .ok
        let before = client.requests.count
        let again = await makeJob(client, written: p.written, total: p.total).run()
        guard case .completed = again else { return XCTFail("\(again)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(client.total)))
        let resumed = client.requests.dropFirst(before).filter { $0.range != OfflineRangePlanner.probeRange }
        XCTAssertTrue(resumed.allSatisfy { r in p.written.missing(in: r.range).first?.start == r.range.start },
                      "besides the head probe, the second run starts every request at a missing byte")
    }

    func testANewFileOnTheServerStartsOver() async throws {
        let client = FakeMediaClient(total: MiB)
        // 3 MiB of an older, bigger version on disk.
        let file = root.appendingPathComponent("video.mp4.part")
        try Data(repeating: 0xEE, count: Int(3 * MiB)).write(to: file)
        let stale = OfflineRangeSet([span(0, 2 * MiB - 1)])
        let outcome = await makeJob(client, written: stale, total: 3 * MiB).run()
        guard case .completed(let p) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(p.total, MiB)
        XCTAssertEqual(fileBytes, btrPattern(0, Int(MiB)), "rewritten and truncated to the new size")
    }

    func testBytesMissingFromTheFileAreFetchedAgain() async throws {
        let client = FakeMediaClient(total: MiB)
        // The manifest says everything was written, but the file is gone.
        let outcome = await makeJob(client, written: OfflineRangeSet([span(0, MiB - 1)]), total: MiB).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(MiB)))
    }

    func testRefusedURLsFailAfterRetriesAndRefresh() async throws {
        let client = FakeMediaClient(total: MiB)
        client.defaultBehavior = .status(403)
        let source = OfflineSourceCounter()
        var config = offlineJobConfig()
        config.attemptsPerChunk = 2
        let outcome = await makeJob(client, source: source, config: config).run()
        guard case .failed(let error, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(error is BTRError, "\(error)")
        XCTAssertGreaterThanOrEqual(source.count, 2, "fresh URLs were fetched before the retry")
    }

    func testExpiringURLsAreRefreshedBeforeUse() async throws {
        let client = FakeMediaClient(total: MiB)
        let now = Date().timeIntervalSince1970
        let source = OfflineSourceCounter(urls: [offlineURL(offlineHostA, deadline: now + 30)])
        let outcome = await makeJob(client, source: source).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(source.count, 2, "one refresh: the URL expires within the lead time")
    }

    func testDirectModeUsesOneConnectionToTheOriginalURLs() async throws {
        let client = FakeMediaClient(total: MiB + 77)
        var config = offlineJobConfig()
        config.accelerated = false
        let outcome = await makeJob(client, config: config).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(MiB + 77)))
        // The head probe and the chunks after it all go to the playurl URL (no swapped hosts with 加速 off).
        XCTAssertTrue(client.requests.contains { $0.range == OfflineRangePlanner.probeRange })
        XCTAssertTrue(client.requests.contains { $0.range.start > OfflineRangePlanner.probeRange.end })
        XCTAssertTrue(client.requests.allSatisfy { $0.host == offlineHostA }, "\(Set(client.requests.map(\.host)))")
    }

    /// Regression: the head probe only ever raced the swapped hosts, so custom hosts that stopped answering failed
    /// every download although the plain path to Bilibili's own URL works (the chunks already fell back).
    func testDeadSwappedHostsFallBackToThePlainPath() async throws {
        let origin = "upos-sz-mirrorcos.bilivideo.com"
        let client = FakeMediaClient(total: MiB + 5)
        client.set(offlineHostA, .status(403))
        client.set(offlineHostB, .status(403))
        let outcome = await makeJob(client, source: OfflineSourceCounter(urls: [offlineURL(origin)])).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(MiB + 5)))
        XCTAssertTrue(client.requests.contains { $0.host == origin && $0.range == OfflineRangePlanner.probeRange })
    }

    /// Regression: the fallback was per chunk, so every chunk first paid two failed accelerated attempts (up to
    /// ~25 s each against hosts that do not answer). A chunk that needed it now keeps the next ones on the plain
    /// path for `plainHoldMs`.
    func testOneFallbackKeepsTheNextChunksOnThePlainPath() async throws {
        let origin = "upos-sz-mirrorcos.bilivideo.com"
        let client = FakeMediaClient(total: 4 * MiB)
        let probe = OfflineRangePlanner.probeRange
        // The swapped hosts answer the head probe, then refuse everything else.
        client.urlRule = { url, range in url.host != origin && range != probe ? .status(403) : nil }
        var config = offlineJobConfig()
        config.chunkBytes = 256 * KiB
        let outcome = await makeJob(client, source: OfflineSourceCounter(urls: [offlineURL(origin)]),
                                    config: config).run()
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fileBytes, btrPattern(0, Int(4 * MiB)))
        let refusedChunks = Set(client.requests.filter { $0.host != origin && $0.range.start > probe.end }
            .map { ($0.range.start - probe.end - 1) / (256 * KiB) })
        XCTAssertFalse(refusedChunks.isEmpty)
        XCTAssertLessThanOrEqual(refusedChunks.count, config.lanes, "only the chunks in flight when it fell back")
    }
}

/// Last progress report (written from the job's ticker task).
private final class OfflineProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last: OfflineJobProgress?

    var value: OfflineJobProgress? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func set(_ p: OfflineJobProgress) {
        lock.lock()
        last = p
        lock.unlock()
    }
}

final class OfflineManagerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = makeTempRoot()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @MainActor
    private func makeManager(_ client: FakeMediaClient, source: OfflineSourceCounter = OfflineSourceCounter(),
                             maxActive: Int = 1) -> OfflineDownloadManager {
        var settings = AccelerationSettings()
        settings.cdnMode = .custom
        settings.customHosts = [offlineHostA, offlineHostB]
        settings.autoConcurrency = false
        settings.manualConcurrency = 6
        let deps = OfflineDownloadManager.Dependencies(
            layout: OfflineStorageLayout(root: root),
            resolveSource: { _ in try source.resolve() },
            makeDownloader: { config in
                BTRDownloader(config: config, client: client, auto: nil, tuning: offlineTuning(), bans: BTRBanRegistry())
            },
            settings: { settings },
            job: offlineJobConfig(),
            maxActiveTasks: maxActive,
            persistIntervalMs: 0)
        return OfflineDownloadManager(dependencies: deps)
    }

    private func sampleTask(cid: Int64 = 1, part: Int = 1) -> OfflineTask {
        var task = OfflineTask(aid: 170001, bvid: "BV17x411w7KC", cid: cid, title: "测试视频")
        task.page = part
        task.partCount = 2
        task.partTitle = "第\(part)P"
        task.ownerName = "UP主"
        task.duration = 300
        return task
    }

    @MainActor
    func testEnqueuedTaskCompletesAndSurvivesRelaunch() async throws {
        let client = FakeMediaClient(total: MiB + 999)
        let manager = makeManager(client)
        XCTAssertEqual(manager.enqueue([sampleTask()]), 1)
        XCTAssertEqual(manager.enqueue([sampleTask()]), 0, "the same part is not queued twice")
        await waitUntil { manager.tasks.first?.state == .completed }
        let done = try XCTUnwrap(manager.tasks.first)
        XCTAssertEqual(done.state, .completed, done.errorMessage ?? "")
        XCTAssertEqual(done.totalBytes, client.total)
        XCTAssertEqual(done.qualityTitle, "1080P 高清")
        XCTAssertNotNil(done.completedAt)
        let file = try XCTUnwrap(manager.localFileURL(for: done))
        XCTAssertEqual(file.lastPathComponent, "video.mp4")
        XCTAssertEqual(try Data(contentsOf: file), btrPattern(0, Int(client.total)))
        XCTAssertEqual(manager.usedBytes, client.total)
        XCTAssertEqual(manager.completedTasks.map(\.id), [done.id])
        manager.savePosition(done.id, seconds: 42)
        manager.flush()

        let relaunched = makeManager(client)
        XCTAssertEqual(relaunched.tasks.map(\.id), [done.id])
        XCTAssertEqual(relaunched.tasks.first?.state, .completed)
        XCTAssertEqual(relaunched.tasks.first?.lastPosition, 42)
        XCTAssertNotNil(relaunched.localFileURL(for: relaunched.tasks[0]))
    }

    @MainActor
    func testPauseKeepsBytesAndResumeFinishes() async throws {
        let client = FakeMediaClient(total: 2 * MiB)
        client.defaultBehavior = .trickle(chunk: 8 * Int(KiB), intervalMs: 5)
        let manager = makeManager(client)
        manager.enqueue([sampleTask()])
        let id = manager.tasks[0].id
        await waitUntil { (manager.task(id: id)?.receivedBytes ?? 0) > 200 * KiB }
        manager.pause(id)
        XCTAssertEqual(manager.task(id: id)?.state, .paused, manager.task(id: id)?.errorMessage ?? "")
        XCTAssertTrue(manager.isAllPaused)
        // Relaunch while paused: the bytes and the state come back from the manifest.
        await waitUntil { !manager.isActive(id) }
        manager.flush()
        let relaunched = makeManager(client)
        let restored = try XCTUnwrap(relaunched.task(id: id))
        XCTAssertEqual(restored.state, .paused)
        XCTAssertGreaterThan(restored.receivedBytes, 0)
        XCTAssertLessThan(restored.receivedBytes, client.total)
        client.defaultBehavior = .ok
        relaunched.resume(id)
        await waitUntil { relaunched.task(id: id)?.state == .completed }
        XCTAssertEqual(relaunched.task(id: id)?.state, .completed)
        let file = try XCTUnwrap(relaunched.localFileURL(for: relaunched.task(id: id)!))
        XCTAssertEqual(try Data(contentsOf: file), btrPattern(0, Int(client.total)))
    }

    @MainActor
    func testInterruptedDownloadContinuesAfterRelaunch() async throws {
        let client = FakeMediaClient(total: MiB)
        var task = sampleTask()
        task.state = .downloading
        task.totalBytes = MiB
        try OfflineManifest.encode([task]).write(to: OfflineStorageLayout(root: root).manifestURL)
        let manager = makeManager(client)
        await waitUntil { manager.tasks.first?.state == .completed }
        XCTAssertEqual(manager.tasks.first?.state, .completed)
    }

    @MainActor
    func testQueueRunsOneAtATimeAndDeleteRemovesFiles() async throws {
        let client = FakeMediaClient(total: MiB)
        client.defaultBehavior = .trickle(chunk: 32 * Int(KiB), intervalMs: 3)
        let manager = makeManager(client)
        manager.enqueue([sampleTask(cid: 1, part: 1), sampleTask(cid: 2, part: 2)])
        XCTAssertEqual(manager.tasks.map(\.state), [.downloading, .waiting])
        let first = manager.tasks[0].id, second = manager.tasks[1].id
        await waitUntil { manager.task(id: first)?.state == .completed }
        await waitUntil { manager.task(id: second)?.state == .completed }
        XCTAssertEqual(manager.tasks.map(\.state), [.completed, .completed])
        let directory = manager.dependencies.layout.directory(for: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        manager.delete([first])
        manager.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(manager.tasks.map(\.id), [second])
        XCTAssertEqual(makeManager(client).tasks.map(\.id), [second], "the deletion is persisted")
    }

    @MainActor
    func testDeletingARunningTaskAndQueueingItAgain() async throws {
        let client = FakeMediaClient(total: MiB)
        client.defaultBehavior = .trickle(chunk: 8 * Int(KiB), intervalMs: 5)
        let manager = makeManager(client)
        manager.enqueue([sampleTask()])
        let id = manager.tasks[0].id
        await waitUntil { (manager.task(id: id)?.receivedBytes ?? 0) > 64 * KiB }
        manager.delete([id])
        XCTAssertTrue(manager.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.dependencies.layout.directory(for: id).path))
        XCTAssertEqual(manager.enqueue([sampleTask()]), 1)
        XCTAssertEqual(manager.task(id: id)?.state, .waiting, "waits for the deleted run to stop")
        XCTAssertEqual(manager.task(id: id)?.receivedBytes, 0)
        client.defaultBehavior = .ok
        await waitUntil { manager.task(id: id)?.state == .completed }
        let task = try XCTUnwrap(manager.task(id: id))
        XCTAssertEqual(task.state, .completed, task.errorMessage ?? "")
        let file = try XCTUnwrap(manager.localFileURL(for: task))
        XCTAssertEqual(try Data(contentsOf: file), btrPattern(0, Int(client.total)))
    }

    @MainActor
    func testSuspendStopsAndForegroundResumes() async throws {
        let client = FakeMediaClient(total: 2 * MiB)
        client.defaultBehavior = .trickle(chunk: 8 * Int(KiB), intervalMs: 5)
        let manager = makeManager(client)
        manager.enqueue([sampleTask()])
        let id = manager.tasks[0].id
        await waitUntil { (manager.task(id: id)?.receivedBytes ?? 0) > 128 * KiB }
        manager.suspend()
        XCTAssertEqual(manager.task(id: id)?.state, .waiting, manager.task(id: id)?.errorMessage ?? "")
        await waitUntil { !manager.isActive(id) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.task(id: id)?.state, .waiting, "nothing starts in the background")
        client.defaultBehavior = .ok
        manager.resumeAfterSuspend()
        await waitUntil { manager.task(id: id)?.state == .completed }
        XCTAssertEqual(manager.task(id: id)?.state, .completed)
    }

    @MainActor
    func testFailedTaskShowsTheReasonAndRetries() async throws {
        let client = FakeMediaClient(total: MiB)
        let source = OfflineSourceCounter()
        source.failing = true
        let manager = makeManager(client, source: source)
        manager.enqueue([sampleTask()])
        let id = manager.tasks[0].id
        await waitUntil { manager.task(id: id)?.state == .failed }
        XCTAssertEqual(manager.task(id: id)?.errorMessage, "该视频暂不支持缓存")
        source.failing = false
        manager.toggle(id)
        await waitUntil { manager.task(id: id)?.state == .completed }
        XCTAssertEqual(manager.task(id: id)?.state, .completed)
        XCTAssertNil(manager.task(id: id)?.errorMessage)
    }

    @MainActor
    func testCompletedTaskWhoseFileVanishedIsMarkedFailed() async throws {
        var task = sampleTask()
        task.state = .completed
        task.totalBytes = 100
        task.written = OfflineRangeSet([span(0, 99)])
        try OfflineManifest.encode([task]).write(to: OfflineStorageLayout(root: root).manifestURL)
        let manager = makeManager(FakeMediaClient(total: 100))
        XCTAssertEqual(manager.tasks.first?.state, .failed)
        XCTAssertEqual(manager.tasks.first?.receivedBytes, 0)
        XCTAssertEqual(manager.tasks.first?.errorMessage, OfflineDownloadError.fileMissing.errorDescription)
    }
}
