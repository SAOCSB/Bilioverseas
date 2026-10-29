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
//      toast `seg.skippedToast` ("已跳过广告") with "撤销" → `tracker.undo(seg)` returns the time to seek back to.
//      `.showPrompt(seg, remaining)`: show `SmartSkipPromptView` (`seg.promptTitle`); `.hidePrompt`: hide it.
//      Segments with `displayOnly` (空降助手 仅显示) are only drawn; the tracker drops them.
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
    /// Stable per detection: the upstream skip-history key `"start:end"` (local detections never
    /// overlap); `sponsorblock:<UUID>` for community segments.
    let id: String
    let start: Double
    let end: Double
    /// `true` → only a manual 「跳过广告」 prompt (never auto-skipped); `false` → may auto-skip.
    let requiresConfirmation: Bool
    /// `chapters`, `description`, `danmaku-time`, `subtitles`, `danmaku-keywords`, `segment-detector`;
    /// `sponsorblock` (「空降助手」).
    let source: String
    /// Machine-readable reason, e.g. `explicit-ad-label`, `explicit-danmaku-skip`,
    /// `complete-sponsor-break`, `cross-source-boundary-conflict`; the category (`sponsor`, `intro` …)
    /// for `sponsorblock`.
    let reason: String
    let matchedKeywords: [String]
    /// 空降助手 总是跳过: auto-skipped on every entry, not only the first (auto mode only).
    let alwaysSkip: Bool
    /// 空降助手 仅显示: drawn on the progress bar only; `SmartSkipTracker` ignores it.
    let displayOnly: Bool
    /// 空降助手 短标题 (「赞助」「开场动画」…) for the button and toast; `nil` = a local ad detection.
    let label: String?
    /// Strip colour `0xRRGGBB` (空降助手 category colour); `nil` = the default ad colours.
    let color: UInt32?

    init(id: String? = nil, start: Double, end: Double, requiresConfirmation: Bool, source: String,
         reason: String = "", matchedKeywords: [String] = [], alwaysSkip: Bool = false, displayOnly: Bool = false,
         label: String? = nil, color: UInt32? = nil) {
        self.id = id ?? "\(SmartSkipJS.numberString(start)):\(SmartSkipJS.numberString(end))"
        self.start = start
        self.end = end
        self.requiresConfirmation = requiresConfirmation
        self.source = source
        self.reason = reason
        self.matchedKeywords = matchedKeywords
        self.alwaysSkip = alwaysSkip
        self.displayOnly = displayOnly
        self.label = label
        self.color = color
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

    /// Title of the manual skip button: 「跳过广告」 / 「跳过疑似广告」, 「跳过: 赞助」 for 空降助手.
    var promptTitle: String {
        if let label { return "跳过: \(label)" }
        return requiresConfirmation ? "跳过疑似广告" : "跳过广告"
    }

    /// Toast after a skip: 「已跳过广告」, 「已跳过赞助片段」 for 空降助手 (features.md §11.4).
    var skippedToast: String { label.map { "已跳过\($0)片段" } ?? "已跳过广告" }
}

// MARK: - Analyzer

/// Public detection entry. Fills missing data (view / player / danmaku / subtitle requests as
/// upstream `api.js`), runs the master pipeline off the main actor and caches per video. With
/// 「空降助手」 on, the BilibiliSponsorBlock segments are fetched alongside and merged in
/// (`SponsorBlockSource.merge`).
actor SmartSkipAnalyzer {
    static let shared = SmartSkipAnalyzer()

    private let loader: SmartSkipDataLoader
    private let sponsorBlock: SponsorBlockClient
    private let accountID: @Sendable () -> Int64
    /// Local detections per account + video part. Only results from complete inputs are kept:
    /// upstream re-runs on every page load, so one failed request must not stick for the session.
    private var cache: [String: [AdSegment]] = [:]
    private var cacheOrder: [String] = []
    /// Raw community rows per server + video part (successful lookups only, 404 included).
    private var sponsorCache: [String: [SponsorBlockSegment]] = [:]
    private var sponsorCacheOrder: [String] = []
    private let cacheLimit = 16

    /// `sponsorBlock` defaults to the loader's transport; `accountID` (the logged-in mid, `0` when
    /// logged out) is part of the cache key: logging in can unlock AI subtitles.
    init(loader: SmartSkipDataLoader = SmartSkipDataLoader(), sponsorBlock: SponsorBlockClient? = nil,
         accountID: @escaping @Sendable () -> Int64 = { BiliHTTP.shared.mid ?? 0 }) {
        self.loader = loader
        self.sponsorBlock = sponsorBlock ?? SponsorBlockClient(transport: loader.transport)
        self.accountID = accountID
    }

    /// Returns the segments to skip, sorted by start (empty when nothing is found, the cid
    /// cannot be resolved, or the task was cancelled). `settings` picks the sources and the
    /// 空降助手 per-category rules; it is read on the caller's actor.
    func analyze(_ context: SmartSkipVideoContext, settings: SmartSkipSettings = AppSettings.shared.smartSkip) async -> [AdSegment] {
        guard settings.localDetection || settings.sponsorBlockEnabled else { return [] }
        guard let resolved = await loader.resolve(context), !Task.isCancelled else { return [] }
        async let local: [AdSegment] = settings.localDetection ? detectLocally(resolved) : []
        async let community: [SponsorBlockSegment] = settings.sponsorBlockEnabled
            ? communitySegments(resolved, server: settings.sponsorBlockServer) : []
        let (localSegments, rows) = await (local, community)
        guard !Task.isCancelled else { return [] }
        return SponsorBlockSource.merge(local: localSegments,
                                        sponsor: SponsorBlockSource.adSegments(rows, settings: settings))
    }

    /// The BiliSmartSkip pipeline on the completed inputs (cached when nothing failed).
    private func detectLocally(_ context: SmartSkipVideoContext) async -> [AdSegment] {
        let key = "\(accountID()):\(context.bvid.isEmpty ? "av\(context.aid)" : context.bvid):\(context.cid):\(context.page)"
        if let hit = cache[key] { return hit }
        guard let loaded = await loader.load(context), !Task.isCancelled else { return [] }
        let segments = SmartSkipPipeline.getSkipSegments(loaded.context.inputs).map(AdSegment.init)
        guard !Task.isCancelled else { return [] }
        if !loaded.degraded { Self.store(segments, key, in: &cache, order: &cacheOrder, limit: cacheLimit) }
        return segments
    }

    /// 空降助手 rows of the part; a failed lookup is `[]` and not cached (the next open retries).
    private func communitySegments(_ context: SmartSkipVideoContext, server: String) async -> [SponsorBlockSegment] {
        let bvid = context.bvid.isEmpty && context.aid > 0 ? BVConverter.av2bv(context.aid) : context.bvid
        let key = "\(server)|\(bvid):\(context.cid)"
        if let hit = sponsorCache[key] { return hit }
        guard let rows = await sponsorBlock.skipSegments(bvid: bvid, cid: context.cid, server: server),
              !Task.isCancelled else { return [] }
        Self.store(rows, key, in: &sponsorCache, order: &sponsorCacheOrder, limit: cacheLimit)
        return rows
    }

    private static func store<T>(_ value: T, _ key: String, in cache: inout [String: T], order: inout [String], limit: Int) {
        cache[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > limit { cache[order.removeFirst()] = nil }
    }

    /// Pure, synchronous detection on complete data (no network).
    static func detect(_ inputs: SmartSkipInputs) -> [AdSegment] {
        SmartSkipPipeline.getSkipSegments(inputs).map(AdSegment.init)
    }

    func clearCache() {
        cache = [:]
        cacheOrder = []
        sponsorCache = [:]
        sponsorCacheOrder = []
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
/// * 空降助手 (native addition): `displayOnly` segments are left out; an `alwaysSkip` segment is
///   auto-skipped on every entry in auto mode, except while the user watches it after 「撤销」. An entry
///   needs a position outside it since its last skip, so a seek that cannot leave it never repeats.
final class SmartSkipTracker {
    /// The actionable segments (`displayOnly` ones removed), sorted by start.
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
    /// 总是跳过 segments auto-skipped and not yet seen to be left: one whose end lies past the media's real end
    /// gets its seek clamped to the duration, still inside, and must not seek again on every tick.
    private var skipsAwaitingExit: Set<String> = []
    private var undone: (segmentID: String, entered: Bool)?
    private var skipOrigins: [String: Double] = [:]
    private var lastTime: Double?
    private var lastNow: Double?
    private var countdownRunning = false
    private var lastIsPlaying = false
    private var interacting = false

    init(segments: [AdSegment], mode: SmartSkipMode, countdownSeconds: Double = Double(SmartSkipConstants.countdown)) {
        self.segments = SmartSkipJS.stableSorted(segments.filter { !$0.displayOnly }) { $0.start - $1.start }
        self.mode = mode
        self.countdownSeconds = countdownSeconds
    }

    /// Feed the current playback position. Returns the action to apply, or `nil` if nothing
    /// changes. `now` is a monotonic clock in seconds (e.g. `ProcessInfo.processInfo.systemUptime`).
    func update(time: Double, isPlaying: Bool, now: Double) -> SmartSkipAction? {
        consumeCountdown(now: now)
        lastTime = time
        lastIsPlaying = isPlaying

        let active = segments.first { time >= $0.start && time < $0.end }
        activeSegment = active
        if active?.id != visit?.segmentID {
            visit = active.map { Visit(segmentID: $0.id) }
            // An interaction belonged to the previous visit's prompt (a hover that ends by the
            // prompt disappearing never reports `false`).
            interacting = false
            if let p = pendingSeek, p.segmentID != active?.id { pendingSeek = nil }
        }
        countdownRunning = isPlaying && !interacting
        if let u = undone {
            if active?.id == u.segmentID { undone?.entered = true } else if u.entered { undone = nil }
        }
        if !skipsAwaitingExit.isEmpty {
            skipsAwaitingExit = skipsAwaitingExit.filter { id in
                segments.contains { $0.id == id && time >= $0.start && time < $0.end }
            }
        }
        guard let segment = active else { return finish(nil) }

        // Our own seek out of this segment is still in flight.
        if let p = pendingSeek, p.segmentID == segment.id {
            if now - p.issuedAt < seekSettleTimeout { return finish(nil) }
            pendingSeek = nil
        }

        let skipped = skippedSegmentIDs.contains(segment.id)
        let skipAgain = segment.alwaysSkip && undone?.segmentID != segment.id && !skipsAwaitingExit.contains(segment.id)
        if mode == .auto && (!skipped || skipAgain) && !segment.requiresConfirmation {
            markSkipped(segment, origin: time, now: now)
            if segment.alwaysSkip { skipsAwaitingExit.insert(segment.id) }
            isPromptVisible = false
            return .autoSkip(segment)
        }

        if undone?.segmentID == segment.id { return finish(nil) }   // user chose to watch it
        switch visit?.prompt ?? .finished {
        case .notShown:
            // skipper.js §10.2: only a suspicious segment counts down; a trusted one (manual mode, or a
            // skipped one entered again) keeps its 「跳过广告」 button until the interval is left (∞ never expires).
            let initial = segment.requiresConfirmation ? countdownSeconds : .infinity
            visit?.prompt = .visible(remaining: initial)
            return finish((segment, initial))
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

    /// Skipped from outside the prompt (the player's segment list): joins the skip history, so auto mode
    /// does not skip it again. The caller seeks; no seek is awaited here.
    func markSkipped(id: String) {
        guard segments.contains(where: { $0.id == id }) else { return }
        skippedSegmentIDs.insert(id)
    }

    /// Any seek (our own skip completing, or the user scrubbing) ends the current visit; the
    /// next update re-evaluates the position from scratch.
    func didSeek(to time: Double) {
        pendingSeek = nil
        visit = nil
        interacting = false
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
        segments = SmartSkipJS.stableSorted(newSegments.filter { !$0.displayOnly }) { $0.start - $1.start }
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
