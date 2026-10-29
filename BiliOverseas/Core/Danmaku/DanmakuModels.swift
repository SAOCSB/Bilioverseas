import Foundation

/// How a danmaku is displayed. Derived from `DanmakuItem.mode`.
enum DanmakuKind: Equatable, Sendable {
    /// Modes 1–3 and 6 (reverse is shown as a normal right-to-left scroll), plus unknown modes.
    case scroll
    /// Mode 5.
    case top
    /// Mode 4.
    case bottom
    /// Modes 7 (JSON positioned), 8 (code) and 9 (BAS). Not rendered yet.
    case advanced
}

/// One danmaku (`DanmakuElem`), decoded from protobuf or the legacy XML, or sent locally.
struct DanmakuItem: Identifiable, Hashable, Sendable {
    /// dmid. Locally created items without a server id use negative ids.
    var id: Int64
    /// Appearance time in video seconds (millisecond precision).
    var time: Double
    /// 1–3 scroll, 4 bottom, 5 top, 6 reverse, 7 advanced, 8 code, 9 BAS.
    var mode: Int = 1
    /// Official sizes: 18 small, 25 standard, 36 large.
    var fontSize: Int = 25
    /// 24-bit RGB (`0xRRGGBB`).
    var color: UInt32 = 0xFFFFFF
    /// `crc32(sender mid)` as lower-case hex (not zero-padded).
    var midHash: String = ""
    var content: String = ""
    /// Unix seconds when it was sent.
    var ctime: Int64 = 0
    /// Cloud-block (智能云屏蔽) weight 0…11; higher = better quality.
    var weight: Int = 0
    /// 0 normal, 1 subtitle, 2 special (code / BAS).
    var pool: Int = 0
    /// Bit flags from the server.
    var attr: Int = 0
    /// `DmColorfulType`: 60001 = VIP gradient.
    var colorful: Int = 0
    var likeCount: Int64 = 0
    /// Sent by the logged-in user (gets a border, bypasses filters).
    var isSelf: Bool = false
    /// Uploader command danmaku.
    var isUp: Bool = false
    /// Number of merged duplicates this item stands for (1 = not merged).
    var count: Int = 1

    static let vipGradualColor = 60001

    var kind: DanmakuKind {
        switch mode {
        case 4: return .bottom
        case 5: return .top
        case 7, 8, 9: return .advanced
        default: return .scroll
        }
    }

    /// Any colour other than pure white (VIP gradient danmaku count as colourful too).
    var isColorful: Bool { (color & 0xFFFFFF) != 0xFFFFFF || colorful == DanmakuItem.vipGradualColor }
    var isVipGradient: Bool { colorful == DanmakuItem.vipGradualColor }

    /// Text shown on screen, including the merge counter.
    var displayText: String { count > 1 ? "\(content) ×\(count)" : content }

    init(id: Int64, time: Double, mode: Int = 1, fontSize: Int = 25, color: UInt32 = 0xFFFFFF,
         midHash: String = "", content: String, ctime: Int64 = 0, weight: Int = 0, pool: Int = 0,
         attr: Int = 0, colorful: Int = 0, likeCount: Int64 = 0, isSelf: Bool = false,
         isUp: Bool = false, count: Int = 1) {
        self.id = id
        self.time = time
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        self.midHash = midHash
        self.content = content
        self.ctime = ctime
        self.weight = weight
        self.pool = pool
        self.attr = attr
        self.colorful = colorful
        self.likeCount = likeCount
        self.isSelf = isSelf
        self.isUp = isUp
        self.count = count
    }
}

/// Decoded `DmSegMobileReply`.
struct DanmakuSegmentReply: Equatable, Sendable {
    var items: [DanmakuItem] = []
    /// 1 = the uploader closed danmaku for this video (「UP主已关闭弹幕」).
    var state: Int = 0
    var isClosed: Bool { state == 1 }

    static let empty = DanmakuSegmentReply()
}

/// Danmaku are served in 6-minute segments; `segment_index` is 1-based.
enum DanmakuSegment {
    static let duration: Double = 360

    /// `floor(ms / 360000) + 1`.
    static func index(for time: Double) -> Int {
        guard time.isFinite, time > 0 else { return 1 }
        return Int(min(time * 1000, 1e15).rounded(.down)) / 360_000 + 1
    }

    /// Video-time range covered by a segment.
    static func range(of index: Int) -> Range<Double> {
        let start = Double(max(index, 1) - 1) * duration
        return start..<(start + duration)
    }

    /// Number of segments for a video of `duration` seconds (at least 1).
    static func count(forDuration duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 1 }
        return max(1, Int((duration / self.duration).rounded(.up)))
    }
}

/// Sender hashes: Bilibili stores `crc32(String(mid))` as lower-case hex without zero padding.
enum DanmakuHash {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func crc32(_ string: String) -> UInt32 { crc32(Array(string.utf8)) }

    /// `mid_hash` of a user id.
    static func midHash(mid: Int64) -> String { String(crc32(String(mid)), radix: 16) }

    /// `midHash` for the user typed in a block list: digits = UID (hashed), otherwise taken as a hash.
    static func normalizeUserRule(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0.isASCII && $0.isNumber }), let mid = Int64(t) { return midHash(mid: mid) }
        let hex = t.hasPrefix("0x") ? String(t.dropFirst(2)) : t
        guard !hex.isEmpty, hex.count <= 8, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}
