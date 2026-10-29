import XCTest
@testable import BiliCore

private final class FakeSpeeds: BTRAssignmentSource {
    var speeds: [String: Double]
    var candidates: [String]
    init(_ speeds: [String: Double], candidates: [String] = []) {
        self.speeds = speeds
        self.candidates = candidates
    }
    func speed(_ url: String) -> Double { speeds[url] ?? 0 }
    func rangeCandidates() -> [String] { candidates }
}

final class BTRAssignmentTests: XCTestCase {
    private let a = btrMediaURL("upos-sz-mirrorali.bilivideo.com")
    private let b = btrMediaURL("upos-sz-mirrorhw.bilivideo.com")
    private let c = btrMediaURL("upos-sz-mirrorbos.bilivideo.com")
    private let d = btrMediaURL("upos-sz-mirror08c.bilivideo.com")

    func testTrivialCases() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([:])
        XCTAssertEqual(assigner.assignPrimaries([], source: src, count: 3), [])
        XCTAssertEqual(assigner.assignPrimaries([a, b], source: src, count: 0), [])
        XCTAssertEqual(assigner.assignPrimaries([a], source: src, count: 3), [a, a, a])
    }

    func testUnmeasuredRotateAndEachRangeOpensOneNodeFurther() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([:])
        XCTAssertEqual(assigner.assignPrimaries([a, b, c], source: src, count: 4), [a, b, c, a])
        XCTAssertEqual(assigner.assignPrimaries([a, b, c], source: src, count: 4), [b, c, a, b])
    }

    func testEqualNodesInTurns() {
        let assigner = BTRAssigner()
        let urls = [a, b, c, d]
        let src = FakeSpeeds(Dictionary(uniqueKeysWithValues: urls.map { ($0, 4.0 * 1024 * 1024) }))
        var firsts: [String] = []
        for _ in 0..<3 {
            let p = assigner.assignPrimaries(urls, source: src, count: 7)
            XCTAssertEqual(p.count, 7)
            for (x, y) in zip(p, p.dropFirst()) { XCTAssertNotEqual(x, y, "neighbouring pieces use different nodes") }
            XCTAssertEqual(Set(p.prefix(4)).count, 4, "the first pieces cover every node")
            firsts.append(p[0])
        }
        XCTAssertEqual(Set(firsts).count, 3, "each range opens on another node")
    }

    func testWeightedShareAndFloor() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([a: 9 * 1024 * 1024, b: 1 * 1024 * 1024])
        let p = assigner.assignPrimaries([a, b], source: src, count: 20)
        let fast = p.filter { $0 == a }.count, slow = p.filter { $0 == b }.count
        XCTAssertEqual(fast + slow, 20)
        XCTAssertGreaterThanOrEqual(fast, slow * 2)
        XCTAssertGreaterThanOrEqual(slow, 1, "the slow node keeps a share")
        XCTAssertEqual(fast, 18)
    }

    func testNodesUnderATwelfthOfTheBestGetNoPrimaries() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([a: 12_000_000, b: 900_000, c: 1_000_000])
        let p = assigner.assignPrimaries([a, b, c], source: src, count: 24)
        XCTAssertFalse(p.contains(b))
        XCTAssertTrue(p.contains(c), "exactly 1/12 is still eligible")
    }

    func testTrialsGoToTheEndForUnmeasuredNodes() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([a: 4_000_000, b: 4_000_000])
        let p = assigner.assignPrimaries([a, b, c, d], source: src, count: 12)
        // trials = min(2 × 2 unknown, 12 / 4) = 3, the last pieces, rotating over the unknown nodes.
        XCTAssertEqual(Array(p.suffix(3)), [c, d, c])
        XCTAssertTrue(p.prefix(9).allSatisfy { $0 == a || $0 == b })
        let q = assigner.assignPrimaries([a, b, c, d], source: src, count: 12)
        XCTAssertEqual(Array(q.suffix(3)), [d, c, d], "the trial cursor carries on")
    }

    func testEveryFourthSmallRangeGivesOneTrialPerResolver() {
        let assigner = BTRAssigner()
        let video = FakeSpeeds([a: 4_000_000])
        let audio = FakeSpeeds([a: 4_000_000])
        var videoTrials = 0, audioTrials = 0
        for _ in 0..<12 {
            // Two pieces: floor(2/4) = 0 trials, except every 4th range.
            if assigner.assignPrimaries([a, b], source: video, count: 2).contains(b) { videoTrials += 1 }
            if assigner.assignPrimaries([a, b], source: audio, count: 2).contains(b) { audioTrials += 1 }
        }
        XCTAssertEqual(videoTrials, 3)
        XCTAssertEqual(audioTrials, 3, "the audio track gets its own trials")
        XCTAssertEqual(assigner.assignPrimaries([a, b], source: video, count: 1), [a], "a single piece has no trial")
    }

    func testInTurnsRotatesAndSkipsVerySlowNodes() {
        let assigner = BTRAssigner()
        let src = FakeSpeeds([a: 12_000_000, b: 500_000], candidates: [a, b, c])
        let picks = (0..<6).map { _ in assigner.inTurnsCandidates(src) }
        XCTAssertEqual(picks, [[a], [c], [a], [c], [a], [c]])
        XCTAssertEqual(BTRAssigner.preferredFor(b, [a, b, c]), [b, a, c])
        XCTAssertEqual(BTRAssigner.preferredFor(nil, [a, b]), [a, b])
    }
}
