import XCTest
@testable import BiliCore

private let hostA = "upos-sz-mirrorali.bilivideo.com"
private let hostB = "upos-sz-mirrorhw.bilivideo.com"
private let hostC = "upos-sz-mirrorbos.bilivideo.com"
private let hostD = "upos-sz-mirror08c.bilivideo.com"
private let KiB = 1024
private let MiB = 1024 * 1024

private func config(_ mode: CDNMode = .custom, hosts: [String] = [], concurrency: Int = 8, auto: Bool = false) -> BTRConfig {
    var c = BTRConfig()
    c.mode = mode
    c.customHosts = hosts
    c.autoConcurrency = auto
    c.concurrency = concurrency
    c.maxAutoThreads = 32
    return c
}

private func fastTuning(hedgeDelayMs: Double = 300, firstByteMs: Double = 1500) -> BTRTuning {
    var t = BTRTuning()
    t.firstByteTimeoutMs = firstByteMs
    t.stallTimeoutMs = 1000
    t.attemptTimeoutMs = 5000
    t.hedgeDelayMs = hedgeDelayMs
    t.roundPauseBaseMs = 20
    t.hedgePollMs = 10
    return t
}

private func make(_ client: FakeMediaClient, _ cfg: BTRConfig, tuning: BTRTuning = fastTuning(),
                  clock: MonotonicClock = SystemClock.shared, auto: AutoConcurrencyController? = nil) -> BTRDownloader {
    BTRDownloader(config: { cfg }, client: client, auto: auto, clock: clock, tuning: tuning, bans: BTRBanRegistry())
}

private func fetch(_ d: BTRDownloader, _ track: BTRTrackHandle, _ range: ByteRange, kind: BTRRangeKind = .ordinary,
                   priority: Int = 50, deadline: (() -> Double?)? = nil,
                   sink: BTRByteSink = BTRByteSink()) async throws -> (total: Int64, bytes: Data) {
    let total = try await d.download(range, track: track, kind: kind, priority: priority, deadline: deadline) { sink.add($0) }
    return (total, sink.bytes)
}

private func range(_ start: Int, _ length: Int) -> ByteRange {
    ByteRange(start: Int64(start), end: Int64(start + length - 1))
}

private func now() -> Double { SystemClock.shared.nowMs() }

private func waitUntil(_ timeout: Double = 2, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
}

private func sleepMs(_ ms: Double) async { try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)) }

final class BTRDownloaderTests: XCTestCase {
    func testOrdinaryRangeDeliversExactBytesAcrossNodes() async throws {
        let client = FakeMediaClient()
        let d = make(client, config(hosts: [hostA, hostB]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let r = range(1000, MiB)
        let out = try await fetch(d, track, r)
        XCTAssertEqual(out.total, client.total)
        XCTAssertEqual(track.total, client.total)
        XCTAssertEqual(out.bytes, btrPattern(1000, MiB))
        XCTAssertGreaterThan(client.count(hostA), 0)
        XCTAssertGreaterThan(client.count(hostB), 0)
        XCTAssertTrue(client.requests.allSatisfy { r.contains($0.range) }, "never asks past the range")
        XCTAssertLessThanOrEqual(client.requests.count, 10, "a steady 1 MiB range costs few requests")
        XCTAssertLessThanOrEqual(client.peakInFlight, 8, "never more connections than threads")
        let stats = d.stats
        XCTAssertGreaterThanOrEqual(stats.totalBytes, Int64(MiB))
        XCTAssertEqual(stats.threads, 8)
        XCTAssertEqual(stats.activeConnections, 0)
        XCTAssertTrue(stats.nodes.contains { $0.host == hostA && $0.state == .healthy })
    }

    func testStreamsVerifiedBytesInOrderBeforeTheRangeCompletes() async throws {
        let client = FakeMediaClient()
        client.defaultBehavior = .trickle(chunk: 8 * KiB, intervalMs: 40)
        let d = make(client, config(hosts: [hostA]), tuning: fastTuning(hedgeDelayMs: 5000))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let sink = BTRByteSink()
        let started = now()
        let out = try await fetch(d, track, range(0, 256 * KiB), sink: sink)
        let finished = now()
        XCTAssertEqual(out.bytes, btrPattern(0, 256 * KiB))
        let deliveries = sink.deliveries
        XCTAssertGreaterThan(deliveries.count, 4, "partial pieces are streamed, not whole pieces only")
        XCTAssertLessThan(deliveries[0].at - started, 150, "the first bytes reach the player at once")
        XCTAssertGreaterThan(finished - deliveries[0].at, 150, "long before the range completes")
    }

    func testRefusingNodeIsBannedOnceAnotherDeliversAndNotAskedAgain() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .status(403))
        let d = make(client, config(hosts: [hostA, hostB]))
        var bans: [(String, BTRBanKind)] = []
        let lock = NSLock()
        d.onBan = { host, kind in lock.lock(); bans.append((host, kind)); lock.unlock() }
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, MiB))
        XCTAssertEqual(out.bytes, btrPattern(0, MiB))
        XCTAssertGreaterThanOrEqual(client.count(hostA), 2)
        XCTAssertEqual(d.banList(routeKey: "bv1:p1")?.bannedHosts(), [hostA])
        lock.lock()
        XCTAssertEqual(bans.map(\.0), [hostA])
        XCTAssertEqual(bans.map(\.1), [.node])
        lock.unlock()
        XCTAssertEqual(track.nodeStatus().first { $0.host == hostA }?.state, .banned)
        let before = client.count(hostA)
        let again = try await fetch(d, track, range(2 * MiB, MiB))
        XCTAssertEqual(again.bytes, btrPattern(2 * MiB, MiB))
        XCTAssertEqual(client.count(hostA), before, "a banned node gets no new requests in this video")
        // Another track of the same route shares the ban list.
        let audio = d.makeTrack(kind: .audio, urls: [btrMediaURL(hostA, file: "1-1-30280")], routeKey: "bv1:p1")
        XCTAssertFalse(btrHosts((audio as! BTRTrack).resolver.urls()).contains(hostA))
    }

    func testInvalidResponsesAreRejectedAndNeverDelivered() async throws {
        let cases: [(String, FakeMediaClient.Behavior)] = [
            ("200 ignoring Range", .ignoreRange), ("wrong range", .wrongRange),
            ("truncated", .truncated(bytes: 1000)), ("oversized", .oversized),
        ]
        for (name, behavior) in cases {
            let client = FakeMediaClient()
            client.set(hostA, behavior)
            let d = make(client, config(hosts: [hostA, hostB]))
            let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
            let out = try await fetch(d, track, range(5000, 512 * KiB))
            XCTAssertEqual(out.bytes.count, 512 * KiB, name)
            XCTAssertEqual(out.bytes, btrPattern(5000, 512 * KiB), name)
            XCTAssertEqual(out.total, client.total, name)
            XCTAssertGreaterThan(client.count(hostA), 0, name)
        }
    }

    func testANodeReportingAnotherFileSizeIsNeverSpliced() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .otherTotal)
        let d = make(client, config(hosts: [hostB, hostA]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostB)], routeKey: "bv1:p1")
        let meta = try await fetch(d, track, range(0, 1000), kind: .meta)
        XCTAssertEqual(meta.bytes, btrPattern(0, 1000))
        XCTAssertEqual(track.total, client.total)
        let out = try await fetch(d, track, range(64 * KiB, MiB))
        XCTAssertEqual(out.total, client.total)
        XCTAssertEqual(out.bytes, btrPattern(64 * KiB, MiB))
        XCTAssertGreaterThan(client.count(hostA), 0)
    }

    func testResumesFromTheVerifiedPrefixInsteadOfDownloadingAgain() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .truncated(bytes: 96 * KiB))
        let d = make(client, config(hosts: [hostA, hostB], concurrency: 1))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let r = range(1000, 512 * KiB)
        let out = try await fetch(d, track, r)
        XCTAssertEqual(out.bytes, btrPattern(1000, 512 * KiB), "spliced bytes are positioned correctly")
        let rescue = client.requests.filter { $0.host == hostB }
        XCTAssertEqual(rescue.count, 1)
        XCTAssertEqual(rescue.first?.range, ByteRange(start: r.start + Int64(96 * KiB), end: r.end),
                       "the rescue asks only for the missing tail")
    }

    func testFirstByteTimeoutMovesToAnotherNode() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .slowHead(ms: 3000))
        let d = make(client, config(hosts: [hostA, hostB], concurrency: 1), tuning: fastTuning(hedgeDelayMs: 5000, firstByteMs: 300))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let started = now()
        let out = try await fetch(d, track, range(0, 64 * KiB))
        let elapsed = now() - started
        XCTAssertEqual(out.bytes, btrPattern(0, 64 * KiB))
        XCTAssertGreaterThanOrEqual(elapsed, 280)
        XCTAssertLessThan(elapsed, 1500)
        XCTAssertEqual(client.requests.map(\.host), [hostA, hostB])
        XCTAssertEqual(track.nodeStatus().first { $0.host == hostA }?.state, .blocked)
        XCTAssertEqual(d.banList(routeKey: "bv1:p1")?.bannedHosts(), [], "one empty reply does not ban")
    }

    func testHedgeCopyRescuesATricklingNode() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .trickle(chunk: 4 * KiB, intervalMs: 100))
        let d = make(client, config(hosts: [hostA, hostB]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let started = now()
        let out = try await fetch(d, track, range(0, 64 * KiB))
        XCTAssertEqual(out.bytes, btrPattern(0, 64 * KiB))
        XCTAssertLessThan(now() - started, 1000, "the trickle alone would take 1.6 s")
        XCTAssertEqual(client.requests.map(\.host), [hostA, hostB])
        XCTAssertGreaterThanOrEqual(d.stats.hedgedBytes, Int64(32 * KiB))
    }

    func testSevenPrimariesLeaveTheEighthSlotForAHedgeAndCancellationStopsEverything() async throws {
        let client = FakeMediaClient()
        client.defaultBehavior = .hang
        let d = make(client, config(hosts: [hostA, hostB]), tuning: fastTuning(hedgeDelayMs: 300, firstByteMs: 10_000))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let task = Task { try await fetch(d, track, range(0, 8 * 64 * KiB)) }
        await sleepMs(150)
        XCTAssertEqual(client.requests.count, 7, "seven primary pieces leave one rescue slot at concurrency eight")
        await waitUntil { client.requests.count >= 8 }
        let hedgeAt = client.requests[7].at - client.requests[0].at
        XCTAssertGreaterThanOrEqual(hedgeAt, 250)
        XCTAssertLessThan(hedgeAt, 900, "a hedge uses the spare slot long before the first-byte timeout")
        await sleepMs(100)
        XCTAssertEqual(client.requests.count, 8, "only one spare slot")
        XCTAssertEqual(client.peakInFlight, 8)
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("a cancelled download must not succeed") }
        let count = client.requests.count
        await sleepMs(400)
        XCTAssertEqual(client.requests.count, count, "no request after cancellation")
        XCTAssertEqual(d.stats.activeConnections, 0, "every slot released")
        XCTAssertEqual(d.stats.queuedRequests, 0)
    }

    func testAnExpiredDeadlineAloneDoesNotFanOut() async throws {
        let client = FakeMediaClient()
        client.defaultBehavior = .hang
        let d = make(client, config(hosts: [hostA, hostB]), tuning: fastTuning(hedgeDelayMs: 900, firstByteMs: 10_000))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let entry = now()
        let task = Task { try await fetch(d, track, range(0, 8 * 64 * KiB), deadline: { entry }) }
        await sleepMs(80)
        XCTAssertEqual(client.requests.count, 7)
        await sleepMs(320)
        XCTAssertEqual(client.requests.count, 7, "a deadline alone does not duplicate any piece before it proves slow")
        task.cancel()
        _ = await task.result
    }

    func testOnTimePieceGetsNoCopyALateOneDoes() async throws {
        func run(_ deadline: Double?) async throws -> [String] {
            let client = FakeMediaClient()
            client.set(hostA, .trickle(chunk: 8 * KiB, intervalMs: 100)) // 64 KiB in ~700 ms
            let d = make(client, config(hosts: [hostA, hostB]))
            let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
            let start = now()
            let fn: (() -> Double?)? = deadline.map { ms in { start + ms } }
            let out = try await fetch(d, track, range(0, 64 * KiB), deadline: fn)
            XCTAssertEqual(out.bytes, btrPattern(0, 64 * KiB))
            return client.requests.map(\.host)
        }
        let far = try await run(20_000)
        XCTAssertEqual(far, [hostA], "due in 20 s and arriving in ~0.7 s: no copy")
        let near = try await run(300)
        XCTAssertEqual(near, [hostA, hostB], "due in 0.3 s: the copy starts")
        let none = try await run(nil)
        XCTAssertEqual(none, [hostA, hostB], "no deadline: the copy starts after the usual delay")
    }

    func testMetaRaceStaggersCandidates() async throws {
        let client = FakeMediaClient()
        let d = make(client, config(hosts: [hostA, hostB, hostC]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, 3012), kind: .meta)
        XCTAssertEqual(out.bytes, btrPattern(0, 3012))
        await sleepMs(400)
        XCTAssertEqual(client.requests.count, 1, "an instant answer stops the staggered candidates before they ask")

        let slow = FakeMediaClient()
        slow.set(hostA, .slowHead(ms: 1000))
        let d2 = make(slow, config(hosts: [hostA, hostB, hostC]))
        let track2 = d2.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let started = now()
        let out2 = try await fetch(d2, track2, range(0, 3012), kind: .meta)
        XCTAssertEqual(out2.bytes, btrPattern(0, 3012))
        XCTAssertLessThan(now() - started, 600)
        XCTAssertEqual(slow.requests.map(\.host), [hostA, hostB])
        let gap = slow.requests[1].at - slow.requests[0].at
        XCTAssertGreaterThanOrEqual(gap, 100, "the second candidate waits 120 ms")
    }

    func testMetaAcceptsAFileShorterThanTheRangeButMediaDoesNot() async throws {
        let client = FakeMediaClient(total: 50_000)
        let d = make(client, config(hosts: [hostA, hostB]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let meta = try await fetch(d, track, range(0, 65536), kind: .meta)
        XCTAssertEqual(meta.total, 50_000)
        XCTAssertEqual(meta.bytes, btrPattern(0, 50_000))
        do {
            _ = try await fetch(d, track, range(40_000, 30_000))
            XCTFail("a media range past the end is not clipped")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testStartupProbesTheHeadThenUsesProvenNodes() async throws {
        let client = FakeMediaClient()
        client.headDelayMs = 5
        let d = make(client, config(hosts: [hostA, hostB, hostC, hostD]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, MiB), kind: .startup)
        XCTAssertEqual(out.bytes, btrPattern(0, MiB))
        let heads = client.requests.filter { $0.range == ByteRange(start: 0, end: Int64(64 * KiB - 1)) }
        XCTAssertGreaterThanOrEqual(heads.count, 1)
        XCTAssertLessThanOrEqual(heads.count, 4, "the probe races at most every candidate once")
        XCTAssertTrue(client.requests.filter { $0.range.start == 0 }.allSatisfy { $0.range.end == Int64(64 * KiB - 1) })
        XCTAssertTrue(client.requests.filter { $0.range.start > 0 }.allSatisfy { $0.range.start >= Int64(64 * KiB) })
    }

    func testSilentNodeIsBannedAndAPartialNodeIsNot() async throws {
        let clock = BTRManualClock()
        let dead = hostB, partial = hostC
        let client = FakeMediaClient(total: Int64(64 * MiB))
        client.set(dead, .status(503))
        client.set(partial, .truncated(bytes: 1024))
        let d = make(client, config(.mainland), clock: clock)
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        for round in 0..<6 {
            let out = try await fetch(d, track, range(round * 2 * MiB, MiB))
            XCTAssertEqual(out.bytes, btrPattern(Int64(round * 2 * MiB), MiB))
            clock.advance(61_000)
        }
        let bans = d.banList(routeKey: "bv1:p1")!
        XCTAssertEqual(bans.bannedHosts(), [dead])
        XCTAssertGreaterThanOrEqual(client.count(dead), 2, "banned only after two empty replies")
        XCTAssertGreaterThanOrEqual(client.count(partial), 1, "the partial node was tried")
        XCTAssertTrue(bans.allows(btrMediaURL(partial)), "a node that sent data is not banned")
        let before = client.count(dead)
        for round in 0..<3 {
            _ = try await fetch(d, track, range((10 + round) * 2 * MiB, MiB))
            clock.advance(61_000)
        }
        XCTAssertEqual(client.count(dead), before, "a banned node gets no new requests in this video")
    }

    func testSingleAddressSurvivesTwoFailedReplies() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .failFirst(count: 2, status: 503))
        let d = make(client, config(.original))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, 32 * KiB))
        XCTAssertEqual(out.bytes, btrPattern(0, 32 * KiB))
        XCTAssertEqual(client.requests.count, 3)
    }

    func testRelayOnlyTrackDownloadsFromTheRelays() async throws {
        let relayHost = "xy1x2x3x4xy.mcdn.bilivideo.cn", edgeHost = "ccf958o.edge.mountaintoys.cn"
        let file = "/upgcxcode/00/00/1/1-1-30080.m4s"
        let relay = "https://\(relayHost):8082/v1/resource\(file)?e=1&os=mcdn&upsig=r"
        let edge = "https://\(edgeHost):4483/v1/resource\(file)?e=1&os=mcdn&upsig=e"
        let client = FakeMediaClient()
        client.set(relayHost, .status(502))
        let d = make(client, config(.mainland))
        let track = d.makeTrack(kind: .audio, urls: [relay, edge], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, MiB))
        XCTAssertEqual(out.bytes, btrPattern(0, MiB))
        XCTAssertTrue(client.requests.allSatisfy { $0.host == relayHost || $0.host == edgeHost },
                      "no relay address was asked of an ordinary node")
    }

    func testAkamaiOnlyVideoDropsTheRefusedAddressNotTheNodes() async throws {
        let akamai = "upos-hz-mirrorakam.akamaized.net"
        let url = { (os: String) in "https://\(akamai)/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&os=\(os)" }
        let client = FakeMediaClient()
        let asked = NSLock()
        var cosovbv = 0
        client.urlRule = { u, _ in
            guard u.absoluteString.contains("os=cosovbv") else { return nil }
            asked.lock(); cosovbv += 1; asked.unlock()
            return .status(403)
        }
        let d = make(client, config(.mainland))
        let track = d.makeTrack(kind: .video, urls: [url("cosovbv"), url("akam")], routeKey: "bv1:p1")
        let meta = try await fetch(d, track, range(0, 1000), kind: .meta)
        XCTAssertEqual(meta.bytes, btrPattern(0, 1000))
        let out = try await fetch(d, track, range(1000, MiB))
        XCTAssertEqual(out.bytes, btrPattern(1000, MiB))
        let bans = d.banList(routeKey: "bv1:p1")!
        XCTAssertFalse(bans.allowsAddress(url("cosovbv")))
        XCTAssertEqual(bans.bannedHosts(), [], "no node is banned for the refused address")
        asked.lock(); let before = cosovbv; asked.unlock()
        _ = try await fetch(d, track, range(3 * MiB, MiB))
        asked.lock(); XCTAssertEqual(cosovbv, before, "the refused address gets no new requests"); asked.unlock()
        XCTAssertTrue(track.nodeStatus().allSatisfy { $0.state != .banned })
    }

    func testDirectDownloadResumesOnTheNextURLWithStrictValidation() async throws {
        let client = FakeMediaClient()
        client.set(hostA, .truncated(bytes: 100_000))
        let d = make(client, config(.mainland))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA), btrMediaURL(hostB)], routeKey: "bv1:p1")
        let sink = BTRByteSink()
        let total = try await d.downloadDirect(range(0, 300_000), track: track) { sink.add($0) }
        XCTAssertEqual(total, client.total)
        XCTAssertEqual(sink.bytes, btrPattern(0, 300_000))
        XCTAssertEqual(client.requests.map(\.host), [hostA, hostB])
        XCTAssertEqual(client.requests[1].range, ByteRange(start: 100_000, end: 299_999))

        let strict = FakeMediaClient()
        strict.set(hostC, .ignoreRange)
        let d2 = make(strict, config(.mainland))
        let track2 = d2.makeTrack(kind: .video, urls: [btrMediaURL(hostC)], routeKey: "bv1:p1")
        let sink2 = BTRByteSink()
        do {
            _ = try await d2.downloadDirect(range(1000, 2000), track: track2) { sink2.add($0) }
            XCTFail("a 200 answer is not a range")
        } catch {
            XCTAssertEqual(error as? BTRError, .rangeRejected(status: 200))
        }
        XCTAssertEqual(sink2.bytes.count, 0, "nothing unverified was delivered")
    }

    func testCancelAllAbortsAndRefusesNewDownloads() async throws {
        let client = FakeMediaClient()
        client.defaultBehavior = .hang
        let d = make(client, config(hosts: [hostA, hostB]), tuning: fastTuning(hedgeDelayMs: 300, firstByteMs: 10_000))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        let task = Task { try await fetch(d, track, range(0, MiB)) }
        await waitUntil { client.requests.count >= 7 }
        d.cancelAll()
        let result = await task.result
        if case .success = result { XCTFail("cancelled") }
        let count = client.requests.count
        do {
            _ = try await fetch(d, track, range(0, 1000), kind: .meta)
            XCTFail("a closed downloader refuses new work")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await sleepMs(400)
        XCTAssertEqual(client.requests.count, count, "no request after cancelAll")
        XCTAssertEqual(d.stats.activeConnections, 0)
    }

    func testPlayerSideFailureEndsTheDownload() async throws {
        struct Gone: Error {}
        let client = FakeMediaClient()
        client.defaultBehavior = .trickle(chunk: 8 * KiB, intervalMs: 30)
        let d = make(client, config(hosts: [hostA, hostB]))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        do {
            _ = try await d.download(range(0, MiB), track: track, kind: .ordinary, priority: 50, deadline: nil) { _ in throw Gone() }
            XCTFail("onBytes failure must end the download")
        } catch {
            XCTAssertTrue(error is Gone)
        }
        let count = client.requests.count
        await sleepMs(300)
        XCTAssertEqual(client.requests.count, count)
        XCTAssertEqual(d.stats.activeConnections, 0)
    }

    func testAutoConcurrencyDrivesTheSlotLimitAndPushbackStepsBack() async throws {
        let clock = BTRManualClock()
        let auto = AutoConcurrencyController(clock: clock)
        let client = FakeMediaClient()
        let d = make(client, config(.original, auto: true), auto: auto)
        XCTAssertEqual(d.stats.threads, 8)
        XCTAssertTrue(auto.signalStall())
        XCTAssertEqual(d.stats.threads, 12, "the slot limit follows the controller at once")
        client.set(hostA, .status(429))
        let track = d.makeTrack(kind: .audio, urls: [btrMediaURL(hostA), btrMediaURL(hostB)], routeKey: "bv1:p1")
        let out = try await fetch(d, track, range(0, 64 * KiB))
        XCTAssertEqual(out.bytes, btrPattern(0, 64 * KiB))
        XCTAssertEqual(auto.threads, 8, "412/429 steps the count back")
        XCTAssertEqual(d.stats.threads, 8)
        XCTAssertEqual(d.stats.autoReason, "服务器返回 429")
        // The device cap applies to the controller too.
        let capped = AutoConcurrencyController(clock: clock)
        var cfg = config(.original, auto: true)
        cfg.maxAutoThreads = 12
        let d2 = make(client, cfg, auto: capped)
        clock.advance(5000)
        capped.stall()
        clock.advance(5000)
        capped.stall()
        XCTAssertEqual(capped.threads, 12)
        XCTAssertEqual(d2.stats.threads, 12)
    }

    func testURLRefreshAppliesAtOnce() async throws {
        let client = FakeMediaClient()
        let d = make(client, config(.original))
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        _ = try await fetch(d, track, range(0, 1000), kind: .meta)
        track.updateURLs(["https://\(hostB)/upgcxcode/00/00/1/1-1-30080.m4s?deadline=2&os=x"])
        _ = try await fetch(d, track, range(1000, 1000), kind: .meta)
        XCTAssertEqual(client.requests.map(\.host), [hostA, hostB])
        XCTAssertTrue(client.requests[1].url.contains("deadline=2"))
    }
    func testHedgeDueTruthTable() {
        let clock = BTRManualClock(1000)
        func downloader() -> BTRDownloader {
            BTRDownloader(config: { config() }, client: FakeMediaClient(), auto: nil, clock: clock, tuning: fastTuning(),
                          bans: BTRBanRegistry())
        }
        func context() -> BTRAttemptContext { BTRAttemptContext(startedAt: clock.nowMs(), length: 64 * KiB, base: 0) }
        /// 8 KiB every 100 ms for `steps` steps, checking hedgeDue after each (as the 50 ms poll would).
        func steady(_ d: BTRDownloader, _ c: BTRAttemptContext, steps: Int, chunk: Int = 8 * KiB) {
            for i in 1...steps {
                clock.advance(100)
                c.recordChunk(total: i * chunk, now: clock.nowMs())
                _ = d.hedgeDue(c, delayMs: 300, deadlineAt: .infinity, copyBps: 0, rescue: nil)
            }
        }
        let far = { clock.nowMs() + 60_000 }

        // Nothing measured yet.
        let d = downloader()
        let waiting = context()
        clock.advance(100)
        XCTAssertFalse(d.hedgeDue(waiting, delayMs: 300, deadlineAt: far(), copyBps: 0, rescue: nil), "before the delay")
        clock.advance(250)
        XCTAssertTrue(d.hedgeDue(waiting, delayMs: 300, deadlineAt: far(), copyBps: 0, rescue: nil), "no data yet")
        let stopped = context()
        steady(d, stopped, steps: 1)
        clock.advance(400)
        XCTAssertTrue(d.hedgeDue(stopped, delayMs: 300, deadlineAt: far(), copyBps: 0, rescue: nil), "stopped for a whole delay")
        let onTime = context()
        steady(d, onTime, steps: 4)
        XCTAssertFalse(d.hedgeDue(onTime, delayMs: 300, deadlineAt: far(), copyBps: 0, rescue: nil), "on time with spare")
        XCTAssertTrue(d.hedgeDue(onTime, delayMs: 300, deadlineAt: clock.nowMs() + 500, copyBps: 0, rescue: nil),
                      "close to its deadline with no usual speed known")

        // Usual connection speed measured: 64 KiB in 0.8 s = the first copy's pace.
        let m = downloader()
        m.meter.record(bytes: 64 * KiB, elapsedMs: 800)
        let pace = Double(80 * KiB)
        let paced = context()
        steady(m, paced, steps: 4)
        let soon = clock.nowMs() + 500 // finishes in ~400 ms: inside the slack, before the deadline
        XCTAssertFalse(m.hedgeDue(paced, delayMs: 300, deadlineAt: soon, copyBps: pace, rescue: nil),
                       "on pace, copy node not faster: no copy")
        XCTAssertTrue(m.hedgeDue(paced, delayMs: 300, deadlineAt: soon, copyBps: pace * 3, rescue: nil),
                      "copy node known 3× faster")
        XCTAssertTrue(m.hedgeDue(paced, delayMs: 300, deadlineAt: soon, copyBps: 0, rescue: nil), "copy node unmeasured")
        let budget = BTREarlyHedge(limit: 0)
        let late = clock.nowMs() + 300
        XCTAssertTrue(m.hedgeDue(paced, delayMs: 300, deadlineAt: late, copyBps: pace, rescue: budget),
                      "will miss its deadline: one stale-measurement copy per range")
        XCTAssertFalse(m.hedgeDue(paced, delayMs: 300, deadlineAt: late, copyBps: pace, rescue: budget), "budget spent")
        let slow = context()
        steady(m, slow, steps: 4, chunk: 2 * KiB)
        XCTAssertTrue(m.hedgeDue(slow, delayMs: 300, deadlineAt: clock.nowMs() + 500, copyBps: Double(20 * KiB), rescue: nil),
                      "well below the usual speed")
        // lemon: with both sides measured, a first copy without a byte waits 1.5× the usual time to headers.
        m.meter.recordHead(ms: 400)
        let head = context()
        clock.advance(350)
        XCTAssertFalse(m.hedgeDue(head, delayMs: 300, deadlineAt: far(), copyBps: pace, rescue: nil))
        XCTAssertTrue(m.hedgeDue(head, delayMs: 300, deadlineAt: far(), copyBps: 0, rescue: nil), "unmeasured copy node explores")
        clock.advance(300)
        XCTAssertTrue(m.hedgeDue(head, delayMs: 300, deadlineAt: far(), copyBps: pace, rescue: nil))
    }

    func testMeasuredStragglerGetsTheRescueSlotBeforeTheUsualDelay() async throws {
        let warmStart = 60 * MiB
        let client = FakeMediaClient(total: Int64(128 * MiB))
        let lock = NSLock()
        var seen: [Int64: Int] = [:]
        client.urlRule = { _, r in
            if r.start >= Int64(warmStart) { return .slowHead(ms: 600) }
            lock.lock()
            let n = (seen[r.start] ?? 0) + 1
            seen[r.start] = n
            lock.unlock()
            // First copies: 8 KiB after 300 ms, the rest after another 700 ms.
            return n == 1 ? .steps([(8 * KiB, 300), (128 * KiB, 700)]) : .ok
        }
        let d = make(client, config(.original), tuning: fastTuning(hedgeDelayMs: 900, firstByteMs: 5000))
        let warm = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        _ = try await fetch(d, warm, range(warmStart, MiB))
        XCTAssertEqual(d.meter.hedgeDelayMs(maxMs: 900), 900, "pieces took ~600 ms: the usual delay is 900 ms")
        let track = d.makeTrack(kind: .video, urls: [btrMediaURL(hostA), btrMediaURL(hostB)], routeKey: "bv1:p1")
        let began = now()
        let out = try await fetch(d, track, range(0, 8 * 64 * KiB), deadline: { began })
        XCTAssertEqual(out.bytes, btrPattern(0, 8 * 64 * KiB))
        let copies = client.requests.filter { $0.range.start < Int64(warmStart) }
        var firsts = Set<Int64>()
        let rescues = copies.filter { !firsts.insert($0.range.start).inserted }
        let first = (rescues.map(\.at).min() ?? .infinity) - began
        XCTAssertGreaterThanOrEqual(first, 250, "after the first progress report")
        XCTAssertLessThan(first, 700, "before the usual 900 ms delay")
    }

    func testBansLastAcrossSessionsOfTheSameVideoOnly() async throws {
        let registry = BTRBanRegistry()
        let client = FakeMediaClient()
        client.set(hostA, .status(503))
        let cfg = config(hosts: [hostA, hostB])
        let first = BTRDownloader(config: { cfg }, client: client, auto: nil, tuning: fastTuning(), bans: registry)
        let track = first.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1")
        _ = try await fetch(first, track, range(0, MiB))
        XCTAssertEqual(registry.banList(for: "bv1:p1").bannedHosts(), [hostA])
        first.cancelAll()
        let second = BTRDownloader(config: { cfg }, client: client, auto: nil, tuning: fastTuning(), bans: registry)
        let again = second.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv1:p1") as! BTRTrack
        XCTAssertFalse(btrHosts(again.resolver.urls()).contains(hostA), "a new session of the same video keeps its bans")
        let other = second.makeTrack(kind: .video, urls: [btrMediaURL(hostA)], routeKey: "bv2:p1") as! BTRTrack
        XCTAssertTrue(btrHosts(other.resolver.urls()).contains(hostA), "another video starts clean")
    }
}
