import UIKit

/// 点赞 / 复制 / 举报 / 撤回 / 屏蔽 of one danmaku, shared by the 「点击弹幕」 bubble and 「弹幕列表」
/// (features.md §8.6). Server actions need login and a dmid; every result is reported with a toast.
@MainActor
enum DanmakuActions {
    static func copy(_ item: DanmakuItem) {
        UIPasteboard.general.string = item.readableText
        ToastCenter.shared.show("已复制")
    }

    /// Toggles 点赞 and records the new state on `overlay`. Returns it, or nil when the request failed.
    @discardableResult
    static func toggleLike(_ item: DanmakuItem, cid: Int64, overlay: DanmakuOverlayView) async -> DanmakuLikeState? {
        guard canUseServer(item, cid: cid) else { return nil }
        let current = overlay.likeState(of: item)
        do {
            let result = try await DanmakuService.setLike(cid: cid, dmid: item.id, like: !current.liked)
            var next = current
            next.liked = result.liked
            if result.changed { next.count = max(0, current.count + (result.liked ? 1 : -1)) }
            overlay.setLikeState(next, for: item.id)
            if result.changed {
                ToastCenter.shared.show(result.liked ? "点赞成功" : "已取消点赞")
            } else {
                ToastCenter.shared.show(result.liked ? "已经点过赞了" : "还没有点赞")
            }
            return next
        } catch {
            ToastCenter.shared.show(error: error)
            return nil
        }
    }

    /// 举报 with one of `DanmakuService.reportReasons`.
    @discardableResult
    static func report(_ item: DanmakuItem, cid: Int64, reason: Int) async -> Bool {
        guard canUseServer(item, cid: cid) else { return false }
        do {
            try await DanmakuService.report(cid: cid, dmid: item.id, reason: reason)
            ToastCenter.shared.show("举报已提交")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    /// 撤回 an own danmaku; on success it disappears from `overlay` (screen and loaded data).
    @discardableResult
    static func recall(_ item: DanmakuItem, cid: Int64, overlay: DanmakuOverlayView) async -> Bool {
        guard canUseServer(item, cid: cid) else { return false }
        do {
            let message = try await DanmakuService.recall(cid: cid, dmid: item.id)
            overlay.removeDanmaku(id: item.id)
            ToastCenter.shared.show(message.isEmpty || message == "0" ? "撤回成功" : message)
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    /// 屏蔽发送者: adds the sender's midHash to the user block list (and the account's, when logged in).
    static func blockSender(_ item: DanmakuItem) {
        let hash = item.midHash.trimmingCharacters(in: .whitespaces).lowercased()
        guard !hash.isEmpty else {
            ToastCenter.shared.show("无法识别该弹幕的发送者")
            return
        }
        ToastCenter.shared.show(DanmakuBlockSync.addUser(hash: hash) ? "已屏蔽该用户的弹幕" : "该用户已在屏蔽列表中")
    }

    /// 屏蔽关键词: adds the danmaku's text as a keyword rule (and to the account's rules, when logged in).
    static func blockContent(_ item: DanmakuItem) {
        let text = blockKeyword(for: item)
        guard !text.isEmpty else { return }
        ToastCenter.shared.show(DanmakuBlockSync.addKeyword(text) ? "已屏蔽关键词「\(text)」" : "该关键词已在屏蔽列表中")
    }

    /// The keyword 「屏蔽关键词」 adds: the visible text on one line, at most 50 characters (a `/…/` text is
    /// stored as a keyword, not read as a regex).
    static func blockKeyword(for item: DanmakuItem) -> String {
        var text = item.readableText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.count > 50 { text = String(text.prefix(50)) }
        if DanmakuFilter.regexPattern(from: text) != nil { text = String(text.dropLast()) }
        return text
    }

    private static func canUseServer(_ item: DanmakuItem, cid: Int64) -> Bool {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return false
        }
        guard item.hasServerID, cid > 0 else {
            ToastCenter.shared.show("这条弹幕暂不支持该操作")
            return false
        }
        return true
    }
}

/// Danmaku block rules kept in `AppSettings.shared.danmaku` and mirrored to the account
/// (`x/dm/filter/user`, features.md §9) while logged in. Logged out, rules stay local; 「同步账号屏蔽列表」
/// uploads them later. A failed upload keeps the local rule and says so.
@MainActor
enum DanmakuBlockSync {
    /// Adds a keyword or `/regex/` rule. False when it already exists.
    @discardableResult
    static func addKeyword(_ rule: String) -> Bool {
        let settings = AppSettings.shared
        guard !rule.isEmpty, !settings.danmaku.blockedKeywords.contains(rule) else { return false }
        settings.danmaku.blockedKeywords.append(rule)
        let form = DanmakuCloudRule.cloudForm(keyword: rule)
        upload(type: form.type, filter: form.filter) { id in
            guard settings.danmaku.blockedKeywords.contains(rule) else { return false }
            settings.danmaku.cloudRuleIds[rule] = id
            return true
        }
        return true
    }

    /// Adds a sender midHash (`label`: the UID the user typed, shown in the list). False when it already exists.
    @discardableResult
    static func addUser(hash: String, label: String? = nil) -> Bool {
        let settings = AppSettings.shared
        guard !hash.isEmpty, !settings.danmaku.blockedUsers.contains(hash) else { return false }
        settings.danmaku.blockedUsers.append(hash)
        if let label { settings.danmaku.blockedUserLabels[hash] = label }
        upload(type: 2, filter: hash) { id in
            guard settings.danmaku.blockedUsers.contains(hash) else { return false }
            settings.danmaku.cloudUserRuleIds[hash] = id
            return true
        }
        return true
    }

    /// Removes rules locally and, for those stored on the account, there too.
    static func remove(keywords: Set<String> = [], users: Set<String> = []) {
        var danmaku = AppSettings.shared.danmaku
        let ids = danmaku.removeBlockRules(keywords: keywords, users: users)
        AppSettings.shared.danmaku = danmaku
        guard !ids.isEmpty, BiliHTTP.shared.isLoggedIn else { return }
        Task { @MainActor in
            do {
                try await DanmakuService.deleteCloudRules(ids: ids)
            } catch {
                ToastCenter.shared.show("已在本机删除，同步到账号失败：\(error.localizedDescription)")
            }
        }
    }

    struct SyncResult {
        var imported = 0
        var uploaded = 0
        /// Set when an upload failed (the rules before it were uploaded; the rest stay local).
        var uploadError: Error?
    }

    /// 「同步账号屏蔽列表」: imports the account's rules, then uploads the local ones it does not have yet.
    static func sync() async throws -> SyncResult {
        let rules = try await DanmakuService.fetchCloudRules()
        var danmaku = AppSettings.shared.danmaku
        var result = SyncResult()
        result.imported = DanmakuCloudRule.merge(rules, into: &danmaku)
        AppSettings.shared.danmaku = danmaku
        for pending in DanmakuCloudRule.pendingUploads(danmaku) {
            do {
                let stored = try await DanmakuService.addCloudRule(type: pending.type, filter: pending.filter)
                result.uploaded += 1
                guard stored.id > 0 else { continue }
                if pending.type == 2 {
                    if AppSettings.shared.danmaku.blockedUsers.contains(pending.rule) {
                        AppSettings.shared.danmaku.cloudUserRuleIds[pending.rule] = stored.id
                    }
                } else if AppSettings.shared.danmaku.blockedKeywords.contains(pending.rule) {
                    AppSettings.shared.danmaku.cloudRuleIds[pending.rule] = stored.id
                }
            } catch {
                result.uploadError = error
                break
            }
        }
        return result
    }

    /// Uploads one rule when logged in. `store` records the server id and returns false when the local rule is
    /// gone meanwhile, in which case the server copy is deleted again.
    private static func upload(type: Int, filter: String, store: @escaping @MainActor (Int64) -> Bool) {
        guard BiliHTTP.shared.isLoggedIn else { return }
        Task { @MainActor in
            do {
                let rule = try await DanmakuService.addCloudRule(type: type, filter: filter)
                if rule.id > 0, !store(rule.id) { try? await DanmakuService.deleteCloudRules(ids: [rule.id]) }
            } catch {
                ToastCenter.shared.show("已在本机屏蔽，同步到账号失败：\(error.localizedDescription)")
            }
        }
    }
}
