import Foundation

// Port of Bilibili-thread-ripper `src/cdn-resolver.js` (MIT): CDN host lists, URL synthesis by host swap, the
// per-video ban list and the per-track resolver with speed scoring (BTR spec §4–§6).

// MARK: - URL parts (cached)

/// Host / address / route of a URL, parsed once.
struct BTRURLParts {
    /// Lower-cased host name (JS `hostname`).
    var host: String
    /// Signed path + query (JS `pathname + search`): the URL without its node.
    var address: String
    /// Node + file without the query (JS `host + pathname`): speed history survives re-signing.
    var route: String
}

final class BTRURLCache: @unchecked Sendable {
    private static let shared = BTRURLCache()
    private let lock = NSLock()
    private var cache: [String: BTRURLParts] = [:]

    static func parts(_ url: String) -> BTRURLParts { shared.lookup(url) }

    private func lookup(_ url: String) -> BTRURLParts {
        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let parsed: BTRURLParts
        if let c = URLComponents(string: url), let host = c.host?.lowercased(), !host.isEmpty {
            let query = c.percentEncodedQuery ?? ""
            let address = c.percentEncodedPath + (query.isEmpty ? "" : "?" + query)
            let port = c.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
            parsed = BTRURLParts(host: host, address: address, route: host + port + c.percentEncodedPath)
        } else {
            parsed = BTRURLParts(host: "", address: "", route: url)
        }
        lock.lock()
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[url] = parsed
        lock.unlock()
        return parsed
    }
}

/// Ban lists by route (video + part). BTR keeps one per video across restarts of its playback and resets it when
/// the video changes; this keeps the most recent `capacity` routes, so a new session of the same video (quality
/// change, reload) keeps what was learnt.
final class BTRBanRegistry: @unchecked Sendable {
    static let shared = BTRBanRegistry()

    private let capacity: Int
    private let lock = NSLock()
    private var lists: [(route: String, list: BTRBanList)] = []
    private final class Listener {
        weak var owner: AnyObject?
        let call: (String, String, BTRBanKind) -> Void
        init(owner: AnyObject, call: @escaping (String, String, BTRBanKind) -> Void) {
            self.owner = owner
            self.call = call
        }
    }

    private var listeners: [ObjectIdentifier: Listener] = [:]

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    /// The list of `routeKey`, created on first use (most recent first; the oldest route is dropped).
    func banList(for routeKey: String) -> BTRBanList {
        lock.lock()
        defer { lock.unlock() }
        if let i = lists.firstIndex(where: { $0.route == routeKey }) {
            let entry = lists.remove(at: i)
            lists.insert(entry, at: 0)
            return entry.list
        }
        let list = BTRBanList(onBan: { [weak self] host, _, kind in self?.report(routeKey, host, kind) })
        lists.insert((routeKey, list), at: 0)
        if lists.count > capacity { lists.removeLast(lists.count - capacity) }
        return list
    }

    /// `owner` is told about every new ban (`routeKey`, host, kind) while it lives.
    func observe(_ owner: AnyObject, _ call: @escaping (String, String, BTRBanKind) -> Void) {
        lock.lock()
        listeners = listeners.filter { $0.value.owner != nil }
        listeners[ObjectIdentifier(owner)] = Listener(owner: owner, call: call)
        lock.unlock()
    }

    private func report(_ route: String, _ host: String, _ kind: BTRBanKind) {
        lock.lock()
        let calls = listeners.values.filter { $0.owner != nil }.map(\.call)
        lock.unlock()
        for c in calls { c(route, host, kind) }
    }
}

// MARK: - Host lists and URL synthesis

enum BTRCDN {
    /// Default try order (BTR 2026.10.17.1, #44 added mirrorcoso1).
    static let mainlandHosts = [
        "upos-sz-mirrorali.bilivideo.com",
        "upos-sz-mirrorhw.bilivideo.com",
        "upos-sz-mirrorbos.bilivideo.com",
        "upos-sz-mirror08c.bilivideo.com",
        "upos-sz-mirrorbd.bilivideo.com",
        "upos-sz-mirror14b.bilivideo.com",
        "upos-sz-estgoss.bilivideo.com",
        "upos-sz-mirrorcos.bilivideo.com",
        "upos-sz-mirrorcoso1.bilivideo.com",
    ]

    static let overseasHosts = [
        "upos-sz-mirrorcosov.bilivideo.com",
        "upos-sz-mirroraliov.bilivideo.com",
        "cn-hk-eq-01-01.bilivideo.com",
        "cn-hk-eq-01-03.bilivideo.com",
    ]

    static func hostOf(_ url: String) -> String { BTRURLCache.parts(url).host }
    static func addressOf(_ url: String) -> String { BTRURLCache.parts(url).address }
    static func routeOf(_ url: String) -> String { BTRURLCache.parts(url).route }

    /// `*.akamaized.net`: carries its own signature; never a donor unless nothing else exists, never a target.
    static func isAkamai(_ url: String) -> Bool { hostOf(url).hasSuffix(".akamaized.net") }

    /// A P2P / edge-cache relay (mcdn node, mountaintoys.cn): its address works only on relays (#47).
    static func isRelay(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased() else { return false }
        if host.hasPrefix("mcdn.") || host.contains(".mcdn.") { return true }
        if c.percentEncodedPath.lowercased().hasPrefix("/v1/resource/") { return true }
        let os = c.queryItems?.first(where: { $0.name == "os" })?.value ?? ""
        return os.lowercased() == "mcdn"
    }

    /// `safeMediaUrl`: the normalized URL (lower-case host, no default port) if it is a Bilibili media URL.
    static func safeMediaURL(_ value: String) -> String? {
        guard var c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https",
              let host = c.host?.lowercased(), !host.isEmpty,
              BTRRangeCore.isMediaHost(host), BTRRangeCore.isMediaPath(c.percentEncodedPath) else { return nil }
        c.scheme = "https"
        if c.host != host { c.host = host }
        if c.port == 443 { c.port = nil }
        return c.string
    }

    /// Moves a signed URL to another node: host replaced, port CLEARED (PCDN addresses carry e.g. `:4483`, #9),
    /// path and full query kept byte for byte.
    static func swapOrdinaryHost(_ rawURL: String, to targetHost: String, allowAkamai: Bool = false) -> String? {
        if !allowAkamai && isAkamai(rawURL) { return nil }
        let host = targetHost.lowercased()
        guard BTRRangeCore.normalizeCdnHost(host) == host, var c = URLComponents(string: rawURL) else { return nil }
        c.host = host
        c.port = nil
        return c.string
    }

    /// The custom mode's servers (normalized, deduplicated, at most 32); empty outside the custom mode.
    static func customServers(mode: CDNMode, hosts: [String]) -> [String] {
        guard mode == .custom else { return [] }
        return Array(hosts.map(BTRRangeCore.normalizeCdnHost).filter { !$0.isEmpty }.btrDeduped().prefix(32))
    }

    /// Candidate URLs for one representation (`representationUrls`). `urls` = playurl baseUrl + backupUrls in order.
    /// `.original` keeps only the playurl URLs, untouched.
    static func representationURLs(_ urls: [String], mode: CDNMode, customHosts: [String] = []) -> [String] {
        let originals = urls.compactMap(safeMediaURL).btrDeduped()
        if mode == .original { return originals }
        let custom = customServers(mode: mode, hosts: customHosts)
        let hosts = !custom.isEmpty ? custom : mode == .overseas ? overseasHosts : mainlandHosts
        // Relays are never moved: every ordinary node refuses their addresses.
        let ordinary = originals.filter { !isRelay($0) }
        let donor = ordinary.first { !isAkamai($0) }
        let synthetic: [String]
        if let donor {
            synthetic = hosts.compactMap { swapOrdinaryHost(donor, to: $0) }
        } else {
            // Akamai-only accounts (#9): every akamai address on every node, node-major order, so one address every
            // node refuses cannot take all first requests.
            synthetic = hosts.flatMap { host in ordinary.compactMap { swapOrdinaryHost($0, to: host, allowAkamai: true) } }
        }
        let safeSynthetic = synthetic.compactMap(safeMediaURL)
        let allowedOriginals: [String]
        if !custom.isEmpty {
            allowedOriginals = originals.filter { custom.contains(hostOf($0)) }
        } else if mode == .overseas {
            allowedOriginals = originals.filter { !mainlandHosts.contains(hostOf($0)) }
        } else {
            allowedOriginals = originals.filter { mainlandHosts.contains(hostOf($0)) }
        }
        // A track handed out only through relays (#47): use them in every mode rather than failing.
        let relays = ordinary.isEmpty ? originals : []
        return (allowedOriginals + safeSynthetic + relays).btrDeduped()
    }
}

// MARK: - Ban list

enum BTRBanKind: String {
    case node, address
}

/// Per video (route), shared by every track and quality (BTR spec §5). A node that twice fails without sending a
/// single byte is skipped for the rest of the video; a refused (4xx) address is blamed on the address or the node
/// depending on what has delivered data.
final class BTRBanList: @unchecked Sendable {
    private struct ReplyKey: Hashable {
        var node: String
        var address: String
        var refused: Bool
    }

    private let limit: Int
    private let onBan: ((String, Int, BTRBanKind) -> Void)?
    private let lock = NSLock()
    private var replyOrder: [ReplyKey] = []
    private var emptyReplies: [ReplyKey: Int] = [:]
    private var goodNodes = Set<String>()
    private var goodAddresses = Set<String>()
    private var reported = Set<String>()
    private var banned = Set<String>()

    /// `onBan(hostOrNode, strikes, kind)` is called once per newly banned key, outside the lock.
    init(limit: Int = 2, onBan: ((String, Int, BTRBanKind) -> Void)? = nil) {
        self.limit = max(1, limit)
        self.onBan = onBan
    }

    /// A failed attempt. Cancelled attempts and attempts that delivered bytes are not failures. Returns true when a
    /// key was newly banned.
    @discardableResult
    func record(_ url: String, receivedBytes: Int, error: Error?) -> Bool {
        if error?.btrIsCancellation == true || receivedBytes > 0 { return false }
        let parts = BTRURLCache.parts(url)
        guard !parts.host.isEmpty else { return false }
        let status = error?.btrStatus ?? 0
        let key = ReplyKey(node: parts.host, address: parts.address, refused: status >= 400 && status < 500)
        lock.lock()
        if let n = emptyReplies[key] { emptyReplies[key] = n + 1 } else {
            emptyReplies[key] = 1
            replyOrder.append(key)
        }
        let newly = judgeLocked()
        lock.unlock()
        report(newly, url: url)
        return !newly.isEmpty
    }

    /// A verified delivery: the node and the address are proven good.
    func success(_ url: String) {
        let parts = BTRURLCache.parts(url)
        guard !parts.host.isEmpty else { return }
        lock.lock()
        if goodNodes.contains(parts.host) && goodAddresses.contains(parts.address) {
            lock.unlock()
            return
        }
        goodNodes.insert(parts.host)
        goodAddresses.insert(parts.address)
        let newly = judgeLocked()
        lock.unlock()
        report(newly, url: url)
    }

    func allows(_ url: String) -> Bool {
        let p = BTRURLCache.parts(url)
        lock.lock()
        defer { lock.unlock() }
        return !banned.contains("node:\(p.host)") && !banned.contains("address:\(p.address)")
            && !banned.contains("pair:\(p.host) \(p.address)")
    }

    func allowsNode(_ url: String) -> Bool {
        let host = BTRURLCache.parts(url).host
        lock.lock()
        defer { lock.unlock() }
        return !banned.contains("node:\(host)")
    }

    func allowsAddress(_ url: String) -> Bool {
        let address = BTRURLCache.parts(url).address
        lock.lock()
        defer { lock.unlock() }
        return !banned.contains("address:\(address)")
    }

    /// Banned node names.
    func bannedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return banned.filter { $0.hasPrefix("node:") }.map { String($0.dropFirst(5)) }.sorted()
    }

    func reset() {
        lock.lock()
        replyOrder.removeAll()
        emptyReplies.removeAll()
        goodNodes.removeAll()
        goodAddresses.removeAll()
        reported.removeAll()
        banned.removeAll()
        lock.unlock()
    }

    /// Recomputes the bans from scratch; returns the newly banned keys with their strike counts, in order.
    private func judgeLocked() -> [(key: String, count: Int)] {
        var strikes: [String: Int] = [:]
        var order: [String] = []
        for key in replyOrder {
            let count = emptyReplies[key] ?? 0
            let blamed: String
            if !key.refused {
                blamed = "node:\(key.node)"
            } else if goodNodes.contains(key.node) {
                // A node that serves other addresses and refuses one that other nodes serve loses only that pair.
                blamed = goodAddresses.contains(key.address) ? "pair:\(key.node) \(key.address)" : "address:\(key.address)"
            } else if goodAddresses.contains(key.address) {
                blamed = "node:\(key.node)"
            } else {
                blamed = "" // nobody proven yet: blame nobody
            }
            if blamed.isEmpty { continue }
            if strikes[blamed] == nil { order.append(blamed) }
            strikes[blamed, default: 0] += count
        }
        banned = Set(order.filter { (strikes[$0] ?? 0) >= limit })
        var newly: [(String, Int)] = []
        for key in order where banned.contains(key) && !reported.contains(key) {
            reported.insert(key)
            newly.append((key, strikes[key] ?? 0))
        }
        return newly
    }

    private func report(_ newly: [(key: String, count: Int)], url: String) {
        guard let onBan, !newly.isEmpty else { return }
        for item in newly {
            let isNode = item.key.hasPrefix("node:")
            onBan(isNode ? String(item.key.dropFirst(5)) : BTRCDN.hostOf(url), item.count, isNode ? .node : .address)
        }
    }
}

// MARK: - Resolver

/// What assignment needs from a resolver (BTR `assignPrimaries` / desktop `inTurns`).
protocol BTRAssignmentSource: AnyObject {
    /// Fresh measured speed in bytes/s, 0 when unknown or stale.
    func speed(_ url: String) -> Double
    func rangeCandidates() -> [String]
}

/// Per-track CDN resolver (BTR `createResolver`, spec §6). Mode and custom hosts are read through closures on every
/// call, and the track's URLs through `urls`, so settings changes and URL refreshes apply at once. Thread-safe.
final class BTRResolver: BTRAssignmentSource, @unchecked Sendable {
    static let measurementTTLMs: Double = 90_000

    private struct Health {
        var failures = 0
        var blockedUntil: Double = 0
        var lastSuccessAt: Double = 0
    }

    private struct Route {
        var lastSuccessAt: Double = 0
        var lastMeasuredAt: Double = 0
        var bps: Double = 0
    }

    private let urlProvider: () -> [String]
    private let modeProvider: () -> CDNMode
    private let customHostsProvider: () -> [String]
    let bans: BTRBanList?
    private let clock: MonotonicClock
    private let lock = NSLock()
    private var health: [String: Health] = [:]
    private var routes: [String: Route] = [:]
    private var cursor = 0
    private var mediaRangeCount = 0
    private var rangeCursor = 0
    // One-entry cache of representationURLs.
    private var cacheKey: (urls: [String], mode: CDNMode, custom: [String])?
    private var cacheValue: [String] = []

    init(urls: @escaping () -> [String], mode: @escaping () -> CDNMode, customHosts: @escaping () -> [String] = { [] },
         bans: BTRBanList? = nil, clock: MonotonicClock = SystemClock.shared) {
        urlProvider = urls
        modeProvider = mode
        customHostsProvider = customHosts
        self.bans = bans
        self.clock = clock
    }

    // MARK: Lists

    /// Every candidate of the current mode, banned or not (`allUrls`).
    func allURLs() -> [String] {
        let source = urlProvider()
        let mode = modeProvider()
        let custom = mode == .custom ? customHostsProvider() : []
        lock.lock()
        if let key = cacheKey, key.urls == source, key.mode == mode, key.custom == custom {
            let v = cacheValue
            lock.unlock()
            return v
        }
        lock.unlock()
        let value = BTRCDN.representationURLs(source, mode: mode, customHosts: custom)
        lock.lock()
        cacheKey = (source, mode, custom)
        cacheValue = value
        lock.unlock()
        return value
    }

    /// If everything is banned, keep the full list rather than end up with no address at all.
    private func unbanned(_ list: [String]) -> [String] {
        guard let bans else { return list }
        let allowed = list.filter(bans.allows)
        return allowed.isEmpty ? list : allowed
    }

    func urls() -> [String] { unbanned(allURLs()) }

    private func availableLocked(_ url: String, now: Double) -> Bool {
        (health[url]?.blockedUntil ?? 0) <= now
    }

    private func measuredNowLocked(_ url: String, now: Double) -> Bool {
        guard let r = routes[BTRCDN.routeOf(url)], r.lastMeasuredAt > 0 else { return false }
        return now - r.lastMeasuredAt < Self.measurementTTLMs
    }

    /// Had-success first, then bps descending; stable.
    private func sortedBySpeedLocked(_ list: [String]) -> [String] {
        let keyed = list.map { url -> (String, Bool, Double) in
            let r = routes[BTRCDN.routeOf(url)]
            return (url, (r?.lastSuccessAt ?? 0) > 0, r?.bps ?? 0)
        }
        return keyed.btrStableSorted { a, b in
            if a.1 != b.1 { return a.1 }
            return a.2 > b.2
        }.map(\.0)
    }

    /// Simple rotation for fallbacks.
    func ordered(_ pieceIndex: Int = 0, exclude: Set<String> = []) -> [String] {
        let candidates = urls().filter { !exclude.contains($0) }
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        let available = candidates.filter { availableLocked($0, now: now) }
        let pool = available.isEmpty ? candidates : available
        guard !pool.isEmpty else { return [] }
        let offset = ((cursor + pieceIndex) % pool.count + pool.count) % pool.count
        cursor = (cursor + 1) % pool.count
        return Array(pool[offset...] + pool[..<offset])
    }

    /// Called once per media range: warm-up over every node, then the measured nodes plus exploration slots.
    func rangeCandidates() -> [String] {
        let all = urls()
        let mode = modeProvider()
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        let pool = sortedBySpeedLocked(all.filter { availableLocked($0, now: now) })
        if pool.isEmpty { return all }
        let width = min(mediaRangeCount == 0 ? pool.count : 6, pool.count)
        let warmupRanges = mode == .mainland ? 1 : 4
        var selected: [String]
        if mediaRangeCount < warmupRanges {
            selected = Array(pool.prefix(width))
            rangeCursor = width % pool.count
        } else {
            let measured = pool.filter { measuredNowLocked($0, now: now) }
            let rest = pool.filter { !measuredNowLocked($0, now: now) }
            let places = min(rest.count, max(1, width - measured.count))
            let explore = (0..<places).map { rest[(rangeCursor + $0) % rest.count] }
            rangeCursor = (rangeCursor + places) % max(1, pool.count)
            selected = Array(measured.prefix(max(0, width - explore.count))) + explore
            for url in pool {
                if selected.count >= min(3, pool.count) { break }
                if !selected.contains(url) { selected.append(url) }
            }
        }
        mediaRangeCount += 1
        return selected
    }

    /// init / index race and startup fallbacks: Bilibili's own URLs first (except in the custom mode), ≤ 8.
    func startupCandidates() -> [String] {
        let source = urlProvider()
        let mode = modeProvider()
        let custom = BTRCDN.customServers(mode: mode, hosts: mode == .custom ? customHostsProvider() : [])
        let originals = custom.isEmpty ? source.compactMap(BTRCDN.safeMediaURL) : []
        let candidates = unbanned((originals + allURLs()).btrDeduped())
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        return Array(candidates.filter { availableLocked($0, now: now) }.prefix(8))
    }

    /// Not backing off, fastest first.
    func rescueCandidates() -> [String] {
        let all = urls()
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        return sortedBySpeedLocked(all.filter { availableLocked($0, now: now) })
    }

    // MARK: Feedback

    /// A verified delivery; `bps` = 0 when the transfer was too short to measure (< 48 KiB).
    func success(_ url: String, bps: Double) {
        bans?.success(url)
        let key = BTRCDN.routeOf(url)
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        let old = routes[key] ?? Route()
        let measured = bps > 0
        health[url] = Health(failures: 0, blockedUntil: 0, lastSuccessAt: now)
        routes[key] = Route(
            lastSuccessAt: now,
            lastMeasuredAt: measured ? now : old.lastMeasuredAt,
            bps: !measured ? old.bps : old.bps > 0 ? old.bps * 0.65 + bps * 0.35 : bps
        )
    }

    /// Speed of a transfer cut off before its end (a hedge loser): measures the node, forgives nothing.
    func sample(_ url: String, bps: Double) {
        guard bps > 0 else { return }
        let key = BTRCDN.routeOf(url)
        lock.lock()
        defer { lock.unlock() }
        let old = routes[key] ?? Route()
        routes[key] = Route(lastSuccessAt: old.lastSuccessAt, lastMeasuredAt: clock.nowMs(),
                            bps: old.bps > 0 ? old.bps * 0.65 + bps * 0.35 : bps)
    }

    /// A failed attempt: backoff 6 / 12 / 24 / 48 s; 0-byte failures feed the ban list. Cancellation is ignored.
    func failure(_ url: String, error: Error, receivedBytes: Int = 0) {
        if error.btrIsCancellation { return }
        bans?.record(url, receivedBytes: receivedBytes, error: error)
        lock.lock()
        defer { lock.unlock() }
        var h = health[url] ?? Health()
        h.failures += 1
        h.blockedUntil = clock.nowMs() + min(60_000, 3000 * pow(2, Double(min(h.failures, 4))))
        health[url] = h
    }

    func speed(_ url: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        guard measuredNowLocked(url, now: now) else { return 0 }
        return routes[BTRCDN.routeOf(url)]?.bps ?? 0
    }

    func allows(_ url: String) -> Bool { bans?.allows(url) ?? true }

    /// Node list for diagnostics; refused addresses say nothing about their node and are left out.
    func status() -> [CDNNodeStatus] {
        let all = allURLs()
        let usable = bans.map { b in all.filter(b.allowsAddress) } ?? all
        let list = usable.isEmpty ? all : usable
        let nodeBanned = list.map { url in bans.map { !$0.allowsNode(url) } ?? false }
        lock.lock()
        defer { lock.unlock() }
        let now = clock.nowMs()
        return zip(list, nodeBanned).map { url, isBanned in
            let route = routes[BTRCDN.routeOf(url)]
            let state: CDNNodeStatus.State
            if isBanned {
                state = .banned
            } else if (health[url]?.blockedUntil ?? 0) > now {
                state = .blocked
            } else if (route?.lastSuccessAt ?? 0) > 0 {
                state = .healthy
            } else {
                state = .untested
            }
            return CDNNodeStatus(host: BTRCDN.hostOf(url), state: state, bytesPerSecond: route?.bps ?? 0)
        }
    }
}
