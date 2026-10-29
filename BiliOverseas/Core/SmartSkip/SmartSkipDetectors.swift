// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. 1:1 port of `scr/detectors.js` @ master 3ce86fa (v2.1.0): same function names, call
// graph, regexes (verbatim JS sources, see `SmartSkipRegex`), keyword lists and thresholds.
// `extractTimeFromText` lives in `SmartSkipUtils` (time parsing). Part of BiliOverseas
// (GPL-2.0-or-later).

import Foundation

enum SmartSkipDetectors {

    // MARK: - Detection: Chapter markers

    private static let labelNegation = SmartSkipRegex(
        #"(?:无|没有|不含|不是|非|拒绝)\s*(?:任何)?(?:广告|赞助|推广|商单)|\b(?:no|without)\s+(?:ads?|sponsors?(?:hip)?)|\bad[\s-]?free\b"#,
        ignoreCase: true)
    private static let labelWords = ["广告", "赞助", "商单", "恰饭", "推广"]
    private static let labelEnglish = SmartSkipRegex(#"\b(?:ads?|sponsor(?:ed|ship)?)\b"#)
    private static let labelExplicitWhole = SmartSkipRegex(#"^(?:广告|赞助|商单|恰饭|推广|ads?|sponsored|sponsor(?:ship)?)$"#)
    private static let labelExplicitPrefix = SmartSkipRegex(
        #"^(?:广告(?:时间|环节|片段)|赞助(?:商介绍|环节)|商单环节|恰饭(?:时间|环节)|推广(?:时间|环节)|sponsored (?:segment|message))(?:$|\s*[:：|—–-]|\s*[（(])"#)
    private static let labelExplicitSuffix = SmartSkipRegex(#"[（(]\s*(?:广告|赞助|商单|恰饭|推广|ad|sponsored)\s*[）)]$"#)

    /// `getAdLabelEvidence(value)`: whole English words only ("download", "shadow", "adapter" are
    /// not ad labels); a discussion *about* advertising is only a candidate (needs confirmation).
    static func getAdLabelEvidence(_ value: String) -> SmartSkipLabelEvidence? {
        let label = SmartSkipJS.trim(value).lowercased()
        if labelNegation.test(label) { return nil }
        var matchedKeywords = labelWords.filter { SmartSkipJS.includes(label, $0) }
        matchedKeywords += labelEnglish.matchAll(label)
        if matchedKeywords.isEmpty { return nil }
        let explicit = labelExplicitWhole.test(label) || labelExplicitPrefix.test(label) || labelExplicitSuffix.test(label)
        return SmartSkipLabelEvidence(matchedKeywords: SmartSkipJS.unique(matchedKeywords),
                                      requiresConfirmation: !explicit,
                                      reason: explicit ? "explicit-ad-label" : "ambiguous-ad-label")
    }

    private static func candidate(start: Double, end: Double, _ evidence: SmartSkipLabelEvidence) -> SmartSkipSegment {
        SmartSkipSegment(start: start, end: end, requiresConfirmation: evidence.requiresConfirmation,
                         reason: evidence.reason, matchedKeywords: evidence.matchedKeywords)
    }

    /// `detectFromChapters(viewPoints)`: the FIRST explicit chapter wins (even if the caller later
    /// rejects it); the first ambiguous one is the fallback.
    static func detectFromChapters(_ viewPoints: [VideoChapter]?) -> SmartSkipSegment? {
        guard let viewPoints, !viewPoints.isEmpty else { return nil }
        var uncertain: SmartSkipSegment?
        for chapter in viewPoints {
            guard let evidence = getAdLabelEvidence(chapter.title) else { continue }
            let c = candidate(start: chapter.from, end: chapter.to, evidence)
            if !evidence.requiresConfirmation { return c }
            if uncertain == nil { uncertain = c }
        }
        return uncertain
    }

    // MARK: - Detection: Description timestamps

    /// No `m` flag: `^` is the start of the string only; `\s` may span newlines (quirk kept).
    private static let descriptionEntry = SmartSkipRegex(#"(?:^|\n)\s*(\d{1,2}):(\d{2})\s+(.+)"#)

    /// `detectFromDescription(desc, duration)`: `m:ss label` lines; an entry ends at the next
    /// entry (the last one at the video duration).
    static func detectFromDescription(_ desc: String, _ duration: Double) -> SmartSkipSegment? {
        if desc.isEmpty { return nil }
        var entries: [(time: Double, label: String)] = []
        for m in descriptionEntry.execAll(desc) {
            let minutes = Double(m[1]!)!, seconds = Double(m[2]!)!
            if seconds >= 60 { continue }
            entries.append((minutes * 60 + seconds, SmartSkipJS.trim(m[3]!)))
        }
        if entries.count < 2 { return nil }
        var uncertain: SmartSkipSegment?
        for i in entries.indices {
            guard let evidence = getAdLabelEvidence(entries[i].label) else { continue }
            let start = entries[i].time
            let end = i + 1 < entries.count ? entries[i + 1].time : duration
            let c = candidate(start: start, end: end, evidence)
            if !evidence.requiresConfirmation { return c }
            if uncertain == nil { uncertain = c }
        }
        return uncertain
    }

    // MARK: - Detection: Local subtitle evidence (always needs confirmation)

    /// Phrase roles; iteration order = this order (JS object key order).
    private static let subtitlePatterns: [(category: String, pattern: SmartSkipRegex)] = [
        ("sponsor", SmartSkipRegex(
            #"(?:本期(?:视频|节目)?|本视频|本节目|这个视频|这期视频).{0,8}由.{1,24}(?:赞助|冠名)|感谢.{1,24}(?:赞助|冠名)|(?:本期|今天).{0,8}赞助商|sponsoredby"#,
            ignoreCase: true)),
        ("cta", SmartSkipRegex(
            #"(?:评论区|蓝链|链接).{0,14}(?:领券|福利|优惠|下单|购买)|领券.{0,12}(?:评论区|蓝链|链接)|(?:一键|立即|现在|赶紧|快来|直接).{0,6}(?:下单|抢购|领券)"#)),
        ("route", routePattern),
        ("offer", SmartSkipRegex(
            #"优惠券|优惠码|折扣码|领券|(?:新人|新用户|专属|限时).{0,8}(?:优惠|折扣|福利)|(?:免费|限时).{0,6}(?:试用|体验)|(?:购买|下单).{0,8}(?:赠送|立减|优惠)"#)),
        ("pitch", SmartSkipRegex(#"优惠|折扣|福利|旗舰店|包邮|到手价"#)),
    ]
    private static let routePattern = SmartSkipRegex(
        #"(?:点击|点开|扫描|(?:可以|快来|请)点).{0,12}(?:蓝链|链接|二维码)|(?:评论区|蓝链|链接).{0,14}(?:领取|下载)"#)
    private static let subtitleNegation = SmartSkipRegex(
        #"(?:无|没有|不含|不是|并非|拒绝).{0,4}(?:广告|赞助|推广|商单)|(?:不是|并非|没有).{0,24}(?:赞助|冠名)|(?:不要|别|切勿|请勿|禁止|无需|不必|不能|不建议).{0,12}(?:点击|下载|购买|下单|领取|领券|赞助)"#)
    private static let routeCommercial = SmartSkipRegex(#"商品|购买|下单|会场|领券|优惠券"#)
    static let whitespaceRun = SmartSkipRegex(#"\s+"#)
    private static let subtitleClauseSeparator = SmartSkipRegex(#"[。！？!?；;，,]"#)
    private static let trailingNegation = SmartSkipRegex(#"(?:不要|别|切勿|请勿|禁止|无需|不必|不能|不建议)$"#)

    /// `getSubtitleEvidence(content)`: per clause (split on `。！？!?；;，,` incl. commas); a negated
    /// clause is skipped entirely, other clauses of the same row still count.
    static func getSubtitleEvidence(_ content: String) -> SmartSkipSubtitleEvidence {
        var categories: [String] = [], matched: [String] = []
        let value = whitespaceRun.replaceAll(content.lowercased(), with: "")
        for clause in subtitleClauseSeparator.split(value) {
            if subtitleNegation.test(clause) { continue }
            for (category, pattern) in subtitlePatterns {
                if let match = pattern.match(clause) {
                    categories.append(category)
                    matched.append(match[0]!)
                }
            }
            // A teaching/resource link alone is not an ad. Commercial objects can
            // qualify a route within this clause, but never bridge later narrative.
            if routePattern.test(clause), let commercial = routeCommercial.match(clause) {
                categories.append("cta")
                matched.append(commercial[0]!)
            }
        }
        return SmartSkipSubtitleEvidence(categories: SmartSkipJS.unique(categories), matched: SmartSkipJS.unique(matched))
    }

    private static func anchors(_ evidence: SmartSkipSubtitleEvidence) -> Bool {
        evidence.categories.contains { $0 == "cta" || $0 == "sponsor" || $0 == "route" }
    }

    /// `detectFromSubtitles(subtitleLines, danmaku)` (danmaku is unused, as upstream). Always
    /// `requiresConfirmation: true`; `score` is used for ranking and stripped from the result.
    static func detectFromSubtitles(_ subtitleLines: [SubtitleLine]?, _ danmaku: [SmartSkipDanmaku] = []) -> SmartSkipSegment? {
        guard let subtitleLines else { return nil }
        let lines = SmartSkipJS.stableSorted(subtitleLines.filter {
            $0.from.isFinite && $0.to.isFinite && $0.from >= 0 && $0.to > $0.from
        }) { $0.from - $1.from }
        // Adjacent-row checks reuse classification instead of rescanning each row twice.
        let evidenceByLine = lines.map { getSubtitleEvidence($0.content) }

        struct Hit { var from: Double; var to: Double; var index: Int; var lastIndex: Int; var evidence: SmartSkipSubtitleEvidence }
        var hits: [Hit] = []
        for index in lines.indices {
            let line = lines[index]
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            let previous = index > 0 ? lines[index - 1] : nil
            var continuedNegation = false
            if let previous, line.from - previous.to <= 1.5, trailingNegation.test(SmartSkipJS.trim(previous.content)) {
                continuedNegation = true
            }
            var evidence = continuedNegation
                ? getSubtitleEvidence(previous!.content + line.content) : evidenceByLine[index]
            var to = line.to, lastIndex = index
            // Subtitle wrapping may split a single instruction into two adjacent rows.
            if !continuedNegation, let next, next.from - line.to <= 1.5, !anchors(evidence) {
                let nextEvidence = evidenceByLine[index + 1]
                let joined = getSubtitleEvidence(line.content + next.content)
                if !anchors(nextEvidence) && anchors(joined) {
                    evidence = joined
                    to = next.to
                    lastIndex += 1
                }
            }
            if !evidence.categories.isEmpty {
                hits.append(Hit(from: line.from, to: to, index: index, lastIndex: lastIndex, evidence: evidence))
            }
        }

        var groups: [[Hit]] = []
        for hit in hits {
            // Local continuity: at most eight neutral rows / 20 seconds between evidence.
            // A plain "购买" in the next topic cannot keep the ad interval alive.
            if let group = groups.last, let previous = group.last,
               !(hit.from - previous.to > 20 || hit.index - previous.lastIndex > 9 || hit.to - group[0].from > 120) {
                groups[groups.count - 1].append(hit)
            } else {
                groups.append([hit])
            }
        }

        var candidates: [(segment: SmartSkipSegment, score: Double)] = []
        for group in groups {
            let categories = SmartSkipJS.unique(group.flatMap(\.evidence.categories))
            let hasCommercialContext = categories.contains { $0 == "sponsor" || $0 == "offer" || $0 == "pitch" }
            let ctaCount = group.filter {
                $0.evidence.categories.contains("cta") || (hasCommercialContext && $0.evidence.categories.contains("route"))
            }.count
            if ctaCount == 0 && !(categories.contains("sponsor") && categories.contains("offer")) { continue }
            var start = group[0].from, end = group[group.count - 1].to
            let boundaryPaddingSeconds: Double = end - start < 10 ? 5 : 0
            // A short CTA is a nearby manual hint, never a guessed 60–120 second ad.
            // The bounded context is inferred and is explicitly included in diagnostics.
            start = max(0, start - boundaryPaddingSeconds)
            end += boundaryPaddingSeconds
            let segment = SmartSkipSegment(
                start: start, end: end, requiresConfirmation: true,
                reason: ctaCount > 0 ? "subtitle-local-cta" : "subtitle-sponsor-offer",
                matchedKeywords: SmartSkipJS.unique(group.flatMap(\.evidence.matched)),
                evidenceCategories: categories, boundaryPaddingSeconds: boundaryPaddingSeconds)
            let score = Double(ctaCount * 4) + (categories.contains("sponsor") ? 3 : 0) + (categories.contains("offer") ? 2 : 0)
            candidates.append((segment, score))
        }
        let sorted = SmartSkipJS.stableSorted(candidates) { a, b in
            SmartSkipJS.or(b.score - a.score, a.segment.start - b.segment.start)
        }
        SmartSkipUtils.log("subtitle local candidates:", sorted.map(\.segment))
        return sorted.first?.segment
    }

    // MARK: - Detection: Danmaku time-format parsing

    private static let adKeywordPattern = SmartSkipRegex(#"广告|恰饭|接广|商单|赞助"#)
    private static let earlyAdOpening = SmartSkipRegex(#"^(?:恭喜(?:又)?接广|(?:广告|恰饭)(?:开始|时间|环节))[！!，,。\s]"#)
    private static let earlyAdCues: Set<String> = ["跳过广告", "广告结束", "广告完了", "恰饭结束"]

    /// `findAdTimestamps(danmaku, duration = 0)`: groups comments by rounded destination; the winner
    /// is trusted iff at least one comment for it carried an explicit skip cue.
    static func findAdTimestamps(_ danmaku: [SmartSkipDanmaku], _ duration: Double = 0) -> SmartSkipSegment? {
        struct Pair { var start: Double; var end: Double; var explicit: Bool; var cues: [String]; var earlyAdEvidence: Bool; var adKeywords: [String] }
        var groups: [(end: Double, pairs: [Pair])] = []   // insertion-ordered Map keyed by rounded end

        for d in danmaku {
            let start = d.time
            let text = d.textContent
            let endInfo = SmartSkipUtils.extractTimeFromText(text)
            guard let endInfo, start.isFinite, start >= 0 else { continue }
            let candidate = SmartSkipSegment(start: start + 5, end: endInfo.time)
            // A time reference alone can be a discussion of the video, not a skip instruction.
            let cues = getTimestampSkipCues(text, endInfo.reference)
            let explicit = !cues.isEmpty
            // Early sponsor breaks exist. Keep the opening guard for generic jumps, but
            // accept a bounded instruction that explicitly identifies an advertisement.
            let adKeywords = adKeywordPattern.matchAll(text)
            let earlyAdEvidence = explicit
                && (cues.contains { earlyAdCues.contains($0) } || earlyAdOpening.test(SmartSkipJS.trim(text)))
            if !checkAdSegVaild(candidate, duration, earlyAdEvidence) { continue }
            // Short, explicit instructions still qualify when the final interval passes the
            // normal 10-second minimum; a bare timestamp keeps the conservative 30-second gap.
            if !explicit && endInfo.time - start < 30 { continue }
            let end = SmartSkipJS.round(endInfo.time)
            let pair = Pair(start: candidate.start, end: end, explicit: explicit, cues: cues,
                            earlyAdEvidence: earlyAdEvidence, adKeywords: adKeywords)
            if let i = groups.firstIndex(where: { $0.end == end }) { groups[i].pairs.append(pair) } else { groups.append((end, [pair])) }
        }

        let candidates: [SmartSkipSegment] = groups.map { group in
            let pairs = group.pairs
            let explicitPairs = pairs.filter(\.explicit)
            // Do not extend a reliable interval using earlier, unrelated time mentions.
            let supportingPairs = explicitPairs.isEmpty ? pairs : explicitPairs
            return SmartSkipSegment(
                start: supportingPairs.map(\.start).min()!, end: pairs[0].end,
                requiresConfirmation: explicitPairs.isEmpty,
                reason: explicitPairs.isEmpty ? "unconfirmed-time-reference" : "explicit-danmaku-skip",
                matchedKeywords: SmartSkipJS.unique(supportingPairs.flatMap { $0.cues + $0.adKeywords }),
                earlyAdEvidence: supportingPairs.contains { $0.start < 60 && $0.earlyAdEvidence },
                referenceCount: pairs.count,
                explicitCount: explicitPairs.count)
        }
        // Repeated bare timestamps are not independent votes and cannot authorize auto-skip.
        let sorted = SmartSkipJS.stableSorted(candidates) { a, b in
            SmartSkipJS.or(Double(b.explicitCount! - a.explicitCount!),
                           SmartSkipJS.or(Double(b.referenceCount! - a.referenceCount!), a.start - b.start))
        }
        guard var best = sorted.first else { return nil }
        // Expose conflicting destinations instead of hiding why this timestamp won.
        best.alternativeDestinations = sorted.dropFirst()
            .filter { other in other.explicitCount! > 0 && max(best.start, other.start) < min(best.end, other.end) }
            .map { SmartSkipAlternativeDestination(end: $0.end, explicitCount: $0.explicitCount!) }
        return best
    }

    private static let cueNegation = SmartSkipRegex(#"(?:不|别|勿|未|没|并非|非(?:广告|恰饭|接广|商单|赞助|推广|跳过|空降|跳伞)|无需|无须|禁止)"#)
    private static let cue = "(跳过(?:广告)?|空降|跳伞|指路|传送(?:门)?|广告结束|广告完了|恰饭结束|回归正片|正片开始)"
    private static let separators = #"[\s:：,，!！。~～→-]*"#
    private static let cueBefore = SmartSkipRegex(cue + "(?:到|至|在)?" + separators + "$")
    private static let cueAfter = SmartSkipRegex("^" + separators + cue + #"(?:了)?(?:$|[\s,.，。!！~～])"#)
    private static let bareEngineeringCode = SmartSkipRegex(#"^\s*\d{3,4}工程\s*[!！。]?\s*$"#)

    /// `getTimestampSkipCues(text, reference)`: an instruction must sit next to its timestamp
    /// ("3:10的空降兵" is not one); any negation anywhere in the comment kills the cue.
    /// `reference` is located with `indexOf` (FIRST occurrence, UTF-16), not the regex position.
    static func getTimestampSkipCues(_ text: String, _ reference: String) -> [String] {
        if cueNegation.test(text) { return [] }
        let index = SmartSkipJS.indexOf(text, reference)
        let before = SmartSkipJS.slice(text, 0, index)
        let after = SmartSkipJS.slice(text, index + SmartSkipJS.length(reference))
        if let match = cueBefore.match(before) ?? cueAfter.match(after), let cue = match[1] { return [cue] }
        return bareEngineeringCode.test(text) ? ["工程"] : []
    }

    // MARK: - Detection: Danmaku keyword matching (directional)

    /// `getAdTimeByKeywords(danmaku)`: start/end keyword clusters, else the general-keyword span.
    static func getAdTimeByKeywords(_ danmaku: [SmartSkipDanmaku]) -> SmartSkipSegment? {
        let clusterWindow: Double = 15
        let minClusterSize = 2
        let allKeywords = SmartSkipConstants.adStartKeywords + SmartSkipConstants.adEndKeywords + SmartSkipConstants.adGeneralKeywords

        func withKeywords(_ segment: SmartSkipSegment?) -> SmartSkipSegment? {
            guard var segment else { return nil }
            segment.matchedKeywords = SmartSkipJS.unique(danmaku
                .filter { $0.time >= segment.start && $0.time <= segment.end }
                .flatMap { d in allKeywords.filter { SmartSkipJS.includes(d.textContent, $0) } })
            return segment
        }

        var startSignals: [Double] = [], endSignals: [Double] = [], generalSignals: [Double] = []
        for d in danmaku {
            let text = SmartSkipJS.trim(d.textContent)
            let time = d.time
            if SmartSkipConstants.adStartKeywords.contains(where: { SmartSkipJS.includes(text, $0) }) { startSignals.append(time) }
            if SmartSkipConstants.adEndKeywords.contains(where: { SmartSkipJS.includes(text, $0) }) { endSignals.append(time) }
            if SmartSkipConstants.adGeneralKeywords.contains(where: { SmartSkipJS.includes(text, $0) }) { generalSignals.append(time) }
        }

        let startCluster = findCluster(startSignals, clusterWindow, minClusterSize)
        let endCluster = findCluster(endSignals, clusterWindow, minClusterSize)
        if let startCluster, let endCluster, endCluster.center > startCluster.center {
            let adStart = startCluster.start
            let adEnd = endCluster.end
            if adEnd - adStart >= 30 && adEnd - adStart <= 180 {
                return withKeywords(SmartSkipSegment(start: adStart, end: adEnd))
            }
        }
        return withKeywords(getAdTimeByGeneralKeywords(generalSignals))
    }

    /// `findCluster(times, windowSec, minSize)`: the earliest densest window (strict `>`).
    static func findCluster(_ times: [Double], _ windowSec: Double, _ minSize: Int) -> (center: Double, start: Double, end: Double)? {
        if times.count < minSize { return nil }
        let times = SmartSkipJS.stableSorted(times) { $0 - $1 }
        var bestCount = 0, bestStart: Double = 0, bestEnd: Double = 0
        var i = 0
        for j in times.indices {
            while times[j] - times[i] > windowSec { i += 1 }
            let count = j - i + 1
            if count > bestCount {
                bestCount = count
                bestStart = times[i]
                bestEnd = times[j]
            }
        }
        if bestCount >= minSize { return ((bestStart + bestEnd) / 2, bestStart, bestEnd) }
        return nil
    }

    /// `getAdTimeByGeneralKeywords(possibleAdTimes)`. JS truthiness kept: a span starting at
    /// time 0 counts as "not found".
    static func getAdTimeByGeneralKeywords(_ possibleAdTimes: [Double]) -> SmartSkipSegment? {
        if possibleAdTimes.isEmpty { return nil }
        let times = SmartSkipJS.stableSorted(possibleAdTimes) { $0 - $1 }
        let adMaxDuration: Double = 100, adMinDuration: Double = 30
        var i = 0, j = 1
        var adStart: Double?, adEnd: Double?
        while i < times.count && j < times.count {
            let start = times[i]
            let end = times[j]
            if end - start > adMaxDuration {
                if SmartSkipJS.truthy(adStart) { break }
                if j - 1 == i { j += 1 }
                i += 1
            } else {
                if end - start >= adMinDuration {
                    adStart = start
                    adEnd = end
                }
                j += 1
            }
        }
        if SmartSkipJS.truthy(adStart), let adStart, let adEnd { return SmartSkipSegment(start: adStart - 5, end: adEnd) }
        return nil
    }

    // MARK: - Validation

    /// `checkAdSegVaild(adTimes, duration, allowEarlyAd = false)` (sic). Start ≥ 60 (≥ 0 with
    /// early-ad evidence), 10 ≤ length < 180, end < duration − 20 (skipped when duration is 0).
    static func checkAdSegVaild(_ adTimes: SmartSkipSegment?, _ duration: Double, _ allowEarlyAd: Bool = false) -> Bool {
        guard let adTimes else { return false }
        if !adTimes.start.isFinite || !adTimes.end.isFinite { return false }
        if adTimes.start < (allowEarlyAd ? 0 : 60) { return false }
        if adTimes.end - adTimes.start >= 180 { return false }
        if adTimes.end - adTimes.start < 10 { return false }
        if duration > 0 && adTimes.end >= duration - 20 { return false }
        return true
    }
}
