import Foundation

// 消息中心 models: unread counters, the 回复我的 / @我的 / 收到的赞 / 系统通知 feeds and 私信 (whisper).
// Parsers live in `MessageAPI`; `MessageLinks` turns the server's `native_uri` / `uri` strings into in-app targets.

/// Unread counters behind the 首页 「消息」 bell (`/x/msgfeed/unread` + whisper `single_unread`).
struct MessageUnread: Equatable {
    var reply = 0
    var at = 0
    var like = 0
    var system = 0
    /// 私信: followed + unfollowed talkers, business accounts and pushes.
    var whisper = 0

    var total: Int { reply + at + like + system + whisper }

    func count(for kind: MessageFeedKind) -> Int {
        switch kind {
        case .reply: return reply
        case .at: return at
        case .like: return like
        case .system: return system
        }
    }

    mutating func clear(_ kind: MessageFeedKind) {
        switch kind {
        case .reply: reply = 0
        case .at: at = 0
        case .like: like = 0
        case .system: system = 0
        }
    }

    /// Badge text: nil when nothing is unread, 「99+」 above 99.
    static func badgeText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }
}

/// The four notification feeds at the top of 消息中心.
enum MessageFeedKind: String, CaseIterable, Identifiable, Hashable {
    case reply, at, like, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: return "回复我的"
        case .at: return "@我的"
        case .like: return "收到的赞"
        case .system: return "系统通知"
        }
    }
}

/// A comment thread (评论详情): comment area `oid` + `type` and the root comment.
struct MessageCommentThread: Hashable {
    var oid: Int64
    /// Comment area type (1 video, 11 / 17 dynamics, 12 articles …).
    var type: Int
    /// Root comment rpid.
    var root: Int64
}

/// Where a message links to. The UI maps it to a `Route` (dynamics and articles open their web pages).
enum MessageLink: Hashable {
    case video(aid: Int64, bvid: String)
    case bangumi(epId: Int64, seasonId: Int64)
    case dynamic(id: String)
    case user(mid: Int64)
    case live(roomId: Int64)
    case article(id: Int64)
    case comments(MessageCommentThread)
    case web(URL)
}

/// One row of 回复我的 / @我的 / 收到的赞 / 系统通知.
struct MessageFeedItem: Identifiable, Hashable {
    var id: String { "\(kind.rawValue)_\(feedId)" }
    var kind: MessageFeedKind
    var feedId: Int64 = 0
    /// Who replied / @'d / liked; 收到的赞 can carry several.
    var users: [UserBrief] = []
    /// `counts`: replies (回复我的) or people (收到的赞) merged into this row, 0 when unknown.
    var count: Int = 0
    /// Several people merged into this row (「等人」).
    var isMulti = false
    /// What it is about: 「评论」「视频」「动态」…
    var business: String = ""
    /// Their reply / @ text (empty for likes).
    var content: String = ""
    /// My comment they replied to or liked (empty when they commented on the video itself).
    var targetText: String = ""
    /// Root comment text when the reply sits deeper in a thread.
    var rootText: String = ""
    /// Title of the related video / dynamic, or my liked comment; 系统通知: the notice title.
    var title: String = ""
    /// Cover of the related video / dynamic (https, may be empty).
    var image: String = ""
    /// Unix seconds.
    var time: Int64 = 0
    /// Server time text when there is no unix time.
    var timeText: String = ""
    /// The related video / dynamic / page.
    var link: MessageLink? = nil
    /// Comment thread the message belongs to (opens 评论详情).
    var thread: MessageCommentThread? = nil
    /// Their comment (`source_id`) for 回复 / 点赞 from the row; 0 when the message is not a comment.
    var sourceRpid: Int64 = 0
    /// `root_id` of their comment (0 = it is a root comment).
    var sourceRoot: Int64 = 0
    /// I already liked their comment (`like_state`).
    var liked = false
    /// 系统通知 paging cursor.
    var cursor: Int64 = 0

    init(kind: MessageFeedKind, feedId: Int64 = 0) {
        self.kind = kind
        self.feedId = feedId
    }
}

// MARK: - 私信

/// The other side of a whisper conversation (pushed as `Route.whisper`).
struct WhisperPeer: Hashable {
    var talkerId: Int64
    /// 1 = a user (or official account), 2 = 应援团 group.
    var sessionType: Int = 1
    var name: String = ""
    var face: String = ""

    /// Only one-to-one conversations can be answered from the web API.
    var canSend: Bool { sessionType == 1 && talkerId > 0 }
}

/// One row of the 私信 session list.
struct WhisperSession: Identifiable, Hashable {
    var id: String { "\(sessionType)_\(talkerId)" }
    var talkerId: Int64 = 0
    var sessionType: Int = 1
    var name: String = ""
    var face: String = ""
    var unreadCount: Int = 0
    /// One-line preview of the last message.
    var preview: String = ""
    /// Unix seconds of the last message.
    var lastTime: Int64 = 0
    /// `session_ts` (µs), the paging cursor.
    var sessionTs: Int64 = 0
    var isPinned = false
    /// 免打扰: unread shows as a dot.
    var isMuted = false
    var isFollowed = false
    /// Official / system account (UP主小助手 …).
    var isSystem = false
    var maxSeqno: Int64 = 0

    var peer: WhisperPeer {
        WhisperPeer(talkerId: talkerId, sessionType: sessionType, name: name, face: face)
    }
}

/// One whisper message.
struct WhisperMessage: Identifiable, Hashable {
    var id: String { msgKey.isEmpty || msgKey == "0" ? "s\(seqno)" : msgKey }
    var seqno: Int64 = 0
    /// `msg_key` as text (it can exceed what a JSON double holds exactly).
    var msgKey: String = ""
    var senderUid: Int64 = 0
    var receiverId: Int64 = 0
    var type: Int = 0
    /// Unix seconds.
    var timestamp: Int64 = 0
    /// 已撤回 (`msg_status == 1`, or withdrawn by a later 撤回 message).
    var isWithdrawn = false
    /// Sent by an auto-reply rule (`msg_source` 8…11).
    var isAutoReply = false
    var body: WhisperMessageBody = .unsupported(type: 0)
}

enum WhisperMessageBody: Hashable {
    case text(String)
    case image(url: String, width: Int, height: Int)
    /// Video / article / dynamic / live shares and UP主 push cards.
    case card(WhisperCard)
    /// Notification card (系统消息, 订单 …).
    case notice(WhisperNotice)
    /// Grey centered hint (e.g. 「对方主动回复或关注你前，最多发送1条消息」).
    case tip(String)
    /// 撤回 marker: the key of the withdrawn message (removed while parsing).
    case withdraw(msgKey: String)
    case unsupported(type: Int)
}

struct WhisperCard: Hashable {
    var title: String = ""
    var cover: String = ""
    /// 「作者 · 视频」, an article summary …
    var subtitle: String = ""
    /// Seconds (video cards), 0 when unknown.
    var duration: Int = 0
    /// Text sent together with the card (`attach_msg`).
    var note: String = ""
    var link: MessageLink? = nil
}

struct WhisperNotice: Hashable {
    struct Field: Hashable {
        var title: String
        var detail: String
    }

    struct Action: Hashable {
        var text: String
        var link: MessageLink?
    }

    var title: String = ""
    var text: String = ""
    var fields: [Field] = []
    var actions: [Action] = []
}

/// One page of a conversation, oldest first.
struct WhisperMessagePage {
    var messages: [WhisperMessage] = []
    var hasMore = false
    var minSeqno: Int64 = 0
    var maxSeqno: Int64 = 0
    /// Emote token (e.g. 「[doge]」) → https image URL.
    var emotes: [String: String] = [:]
    /// Keys withdrawn by 撤回 markers in this page (the withdrawn message can sit on an older page).
    var withdrawnKeys: Set<String> = []
}

/// A run of 系统通知 text: plain, or a link (`#{文字}{"url"}` markup and bare URLs).
struct MessageTextSegment: Hashable {
    var text: String
    var link: MessageLink?
    /// The link as written (what a tappable `Text` link carries; resolve it again with `MessageLinks.resolve`).
    var url: URL? = nil
}

/// Time labels of a 私信 conversation.
enum WhisperTime {
    /// Messages further apart than this get their own time label.
    static let gap: Int64 = 300

    /// 「12:30」 today, 「昨天 12:30」, 「05-01 12:30」 this year, else 「2023-05-01 12:30」.
    static func label(_ unix: Int64, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard unix > 0 else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        let prefix: String
        if cal.isDate(date, inSameDayAs: now) {
            prefix = ""
        } else if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            prefix = "昨天 "
        } else if cal.component(.year, from: date) == cal.component(.year, from: now) {
            f.dateFormat = "MM-dd "
            prefix = f.string(from: date)
        } else {
            f.dateFormat = "yyyy-MM-dd "
            prefix = f.string(from: date)
        }
        f.dateFormat = "HH:mm"
        return prefix + f.string(from: date)
    }

    /// Whether the message at `index` starts a new time group.
    static func startsGroup(_ messages: [WhisperMessage], at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        return messages[index].timestamp - messages[index - 1].timestamp > gap
    }
}

// MARK: - Link resolution

/// Resolves `bilibili://…` app links and bilibili.com web links found in messages.
enum MessageLinks {
    /// nil for empty strings, placeholders (`?…`) and schemes the app cannot open.
    static func resolve(_ raw: String) -> MessageLink? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("?") else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        guard let url = URL(string: s)
            ?? s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "bilibili" { return resolveApp(url) }
        if scheme == "http" || scheme == "https" { return resolveWeb(url) }
        return nil
    }

    /// Path components without the leading "/".
    private static func parts(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func positive(_ s: String) -> Int64? {
        guard let v = Int64(s), v > 0 else { return nil }
        return v
    }

    private static func video(_ token: String) -> MessageLink? {
        if let r = token.range(of: #"BV1[1-9A-HJ-NP-Za-km-z]{9}"#, options: .regularExpression) {
            return .video(aid: 0, bvid: String(token[r]))
        }
        var t = token
        if t.lowercased().hasPrefix("av") { t = String(t.dropFirst(2)) }
        return positive(t).map { .video(aid: $0, bvid: "") }
    }

    private static func resolveApp(_ url: URL) -> MessageLink? {
        let p = parts(url)
        let first = p.first
        switch url.host?.lowercased() ?? "" {
        case "video":
            return first.flatMap(video)
        case "pgc":
            // bilibili://pgc/season/ep/123 · bilibili://pgc/season/456
            if let i = p.firstIndex(of: "ep"), i + 1 < p.count, let ep = positive(p[i + 1]) {
                return .bangumi(epId: ep, seasonId: 0)
            }
            if let ss = p.last.flatMap(positive) { return .bangumi(epId: 0, seasonId: ss) }
            return nil
        case "bangumi":
            if p.first == "season", p.count > 1, let ss = positive(p[1]) { return .bangumi(epId: 0, seasonId: ss) }
            return nil
        case "space":
            return first.flatMap(positive).map { .user(mid: $0) }
        case "live":
            return first.flatMap(positive).map { .live(roomId: $0) }
        case "article":
            return first.flatMap(positive).map { .article(id: $0) }
        case "following", "opus":
            // bilibili://following/detail/832703053858603029 · bilibili://opus/detail/…
            let id = p.first == "detail" ? (p.count > 1 ? p[1] : "") : (first ?? "")
            if id.lowercased().hasPrefix("cv"), let cv = positive(String(id.dropFirst(2))) { return .article(id: cv) }
            return positive(id).map { .dynamic(id: String($0)) }
        case "comment":
            // bilibili://comment/detail/{type}/{oid}/{root}/?anchor=… · bilibili://comment/msg_fold/{type}/{oid}/{root}/…
            guard p.count >= 4, p[0] == "detail" || p[0] == "msg_fold",
                  let type = Int(p[1]), type > 0, let oid = positive(p[2]), let root = positive(p[3]) else { return nil }
            return .comments(MessageCommentThread(oid: oid, type: type, root: root))
        case "browser":
            return query(url, "url").flatMap(resolve)
        default:
            return nil
        }
    }

    private static func resolveWeb(_ url: URL) -> MessageLink? {
        let host = url.host?.lowercased() ?? ""
        guard host == "bilibili.com" || host.hasSuffix(".bilibili.com") else { return .web(url) }
        let p = parts(url)
        let path = url.path
        if host == "space.bilibili.com", let mid = p.first.flatMap(positive) { return .user(mid: mid) }
        if host == "live.bilibili.com" {
            let id = p.first == "h5" ? (p.count > 1 ? p[1] : nil) : p.first
            if let room = id.flatMap(positive) { return .live(roomId: room) }
            return .web(url)
        }
        if host == "t.bilibili.com", let id = p.first.flatMap(positive) { return .dynamic(id: String(id)) }
        if let i = p.firstIndex(where: { $0 == "opus" || $0 == "dynamic" }), i + 1 < p.count,
           let id = positive(p[i + 1]) {
            return .dynamic(id: String(id))
        }
        if let i = p.firstIndex(of: "video"), i + 1 < p.count, let v = video(p[i + 1]) { return v }
        if path.contains("/bangumi/play/"), let last = p.last {
            if last.hasPrefix("ep"), let ep = positive(String(last.dropFirst(2))) { return .bangumi(epId: ep, seasonId: 0) }
            if last.hasPrefix("ss"), let ss = positive(String(last.dropFirst(2))) { return .bangumi(epId: 0, seasonId: ss) }
        }
        if let i = p.firstIndex(of: "read"), i + 1 < p.count, p[i + 1].hasPrefix("cv"),
           let cv = positive(String(p[i + 1].dropFirst(2))) {
            return .article(id: cv)
        }
        if path.hasPrefix("/h5/comment/sub"), let oid = query(url, "oid").flatMap(positive),
           let type = query(url, "pageType").flatMap({ Int($0) }), type > 0, let root = query(url, "root").flatMap(positive) {
            return .comments(MessageCommentThread(oid: oid, type: type, root: root))
        }
        return .web(url)
    }

    // MARK: 系统通知 text

    private static let systemRegex = try? NSRegularExpression(
        pattern: #"#\{([^}]*)\}\{([^}]*)\}|https?://[^\s<>"'，。）】]+"#)

    /// Splits 系统通知 text into plain runs and links: `#{查看详情}{"https://…"}` becomes a link titled
    /// 「查看详情」, bare URLs become 「网页链接」 links.
    static func systemSegments(_ text: String) -> [MessageTextSegment] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        guard let regex = systemRegex else { return [MessageTextSegment(text: text, link: nil)] }
        var out: [MessageTextSegment] = []
        var cursor = 0
        for m in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out.append(MessageTextSegment(
                    text: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), link: nil))
            }
            if m.range(at: 1).location != NSNotFound {
                let title = ns.substring(with: m.range(at: 1))
                let raw = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                let link = resolve(raw)
                out.append(MessageTextSegment(text: title.isEmpty ? "查看详情" : title, link: link,
                                              url: link == nil ? nil : URL(string: raw)))
                cursor = m.range.location + m.range.length
            } else {
                // Trailing punctuation belongs to the sentence, not the URL.
                var raw = ns.substring(with: m.range)
                while let last = raw.last, ".,;:!?)]".contains(last) { raw.removeLast() }
                let link = resolve(raw)
                out.append(MessageTextSegment(text: link == nil ? raw : "网页链接", link: link,
                                              url: link == nil ? nil : URL(string: raw)))
                cursor = m.range.location + (raw as NSString).length
            }
        }
        if cursor < ns.length {
            out.append(MessageTextSegment(text: ns.substring(from: cursor), link: nil))
        }
        return out
    }
}
