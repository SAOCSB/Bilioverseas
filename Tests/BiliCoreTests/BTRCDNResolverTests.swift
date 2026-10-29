import XCTest
@testable import BiliCore

private let akamaiHost = "upos-hz-mirrorakam.akamaized.net"
private func akamaiURL(_ os: String) -> String { "https://\(akamaiHost)/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&os=\(os)" }
private let relayFile = "/upgcxcode/00/00/1/1-1-30080.m4s"
private let relayURL = "https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource\(relayFile)?e=1&os=mcdn&upsig=r"
private let edgeURL = "https://ccf958o.edge.mountaintoys.cn:4483/v1/resource\(relayFile)?e=1&os=mcdn&upsig=e"
private let dead = BTRError.rangeRejected(status: 503)
private let refused = BTRError.rangeRejected(status: 403)

private func osOf(_ url: String) -> String? {
    URLComponents(string: url)?.queryItems?.first { $0.name == "os" }?.value
}

final class BTRCDNTests: XCTestCase {
    func testHostLists() {
        XCTAssertEqual(BTRCDN.mainlandHosts.count, 9)
        XCTAssertEqual(BTRCDN.mainlandHosts.last, "upos-sz-mirrorcoso1.bilivideo.com")
        XCTAssertEqual(BTRCDN.overseasHosts, ["upos-sz-mirrorcosov.bilivideo.com", "upos-sz-mirroraliov.bilivideo.com",
                                              "cn-hk-eq-01-01.bilivideo.com", "cn-hk-eq-01-03.bilivideo.com"])
    }

    func testClassification() {
        XCTAssertTrue(BTRCDN.isAkamai(akamaiURL("akam")))
        XCTAssertFalse(BTRCDN.isAkamai(btrMediaURL("upos-sz-mirrorali.bilivideo.com")))
        XCTAssertTrue(BTRCDN.isRelay(relayURL))
        XCTAssertTrue(BTRCDN.isRelay(edgeURL))
        XCTAssertTrue(BTRCDN.isRelay("https://a.bilivideo.com/x.m4s?os=MCDN"))
        XCTAssertFalse(BTRCDN.isRelay(btrMediaURL("upos-sz-estgoss.bilivideo.com")))
        XCTAssertFalse(BTRCDN.isRelay(akamaiURL("akam")))
    }

    func testSwapOrdinaryHost() {
        XCTAssertNil(BTRCDN.swapOrdinaryHost(akamaiURL("akam"), to: "upos-sz-mirrorali.bilivideo.com"))
        XCTAssertNotNil(BTRCDN.swapOrdinaryHost(akamaiURL("akam"), to: "upos-sz-mirrorali.bilivideo.com", allowAkamai: true))
        XCTAssertNil(BTRCDN.swapOrdinaryHost(btrMediaURL("upos-sz-mirrorali.bilivideo.com"), to: "example.com"))
        // A peer CDN's port must not follow the address to another node (#9).
        let swapped = BTRCDN.swapOrdinaryHost("https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/a/b.m4s?e=1",
                                              to: "upos-sz-mirrorali.bilivideo.com")
        XCTAssertEqual(swapped, "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/a/b.m4s?e=1")
        // The signed query survives byte for byte.
        let signed = BTRCDN.swapOrdinaryHost("https://cn-gdfs-ct-01-01.bilivideo.com/a/b.m4s?sign=a%2Bb&x=1&deadline=9",
                                             to: "upos-sz-mirrorhw.bilivideo.com")
        XCTAssertEqual(signed, "https://upos-sz-mirrorhw.bilivideo.com/a/b.m4s?sign=a%2Bb&x=1&deadline=9")
    }

    func testAkamaiOnlyRepresentation() {
        let akamaiOnly = [akamaiURL("cosovbv"), akamaiURL("akam")]
        let mainland = BTRCDN.representationURLs(akamaiOnly, mode: .mainland)
        XCTAssertEqual(mainland.count, BTRCDN.mainlandHosts.count * 2, "two addresses on each mainland node")
        XCTAssertEqual(btrHosts(mainland).btrDeduped(), BTRCDN.mainlandHosts)
        // Node-major order: the first requests already cover both addresses.
        XCTAssertEqual(mainland.prefix(2).map(osOf), ["cosovbv", "akam"])
        let overseas = BTRCDN.representationURLs(akamaiOnly, mode: .overseas)
        XCTAssertEqual(Array(overseas.prefix(2)), akamaiOnly, "the originals stay first in overseas mode")
        XCTAssertEqual(btrHosts(overseas).btrDeduped(), [akamaiHost] + BTRCDN.overseasHosts)
    }

    func testMixedRepresentationUsesTheOrdinaryDonor() {
        let mixed = [akamaiURL("akam"), btrMediaURL("upos-sz-mirrorcosov.bilivideo.com")]
        let urls = BTRCDN.representationURLs(mixed, mode: .mainland)
        XCTAssertEqual(urls.count, BTRCDN.mainlandHosts.count)
        XCTAssertTrue(urls.allSatisfy { osOf($0) == "x" })
    }

    func testRelays() {
        let mixed = BTRCDN.representationURLs([relayURL, edgeURL, btrMediaURL("upos-sz-estgoss.bilivideo.com")], mode: .mainland)
        XCTAssertEqual(mixed.count, BTRCDN.mainlandHosts.count)
        XCTAssertTrue(mixed.allSatisfy { !BTRCDN.isRelay($0) }, "no relay address on an ordinary node")
        for mode in [CDNMode.mainland, .overseas] {
            XCTAssertEqual(BTRCDN.representationURLs([relayURL, edgeURL], mode: mode), [relayURL, edgeURL])
        }
        XCTAssertEqual(BTRCDN.representationURLs([relayURL, edgeURL], mode: .custom, customHosts: ["upos-sz-mirrorali.bilivideo.com"]),
                       [relayURL, edgeURL])
    }

    func testCustomAndOriginalModes() {
        let hosts = ["upos-sz-mirrorcos.bilivideo.com", "example.com", "UPOS-SZ-MIRRORCOS.bilivideo.com", "cn-gdfs-ct-01-01.bilivideo.com"]
        XCTAssertEqual(BTRCDN.customServers(mode: .custom, hosts: hosts),
                       ["upos-sz-mirrorcos.bilivideo.com", "cn-gdfs-ct-01-01.bilivideo.com"])
        XCTAssertEqual(BTRCDN.customServers(mode: .mainland, hosts: hosts), [])
        let ali = [btrMediaURL("upos-sz-mirrorali.bilivideo.com")]
        XCTAssertEqual(btrHosts(BTRCDN.representationURLs(ali, mode: .custom, customHosts: hosts)),
                       ["upos-sz-mirrorcos.bilivideo.com", "cn-gdfs-ct-01-01.bilivideo.com"])
        // Empty custom list behaves as mainland.
        XCTAssertEqual(btrHosts(BTRCDN.representationURLs(ali, mode: .custom, customHosts: [])), BTRCDN.mainlandHosts)
        // Original: playurl URLs untouched (deduplicated, whitelisted).
        let originals = [akamaiURL("akam"), btrMediaURL("cn-hk-eq-01-01.bilivideo.com"), akamaiURL("akam"), "http://x.bilivideo.com/a.m4s"]
        XCTAssertEqual(BTRCDN.representationURLs(originals, mode: .original), [akamaiURL("akam"), btrMediaURL("cn-hk-eq-01-01.bilivideo.com")])
        // Mainland keeps only mainland originals first; overseas drops mainland originals.
        let both = [btrMediaURL("upos-sz-mirrorhw.bilivideo.com"), btrMediaURL("cn-hk-eq-01-01.bilivideo.com")]
        let mainland = BTRCDN.representationURLs(both, mode: .mainland)
        XCTAssertEqual(mainland.first, both[0])
        XCTAssertFalse(mainland.contains(both[1]))
        let overseas = BTRCDN.representationURLs(both, mode: .overseas)
        XCTAssertEqual(overseas.first, both[1])
        XCTAssertFalse(overseas.contains(both[0]))
        XCTAssertEqual(overseas.count, 4, "cn-hk-eq-01-01 original + 4 overseas hosts, deduplicated")
    }
}

final class BTRBanListTests: XCTestCase {
    func testNodeBannedAfterTwoEmptyRepliesForTheCurrentVideoOnly() {
        var banned: [String] = []
        let bans = BTRBanList(onBan: { host, _, _ in banned.append(host) })
        let hw = btrMediaURL("upos-sz-mirrorhw.bilivideo.com")
        XCTAssertFalse(bans.record(hw, receivedBytes: 0, error: CancellationError()), "a cancelled hedge copy is not a failure")
        XCTAssertFalse(bans.record(hw, receivedBytes: 4096, error: dead), "a transfer that sent data is not a dead node")
        XCTAssertFalse(bans.record(hw, receivedBytes: 0, error: dead))
        XCTAssertTrue(bans.allows(hw))
        // A different signed URL on the same node counts toward the same node.
        XCTAssertTrue(bans.record(hw.replacingOccurrences(of: "30080", with: "30280"), receivedBytes: 0, error: dead))
        XCTAssertFalse(bans.allows(hw))
        XCTAssertEqual(banned, ["upos-sz-mirrorhw.bilivideo.com"])
        XCTAssertFalse(bans.record(hw, receivedBytes: 0, error: dead), "a banned node is reported once")
        XCTAssertEqual(bans.bannedHosts(), ["upos-sz-mirrorhw.bilivideo.com"])
        bans.reset()
        XCTAssertTrue(bans.allows(hw))
        XCTAssertEqual(bans.bannedHosts(), [])
        XCTAssertFalse(bans.record(hw, receivedBytes: 0, error: dead), "strikes start again for the next video")
    }

    func testRefusedAddressIsDroppedInsteadOfTheNodes() {
        var kinds: [BTRBanKind] = []
        let bans = BTRBanList(onBan: { _, _, kind in kinds.append(kind) })
        let at = { (host: String, os: String) in akamaiURL(os).replacingOccurrences(of: akamaiHost, with: host) }
        // Refused before anything has delivered: nobody is blamed yet.
        bans.record(akamaiURL("cosovbv"), receivedBytes: 0, error: refused)
        bans.record(akamaiURL("cosovbv"), receivedBytes: 0, error: refused)
        XCTAssertTrue(bans.allows(akamaiURL("cosovbv")))
        XCTAssertEqual(kinds, [])
        // The same node serves the other address, so the refused address is at fault.
        bans.success(akamaiURL("akam"))
        XCTAssertFalse(bans.allowsAddress(akamaiURL("cosovbv")))
        XCTAssertFalse(bans.allows(at("upos-sz-mirrorali.bilivideo.com", "cosovbv")), "dropped on every node")
        XCTAssertTrue(bans.allows(akamaiURL("akam")))
        XCTAssertEqual(bans.bannedHosts(), [])
        XCTAssertEqual(kinds, [.address])
        // A node that refuses an address other nodes serve is at fault itself.
        let lacking = "upos-sz-mirrorbos.bilivideo.com"
        bans.record(at(lacking, "akam"), receivedBytes: 0, error: refused)
        XCTAssertTrue(bans.allows(at(lacking, "akam")))
        bans.record(at(lacking, "akam"), receivedBytes: 0, error: refused)
        XCTAssertFalse(bans.allowsNode(at(lacking, "akam")))
        XCTAssertTrue(bans.allowsAddress(at(lacking, "akam")))
        XCTAssertEqual(bans.bannedHosts(), [lacking])
        XCTAssertEqual(kinds, [.address, .node])
        bans.reset()
        XCTAssertTrue(bans.allows(akamaiURL("cosovbv")))
        XCTAssertTrue(bans.allows(at(lacking, "akam")))
    }

    func testNodeKeepsItsWorkingAddressAfterRefusingAnother() {
        var kinds: [BTRBanKind] = []
        let bans = BTRBanList(onBan: { _, _, kind in kinds.append(kind) })
        let mirror = "upos-sz-mirroraliov.bilivideo.com"
        let at = { (host: String, os: String) in akamaiURL(os).replacingOccurrences(of: akamaiHost, with: host) }
        bans.success(at(mirror, "cosovbv"))
        bans.success(at(mirror, "akam"))
        bans.success(akamaiURL("akam"))
        bans.record(akamaiURL("cosovbv"), receivedBytes: 0, error: refused)
        bans.record(akamaiURL("cosovbv"), receivedBytes: 0, error: refused)
        XCTAssertFalse(bans.allows(akamaiURL("cosovbv")), "pair ban")
        XCTAssertTrue(bans.allows(akamaiURL("akam")))
        XCTAssertTrue(bans.allows(at(mirror, "cosovbv")))
        XCTAssertEqual(bans.bannedHosts(), [])
        XCTAssertEqual(kinds, [.address])
        let resolver = BTRResolver(urls: { [akamaiURL("cosovbv"), akamaiURL("akam")] }, mode: { .overseas }, bans: bans,
                                   clock: BTRManualClock())
        XCTAssertTrue(resolver.urls().contains(akamaiURL("akam")))
        XCTAssertFalse(resolver.urls().contains(akamaiURL("cosovbv")))
        XCTAssertTrue(resolver.status().allSatisfy { $0.state != .banned })
    }

    func testLemonTrace() {
        // proxy-ports §3.7: a 403 twice → allowed; b (same address) succeeds → a's node banned; a with a new
        // signature succeeds → old address on a becomes a pair ban, new signature allowed.
        let bans = BTRBanList()
        let a = "https://upos-sz-mirrorali.bilivideo.com/v/1.m4s?sig=old"
        let b = "https://upos-sz-mirrorhw.bilivideo.com/v/1.m4s?sig=old"
        let aNew = "https://upos-sz-mirrorali.bilivideo.com/v/1.m4s?sig=new"
        bans.record(a, receivedBytes: 0, error: refused)
        bans.record(a, receivedBytes: 0, error: refused)
        XCTAssertTrue(bans.allows(a))
        bans.success(b)
        XCTAssertFalse(bans.allowsNode(a))
        XCTAssertTrue(bans.allows(b))
        bans.success(aNew)
        XCTAssertTrue(bans.allowsNode(a), "the node now serves an address")
        XCTAssertFalse(bans.allows(a), "the refused address stays dropped on that node (pair)")
        XCTAssertTrue(bans.allows(aNew))
        XCTAssertTrue(bans.allows(b))
        XCTAssertFalse(bans.record(aNew, receivedBytes: 10, error: dead), "partial bodies never count")
    }
}

final class BTRResolverTests: XCTestCase {
    private let ali = btrMediaURL("upos-sz-mirrorali.bilivideo.com")
    private let hw = btrMediaURL("upos-sz-mirrorhw.bilivideo.com")

    func testBannedNodesAreSkippedButNeverNoAddress() {
        let clock = BTRManualClock()
        let bans = BTRBanList()
        let resolver = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, bans: bans, clock: clock)
        XCTAssertEqual(resolver.urls().count, 9)
        resolver.failure(hw, error: dead, receivedBytes: 0)
        XCTAssertEqual(resolver.urls().count, 9, "one strike does not ban")
        resolver.failure(hw, error: dead, receivedBytes: 0)
        for list in [resolver.urls(), resolver.ordered(0), resolver.rangeCandidates(), resolver.rescueCandidates(),
                     resolver.startupCandidates()] {
            XCTAssertFalse(btrHosts(list).contains("upos-sz-mirrorhw.bilivideo.com"))
            XCTAssertFalse(list.isEmpty)
        }
        XCTAssertFalse(resolver.allows(hw))
        XCTAssertEqual(resolver.status().first { $0.host == "upos-sz-mirrorhw.bilivideo.com" }?.state, .banned)
        // Another resolver of the same video shares the list.
        let audio = BTRResolver(urls: { [btrMediaURL("upos-sz-mirrorbos.bilivideo.com")] }, mode: { .mainland }, bans: bans, clock: clock)
        XCTAssertFalse(btrHosts(audio.urls()).contains("upos-sz-mirrorhw.bilivideo.com"))
        for host in BTRCDN.mainlandHosts {
            bans.record(btrMediaURL(host), receivedBytes: 0, error: dead)
            bans.record(btrMediaURL(host), receivedBytes: 0, error: dead)
        }
        XCTAssertEqual(resolver.urls().count, 9, "with every node banned the full list is used again")
        XCTAssertFalse(resolver.startupCandidates().isEmpty)
        // Without a ban list nothing is banned.
        let plain = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, clock: clock)
        plain.failure(hw, error: dead)
        plain.failure(hw, error: dead)
        XCTAssertTrue(plain.allows(hw))
    }

    func testBackoffAndStates() {
        let clock = BTRManualClock()
        let resolver = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, clock: clock)
        XCTAssertEqual(resolver.status().first?.state, .untested)
        resolver.failure(ali, error: CancellationError())
        XCTAssertTrue(resolver.rescueCandidates().contains(ali), "cancellation is not a failure")
        resolver.failure(ali, error: dead)
        XCTAssertFalse(resolver.rescueCandidates().contains(ali))
        XCTAssertEqual(resolver.status().first?.state, .blocked)
        clock.advance(5999)
        XCTAssertFalse(resolver.rescueCandidates().contains(ali))
        clock.advance(2)
        XCTAssertTrue(resolver.rescueCandidates().contains(ali), "first failure: 6 s")
        resolver.failure(ali, error: dead)
        clock.advance(11_999)
        XCTAssertFalse(resolver.rescueCandidates().contains(ali))
        clock.advance(2)
        XCTAssertTrue(resolver.rescueCandidates().contains(ali), "second: 12 s")
        resolver.failure(ali, error: dead)
        resolver.failure(ali, error: dead)
        resolver.failure(ali, error: dead)
        clock.advance(47_999)
        XCTAssertFalse(resolver.rescueCandidates().contains(ali))
        clock.advance(2)
        XCTAssertTrue(resolver.rescueCandidates().contains(ali), "capped at 48 s")
        // ordered() falls back to blocked ones rather than nothing.
        let single = BTRResolver(urls: { [self.ali] }, mode: { .original }, clock: clock)
        single.failure(ali, error: dead)
        XCTAssertEqual(single.ordered(0), [ali])
        XCTAssertEqual(single.rescueCandidates(), [])
        single.success(ali, bps: 0)
        XCTAssertEqual(single.status().first?.state, .healthy)
    }

    func testSpeedReportingSampleAndStaleness() {
        let clock = BTRManualClock()
        let resolver = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, clock: clock)
        XCTAssertEqual(resolver.speed(ali), 0)
        resolver.success(ali, bps: 5_000_000)
        XCTAssertEqual(resolver.speed(ali), 5_000_000)
        resolver.success(ali, bps: 1_000_000)
        XCTAssertEqual(resolver.speed(ali), 5_000_000 * 0.65 + 1_000_000 * 0.35, accuracy: 0.001)
        // Short transfers do not keep an old measurement alive.
        for _ in 0..<5 {
            clock.advance(20_000)
            resolver.success(ali, bps: 0)
        }
        XCTAssertEqual(resolver.speed(ali), 0, "after 90 s without a real measurement")
        XCTAssertEqual(resolver.status().first { $0.host == "upos-sz-mirrorali.bilivideo.com" }?.state, .healthy)
        resolver.success(ali, bps: 3_000_000)
        XCTAssertGreaterThan(resolver.speed(ali), 0)
        // A sample measures without forgiving.
        let other = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, clock: clock)
        other.failure(ali, error: BTRError.stallTimeout, receivedBytes: 4096)
        XCTAssertFalse(other.rangeCandidates().contains(ali))
        other.sample(ali, bps: 300_000)
        XCTAssertEqual(other.speed(ali), 300_000)
        XCTAssertFalse(other.rescueCandidates().contains(ali))
        XCTAssertEqual(other.status().first { $0.host == "upos-sz-mirrorali.bilivideo.com" }?.state, .blocked)
    }

    func testFreshSignatureKeepsSpeedNotFailures() {
        let clock = BTRManualClock()
        let host = "upos-sz-mirrorali.bilivideo.com"
        var current = ["https://\(host)/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&upsig=old"]
        let lock = NSLock()
        let resolver = BTRResolver(urls: { lock.lock(); defer { lock.unlock() }; return current }, mode: { .mainland }, clock: clock)
        let old = resolver.urls().first { BTRCDN.hostOf($0) == host }!
        resolver.success(old, bps: 5_000_000)
        resolver.failure(old, error: refused)
        lock.lock()
        current = ["https://\(host)/upgcxcode/00/00/1/1-1-30080.m4s?deadline=2&upsig=new"]
        lock.unlock()
        let fresh = resolver.urls().first { BTRCDN.hostOf($0) == host }!
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(resolver.speed(fresh), 5_000_000, "the node's speed is known at once")
        XCTAssertTrue(resolver.rangeCandidates().contains(fresh), "not backing off for the old address's failure")
    }

    func testRangeCandidatesWarmupAndModeChangesApplyLive() {
        let clock = BTRManualClock()
        var mode = CDNMode.mainland
        var custom: [String] = []
        let resolver = BTRResolver(urls: { [self.ali] }, mode: { mode }, customHosts: { custom }, clock: clock)
        XCTAssertEqual(resolver.rangeCandidates().count, 9, "first range: every node")
        XCTAssertEqual(resolver.rangeCandidates().count, 6, "mainland warm-up is one range; then 6")
        mode = .custom
        custom = ["upos-sz-mirrorcos.bilivideo.com", "cn-gdfs-ct-01-01.bilivideo.com"]
        XCTAssertEqual(btrHosts(resolver.urls()), custom)
        XCTAssertEqual(btrHosts(resolver.startupCandidates()), custom, "custom mode does not race Bilibili's own address")
        custom = []
        XCTAssertEqual(btrHosts(resolver.urls()), BTRCDN.mainlandHosts)
        XCTAssertEqual(btrHosts(resolver.startupCandidates()).first, "upos-sz-mirrorali.bilivideo.com")
        custom = ["upos-sz-mirrorbos.bilivideo.com"]
        XCTAssertEqual(btrHosts(resolver.urls()), ["upos-sz-mirrorbos.bilivideo.com"])
        // Overseas warm-up: 4 ranges over every node.
        let overseas = BTRResolver(urls: { [btrMediaURL("cn-hk-eq-01-01.bilivideo.com")] }, mode: { .overseas }, clock: clock)
        XCTAssertEqual((0..<4).map { _ in overseas.rangeCandidates().count }, [4, 4, 4, 4])
        // Own original first, ≤ 8 startup candidates.
        let own = BTRResolver(urls: { [btrMediaURL("cn-hk-eq-01-01.bilivideo.com"), self.ali] }, mode: { .mainland }, clock: clock)
        let startup = own.startupCandidates()
        XCTAssertEqual(startup.first, btrMediaURL("cn-hk-eq-01-01.bilivideo.com"))
        XCTAssertEqual(startup.count, 8)
    }

    func testOrderedRotates() {
        let resolver = BTRResolver(urls: { [self.ali] }, mode: { .mainland }, clock: BTRManualClock())
        let first = resolver.ordered(0)
        let second = resolver.ordered(0)
        XCTAssertEqual(first.count, 9)
        XCTAssertEqual(second.first, first[1], "cursor moves one node per call")
        XCTAssertEqual(resolver.ordered(3, exclude: [first[0]]).count, 8)
    }

    func testStaleMeasurementGetsAnotherTryThroughTheExplorationSlot() {
        let clock = BTRManualClock()
        let hosts = Array(BTRCDN.mainlandHosts.prefix(8))
        let resolver = BTRResolver(urls: { [btrMediaURL(hosts[0])] }, mode: { .mainland }, clock: clock)
        let slow = btrMediaURL(hosts[7])
        for (i, host) in hosts.enumerated() { resolver.success(btrMediaURL(host), bps: Double(8 - i) * 1024 * 1024) }
        _ = resolver.rangeCandidates() // warm-up
        var triedAt: [Int] = []
        for seconds in stride(from: 20, through: 160, by: 20) {
            clock.advance(20_000)
            let picked = resolver.rangeCandidates()
            XCTAssertEqual(picked.count, 6)
            if picked.contains(slow) { triedAt.append(seconds) }
            for url in picked {
                let s = resolver.speed(url)
                resolver.success(url, bps: s > 0 ? s : 1024 * 1024)
            }
        }
        XCTAssertGreaterThanOrEqual(triedAt.count, 1, "the slow node is tried again")
        XCTAssertGreaterThanOrEqual(triedAt.first ?? 0, 90, "but not while its measurement is fresh")
        XCTAssertLessThanOrEqual(triedAt.count, 2, "one try measures it for another 90 s: \(triedAt)")
        XCTAssertGreaterThan(resolver.speed(slow), 0)
    }
}
