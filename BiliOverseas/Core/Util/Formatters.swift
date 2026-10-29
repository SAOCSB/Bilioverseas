import Foundation

enum Fmt {
    /// 12345 → "1.2万", 123456789 → "1.2亿".
    static func count(_ n: Int64) -> String {
        if n >= 100_000_000 { return trim(Double(n) / 100_000_000) + "亿" }
        if n >= 10_000 { return trim(Double(n) / 10_000) + "万" }
        return String(max(0, n))
    }
    static func count(_ n: Int) -> String { count(Int64(n)) }

    private static func trim(_ d: Double) -> String {
        let s = String(format: "%.1f", d)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// 75 → "01:15", 3725 → "1:02:05".
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        return duration(Int(seconds))
    }

    /// Parses "12:34" / "1:02:03" / "754" into seconds.
    static func parseDuration(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Relative publish time like the official client: 刚刚 / 5分钟前 / 3小时前 / 昨天 / 03-12 / 2023-03-12.
    static func relativeDate(_ unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let diff = now.timeIntervalSince(date)
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        let cal = Calendar(identifier: .gregorian)
        if cal.isDateInYesterday(date) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now) ? "MM-dd" : "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func dateTime(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Bytes/second → "3.2 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func bytes(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.0f B", b)
    }

    /// Appends Bilibili's image-resize suffix (`@{w}w_{h}h_1c.webp`) to hdslb URLs.
    static func thumb(_ url: String, width: Int, height: Int? = nil) -> String {
        let u = url.biliHTTPS
        guard !u.isEmpty, u.contains("hdslb.com"), !u.contains("@"), !u.hasSuffix(".gif") else { return u }
        if let height { return u + "@\(width)w_\(height)h_1c.webp" }
        return u + "@\(width)w.webp"
    }
}

/// Bilibili AV/BV conversion (the 2024+ algorithm with 58-char table and XOR/MASK).
enum BVConverter {
    private static let table = Array("FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf")
    private static let xorCode: Int64 = 23442827791579
    private static let maskCode: Int64 = 2251799813685247
    private static let maxAid: Int64 = 1 << 51
    private static let base: Int64 = 58

    static func bv2av(_ bvid: String) -> Int64? {
        var chars = Array(bvid)
        guard chars.count == 12 else { return nil }
        chars.swapAt(3, 9)
        chars.swapAt(4, 7)
        var tmp: Int64 = 0
        for c in chars[3...] {
            guard let idx = table.firstIndex(of: c) else { return nil }
            tmp = tmp * base + Int64(idx)
        }
        return (tmp & maskCode) ^ xorCode
    }

    static func av2bv(_ aid: Int64) -> String {
        var bytes = Array("BV1000000000")
        var bvIndex = bytes.count - 1
        var tmp = (maxAid | aid) ^ xorCode
        while tmp > 0 {
            bytes[bvIndex] = table[Int(tmp % base)]
            tmp /= base
            bvIndex -= 1
        }
        bytes.swapAt(3, 9)
        bytes.swapAt(4, 7)
        return String(bytes)
    }
}
