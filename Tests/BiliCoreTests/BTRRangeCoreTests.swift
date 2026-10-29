import XCTest
@testable import BiliCore

final class BTRRangeCoreTests: XCTestCase {
    func testMediaURLWhitelist() {
        XCTAssertTrue(BTRRangeCore.isBilibiliMediaURL(btrMediaURL("upos-sz-mirrorali.bilivideo.com")))
        XCTAssertTrue(BTRRangeCore.isBilibiliMediaURL("https://upos-hz-mirrorakam.akamaized.net/a/b.MP4?x=1"))
        XCTAssertTrue(BTRRangeCore.isBilibiliMediaURL("https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/a.m4s?os=mcdn"))
        XCTAssertTrue(BTRRangeCore.isBilibiliMediaURL("https://peer.szbdyd.com:4483/a.flv"))
        XCTAssertFalse(BTRRangeCore.isBilibiliMediaURL("http://upos-sz-mirrorali.bilivideo.com/a.m4s"), "http is rejected")
        XCTAssertFalse(BTRRangeCore.isBilibiliMediaURL("https://upos-sz-mirrorali.bilivideo.com/a.m4s.txt"))
        XCTAssertFalse(BTRRangeCore.isBilibiliMediaURL("https://example.com/a.m4s"))
        XCTAssertFalse(BTRRangeCore.isBilibiliMediaURL("https://bilivideo.com.example.net/a.m4s"))
        XCTAssertFalse(BTRRangeCore.isBilibiliMediaURL("https://api.bilibili.com/x/player/playurl"))
    }

    func testNormalizeCdnHost() {
        XCTAssertEqual(BTRRangeCore.normalizeCdnHost(" https://CN-GDFS-CT-01-01.bilivideo.com:4483/x?y=1 "),
                       "cn-gdfs-ct-01-01.bilivideo.com")
        XCTAssertEqual(BTRRangeCore.normalizeCdnHost("upos-sz-mirrorcos.bilivideo.com"), "upos-sz-mirrorcos.bilivideo.com")
        XCTAssertEqual(BTRRangeCore.normalizeCdnHost("UPOS-SZ-MIRRORCOS.bilivideo.com"), "upos-sz-mirrorcos.bilivideo.com")
        for bad in ["example.com", "bilivideo.com.example.net", "https://1.2.3.4/", "upos sz.bilivideo.com", "", "127.0.0.1",
                    "-bad.bilivideo.com", String(repeating: "a", count: 250) + ".bilivideo.com"] {
            XCTAssertEqual(BTRRangeCore.normalizeCdnHost(bad), "", bad)
        }
    }

    func testParseByteRange() {
        XCTAssertEqual(BTRRangeCore.parseByteRange("0-927"), ByteRange(start: 0, end: 927))
        XCTAssertEqual(BTRRangeCore.parseByteRange(" 928-3011 "), ByteRange(start: 928, end: 3011))
        XCTAssertEqual(BTRRangeCore.parseByteRange("5-5")?.length, 1)
        XCTAssertNil(BTRRangeCore.parseByteRange("10-9"))
        XCTAssertNil(BTRRangeCore.parseByteRange("-9"))
        XCTAssertNil(BTRRangeCore.parseByteRange("a-9"))
        XCTAssertNil(BTRRangeCore.parseByteRange("1-2-3"))
        XCTAssertNil(BTRRangeCore.parseByteRange("0-9007199254740992"), "not a safe integer")
    }

    func testParseRangeHeaderIsClosedOnly() {
        XCTAssertEqual(BTRRangeCore.parseRangeHeader("bytes=0-65535"), ByteRange(start: 0, end: 65535))
        XCTAssertEqual(BTRRangeCore.parseRangeHeader("Bytes=10-20"), ByteRange(start: 10, end: 20))
        XCTAssertNil(BTRRangeCore.parseRangeHeader("bytes=0-"))
        XCTAssertNil(BTRRangeCore.parseRangeHeader("bytes=-500"))
        XCTAssertNil(BTRRangeCore.parseRangeHeader(nil))
    }

    func testParseContentRange() {
        XCTAssertEqual(BTRRangeCore.parseContentRange("bytes 0-99/100"), BTRContentRange(start: 0, end: 99, total: 100))
        XCTAssertEqual(BTRRangeCore.parseContentRange("BYTES   5-9/8388608"), BTRContentRange(start: 5, end: 9, total: 8_388_608))
        XCTAssertEqual(BTRRangeCore.parseContentRange("bytes 0-99/*"), BTRContentRange(start: 0, end: 99, total: nil))
        XCTAssertNil(BTRRangeCore.parseContentRange("bytes 0-99/99"), "total must exceed end")
        XCTAssertNil(BTRRangeCore.parseContentRange("bytes 9-0/100"))
        XCTAssertNil(BTRRangeCore.parseContentRange("bytes0-9/100"), "needs whitespace")
        XCTAssertNil(BTRRangeCore.parseContentRange("bytes */100"))
        XCTAssertNil(BTRRangeCore.parseContentRange(nil))
    }

    func testParseClientRange() {
        // lemon parseRange vectors (total 100).
        XCTAssertEqual(BTRRangeCore.parseClientRange(nil, total: 100), ByteRange(start: 0, end: 99))
        XCTAssertEqual(BTRRangeCore.parseClientRange("bytes=20-", total: 100), ByteRange(start: 20, end: 99))
        XCTAssertEqual(BTRRangeCore.parseClientRange("bytes=20-999", total: 100), ByteRange(start: 20, end: 99))
        XCTAssertEqual(BTRRangeCore.parseClientRange("bytes=-10", total: 100), ByteRange(start: 90, end: 99))
        XCTAssertEqual(BTRRangeCore.parseClientRange("bytes=0-1", total: 100), ByteRange(start: 0, end: 1))
        for bad in ["bytes=100-", "bytes=20-10", "bytes=-0", "bytes=1-2,4-5", "bytes=-", "items=0-1"] {
            XCTAssertNil(BTRRangeCore.parseClientRange(bad, total: 100), bad)
        }
    }

    func testSplitRange() {
        let pieces = BTRRangeCore.splitRange(start: 1000, end: 1000 + 10 - 1, concurrency: 3, minChunkBytes: 1)
        // Minimum is clamped to 32 KiB: 10 bytes is one piece.
        XCTAssertEqual(pieces, [BTRPiece(index: 0, start: 1000, end: 1009)])
        let even = BTRRangeCore.splitRange(start: 0, end: 512 * 1024 - 1, concurrency: 7, minChunkBytes: 64 * 1024)
        XCTAssertEqual(even.count, 7)
        XCTAssertEqual(even.first?.start, 0)
        XCTAssertEqual(even.last?.end, 512 * 1024 - 1)
        // Remainder spread over the first pieces; contiguous.
        let sizes = even.map(\.length)
        XCTAssertEqual(sizes.reduce(0, +), 512 * 1024)
        XCTAssertTrue(sizes.max()! - sizes.min()! <= 1)
        XCTAssertTrue(sizes.first! >= sizes.last!)
        for (a, b) in zip(even, even.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
        XCTAssertEqual(even.map(\.index), Array(0..<7))
        // Limited by the minimum chunk.
        XCTAssertEqual(BTRRangeCore.splitRange(start: 0, end: 2 * 1024 * 1024 - 1, concurrency: 28, minChunkBytes: 512 * 1024).count, 4)
        // ≤ 512 pieces.
        XCTAssertEqual(BTRRangeCore.splitRange(start: 0, end: 1 << 40, concurrency: 10_000, minChunkBytes: 64 * 1024).count, 512)
    }

    func testRoundPauseAndNormalLimit() {
        XCTAssertEqual(BTRConstants.roundPauseMs(1), 500)
        XCTAssertEqual(BTRConstants.roundPauseMs(2), 1000)
        XCTAssertEqual(BTRConstants.roundPauseMs(5), 2000)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 1), 1)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 2), 1)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 4), 3)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 8), 7)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 16), 14)
        XCTAssertEqual(BTRSlotPool.normalLimit(for: 64), 56)
    }

    func testAdaptiveMinChunk() {
        let meter = BTRMeter()
        XCTAssertEqual(meter.adaptiveMinChunk(rangeLength: 2 * 1024 * 1024, pieceLimit: 28, hostCount: 1), 64 * 1024,
                       "unmeasured: 64 KiB")
        XCTAssertEqual(meter.hedgeDelayMs(maxMs: 900), 900)
        meter.record(bytes: 1024 * 1024, elapsedMs: 100) // 10 MiB/s
        // ~0.6 s of one connection capped at 1 MiB, and the spread keeps ≥ 4 pieces.
        XCTAssertEqual(meter.adaptiveMinChunk(rangeLength: 2 * 1024 * 1024, pieceLimit: 28, hostCount: 1), 512 * 1024)
        XCTAssertEqual(meter.adaptiveMinChunk(rangeLength: 64 * 1024 * 1024, pieceLimit: 28, hostCount: 9), 1024 * 1024)
        XCTAssertEqual(meter.hedgeDelayMs(maxMs: 900), 250, "1.5 × 100 ms clamped to 250")
        meter.record(bytes: 1000, elapsedMs: 5000)
        XCTAssertEqual(meter.hedgeDelayMs(maxMs: 900), 250, "short transfers do not count")
        let slow = BTRMeter()
        slow.record(bytes: 100 * 1024, elapsedMs: 1000) // 100 KiB/s → target 0 → floor
        XCTAssertEqual(slow.adaptiveMinChunk(rangeLength: 4 * 1024 * 1024, pieceLimit: 7, hostCount: 9), 64 * 1024)
        XCTAssertEqual(slow.hedgeDelayMs(maxMs: 900), 900)
    }
}
