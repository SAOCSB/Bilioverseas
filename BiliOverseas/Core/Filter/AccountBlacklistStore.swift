import Foundation

/// Thread-safe set of the mids on the logged-in account's blacklist (黑名单 / 拉黑), PiliPlus's
/// `blackMids`. `FeedFilter` hides their cards from every list except their own space page.
/// `refreshFromAccount()` replaces it with the server list (after login / at launch), `insert` /
/// `remove` follow 拉黑 / 取消拉黑 made in the app, and `clear()` empties it on logout.
/// The set is persisted so the first pages after launch are already filtered.
final class AccountBlacklistStore {
    static let shared = AccountBlacklistStore()

    /// Posted (on any thread, object: the store) after the set changed, so lists re-apply `FeedFilter`.
    static let didChange = Notification.Name("AccountBlacklistStoreDidChange")

    private let lock = NSLock()
    private var storage: Set<Int64>
    private let defaults: UserDefaults?
    private let key: String

    /// - Parameter defaults: where to persist the set; nil keeps it in memory only (tests).
    init(defaults: UserDefaults? = .standard, key: String = "feedFilter.blacklistMids") {
        self.defaults = defaults
        self.key = key
        if let data = defaults?.data(forKey: key),
           let saved = try? JSONDecoder().decode([Int64].self, from: data) {
            storage = Set(saved)
        } else {
            storage = []
        }
    }

    var mids: Set<Int64> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func contains(_ mid: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains(mid)
    }

    /// Replaces the whole set (the account's blacklist was fetched).
    func update(_ mids: Set<Int64>) {
        mutate { storage in
            guard storage != mids else { return false }
            storage = mids
            return true
        }
    }

    /// 拉黑 succeeded.
    func insert(_ mid: Int64) {
        guard mid != 0 else { return }
        mutate { $0.insert(mid).inserted }
    }

    /// 取消拉黑 succeeded.
    func remove(_ mid: Int64) {
        mutate { $0.remove(mid) != nil }
    }

    /// Applies `change` under the lock; when it reports a change, persists and posts `didChange`.
    private func mutate(_ change: (inout Set<Int64>) -> Bool) {
        lock.lock()
        let changed = change(&storage)
        if changed { persistLocked() }
        lock.unlock()
        if changed { NotificationCenter.default.post(name: AccountBlacklistStore.didChange, object: self) }
    }

    /// Logout.
    func clear() { update([]) }

    /// Caller holds `lock`.
    private func persistLocked() {
        guard let defaults else { return }
        if storage.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(Array(storage)) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Account sync

extension AccountBlacklistStore {
    /// `GET /x/relation/blacks` page size (the server's maximum).
    static let pageSize = 50

    /// `data` of `/x/relation/blacks` → mids on the page and the list's total.
    static func parseBlacks(_ data: JSON) -> (mids: [Int64], total: Int) {
        let mids = data["list"].arrayValue.compactMap { j -> Int64? in
            let mid = j["mid"].int64Value
            return mid > 0 ? mid : nil
        }
        return (mids, data["total"].intValue)
    }

    /// Replaces the set with the account's blacklist (login required; at most `cap` mids). Throws only
    /// when the first page fails (the stored set is kept then); after a later failure the fetched mids
    /// are added to the stored ones.
    @discardableResult
    func refreshFromAccount(cap: Int = 1000) async throws -> Set<Int64> {
        guard BiliHTTP.shared.isLoggedIn else { throw BiliError.notLoggedIn }
        var mids = Set<Int64>()
        var page = 1
        var complete = true
        while mids.count < cap {
            let result: (mids: [Int64], total: Int)
            do {
                let data = try await BiliHTTP.shared.api(
                    BiliHost.api + "/x/relation/blacks",
                    query: ["pn": page, "ps": AccountBlacklistStore.pageSize, "re_version": 0, "web_location": "333.1387"])
                result = AccountBlacklistStore.parseBlacks(data)
            } catch {
                if page == 1 || ListMapping.isCancellation(error) { throw error }
                complete = false
                break
            }
            mids.formUnion(result.mids)
            let more = result.mids.count >= AccountBlacklistStore.pageSize
                && (result.total == 0 || page * AccountBlacklistStore.pageSize < result.total)
            guard more else { break }
            page += 1
        }
        // A partial list cannot tell removed mids from unfetched ones: keep the stored ones too.
        if !complete { mids.formUnion(self.mids) }
        update(mids)
        return mids
    }
}
