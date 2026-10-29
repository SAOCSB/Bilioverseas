import Foundation

// Feed filtering ("屏蔽广告视频"). Foundation only, Linux-compilable.
//
// Rule matrix (✓ = applies, A = only when `applyToAllLists`, – = never):
//
// | rule                                   | recommend | popular / ranking / related | search | dynamics | space | history / favorites |
// |----------------------------------------|-----------|-----------------------------|--------|----------|-------|---------------------|
// | ad cards (`kind == .ad`, hard signals) | ✓         | ✓                           | ✓      | ✓        | ✓     | –                   |
// | account blacklist (拉黑, `blackMids`)   | ✓         | ✓                           | ✓      | ✓        | –     | –                   |
// | live / PGC cards                       | ✓         | –                           | –      | –        | –     | –                   |
// | blocked UPs (not follow-exempt)        | ✓         | A                           | A      | ✓ (*)    | –     | –                   |
// | 疑似恰饭 heuristic                      | ✓         | A                           | A      | ✓ (*)    | –     | –                   |
// | keywords (title; dynamics: + text)     | ✓         | A                           | A      | ✓ (*)    | –     | –                   |
// | zone (分区, `tname`)                    | ✓         | A (popular / ranking)       | –      | –        | –     | –                   |
// | duration / like ratio / play count     | ✓         | A                           | –      | –        | –     | –                   |
//
// `exemptFollowed` skips every user rule below "blocked UPs" for followed UPs. (*) Dynamics only
// contain followed UPs, so there the UP / 恰饭 (PiliPlus `antiGoodsDyn`) / keyword rules run without
// the exemption; keywords also match the text of image / text posts (PiliPlus ban words over opus text).
// The account blacklist is never shown on the blocked UP's own space page.
// History and favorites are lists the user built — nothing is ever removed from them.

/// Which list a card is shown in; decides which `FeedFilter` rules apply.
enum FeedScope: String, CaseIterable, Hashable {
    case recommend, popular, ranking, search, related, dynamics, space, history, favorites

    /// Lists the user built themselves (never filtered).
    var isUserCurated: Bool { self == .history || self == .favorites }
}

/// Why a card was hidden (see `FeedFilter.reason(for:scope:)`).
enum FeedFilterReason: Equatable, CustomStringConvertible {
    case ad(signal: String)
    case liveCard
    case pgcCard
    case promoted(evidence: String)
    case keyword(rule: String)
    case uploader(rule: String)
    /// The zone name (`VideoCard.zone`) matched a 分区屏蔽 rule.
    case zone(rule: String)
    /// The UP is on the account blacklist (拉黑).
    case blacklisted
    case tooShort(duration: Int, minimum: Int)
    case lowLikeRatio(likes: Int64, views: Int64, minimumPercent: Int)
    case lowPlayCount(views: Int64, minimum: Int)

    var description: String {
        switch self {
        case .ad(let signal): return "广告卡片（\(signal)）"
        case .liveCard: return "直播卡片"
        case .pgcCard: return "番剧/课程卡片"
        case .promoted(let evidence): return "疑似恰饭：\(evidence)"
        case .keyword(let rule): return "命中关键词 \(rule)"
        case .uploader(let rule): return "已屏蔽的 UP 主 \(rule)"
        case .zone(let rule): return "命中分区 \(rule)"
        case .blacklisted: return "已拉黑的用户"
        case .tooShort(let d, let m): return "时长 \(d) 秒，短于 \(m) 秒"
        case .lowLikeRatio(let l, let v, let m):
            let pct = v > 0 ? Double(l) * 100 / Double(v) : 0
            return "点赞率 " + String(format: "%.2f", pct) + "%，低于 \(m)%"
        case .lowPlayCount(let v, let m): return "播放量 \(v)，低于 \(m)"
        }
    }
}

/// Immutable filter built from `FeedFilterSettings`. Cheap to query; regexes are compiled once
/// (and cached process-wide by pattern).
struct FeedFilter {
    let settings: FeedFilterSettings
    private let isFollowedMid: (Int64) -> Bool
    private let isBlacklistedMid: (Int64) -> Bool
    private let keywordRules: [FeedKeywordRule]
    /// 分区屏蔽: same format as the keywords, matched against `VideoCard.zone`.
    private let zoneRules: [FeedKeywordRule]
    /// mid → the rule text the user entered.
    private let blockedMids: [Int64: String]
    /// lower-cased name → the rule text the user entered.
    private let blockedNames: [String: String]

    /// - Parameters:
    ///   - isFollowed: whether the current user follows a mid (in addition to `VideoCard.isFollowed`).
    ///   - isBlacklisted: whether a mid is on the account blacklist (`AccountBlacklistStore`).
    init(settings: FeedFilterSettings, isFollowed: @escaping (Int64) -> Bool = { _ in false },
         isBlacklisted: @escaping (Int64) -> Bool = { _ in false }) {
        self.settings = settings
        self.isFollowedMid = isFollowed
        self.isBlacklistedMid = isBlacklisted
        self.keywordRules = settings.blockedKeywords.compactMap(FeedKeywordRule.init)
        self.zoneRules = settings.blockedZones.compactMap(FeedKeywordRule.init)
        var mids: [Int64: String] = [:]
        var names: [String: String] = [:]
        for raw in settings.blockedUploaders {
            let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { continue }
            if let mid = FeedFilter.parseMid(rule) { mids[mid] = rule }
            let name = rule.hasPrefix("@") ? String(rule.dropFirst()) : rule
            if !name.isEmpty { names[name.lowercased()] = rule }
        }
        self.blockedMids = mids
        self.blockedNames = names
    }

    init(settings: FeedFilterSettings, followedMids: Set<Int64>, blacklistedMids: Set<Int64> = []) {
        self.init(settings: settings, isFollowed: { followedMids.contains($0) },
                  isBlacklisted: { blacklistedMids.contains($0) })
    }

    // MARK: Queries

    func allows(_ card: VideoCard, scope: FeedScope) -> Bool {
        reason(for: card, scope: scope) == nil
    }

    /// Human-readable reason the card is hidden (for debugging / "为什么屏蔽"), nil when allowed.
    func explain(_ card: VideoCard, scope: FeedScope) -> String? {
        reason(for: card, scope: scope)?.description
    }

    /// Closure for `PagedListModel(filter:)`. Captures this snapshot of the settings; use
    /// `FeedFilter.liveFilter(scope:)` to follow settings changes without rebuilding the model.
    func filterClosure(scope: FeedScope) -> (VideoCard) -> Bool {
        let filter = self
        return { filter.allows($0, scope: scope) }
    }

    /// Filters a whole array (for lists that don't use `PagedListModel`, e.g. related videos).
    func apply(_ cards: [VideoCard], scope: FeedScope) -> [VideoCard] {
        cards.filter { allows($0, scope: scope) }
    }

    func reason(for card: VideoCard, scope: FeedScope) -> FeedFilterReason? {
        if scope.isUserCurated { return nil }

        if settings.blockAdCards, let signal = FeedFilter.hardAdSignal(of: card) {
            return .ad(signal: signal)
        }
        // 拉黑 is the user's own account-level block (PiliPlus `blackMids`): no switch, no exemption.
        if scope != .space, card.ownerMid != 0, isBlacklistedMid(card.ownerMid) { return .blacklisted }
        if scope == .recommend {
            if settings.blockLiveCards && card.kind == .live { return .liveCard }
            if settings.blockPGCCards && card.kind == .bangumi { return .pgcCard }
        }

        switch scope {
        case .recommend:
            break
        case .popular, .ranking, .search, .related:
            guard settings.applyToAllLists else { return nil }
        case .dynamics:
            // Every dynamic comes from a followed UP, so the follow exemption would switch these off.
            if let rule = matchUploader(card) { return .uploader(rule: rule) }
            if settings.blockPromotedVideos, let evidence = FeedPromotionDetector.evidence(for: card) {
                return .promoted(evidence: evidence)
            }
            if let rule = matchKeyword(card, includingText: !FeedFilter.isPlayableKind(card.kind)) {
                return .keyword(rule: rule)
            }
            return nil
        case .space, .history, .favorites:
            return nil
        }

        // Explicit per-UP blocks win over the follow exemption.
        if let rule = matchUploader(card) { return .uploader(rule: rule) }
        if settings.exemptFollowed && isFollowed(card) { return nil }

        if settings.blockPromotedVideos, let evidence = FeedPromotionDetector.evidence(for: card) {
            return .promoted(evidence: evidence)
        }
        if let rule = matchKeyword(card, includingText: false) { return .keyword(rule: rule) }
        if !zoneRules.isEmpty, !card.zone.isEmpty, scope == .recommend || scope == .popular || scope == .ranking,
           let rule = zoneRules.first(where: { $0.matches(card.zone) }) {
            return .zone(rule: rule.source)
        }

        // Numeric thresholds: plain videos only, never on search results (the user asked for them).
        guard card.kind == .video, scope != .search else { return nil }
        if settings.minDuration > 0, card.duration > 0, card.duration < settings.minDuration {
            return .tooShort(duration: card.duration, minimum: settings.minDuration)
        }
        if settings.minPlayCount > 0, card.viewCount > 0, card.viewCount < Int64(settings.minPlayCount) {
            return .lowPlayCount(views: card.viewCount, minimum: settings.minPlayCount)
        }
        if settings.minLikeRatio > 0, card.likeCount > 0, card.viewCount > 0,
           card.likeCount * 100 < Int64(settings.minLikeRatio) * card.viewCount {
            return .lowLikeRatio(likes: card.likeCount, views: card.viewCount, minimumPercent: settings.minLikeRatio)
        }
        return nil
    }

    /// Followed via the card flag, the followed-mids provider, or the feed's 「已关注」 reason badge.
    func isFollowed(_ card: VideoCard) -> Bool {
        if card.isFollowed { return true }
        if card.ownerMid != 0 && isFollowedMid(card.ownerMid) { return true }
        return FeedFilter.followedMarkers.contains(card.reason) || FeedFilter.followedMarkers.contains(card.badge)
    }

    /// The 「UP 主屏蔽」 rule that hides this card's uploader, nil when none does.
    func matchUploader(_ card: VideoCard) -> String? {
        if card.ownerMid != 0, let rule = blockedMids[card.ownerMid] { return rule }
        if !card.ownerName.isEmpty, let rule = blockedNames[card.ownerName.lowercased()] { return rule }
        return nil
    }

    /// First keyword rule matching the title (`<em>` markup stripped), and with `includingText` also
    /// `desc` (the text of image / text dynamics).
    private func matchKeyword(_ card: VideoCard, includingText: Bool) -> String? {
        guard !keywordRules.isEmpty else { return nil }
        let title = card.title.contains("<") ? card.title.strippingHTMLTags : card.title
        let text = includingText && !card.desc.isEmpty ? title + "\n" + card.desc : title
        return keywordRules.first(where: { $0.matches(text) })?.source
    }

    // MARK: Helpers (static, also used by the settings UI and tests)

    static let followedMarkers: Set<String> = ["已关注", "新关注"]

    /// Video / episode / live cards: in 动态 their `desc` is the video description, not the post text.
    static func isPlayableKind(_ kind: CardKind) -> Bool {
        kind == .video || kind == .bangumi || kind == .live
    }

    /// `adSignals` (api-lists.md §1.5) that mark a UP's own commerce, not a platform ad card:
    /// goods attached to a dynamic / video (带货) and game promotion attachments. They only count
    /// for the 恰饭 rule, even when the parser also set `kind = .ad` for them.
    static func isSoftPromotionSignal(_ signal: String) -> Bool {
        let s = signal.lowercased()
        return s.contains("goods") || s == "game"
    }

    /// The first hard ad signal (`goto=ad`, `business_info`, `card_goto=ad_*`, `ad_info`,
    /// `card_type=cm_*` …), or `"kind=ad"` for an `.ad` card without signals; nil when not an ad card.
    static func hardAdSignal(of card: VideoCard) -> String? {
        if let s = card.adSignals.first(where: { !isSoftPromotionSignal($0) }) { return s }
        if card.kind == .ad && card.adSignals.isEmpty { return "kind=ad" }
        return nil
    }

    /// `12345`, `UID:12345`, `uid 12345`, `mid:12345` → 12345.
    static func parseMid(_ rule: String) -> Int64? {
        var s = rule.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["uid:", "uid：", "uid", "mid:", "mid：", "mid"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !s.isEmpty, s.count <= 19, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let mid = Int64(s), mid > 0 else { return nil }
        return mid
    }

    /// False for a `/regex/` rule that does not compile (it is ignored by the filter) or an empty rule.
    static func isValidKeywordRule(_ rule: String) -> Bool {
        FeedKeywordRule(rule) != nil
    }
}

// MARK: - Shared instance

extension FeedFilter {
    private static let currentLock = NSLock()
    private static var cachedCurrent: (settings: FeedFilterSettings, filter: FeedFilter)?

    /// Filter for the current `AppSettings.shared.feedFilter`, `FollowedUpsStore.shared` and
    /// `AccountBlacklistStore.shared`. Rebuilt only when the settings change. Read it on the main
    /// thread (AppSettings is UI state).
    static var current: FeedFilter {
        let settings = AppSettings.shared.feedFilter
        currentLock.lock()
        defer { currentLock.unlock() }
        if let cached = cachedCurrent, cached.settings == settings { return cached.filter }
        let store = FollowedUpsStore.shared
        let blacklist = AccountBlacklistStore.shared
        let filter = FeedFilter(settings: settings, isFollowed: { store.contains($0) },
                                isBlacklisted: { blacklist.contains($0) })
        cachedCurrent = (settings, filter)
        return filter
    }

    /// Like `current.filterClosure(scope:)`, but each call consults the latest settings, so a list
    /// model created before the user edited the rules applies them from the next page on.
    static func liveFilter(scope: FeedScope) -> (VideoCard) -> Bool {
        { FeedFilter.current.allows($0, scope: scope) }
    }
}

// MARK: - Keyword rules

/// One title rule: plain case-insensitive substring, or `/pattern/` (case-insensitive regex).
enum FeedKeywordRule {
    case plain(String)
    case regex(NSRegularExpression, source: String)

    /// nil for an empty rule or a regex that does not compile.
    init?(_ raw: String) {
        let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return nil }
        if rule.count >= 3, rule.hasPrefix("/"), rule.hasSuffix("/") {
            let pattern = String(rule.dropFirst().dropLast())
            guard let regex = FeedFilterRegexCache.regex(pattern) else { return nil }
            self = .regex(regex, source: rule)
        } else {
            self = .plain(rule)
        }
    }

    var source: String {
        switch self {
        case .plain(let s): return s
        case .regex(_, let source): return source
        }
    }

    func matches(_ text: String) -> Bool {
        switch self {
        case .plain(let needle):
            return text.range(of: needle, options: .caseInsensitive) != nil
        case .regex(let regex, _):
            return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

/// Process-wide cache of compiled case-insensitive user regexes (invalid patterns cached as invalid).
enum FeedFilterRegexCache {
    private static let lock = NSLock()
    private static var compiled: [String: NSRegularExpression] = [:]
    private static var invalid: Set<String> = []

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let r = compiled[pattern] { return r }
        if invalid.contains(pattern) { return nil }
        if compiled.count + invalid.count > 512 {
            compiled.removeAll()
            invalid.removeAll()
        }
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            invalid.insert(pattern)
            return nil
        }
        compiled[pattern] = r
        return r
    }
}

// MARK: - 恰饭 / paid-promotion heuristic

/// Conservative detector for paid promotions ("恰饭" / 商单 / 品牌合作) among normal videos.
///
/// A card counts as promoted when ONE strong signal or TWO distinct weak terms are found in
/// title + desc (plus badge / reason / adSignals):
/// - strong: a soft `adSignals` entry ("goods" 带货); a badge / reason containing 广告 / 推广 / 商单 /
///   恰饭 / 赞助 / 商业; a tag such as 【恰饭】 (商单) #广告 #品牌合作#; phrases 商单, 金主爸爸,
///   合作推广, 品牌合作, 商业推广, 赞助播出, 本期赞助, 恰个饭, 这期恰饭, 要恰饭 …; sentences
///   "本期视频由…赞助/冠名/特约" and "感谢…赞助/金主".
/// - weak: 恰饭, 推广, 广告, 赞助, 金主, 种草, 带货, 好物推荐/分享, 优惠码/券, 折扣码, 领券,
///   购买链接, 商品链接, 专属优惠, 限时优惠.
///
/// False-positive guards for every occurrence:
/// - negation / meta words in the 4 characters before it (cut at punctuation): 非 无 不 没 未 零 拒 免
///   去 反 防 跳过 屏蔽 拦截 关闭 接 聊 谈 如何 怎么 关于 揭秘 任何 — "无广告", "非商单", "不是恰饭",
///   "去广告", "如何接商单", "不含任何商业推广";
/// - contact boilerplate / meta words in the 8 characters after it (cut at sentence punctuation):
///   合作 联系 私信 洽谈 咨询 邮箱 微信 vx wx qq @ 报价 价格 多少钱 收入 揭秘 内幕 行情 平台 吗 勿
///   免谈 dd 滴滴 加v 戳 主页 简介 — "商单合作请私信", "商单勿扰", "商单dd", "商单报价", "这是恰饭吗";
/// - noun compounds: 广告学/法/牌/词/片/位/业/人/史/公司/设计/创意/专业/招租/拦截/营销/推广 …,
///   推广普通话/大使/计划 …, 带货主播/乱象 … — "广告学专业解读", "推广普通话".
/// - fan tipping: 金主 / 赞助 in a clause that mentions 「充电」 (Bilibili's tipping; not 充电宝/器 …)
///   thank viewers, not a sponsor — "感谢充电的金主爸爸们", a common description footer.
/// Bare 广告 / 推广 / 恰饭 (恰饭 also means 吃饭 in 湘方言: "长沙恰饭 vlog") are weak only.
enum FeedPromotionDetector {
    static func evidence(for card: VideoCard) -> String? {
        evidence(title: card.title, desc: card.desc, badge: card.badge, reason: card.reason, signals: card.adSignals)
    }

    static func evidence(title: String, desc: String = "", badge: String = "", reason: String = "",
                         signals: [String] = []) -> String? {
        if let s = signals.first(where: FeedFilter.isSoftPromotionSignal) { return "带货标记（\(s)）" }
        for label in markerLabels {
            if badge.contains(label) { return "角标“\(badge)”" }
            if reason.contains(label) { return "推荐理由“\(reason)”" }
        }
        let cleanTitle = title.contains("<") ? title.strippingHTMLTags : title
        let text = desc.isEmpty ? cleanTitle : cleanTitle + "\n" + desc
        if text.isEmpty { return nil }

        if let tag = firstTag(in: text) { return "标签“\(tag)”" }
        for phrase in strongPhrases where hasAffirmedOccurrence(of: phrase, in: text) {
            return "含“\(phrase)”"
        }
        if let sentence = firstSponsorSentence(in: text) { return "含“\(sentence)”" }

        var hits: [String] = []
        for term in weakTerms where hasAffirmedOccurrence(of: term, in: text) {
            hits.append(term)
            if hits.count >= 2 { return "含“\(hits[0])”“\(hits[1])”" }
        }
        return nil
    }

    // MARK: Vocabulary

    static let markerLabels = ["广告", "推广", "商单", "恰饭", "赞助", "商业"]

    static let strongPhrases = [
        "商单", "金主爸爸", "合作推广", "品牌合作", "商业推广", "赞助播出", "本期赞助",
        "恰个饭", "恰一口饭", "恰一下饭", "恰饭视频", "恰饭时间", "本期恰饭", "这期恰饭",
        "又恰饭", "要恰饭", "恰饭啦", "恰到饭",
    ]

    static let weakTerms = [
        "恰饭", "推广", "广告", "赞助", "金主", "种草", "带货", "好物推荐", "好物分享",
        "优惠码", "优惠券", "折扣码", "领券", "购买链接", "商品链接", "专属优惠", "限时优惠",
    ]

    /// Words in the 4 characters before a term that negate it or make it meta-discussion.
    static let suppressingPrefixes = [
        "非", "无", "不", "没", "未", "零", "拒", "免", "去", "反", "防", "跳过", "屏蔽", "拦截", "关闭",
        "接", "聊", "谈", "如何", "怎么", "关于", "揭秘", "任何",
    ]

    /// Words in the 8 characters after a term that indicate contact boilerplate or meta-discussion.
    static let suppressingSuffixes = [
        "合作", "联系", "私信", "洽谈", "咨询", "邮箱", "邮件", "微信", "vx", "wx", "qq", "@",
        "报价", "价格", "多少钱", "收入", "揭秘", "内幕", "行情", "平台", "吗",
        "勿", "免谈", "dd", "滴滴", "加v", "+v", "戳", "主页", "简介",
    ]

    /// Compounds where the term is part of an unrelated noun.
    static let nounSuffixes: [String: [String]] = [
        "广告": ["学", "法", "牌", "词", "片", "位", "业", "人", "史", "圈", "歌", "曲", "语", "费", "公司",
                "设计", "创意", "专业", "狂人", "拦截", "屏蔽", "插件", "招租", "案例", "分析", "鉴赏",
                "合集", "盘点", "大赏", "文案", "策划", "营销", "行业", "理论", "传播", "投放", "推广", "素材"],
        "推广": ["普通话", "大使", "策略", "方案", "技巧", "渠道", "曲", "员", "计划", "大会"],
        "带货": ["主播", "乱象", "行业", "翻车", "达人"],
    ]

    // MARK: Matching

    private static let tagTermPattern = "商单|恰饭|广告|推广|赞助|金主|品牌合作|合作推广|商业合作|商业推广"
    private static let tagInner = "[^【】\\[\\]〔〕()（）#\\s]"

    /// 【…恰饭…】 / [广告] / （推广） — up to 6 characters on each side of the term inside the brackets.
    private static let bracketTagRegex = try? NSRegularExpression(
        pattern: "[【\\[〔(（](\(tagInner){0,6}?)(\(tagTermPattern))(\(tagInner){0,6}?)[】\\]〕)）]")
    /// #恰饭# / #商单 (closed by #, whitespace or end).
    private static let hashTagRegex = try? NSRegularExpression(
        pattern: "#(\(tagInner){0,6}?)(\(tagTermPattern))(\(tagInner){0,6}?)(?:#|\\s|$)")
    /// 本期视频由 XX 赞助 / 本节目由 XX 冠名播出.
    private static let sponsoredByRegex = try? NSRegularExpression(
        pattern: "本(?:期|集|条|次|篇|个)?(?:视频|节目|内容|作品)?由([^，。！？!?;；\\n]{1,24}?)(?:赞助|冠名|特约|独家支持|提供支持|倾情支持|支持播出)")
    /// 感谢 XX 的赞助 / 感谢金主爸爸.
    private static let thanksSponsorRegex = try? NSRegularExpression(
        pattern: "感谢([^，。！？!?;；\\n]{0,16}?)(?:赞助|金主|冠名)")
    private static let gapNegators = ["非", "无", "不", "没", "未", "任何"]

    static func firstTag(in text: String) -> String? {
        let ns = text as NSString
        for regex in [bracketTagRegex, hashTagRegex].compactMap({ $0 }) {
            for m in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                let before = ns.substring(with: m.range(at: 1))
                let term = ns.substring(with: m.range(at: 2))
                let after = ns.substring(with: m.range(at: 3))
                if suppressingPrefixes.contains(where: { before.contains($0) }) { continue }
                if suppressingSuffixes.contains(where: { after.lowercased().contains($0) }) { continue }
                if let nouns = nounSuffixes[term], nouns.contains(where: { after.hasPrefix($0) }) { continue }
                return ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func firstSponsorSentence(in text: String) -> String? {
        let ns = text as NSString
        for regex in [sponsoredByRegex, thanksSponsorRegex].compactMap({ $0 }) {
            for m in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                let gap = ns.substring(with: m.range(at: 1))
                if gapNegators.contains(where: { gap.contains($0) }) { continue }
                if let r = Range(m.range, in: text) {
                    if isSuppressed(text, before: r.lowerBound) { continue }
                    if mentionsFanCharging(clause(of: text, around: r)) { continue }
                }
                return ns.substring(with: m.range)
            }
        }
        return nil
    }

    /// True if at least one occurrence of `term` survives the negation / boilerplate / noun guards.
    static func hasAffirmedOccurrence(of term: String, in text: String) -> Bool {
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
            from = r.upperBound
            if isSuppressed(text, before: r.lowerBound) { continue }
            if isBoilerplate(text, after: r.upperBound) { continue }
            if let nouns = nounSuffixes[term], nouns.contains(where: { text[r.upperBound...].hasPrefix($0) }) { continue }
            if sponsorWords.contains(where: { term.contains($0) }), mentionsFanCharging(clause(of: text, around: r)) { continue }
            return true
        }
        return false
    }

    /// Terms whose meaning flips to fan tipping next to 「充电」.
    private static let sponsorWords = ["金主", "赞助"]

    /// 「充电」 (fan tipping) not part of a product noun like 充电宝 / 充电器 / 充电头.
    static func mentionsFanCharging<S: StringProtocol>(_ s: S) -> Bool {
        var from = s.startIndex
        while from < s.endIndex, let r = s.range(of: "充电", range: from..<s.endIndex) {
            guard let next = s[r.upperBound...].first, "宝器头线桩站口".contains(next) else { return true }
            from = r.upperBound
        }
        return false
    }

    /// The sentence (cut at sentence punctuation) that contains `r`.
    private static func clause(of text: String, around r: Range<String.Index>) -> Substring {
        let start = text[..<r.lowerBound].lastIndex(where: isSentenceBreak).map { text.index(after: $0) } ?? text.startIndex
        let end = text[r.upperBound...].firstIndex(where: isSentenceBreak) ?? text.endIndex
        return text[start..<end]
    }

    private static func isSuppressed(_ text: String, before index: String.Index) -> Bool {
        let start = text.index(index, offsetBy: -4, limitedBy: text.startIndex) ?? text.startIndex
        var window = text[start..<index]
        if let cut = window.lastIndex(where: isWordBreak) { window = window[window.index(after: cut)...] }
        return !window.isEmpty && suppressingPrefixes.contains(where: { window.contains($0) })
    }

    private static func isBoilerplate(_ text: String, after index: String.Index) -> Bool {
        let end = text.index(index, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
        var window = text[index..<end]
        if let cut = window.firstIndex(where: isSentenceBreak) { window = window[..<cut] }
        let lower = window.lowercased()
        return !lower.isEmpty && suppressingSuffixes.contains(where: { lower.contains($0) })
    }

    private static func isSentenceBreak(_ c: Character) -> Bool {
        "，。！？；,.!?;\n…~～".contains(c)
    }

    private static func isWordBreak(_ c: Character) -> Bool {
        isSentenceBreak(c) || c.isWhitespace || "、/|｜:：【】[]()（）#「」『』\"'“”《》<>".contains(c)
    }
}
