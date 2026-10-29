// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. Port of `scr/utils.js` (+ `extractTimeFromText` from `scr/detectors.js`) @ master 3ce86fa
// (v2.1.0). Part of BiliOverseas (GPL-2.0-or-later).
//
// Besides the upstream utilities this file holds the JavaScript-semantics layer the port relies on:
//  * `SmartSkipRegex`: compiles the upstream JS regex sources VERBATIM after a mechanical
//    JS → ICU translation (`\d` `\D` `\s` `\S` `\w` `\W` `\b` `\B` `$` `.`), so ASCII-only digits,
//    the JS whitespace set, ASCII word boundaries and "end of input" behave exactly like V8.
//    Quantifiers count UTF-16 code units like JS: astral scalars are replaced by two BMP
//    placeholders before matching (UTF-16 offsets are unchanged, so match ranges map 1:1 back).
//  * `SmartSkipJS`: trim / includes / indexOf / slice on UTF-16, `Number()`, `parseFloat`,
//    `Math.round`, truthiness and an explicitly STABLE sort (Swift's `sort` is not stable).

import Foundation

// MARK: - JavaScript semantics

enum SmartSkipJS {
    /// Members of the JS `\s` class (WhiteSpace + LineTerminator), as an ICU set body.
    static let whitespaceClassBody = #"\t\n\u000B\f\r    -     　﻿"#

    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.prototype.trim()` (JS whitespace set, which includes U+FEFF unlike Foundation's).
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first...last])
    }

    /// `haystack.indexOf(needle)` in UTF-16 code units (code-unit exact, no canonical equivalence).
    static func indexOf(_ haystack: String, _ needle: String) -> Int {
        indexOf(Array(haystack.utf16), Array(needle.utf16))
    }

    static func indexOf(_ h: [UInt16], _ n: [UInt16]) -> Int {
        if n.isEmpty { return 0 }
        guard h.count >= n.count else { return -1 }
        let first = n[0]
        var i = 0
        let last = h.count - n.count
        while i <= last {
            if h[i] == first {
                var j = 1
                while j < n.count && h[i + j] == n[j] { j += 1 }
                if j == n.count { return i }
            }
            i += 1
        }
        return -1
    }

    /// `haystack.includes(needle)` (code-unit exact).
    static func includes(_ haystack: String, _ needle: String) -> Bool { indexOf(haystack, needle) >= 0 }

    /// `s.slice(start, end)` on UTF-16 code units, with JS negative-index semantics.
    static func slice(_ s: String, _ start: Int, _ end: Int? = nil) -> String {
        let u = Array(s.utf16)
        let len = u.count
        func clamp(_ v: Int) -> Int { v < 0 ? max(len + v, 0) : min(v, len) }
        let from = clamp(start)
        let to = clamp(end ?? len)
        guard from < to else { return "" }
        return String(decoding: u[from..<to], as: UTF16.self)
    }

    /// UTF-16 length (`s.length`).
    static func length(_ s: String) -> Int { s.utf16.count }

    /// JS truthiness of a number (`0`, `NaN` are falsy).
    static func truthy(_ x: Double) -> Bool { x != 0 && !x.isNaN }
    static func truthy(_ x: Double?) -> Bool { x.map(truthy) ?? false }

    /// `a || b` on numbers (used in comparator chains like `b.score - a.score || a.start - b.start`).
    static func or(_ a: Double, _ b: @autoclosure () -> Double) -> Double { truthy(a) ? a : b() }

    /// Stable sort with a JS-style numeric comparator (negative → `a` first; `0`/`NaN` → keep order).
    static func stableSorted<T>(_ items: [T], by comparator: (T, T) -> Double) -> [T] {
        items.enumerated().sorted { x, y in
            let c = comparator(x.element, y.element)
            if c < 0 { return true }
            if c > 0 { return false }
            return x.offset < y.offset
        }.map(\.element)
    }

    /// `[...new Set(strings)]` — ordered de-duplication with code-unit equality.
    static func unique(_ items: [String]) -> [String] {
        var seen = Set<[UInt16]>()
        var out: [String] = []
        for s in items where seen.insert(Array(s.utf16)).inserted { out.append(s) }
        return out
    }

    /// `Math.round` (round half toward +∞, exact for all doubles).
    static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let r = x.rounded(.down)
        return x - r >= 0.5 ? r + 1 : r
    }

    /// `Number.isSafeInteger`.
    static func isSafeInteger(_ x: Double) -> Bool {
        x.isFinite && x.rounded(.towardZero) == x && abs(x) <= 9_007_199_254_740_991
    }

    /// JS `Number(value)` for a lenient JSON value (used by `normalizeVideoInfo`). The `JSON` type
    /// cannot tell `null` from a missing key; both coercions (0 vs NaN) give the same results there.
    static func number(_ json: JSON) -> Double {
        switch json {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return number(s)
        case .array(let a):
            if a.isEmpty { return 0 }
            if a.count == 1 { return number(a[0]) }
            return .nan
        case .object: return .nan
        }
    }

    /// JS `Number(string)`: trims, `''` → 0, decimal / exponent / `0x` `0o` `0b` / `Infinity`.
    static func number(_ string: String) -> Double {
        let t = trim(string)
        if t.isEmpty { return 0 }
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = t.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let digits = String(t.dropFirst(2))
            guard !digits.isEmpty, let v = UInt64(digits, radix: radix) else { return .nan }
            return Double(v)
        }
        guard decimalLiteral.test(t), let d = Double(t) else { return .nan }
        return d
    }

    private static let decimalLiteral = SmartSkipRegex(#"^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$"#)
    private static let decimalPrefix = SmartSkipRegex(#"^[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)"#)

    /// JS `parseFloat(string)`: skips leading whitespace and parses the longest numeric prefix.
    static func parseFloat(_ string: String) -> Double {
        let s = String(string.unicodeScalars.drop(while: isWhitespace))
        guard let m = decimalPrefix.match(s), let text = m[0] else { return .nan }
        if text.hasSuffix("Infinity") { return text.hasPrefix("-") ? -.infinity : .infinity }
        return Double(text) ?? .nan
    }

    /// JS `String(number)` for the values this module formats (ids, keys, logs).
    static func numberString(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        if x == x.rounded(), abs(x) < 1e21 { return String(Int64(x)) }
        return "\(x)"
    }

    /// Replaces each astral scalar with two BMP placeholders so ICU counts UTF-16 code units like
    /// JS. UTF-16 offsets are preserved, so ranges found in the result apply to the original.
    static func utf16Equivalent(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value > 0xFFFF }) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value > 0xFFFF {
                out.append("\u{E000}")
                out.append("\u{E000}")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

// MARK: - Regex

/// One regex match, JS style: `self[0]` is the whole match, `self[n]` the n-th group
/// (`nil` = group did not participate, like `undefined`). `index` is the UTF-16 offset.
struct SmartSkipRegexMatch {
    let groups: [String?]
    let index: Int
    let length: Int
    subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
}

/// A JS regular expression (source written exactly as in the upstream code, without slashes)
/// compiled for ICU. Patterns are module constants; an invalid one is a programming error.
final class SmartSkipRegex {
    let source: String
    let icuPattern: String
    private let regex: NSRegularExpression

    init(_ source: String, ignoreCase: Bool = false) {
        self.source = source
        icuPattern = SmartSkipRegex.translate(source)
        do {
            regex = try NSRegularExpression(pattern: icuPattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            fatalError("SmartSkipRegex: invalid pattern \(source) → \(icuPattern): \(error)")
        }
    }

    private static let wordClass = "A-Za-z0-9_"
    private static let boundary = "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    private static let nonBoundary = "(?:(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<![A-Za-z0-9_])(?![A-Za-z0-9_]))"

    /// Mechanical JS (no `u` flag) → ICU translation. See spec §13.1.
    static func translate(_ js: String) -> String {
        let chars = Array(js.unicodeScalars)
        var out = ""
        var inClass = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "D": out += inClass ? #"\x{0}-/:-\x{10FFFF}"# : "[^0-9]"
                case "s": out += inClass ? SmartSkipJS.whitespaceClassBody : "[\(SmartSkipJS.whitespaceClassBody)]"
                case "S": out += "[^\(SmartSkipJS.whitespaceClassBody)]"
                case "w": out += inClass ? wordClass : "[\(wordClass)]"
                case "W": out += "[^\(wordClass)]"
                case "b": out += inClass ? #"\u0008"# : boundary
                case "B": out += nonBoundary
                default: out += "\\" + String(n)
                }
                i += 2
                continue
            }
            if inClass {
                switch c {
                case "]": inClass = false; out += "]"
                // Characters with a meaning in ICU set syntax but literal in a JS class.
                case "[", ":", "&", "$", "{", "}": out += "\\" + String(c)
                default: out.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "[":
                    inClass = true
                    out += "["
                    if i + 1 < chars.count, chars[i + 1] == "^" { out += "^"; i += 1 }
                case "$": out += #"\z"#
                case ".": out += #"[^\n\r  ]"#
                default: out.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        return out
    }

    private func nsMatches(_ subject: String, all: Bool) -> [NSTextCheckingResult] {
        let prepared = SmartSkipJS.utf16Equivalent(subject)
        let range = NSRange(location: 0, length: prepared.utf16.count)
        if all { return regex.matches(in: prepared, options: [], range: range) }
        return regex.firstMatch(in: prepared, options: [], range: range).map { [$0] } ?? []
    }

    private static func substring(_ ns: NSString, _ r: NSRange) -> String? {
        r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    private func convert(_ result: NSTextCheckingResult, _ ns: NSString) -> SmartSkipRegexMatch {
        let groups = (0..<result.numberOfRanges).map { SmartSkipRegex.substring(ns, result.range(at: $0)) }
        return SmartSkipRegexMatch(groups: groups, index: result.range.location, length: result.range.length)
    }

    /// `regex.test(s)` (non-global).
    func test(_ s: String) -> Bool { !nsMatches(s, all: false).isEmpty }

    /// `s.match(regex)` without the `g` flag: first (leftmost) match with groups.
    func match(_ s: String) -> SmartSkipRegexMatch? {
        guard let r = nsMatches(s, all: false).first else { return nil }
        return convert(r, s as NSString)
    }

    /// `s.match(regex)` WITH the `g` flag: every whole match, in order (`[]` instead of `null`).
    func matchAll(_ s: String) -> [String] {
        let ns = s as NSString
        return nsMatches(s, all: true).compactMap { SmartSkipRegex.substring(ns, $0.range) }
    }

    /// A global `exec` loop (`while ((m = re.exec(s)) !== null)`), all matches with groups.
    func execAll(_ s: String) -> [SmartSkipRegexMatch] {
        let ns = s as NSString
        return nsMatches(s, all: true).map { convert($0, ns) }
    }

    /// `s.split(regex)` for a capture-free separator.
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var start = 0
        for r in nsMatches(s, all: true) where r.range.length > 0 {
            out.append(ns.substring(with: NSRange(location: start, length: r.range.location - start)))
            start = r.range.location + r.range.length
        }
        out.append(ns.substring(from: start))
        return out
    }

    /// `s.replace(/…/g, replacement)` with a literal replacement.
    func replaceAll(_ s: String, with replacement: String) -> String {
        let matches = nsMatches(s, all: true)
        guard !matches.isEmpty else { return s }
        let ns = s as NSString
        var out = ""
        var start = 0
        for r in matches {
            out += ns.substring(with: NSRange(location: start, length: r.range.location - start))
            out += replacement
            start = r.range.location + r.range.length
        }
        out += ns.substring(from: start)
        return out
    }
}

// MARK: - utils.js

/// `TimeInfo` returned by `extractTimeFromText`.
struct SmartSkipTimeInfo: Equatable {
    var time: Double
    var confidence: Int = 1
    /// The matched time substring (used by `getTimestampSkipCues`).
    var reference: String
}

enum SmartSkipUtils {
    /// `log(...args)` — no-op unless `SmartSkipConstants.debug`. Never logs URLs or cookies.
    static func log(_ items: Any...) {
        guard SmartSkipConstants.debug else { return }
        print("[BiliSmartSkip]", items.map { "\($0)" }.joined(separator: " "))
    }

    /// `formatTime(s)` (logging only): `m:ss`, JS `Math.floor` and `%` (fmod) semantics.
    static func formatTime(_ s: Double) -> String {
        let m = (s / 60).rounded(.down)
        let sec = fmod(s, 60).rounded(.down)
        var secText = SmartSkipJS.numberString(sec)
        while secText.utf16.count < 2 { secText = "0" + secText }
        return "\(SmartSkipJS.numberString(m)):\(secText)"
    }

    private static let zhDigits: [String: Double] = [
        "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let asciiDigits = SmartSkipRegex(#"^\d+$"#)
    private static let zeroPrefixed = SmartSkipRegex(#"^零[一二三四五六七八九]$"#)

    /// `zhNumToInt(str)`: `'05'`→5, `'零五'`→5, `'十'`→10, `'十五'`→15, `'二十'`→20, `'二十五'`→25.
    /// Returns `NaN` where JS returns `undefined` (unknown numeral).
    static func zhNumToInt(_ str: String) -> Double {
        if asciiDigits.test(str) { return SmartSkipJS.number(str) }
        if zeroPrefixed.test(str) { return zhDigits[SmartSkipJS.slice(str, 1, 2)] ?? .nan }
        if str == "十" { return 10 }
        if SmartSkipJS.includes(str, "十") {
            let parts = str.components(separatedBy: "十")
            let left = parts[0], right = parts.count > 1 ? parts[1] : ""
            let tens = left.isEmpty ? 1 : (zhDigits[left] ?? .nan)
            let ones = right.isEmpty ? 0 : (zhDigits[right] ?? .nan)
            return tens * 10 + ones
        }
        return zhDigits[str] ?? .nan
    }

    // `extractTimeFromText` regexes (detectors.js), verbatim.
    private static let clockTime = SmartSkipRegex(#"(?:^|\D)((\d{1,2})[:;：；](\d{2}))(?!\d)"#)
    private static let chineseTime = SmartSkipRegex(#"(?:^|\D)(([一二三四五六七八九]?十[一二三四五六七八九]?|[零一二三四五六七八九]|\d{1,2})分([一二三四五六七八九]?十[一二三四五六七八九]?|零[一二三四五六七八九]|[零一二三四五六七八九]|\d{1,2})秒?)(?!\d)"#)
    private static let engineeringCode = SmartSkipRegex(#"(?:^|\D)((\d{1,2})(\d{2})工程)"#)

    /// `extractTimeFromText(text)` (detectors.js): first format that matches wins; a match whose
    /// seconds are ≥ 60 returns `nil` WITHOUT trying the next format (formats 1 and 2).
    /// `10.5分钟` is NOT supported (exactly like master, despite the upstream README).
    static func extractTimeFromText(_ text: String) -> SmartSkipTimeInfo? {
        if let m1 = clockTime.match(text) {
            let minutes = Double(m1[2]!)!, seconds = Double(m1[3]!)!
            return seconds < 60 ? SmartSkipTimeInfo(time: minutes * 60 + seconds, reference: m1[1]!) : nil
        }
        if let m2 = chineseTime.match(text) {
            let seconds = zhNumToInt(m2[3]!)
            return seconds < 60
                ? SmartSkipTimeInfo(time: zhNumToInt(m2[2]!) * 60 + seconds, reference: m2[1]!) : nil
        }
        // "705工程", "0705工程" → 7:05
        if let m3 = engineeringCode.match(text) {
            let seconds = Double(m3[3]!)!
            if seconds < 60 { return SmartSkipTimeInfo(time: Double(m3[2]!)! * 60 + seconds, reference: m3[1]!) }
        }
        return nil
    }
}
