import Foundation

/// 消息中心 (login required): the unread counters of the 首页 「消息」 bell, the 回复我的 / @我的 / 收到的赞 /
/// 系统通知 feeds and 私信 (whisper) sessions and conversations.
///
/// Paging: the msgfeed lists use the server cursor `{id, time}` (`Page.next` = `"id|time"`), 系统通知 the last
/// item's `cursor`, sessions the oldest unpinned `session_ts` (µs) and conversations the oldest `msg_seqno`.
/// Whisper endpoints live on `api.vc.bilibili.com` and are called like the web IM page (message.bilibili.com).
enum MessageAPI {
    static let messageHost = "https://message.bilibili.com"
    /// Referer / Origin of the web IM page, sent with every `api.vc` request.
    static let imHeaders = ["Referer": "https://message.bilibili.com/", "Origin": "https://message.bilibili.com"]
    private static let feedLocation = "333.40164"
    private static let unreadLocation = "333.1365"

    // MARK: Unread

    /// msgfeed counters plus 私信 unread. A failing whisper counter only drops the 私信 part.
    static func unread() async throws -> MessageUnread {
        async let feedR = ListMapping.capture {
            try await BiliHTTP.shared.api(BiliHost.api + "/x/msgfeed/unread",
                                          query: ["build": 0, "mobi_app": "web", "web_location": unreadLocation])
        }
        async let whisperR = ListMapping.capture {
            try await BiliHTTP.shared.api(BiliHost.message + "/session_svr/v1/session_svr/single_unread",
                                          query: ["unread_type": 0, "build": 0, "mobi_app": "web",
                                                  "web_location": unreadLocation],
                                          headers: imHeaders)
        }
        let feedResult = await feedR
        let whisperResult = await whisperR
        let feed = try feedResult.get()
        return parseUnread(feed: feed, whisper: (try? whisperResult.get()) ?? .null)
    }

    /// `feed` = data of `/x/msgfeed/unread`, `whisper` = data of `single_unread` (or null).
    static func parseUnread(feed: JSON, whisper: JSON) -> MessageUnread {
        var u = MessageUnread()
        u.reply = max(0, feed["reply"].intValue)
        u.at = max(0, feed["at"].intValue)
        u.like = max(0, feed["like"].intValue)
        u.system = max(0, feed["sys_msg"].intValue)
        let whisperKeys = ["follow_unread", "unfollow_unread", "biz_msg_follow_unread", "biz_msg_unfollow_unread",
                           "unfollow_push_msg", "custom_unread"]
        u.whisper = whisperKeys.reduce(0) { $0 + max(0, whisper[$1].intValue) }
        return u
    }

    // MARK: Feeds

    /// One page of 回复我的 / @我的 / 收到的赞 / 系统通知. `cursor` is the previous page's `next`.
    static func feed(_ kind: MessageFeedKind, cursor: String?) async throws -> Page<MessageFeedItem> {
        if kind == .system { return try await systemNotices(cursor: cursor) }
        let c = decodeFeedCursor(cursor)
        var query: [String: Any] = ["platform": "web", "mobi_app": "web", "build": 0, "web_location": feedLocation]
        if c.id > 0 || c.time > 0 {
            query["id"] = c.id
            query[timeParameter(kind)] = c.time
        }
        let data = try await BiliHTTP.shared.api(BiliHost.api + "/x/msgfeed/" + kind.rawValue, query: query)
        return parseFeedPage(data, kind: kind)
    }

    static func timeParameter(_ kind: MessageFeedKind) -> String {
        switch kind {
        case .reply: return "reply_time"
        case .at: return "at_time"
        case .like, .system: return "like_time"
        }
    }

    static func encodeFeedCursor(id: Int64, time: Int64) -> String { "\(id)|\(time)" }

    static func decodeFeedCursor(_ cursor: String?) -> (id: Int64, time: Int64) {
        guard let cursor, !cursor.isEmpty else { return (0, 0) }
        let parts = cursor.split(separator: "|", omittingEmptySubsequences: false)
        let id = parts.count > 0 ? Int64(parts[0]) ?? 0 : 0
        let time = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
        return (id, time)
    }

    /// `data` of `/x/msgfeed/reply|at|like`. 收到的赞 has `latest` (new since the last visit) and `total`
    /// (the rest, which carries the cursor); both are shown in one list, newest first.
    static func parseFeedPage(_ data: JSON, kind: MessageFeedKind) -> Page<MessageFeedItem> {
        let paged: [JSON]
        let all: [JSON]
        let cursor: JSON
        if kind == .like {
            paged = data[path: "total.items"].arrayValue
            all = data[path: "latest.items"].arrayValue + paged
            cursor = data[path: "total.cursor"]
        } else {
            paged = data["items"].arrayValue
            all = paged
            cursor = data["cursor"]
        }
        let items = all.compactMap { feedItem($0, kind: kind) }
        let id = cursor["id"].int64Value
        let time = cursor["time"].int64Value
        let hasMore = !cursor["is_end"].boolValue && !paged.isEmpty && (id > 0 || time > 0)
        return Page(items: items, hasMore: hasMore, next: hasMore ? encodeFeedCursor(id: id, time: time) : nil)
    }

    static func feedItem(_ j: JSON, kind: MessageFeedKind) -> MessageFeedItem? {
        let feedId = j["id"].int64Value
        guard feedId != 0 else { return nil }
        var m = MessageFeedItem(kind: kind, feedId: feedId)
        let it = j["item"]
        if kind == .like {
            m.users = j["users"].arrayValue.compactMap(feedUser)
            m.time = j["like_time"].int64Value
        } else {
            m.users = feedUser(j["user"]).map { [$0] } ?? []
            m.time = (kind == .reply ? j["reply_time"] : j["at_time"]).int64Value
        }
        m.count = max(0, j["counts"].intValue)
        m.isMulti = j["is_multi"].boolValue || (kind == .like && max(m.count, m.users.count) > 1)
        m.business = it["business"].stringValue
        m.title = it["title"].stringValue
        m.image = ListMapping.image(it["image"])
        m.content = it["source_content"].stringValue
        m.targetText = it["target_reply_content"].stringValue
        m.rootText = it["root_reply_content"].stringValue
        m.liked = it["like_state"].intValue == 1

        let businessId = it["business_id"].intValue
        let subject = it["subject_id"].int64Value
        let native = MessageLinks.resolve(it["native_uri"].stringValue)
        let web = MessageLinks.resolve(it["uri"].stringValue)
        switch kind {
        case .reply, .at:
            m.link = contentLink(native: native, web: web, businessId: businessId, subjectId: subject)
            let source = it["source_id"].int64Value
            let root = it["root_id"].int64Value
            // 回复我的 rows are always comments; @ can also come from a dynamic or danmaku.
            let isComment = kind == .reply || it["type"].stringValue == "reply"
            if isComment, source > 0, subject > 0, businessId > 0 {
                m.sourceRpid = source
                m.sourceRoot = root
                m.thread = MessageCommentThread(oid: subject, type: businessId, root: root > 0 ? root : source)
            } else if case .comments(let t)? = native {
                m.thread = t
            }
        case .like:
            m.link = contentLink(native: native, web: web, businessId: 0, subjectId: 0)
            if case .comments(let t)? = native {
                m.thread = t
            } else if case .comments(let t)? = web {
                m.thread = t
            }
        case .system:
            break
        }
        return m
    }

    /// The video / dynamic / article a message is about: the app link, else what the comment area implies
    /// (`business_id` 1 = video aid, 12 = article, 17 = dynamic), else the web link. Comment-detail links are skipped.
    static func contentLink(native: MessageLink?, web: MessageLink?, businessId: Int, subjectId: Int64) -> MessageLink? {
        if let native, !isComments(native) { return native }
        if subjectId > 0 {
            switch businessId {
            case 1: return .video(aid: subjectId, bvid: "")
            case 12: return .article(id: subjectId)
            case 17: return .dynamic(id: String(subjectId))
            default: break
            }
        }
        if let web, !isComments(web) { return web }
        return nil
    }

    private static func isComments(_ link: MessageLink) -> Bool {
        if case .comments = link { return true }
        return false
    }

    static func feedUser(_ j: JSON) -> UserBrief? {
        let mid = j["mid"].int64Value
        let name = j["nickname"].string ?? j["name"].stringValue
        guard mid > 0 || !name.isEmpty else { return nil }
        var u = UserBrief(mid: mid)
        u.name = name
        u.face = ListMapping.image(j["avatar"].exists ? j["avatar"] : j["face"])
        u.isFollowed = j["follow"].boolValue
        return u
    }

    // MARK: 系统通知

    static func systemNotices(cursor: String?, pageSize: Int = 20) async throws -> Page<MessageFeedItem> {
        var query: [String: Any] = ["page_size": pageSize, "mobi_app": "web", "build": 0, "web_location": feedLocation]
        if let c = cursor.flatMap({ Int64($0) }), c > 0 { query["cursor"] = c }
        let data = try await BiliHTTP.shared.api(messageHost + "/x/sys-msg/query_notify_list", query: query)
        return parseSystemPage(data)
    }

    /// `data` of `query_notify_list` (a plain array). The next cursor is the last item's `cursor`.
    static func parseSystemPage(_ data: JSON) -> Page<MessageFeedItem> {
        let list = data.array ?? data["list"].arrayValue
        let items = list.compactMap(systemItem)
        let last = items.last?.cursor ?? 0
        let hasMore = !items.isEmpty && last > 0
        return Page(items: items, hasMore: hasMore, next: hasMore ? String(last) : nil)
    }

    static func systemItem(_ j: JSON) -> MessageFeedItem? {
        let id = j["id"].int64Value
        guard id != 0 else { return nil }
        var m = MessageFeedItem(kind: .system, feedId: id)
        m.cursor = j["cursor"].int64Value
        m.title = j["title"].stringValue
        m.content = systemContent(j["content"].stringValue)
        m.timeText = j["time_at"].stringValue
        m.time = parseServerTime(m.timeText)
        return m
    }

    /// Notice bodies are plain text or a JSON object whose `web` member holds the text.
    static func systemContent(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{"), let j = try? JSON(string: t), let web = j["web"].string, !web.isEmpty { return web }
        return raw
    }

    private static let serverTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 「2024-05-01 12:34:56」 (Beijing time) → unix seconds, 0 when unparsable.
    static func parseServerTime(_ s: String) -> Int64 {
        guard !s.isEmpty, let d = serverTimeFormatter.date(from: s) else { return 0 }
        return Int64(d.timeIntervalSince1970)
    }

    /// Marks 系统通知 read up to `cursor` (the newest item's).
    static func markSystemRead(cursor: Int64) async {
        guard cursor > 0, let csrf = BiliHTTP.shared.csrf else { return }
        _ = try? await BiliHTTP.shared.api(messageHost + "/x/sys-msg/update_cursor", query: ["csrf": csrf, "cursor": cursor])
    }

    // MARK: 私信 sessions

    /// One page of 私信 sessions (pinned first, then newest). Names and avatars of user sessions come from
    /// `x/im/user_infos`; if that fails the rows show their UID.
    static func sessions(cursor: String?) async throws -> Page<WhisperSession> {
        var query: [String: Any] = ["session_type": 1, "group_fold": 1, "unfollow_fold": 0, "sort_rule": 2,
                                    "build": 0, "mobi_app": "web"]
        if let ts = cursor.flatMap({ Int64($0) }), ts > 0 { query["end_ts"] = ts }
        let data = try await BiliHTTP.shared.api(BiliHost.message + "/session_svr/v1/session_svr/get_sessions",
                                                 query: query, sign: .wbi, headers: imHeaders)
        var page = parseSessions(data)
        let missing = page.items.filter { $0.sessionType == 1 && ($0.name.isEmpty || $0.face.isEmpty) }.map(\.talkerId)
        if !missing.isEmpty {
            let users = await userInfos(mids: missing)
            page.items = page.items.map { applyUser(users[$0.talkerId], to: $0) }
        }
        return page
    }

    static func parseSessions(_ data: JSON) -> Page<WhisperSession> {
        let list = data["session_list"].arrayValue
        let sessions = list.compactMap(session)
        let cursorTs = sessions.filter { !$0.isPinned && $0.sessionTs > 0 }.map(\.sessionTs).min()
            ?? sessions.last?.sessionTs ?? 0
        let hasMore = data["has_more"].boolValue && !list.isEmpty && cursorTs > 0
        return Page(items: sessions, hasMore: hasMore, next: hasMore ? String(cursorTs) : nil)
    }

    static func session(_ j: JSON) -> WhisperSession? {
        let talker = j["talker_id"].int64Value
        let type = j["session_type"].int ?? 1
        // 1 = user / official account, 2 = 应援团 group; folded containers cannot be opened.
        guard talker > 0, type == 1 || type == 2 else { return nil }
        var s = WhisperSession()
        s.talkerId = talker
        s.sessionType = type
        s.unreadCount = max(0, j["unread_count"].intValue)
        s.sessionTs = j["session_ts"].int64Value
        s.isPinned = j["top_ts"].int64Value > 0
        s.isMuted = j["is_dnd"].boolValue
        s.isFollowed = j["is_follow"].boolValue
        s.isSystem = j["system_msg_type"].intValue > 0
        s.maxSeqno = j["max_seqno"].int64Value
        if s.sessionType == 2 {
            s.name = j["group_name"].stringValue
            s.face = ListMapping.image(j["group_cover"])
        }
        let account = j["account_info"]
        if s.name.isEmpty { s.name = account["name"].stringValue }
        if s.face.isEmpty { s.face = ListMapping.image(account["pic_url"]) }
        let last = j["last_msg"]
        if last.object != nil {
            let msg = message(last)
            s.preview = previewText(msg, talkerId: talker)
            s.lastTime = msg.timestamp
        }
        if s.lastTime == 0 { s.lastTime = s.sessionTs / 1_000_000 }
        return s
    }

    static func applyUser(_ user: UserBrief?, to s: WhisperSession) -> WhisperSession {
        guard let user else { return s }
        var out = s
        if out.name.isEmpty { out.name = user.name }
        if out.face.isEmpty { out.face = user.face }
        return out
    }

    /// Names and avatars for talker ids (`x/im/user_infos`, falling back to `account/v1/user/cards`).
    static func userInfos(mids: [Int64]) async -> [Int64: UserBrief] {
        let uids = mids.map { String($0) }.joined(separator: ",")
        var query: [String: Any] = ["uids": uids, "build": 0, "mobi_app": "web"]
        if let csrf = BiliHTTP.shared.csrf {
            query["csrf"] = csrf
            query["csrf_token"] = csrf
        }
        if let data = try? await BiliHTTP.shared.api(BiliHost.message + "/x/im/user_infos", query: query, headers: imHeaders) {
            let users = parseUserInfos(data)
            if !users.isEmpty { return users }
        }
        if let data = try? await BiliHTTP.shared.api(BiliHost.message + "/account/v1/user/cards",
                                                     query: ["uids": uids], headers: imHeaders) {
            return parseUserInfos(data)
        }
        return [:]
    }

    static func parseUserInfos(_ data: JSON) -> [Int64: UserBrief] {
        var out: [Int64: UserBrief] = [:]
        for j in data.array ?? data["list"].arrayValue {
            let mid = j["mid"].int64Value
            guard mid > 0 else { continue }
            out[mid] = UserBrief(mid: mid, name: j["name"].stringValue, face: ListMapping.image(j["face"]),
                                 sign: j["sign"].stringValue)
        }
        return out
    }

    // MARK: 私信 conversation

    /// The newest messages (`before` nil), or the ones older than seqno `before`.
    static func messages(peer: WhisperPeer, before seqno: Int64? = nil, size: Int = 30) async throws -> WhisperMessagePage {
        var query: [String: Any] = ["talker_id": peer.talkerId, "session_type": peer.sessionType, "size": size,
                                    "sender_device_id": 1, "build": 0, "mobi_app": "web"]
        if let seqno, seqno > 0 {
            query["begin_seqno"] = 0
            query["end_seqno"] = seqno
        }
        let data = try await BiliHTTP.shared.api(BiliHost.message + "/svr_sync/v1/svr_sync/fetch_session_msgs",
                                                 query: query, sign: .wbi, headers: imHeaders)
        return parseMessages(data)
    }

    /// `data` of `fetch_session_msgs` → oldest-first messages. 撤回 markers (type 5) are removed and flag the
    /// message they withdraw; `minSeqno` / `maxSeqno` cover every returned message, markers included.
    static func parseMessages(_ data: JSON) -> WhisperMessagePage {
        var page = WhisperMessagePage()
        let all = data["messages"].arrayValue.map(message)
        var withdrawn = Set<String>()
        var list: [WhisperMessage] = []
        for m in all {
            if case .withdraw(let key) = m.body {
                if !key.isEmpty { withdrawn.insert(key) }
            } else {
                list.append(m)
            }
        }
        for i in list.indices where withdrawn.contains(list[i].msgKey) { list[i].isWithdrawn = true }
        list.sort { $0.seqno < $1.seqno }
        page.messages = list
        page.withdrawnKeys = withdrawn
        page.hasMore = data["has_more"].boolValue
        let seqnos = all.map(\.seqno).filter { $0 > 0 }
        page.minSeqno = seqnos.min() ?? data["min_seqno"].int64Value
        page.maxSeqno = seqnos.max() ?? data["max_seqno"].int64Value
        for e in data["e_infos"].arrayValue {
            let token = e["text"].stringValue
            // The doc's field table says `uri`, its examples `url`.
            let url = ListMapping.image(e["url"].exists ? e["url"] : (e["uri"].exists ? e["uri"] : e["gif_url"]))
            if !token.isEmpty, !url.isEmpty { page.emotes[token] = url }
        }
        return page
    }

    static func message(_ j: JSON) -> WhisperMessage {
        var m = WhisperMessage()
        m.seqno = j["msg_seqno"].int64Value
        m.msgKey = j["msg_key"].stringValue
        m.senderUid = j["sender_uid"].int64Value
        m.receiverId = j["receiver_id"].int64Value
        m.type = j["msg_type"].intValue
        m.timestamp = j["timestamp"].int64Value
        m.isWithdrawn = j["msg_status"].intValue == 1
        m.isAutoReply = (8...11).contains(j["msg_source"].intValue)
        m.body = messageBody(type: m.type, content: j["content"])
        return m
    }

    /// `content` is a JSON document inside a string (an object on some responses); 撤回 carries a bare key.
    static func messageBody(type: Int, content: JSON) -> WhisperMessageBody {
        let raw = content.string ?? ""
        if type == 5 {
            return .withdraw(msgKey: raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")))
        }
        let c: JSON = content.object != nil ? content : ((try? JSON(string: raw)) ?? .null)
        switch type {
        case 1:
            return .text(c["content"].string ?? raw)
        case 2, 6:
            let url = ListMapping.image(c["url"])
            guard !url.isEmpty else { return .unsupported(type: type) }
            return .image(url: url, width: c["width"].intValue, height: c["height"].intValue)
        case 7:
            return shareCard(c).map { .card($0) } ?? .unsupported(type: type)
        case 10:
            return .notice(notice(c))
        case 11:
            var card = WhisperCard()
            card.duration = c["times"].intValue
            card.title = card.duration == 0 ? "内容已失效" : c["title"].stringValue
            card.cover = ListMapping.image(c["cover"])
            card.subtitle = "视频"
            card.note = c[path: "attach_msg.content"].stringValue
            let aid = c["rid"].int64Value
            let bvid = c["bvid"].stringValue
            if card.duration > 0, aid > 0 || !bvid.isEmpty { card.link = .video(aid: aid, bvid: bvid) }
            return .card(card)
        case 12:
            var card = WhisperCard()
            card.title = c["title"].stringValue
            card.subtitle = c["summary"].stringValue
            card.cover = ListMapping.image(c["image_urls"][0])
            let rid = c["rid"].int64Value
            if rid > 0 { card.link = .article(id: rid) }
            return card.title.isEmpty ? .unsupported(type: type) : .card(card)
        case 13:
            var card = WhisperCard()
            card.cover = ListMapping.image(c["pic_url"])
            card.link = MessageLinks.resolve(c["jump_url"].stringValue)
            return card.cover.isEmpty ? .unsupported(type: type) : .card(card)
        case 14:
            var card = WhisperCard()
            card.title = c["title"].stringValue
            card.cover = ListMapping.image(c["cover"])
            let source = c["source"].stringValue
            card.subtitle = [c["author"].stringValue, source].filter { !$0.isEmpty }.joined(separator: " · ")
            if source == "直播", let room = c["sourceID"].int64, room > 0 {
                card.link = .live(roomId: room)
            } else {
                card.link = MessageLinks.resolve(c["url"].stringValue)
            }
            return card.title.isEmpty && card.cover.isEmpty ? .unsupported(type: type) : .card(card)
        case 16:
            let title = c["main_title"].stringValue
            return title.isEmpty ? .unsupported(type: type) : .notice(WhisperNotice(title: title))
        case 18:
            let text = tipText(c["content"])
            return text.isEmpty ? .unsupported(type: type) : .tip(text)
        default:
            return .unsupported(type: type)
        }
    }

    /// 分享 (type 7): `source` 2 相簿, 5 视频, 6 专栏, 11 动态, 16 番剧.
    static func shareCard(_ c: JSON) -> WhisperCard? {
        var card = WhisperCard()
        card.title = c["title"].stringValue
        card.cover = ListMapping.image(c["thumb"])
        let id = c["id"].stringValue
        var label = ""
        switch c["source"].intValue {
        case 2:
            label = "相簿"
            if !id.isEmpty { card.link = URL(string: "https://h.bilibili.com/\(id)").map { .web($0) } }
        case 5:
            label = "视频"
            var bvid = c["bvid"].stringValue
            let aid = Int64(id) ?? 0
            if bvid.isEmpty, id.hasPrefix("BV") { bvid = id }
            if aid > 0 || !bvid.isEmpty { card.link = .video(aid: aid, bvid: bvid) }
        case 6:
            label = "专栏"
            if let cv = Int64(id), cv > 0 { card.link = .article(id: cv) }
            let headline = c["headline"].stringValue
            if !headline.isEmpty { card.note = headline }
        case 11:
            label = "动态"
            if let dyn = Int64(id), dyn > 0 { card.link = .dynamic(id: id) }
        case 16:
            label = "番剧"
            if let ep = Int64(id), ep > 0 { card.link = .bangumi(epId: ep, seasonId: 0) }
        default:
            card.link = MessageLinks.resolve(c["url"].stringValue)
        }
        card.subtitle = [c["author"].stringValue, label].filter { !$0.isEmpty }.joined(separator: " · ")
        return card.title.isEmpty && card.cover.isEmpty ? nil : card
    }

    /// 通知卡片 (type 10): title, text, `modules` rows and up to three `jump_text*` / `jump_uri*` actions.
    static func notice(_ c: JSON) -> WhisperNotice {
        var n = WhisperNotice()
        n.title = c["title"].stringValue
        n.text = c["text"].stringValue
        n.fields = c["modules"].arrayValue.compactMap { m in
            let title = m["title"].stringValue
            let detail = m["detail"].stringValue
            return title.isEmpty && detail.isEmpty ? nil : WhisperNotice.Field(title: title, detail: detail)
        }
        for suffix in ["", "_2", "_3"] {
            let uri = c["jump_uri" + suffix].stringValue
            guard !uri.isEmpty else { continue }
            let text = c["jump_text" + suffix].stringValue
            n.actions.append(WhisperNotice.Action(text: text.isEmpty ? "查看详情" : text, link: MessageLinks.resolve(uri)))
        }
        return n
    }

    /// Tip (type 18): `content` holds a JSON array (often inside a string) of `{text}` lines.
    static func tipText(_ j: JSON) -> String {
        var lines = j.array
        if lines == nil, let s = j.string {
            if let parsed = try? JSON(string: s), let array = parsed.array { lines = array } else { return s }
        }
        return (lines ?? []).map { $0["text"].stringValue }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Session-list preview of a message.
    static func previewText(_ m: WhisperMessage, talkerId: Int64) -> String {
        let withdrawnText = m.senderUid == talkerId ? "对方撤回了一条消息" : "你撤回了一条消息"
        if m.isWithdrawn { return withdrawnText }
        switch m.body {
        case .text(let s):
            return s.replacingOccurrences(of: "\n", with: " ")
        case .image:
            return m.type == 6 ? "[表情]" : "[图片]"
        case .card(let card):
            switch m.type {
            case 11: return "[视频] " + card.title
            case 12: return "[专栏] " + card.title
            case 13: return "[图片]"
            default: return card.title.isEmpty ? "[分享]" : "[分享] " + card.title
            }
        case .notice(let n):
            return n.title.isEmpty ? "[通知]" : n.title
        case .tip(let s):
            return s.replacingOccurrences(of: "\n", with: " ")
        case .withdraw:
            return withdrawnText
        case .unsupported:
            return "[暂不支持的消息]"
        }
    }

    /// Marks the conversation read up to `seqno`.
    @discardableResult
    static func ack(peer: WhisperPeer, seqno: Int64) async -> Bool {
        guard seqno > 0, let csrf = BiliHTTP.shared.csrf else { return false }
        let query: [String: Any] = ["talker_id": peer.talkerId, "session_type": peer.sessionType, "ack_seqno": seqno,
                                    "build": 0, "mobi_app": "web", "csrf_token": csrf, "csrf": csrf]
        do {
            _ = try await BiliHTTP.shared.api(BiliHost.message + "/session_svr/v1/session_svr/update_ack",
                                              query: query, sign: .wbi, headers: imHeaders)
            return true
        } catch {
            return false
        }
    }

    // MARK: Send

    /// Sends a text 私信 like the web IM page (form body, WBI-signed `w_*` query). Returns the new `msg_key`.
    @discardableResult
    static func sendText(_ text: String, to receiverId: Int64) async throws -> String {
        guard let csrf = BiliHTTP.shared.csrf else { throw BiliError.notLoggedIn }
        let sender = BiliHTTP.shared.mid ?? AuthService.shared.mid
        guard sender > 0, receiverId > 0 else { throw BiliError.notLoggedIn }
        let request = sendTextRequest(text, sender: sender, receiver: receiverId,
                                      deviceId: UUID().uuidString.uppercased(),
                                      timestamp: Int64(Date().timeIntervalSince1970), csrf: csrf)
        let data = try await BiliHTTP.shared.api(BiliHost.message + "/web_im/v1/web_im/send_msg", method: "POST",
                                                 query: request.query, form: request.form, sign: .wbi,
                                                 headers: imHeaders)
        return data["msg_key"].stringValue
    }

    static func sendTextRequest(_ text: String, sender: Int64, receiver: Int64, deviceId: String, timestamp: Int64,
                                csrf: String) -> (query: [String: Any], form: [String: Any]) {
        // Like the web page: `/` unescaped.
        let content = (try? JSONSerialization.data(withJSONObject: ["content": text], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let query: [String: Any] = ["w_sender_uid": sender, "w_receiver_id": receiver, "w_dev_id": deviceId]
        let form: [String: Any] = [
            "msg[sender_uid]": sender,
            "msg[receiver_type]": 1,
            "msg[receiver_id]": receiver,
            "msg[msg_type]": 1,
            "msg[msg_status]": 0,
            "msg[content]": content,
            "msg[timestamp]": timestamp,
            // 1 = current emote names (0 makes the server rewrite e.g. [doge] to an old one), as the web page sends.
            "msg[new_face_version]": 1,
            "msg[dev_id]": deviceId,
            "from_firework": 0,
            "build": 0,
            "mobi_app": "web",
            "csrf": csrf,
            "csrf_token": csrf,
        ]
        return (query, form)
    }
}
