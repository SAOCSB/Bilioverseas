import Foundation

/// A parsed mode-7 danmaku (「高级弹幕」: positioned, optionally moving / fading / rotated text).
///
/// The content is a JSON array
/// `[x, y, "alphaFrom-alphaTo", lifetime, text, rotateZ, rotateY, toX, toY, moveDuration, moveDelay, stroke, font, easing, path]`;
/// only the first five are required. Lifetime is in seconds, move duration and delay in milliseconds.
/// Coordinates: a decimal up to 1 is a fraction of the player size; an integer (or anything above 1) is in pixels
/// of Bilibili's 682 × 438 reference player (DanmakuFlameMaster `BILI_PLAYER_WIDTH/HEIGHT`). Path animations and
/// custom fonts are not supported: the text moves in a straight line from (x, y) to (toX, toY).
struct DanmakuAdvancedSpec: Equatable, Sendable {
    /// Reference player size for pixel coordinates.
    static let referenceWidth: Double = 682
    static let referenceHeight: Double = 438
    /// Used when the lifetime is missing or invalid.
    static let defaultDuration: Double = 4.5

    /// Fractions of the player width / height (top-left corner of the text).
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
    var startAlpha: Double = 1
    var endAlpha: Double = 1
    /// Seconds on screen.
    var duration: Double
    /// Text with real line breaks (Bilibili writes them as `/n`).
    var text: String
    /// Degrees.
    var rotateZ: Double = 0
    var rotateY: Double = 0
    /// Seconds the move from start to end takes, after `moveDelay`.
    var moveDuration: Double
    var moveDelay: Double = 0
    var hasStroke: Bool = true
    /// 「线性加速」: ease in (cubic) instead of a linear move.
    var easeIn: Bool = false

    var isMoving: Bool { startX != endX || startY != endY }

    /// Top-left position (fractions) `elapsed` seconds after the item appeared.
    func position(at elapsed: Double) -> (x: Double, y: Double) {
        guard isMoving, elapsed > moveDelay else { return (startX, startY) }
        var p = min(1, (elapsed - moveDelay) / max(moveDuration, 0.001))
        if easeIn { p = p * p * p }
        return (startX + (endX - startX) * p, startY + (endY - startY) * p)
    }

    /// Opacity 0…1 `elapsed` seconds after the item appeared (linear over the lifetime).
    func alpha(at elapsed: Double) -> Double {
        let p = min(max(elapsed / max(duration, 0.001), 0), 1)
        return min(max(startAlpha + (endAlpha - startAlpha) * p, 0), 1)
    }

    /// nil when the content is not a usable mode-7 array.
    static func parse(_ content: String) -> DanmakuAdvancedSpec? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        // Raw line breaks inside the text string are not valid JSON; escape them only when the plain parse fails
        // (a break between two elements would break the escaped form instead).
        guard let list = jsonArray(trimmed) ?? jsonArray(trimmed.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")),
            list.count >= 5
        else { return nil }

        let rawText = (list[4] as? String) ?? number(list[4]).map { String($0) } ?? ""
        let text = rawText.replacingOccurrences(of: "/n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let x = coordinate(list[0], reference: referenceWidth),
              let y = coordinate(list[1], reference: referenceHeight)
        else { return nil }

        var duration = number(list[3]) ?? defaultDuration
        if !duration.isFinite || duration <= 0 { duration = defaultDuration }
        let alphas = alphaRange(list[2])
        var spec = DanmakuAdvancedSpec(startX: x, startY: y, endX: x, endY: y,
                                       startAlpha: alphas.from, endAlpha: alphas.to, duration: duration,
                                       text: text, moveDuration: duration)
        spec.rotateZ = element(list, 5).flatMap(number).flatMap(finite) ?? 0
        spec.rotateY = element(list, 6).flatMap(number).flatMap(finite) ?? 0
        if let toX = element(list, 7).flatMap({ coordinate($0, reference: referenceWidth) }) { spec.endX = toX }
        if let toY = element(list, 8).flatMap({ coordinate($0, reference: referenceHeight) }) { spec.endY = toY }
        // A missing or zero move duration spans the whole lifetime (DanmakuFlameMaster).
        if let ms = element(list, 9).flatMap(number).flatMap(finite), ms > 0 { spec.moveDuration = ms / 1000 }
        if let ms = element(list, 10).flatMap(number).flatMap(finite), ms > 0 { spec.moveDelay = ms / 1000 }
        if let stroke = element(list, 11) { spec.hasStroke = flag(stroke) }
        if let easing = element(list, 13) { spec.easeIn = flag(easing) }
        return spec
    }

    // MARK: Parsing helpers

    private static func jsonArray(_ s: String) -> [Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    private static func element(_ list: [Any], _ index: Int) -> Any? {
        guard index < list.count, !(list[index] is NSNull) else { return nil }
        if let s = list[index] as? String, s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return list[index]
    }

    private static func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }

    private static func number(_ v: Any) -> Double? {
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let b = v as? Bool { return b ? 1 : 0 }
        return nil
    }

    private static func flag(_ v: Any) -> Bool {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces).lowercased() == "true" || Double(s) == 1 }
        return number(v) == 1
    }

    /// Fraction of the player size: decimals up to 1 as they are, pixels (integers, or anything above 1) divided by
    /// the reference size.
    private static func coordinate(_ raw: Any, reference: Double) -> Double? {
        guard let v = number(raw), v.isFinite else { return nil }
        let isPixel: Bool
        if let s = raw as? String {
            isPixel = v > 1 || !s.contains(".")
        } else {
            isPixel = v > 1
        }
        return isPixel ? v / reference : v
    }

    /// `"1-0.2"` → (1, 0.2); a single number is a constant opacity.
    private static func alphaRange(_ raw: Any) -> (from: Double, to: Double) {
        func clamp(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } }
        if let s = raw as? String {
            let parts = s.split(separator: "-", omittingEmptySubsequences: true)
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            let from = clamp(parts.first ?? nil) ?? 1
            let to = parts.count > 1 ? clamp(parts[1]) ?? from : from
            return (from, to)
        }
        let a = clamp(number(raw)) ?? 1
        return (a, a)
    }
}

extension DanmakuItem {
    /// Text for lists, copying and keyword rules: the visible text of a mode-7 item, `content` otherwise.
    var readableText: String {
        guard mode == 7, let spec = DanmakuAdvancedSpec.parse(content) else { return content }
        return spec.text
    }

    /// Server actions (点赞 / 举报 / 撤回) need the dmid; locally inserted items without one have id ≤ 0.
    var hasServerID: Bool { id > 0 }
}

/// 「跳转」 targets written in danmaku text, e.g. 「3:25 高能」 or 「1：02：03」 (features.md §8.6).
enum DanmakuTimestamp {
    private static let regex = try? NSRegularExpression(pattern: "(?:\\d+[:：])?\\d+[:：][0-5]?\\d(?!\\d)")

    /// Seconds of the first timestamp in `text` when it lies within `(0, duration)`; with an unknown duration
    /// (≤ 0) any positive time is accepted.
    static func seconds(in text: String, duration: Double) -> Double? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text)
        else { return nil }
        let parts = text[r].split(whereSeparator: { $0 == ":" || $0 == "：" }).compactMap { Double(String($0)) }
        guard (2...3).contains(parts.count) else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        guard seconds > 0, duration <= 0 || seconds < duration else { return nil }
        return seconds
    }
}
