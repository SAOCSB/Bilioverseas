import Foundation

/// Thread-safe set of the mids the logged-in user follows, used by `FeedFilter` for the
/// 「关注的 UP 不过滤」 exemption. The API / auth layer fills it after login (`update(_:)`),
/// keeps it current on follow / unfollow (`insert` / `remove`) and empties it on logout (`clear()`).
/// The set is persisted so the very first recommend page after launch is already exempted.
final class FollowedUpsStore {
    static let shared = FollowedUpsStore()

    private let lock = NSLock()
    private var storage: Set<Int64>
    private let defaults: UserDefaults?
    private let key: String

    /// - Parameter defaults: where to persist the set; nil keeps it in memory only (tests).
    init(defaults: UserDefaults? = .standard, key: String = "feedFilter.followedMids") {
        self.defaults = defaults
        self.key = key
        if let data = defaults?.data(forKey: key),
           let saved = try? JSONDecoder().decode([Int64].self, from: data) {
            storage = Set(saved)
        } else {
            storage = []
        }
    }

    /// Snapshot of the followed mids. Setting it is the same as `update(_:)`.
    var mids: Set<Int64> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set { update(newValue) }
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

    /// Replaces the whole set (e.g. after fetching the followings list).
    func update(_ mids: Set<Int64>) {
        lock.lock()
        defer { lock.unlock() }
        storage = mids
        persistLocked()
    }

    /// The user followed someone.
    func insert(_ mid: Int64) {
        guard mid != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if storage.insert(mid).inserted { persistLocked() }
    }

    /// The user unfollowed someone.
    func remove(_ mid: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if storage.remove(mid) != nil { persistLocked() }
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
