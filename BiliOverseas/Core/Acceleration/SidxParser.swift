import Foundation

// ISO-BMFF `sidx` (Segment Index Box, ISO/IEC 14496-12 §8.16.3) parsing for Bilibili DASH fMP4 files.
//
// Behaviour follows BTR `sidx.js` (MIT) and avplayer-hls spec §5, with the reference parser's bugs fixed:
// `size == 1` (64-bit largesize, header 16) and `size == 0` (box runs to the end of the data) are handled,
// hierarchical indexes (`reference_type == 1`) are rejected, `first_offset` is honoured, and every box is
// bounds-checked before it is read.

/// One media segment (subsegment) referenced by a `sidx` box.
struct SidxSegment: Hashable {
    /// 0-based position in the index.
    var index: Int
    /// Absolute byte range of the segment inside the media file.
    var byteRange: ByteRange
    /// Seconds from the first referenced segment (the HLS playlist timeline: the sum of the previous `EXTINF`s).
    var startTime: Double
    /// Seconds.
    var duration: Double

    var endTime: Double { startTime + duration }
}

/// A parsed segment index.
struct SidxIndex: Hashable {
    var timescale: UInt32
    var earliestPresentationTime: UInt64
    var firstOffset: UInt64
    var segments: [SidxSegment]

    var duration: Double { segments.last?.endTime ?? 0 }
    var maxSegmentDuration: Double { segments.map(\.duration).max() ?? 0 }
    /// Bytes from the first segment's first byte to the last segment's last byte.
    var mediaRange: ByteRange? {
        guard let first = segments.first, let last = segments.last else { return nil }
        return ByteRange(start: first.byteRange.start, end: last.byteRange.end)
    }

    /// Index of the segment playing at `seconds` (BTR `segmentIndexAt`): binary search for
    /// `startTime <= t < endTime`, otherwise the nearest index clamped into `0..<count`. -1 when empty.
    func segmentIndex(at seconds: Double) -> Int {
        SidxIndex.segmentIndex(in: segments, at: seconds)
    }

    static func segmentIndex(in segments: [SidxSegment], at seconds: Double) -> Int {
        guard !segments.isEmpty else { return -1 }
        let target = seconds.isFinite ? max(0, seconds) : 0
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let segment = segments[middle]
            if target < segment.startTime {
                high = middle - 1
            } else if target >= segment.endTime {
                low = middle + 1
            } else {
                return middle
            }
        }
        return max(0, min(segments.count - 1, low))
    }

    /// Index of the segment whose byte range contains `offset`, nil if none does.
    static func segmentIndex(in segments: [SidxSegment], containingByte offset: Int64) -> Int? {
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = segments[middle].byteRange
            if offset < range.start {
                high = middle - 1
            } else if offset > range.end {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }
}

enum SidxParseError: Error, Equatable, CustomStringConvertible {
    /// The data ends inside a box header or a box body.
    case truncated
    case malformedBox(String)
    /// No `sidx` box at the top level of the data.
    case notFound
    case unsupportedVersion(Int)
    /// `reference_type == 1`: the index points at further `sidx` boxes (not produced by Bilibili, not supported).
    case hierarchical
    case invalid(String)

    var description: String {
        switch self {
        case .truncated: return "sidx 数据不完整"
        case .malformedBox(let m): return "MP4 box 格式错误：\(m)"
        case .notFound: return "没有找到 sidx 索引"
        case .unsupportedVersion(let v): return "不支持的 sidx 版本 \(v)"
        case .hierarchical: return "不支持多级 sidx 索引"
        case .invalid(let m): return "sidx 索引无效：\(m)"
        }
    }
}

/// Where the `sidx` box sits inside the first bytes of a file (used when playurl gave no `segment_base`).
enum SidxLocation: Equatable {
    /// `initRange` = every box before the sidx (ftyp + moov …); `indexRange` = the sidx box itself.
    case found(initRange: ByteRange, indexRange: ByteRange)
    /// The data ends before the sidx (or the box in front of it) is complete: fetch at least this many bytes.
    case needMore(minimumLength: Int64)
    /// Media boxes (`moof` / `mdat`) start before any sidx: the file has no index.
    case notFound
}

enum SidxParser {
    static let maxReferences = 10_000

    /// Parses the first top-level `sidx` box in `data`.
    /// - Parameter absoluteStart: file offset of `data[0]` (the `index_range` start when `data` is exactly the
    ///   index bytes, 0 when it is the head of the file).
    static func parse(_ data: Data, absoluteStart: Int64 = 0) throws -> SidxIndex {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 8 <= bytes.count {
            let box = try boxHeader(bytes, at: offset)
            guard offset + box.size <= bytes.count else { throw SidxParseError.truncated }
            if box.type == "sidx" {
                return try parseBox(bytes, boxOffset: offset, boxSize: box.size, headerSize: box.headerSize,
                                    absoluteStart: absoluteStart)
            }
            offset += box.size
        }
        throw SidxParseError.notFound
    }

    /// Walks the top-level boxes of the head of a file to find the sidx (avplayer-hls §6.2 fallback when
    /// `segment_base` is missing). `data` must start at file offset 0.
    static func locate(in data: Data) -> SidxLocation {
        let bytes = [UInt8](data)
        var offset = 0
        while true {
            guard offset + 8 <= bytes.count else { return .needMore(minimumLength: Int64(offset + 16)) }
            let raw = readUInt32(bytes, offset)
            // size == 0 means "to the end of the file", which only a trailing mdat does.
            if raw == 0 { return .notFound }
            if raw == 1 && offset + 16 > bytes.count { return .needMore(minimumLength: Int64(offset + 16)) }
            guard let box = try? boxHeader(bytes, at: offset) else { return .notFound }
            if box.type == "moof" || box.type == "mdat" { return .notFound }
            guard offset + box.size <= bytes.count else { return .needMore(minimumLength: Int64(offset + box.size)) }
            if box.type == "sidx" {
                guard offset > 0 else { return .notFound }
                return .found(initRange: ByteRange(start: 0, end: Int64(offset) - 1),
                              indexRange: ByteRange(start: Int64(offset), end: Int64(offset + box.size) - 1))
            }
            offset += box.size
        }
    }

    // MARK: - Internals

    private struct BoxHeader {
        var size: Int
        var headerSize: Int
        var type: String
    }

    private static func boxHeader(_ bytes: [UInt8], at offset: Int) throws -> BoxHeader {
        guard offset + 8 <= bytes.count else { throw SidxParseError.truncated }
        let raw = readUInt32(bytes, offset)
        let type = fourCC(bytes, offset + 4)
        var size: UInt64 = UInt64(raw)
        var header = 8
        if raw == 1 {
            guard offset + 16 <= bytes.count else { throw SidxParseError.truncated }
            size = readUInt64(bytes, offset + 8)
            header = 16
        } else if raw == 0 {
            size = UInt64(bytes.count - offset)
        }
        guard size >= UInt64(header) else { throw SidxParseError.malformedBox("\(type) 长度 \(size)") }
        guard size <= UInt64(Int.max / 2) else { throw SidxParseError.malformedBox("\(type) 过大") }
        return BoxHeader(size: Int(size), headerSize: header, type: type)
    }

    private static func parseBox(_ bytes: [UInt8], boxOffset: Int, boxSize: Int, headerSize: Int,
                                 absoluteStart: Int64) throws -> SidxIndex {
        let end = boxOffset + boxSize
        var cursor = boxOffset + headerSize
        func need(_ n: Int) throws { if cursor + n > end { throw SidxParseError.truncated } }

        try need(12)
        let version = Int(bytes[cursor])
        cursor += 4 // version + flags
        cursor += 4 // reference_ID
        let timescale = readUInt32(bytes, cursor)
        cursor += 4
        guard timescale > 0 else { throw SidxParseError.invalid("timescale = 0") }

        let earliest: UInt64
        let firstOffset: UInt64
        switch version {
        case 0:
            try need(8)
            earliest = UInt64(readUInt32(bytes, cursor))
            firstOffset = UInt64(readUInt32(bytes, cursor + 4))
            cursor += 8
        case 1:
            try need(16)
            earliest = readUInt64(bytes, cursor)
            firstOffset = readUInt64(bytes, cursor + 8)
            cursor += 16
        default:
            throw SidxParseError.unsupportedVersion(version)
        }
        guard firstOffset <= UInt64(Int64.max / 4), earliest <= UInt64(Int64.max / 4) else {
            throw SidxParseError.invalid("偏移量过大")
        }

        try need(4)
        cursor += 2 // reserved
        let count = Int(readUInt16(bytes, cursor))
        cursor += 2
        guard count >= 1, count <= maxReferences else { throw SidxParseError.invalid("reference_count = \(count)") }
        guard cursor + count * 12 <= end else { throw SidxParseError.truncated }

        var byteCursor = absoluteStart + Int64(boxOffset) + Int64(boxSize) + Int64(firstOffset)
        var timeCursor: UInt64 = 0
        let scale = Double(timescale)
        var segments: [SidxSegment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let reference = readUInt32(bytes, cursor)
            let duration = readUInt32(bytes, cursor + 4)
            cursor += 12 // + SAP word
            if reference >> 31 == 1 { throw SidxParseError.hierarchical }
            let size = Int64(reference & 0x7fff_ffff)
            guard size > 0 else { throw SidxParseError.invalid("referenced_size = 0") }
            segments.append(SidxSegment(
                index: segments.count,
                byteRange: ByteRange(start: byteCursor, end: byteCursor + size - 1),
                startTime: Double(timeCursor) / scale,
                duration: Double(duration) / scale))
            byteCursor += size
            timeCursor += UInt64(duration)
        }
        return SidxIndex(timescale: timescale, earliestPresentationTime: earliest, firstOffset: firstOffset,
                         segments: segments)
    }

    private static func readUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func readUInt64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(readUInt32(b, o)) << 32 | UInt64(readUInt32(b, o + 4))
    }

    private static func fourCC(_ b: [UInt8], _ o: Int) -> String {
        String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }
}
