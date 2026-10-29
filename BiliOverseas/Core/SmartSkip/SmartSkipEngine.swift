// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. Detection pipeline = 1:1 port of `scr/content.js` (`getSkipSegment`,
// `getSkipSegments`, `combineSkipSegments`) @ master 3ce86fa (v2.1.0). The runtime part
// (`SmartSkipTracker`) re-implements `scr/skipper.js` natively, adopting the sensible fixes of the
// unmerged `fix/improve-detction-rate` branch (exact 5 s countdown that pauses while paused or
// while the user interacts, no stale-button seeks). Part of BiliOverseas (GPL-2.0-or-later).
//
// Player integration (summary):
//   1. On every new (bvid, cid): `tracker = nil`; `Task { let segs = await SmartSkipAnalyzer.shared
//      .analyze(ctx); guard still same video; tracker = SmartSkipTracker(segments: segs, mode: …) }`.
//   2. Periodic time observer (≤ 0.25 s) and on play/pause changes:
//      `tracker.update(time:isPlaying:now:)` → apply the returned `SmartSkipAction`.
//      `.autoSkip(seg)`: seek to `seg.seekTarget` with zero tolerance, then `tracker.didSeek(to:)`;
//      toast "已跳过广告" with "撤销" → `tracker.undo(seg)` returns the time to seek back to.
//      `.showPrompt(seg, remaining)`: show `SmartSkipPromptView`; `.hidePrompt`: hide it.
//   3. Prompt tap → `if let t = tracker.userSkipped(seg) { seek(t) }`; ✕ → `tracker.userDismissed(seg)`.
//   4. User scrubs → `tracker.didSeek(to:)`. Player item replaced (same video) → `replaceSegments`.

import Foundation

// MARK: - Pipeline (content.js)

enum SmartSkipPipeline {
    /// `getSkipSegment(inputs)` — the primary single-candidate cascade (order is the priority):
    /// 1 chapters, 2 description, 3 danmaku destinations (trusted), ambiguous label fallback,
    /// 4 subtitles (manual), 5 danmaku keywords (manual).
    static func getSkipSegment(_ inputs: SmartSkipInputs) -> SmartSkipSegment? {
        guard inputs.cid > 0 else { return nil }
        let duration = inputs.duration
        func selectSegment(_ segment: SmartSkipSegment, _ source: String, _ requiresConfirmation: Bool? = nil) -> SmartSkipSegment {
            let rc = requiresConfirmation ?? segment.needsConfirmation
            var result = segment
            result.source = source
            result.requiresConfirmation = rc
            result.confidence = rc ? "low" : "high"
            SmartSkipUtils.log("detection:", inputs.bvid, inputs.cid, result)
            return result
        }
        var labelCandidate: (segment: SmartSkipSegment, source: String)?

        // 1. Chapter markers (highest confidence)
        var adTimes = SmartSkipDetectors.detectFromChapters(inputs.chapters)
        if let a = adTimes, SmartSkipDetectors.checkAdSegVaild(a, duration) {
            if a.requiresConfirmation == false { return selectSegment(a, "chapters") }
            labelCandidate = (a, "chapters")
        }
        // 2. Description timestamps (high confidence)
        adTimes = SmartSkipDetectors.detectFromDescription(inputs.desc, duration)
        if let a = adTimes, SmartSkipDetectors.checkAdSegVaild(a, duration) {
            if a.requiresConfirmation == false { return selectSegment(a, "description") }
            if labelCandidate == nil { labelCandidate = (a, "description") }
        }
        // 3. User-provided skip destinations take priority over inferred subtitle bounds.
        let timestamp = SmartSkipDetectors.findAdTimestamps(inputs.danmaku, duration)
        if let timestamp, timestamp.requiresConfirmation == false { return selectSegment(timestamp, "danmaku-time") }
        if let labelCandidate { return selectSegment(labelCandidate.segment, labelCandidate.source) }

        // 4. Subtitle keywords locate candidates, but cannot establish safe seek boundaries.
        var subtitleCandidate: SmartSkipSegment?
        adTimes = SmartSkipDetectors.detectFromSubtitles(inputs.subtitles, inputs.danmaku)
        if let a = adTimes, SmartSkipDetectors.checkAdSegVaild(a, duration) { subtitleCandidate = a }
        if let timestamp, let subtitleCandidate {
            // Agreement is useful for diagnostics, but two weak signals must not authorize a seek.
            SmartSkipUtils.log("cross-check:", timestamp, subtitleCandidate,
                               max(timestamp.start, subtitleCandidate.start) < min(timestamp.end, subtitleCandidate.end),
                               abs(timestamp.end - subtitleCandidate.end))
        }
        if let timestamp { return selectSegment(timestamp, "danmaku-time", true) }
        if let subtitleCandidate { return selectSegment(subtitleCandidate, "subtitles", true) }

        // 5. Danmaku keyword matching (low confidence)
        adTimes = SmartSkipDetectors.getAdTimeByKeywords(inputs.danmaku)
        if let a = adTimes, SmartSkipDetectors.checkAdSegVaild(a, duration) { return selectSegment(a, "danmaku-keywords", true) }
        SmartSkipUtils.log("No ad detected.")
        return nil
    }

    /// `getSkipSegments()` — production entry: primary cascade + complete-segment proposals,
    /// merged by `combineSkipSegments`.
    static func getSkipSegments(_ inputs: SmartSkipInputs) -> [SmartSkipSegment] {
        let primary = getSkipSegment(inputs)
        let fallback = primary.map { [$0] } ?? []
        guard inputs.cid > 0 else { return fallback }
        let proposals = SmartSkipSegmentDetector.detectSegments(inputs, .production)
        let segments = combineSkipSegments(primary, proposals)
        SmartSkipUtils.log("segments:", inputs.bvid, inputs.cid, segments)
        return segments
    }

    /// `combineSkipSegments(primary, proposals)`: a trusted chapter/description primary is
    /// authoritative; a trusted timestamp contradicted by observed structure becomes a MANUAL
    /// conflict segment; a structural candidate may replace the primary; then a greedy,
    /// non-overlapping fill (trusted first, then by start).
    static func combineSkipSegments(_ primary: SmartSkipSegment?, _ proposals: [SmartSkipSegment]) -> [SmartSkipSegment] {
        let valid = proposals.filter {
            $0.skipDecision != "keep" && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
        }
        func overlap(_ a: SmartSkipSegment, _ b: SmartSkipSegment) -> Bool { max(a.start, b.start) < min(a.end, b.end) }
        var retained = primary
        var conflict: SmartSkipSegment?
        // (a) A trusted danmaku destination contradicted by observed structure is demoted.
        if let r = retained, r.source == "danmaku-time", r.requiresConfirmation == false {
            let contradiction = valid.first { segment in
                let endKind = segment.boundaryEvidence?.end?.kind
                return overlap(segment, r)
                    && ((segment.reviewReasons ?? []).contains("conflicting-time-destinations")
                        || endKind == "commercial-continuation-after-timestamp"
                        || (abs(segment.end - r.end) > 3
                            && (endKind == "explicit-return"
                                || (segment.requiresConfirmation == false && endKind == "chapter-end"))))
            }
            if let contradiction {
                var c = contradiction
                c.requiresConfirmation = true
                c.autoEligible = false
                c.confidence = "low"
                c.boundaryConfidence = "uncertain"
                c.reason = "cross-source-boundary-conflict"
                c.conflictingTimestamp = SmartSkipConflictingTimestamp(start: r.start, end: r.end, matchedKeywords: r.matchedKeywords)
                c.reviewReasons = (contradiction.reviewReasons ?? []) + ["trusted-destination-conflicts-with-observed-boundary"]
                conflict = c
                retained = nil
            }
        }
        // (b) A source with explicit boundaries remains authoritative. A structural candidate
        // can refine a community start only when its end agrees closely.
        if let r = retained {
            let padding = r.boundaryPaddingSeconds ?? 0
            let replacement = valid.first { segment in
                guard overlap(segment, r) else { return false }
                if r.requiresConfirmation != false {
                    return segment.requiresConfirmation == false
                        || (segment.start <= r.start + padding && segment.end >= r.end - padding)
                }
                return r.source == "danmaku-time" && segment.requiresConfirmation == false
                    && abs(segment.end - r.end) <= 3 && segment.start <= r.start
            }
            if replacement != nil { retained = nil }   // the replacement itself is added in (c)
        }
        // (c) Greedy fill: trusted proposals first, then by start; never overlapping.
        var selected: [SmartSkipSegment] = conflict.map { [$0] } ?? retained.map { [$0] } ?? []
        let ordered = SmartSkipJS.stableSorted(valid) { a, b in
            SmartSkipJS.or(Double((a.needsConfirmation ? 1 : 0) - (b.needsConfirmation ? 1 : 0)), a.start - b.start)
        }
        for proposal in ordered where !selected.contains(where: { overlap($0, proposal) }) {
            selected.append(proposal)
        }
        return SmartSkipJS.stableSorted(selected) { $0.start - $1.start }
    }
}

// MARK: - Public result

/// One interval to skip, as handed to the player.
struct AdSegment: Identifiable, Hashable {
    /// Stable per detection: the upstream skip-history key `"start:end"` (segments never overlap).
    let id: String
    let start: Double
    let end: Double
    /// `true` → only a manual 「跳过广告」 prompt (never auto-skipped); `false` → may auto-skip.
    let requiresConfirmation: Bool
    /// `chapters`, `description`, `danmaku-time`, `subtitles`, `danmaku-keywords`, `segment-detector`.
    let source: String
    /// Machine-readable reason, e.g. `explicit-ad-label`, `explicit-danmaku-skip`,
    /// `complete-sponsor-break`, `cross-source-boundary-conflict`.
    let reason: String
    let matchedKeywords: [String]

    init(id: String? = nil, start: Double, end: Double, requiresConfirmation: Bool, source: String,
         reason: String = "", matchedKeywords: [String] = []) {
        self.id = id ?? "\(SmartSkipJS.numberString(start)):\(SmartSkipJS.numberString(end))"
        self.start = start
        self.end = end
        self.requiresConfirmation = requiresConfirmation
        self.source = source
        self.reason = reason
        self.matchedKeywords = matchedKeywords
    }

    init(_ segment: SmartSkipSegment) {
        self.init(id: segment.skipKey, start: segment.start, end: segment.end,
                  requiresConfirmation: segment.needsConfirmation, source: segment.source ?? "",
                  reason: segment.reason ?? "", matchedKeywords: segment.matchedKeywords)
    }

    /// Where to seek (zero tolerance): just past the half-open interval `[start, end)`, like
    /// upstream's `end + 0.05`, so CMTime rounding cannot land back inside the ad.
    var seekTarget: Double { end + 0.05 }
    var duration: Double { end - start }
}

// MARK: - Analyzer

/// Public detection entry. Fills missing data (view / player / danmaku / subtitle requests as
/// upstream `api.js`), runs the master pipeline off the main actor and caches per video.
actor SmartSkipAnalyzer {
    static let shared = SmartSkipAnalyzer()

    private let loader: SmartSkipDataLoader
    private var cache: [String: [AdSegment]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 16

    init(loader: SmartSkipDataLoader = SmartSkipDataLoader()) {
        self.loader = loader
    }

    /// Returns the segments to skip, sorted by start (empty when nothing is found, the cid
    /// cannot be resolved, or the task was cancelled).
    func analyze(_ context: SmartSkipVideoContext) async -> [AdSegment] {
        let key = "\(context.bvid.isEmpty ? "av\(context.aid)" : context.bvid):\(context.cid):\(context.page)"
        if context.cid > 0, let hit = cache[key] { return hit }
        guard let complete = await loader.complete(context), !Task.isCancelled else { return [] }
        let segments = SmartSkipPipeline.getSkipSegments(complete.inputs).map(AdSegment.init)
        guard !Task.isCancelled else { return [] }
        let storeKey = "\(complete.bvid.isEmpty ? "av\(complete.aid)" : complete.bvid):\(complete.cid):\(complete.page)"
        cache[storeKey] = segments
        cacheOrder.removeAll { $0 == storeKey }
        cacheOrder.append(storeKey)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return segments
    }

    /// Pure, synchronous detection on complete data (no network).
    static func detect(_ inputs: SmartSkipInputs) -> [AdSegment] {
        SmartSkipPipeline.getSkipSegments(inputs).map(AdSegment.init)
    }

    func clearCache() {
        cache = [:]
        cacheOrder = []
    }
}

// MARK: - Runtime tracker

enum SmartSkipAction: Equatable {
    /// Seek to `segment.seekTarget` (zero tolerance), keep the play state, then call
    /// `didSeek(to:)`. Hide any prompt. If `showToast`: toast 「已跳过广告」 with 「撤销」 → `undo`.
    case autoSkip(AdSegment)
    /// Show / update the 「跳过广告」 prompt for `segment`; it auto-hides when the countdown ends.
    case showPrompt(AdSegment, countdownRemaining: Double)
    /// Remove the prompt.
    case hidePrompt
}

/// Pure per-video state machine replacing `attachSkipper` / `skipToEnd` / the countdown (all
/// times injected → unit-testable). Not thread-safe: drive it from one actor (the main actor).
///
/// Rules (master semantics unless noted):
/// * Active segment = first (by start) with `start <= t < end`.
/// * Auto mode, trusted segment, not yet skipped → `.autoSkip` once ("skip each segment once").
///   Re-entering a skipped segment (user seeked back) shows the manual prompt instead.
/// * Otherwise a prompt with a countdown (default 5 s, exact, branch fix): it only runs while
///   playing and not interacting, keeps partial seconds, never seeks on expiry, and is not shown
///   again during the same visit after expiry / ✕. Leaving the interval or seeking ends a visit.
/// * Mode changes apply on the next update. Skip history survives `replaceSegments`.
final class SmartSkipTracker {
    private(set) var segments: [AdSegment]
    var mode: SmartSkipMode
    /// Prompt countdown length in seconds.
    var countdownSeconds: Double
    /// After issuing a seek, ticks still inside that segment are ignored for this long (the seek
    /// is in flight — mirrors upstream's 1 s `seeked` fallback) unless `didSeek` arrives first.
    var seekSettleTimeout: Double = 1.0
    /// Longest gap between two updates that is counted against the countdown (a longer gap means
    /// playback was not progressing, e.g. the periodic observer stopped while paused).
    var maxTickInterval: Double = 1.0

    /// Ids of segments skipped (automatically or manually) in this video.
    private(set) var skippedSegmentIDs: Set<String> = []
    /// The segment containing the last updated time.
    private(set) var activeSegment: AdSegment?
    private(set) var isPromptVisible = false

    private enum PromptState { case notShown, visible(remaining: Double), finished }
    private struct Visit {
        var segmentID: String
        var prompt: PromptState = .notShown
    }
    private var visit: Visit?
    private var pendingSeek: (segmentID: String, issuedAt: Double)?
    private var undone: (segmentID: String, entered: Bool)?
    private var skipOrigins: [String: Double] = [:]
    private var lastTime: Double?
    private var lastNow: Double?
    private var countdownRunning = false
    private var lastIsPlaying = false
    private var interacting = false

    init(segments: [AdSegment], mode: SmartSkipMode, countdownSeconds: Double = Double(SmartSkipConstants.countdown)) {
        self.segments = SmartSkipJS.stableSorted(segments) { $0.start - $1.start }
        self.mode = mode
        self.countdownSeconds = countdownSeconds
    }

    /// Feed the current playback position. Returns the action to apply, or `nil` if nothing
    /// changes. `now` is a monotonic clock in seconds (e.g. `ProcessInfo.processInfo.systemUptime`).
    func update(time: Double, isPlaying: Bool, now: Double) -> SmartSkipAction? {
        consumeCountdown(now: now)
        lastTime = time
        lastIsPlaying = isPlaying
        countdownRunning = isPlaying && !interacting

        let active = segments.first { time >= $0.start && time < $0.end }
        activeSegment = active
        if active?.id != visit?.segmentID {
            visit = active.map { Visit(segmentID: $0.id) }
            if let p = pendingSeek, p.segmentID != active?.id { pendingSeek = nil }
        }
        if let u = undone {
            if active?.id == u.segmentID { undone?.entered = true } else if u.entered { undone = nil }
        }
        guard let segment = active else { return finish(nil) }

        // Our own seek out of this segment is still in flight.
        if let p = pendingSeek, p.segmentID == segment.id {
            if now - p.issuedAt < seekSettleTimeout { return finish(nil) }
            pendingSeek = nil
        }

        let skipped = skippedSegmentIDs.contains(segment.id)
        if mode == .auto && !skipped && !segment.requiresConfirmation {
            markSkipped(segment, origin: time, now: now)
            isPromptVisible = false
            return .autoSkip(segment)
        }

        if undone?.segmentID == segment.id { return finish(nil) }   // user chose to watch it
        switch visit?.prompt ?? .finished {
        case .notShown:
            visit?.prompt = .visible(remaining: countdownSeconds)
            return finish((segment, countdownSeconds))
        case .visible(let remaining):
            if remaining <= 0 {
                visit?.prompt = .finished
                return finish(nil)
            }
            return finish((segment, remaining))
        case .finished:
            return finish(nil)
        }
    }

    /// The user tapped the prompt. Returns the seek target, or `nil` for a stale prompt (its
    /// segment is no longer the active one) — never seeks backwards.
    @discardableResult
    func userSkipped(_ segment: AdSegment) -> Double? {
        guard let active = activeSegment, active.id == segment.id else { return nil }
        if let t = lastTime, active.seekTarget <= t { return nil }
        markSkipped(active, origin: lastTime ?? active.start, now: lastNow ?? 0)
        visit?.prompt = .finished
        isPromptVisible = false
        return active.seekTarget
    }

    /// The user closed the prompt (✕): hidden for the rest of this visit.
    func userDismissed(_ segment: AdSegment) {
        if visit?.segmentID == segment.id { visit?.prompt = .finished }
        isPromptVisible = false
    }

    /// Any seek (our own skip completing, or the user scrubbing) ends the current visit; the
    /// next update re-evaluates the position from scratch.
    func didSeek(to time: Double) {
        pendingSeek = nil
        visit = nil
        lastTime = time
    }

    /// "撤销" on the 「已跳过广告」 toast: returns where to seek back to. The segment stays in the
    /// skip history (never auto-skipped again) and no prompt is shown while the user watches it.
    @discardableResult
    func undo(_ segment: AdSegment) -> Double? {
        guard let target = segments.first(where: { $0.id == segment.id }) else { return nil }
        skippedSegmentIDs.insert(target.id)
        pendingSeek = nil
        visit = nil
        undone = (target.id, false)
        let origin = skipOrigins[target.id] ?? target.start
        return min(max(origin, target.start), target.end)
    }

    /// The user is touching the prompt / controls: the countdown pauses (and resumes later
    /// without restarting).
    func setInteracting(_ value: Bool, now: Double) {
        consumeCountdown(now: now)
        interacting = value
        countdownRunning = lastIsPlaying && !interacting
    }

    /// Same video, new segment list or a replaced player item: keeps the skip history.
    func replaceSegments(_ newSegments: [AdSegment]) {
        segments = SmartSkipJS.stableSorted(newSegments) { $0.start - $1.start }
        visit = nil
        pendingSeek = nil
    }

    // MARK: private

    private func markSkipped(_ segment: AdSegment, origin: Double, now: Double) {
        skippedSegmentIDs.insert(segment.id)
        skipOrigins[segment.id] = origin
        pendingSeek = (segment.id, now)
    }

    private func consumeCountdown(now: Double) {
        defer { lastNow = now }
        guard countdownRunning, let last = lastNow, case .visible(let remaining)? = visit?.prompt else { return }
        let elapsed = min(max(0, now - last), maxTickInterval)
        visit?.prompt = .visible(remaining: max(0, remaining - elapsed))
    }

    private func finish(_ prompt: (AdSegment, Double)?) -> SmartSkipAction? {
        if let (segment, remaining) = prompt {
            isPromptVisible = true
            return .showPrompt(segment, countdownRemaining: remaining)
        }
        if isPromptVisible {
            isPromptVisible = false
            return .hidePrompt
        }
        return nil
    }
}
