// SmartSkip — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0. Data shapes of the upstream JS objects (spec §4) @ master 3ce86fa (v2.1.0).
// Part of BiliOverseas (GPL-2.0-or-later).
//
// JS objects are open-ended; the Swift structs carry every field that drives behaviour plus the
// diagnostics the upstream tests assert on. Optional fields model "absent" (`undefined`).

import Foundation

/// One danmaku comment: `{ time /* s */, textContent }`.
struct SmartSkipDanmaku: Hashable {
    var time: Double
    var textContent: String

    init(time: Double, textContent: String) {
        self.time = time
        self.textContent = textContent
    }
}

/// Everything the detectors consume (the upstream `inputs` object plus the description).
struct SmartSkipInputs {
    var bvid: String = ""
    var cid: Int64 = 0
    /// Seconds; `0` = unknown (disables the end-of-video guard, segment-detector returns nothing).
    var duration: Double = 0
    var title: String = ""
    var desc: String = ""
    /// `view_points` (`from`, `to`, `content` ↔ `title`), unfiltered.
    var chapters: [VideoChapter] = []
    /// Sorted ascending by time (stable).
    var danmaku: [SmartSkipDanmaku] = []
    /// Body rows of the chosen subtitle track (`[]` when there is none).
    var subtitles: [SubtitleLine] = []
}

/// `getAdLabelEvidence` result.
struct SmartSkipLabelEvidence: Equatable {
    var matchedKeywords: [String]
    var requiresConfirmation: Bool
    /// `'explicit-ad-label'` | `'ambiguous-ad-label'`
    var reason: String
}

/// `getSubtitleEvidence` result (insertion-ordered, de-duplicated).
struct SmartSkipSubtitleEvidence: Equatable {
    var categories: [String] = []
    var matched: [String] = []
}

struct SmartSkipAlternativeDestination: Equatable {
    var end: Double
    var explicitCount: Int
}

/// `statement(line)` — diagnostics of one subtitle row.
struct SmartSkipStatement: Equatable {
    var from: Double
    var to: Double
    var roles: [String]
    var matchedKeywords: [String]
}

/// A structural chapter envelope (`chapterRanges`).
struct SmartSkipChapterRange: Equatable {
    var start: Double
    var end: Double
    var title: String
}

/// An explicit danmaku destination (`destinations`).
struct SmartSkipDestination: Equatable {
    var time: Double
    var end: Double
    var cues: [String]
    var text: String
}

struct SmartSkipAlternativeEnd: Equatable {
    var end: Double
    var references: Int
}

struct SmartSkipReaction: Equatable {
    var time: Double
    var text: String
}

struct SmartSkipBoundaryPoint: Equatable {
    var kind: String
    var time: Double? = nil
    var returnLine: SmartSkipStatement? = nil
}

/// `boundaryEvidence` of a segment-detector proposal.
struct SmartSkipBoundaryEvidence: Equatable {
    var sources: [String] = []
    var start: SmartSkipBoundaryPoint? = nil
    var end: SmartSkipBoundaryPoint? = nil
    var chapter: SmartSkipChapterRange? = nil
    var timeReferences: [SmartSkipDestination]? = nil
    var alternativeEnds: [SmartSkipAlternativeEnd]? = nil
    var commercialReactions: [SmartSkipReaction]? = nil
}

struct SmartSkipConflictingTimestamp: Equatable {
    var start: Double
    var end: Double
    var matchedKeywords: [String]
}

/// A detection candidate / primary segment / segment-detector proposal (one shape for all, like
/// the JS objects that `combineSkipSegments` inspects).
struct SmartSkipSegment: Equatable {
    var start: Double
    var end: Double
    /// `'chapters' | 'description' | 'danmaku-time' | 'subtitles' | 'danmaku-keywords' | 'segment-detector'`
    var source: String? = nil
    /// `nil` = absent. Every consumer tests `requiresConfirmation !== false` → see `needsConfirmation`.
    var requiresConfirmation: Bool? = nil
    /// `'high'` | `'low'`
    var confidence: String? = nil
    var reason: String? = nil
    var matchedKeywords: [String] = []

    // danmaku-time
    var earlyAdEvidence: Bool? = nil
    var referenceCount: Int? = nil
    var explicitCount: Int? = nil
    var alternativeDestinations: [SmartSkipAlternativeDestination]? = nil

    // subtitles
    var evidenceCategories: [String]? = nil
    var boundaryPaddingSeconds: Double? = nil

    // segment-detector
    var sources: [String]? = nil
    /// `'ad'` | `'uncertain'`
    var contentType: String? = nil
    /// `'skip'` | `'keep'`
    var skipDecision: String? = nil
    var autoEligible: Bool? = nil
    var boundaryConfidence: String? = nil
    var boundaryEvidence: SmartSkipBoundaryEvidence? = nil
    var observedEvidence: [SmartSkipStatement]? = nil
    var observedLineCount: Int? = nil
    var reviewReasons: [String]? = nil

    // combineSkipSegments
    var conflictingTimestamp: SmartSkipConflictingTimestamp? = nil

    /// `requiresConfirmation !== false` (missing means "needs confirmation").
    var needsConfirmation: Bool { requiresConfirmation != false }

    /// The upstream skip-history key `` `${start}:${end}` ``.
    var skipKey: String { "\(SmartSkipJS.numberString(start)):\(SmartSkipJS.numberString(end))" }
}
