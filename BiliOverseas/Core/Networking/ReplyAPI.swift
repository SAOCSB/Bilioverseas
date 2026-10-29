import Foundation

/// Comment (评论) REST API. `oid` = aid (PGC: the episode's aid), `type` = 1 for videos.
enum ReplyAPI {
    private static var http: BiliHTTP { BiliHTTP.shared }
    private static let api = BiliHost.api

    // MARK: - Lists

    /// Main comment list with cursor pagination. Logged in: `/x/v2/reply/wbi/main` (WBI, carries the
    /// user's like state); logged out or on failure: `/x/v2/reply/main`.
    static func mainList(oid: Int64, type: Int = 1, sort: ReplySort = .hot, cursor: String? = nil) async throws -> ReplyPage {
        let query = mainListQuery(oid: oid, type: type, sort: sort, cursor: cursor)
        let isFirstPage = (cursor ?? "").isEmpty
        let wbiURL = api + "/x/v2/reply/wbi/main"
        let plainURL = api + "/x/v2/reply/main"
        do {
            let data: JSON
            if http.isLoggedIn {
                do {
                    data = try await http.api(wbiURL, query: query, sign: .wbi)
                } catch let e where isEndpointFailure(e) {
                    data = try await http.api(plainURL, query: query)
                }
            } else {
                do {
                    data = try await http.api(plainURL, query: query)
                } catch let e where isEndpointFailure(e) {
                    data = try await http.api(wbiURL, query: query, sign: .wbi)
                }
            }
            return parseMainPage(data, isFirstPage: isFirstPage)
        } catch {
            throw mapError(error)
        }
    }

    static func mainListQuery(oid: Int64, type: Int, sort: ReplySort, cursor: String?) -> [String: Any] {
        var q: [String: Any] = [
            "oid": oid, "type": type, "mode": sort.mode,
            "pagination_str": paginationString(offset: cursor),
            "plat": 1, "web_location": "1315875",
        ]
        if (cursor ?? "").isEmpty { q["seek_rpid"] = "" }
        return q
    }

    /// `{"offset":"…"}` with the offset JSON-escaped (it is itself a JSON string).
    static func paginationString(offset: String?) -> String {
        #"{"offset":""# + jsonEscaped(offset ?? "") + #""}"#
    }

    static func jsonEscaped(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    /// Parses `data` of `/x/v2/reply/(wbi/)main`.
    static func parseMainPage(_ data: JSON, isFirstPage: Bool) -> ReplyPage {
        var page = ReplyPage()
        let upperMid = data[path: "upper.mid"].int64Value
        page.upperMid = upperMid
        if isFirstPage {
            var seen = Set<Int64>()
            let candidates = [data[path: "top.upper"], data[path: "top.admin"], data[path: "upper.top"]]
                + data["top_replies"].arrayValue
            for j in candidates where j.object != nil {
                var r = ReplyItem(json: j, upperMid: upperMid)
                guard r.rpid != 0, seen.insert(r.rpid).inserted else { continue }
                r.isUpTop = true
                page.topItems.append(r)
            }
        }
        let topIds = Set(page.topItems.map(\.rpid))
        page.items = data["replies"].arrayValue
            .map { ReplyItem(json: $0, upperMid: upperMid) }
            .filter { $0.rpid != 0 && !topIds.contains($0.rpid) }
        let cursor = data["cursor"]
        let next = cursor[path: "pagination_reply.next_offset"].stringValue
        page.nextCursor = next.isEmpty ? nil : next
        page.hasMore = !cursor["is_end"].boolValue && page.nextCursor != nil
        page.totalCount = cursor["all_count"].int ?? data[path: "page.count"].intValue
        applyControl(data["control"], to: &page, root: true)
        return page
    }

    /// Sub replies of `root` (`/x/v2/reply/reply`, 20 per page, `page` is 1-based).
    static func subReplies(oid: Int64, type: Int = 1, root: Int64, page: Int = 1) async throws -> ReplyPage {
        do {
            let data = try await http.api(api + "/x/v2/reply/reply", query: [
                "oid": oid, "type": type, "root": root, "pn": max(1, page), "ps": 20, "web_location": "333.788",
            ])
            return parseSubPage(data, page: max(1, page))
        } catch {
            throw mapError(error)
        }
    }

    static func parseSubPage(_ data: JSON, page: Int) -> ReplyPage {
        var out = ReplyPage()
        let upperMid = data[path: "upper.mid"].int64Value
        out.upperMid = upperMid
        out.items = data["replies"].arrayValue.map { ReplyItem(json: $0, upperMid: upperMid) }.filter { $0.rpid != 0 }
        if data["root"].object != nil {
            let r = ReplyItem(json: data["root"], upperMid: upperMid)
            if r.rpid != 0 { out.root = r }
        }
        let count = data[path: "page.count"].intValue
        let size = data[path: "page.size"].int ?? 20
        let num = data[path: "page.num"].int ?? page
        out.totalCount = count
        out.hasMore = !out.items.isEmpty && num * max(size, 1) < count
        out.nextCursor = out.hasMore ? String(num + 1) : nil
        applyControl(data["control"], to: &out, root: false)
        return out
    }

    private static func applyControl(_ control: JSON, to page: inout ReplyPage, root: Bool) {
        page.inputDisabled = control["input_disable"].boolValue
        let text = control[root ? "root_input_text" : "child_input_text"].stringValue
        page.inputPlaceholder = text
    }

    // MARK: - Actions

    /// Like (`like == true`) or cancel (`/x/v2/reply/action`, action 1/0).
    static func like(oid: Int64, type: Int = 1, rpid: Int64, like: Bool) async throws {
        _ = try await post("/x/v2/reply/action", form: ["oid": oid, "type": type, "rpid": rpid, "action": like ? 1 : 0])
    }

    /// Dislike / cancel (`/x/v2/reply/hate`).
    static func dislike(oid: Int64, type: Int = 1, rpid: Int64, dislike: Bool) async throws {
        _ = try await post("/x/v2/reply/hate", form: ["oid": oid, "type": type, "rpid": rpid, "action": dislike ? 1 : 0])
    }

    /// Posts a comment. For a root comment leave `root`/`parent` 0; replying to a root comment sets both to
    /// its rpid; replying deeper sets `root` = root rpid, `parent` = replied rpid.
    static func add(oid: Int64, type: Int = 1, message: String, root: Int64 = 0, parent: Int64 = 0) async throws -> ReplyItem {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BiliError.other("请输入评论内容") }
        var form: [String: Any] = ["oid": oid, "type": type, "message": text, "plat": 1]
        if root != 0 { form["root"] = root }
        if parent != 0 { form["parent"] = parent }
        let data = try await post("/x/v2/reply/add", form: form)
        return parseAddResult(data, oid: oid, type: type, message: text, root: root, parent: parent)
    }

    static func parseAddResult(_ data: JSON, oid: Int64, type: Int, message: String, root: Int64, parent: Int64) -> ReplyItem {
        let reply = data["reply"]
        if reply["rpid"].int64Value != 0 { return ReplyItem(json: reply) }
        var r = ReplyItem()
        r.rpid = data["rpid"].int64Value
        r.oid = oid
        r.type = type
        r.root = root
        r.parent = parent
        r.message = message
        r.ctime = Int64(Date().timeIntervalSince1970)
        r.mid = BiliHTTP.shared.mid ?? 0
        return r
    }

    static func delete(oid: Int64, type: Int = 1, rpid: Int64) async throws {
        _ = try await post("/x/v2/reply/del", form: ["oid": oid, "type": type, "rpid": rpid])
    }

    // MARK: - Errors

    static func friendlyMessage(code: Int) -> String? {
        switch code {
        case 12002: return "评论区已关闭"
        case 12009: return "评论主体不存在"
        case 12015: return "需要输入验证码，请稍后再试"
        case 12016: return "评论包含敏感信息"
        case 12022: return "该评论已被删除"
        case 12025: return "评论字数过多"
        case 12035: return "你已被UP主拉黑，无法评论"
        case 12051: return "重复评论，请勿刷屏"
        case 12053: return "评论发送太频繁，请稍后再试"
        case -111: return "登录状态校验失败，请重新登录"
        default: return nil
        }
    }

    static func mapError(_ error: Error) -> Error {
        guard let e = error as? BiliError, case .api(let code, _) = e, let msg = friendlyMessage(code: code) else { return error }
        return BiliError.api(code: code, message: msg)
    }

    private static func isEndpointFailure(_ error: Error) -> Bool {
        guard let e = error as? BiliError else { return true }
        switch e {
        case .http, .decoding: return true
        case .api(let code, _): return [-400, -403, -404, -352, -412].contains(code)
        default: return false
        }
    }

    private static func post(_ path: String, form: [String: Any]) async throws -> JSON {
        do { return try await http.post(api + path, form: form) } catch { throw mapError(error) }
    }
}
