// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): runtime tracker (skipper.js
// re-implemented). Upstream `multiple-segments` / `regression` skipper cases @ test-branch 24d28a8
// plus the native rules: skip once, re-entry → manual prompt, exact countdown, seek, undo.

import XCTest
@testable import BiliCore

final class SmartSkipTrackerTests: XCTestCase {
    private func A(_ start: Double, _ end: Double) -> AdSegment {
        AdSegment(start: start, end: end, requiresConfirmation: false, source: "fixture")
    }
    private func M(_ start: Double, _ end: Double) -> AdSegment {
        AdSegment(start: start, end: end, requiresConfirmation: true, source: "fixture")
    }
    private func remaining(_ action: SmartSkipAction?) -> Double? {
        if case .showPrompt(_, let r)? = action { return r }
        return nil
    }

    // MARK: upstream skipper behaviour

    func testSegmentWithoutAnExplicitTrustFlagNeverAutoSkips() {
        let segment = AdSegment(SmartSkipSegment(start: 79, end: 103))
        XCTAssertTrue(segment.requiresConfirmation, "a missing requiresConfirmation means 'needs confirmation'")
        let h = SSHarness(segments: [segment], mode: .auto)
        h.tick(79)
        XCTAssertSeeks(h, [])
        XCTAssertTrue(h.buttonIsSuspicious)
    }

    func testEachIndependentBreakSkipsOnceWithoutSeekingTheNarrative() {
        let h = SSHarness(segments: [A(40, 65), A(150, 190)])
        h.tick(40); h.tick(45); h.tick(65); h.tick(100)
        XCTAssertSeeks(h, [65.05])
        h.tick(150); h.tick(155); h.tick(40)
        XCTAssertSeeks(h, [65.05, 190.05])
        XCTAssertEqual(h.tracker.skippedSegmentIDs.count, 2)
        XCTAssertTrue(h.buttonVisible, "re-entering a skipped break shows the manual button")
        XCTAssertFalse(h.buttonIsSuspicious)
    }

    func testTrustRemainsPerIntervalAcrossAutomaticAndManualBreaks() {
        let h = SSHarness(segments: [A(40, 65), M(100, 130), A(150, 190)])
        h.tick(40); h.tick(100); h.advance(12)
        XCTAssertSeeks(h, [65.05])
        h.tick(150)
        XCTAssertSeeks(h, [65.05, 190.05])
    }

    func testAButtonFromThePrecedingSegmentCannotSeekToItsStaleEnd() {
        let h = SSHarness(segments: [A(40, 65), A(150, 190)], mode: .manual)
        h.tick(40); h.tick(150); h.click()
        XCTAssertSeeks(h, [190.05])
        h.tick(100)
        XCTAssertFalse(h.buttonVisible)
        XCTAssertNil(h.tracker.activeSegment)
        XCTAssertNil(h.tracker.userSkipped(A(40, 65)), "a stale prompt never seeks")
    }

    func testReattachingAReplacementPlayerPreservesSkipHistory() {
        let segments = [A(40, 65), A(150, 190)]
        let h = SSHarness(segments: segments)
        h.tick(40)
        h.tracker.replaceSegments(segments)
        h.tick(40); h.tick(150)
        XCTAssertSeeks(h, [65.05, 190.05])
    }

    func testNavigationCleanupResetsAllIntervalHistory() {
        let segments = [A(40, 65), A(150, 190)]
        let first = SSHarness(segments: segments)
        first.tick(40)
        let second = SSHarness(segments: segments)   // new video → new tracker
        second.tick(40)
        XCTAssertSeeks(first, [65.05])
        XCTAssertSeeks(second, [65.05])
    }

    // MARK: countdown

    func testCountdownIsExactlyFiveSecondsOfPlaybackAndNeverSeeks() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .auto)
        XCTAssertEqual(remaining(tracker.update(time: 100, isPlaying: true, now: 0)), 5)
        var hiddenAt: Double?
        for step in 1...40 {
            let now = Double(step) * 0.25
            let action = tracker.update(time: 100 + now, isPlaying: true, now: now)
            if action == .hidePrompt { hiddenAt = now; break }
            XCTAssertEqual(remaining(action)!, 5 - now, accuracy: 1e-9)
        }
        XCTAssertEqual(hiddenAt, 5)
        XCTAssertNil(tracker.update(time: 106, isPlaying: true, now: 6), "not shown again during the same visit")
        XCTAssertFalse(tracker.isPromptVisible)
    }

    func testCountdownLengthIsConfigurable() {
        let h = SSHarness(segments: [M(100, 200)], countdown: 3)
        h.tick(100)
        XCTAssertEqual(h.prompt?.remaining, 3)
        h.advance(2.75)
        XCTAssertTrue(h.buttonVisible)
        h.advance(0.25)
        XCTAssertFalse(h.buttonVisible)
        XCTAssertSeeks(h, [])
    }

    func testCountdownPausesWhilePausedAndKeepsPartialSeconds() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .manual)
        _ = tracker.update(time: 100, isPlaying: true, now: 0)
        XCTAssertEqual(remaining(tracker.update(time: 100.5, isPlaying: true, now: 0.5))!, 4.5, accuracy: 1e-9)
        XCTAssertEqual(remaining(tracker.update(time: 101.3, isPlaying: true, now: 1.3))!, 3.7, accuracy: 1e-9)
        XCTAssertEqual(remaining(tracker.update(time: 101.3, isPlaying: false, now: 1.3))!, 3.7, accuracy: 1e-9, "pause reported")
        XCTAssertEqual(remaining(tracker.update(time: 101.3, isPlaying: false, now: 30))!, 3.7, accuracy: 1e-9, "no progress while paused")
        XCTAssertEqual(remaining(tracker.update(time: 101.3, isPlaying: true, now: 30))!, 3.7, accuracy: 1e-9, "resume does not restart")
        XCTAssertEqual(remaining(tracker.update(time: 101.8, isPlaying: true, now: 30.5))!, 3.2, accuracy: 1e-9)
    }

    func testCountdownDoesNotStartWhileTheVideoIsPaused() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .manual)
        XCTAssertEqual(remaining(tracker.update(time: 150, isPlaying: false, now: 0)), 5, "user scrubbed in while paused")
        XCTAssertEqual(remaining(tracker.update(time: 150, isPlaying: false, now: 60)), 5)
    }

    func testInteractionPausesTheCountdownWithoutRestartingIt() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .manual)
        _ = tracker.update(time: 100, isPlaying: true, now: 0)
        _ = tracker.update(time: 101, isPlaying: true, now: 1)
        tracker.setInteracting(true, now: 1.5)
        XCTAssertEqual(remaining(tracker.update(time: 102, isPlaying: true, now: 2)), 3.5)
        XCTAssertEqual(remaining(tracker.update(time: 103, isPlaying: true, now: 3)), 3.5, "frozen while touching")
        tracker.setInteracting(false, now: 3.5)
        XCTAssertEqual(remaining(tracker.update(time: 104, isPlaying: true, now: 4)), 3.0)
    }

    /// SwiftUI's `onHover` sends no `false` when the prompt is removed under the pointer, so an
    /// interaction never outlives the visit whose prompt it was on.
    func testInteractionEndsWithItsVisit() {
        let h = SSHarness(segments: [M(100, 130), M(200, 230)], mode: .manual)
        h.tick(100)
        h.tracker.setInteracting(true, now: h.now)
        h.advance(2)
        h.dismiss()                       // prompt removed while "hovered"
        h.tick(150)
        h.tick(200)
        XCTAssertTrue(h.buttonVisible)
        h.advance(5.25)
        XCTAssertFalse(h.buttonVisible, "the next prompt counts down and hides")
    }

    func testALongSilentGapCountsAsAtMostOneTick() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .manual)
        _ = tracker.update(time: 100, isPlaying: true, now: 0)
        XCTAssertEqual(remaining(tracker.update(time: 100.2, isPlaying: true, now: 120)), 4,
                       "the periodic observer was silent (paused / backgrounded)")
    }

    /// skipper.js §10.2: a trusted segment's button has no countdown; it stays until the interval is left.
    func testManualModeTrustedSegmentButtonStaysUntilLeftAndReappearsOnReentry() {
        let h = SSHarness(segments: [A(100, 200)], mode: .manual)
        h.tick(100)
        XCTAssertTrue(h.buttonVisible)
        XCTAssertFalse(h.buttonIsSuspicious)
        XCTAssertEqual(h.prompt?.remaining, .infinity)
        h.advance(30)
        XCTAssertTrue(h.buttonVisible, "no countdown for a trusted segment")
        h.tick(210)
        XCTAssertFalse(h.buttonVisible, "gone once the interval is left")
        h.tick(150)
        XCTAssertTrue(h.buttonVisible, "a new visit offers the button again")
        XCTAssertSeeks(h, [])
    }

    func testReenteringAnAutoSkippedSegmentOffersALastingButton() {
        let h = SSHarness(segments: [A(100, 200)], mode: .auto)
        h.tick(100)
        XCTAssertSeeks(h, [200.05])
        h.seeked()
        h.tick(250)
        h.tick(150)
        h.advance(20)
        XCTAssertTrue(h.buttonVisible, "dragged back in: 「跳过广告」 stays (upstream README)")
        XCTAssertSeeks(h, [200.05])
    }

    func testMarkSkippedFromTheSegmentListStopsAutoSkip() {
        let h = SSHarness(segments: [A(100, 200), A(300, 360)], mode: .auto)
        h.tracker.markSkipped(id: A(300, 360).id)
        h.tracker.markSkipped(id: "unknown")
        h.tick(310)
        XCTAssertSeeks(h, [], "already skipped from the list: only the button")
        XCTAssertTrue(h.buttonVisible)
        XCTAssertEqual(h.tracker.skippedSegmentIDs, [A(300, 360).id])
    }

    // MARK: user actions

    func testDismissHidesThePromptForTheVisitOnly() {
        let h = SSHarness(segments: [M(100, 200)])
        h.tick(100)
        h.dismiss()
        h.tick(101)
        h.advance(1)
        XCTAssertFalse(h.buttonVisible)
        h.tick(250)
        h.tick(120)
        XCTAssertTrue(h.buttonVisible)
    }

    func testManualSkipMarksTheSegmentSkippedSoAutoModeNeverSkipsItAgain() {
        let h = SSHarness(segments: [A(100, 200)], mode: .manual)
        h.tick(100)
        h.click()
        XCTAssertSeeks(h, [200.05])
        XCTAssertEqual(h.tracker.skippedSegmentIDs, ["100:200"])
        h.setMode(.auto)
        h.seeked()
        h.tick(150)
        XCTAssertSeeks(h, [200.05])
        XCTAssertTrue(h.buttonVisible)
    }

    func testTicksDuringAnInFlightSeekAreIgnoredThenTreatedAsReentry() {
        let tracker = SmartSkipTracker(segments: [A(100, 200)], mode: .auto)
        XCTAssertEqual(tracker.update(time: 100, isPlaying: true, now: 0), .autoSkip(A(100, 200)))
        XCTAssertNil(tracker.update(time: 100.2, isPlaying: true, now: 0.25), "seek still in flight")
        XCTAssertNil(tracker.update(time: 100.4, isPlaying: true, now: 0.75))
        XCTAssertEqual(remaining(tracker.update(time: 100.6, isPlaying: true, now: 1.0)), .infinity,
                       "the seek never landed: offer the (lasting) manual button, never auto-skip twice")
    }

    func testDidSeekEndsTheInFlightState() {
        let tracker = SmartSkipTracker(segments: [A(100, 200)], mode: .auto)
        _ = tracker.update(time: 100, isPlaying: true, now: 0)
        tracker.didSeek(to: 150)   // e.g. the user scrubbed back in right away
        XCTAssertEqual(remaining(tracker.update(time: 150, isPlaying: true, now: 0.1)), .infinity)
    }

    func testSeekingOutHidesThePromptAndSeekingWithinStartsAFreshVisit() {
        let tracker = SmartSkipTracker(segments: [M(100, 200)], mode: .manual)
        _ = tracker.update(time: 100, isPlaying: true, now: 0)
        tracker.userDismissed(M(100, 200))
        XCTAssertNil(tracker.update(time: 101, isPlaying: true, now: 1))
        tracker.didSeek(to: 150)
        XCTAssertEqual(remaining(tracker.update(time: 150, isPlaying: true, now: 2)), 5)
        tracker.didSeek(to: 300)
        XCTAssertEqual(tracker.update(time: 300, isPlaying: true, now: 3), .hidePrompt)
        XCTAssertNil(tracker.update(time: 300.25, isPlaying: true, now: 3.25))
    }

    func testUndoSeeksBackAndNeverAutoSkipsThatSegmentAgain() {
        let h = SSHarness(segments: [A(100, 160)])
        h.tick(100.2)
        XCTAssertSeeks(h, [160.05])
        h.seeked()
        h.tick(160.3)
        h.tick(160.5)                                   // an update before the undo seek lands
        let back = h.tracker.undo(A(100, 160))
        XCTAssertEqual(back, 100.2, "back to where the skip happened")
        h.seek(back!)
        h.seeked()
        h.tick(100.4)
        h.advance(3)
        h.tick(130)
        XCTAssertSeeks(h, [160.05, 100.2])
        XCTAssertFalse(h.buttonVisible, "no prompt while the user chose to watch it")
        h.tick(161)
        h.tick(120)
        XCTAssertTrue(h.buttonVisible, "a later re-entry offers the manual button")
        XCTAssertSeeks(h, [160.05, 100.2])
        XCTAssertNil(h.tracker.undo(A(1, 2)), "unknown segment")
    }

    func testModeSwitchToAutoWhilePromptIsVisibleSkipsOnTheNextTick() {
        let tracker = SmartSkipTracker(segments: [A(100, 200)], mode: .manual)
        XCTAssertEqual(remaining(tracker.update(time: 100, isPlaying: true, now: 0)), .infinity)
        tracker.mode = .auto
        XCTAssertEqual(tracker.update(time: 100.25, isPlaying: true, now: 0.25), .autoSkip(A(100, 200)))
        XCTAssertFalse(tracker.isPromptVisible)
    }

    func testAdjacentSegmentsHandOverThePromptDirectly() {
        let tracker = SmartSkipTracker(segments: [M(65, 80), M(40, 65)], mode: .manual)
        XCTAssertEqual(tracker.segments.map(\.start), [40, 65], "sorted by start")
        XCTAssertEqual(tracker.update(time: 50, isPlaying: true, now: 0), .showPrompt(M(40, 65), countdownRemaining: 5))
        XCTAssertEqual(tracker.update(time: 66, isPlaying: true, now: 0.25), .showPrompt(M(65, 80), countdownRemaining: 5))
        XCTAssertEqual(tracker.update(time: 80, isPlaying: true, now: 0.5), .hidePrompt, "[start, end) is half-open")
    }

    func testHalfOpenIntervalBoundaries() {
        let tracker = SmartSkipTracker(segments: [A(40, 65)], mode: .auto)
        XCTAssertNil(tracker.update(time: 39.99, isPlaying: true, now: 0))
        XCTAssertNil(tracker.update(time: 65, isPlaying: true, now: 0.25))
        XCTAssertEqual(tracker.update(time: 40, isPlaying: true, now: 0.5), .autoSkip(A(40, 65)))
    }

    func testSuspiciousSegmentInAutoModeOnlyEverPrompts() {
        let h = SSHarness(segments: [M(100, 200)], mode: .auto)
        h.tick(100)
        h.advance(1)
        h.tick(150)
        XCTAssertSeeks(h, [])
        XCTAssertTrue(h.buttonIsSuspicious)
        h.click()
        XCTAssertSeeks(h, [200.05])
    }

    func testAdSegmentIdentityAndSeekTarget() {
        let segment = AdSegment(SmartSkipSegment(start: 39.751, end: 92, source: "danmaku-time", requiresConfirmation: false,
                                                 reason: "explicit-danmaku-skip", matchedKeywords: ["跳伞"]))
        XCTAssertEqual(segment.id, "39.751:92")
        XCTAssertEqual(segment.seekTarget, 92.05, accuracy: 1e-9)
        XCTAssertFalse(segment.requiresConfirmation)
        XCTAssertEqual(segment.source, "danmaku-time")
        XCTAssertEqual(segment.reason, "explicit-danmaku-skip")
        XCTAssertEqual(segment.matchedKeywords, ["跳伞"])
        XCTAssertEqual(AdSegment(start: 79, end: 103, requiresConfirmation: true, source: "x").id, "79:103")
    }
}
