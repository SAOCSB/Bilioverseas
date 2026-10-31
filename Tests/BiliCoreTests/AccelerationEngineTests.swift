import XCTest
@testable import BiliCore

final class AccelerationEngineTests: XCTestCase {
    private struct Harness {
        let engine: AccelerationEngine
        let downloader: EngineFakeDownloader
        let auto: EngineFakeAuto
        let server: EngineFakeServer
    }

    private final class WallClock: @unchecked Sendable {
        var now: Double = 1_800_000_000
    }

    private func makeHarness(files: [MediaKind: Data], settings: AccelerationSettings = AccelerationSettings(),
                             wall: WallClock = WallClock(), maxSessions: Int = 4,
                             settingsProvider: (() -> AccelerationSettings)? = nil,
                             settingsDidChange: Notification.Name? = nil) -> Harness {
        let downloader = EngineFakeDownloader(files: files)
        let auto = EngineFakeAuto()
        let server = EngineFakeServer()
        var deps = AccelerationEngine.Dependencies(
            makeServer: { _ in server },
            makePrimaryClient: { EngineFakeMediaClient(name: "h1") },
            makeFallbackClient: { EngineFakeMediaClient(name: "urlsession") },
            makeDownloader: { _, _ in downloader },
            auto: auto,
            settings: settingsProvider ?? { settings },
            settingsDidChange: settingsDidChange)
        deps.clock = EngineTestClock()
        deps.wallClock = { wall.now }
        deps.cacheBudgetBytes = 64 << 20
        deps.metadataTimeout = 5
        deps.refreshCheckInterval = 3600
        deps.maxSessions = maxSessions
        return Harness(engine: AccelerationEngine(dependencies: deps), downloader: downloader, auto: auto, server: server)
    }

    private func get(_ engine: AccelerationEngine, _ path: String, range: String? = nil,
                     method: String = "GET") async -> LocalProxyResponse {
        var headers: [String: String] = ["host": "127.0.0.1"]
        if let range { headers["range"] = range }
        return await engine.handle(ProxyHTTPRequest(method: method, target: path, headers: headers))
    }

    private func body(_ response: LocalProxyResponse) async throws -> Data {
        switch response.body {
        case .none: return Data()
        case .data(let d): return d
        case .stream(let s): return try await engineDrain(s)
        }
    }

    private func header(_ response: LocalProxyResponse, _ name: String) -> String? {
        response.headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    private func token(_ session: PlaybackSession) -> String { session.id }

    private let videoFile = EngineSyntheticMP4.make(segmentSizes: [100_000, 90_000, 80_000],
                                                    durations: [2002, 2002, 1001], timescale: 1000, seed: 3)
    private let audioFile = EngineSyntheticMP4.make(segmentSizes: [30_000, 30_000, 20_000],
                                                    durations: [2000, 2000, 1000], timescale: 1000, moovSize: 700, seed: 9)

    private func request(video: DashStream? = nil, audio: DashStream?? = nil, accelerate: Bool = true,
                         refresh: (() async throws -> (video: DashStream, audio: DashStream?))? = nil) -> PlaybackRequest {
        let v = video ?? EngineSyntheticMP4.stream(.video, file: videoFile)
        let a: DashStream? = audio ?? EngineSyntheticMP4.stream(.audio, file: audioFile, bandwidth: 319_000)
        return PlaybackRequest(routeKey: "BV1xx411c7mD:p1", video: v, audio: a, duration: 5, accelerate: accelerate,
                               allowHDR: true, refreshURLs: refresh)
    }

    func testPrepareBuildsHLSAndServesMedia() async throws {
        let h = makeHarness(files: [.video: videoFile.data, .audio: audioFile.data])
        let session = try await h.engine.prepare(request())
        let tok = token(session)
        XCTAssertEqual(tok.count, 48)
        XCTAssertTrue(tok.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(session.url.absoluteString, "http://127.0.0.1:54321/\(tok)/master.m3u8")
        XCTAssertTrue(session.isHLS)
        XCTAssertEqual(h.auto.count("newSession"), 1)

        // init + sidx as ONE meta range per track, before anything is published.
        let metaCalls = h.downloader.calls.filter { $0.rangeKind == .meta }
        XCTAssertEqual(Set(metaCalls.map { "\($0.kind)\($0.range)" }),
                       ["video0-\(videoFile.indexRange.end)", "audio0-\(audioFile.indexRange.end)"])
        XCTAssertEqual(h.downloader.calls.count, 2)

        let master = await get(h.engine, "/\(tok)/master.m3u8")
        XCTAssertEqual(master.status, 200)
        XCTAssertEqual(header(master, "Content-Type"), "application/vnd.apple.mpegurl")
        let masterText = String(decoding: try await body(master), as: UTF8.self)
        XCTAssertEqual(masterText, HLSPlaylistBuilder.masterPlaylist(
            video: request().video, videoURI: "v.m3u8", audio: request().audio, audioURI: "a.m3u8"))
        XCTAssertTrue(masterText.contains("URI=\"a.m3u8\""))

        let media = await get(h.engine, "/\(tok)/v.m3u8")
        let mediaText = String(decoding: try await body(media), as: UTF8.self)
        XCTAssertTrue(mediaText.contains("#EXT-X-MAP:URI=\"v.m4s\",BYTERANGE=\"\(videoFile.initRange.length)@0\"\n"), mediaText)
        let s1 = videoFile.segments[1]
        XCTAssertTrue(mediaText.contains("#EXTINF:2.002,\n#EXT-X-BYTERANGE:\(s1.length)@\(s1.start)\nv.m4s\n"), mediaText)
        let audioText = String(decoding: try await body(await get(h.engine, "/\(tok)/a.m3u8")), as: UTF8.self)
        XCTAssertTrue(audioText.contains("#EXT-X-MAP:URI=\"a.m4s\""))

        // A segment range → 206 with exact headers and bytes.
        let total = Int64(videoFile.data.count)
        let partial = await get(h.engine, "/\(tok)/v.m4s", range: "bytes=\(s1.start)-\(s1.end)")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(header(partial, "Content-Range"), "bytes \(s1.start)-\(s1.end)/\(total)")
        XCTAssertEqual(header(partial, "Content-Length"), "\(s1.length)")
        XCTAssertEqual(header(partial, "Content-Type"), "video/mp4")
        XCTAssertEqual(header(partial, "Accept-Ranges"), "bytes")
        let partialBytes = try await body(partial)
        XCTAssertEqual(partialBytes, videoFile.data.subdata(in: Int(s1.start)..<Int(s1.end + 1)))

        // The init range is answered from memory (no download).
        let callsBefore = h.downloader.calls.count
        let initResponse = await get(h.engine, "/\(tok)/v.m4s", range: "bytes=0-\(videoFile.initRange.end)")
        let initBytes = try await body(initResponse)
        XCTAssertEqual(initBytes, videoFile.data.prefix(Int(videoFile.initRange.end + 1)))
        XCTAssertEqual(h.downloader.calls.count, callsBefore)

        // No Range → 200 with the whole file streamed (never a redirect).
        let full = await get(h.engine, "/\(tok)/a.m4s")
        XCTAssertEqual(full.status, 200)
        XCTAssertNil(header(full, "Content-Range"))
        XCTAssertEqual(header(full, "Content-Type"), "audio/mp4")
        XCTAssertEqual(header(full, "Content-Length"), "\(audioFile.data.count)")
        let fullBytes = try await body(full)
        XCTAssertEqual(fullBytes, audioFile.data)

        let head = await get(h.engine, "/\(tok)/v.m4s", method: "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(header(head, "Content-Length"), "\(total)")
        if case .none = head.body {} else { XCTFail("HEAD has no body") }

        let unsatisfiable = await get(h.engine, "/\(tok)/v.m4s", range: "bytes=\(total)-")
        XCTAssertEqual(unsatisfiable.status, 416)
        XCTAssertEqual(header(unsatisfiable, "Content-Range"), "bytes */\(total)")
        let multi = await get(h.engine, "/\(tok)/v.m4s", range: "bytes=0-1,5-6")
        XCTAssertEqual(multi.status, 416)

        let post = await get(h.engine, "/\(tok)/v.m4s", method: "POST")
        XCTAssertEqual(post.status, 405)
        let unknownName = await get(h.engine, "/\(tok)/p.mp4")
        XCTAssertEqual(unknownName.status, 404)
        let unknownToken = await get(h.engine, "/deadbeef/master.m3u8")
        XCTAssertEqual(unknownToken.status, 404)
        let root = await get(h.engine, "/")
        XCTAssertEqual(root.status, 404)

        XCTAssertEqual(session.stats.threads, 8)
        session.close()
        let closed = await get(h.engine, "/\(tok)/master.m3u8")
        XCTAssertEqual(closed.status, 404)
        XCTAssertGreaterThanOrEqual(h.downloader.cancelAllCount, 1)
    }

    func testVideoOnlySession() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        let session = try await h.engine.prepare(request(audio: .some(nil)))
        let text = String(decoding: try await body(await get(h.engine, "/\(session.id)/master.m3u8")), as: UTF8.self)
        XCTAssertFalse(text.contains("AUDIO"))
        let response1 = await get(h.engine, "/\(session.id)/a.m3u8")
        XCTAssertEqual(response1.status, 404)
        let response2 = await get(h.engine, "/\(session.id)/a.m4s")
        XCTAssertEqual(response2.status, 404)
        session.close()
    }

    func testRejectsNonBilibiliURLs() async {
        let h = makeHarness(files: [.video: videoFile.data])
        var foreign = EngineSyntheticMP4.stream(.video, file: videoFile)
        foreign.baseURL = "https://evil.example.com/upgcxcode/v.m4s"
        foreign.backupURLs = ["http://upos-sz-mirrorali.bilivideo.com/v.m4s", "https://bilivideo.com.evil.net/v.m4s"]
        do {
            _ = try await h.engine.prepare(request(video: foreign, audio: .some(nil)))
            XCTFail("must reject")
        } catch {
            XCTAssertEqual(error as? AccelerationEngineError, .noAllowedURL)
        }
        XCTAssertTrue(h.downloader.calls.isEmpty, "no request to any host")
        XCTAssertTrue(EngineMediaURLPolicy.isAllowed("https://upos-sz-mirrorali.bilivideo.com/a/b-30280.m4s?deadline=1"))
        XCTAssertTrue(EngineMediaURLPolicy.isAllowed("https://upos-hz-mirrorakam.akamaized.net/a/b.m4s?hdnts=x"))
        XCTAssertTrue(EngineMediaURLPolicy.isAllowed("https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/a/b.mp4"))
        XCTAssertFalse(EngineMediaURLPolicy.isAllowed("https://upos-sz-mirrorali.bilivideo.com/a/b.json"))
        XCTAssertFalse(EngineMediaURLPolicy.isAllowed("https://notbilivideo.com/a/b.m4s"))
        XCTAssertEqual(EngineMediaURLPolicy.allowed(["https://a.bilivideo.com/x.m4s", "https://a.bilivideo.com/x.m4s",
                                                     "https://e.com/x.m4s"]), ["https://a.bilivideo.com/x.m4s"])
    }

    func testSeparateMetaRangesWhenNotContiguous() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        var stream = EngineSyntheticMP4.stream(.video, file: videoFile)
        stream.initRange = "0-23" // ftyp only: the moov lies between init and index
        let session = try await h.engine.prepare(request(video: stream, audio: .some(nil)))
        XCTAssertEqual(Set(h.downloader.calls.map(\.range)),
                       [ByteRange(start: 0, end: 23), videoFile.indexRange])
        let text = String(decoding: try await body(await get(h.engine, "/\(session.id)/v.m3u8")), as: UTF8.self)
        XCTAssertTrue(text.contains("BYTERANGE=\"24@0\""))
        // Bytes between the two pinned ranges are still served (as an uncached range).
        let gap = await get(h.engine, "/\(session.id)/v.m4s", range: "bytes=0-\(videoFile.indexRange.end)")
        let gapBytes = try await body(gap)
        XCTAssertEqual(gapBytes, videoFile.data.prefix(Int(videoFile.indexRange.end + 1)))
        session.close()
    }

    func testMissingSegmentBaseLocatesSidxInHead() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        var stream = EngineSyntheticMP4.stream(.video, file: videoFile)
        stream.initRange = ""
        stream.indexRange = ""
        let session = try await h.engine.prepare(request(video: stream, audio: .some(nil)))
        let total = Int64(videoFile.data.count)
        XCTAssertEqual(h.downloader.calls.map(\.range), [ByteRange(start: 0, end: 4095),
                                                        ByteRange(start: 4096, end: min(262_143, total - 1))])
        let text = String(decoding: try await body(await get(h.engine, "/\(session.id)/v.m3u8")), as: UTF8.self)
        XCTAssertTrue(text.contains("BYTERANGE=\"\(videoFile.initRange.length)@0\""), text)
        XCTAssertTrue(text.contains("\(videoFile.segments[2].length)@\(videoFile.segments[2].start)"))
        session.close()
    }

    func testMetadataFailureThrowsAndCancels() async {
        let h = makeHarness(files: [.video: videoFile.data])
        h.downloader.acceleratedFailures = 100
        h.downloader.directFailures = 100
        do {
            _ = try await h.engine.prepare(request(audio: .some(nil)))
            XCTFail("must fail")
        } catch {
            guard case .metadata = error as? AccelerationEngineError else { return XCTFail("\(error)") }
        }
        XCTAssertGreaterThanOrEqual(h.downloader.cancelAllCount, 1)
    }

    func testFirstByteFailureIsA502() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        let session = try await h.engine.prepare(request(audio: .some(nil)))
        h.downloader.acceleratedFailures = 100
        h.downloader.directFailures = 100
        let s0 = videoFile.segments[0]
        let response = await get(h.engine, "/\(session.id)/v.m4s", range: "bytes=\(s0.start)-\(s0.end)")
        XCTAssertEqual(response.status, 502)
        XCTAssertEqual(header(response, "Content-Length"), "0")
        session.close()
    }

    func testAccelerationOffStillServesThroughProxy() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        let session = try await h.engine.prepare(request(audio: .some(nil), accelerate: false))
        XCTAssertEqual(h.auto.count("newSession"), 0)
        let s2 = videoFile.segments[2]
        let bytes = try await body(await get(h.engine, "/\(session.id)/v.m4s", range: "bytes=\(s2.start)-\(s2.end)"))
        XCTAssertEqual(bytes, videoFile.data.subdata(in: Int(s2.start)..<Int(s2.end + 1)))
        XCTAssertTrue(h.downloader.calls.allSatisfy(\.direct))
        XCTAssertFalse(session.stats.accelerated)
        session.update(time: 0, rate: 1, playing: true, bufferedAhead: 1, cacheFull: false)
        session.playerDidStall()
        XCTAssertEqual(h.auto.count("buffer"), 0)
        XCTAssertEqual(h.auto.count("stall"), 0)
        session.close()
    }

    func testProgressiveSession() async throws {
        let file = EngineSyntheticMP4.pattern(count: 5_000_000, seed: 7)
        let h = makeHarness(files: [.video: file])
        let segment = ProgressiveSegment(order: 1, url: "https://upos-sz-mirrorali.bilivideo.com/x/1-1-16.mp4?deadline=9",
                                         backupURLs: [], lengthMs: 60_000, size: Int64(file.count))
        let session = try await h.engine.prepareProgressive(routeKey: "av1:p1", segment: segment, accelerate: true)
        XCTAssertFalse(session.isHLS)
        XCTAssertTrue(session.url.absoluteString.hasSuffix("/\(session.id)/p.mp4"))
        XCTAssertEqual(h.downloader.calls.first?.range, ByteRange(start: 0, end: 65535))
        let probe = await get(h.engine, "/\(session.id)/p.mp4", range: "bytes=0-1")
        XCTAssertEqual(probe.status, 206)
        XCTAssertEqual(header(probe, "Content-Range"), "bytes 0-1/\(file.count)")
        let probeBytes = try await body(probe)
        XCTAssertEqual(probeBytes, file.prefix(2))
        let tail = await get(h.engine, "/\(session.id)/p.mp4", range: "bytes=3000000-")
        let tailBytes = try await body(tail)
        XCTAssertEqual(tailBytes, file.subdata(in: 3_000_000..<file.count))
        let response3 = await get(h.engine, "/\(session.id)/master.m3u8")
        XCTAssertEqual(response3.status, 404)
        session.close()

        let units = AccelerationEngine.progressiveUnits(total: 5_000_000, from: 65536, duration: 60)
        XCTAssertEqual(units.first?.byteRange.start, 65536)
        XCTAssertEqual(units.last?.byteRange.end, 4_999_999)
        XCTAssertEqual(units.last?.endTime ?? 0, 60, accuracy: 1e-6)

        let flv = ProgressiveSegment(order: 1, url: "https://upos-sz-mirrorali.bilivideo.com/x/1.flv")
        do {
            _ = try await h.engine.prepareProgressive(routeKey: "av1:p1", segment: flv, accelerate: true)
            XCTFail("FLV is not playable by AVPlayer")
        } catch {
            XCTAssertEqual(error as? AccelerationEngineError, .unsupportedFormat("FLV"))
        }
    }

    func testURLRefreshPolicy() {
        XCTAssertEqual(URLRefreshPolicy.deadline(of: "https://a.bilivideo.com/x.m4s?e=1&deadline=1700000000&os=x"), 1_700_000_000)
        XCTAssertNil(URLRefreshPolicy.deadline(of: "https://a.akamaized.net/x.m4s?hdnts=exp=1"))
        XCTAssertEqual(URLRefreshPolicy.backoffMs(failures: 0), 45_000)
        XCTAssertEqual(URLRefreshPolicy.backoffMs(failures: 1), 90_000)
        XCTAssertEqual(URLRefreshPolicy.backoffMs(failures: 2), 180_000)
        XCTAssertEqual(URLRefreshPolicy.backoffMs(failures: 3), 300_000)
        XCTAssertEqual(URLRefreshPolicy.backoffMs(failures: 9), 300_000)
        XCTAssertFalse(URLRefreshPolicy.isDue(nowSeconds: 1000, deadline: 1121, urgent: false, nowMs: 0, lastAttemptMs: nil, failures: 0))
        XCTAssertTrue(URLRefreshPolicy.isDue(nowSeconds: 1000, deadline: 1120, urgent: false, nowMs: 0, lastAttemptMs: nil, failures: 0))
        XCTAssertFalse(URLRefreshPolicy.isDue(nowSeconds: 1000, deadline: 1000, urgent: true, nowMs: 50_000,
                                              lastAttemptMs: 10_000, failures: 0))
        XCTAssertTrue(URLRefreshPolicy.isDue(nowSeconds: 1000, deadline: nil, urgent: true, nowMs: 60_000,
                                             lastAttemptMs: 10_000, failures: 0))
        XCTAssertFalse(URLRefreshPolicy.isDue(nowSeconds: 1000, deadline: nil, urgent: false, nowMs: 0, lastAttemptMs: nil, failures: 0))
    }

    func testExpiryRefreshSwapsURLsInPlaceWithBackoff() async throws {
        let wall = WallClock()
        let h = makeHarness(files: [.video: videoFile.data], wall: wall)
        let soon = Int(wall.now) + 60
        let later = Int(wall.now) + 7200
        final class Counter: @unchecked Sendable { var calls = 0; var deadline = 0 }
        let counter = Counter()
        counter.deadline = later
        let video = EngineSyntheticMP4.stream(.video, file: videoFile, deadline: soon)
        let fileRef = videoFile
        let session = try await h.engine.prepare(request(video: video, audio: .some(nil), refresh: {
            counter.calls += 1
            return (video: EngineSyntheticMP4.stream(.video, file: fileRef, host: "upos-sz-mirrorhw.bilivideo.com",
                                                     deadline: counter.deadline), audio: nil)
        }))
        XCTAssertEqual(session.urlDeadline, Double(soon))
        await session.refreshIfDue()
        XCTAssertEqual(counter.calls, 1)
        let track = try XCTUnwrap(h.downloader.madeTracks.first { $0.kind == .video })
        XCTAssertEqual(track.updateCount, 1)
        XCTAssertTrue(track.urls.first?.contains("mirrorhw") ?? false)
        XCTAssertTrue(track.urls.first?.contains("deadline=\(later)") ?? false)
        XCTAssertEqual(session.urlDeadline, Double(later))
        // Not due any more.
        await session.refreshIfDue()
        XCTAssertEqual(counter.calls, 1)
        // Near the new deadline it is due again, but only after the 45 s backoff.
        wall.now = Double(later) - 100
        await session.refreshIfDue()
        XCTAssertEqual(counter.calls, 1, "45 s gap since the last attempt (monotonic clock unchanged)")
        session.close()
    }

    func testProgressiveSessionRefreshesSignedURLsOfTheSameFile() async throws {
        let wall = WallClock()
        let file = EngineSyntheticMP4.pattern(count: 3_000_000, seed: 11)
        let h = makeHarness(files: [.video: file], wall: wall)
        let soon = Int(wall.now) + 60
        let later = Int(wall.now) + 7200
        let path = "/upgcxcode/00/00/1/1-1-16.mp4"
        let segment = ProgressiveSegment(order: 1, url: "https://upos-sz-mirrorali.bilivideo.com\(path)?deadline=\(soon)",
                                         backupURLs: [], lengthMs: 60_000, size: Int64(file.count))
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let refresh = AccelerationEngine.progressiveRefresher(for: segment) {
            counter.calls += 1
            return [ProgressiveSegment(order: 1, url: "https://upos-sz-mirrorcos.bilivideo.com/other/2-1-16.mp4?deadline=\(later)"),
                    ProgressiveSegment(order: 1, url: "https://upos-sz-mirrorhw.bilivideo.com\(path)?deadline=\(later)",
                                       backupURLs: ["https://upos-sz-mirrorcos.bilivideo.com\(path)?deadline=\(later)"])]
        }
        let session = try await h.engine.prepareProgressive(routeKey: "av1:p1", segment: segment, accelerate: true,
                                                            refreshURLs: refresh)
        XCTAssertEqual(session.urlDeadline, Double(soon))
        await session.refreshIfDue()
        XCTAssertEqual(counter.calls, 1)
        let track = try XCTUnwrap(h.downloader.madeTracks.first { $0.kind == .video })
        XCTAssertEqual(track.updateCount, 1)
        XCTAssertEqual(track.urls.first, "https://upos-sz-mirrorhw.bilivideo.com\(path)?deadline=\(later)")
        XCTAssertEqual(session.urlDeadline, Double(later))
        session.close()
    }

    func testProgressiveRefresherMatchesByPath() async throws {
        let segment = ProgressiveSegment(order: 1, url: "https://a.bilivideo.com/x/1-1-80.mp4?deadline=1")
        let backupHit = AccelerationEngine.matchingSegment(path: "/x/1-1-80.mp4", in: [
            ProgressiveSegment(order: 1, url: "https://b.bilivideo.com/y/1-1-80.mp4?deadline=2",
                               backupURLs: ["https://c.bilivideo.com/x/1-1-80.mp4?deadline=2"]),
        ])
        XCTAssertEqual(backupHit?.url, "https://c.bilivideo.com/x/1-1-80.mp4?deadline=2")
        XCTAssertEqual(backupHit?.backupURLs, ["https://b.bilivideo.com/y/1-1-80.mp4?deadline=2"])
        let refresh = AccelerationEngine.progressiveRefresher(for: segment) {
            [ProgressiveSegment(order: 1, url: "https://a.bilivideo.com/x/1-1-64.mp4?deadline=2")]
        }
        do {
            _ = try await refresh()
            XCTFail("another quality's file must not replace the current one")
        } catch {
            XCTAssertEqual(error as? AccelerationEngineError, .noAllowedURL)
        }
    }

    func testSettingsChangeReachesEngineWithoutASession() async throws {
        final class Box: @unchecked Sendable { var value = AccelerationSettings() }
        let box = Box()
        let name = Notification.Name("AccelerationEngineTests.settings.\(UUID().uuidString)")
        let h = makeHarness(files: [.video: videoFile.data], settingsProvider: { box.value }, settingsDidChange: name)
        XCTAssertEqual(h.engine.currentSettings.cdnMode, .mainland)
        box.value.cdnMode = .overseas
        box.value.enabled = false
        XCTAssertEqual(h.engine.currentSettings.cdnMode, .mainland, "snapshot until told")
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(h.engine.currentSettings.cdnMode, .overseas)
        XCTAssertFalse(h.engine.currentSettings.enabled)
        // The next session reads the fresh snapshot: acceleration switched off → its media goes the plain path.
        let session = try await h.engine.prepare(request(audio: .some(nil)))
        XCTAssertFalse(session.store.isAccelerating)
        session.close()
    }

    func testOlderPlayurlAnswerNeverOverwritesNewerURLs() async throws {
        let wall = WallClock()
        let h = makeHarness(files: [.video: videoFile.data], wall: wall)
        let current = Int(wall.now) + 100
        let video = EngineSyntheticMP4.stream(.video, file: videoFile, deadline: current)
        let fileRef = videoFile
        let session = try await h.engine.prepare(request(video: video, audio: .some(nil), refresh: {
            (video: EngineSyntheticMP4.stream(.video, file: fileRef, deadline: current - 50), audio: nil)
        }))
        await session.refreshIfDue()
        let track = try XCTUnwrap(h.downloader.madeTracks.first { $0.kind == .video })
        XCTAssertEqual(track.updateCount, 0)
        XCTAssertEqual(session.urlDeadline, Double(current))
        session.close()
    }

    func testPlayerSignalsFeedAutoConcurrency() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        let session = try await h.engine.prepare(request(audio: .some(nil)))
        XCTAssertEqual(h.auto.count("newSession"), 1)
        h.downloader.gate = EngineAsyncGate() // keep prefetches pending: nothing gets cached
        session.update(time: 0, rate: 1, playing: true, bufferedAhead: 1, cacheFull: false)
        XCTAssertEqual(h.auto.count("buffer"), 1)
        session.playerDidStall()
        XCTAssertEqual(h.auto.count("stall"), 1)
        session.update(time: 0.25, rate: 1, playing: true, bufferedAhead: 30, cacheFull: true)
        session.playerDidStall()
        XCTAssertEqual(h.auto.count("stall"), 1, "decoder-bound wait with plenty buffered is not a network stall")
        session.playerWillSeek(to: 4, outsideBuffer: true)
        XCTAssertEqual(h.auto.count("newSession"), 2)
        session.playerWillSeek(to: 1, outsideBuffer: false)
        XCTAssertEqual(h.auto.count("newSession"), 2)
        let stats = session.stats
        XCTAssertTrue(stats.accelerated)
        XCTAssertEqual(stats.totalBytes, 1234)
        XCTAssertFalse(stats.nodes.isEmpty)
        session.close()
        session.update(time: 1, rate: 1, playing: true, bufferedAhead: 1, cacheFull: false)
        XCTAssertEqual(h.auto.count("buffer"), 2, "closed sessions ignore signals")
    }

    func testOldestSessionClosedBeyondLimit() async throws {
        let h = makeHarness(files: [.video: videoFile.data], maxSessions: 2)
        let a = try await h.engine.prepare(request(audio: .some(nil)))
        let b = try await h.engine.prepare(request(audio: .some(nil)))
        let c = try await h.engine.prepare(request(audio: .some(nil)))
        XCTAssertTrue(a.isClosed)
        XCTAssertFalse(b.isClosed)
        XCTAssertFalse(c.isClosed)
        XCTAssertNil(h.engine.session(forToken: a.id))
        XCTAssertNotEqual(b.id, c.id)
        b.close()
        c.close()
    }

    func testSessionInUseIsEvictedAfterTheOthers() async throws {
        let h = makeHarness(files: [.video: videoFile.data], maxSessions: 2)
        let a = try await h.engine.prepare(request(audio: .some(nil)))
        let b = try await h.engine.prepare(request(audio: .some(nil)))
        a.markInUse()
        let c = try await h.engine.prepare(request(audio: .some(nil)))
        XCTAssertFalse(a.isClosed)
        XCTAssertTrue(b.isClosed)
        XCTAssertFalse(c.isClosed)
        a.close()
        c.close()
    }

    func testReleasingTheSessionClosesIt() async throws {
        let h = makeHarness(files: [.video: videoFile.data])
        var session: PlaybackSession? = try await h.engine.prepare(request(audio: .some(nil)))
        let tok = session!.id
        XCTAssertNotNil(h.engine.session(forToken: tok))
        session = nil
        XCTAssertNil(h.engine.session(forToken: tok))
        let response4 = await get(h.engine, "/\(tok)/master.m3u8")
        XCTAssertEqual(response4.status, 404)
    }

    func testLifecycleHooks() {
        let h = makeHarness(files: [:])
        h.engine.startIfNeeded()
        h.engine.startIfNeeded()
        XCTAssertEqual(h.server.startCount, 2)
        h.engine.applicationWillEnterForeground()
        XCTAssertEqual(h.server.ensureCount, 1)
        h.engine.applicationDidEnterBackground()
        h.engine.applicationDidReceiveMemoryWarning()
        let old = AccelerationEngine.maxAutoThreads
        AccelerationEngine.maxAutoThreads = 64
        XCTAssertEqual(AccelerationEngine.maxAutoThreads, 64)
        AccelerationEngine.maxAutoThreads = 1000
        XCTAssertEqual(AccelerationEngine.maxAutoThreads, 128)
        AccelerationEngine.maxAutoThreads = old
    }

    func testMediaClientSwitchFallsBackAfterRepeatedTLSFailures() async throws {
        let primary = EngineFakeMediaClient(name: "h1")
        primary.error = MediaFetchError.tls("handshake")
        let fallback = EngineFakeMediaClient(name: "urlsession")
        fallback.events = [.head(status: 206, headers: [:]), .data(Data([1, 2, 3]))]
        let client = EngineMediaClientSwitch(makePrimary: { primary }, makeFallback: { fallback })
        let url = URL(string: "https://upos-sz-mirrorali.bilivideo.com/x.m4s")!
        func run() async -> Bool {
            do {
                for try await _ in client.get(url, range: ByteRange(start: 0, end: 2), highPriority: false) {}
                return true
            } catch { return false }
        }
        for _ in 0..<(EngineMediaClientSwitch.tlsFailureLimit - 1) {
            let ok = await run()
            XCTAssertFalse(ok)
        }
        XCTAssertFalse(client.isUsingFallback)
        let last = await run()
        XCTAssertFalse(last)
        XCTAssertTrue(client.isUsingFallback)
        let ok = await run()
        XCTAssertTrue(ok)
        XCTAssertEqual(fallback.getCount, 1)
        XCTAssertEqual(primary.getCount, EngineMediaClientSwitch.tlsFailureLimit)
        client.closeIdleConnections()
        XCTAssertEqual(fallback.idleCloses, 1)
    }

    func testTLSFailureCountResetsOnSuccess() async {
        let primary = EngineFakeMediaClient(name: "h1")
        let client = EngineMediaClientSwitch(makePrimary: { primary }, makeFallback: { EngineFakeMediaClient(name: "u") })
        let url = URL(string: "https://upos-sz-mirrorali.bilivideo.com/x.m4s")!
        for round in 0..<3 {
            primary.error = MediaFetchError.tls("x")
            primary.events = []
            for _ in 0..<(EngineMediaClientSwitch.tlsFailureLimit - 1) {
                do { for try await _ in client.get(url, range: ByteRange(start: 0, end: 0), highPriority: false) {} } catch {}
            }
            primary.error = nil
            primary.events = [.head(status: 206, headers: [:])]
            do { for try await _ in client.get(url, range: ByteRange(start: 0, end: 0), highPriority: false) {} } catch {}
            XCTAssertFalse(client.isUsingFallback, "round \(round)")
        }
    }
}
