import XCTest
@testable import BiliCore

final class SidxParserTests: XCTestCase {
    typealias Ref = EngineSyntheticMP4.Reference

    /// avplayer-hls §4.9: init 0-1004, index 1005-1668 (a 664-byte sidx), timescale 16000.
    func testWorkedExampleAbsoluteOffsets() throws {
        let box = EngineSyntheticMP4.sidxBox(timescale: 16000, references: [
            Ref(size: 524_288, duration: 80080), Ref(size: 498_001, duration: 80080), Ref(size: 301_777, duration: 51200),
        ], boxSize: 664)
        XCTAssertEqual(box.count, 664)
        let index = try SidxParser.parse(box, absoluteStart: 1005)
        XCTAssertEqual(index.timescale, 16000)
        XCTAssertEqual(index.segments.map(\.byteRange), [
            ByteRange(start: 1669, end: 1669 + 524_288 - 1),
            ByteRange(start: 525_957, end: 525_957 + 498_001 - 1),
            ByteRange(start: 1_023_958, end: 1_023_958 + 301_777 - 1),
        ])
        XCTAssertEqual(index.segments.map { "\($0.byteRange.length)@\($0.byteRange.start)" },
                       ["524288@1669", "498001@525957", "301777@1023958"])
        XCTAssertEqual(index.segments[0].duration, 5.005, accuracy: 1e-9)
        XCTAssertEqual(index.segments[2].duration, 3.2, accuracy: 1e-9)
        XCTAssertEqual(index.segments[1].startTime, 5.005, accuracy: 1e-9)
        XCTAssertEqual(index.segments.map(\.index), [0, 1, 2])
        XCTAssertEqual(index.duration, 13.21, accuracy: 1e-9)
        XCTAssertEqual(index.mediaRange, ByteRange(start: 1669, end: 1_023_958 + 301_777 - 1))
    }

    func testVersion1With64BitFieldsAndFirstOffset() throws {
        let box = EngineSyntheticMP4.sidxBox(version: 1, timescale: 1000, earliest: 0x1_0000_0000, firstOffset: 100,
                                             references: [Ref(size: 1000, duration: 2000), Ref(size: 500, duration: 1500)])
        XCTAssertEqual(box.count, 8 + 12 + 16 + 4 + 24)
        let index = try SidxParser.parse(box, absoluteStart: 4000)
        XCTAssertEqual(index.earliestPresentationTime, 0x1_0000_0000)
        XCTAssertEqual(index.firstOffset, 100)
        let first = Int64(4000 + box.count + 100)
        XCTAssertEqual(index.segments[0].byteRange, ByteRange(start: first, end: first + 999))
        XCTAssertEqual(index.segments[1].byteRange, ByteRange(start: first + 1000, end: first + 1499))
        // Times are on the playlist timeline (from the first reference), not offset by earliest_presentation_time.
        XCTAssertEqual(index.segments[0].startTime, 0)
        XCTAssertEqual(index.segments[1].startTime, 2.0)
        XCTAssertEqual(index.segments[1].duration, 1.5)
    }

    func testLargesizeHeader() throws {
        let box = EngineSyntheticMP4.sidxBox(timescale: 90000, references: [Ref(size: 777, duration: 90000)],
                                             largesize: true)
        XCTAssertEqual(box.count, 16 + 12 + 8 + 4 + 12)
        let index = try SidxParser.parse(box, absoluteStart: 50)
        XCTAssertEqual(index.segments.count, 1)
        // first byte = absoluteStart + box size (the 16-byte header is part of the box size).
        XCTAssertEqual(index.segments[0].byteRange, ByteRange(start: Int64(50 + box.count), end: Int64(50 + box.count + 776)))
        XCTAssertEqual(index.segments[0].duration, 1.0)
    }

    func testLargesizeOnPrecedingBoxIsSkippedCorrectly() throws {
        // A 24-byte 'free' box written with the 64-bit size form, then the sidx.
        var data = Data(EngineSyntheticMP4.be32(1) + Array("free".utf8) + EngineSyntheticMP4.be64(24) + [UInt8](repeating: 0, count: 8))
        let sidx = EngineSyntheticMP4.sidxBox(timescale: 1000, references: [Ref(size: 10, duration: 1000)])
        data.append(sidx)
        let index = try SidxParser.parse(data, absoluteStart: 0)
        XCTAssertEqual(index.segments[0].byteRange.start, Int64(24 + sidx.count))
    }

    func testBoxRunningToEndOfData() throws {
        // size == 0: the sidx extends to the end of the data.
        var box = [UInt8](EngineSyntheticMP4.sidxBox(timescale: 1000, references: [Ref(size: 64, duration: 500)]))
        box.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        let index = try SidxParser.parse(Data(box), absoluteStart: 10)
        XCTAssertEqual(index.segments[0].byteRange.start, Int64(10 + box.count))
    }

    func testHierarchicalIndexIsRejected() {
        let box = EngineSyntheticMP4.sidxBox(timescale: 1000, references: [
            Ref(size: 100, duration: 1000), Ref(size: 200, duration: 1000, type: 1),
        ])
        XCTAssertThrowsError(try SidxParser.parse(box)) { XCTAssertEqual($0 as? SidxParseError, .hierarchical) }
    }

    func testRejectsMalformedInput() {
        let good = EngineSyntheticMP4.sidxBox(timescale: 1000, references: [Ref(size: 100, duration: 1000)])
        XCTAssertThrowsError(try SidxParser.parse(good.prefix(good.count - 4))) {
            XCTAssertEqual($0 as? SidxParseError, .truncated)
        }
        let zeroScale = EngineSyntheticMP4.sidxBox(timescale: 0, references: [Ref(size: 100, duration: 1000)])
        XCTAssertThrowsError(try SidxParser.parse(zeroScale))
        let zeroSize = EngineSyntheticMP4.sidxBox(timescale: 1000, references: [Ref(size: 0, duration: 1000)])
        XCTAssertThrowsError(try SidxParser.parse(zeroSize))
        var v2 = [UInt8](good)
        v2[8] = 2
        XCTAssertThrowsError(try SidxParser.parse(Data(v2))) { XCTAssertEqual($0 as? SidxParseError, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try SidxParser.parse(EngineSyntheticMP4.box("moov", size: 40))) {
            XCTAssertEqual($0 as? SidxParseError, .notFound)
        }
        // Box header claiming less than its own header.
        XCTAssertThrowsError(try SidxParser.parse(Data(EngineSyntheticMP4.be32(4) + Array("sidx".utf8))))
    }

    func testParsesSidxAfterInitBoxesInFileHead() throws {
        let file = EngineSyntheticMP4.make(segmentSizes: [3000, 2000, 1000], durations: [2000, 2000, 1000])
        let index = try SidxParser.parse(file.data.prefix(Int(file.indexRange.end + 1)), absoluteStart: 0)
        XCTAssertEqual(index.segments.map(\.byteRange), file.segments)
        // The same bytes as the index range alone, with its absolute start.
        let alone = try SidxParser.parse(file.data.subdata(in: Int(file.indexRange.start)..<Int(file.indexRange.end + 1)),
                                         absoluteStart: file.indexRange.start)
        XCTAssertEqual(alone.segments, index.segments)
    }

    func testLocateInFileHead() {
        let file = EngineSyntheticMP4.make(segmentSizes: [3000, 2000], durations: [2000, 2000])
        XCTAssertEqual(SidxParser.locate(in: file.data),
                       .found(initRange: file.initRange, indexRange: file.indexRange))
        // Cut inside the moov box: need at least up to the end of the moov.
        XCTAssertEqual(SidxParser.locate(in: file.data.prefix(100)), .needMore(minimumLength: 24 + 1000))
        // Cut inside the sidx box.
        XCTAssertEqual(SidxParser.locate(in: file.data.prefix(Int(file.indexRange.start) + 10)),
                       .needMore(minimumLength: file.indexRange.end + 1))
        // Media before any sidx.
        var noIndex = EngineSyntheticMP4.box("ftyp", size: 24)
        noIndex.append(EngineSyntheticMP4.box("moof", size: 100))
        XCTAssertEqual(SidxParser.locate(in: noIndex), .notFound)
    }

    func testSegmentIndexAtTime() throws {
        let box = EngineSyntheticMP4.sidxBox(timescale: 1000, references: [
            Ref(size: 10, duration: 2000), Ref(size: 10, duration: 2000), Ref(size: 10, duration: 1000),
        ])
        let index = try SidxParser.parse(box)
        XCTAssertEqual(index.segmentIndex(at: 0), 0)
        XCTAssertEqual(index.segmentIndex(at: 1.999), 0)
        XCTAssertEqual(index.segmentIndex(at: 2.0), 1)
        XCTAssertEqual(index.segmentIndex(at: 4.5), 2)
        XCTAssertEqual(index.segmentIndex(at: 99), 2)
        XCTAssertEqual(index.segmentIndex(at: -5), 0)
        XCTAssertEqual(index.segmentIndex(at: .nan), 0)
        XCTAssertEqual(SidxIndex.segmentIndex(in: [], at: 1), -1)
        let first = index.segments[0].byteRange.start
        XCTAssertEqual(SidxIndex.segmentIndex(in: index.segments, containingByte: first), 0)
        XCTAssertEqual(SidxIndex.segmentIndex(in: index.segments, containingByte: first + 15), 1)
        XCTAssertNil(SidxIndex.segmentIndex(in: index.segments, containingByte: first - 1))
        XCTAssertNil(SidxIndex.segmentIndex(in: index.segments, containingByte: first + 30))
    }
}
