// 「空降助手」 — community segments from BilibiliSponsorBlock (https://github.com/hanydd/BilibiliSponsorBlock)
// as a second SmartSkip source (features.md §11). Upstream BiliSmartSkip has no such source: this file is
// not part of the port. Category table and skip semantics follow PiliPlus (`models/common/sponsor_block`).
// Part of BiliOverseas (GPL-2.0-or-later).
//
// Flow: `SponsorBlockClient.skipSegments` (raw rows, cached per video by `SmartSkipAnalyzer`) →
// `SponsorBlockSource.adSegments(_:settings:)` (current per-category settings) → `merge(local:sponsor:)`
// with the local detections → the one `[AdSegment]` list the player draws and `SmartSkipTracker` runs.

import Foundation

/// `actionType` of a submitted segment.
enum SponsorBlockActionType: String {
    case skip, mute, full, poi
}

/// Segment categories (§11.2): 标题, 短标题 (toasts / skip button), default colour, allowed actions.
enum SponsorBlockCategory: String, CaseIterable, Identifiable {
    case sponsor
    case selfpromo
    case exclusiveAccess = "exclusive_access"
    case interaction
    case poiHighlight = "poi_highlight"
    case intro
    case outro
    case preview
    case padding
    case filler
    case musicOfftopic = "music_offtopic"
    case jumpscare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sponsor: return "赞助/恰饭"
        case .selfpromo: return "无偿/自我推广"
        case .exclusiveAccess: return "独家访问/抢先体验"
        case .interaction: return "三连/互动提醒"
        case .poiHighlight: return "精彩时刻/重点"
        case .intro: return "过场/开场动画"
        case .outro: return "鸣谢/结束画面"
        case .preview: return "回顾/概要"
        case .padding: return "填充内容/前黑/后黑"
        case .filler: return "离题闲聊/玩笑"
        case .musicOfftopic: return "音乐:非音乐部分"
        case .jumpscare: return "惊吓片段"
        }
    }

    var shortTitle: String {
        switch self {
        case .sponsor: return "赞助"
        case .selfpromo: return "推广"
        case .exclusiveAccess: return "品牌合作"
        case .interaction: return "三连提醒"
        case .poiHighlight: return "精彩时刻"
        case .intro: return "开场动画"
        case .outro: return "片尾"
        case .preview: return "预览"
        case .padding: return "填充内容"
        case .filler: return "离题"
        case .musicOfftopic: return "非音乐"
        case .jumpscare: return "惊吓"
        }
    }

    /// From BilibiliSponsorBlock's zh_CN messages (via PiliPlus `SegmentType`).
    var detail: String {
        switch self {
        case .sponsor: return "付费推广、推荐和直接广告。不是自我推广或免费提及他们喜欢的商品/创作者/网站/产品。"
        case .selfpromo: return "类似于“赞助广告”，但无报酬或是自我推广。包括有关商品、捐赠的部分或合作者的信息。"
        case .exclusiveAccess: return "仅用于对整个视频进行标记。适用于展示UP主免费或获得补贴后使用的产品、服务或场地的视频。"
        case .interaction: return "视频中间简短提醒观众来一键三连或关注。如果片段较长，或是有具体内容，则应分类为自我推广。"
        case .poiHighlight: return "大部分人都在寻找的空降时间。类似于“封面在12:34”的评论。"
        case .intro: return "没有实际内容的间隔片段。可以是暂停、静态帧或重复动画。不适用于包含内容的过场。"
        case .outro: return "致谢画面或片尾画面。不包含内容的结尾。"
        case .preview: return "展示此视频或同系列视频将出现的画面集锦，片段中所有内容都将在之后的正片中再次出现。"
        case .padding: return "搬运视频片头片尾的纯粹填充内容，如黑屏或无关画面，与视频主体内容无实际意义和关联。"
        case .filler: return "仅作为填充内容或增添趣味而添加的离题片段，这些内容对理解视频的主要内容并非必需。"
        case .musicOfftopic: return "仅用于音乐视频。此分类只能用于音乐视频中未包括于其他分类的部分。"
        case .jumpscare: return "突发大音量、跳脸、恐怖音效及意外惊吓。"
        }
    }

    /// Default strip colour, `0xRRGGBB`.
    var color: UInt32 {
        switch self {
        case .sponsor: return 0x00D400
        case .selfpromo: return 0xFFFF00
        case .exclusiveAccess: return 0x008A5C
        case .interaction: return 0xCC00FF
        case .poiHighlight: return 0xFF1684
        case .intro: return 0x00FFFF
        case .outro: return 0x0202ED
        case .preview: return 0x008FD6
        case .padding: return 0x222222
        case .filler: return 0x7300FF
        case .musicOfftopic: return 0xFF9900
        case .jumpscare: return 0xE53935
        }
    }

    var actions: [SponsorBlockActionType] {
        switch self {
        case .sponsor, .selfpromo: return [.skip, .mute, .full]
        case .exclusiveAccess: return [.full]
        case .interaction, .intro, .outro, .preview, .filler: return [.skip, .mute]
        case .poiHighlight: return [.poi]
        case .padding, .musicOfftopic: return [.skip]
        case .jumpscare: return [.mute]
        }
    }

    /// Categories with time ranges, the ones requested and offered in the settings. Whole-video labels
    /// (`exclusive_access`) and single highlight points (`poi_highlight`) have no player UI yet.
    static let rangeCategories: [SponsorBlockCategory] = allCases.filter { $0.actions.contains(.skip) || $0.actions.contains(.mute) }

    /// Paid / self promotion: the same thing the local detectors look for.
    var isPromotion: Bool { self == .sponsor || self == .selfpromo }
}

/// One row of `GET /api/skipSegments` (`[{category, actionType, segment: [start, end], UUID, videoDuration, votes}]`).
struct SponsorBlockSegment: Equatable {
    var uuid: String
    /// Raw category; unknown ones are kept here and dropped by the mapper.
    var category: String
    /// Raw action type; a missing one means `skip`.
    var actionType: String
    /// Seconds.
    var start: Double
    var end: Double
    var votes: Int = 0
    /// Seconds; `0` = not sent.
    var videoDuration: Double = 0
}

extension SmartSkipSettings {
    /// The configured skip type of `category` (default 跳过一次).
    func sponsorBlockSkipType(for category: SponsorBlockCategory) -> SponsorBlockSkipType {
        sponsorBlockSkipTypes[category.rawValue] ?? .skipOnce
    }

    mutating func setSponsorBlockSkipType(_ type: SponsorBlockSkipType, for category: SponsorBlockCategory) {
        sponsorBlockSkipTypes[category.rawValue] = type
    }
}

enum SponsorBlockSource {
    /// `AdSegment.source` of community segments.
    static let sourceName = "sponsorblock"

    /// Maps raw rows onto player segments with the current settings (PiliPlus `SegmentModel.fromItemModel`):
    /// * unknown or 禁用 categories, empty / reversed ranges (whole-video labels `[0, 0]`, highlight points)
    ///   and `full` / `poi` actions are dropped;
    /// * `mute` segments cannot be muted here, and segments shorter than the minimum length are downgraded:
    ///   both become 仅显示 (`displayOnly`, strip only);
    /// * 总是跳过 / 跳过一次 may auto-skip (`requiresConfirmation == false`), 手动跳过 only gets the button.
    /// Ids are `sponsorblock:<UUID>`, so they never collide with local `start:end` ids.
    static func adSegments(_ rows: [SponsorBlockSegment], settings: SmartSkipSettings) -> [AdSegment] {
        var seen = Set<String>()
        var out: [AdSegment] = []
        for row in rows {
            guard let category = SponsorBlockCategory(rawValue: row.category) else { continue }
            var type = settings.sponsorBlockSkipType(for: category)
            guard type != .disable else { continue }
            let start = max(0, row.start)
            guard row.start.isFinite, row.end.isFinite, row.end > start else { continue }
            switch SponsorBlockActionType(rawValue: row.actionType) ?? .skip {
            case .skip: break
            case .mute: type = .showOnly
            case .full, .poi: continue
            }
            if row.end - start < settings.sponsorBlockMinDuration { type = .showOnly }
            let key = row.uuid.isEmpty ? "\(category.rawValue):\(SmartSkipJS.numberString(start)):\(SmartSkipJS.numberString(row.end))" : row.uuid
            let id = "\(sourceName):\(key)"
            guard seen.insert(id).inserted else { continue }
            out.append(AdSegment(id: id, start: start, end: row.end,
                                 requiresConfirmation: type != .alwaysSkip && type != .skipOnce,
                                 source: sourceName, reason: category.rawValue,
                                 alwaysSkip: type == .alwaysSkip, displayOnly: type == .showOnly,
                                 label: category.shortTitle, color: category.color))
        }
        return out
    }

    /// One list for the player. Community 赞助 / 推广 segments that will be acted on (not 仅显示) have
    /// reviewed boundaries, so local detections overlapping them are dropped; every other segment of
    /// both sources is kept. Sorted by start (stable: local first on ties).
    static func merge(local: [AdSegment], sponsor: [AdSegment]) -> [AdSegment] {
        let authoritative = sponsor.filter { !$0.displayOnly && SponsorBlockCategory(rawValue: $0.reason)?.isPromotion == true }
        let kept = local.filter { segment in
            !authoritative.contains { max(segment.start, $0.start) < min(segment.end, $0.end) }
        }
        return SmartSkipJS.stableSorted(kept + sponsor) { $0.start - $1.start }
    }
}
