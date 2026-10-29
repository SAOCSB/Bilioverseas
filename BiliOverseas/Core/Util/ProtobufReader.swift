import Foundation

/// Minimal protobuf wire-format reader (no codegen, no dependency). Enough to decode
/// Bilibili's danmaku segments (`DmSegMobileReply`) and other small messages.
struct ProtobufReader {
    enum WireType: Int {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
    }

    enum DecodeError: Error {
        case truncated
        case malformedVarint
        case unsupportedWireType(Int)
    }

    private let bytes: [UInt8]
    private(set) var index: Int
    private let end: Int

    init(data: Data) {
        bytes = [UInt8](data)
        index = 0
        end = bytes.count
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        index = 0
        end = bytes.count
    }

    var isAtEnd: Bool { index >= end }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < end else { throw DecodeError.truncated }
            let b = bytes[index]
            index += 1
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { throw DecodeError.malformedVarint }
        }
    }

    /// Returns `nil` at end of message.
    mutating func readTag() throws -> (field: Int, wire: WireType)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let wireRaw = Int(key & 0x7)
        guard let wire = WireType(rawValue: wireRaw) else { throw DecodeError.unsupportedWireType(wireRaw) }
        return (Int(key >> 3), wire)
    }

    mutating func readBytes() throws -> [UInt8] {
        let raw = try readVarint()
        // Validate before converting: garbage input can carry lengths that overflow Int.
        guard raw <= UInt64(end - index) else { throw DecodeError.truncated }
        let len = Int(raw)
        let out = Array(bytes[index..<(index + len)])
        index += len
        return out
    }

    mutating func readString() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }

    mutating func readMessage() throws -> ProtobufReader {
        ProtobufReader(bytes: try readBytes())
    }

    mutating func readFixed32() throws -> UInt32 {
        guard index + 4 <= end else { throw DecodeError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[index + i]) << (8 * UInt32(i)) }
        index += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard index + 8 <= end else { throw DecodeError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
        index += 8
        return v
    }

    mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readVarint()) }
    mutating func readInt32() throws -> Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: try readVarint())) }
    mutating func readUInt32() throws -> UInt32 { UInt32(truncatingIfNeeded: try readVarint()) }
    mutating func readBool() throws -> Bool { try readVarint() != 0 }

    mutating func skip(_ wire: WireType) throws {
        switch wire {
        case .varint: _ = try readVarint()
        case .fixed64: _ = try readFixed64()
        case .lengthDelimited: _ = try readBytes()
        case .fixed32: _ = try readFixed32()
        case .startGroup, .endGroup: throw DecodeError.unsupportedWireType(wire.rawValue)
        }
    }
}

/// Minimal protobuf writer (for gRPC request bodies if ever needed, and for tests).
struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func writeTag(_ field: Int, _ wire: ProtobufReader.WireType) {
        writeVarint(UInt64(field << 3 | wire.rawValue))
    }

    mutating func write(_ field: Int, int64 value: Int64) {
        writeTag(field, .varint)
        writeVarint(UInt64(bitPattern: value))
    }

    mutating func write(_ field: Int, string value: String) {
        write(field, bytes: Array(value.utf8))
    }

    mutating func write(_ field: Int, bytes value: [UInt8]) {
        writeTag(field, .lengthDelimited)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func write(_ field: Int, message: ProtobufWriter) {
        write(field, bytes: message.bytes)
    }
}
