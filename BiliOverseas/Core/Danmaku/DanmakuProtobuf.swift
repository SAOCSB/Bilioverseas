import Foundation

/// Hand-written decoder for `bilibili.community.service.dm.v1.DmSegMobileReply` (the body of
/// `x/v2/dm/web/seg.so` and `x/v2/dm/wbi/web/seg.so`). Unknown fields are skipped, and a known
/// field that arrives with an unexpected wire type is skipped too.
///
/// DmSegMobileReply: 1 elems (repeated DanmakuElem), 2 state int32 (1 = closed), 3 ai_flag,
/// 4 segment_rules, 5 colorful_src, 6 context_src.
/// DanmakuElem: 1 id int64, 2 progress int32 (ms), 3 mode int32, 4 fontsize int32, 5 color uint32,
/// 6 mid_hash string, 7 content string, 8 ctime int64, 9 weight int32, 10 action string,
/// 11 pool int32, 12 id_str string, 13 attr int32, 15 like_count int64, 22 animation string,
/// 23 extra string, 24 colorful enum (60001 = VIP gradient), 25 type, 26 oid, 27 dm_from.
enum DanmakuProtobuf {
    enum DecodeError: Error, Equatable {
        /// The body looks like JSON / HTML / XML / text (an error page), not protobuf.
        case notProtobuf
    }

    static func decodeSegmentReply(_ data: Data) throws -> DanmakuSegmentReply {
        try decodeSegmentReply(bytes: [UInt8](data))
    }

    static func decodeSegmentReply(bytes: [UInt8]) throws -> DanmakuSegmentReply {
        if bytes.isEmpty { return .empty }
        if looksTextual(bytes) { throw DecodeError.notProtobuf }
        // Walk the wire structure first with overflow-safe arithmetic so arbitrary garbage can
        // never reach a length the shared reader would have to convert unsafely.
        guard isStructurallyValid(bytes, from: 0, to: bytes.count, depth: 0) else { throw DecodeError.notProtobuf }
        var reader = ProtobufReader(bytes: bytes)
        var reply = DanmakuSegmentReply()
        var first = true
        while let tag = try reader.readTag() {
            // A real reply never starts with field 0 or a field outside the message.
            if first, tag.field == 0 || tag.field > 6 { throw DecodeError.notProtobuf }
            first = false
            switch (tag.field, tag.wire) {
            case (1, .lengthDelimited):
                var sub = try reader.readMessage()
                if let item = try decodeElem(&sub) { reply.items.append(item) }
            case (2, .varint):
                reply.state = Int(try reader.readInt32())
            default:
                try reader.skip(tag.wire)
            }
        }
        return reply
    }

    /// Decodes one `DanmakuElem`. Returns nil for elements without content.
    static func decodeElem(_ reader: inout ProtobufReader) throws -> DanmakuItem? {
        var item = DanmakuItem(id: 0, time: 0, content: "")
        var idStr = ""
        while let tag = try reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, .varint): item.id = try reader.readInt64()
            case (2, .varint): item.time = Double(max(0, try reader.readInt32())) / 1000
            case (3, .varint): item.mode = Int(try reader.readInt32())
            case (4, .varint): item.fontSize = Int(try reader.readInt32())
            case (5, .varint): item.color = try reader.readUInt32() & 0xFFFFFF
            case (6, .lengthDelimited): item.midHash = try reader.readString()
            case (7, .lengthDelimited): item.content = try reader.readString()
            case (8, .varint): item.ctime = try reader.readInt64()
            case (9, .varint): item.weight = Int(try reader.readInt32())
            case (11, .varint): item.pool = Int(try reader.readInt32())
            case (12, .lengthDelimited): idStr = try reader.readString()
            case (13, .varint): item.attr = Int(try reader.readInt32())
            case (15, .varint): item.likeCount = try reader.readInt64()
            case (24, .varint): item.colorful = Int(try reader.readInt32())
            default: try reader.skip(tag.wire)
            }
        }
        if item.id == 0, let parsed = Int64(idStr) { item.id = parsed }
        if item.fontSize <= 0 { item.fontSize = 25 }
        guard !item.content.isEmpty else { return nil }
        return item
    }

    /// Checks tags, wire types and length prefixes of the reply (depth 0) and of every `elems`
    /// entry (depth 1) without decoding anything.
    static func isStructurallyValid(_ b: [UInt8], from start: Int, to end: Int, depth: Int) -> Bool {
        var i = start
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < end {
                let byte = b[i]
                i += 1
                if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < end {
            guard let key = varint() else { return false }
            let field = key >> 3
            guard field > 0 else { return false }
            switch key & 7 {
            case 0:
                guard varint() != nil else { return false }
            case 1:
                guard end - i >= 8 else { return false }
                i += 8
            case 5:
                guard end - i >= 4 else { return false }
                i += 4
            case 2:
                guard let len = varint(), len <= UInt64(end - i) else { return false }
                let sub = i
                i += Int(len)
                if depth == 0, field == 1, !isStructurallyValid(b, from: sub, to: i, depth: 1) { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Error bodies (JSON envelopes, HTML pages, XML) start with printable ASCII that is not a
    /// plausible first protobuf tag of this message.
    static func looksTextual(_ bytes: [UInt8]) -> Bool {
        var i = 0
        // Skip a UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        guard i < bytes.count else { return true }
        // Note: 0x0A ("\n") is the normal first byte (field 1, length-delimited), so whitespace is
        // not treated as text here; other garbage fails in the reader with a thrown error.
        switch bytes[i] {
        case UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "<"):
            return true
        default:
            return false
        }
    }
}
