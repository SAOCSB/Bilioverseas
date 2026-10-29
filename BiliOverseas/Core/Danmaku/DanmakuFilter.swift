import Foundation

/// Pure danmaku filter built from `DanmakuSettings`.
///
/// Order (per segment batch): own danmaku bypass everything; then type blocks (scroll / top /
/// bottom / colourful / advanced), cloud-block weight, user block rules (keyword substring and
/// `/regex/`, both case-insensitive; sender midHash); finally duplicate merging. The maximum
/// on-screen density is enforced by the renderer.
struct DanmakuFilter {
    let hideScroll: Bool
    let hideTop: Bool
    let hideBottom: Bool
    let hideColorful: Bool
    let hideAdvanced: Bool
    let cloudBlockLevel: Int
    let mergeDuplicates: Bool
    let mergeWindow: Double
    /// Lower-cased plain keywords.
    let keywords: [String]
    /// Compiled `/regex/` rules (invalid patterns are dropped).
    let regexes: [NSRegularExpression]
    let blockedUsers: Set<String>
    /// `crc32(mid)` of the logged-in user, to recognise own danmaku.
    let selfMidHash: String?

    init(settings: DanmakuSettings, selfMidHash: String? = nil) {
        hideScroll = settings.hideScroll
        hideTop = settings.hideTop
        hideBottom = settings.hideBottom
        hideColorful = settings.hideColorful
        hideAdvanced = settings.hideAdvanced
        cloudBlockLevel = settings.cloudBlockLevel
        mergeDuplicates = settings.mergeDuplicates
        mergeWindow = settings.mergeWindow
        var kws: [String] = []
        var res: [NSRegularExpression] = []
        for rule in settings.blockedKeywords {
            if let pattern = DanmakuFilter.regexPattern(from: rule) {
                if let re = DanmakuFilter.compiledRegex(pattern) { res.append(re) }
            } else {
                let kw = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !kw.isEmpty { kws.append(kw) }
            }
        }
        keywords = kws
        regexes = res
        blockedUsers = Set(settings.blockedUsers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        let me = selfMidHash?.lowercased() ?? ""
        self.selfMidHash = me.isEmpty ? nil : me
    }

    // MARK: Single item

    func isOwn(_ item: DanmakuItem) -> Bool {
        if item.isSelf { return true }
        guard let selfMidHash, !item.midHash.isEmpty else { return false }
        return item.midHash.lowercased() == selfMidHash
    }

    /// Type / colour blocks.
    func passesType(_ item: DanmakuItem) -> Bool {
        switch item.kind {
        case .scroll: if hideScroll { return false }
        case .top: if hideTop { return false }
        case .bottom: if hideBottom { return false }
        case .advanced: if hideAdvanced { return false }
        }
        if hideColorful, item.isColorful { return false }
        return true
    }

    /// Cloud-block level and user rules.
    func passesRules(_ item: DanmakuItem) -> Bool {
        if cloudBlockLevel > 0, !item.isUp, item.weight < cloudBlockLevel { return false }
        if !blockedUsers.isEmpty, blockedUsers.contains(item.midHash.lowercased()) { return false }
        if !keywords.isEmpty {
            let lower = item.content.lowercased()
            for kw in keywords where lower.contains(kw) { return false }
        }
        if !regexes.isEmpty {
            let text = item.content
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for re in regexes where re.firstMatch(in: text, options: [], range: range) != nil { return false }
        }
        return true
    }

    /// Whether a single danmaku may be shown (own danmaku always pass).
    func shouldShow(_ item: DanmakuItem) -> Bool {
        if isOwn(item) { return true }
        return passesType(item) && passesRules(item)
    }

    // MARK: Batch

    /// Filters a batch (sorted by time), marks own danmaku and merges duplicates if enabled.
    func apply(_ items: [DanmakuItem]) -> [DanmakuItem] {
        var out: [DanmakuItem] = []
        out.reserveCapacity(items.count)
        for var item in items {
            if isOwn(item) {
                item.isSelf = true
                out.append(item)
            } else if passesType(item), passesRules(item) {
                out.append(item)
            }
        }
        return mergeDuplicates ? DanmakuFilter.merge(out, window: mergeWindow) : out
    }

    /// Collapses identical (normalised) content: later duplicates within `window` seconds of the
    /// group's first item are dropped and counted on the first. `window <= 0` merges the whole batch.
    /// Own danmaku are never merged. Input must be sorted by time.
    static func merge(_ items: [DanmakuItem], window: Double) -> [DanmakuItem] {
        var out: [DanmakuItem] = []
        out.reserveCapacity(items.count)
        var groups: [String: (index: Int, time: Double)] = [:]
        for item in items {
            if item.isSelf { out.append(item); continue }
            let key = normalizedContent(item.content)
            if key.isEmpty { out.append(item); continue }
            if let g = groups[key], window <= 0 || item.time - g.time <= window {
                out[g.index].count += max(1, item.count)
                continue
            }
            groups[key] = (out.count, item.time)
            out.append(item)
        }
        return out
    }

    /// Lower-cased, full-width ASCII folded to half-width, all whitespace removed.
    static func normalizedContent(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            var v = u.value
            if v == 0x3000 { continue }
            if (0xFF01...0xFF5E).contains(v) { v -= 0xFEE0 }
            guard let scalar = Unicode.Scalar(v) else { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    // MARK: Regex rules

    /// `"/abc/"` → `"abc"`; nil for plain keywords (or an empty pattern).
    static func regexPattern(from rule: String) -> String? {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.hasPrefix("/"), t.hasSuffix("/") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    private static let regexLock = NSLock()
    private static var regexCache: [String: NSRegularExpression?] = [:]

    /// Case-insensitive compiled regex, cached across filters. Invalid patterns return nil.
    static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        if regexCache.count > 512 { regexCache.removeAll() }
        regexCache[pattern] = .some(re)
        return re
    }

    static func isValidRegex(_ pattern: String) -> Bool { compiledRegex(pattern) != nil }

    /// True when a settings change requires re-filtering already loaded danmaku.
    static func filterFieldsChanged(_ a: DanmakuSettings, _ b: DanmakuSettings) -> Bool {
        a.hideScroll != b.hideScroll || a.hideTop != b.hideTop || a.hideBottom != b.hideBottom
            || a.hideColorful != b.hideColorful || a.hideAdvanced != b.hideAdvanced
            || a.cloudBlockLevel != b.cloudBlockLevel || a.mergeDuplicates != b.mergeDuplicates
            || a.mergeWindow != b.mergeWindow || a.blockedKeywords != b.blockedKeywords
            || a.blockedUsers != b.blockedUsers
    }
}

extension DanmakuSettings {
    /// Base danmaku font size in points (PiliPlus mobile).
    static let baseFontSize: Double = 15

    /// Font size in points for the current presentation.
    func resolvedFontSize(fullscreen: Bool) -> Double {
        let scale = fullscreen ? fontScaleFullscreen : fontScale
        return DanmakuSettings.baseFontSize * min(max(scale, 0.5), 2.5)
    }

    /// 「弹幕速度」 presets: label and scroll duration in seconds (slower → faster).
    static let speedPresets: [(title: String, duration: Double)] = [
        ("极慢", 11), ("较慢", 9), ("适中", 7), ("较快", 5.5), ("极快", 4),
    ]

    /// Index into `speedPresets` closest to `scrollDuration`.
    var speedPresetIndex: Int {
        var best = 0
        var bestDiff = Double.infinity
        for (i, p) in DanmakuSettings.speedPresets.enumerated() {
            let d = abs(p.duration - scrollDuration)
            if d < bestDiff { best = i; bestDiff = d }
        }
        return best
    }

    /// Resets every display option to its default but keeps the user's block lists.
    mutating func resetDisplayOptions() {
        var fresh = DanmakuSettings()
        fresh.blockedKeywords = blockedKeywords
        fresh.blockedUsers = blockedUsers
        fresh.blockedUserLabels = blockedUserLabels
        fresh.cloudRuleIds = cloudRuleIds
        fresh.cloudUserRuleIds = cloudUserRuleIds
        fresh.cloudRulesMid = cloudRulesMid
        fresh.enabled = enabled
        self = fresh
    }
}
