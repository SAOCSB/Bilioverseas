// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. 1:1 port of `scr/segment-detector.js` (`BiliSegmentDetector.detectSegments`) @ master
// 3ce86fa (v2.1.0): complete sponsor-break proposals from pure local rules. Same passes, regexes,
// LIMITS and ordering. Part of BiliOverseas (GPL-2.0-or-later).

import Foundation

/// The optional `helpers` argument of `detectSegments`. Production passes all four
/// (`.production`); several upstream tests call it without helpers (`.none`), which switches
/// `classify`, `destinations` and PASS A to their built-in fallbacks.
struct SmartSkipDetectorHelpers {
    var getSubtitleEvidence: ((String) -> SmartSkipSubtitleEvidence?)?
    var extractTimeFromText: ((String) -> SmartSkipTimeInfo?)?
    var getTimestampSkipCues: ((String, String) -> [String])?
    var getAdLabelEvidence: ((String) -> SmartSkipLabelEvidence?)?

    static let none = SmartSkipDetectorHelpers(getSubtitleEvidence: nil, extractTimeFromText: nil,
                                               getTimestampSkipCues: nil, getAdLabelEvidence: nil)
    static let production = SmartSkipDetectorHelpers(
        getSubtitleEvidence: { SmartSkipDetectors.getSubtitleEvidence($0) },
        extractTimeFromText: { SmartSkipUtils.extractTimeFromText($0) },
        getTimestampSkipCues: { SmartSkipDetectors.getTimestampSkipCues($0, $1) },
        getAdLabelEvidence: { SmartSkipDetectors.getAdLabelEvidence($0) })
}

enum SmartSkipSegmentDetector {
    /// Search bounds limit work and confidence, never crop an otherwise longer ad into an
    /// allegedly complete automatic interval.
    enum LIMITS {
        static let searchSeconds: Double = 300
        static let gapSeconds: Double = 8
        static let wrapSeconds: Double = 1.5
        static let endpointTolerance: Double = 3
        static let minimumBreakSeconds: Double = 10
        static let chapterFraction: Double = 0.6
    }

    /// An annotated subtitle row (`prepare`), also used for seeds (`lastIndex`).
    struct Line {
        var from: Double
        var to: Double
        var content: String
        var roles: [String]
        var matched: [String]
        var anchorEnd: Double
        var index: Int
        var lastIndex: Int
    }

    // MARK: Primitives

    static func valid(_ start: Double, _ end: Double, _ duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration
    }

    /// A NUMBER in JS, used as truthy (> 0).
    static func overlap(_ a: (start: Double, end: Double), _ b: (start: Double, end: Double)) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    static func compact(_ value: String) -> String {
        SmartSkipDetectors.whitespaceRun.replaceAll(value.lowercased(), with: "")
    }

    // MARK: Role patterns (verbatim; iteration order = this order; no flags)

    private static let patterns: [(role: String, pattern: SmartSkipRegex)] = [
        ("sponsor", SmartSkipRegex(#"(?:本期(?:视频|节目)?|本视频|本节目|这个视频|这期视频).{0,12}(?:赞助商|由.{1,28}(?:赞助|冠名))|感谢.{0,8}(?:甲方|金主)|感谢.{1,24}(?:赞助|冠名)|(?:本期|这次|今天|我们).{0,8}(?:与|和).{1,24}(?:合作|联合推出)|(?:接下来|现在|稍后).{0,8}(?:通过|是|进入).{0,28}(?:广告|赞助环节)|sponsoredby"#)),
        ("sponsorIntro", SmartSkipRegex(#"感谢.{1,24}(?:赞助|冠名)|感谢.{1,20}(?:的)?催更|(?:广告|恰饭)(?:时间|环节|开始)"#)),
        ("cta", SmartSkipRegex(#"(?:评论区|蓝链|链接|二维码|官网).{0,18}(?:领|优惠|购买|下单|试用)|(?:点击|扫描|前往|访问|使用).{0,18}(?:评论区|蓝链|链接|二维码|官网)|(?:立即|现在|赶紧|快来).{0,6}(?:下单|抢购|领券)"#)),
        ("offer", SmartSkipRegex(#"优惠券|优惠码|折扣码|领券|新客|新用户|补贴|(?:免费|限时).{0,8}(?:试用|体验)|首年.{0,8}(?:折|优惠)"#)),
        ("pitch", SmartSkipRegex(#"优惠|折扣|福利|旗舰店|包邮|到手价|划算|性价比|正品保障|质保|验机报告|保价"#)),
        ("price", SmartSkipRegex(#"(?:只要|仅需|到手|售价|价格).{0,8}\d|\d+(?:\.\d+)?(?:多|左右)?(?:元|块|折)|\d{3,6}.{0,8}(?:拿下|买)"#)),
        ("product", SmartSkipRegex(#"这款|他家|它家|产品|上门回收|二手商品|会员|课程|平台|同款|功能|性能|售后|保障"#)),
        ("relationship", SmartSkipRegex(#"(?:我|我们).{0,16}(?:恰.{0,5}饭|接.{0,3}商单|接.{0,3}广|品牌方)|合作\d+年|合作多年"#)),
        ("return", SmartSkipRegex(#"(?:现在|那么|好了|接下来)?(?:回到|回归)(?:视频|正片|正文|正题|主题|主线|故事)|言归正传|(?:广告|恰饭)(?:结束|完了)|继续(?:刚才的话题|刚才的故事|正片)"#)),
        ("softReturn", SmartSkipRegex(#"^(?:好了?[,，]?|那么|接下来)?让我们从.{1,20}开始|^说回(?:刚才|前面)"#)),
    ]
    private static let negative = SmartSkipRegex(#"(?:无|没有|不含|不是|并非|拒绝).{0,8}(?:广告|赞助|冠名|推广|商单)|(?:不要|别|切勿|请勿|禁止|无需|不必|不能|不建议).{0,16}(?:点击|下载|购买|下单|领取|领券|赞助|回到|回归)"#)
    private static let reported = SmartSkipRegex(#"(?:他说|她说|有人说|所谓|举个例子|这句话|那句|广告词|广告里|假设).{0,24}(?:赞助|广告|冠名)|[“「『"].{0,30}(?:本视频|本期|赞助)"#)
    private static let audienceGratitude = SmartSkipRegex(#"感谢.{0,6}(?:大家|观众|粉丝|你们|朋友|老师|网友).{0,8}催更"#)
    private static let clauseSeparator = SmartSkipRegex(#"[。！？!?；;]"#)
    private static let quotedExample = SmartSkipRegex(#"(?:广告词|广告文案|赞助声明).{0,12}(?:示例|例子|模板)|(?:示例|举例|比如).{0,12}(?:广告词|赞助声明)"#)
    private static let negatedWrapEnd = SmartSkipRegex(#"(?:不要|别|切勿|请勿|禁止|无需|不必|不能|不建议|没有|不是)$"#)
    private static let decorativeFrame = SmartSkipRegex(#"^[░▒▓█▌▐▏▎▍▊▋▉★☆✦✧]+|[░▒▓█▌▐▏▎▍▊▋▉★☆✦✧]+$"#)
    private static let fallbackCommand = SmartSkipRegex(#"^(?:跳过广告|广告结束|空降|跳伞)\s*(\d{1,2})[:：](\d{2})[!！。]?$"#)
    private static let fallbackEngineering = SmartSkipRegex(#"^(\d{1,2})(\d{2})工程[!！。]?$"#)
    private static let fallbackAdChapter = SmartSkipRegex(#"^(?:广告|赞助|商单|恰饭|广告时间|赞助环节|ad|sponsored)$"#, ignoreCase: true)
    private static let reactionNegation = SmartSkipRegex(#"(?:不是|没|无|不算|是不是|难道|并非)"#)
    private static let reactionPattern = SmartSkipRegex(#"感谢甲方|恭喜.{0,4}接广|接到商单|甲方.{0,6}文案"#)
    private static let productThemeTitle = SmartSkipRegex(#"开箱|试吃|测评|评测|品鉴|好物推荐|购物分享"#)
    private static let courseTitle = SmartSkipRegex(#"课程|教程|教学|入门"#)
    private static let courseLine = SmartSkipRegex(#"本课程|这门课|这个课程|第一课|教学目标|本套教程"#)

    // MARK: classify / prepare

    static func classify(_ text: String, _ helpers: SmartSkipDetectorHelpers) -> (roles: [String], matched: [String]) {
        var roles: [String] = [], matched: [String] = []
        let value = compact(text)
        for clause in clauseSeparator.split(value) {          // NOTE: no comma split here
            if negative.test(clause) || reported.test(clause) { continue }   // skips helper evidence too
            for (role, pattern) in patterns {
                if role == "sponsorIntro" && audienceGratitude.test(clause) { continue }
                if let match = pattern.match(clause) {
                    roles.append(role)
                    matched.append(match[0]!)
                }
            }
            if let getSubtitleEvidence = helpers.getSubtitleEvidence {
                let evidence = getSubtitleEvidence(clause)
                for role in evidence?.categories ?? [] where role != "sponsor" { roles.append(role) }
                for match in evidence?.matched ?? [] { matched.append(match) }
            }
        }
        return (SmartSkipJS.unique(roles), SmartSkipJS.unique(matched))
    }

    private struct RowKey: Hashable { var from: Double; var to: Double; var content: [UInt16] }

    static func prepare(_ subtitles: [SubtitleLine], _ duration: Double, _ helpers: SmartSkipDetectorHelpers) -> [Line] {
        var seen = Set<RowKey>()
        let lines = SmartSkipJS.stableSorted(subtitles.filter { valid($0.from, $0.to, duration) }) { a, b in
            SmartSkipJS.or(a.from - b.from, a.to - b.to)
        }.filter { line in
            seen.insert(RowKey(from: line.from, to: line.to, content: Array(line.content.utf16))).inserted
        }
        func isSponsor(_ roles: [String]) -> Bool { roles.contains { $0 == "sponsor" || $0 == "sponsorIntro" } }
        return lines.enumerated().map { index, line in
            let previous = index > 0 ? lines[index - 1] : nil
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            let quotedContext = lines[max(0, index - 3)..<index].contains { before in
                line.from - before.to <= 15 && quotedExample.test(before.content)
            }
            var negatedWrap = false
            if let previous, line.from - previous.to <= LIMITS.wrapSeconds,
               negatedWrapEnd.test(SmartSkipJS.trim(previous.content)) {
                negatedWrap = true
            }
            let text = negatedWrap ? previous!.content + line.content : line.content
            var evidence = classify(text, helpers)
            var anchorEnd = line.to
            if !negatedWrap, let next, next.from >= line.to, next.from - line.to <= LIMITS.wrapSeconds,
               !isSponsor(evidence.roles), !isSponsor(classify(next.content, helpers).roles) {
                let joined = classify(line.content + next.content, helpers)
                if isSponsor(joined.roles) {   // wrapped sponsor sentence
                    evidence = joined
                    anchorEnd = next.to
                }
            }
            if quotedContext {
                evidence.roles = evidence.roles.filter { !["sponsor", "sponsorIntro", "relationship"].contains($0) }
            }
            return Line(from: line.from, to: line.to, content: line.content, roles: evidence.roles,
                        matched: evidence.matched, anchorEnd: anchorEnd, index: index, lastIndex: index)
        }
    }

    static func has(_ line: Line, _ roles: String...) -> Bool { line.roles.contains { roles.contains($0) } }
    static func commercial(_ line: Line) -> Bool { line.roles.contains { ["cta", "offer", "pitch", "price"].contains($0) } }

    // MARK: destinations / chapters / reactions

    /// Removes decorative frames only, never narrative/negation words.
    static func cleanInstruction(_ text: String) -> String {
        SmartSkipJS.trim(decorativeFrame.replaceAll(SmartSkipJS.trim(text), with: ""))
    }

    /// Explicit danmaku destinations only (non-empty cues), destination after the comment and
    /// ≤ duration. No `+5` offset here (unlike `findAdTimestamps`).
    static func destinations(_ danmaku: [SmartSkipDanmaku], _ duration: Double, _ helpers: SmartSkipDetectorHelpers) -> [SmartSkipDestination] {
        var result: [SmartSkipDestination] = []
        for comment in danmaku {
            if !comment.time.isFinite || comment.time < 0 || comment.time >= duration { continue }
            let text = cleanInstruction(comment.textContent)
            var parsedTime: Double?
            var cues: [String]?
            if let extract = helpers.extractTimeFromText, let skipCues = helpers.getTimestampSkipCues {
                if let parsed = extract(text) {
                    parsedTime = parsed.time
                    cues = skipCues(text, parsed.reference)
                }
            } else if let m = fallbackCommand.match(text) ?? fallbackEngineering.match(text),
                      let minutes = Double(m[1]!), let seconds = Double(m[2]!), seconds < 60 {
                parsedTime = minutes * 60 + seconds
                cues = ["explicit-time-command"]
            }
            guard let time = parsedTime, let cues, !cues.isEmpty, valid(comment.time, time, duration) else { continue }
            result.append(SmartSkipDestination(time: comment.time, end: time, cues: cues, text: SmartSkipJS.slice(text, 0, 120)))
        }
        return result
    }

    /// Structural envelopes (any title): never the first or last chapter; any overlap → none.
    static func chapterRanges(_ chapters: [VideoChapter], _ duration: Double) -> [SmartSkipChapterRange] {
        let result = SmartSkipJS.stableSorted(chapters.filter { valid($0.from, $0.to, duration) }
            .map { SmartSkipChapterRange(start: $0.from, end: $0.to, title: SmartSkipJS.slice($0.title, 0, 120)) }) { $0.start - $1.start }
        if result.indices.contains(where: { $0 > 0 && result[$0].start < result[$0 - 1].end }) { return [] }
        return result.enumerated().filter { index, chapter in
            index > 0 && index < result.count - 1
                && chapter.end - chapter.start <= LIMITS.searchSeconds
                && chapter.end - chapter.start <= duration * LIMITS.chapterFraction
        }.map(\.element)
    }

    /// Distinct affirmative "community" reactions inside `[start, end)`.
    static func reactions(_ danmaku: [SmartSkipDanmaku], _ start: Double, _ end: Double) -> [SmartSkipReaction] {
        var seen = Set<[UInt16]>()
        var found: [SmartSkipReaction] = []
        for comment in danmaku {
            if !comment.time.isFinite || comment.time < start || comment.time >= end { continue }
            let text = compact(comment.textContent)
            if reactionNegation.test(text) { continue }
            if !reactionPattern.test(text) { continue }
            if seen.insert(Array(text.utf16)).inserted {
                found.append(SmartSkipReaction(time: comment.time, text: SmartSkipJS.slice(text, 0, 120)))
            }
        }
        return found
    }

    static func alignTimeEnd(_ end: Double, _ lines: [Line]) -> Double {
        guard let previous = lines.last(where: { $0.to <= end && end - $0.to <= LIMITS.endpointTolerance }) else { return end }
        let next = previous.index + 1 < lines.count ? lines[previous.index + 1] : nil
        let closing = lines.contains { $0.to <= previous.to && previous.to - $0.to <= 5 && commercial($0) }
        if closing, let next, !commercial(next), next.from >= previous.to { return previous.to }
        return end
    }

    static func chain(_ lines: [Line]) -> Bool {
        let unique = Set(lines.filter(commercial).map { Array(compact($0.content).utf16) })
        let roles = Set(lines.flatMap(\.roles))
        return unique.count >= 2 && ["cta", "offer", "pitch"].contains { roles.contains($0) }
    }

    static func statement(_ line: Line) -> SmartSkipStatement {
        SmartSkipStatement(from: line.from, to: line.anchorEnd, roles: line.roles, matchedKeywords: Array(line.matched.prefix(6)))
    }

    static func result(_ start: Double, _ end: Double, _ seed: Line?, _ body: [Line], _ boundary: SmartSkipBoundaryEvidence,
                       keep: Bool = false, auto: Bool = false, reasons: [String] = []) -> SmartSkipSegment {
        let autoEligible = !keep && auto
        let seedSponsor = seed.map { has($0, "sponsor", "sponsorIntro") } ?? false
        return SmartSkipSegment(
            start: start, end: end, source: "segment-detector",
            requiresConfirmation: !autoEligible,
            confidence: autoEligible ? "high" : "low",
            reason: keep ? "standalone-or-content-theme-kept" : "complete-sponsor-break",
            matchedKeywords: Array(SmartSkipJS.unique(body.flatMap(\.matched)).prefix(24)),
            earlyAdEvidence: autoEligible && start < 60,
            sources: ["subtitles"] + SmartSkipJS.unique(boundary.sources),
            contentType: autoEligible || seedSponsor ? "ad" : "uncertain",
            skipDecision: keep ? "keep" : "skip",
            autoEligible: autoEligible,
            boundaryConfidence: autoEligible ? "high" : "uncertain",
            boundaryEvidence: boundary,
            observedEvidence: body.filter { commercial($0) || has($0, "sponsor", "sponsorIntro") }.prefix(8).map(statement),
            observedLineCount: body.count,
            reviewReasons: reasons)
    }

    // MARK: detectSegments

    /// `detectSegments(input, helpers = {})` — pure and synchronous; never mutates its input.
    static func detectSegments(_ input: SmartSkipInputs?, _ helpers: SmartSkipDetectorHelpers = .none) -> [SmartSkipSegment] {
        guard let input, input.duration.isFinite, input.duration > 0 else { return [] }
        let duration = input.duration
        let lines = prepare(input.subtitles, duration, helpers)
        let chapters = chapterRanges(input.chapters, duration)
        let times = destinations(input.danmaku, duration, helpers)
        let title = compact(input.title)
        let productTheme = productThemeTitle.test(title)
        let ownCourse = courseTitle.test(title) && lines.contains { $0.from < 45 && courseLine.test($0.content) }
        var output: [SmartSkipSegment] = []
        func span(_ s: SmartSkipSegment) -> (start: Double, end: Double) { (s.start, s.end) }

        // PASS A — explicit author-labelled ad chapters do not require subtitle availability.
        // Unlike the legacy single-candidate API, retain every separate ad chapter.
        for chapter in input.chapters {
            if !valid(chapter.from, chapter.to, duration) { continue }
            let evidence: SmartSkipLabelEvidence?
            if let getAdLabelEvidence = helpers.getAdLabelEvidence {
                evidence = getAdLabelEvidence(chapter.title)
            } else if fallbackAdChapter.test(SmartSkipJS.trim(chapter.title)) {
                evidence = SmartSkipLabelEvidence(matchedKeywords: [chapter.title], requiresConfirmation: false, reason: "")
            } else {
                evidence = nil
            }
            guard let evidence, evidence.requiresConfirmation == false else { continue }   // explicit labels only
            let length = chapter.to - chapter.from
            let auto = length >= LIMITS.minimumBreakSeconds && length <= LIMITS.searchSeconds
                && length <= duration * LIMITS.chapterFraction
            var segment = result(chapter.from, chapter.to, nil, [], SmartSkipBoundaryEvidence(
                sources: ["chapters"],
                start: SmartSkipBoundaryPoint(kind: "explicit-ad-chapter", time: chapter.from),
                end: SmartSkipBoundaryPoint(kind: "explicit-ad-chapter", time: chapter.to)),
                auto: auto, reasons: auto ? [] : ["chapter-duration-needs-review"])
            segment.contentType = "ad"
            segment.reason = "explicit-ad-chapter"
            segment.matchedKeywords = evidence.matchedKeywords
            if !output.contains(where: { overlap(span($0), span(segment)) > 0 }) { output.append(segment) }
        }

        // Seeds: adjacent sponsor wording can be one wrapped declaration. A separate later
        // declaration is always a search barrier, never evidence for this one.
        var seeds: [Line] = []
        for line in lines where has(line, "sponsor", "sponsorIntro") {
            if var previous = seeds.last, line.index == previous.lastIndex + 1,
               line.from - previous.anchorEnd <= LIMITS.wrapSeconds {
                previous.anchorEnd = max(previous.anchorEnd, line.anchorEnd)
                previous.lastIndex = line.index
                previous.roles = SmartSkipJS.unique(previous.roles + line.roles)
                seeds[seeds.count - 1] = previous
            } else {
                var seed = line
                seed.lastIndex = line.index
                seeds.append(seed)
            }
        }

        // PASS B — one proposal per seed.
        for seedIndex in seeds.indices {
            let seed = seeds[seedIndex]
            let nextSeed = seedIndex + 1 < seeds.count ? seeds[seedIndex + 1] : nil
            if output.contains(where: { seed.from >= $0.start && seed.from < $0.end }) { continue }
            let chapter = chapters.first { ch in
                ch.start <= seed.from && ch.end >= seed.anchorEnd && (nextSeed == nil || nextSeed!.from >= ch.end)
            }
            let start = chapter?.start ?? seed.from
            let limit = min(duration, start + LIMITS.searchSeconds, chapter?.end ?? .infinity, nextSeed?.from ?? .infinity)
            let after = lines.filter { $0.from >= seed.from && $0.from < limit }
            let returned = after.first { $0.index > seed.index && has($0, "return") }
            let softReturn = after.first { line in
                line.index > seed.index && has(line, "softReturn")
                    && after.contains { $0.to <= line.from && has($0, "cta", "offer") }
            }
            let stop: Line?
            if let returned, let softReturn { stop = returned.from <= softReturn.from ? returned : softReturn } else { stop = returned ?? softReturn }
            let explicitStop = stop.map { has($0, "return") } ?? false
            var end: Double? = stop.map { lines[$0.index - 1].to } ?? chapter?.end
            var endKind: String? = stop != nil ? (explicitStop ? "explicit-return" : "post-offer-transition")
                : chapter != nil ? "chapter-end" : nil
            var scope = after.filter { !SmartSkipJS.truthy(end) || $0.to <= end! }
            // A lone opening credit does not open a sponsor state over the main video.
            let earlyFollow = scope.filter { $0.from <= seed.anchorEnd + 25 && $0.index > seed.index }
            if chapter == nil && seed.from < 10 && seed.to - seed.from <= 8
                && !earlyFollow.contains(where: { has($0, "cta", "offer", "pitch", "product") }) {
                output.append(result(seed.from, seed.anchorEnd, seed, [seed], SmartSkipBoundaryEvidence(
                    start: SmartSkipBoundaryPoint(kind: "sponsor-statement"), end: SmartSkipBoundaryPoint(kind: "statement-end")),
                    keep: true, reasons: ["single-statement-without-promotional-continuation"]))
                continue
            }
            // Explicit danmaku destinations near this seed.
            let searchEnd = SmartSkipJS.truthy(end) ? end! : limit
            let nearby = times.filter { time in
                time.time >= start - 15 && time.time < searchEnd
                    && time.end > seed.anchorEnd && time.end <= limit && time.end - start <= LIMITS.searchSeconds
                    && (!SmartSkipJS.truthy(end) || abs(time.end - end!) <= LIMITS.endpointTolerance)
            }
            var groups: [(end: Double, references: [SmartSkipDestination])] = []
            for time in SmartSkipJS.stableSorted(nearby, by: { $0.end - $1.end }) {
                if let g = groups.firstIndex(where: { abs($0.end - time.end) <= LIMITS.endpointTolerance }) {
                    groups[g].references.append(time)
                } else {
                    groups.append((time.end, [time]))
                }
            }
            groups = SmartSkipJS.stableSorted(groups) { a, b in
                SmartSkipJS.or(Double(b.references.count - a.references.count), a.end - b.end)
            }
            let selected = groups.first
            let conflict = !SmartSkipJS.truthy(end) && groups.count > 1
            if !SmartSkipJS.truthy(end), let selected {
                end = selected.end
                endKind = "explicit-danmaku-end"
            }
            var continuingAfterTime = false
            if endKind == "explicit-danmaku-end", let e = end {
                let continuation = after.filter { $0.from >= e && $0.from <= e + 12 && has($0, "cta", "offer") }
                if let last = continuation.last {
                    // A destination inside a still-visible offer is not a complete end.
                    // Keep the observed continuation as a manual proposal, never crop it.
                    end = last.to
                    endKind = "commercial-continuation-after-timestamp"
                    continuingAfterTime = true
                }
                if !continuingAfterTime { end = alignTimeEnd(e, lines) }
            }
            if !SmartSkipJS.truthy(end) {
                // Missing a firm endpoint is explicit uncertainty, not a reason to use
                // only the last CTA or manufacture a fixed-size interval.
                let gapIndex = after.indices.first { $0 > 0 && after[$0].from - after[$0 - 1].to > LIMITS.gapSeconds }
                scope = gapIndex.map { Array(after[..<$0]) } ?? after
                let lastCommercial = scope.filter(commercial).last
                end = SmartSkipJS.truthy(lastCommercial?.to) ? lastCommercial!.to : seed.anchorEnd
                endKind = nextSeed != nil && limit == nextSeed!.from ? "unresolved-before-next-sponsor" : "last-observed-commercial-line"
            }
            let finalEnd = end!
            scope = lines.filter { $0.from >= start && $0.to <= finalEnd }
            if !valid(start, finalEnd, duration) { continue }
            let sustained = chain(scope) && scope.count >= 4 && finalEnd - start >= LIMITS.minimumBreakSeconds
            let independentBreak = explicitStop || chapter != nil
                || (selected != nil && has(seed, "sponsor") && scope.contains { has($0, "cta") })
            let themeRisk = ((productTheme || ownCourse) && !independentBreak) || finalEnd - start > duration * LIMITS.chapterFraction
            let hardEnd = ["explicit-return", "explicit-danmaku-end", "chapter-end"].contains(endKind ?? "")
            let strongStart = has(seed, "sponsor")
            let corroboratedIntro = has(seed, "sponsorIntro") && selected != nil
                && Set(scope.filter(commercial).map { Array(compact($0.content).utf16) }).count >= 3
            let subtitleGap = scope.indices.contains { $0 > 0 && scope[$0].from - scope[$0 - 1].to > LIMITS.gapSeconds }
            let auto = (strongStart || corroboratedIntro) && sustained && hardEnd && !conflict && !themeRisk
                && (!subtitleGap || chapter != nil)
            let keep = themeRisk && stop == nil && chapter == nil
            var sources: [String] = []
            if chapter != nil { sources.append("chapters") }
            if selected != nil { sources.append("danmaku-time") }
            var reasons: [String] = []                      // reasons in THIS order
            if !strongStart && !corroboratedIntro { reasons.append("weak-sponsor-identity") }
            if !sustained { reasons.append("insufficient-promotional-continuation") }
            if !hardEnd { reasons.append("end-needs-review") }
            if continuingAfterTime { reasons.append("commercial-content-after-time-destination") }
            if conflict { reasons.append("conflicting-time-destinations") }
            if subtitleGap && chapter == nil { reasons.append("subtitle-continuity-gap") }
            if themeRisk { reasons.append("content-theme-may-be-kept") }
            output.append(result(start, finalEnd, seed, scope, SmartSkipBoundaryEvidence(
                sources: sources,
                start: SmartSkipBoundaryPoint(kind: chapter != nil ? "chapter-start" : "sponsor-statement", time: start),
                end: SmartSkipBoundaryPoint(kind: endKind ?? "", time: finalEnd, returnLine: stop.map(statement)),
                chapter: chapter,
                timeReferences: selected.map { Array($0.references.prefix(6)) },
                alternativeEnds: groups.dropFirst().map { SmartSkipAlternativeEnd(end: $0.end, references: $0.references.count) }),
                keep: keep, auto: auto, reasons: reasons))
        }

        // PASS C — a chapter can recover a full manual interval even when only a CTA is
        // explicit. It never becomes automatic without an independent sponsor start.
        for chapter in chapters {
            if output.contains(where: { overlap(span($0), (chapter.start, chapter.end)) > 0 }) { continue }
            let body = lines.filter { $0.from >= chapter.start && $0.to <= chapter.end }
            let completeCta = body.contains { has($0, "cta") && has($0, "offer", "pitch") }
            if (!chain(body) || !body.contains(where: { has($0, "cta") })) && !completeCta { continue }
            let community = reactions(input.danmaku, chapter.start, chapter.end)
            let corroborated = completeCta && body.contains { has($0, "relationship") }
                && community.count >= 2 && !productTheme && !ownCourse
            output.append(result(chapter.start, chapter.end, nil, body, SmartSkipBoundaryEvidence(
                sources: ["chapters"],
                start: SmartSkipBoundaryPoint(kind: "chapter-start", time: chapter.start),
                end: SmartSkipBoundaryPoint(kind: "chapter-end", time: chapter.end),
                chapter: chapter,
                commercialReactions: Array(community.prefix(6))),
                auto: corroborated, reasons: corroborated ? [] : ["commercial-chapter-without-explicit-sponsor-start"]))
        }
        return SmartSkipJS.stableSorted(output) { a, b in SmartSkipJS.or(a.start - b.start, a.end - b.end) }
    }
}
