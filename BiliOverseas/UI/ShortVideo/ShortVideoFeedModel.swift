import Combine
import SwiftUI

/// State of the 短视频 feed: the videos loaded so far, the one on screen, and its players. The current
/// video plays while the screen is visible and the app is active; the next one is prepared so a swipe
/// starts at once; the previous one keeps its player for a quick swipe back. Others are released.
@MainActor
final class ShortVideoFeedModel: ObservableObject {
    @Published private(set) var items: [ShortVideoItem] = []
    @Published var index = 0 {
        didSet {
            guard index != oldValue else { return }
            userPaused = false
            activate()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// 「只看竖屏」: landscape videos are skipped.
    @Published private(set) var portraitOnly = AppSettings.shared.general.shortVideoOnlyPortrait
    /// 「N人正在看」 of the video on screen.
    @Published private(set) var onlineText: String?
    /// The page a swipe is coming to rest on (nil: none is). `index` follows once it has stopped. Not published: a
    /// render in the middle of the swipe's deceleration would rebuild the visible pages for nothing.
    var landingIndex: Int?

    /// Entry video (tapped in a list), shown first while page 1 loads; nil starts from the feed's pick.
    let start: ShortVideoItem?
    private var cursor: ShortVideoCursor?
    private var exhausted = false
    private var playbacks: [String: ShortVideoPlayback] = [:]
    private var socials: [String: ShortVideoSocial] = [:]
    private var visible = false
    private var appActive = true
    /// The user paused the video on screen (tap); coming back to the screen or the app keeps it paused.
    private var userPaused = false
    /// Bumped by 换一批 so a page still loading for the old feed is dropped.
    private var generation = 0
    private var loadingGeneration: Int?
    private var onlineItemID: String?
    private var onlineTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(start: ShortVideoItem?) {
        self.start = start
        if let start { items = [start] }
        if SmokeTest.isEnabled { SmokeTest.activeShortVideoFeed = self }
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setAppActive(false) }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.setAppActive(true) }
            .store(in: &cancellables)
    }

    var current: ShortVideoItem? { items.indices.contains(index) ? items[index] : nil }

    /// What the bars around the pages act on: while a swipe comes to rest, the video it comes to, not the one leaving.
    var showing: ShortVideoItem? {
        if let landingIndex, items.indices.contains(landingIndex) { return items[landingIndex] }
        return current
    }

    // MARK: Loading

    func loadInitialIfNeeded() async {
        guard cursor == nil, !isLoading else { return }
        if !items.isEmpty { activate() }
        await loadMore()
    }

    /// 换一批: starts the feed over from the entry video.
    func reload() async {
        generation += 1
        closeAll()
        items = []
        onlineTask?.cancel()
        onlineItemID = nil
        onlineText = nil
        cursor = nil
        exhausted = false
        userPaused = false
        index = 0
        await loadMore()
    }

    /// Appends the next page. A page can come back without a new video (all ads, or no portrait one with
    /// 「只看竖屏」), so it asks again, a few times at most; the next swipe near the end tries once more.
    func loadMore() async {
        let gen = generation
        guard loadingGeneration != gen, !exhausted else { return }
        loadingGeneration = gen
        isLoading = true
        errorText = nil
        defer {
            if loadingGeneration == gen {
                loadingGeneration = nil
                isLoading = false
            }
        }
        do {
            for _ in 0..<4 {
                let page = try await ShortVideoAPI.feed(start: start, cursor: cursor)
                guard gen == generation else { return }
                cursor = page.next
                exhausted = page.next == nil
                if append(page.items) > 0 || exhausted { return }
            }
            if !items.isEmpty { ToastCenter.shared.show("暂时没有更多短视频了") }
        } catch {
            guard gen == generation, !ListMapping.isCancellation(error) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? "加载失败"
            errorText = message
            // The placeholder only shows while nothing is loaded; past that, say it here.
            if !items.isEmpty { ToastCenter.shared.show("加载更多失败：\(message)") }
        }
    }

    /// Adds the videos not shown yet and returns how many. The entry video, shown before page 1,
    /// takes the feed's fuller copy (counts, uploader) in place.
    private func append(_ page: [ShortVideoItem]) -> Int {
        var known = Set(items.map(\.id))
        var fresh: [ShortVideoItem] = []
        for item in page {
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                if i == 0, item.id == start?.id {
                    items[0] = item
                    socials[item.id]?.update(from: item)
                }
                continue
            }
            guard !known.contains(item.id), !portraitOnly || item.isPortrait else { continue }
            known.insert(item.id)
            fresh.append(item)
        }
        items.append(contentsOf: fresh)
        // Prepares the new next video when the one on screen was the last.
        if !fresh.isEmpty { activate() }
        return fresh.count
    }

    /// Tap to pause / resume the video on screen.
    func togglePlay(_ item: ShortVideoItem) {
        guard let playback = playbacks[item.id] else { return }
        if playback.isPaused {
            userPaused = false
            playback.play()
        } else {
            userPaused = true
            playback.pause()
        }
    }

    /// 「只看竖屏」 on drops the landscape videos ahead (the one on screen stays); off affects later pages.
    func setPortraitOnly(_ on: Bool) {
        portraitOnly = on
        AppSettings.shared.general.shortVideoOnlyPortrait = on
        guard on else { return }
        items = items.enumerated().filter { $0.offset <= index || $0.element.isPortrait }.map(\.element)
        activate()
    }

    // MARK: Players

    /// The player for an item on screen (created on demand; only the current video and its
    /// neighbours keep theirs).
    func playback(for item: ShortVideoItem) -> ShortVideoPlayback {
        if let existing = playbacks[item.id] { return existing }
        let made = ShortVideoPlayback(item: item)
        playbacks[item.id] = made
        return made
    }

    func social(for item: ShortVideoItem) -> ShortVideoSocial {
        if let existing = socials[item.id] { return existing }
        let made = ShortVideoSocial(item: item)
        socials[item.id] = made
        return made
    }

    func setVisible(_ isVisible: Bool) {
        visible = isVisible
        PlayerNowPlayingCenter.shared.shortVideosVisible = isVisible
        if !isVisible { reportCurrentHistory() }
        activate()
    }

    private func setAppActive(_ active: Bool) {
        appActive = active
        if !active { reportCurrentHistory() }
        activate()
    }

    /// Leaving the screen or the app counts as having watched the video on screen (re-reported, further
    /// along, when watching goes on).
    private func reportCurrentHistory() {
        if let current { playbacks[current.id]?.reportHistoryIfNeeded() }
    }

    /// Plays the current video (when it can be seen), prepares the next, pauses the previous,
    /// releases the rest, and asks for more videos near the end. At most three engine sessions stay
    /// open (the engine keeps four), and only the current one while another page covers the feed.
    private func activate() {
        guard let current else { return }
        let range = visible ? (index - 1...index + 1) : (index...index)
        let window = Set(range.filter { items.indices.contains($0) }.map { items[$0].id })
        for (id, playback) in playbacks where !window.contains(id) {
            playback.close()
            playbacks[id] = nil
        }
        for id in socials.keys where !window.contains(id) && id != current.id { socials[id] = nil }

        if visible, items.indices.contains(index - 1), let previous = playbacks[items[index - 1].id] {
            previous.pause()
            previous.reportHistoryIfNeeded()
        }
        if visible, items.indices.contains(index + 1) {
            let next = playback(for: items[index + 1])
            next.pause()
            next.prepare()
        }
        let now = playback(for: current)
        if visible && appActive && !userPaused {
            if now.isPaused { now.play() }
        } else {
            now.pause()
            now.prepare()
        }
        Task { await social(for: current).loadRelationIfNeeded() }
        Task { await social(for: current).loadFansIfNeeded(mid: current.ownerMid) }
        loadOnlineIfNeeded(current)
        if index >= items.count - 3 {
            Task { await loadMore() }
        }
    }

    /// Asked once per video.
    private func loadOnlineIfNeeded(_ item: ShortVideoItem) {
        guard onlineItemID != item.id else { return }
        onlineItemID = item.id
        onlineText = nil
        onlineTask?.cancel()
        onlineTask = Task { [weak self] in
            var cid = item.cid
            if cid == 0 { cid = (try? await VideoAPI.detail(item.videoRef).cid) ?? 0 }
            guard cid != 0, let text = try? await VideoAPI.onlineCount(aid: item.aid, cid: cid, bvid: item.bvid),
                  !Task.isCancelled else { return }
            self?.onlineText = "\(text)人正在看"
        }
    }

    func closeAll() {
        for playback in playbacks.values { playback.close() }
        playbacks = [:]
        socials = [:]
    }

    /// 不感兴趣: tells the feed (TV login only) and skips to the next video.
    func dislike(_ item: ShortVideoItem, reason: FeedDislikeReason) async {
        guard let feedback = item.feedback else { return }
        do {
            try await FeedAPI.dislike(feedback, reason: reason)
            VideoCardActions.showDisliked(feedback, reason: reason)
            if let i = items.firstIndex(where: { $0.id == item.id }), i == index, i + 1 < items.count {
                index = i + 1
            }
        } catch {
            ToastCenter.shared.show((error as? LocalizedError)?.errorDescription ?? "操作失败")
        }
    }
}

/// Like / coin / favourite / follow state of one item, loaded when it comes on screen.
@MainActor
final class ShortVideoSocial: ObservableObject {
    let item: ShortVideoItem
    @Published var liked = false
    @Published var coins = 0
    @Published var favored = false
    @Published var following: Bool
    @Published var likeCount: Int64
    @Published var coinCount: Int64
    @Published var favoriteCount: Int64
    @Published private(set) var ownerFans: Int64 = 0
    private var loaded = false
    private var fansLoaded = false
    private var busy = false

    init(item: ShortVideoItem) {
        self.item = item
        following = item.isFollowing
        likeCount = item.likeCount
        coinCount = item.coinCount
        favoriteCount = item.favoriteCount
    }

    func loadRelationIfNeeded() async {
        guard !loaded, BiliHTTP.shared.isLoggedIn else { return }
        loaded = true
        guard let relation = try? await VideoAPI.relation(aid: item.aid, bvid: item.bvid) else {
            loaded = false
            return
        }
        liked = relation.liked
        coins = relation.coinCount
        favored = relation.favored
        following = relation.followingUp
    }

    /// The 粉丝 under the uploader's name. `mid`: the entry card's copy of the item may not have had it.
    func loadFansIfNeeded(mid: Int64) async {
        guard !fansLoaded, mid > 0 else { return }
        fansLoaded = true
        guard let data = try? await BiliHTTP.shared.api(BiliHost.api + "/x/web-interface/card", query: ["mid": mid]) else {
            fansLoaded = false
            return
        }
        ownerFans = data["follower"].int64 ?? data[path: "card.fans"].int64Value
    }

    /// Like or undo; `onlyLike` (double tap) never undoes.
    func toggleLike(onlyLike: Bool = false) async {
        guard ShortVideoSocial.requireLogin("点赞"), !busy else { return }
        if onlyLike && liked { return }
        let target = !liked
        busy = true
        defer { busy = false }
        liked = target
        likeCount = max(0, likeCount + (target ? 1 : -1))
        do {
            try await VideoAPI.like(aid: item.aid, like: target)
        } catch {
            liked = !target
            likeCount = max(0, likeCount + (target ? -1 : 1))
            ShortVideoSocial.showError(error)
        }
    }

    /// 一键三连: a long press on 点赞. `maxCoins`: the entry card's copy of the item does not say it.
    func triple(maxCoins: Int) async {
        guard ShortVideoSocial.requireLogin("三连"), !busy else { return }
        if liked && coins >= maxCoins && favored {
            ToastCenter.shared.show("已完成三连")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await VideoAPI.triple(aid: item.aid, bvid: item.bvid)
            if result.like && !liked {
                liked = true
                likeCount += 1
            }
            if result.coin && coins < maxCoins {
                coinCount += Int64(maxCoins - coins)
                coins = maxCoins
            }
            if result.fav && !favored {
                favored = true
                favoriteCount += 1
            }
            ToastCenter.shared.show(result.coin || coins >= maxCoins ? "三连成功" : "投币失败")
        } catch {
            ShortVideoSocial.showError(error)
        }
    }

    func coin(_ count: Int, alsoLike: Bool) async {
        guard ShortVideoSocial.requireLogin("投币") else { return }
        do {
            let likedToo = try await VideoAPI.coin(aid: item.aid, count: count, alsoLike: alsoLike)
            coins += count
            coinCount += Int64(count)
            if likedToo && !liked {
                liked = true
                likeCount += 1
            }
            ToastCenter.shared.show("投币成功")
        } catch {
            ShortVideoSocial.showError(error)
        }
    }

    func favoriteChanged(_ isFavored: Bool) {
        if isFavored != favored { favoriteCount = max(0, favoriteCount + (isFavored ? 1 : -1)) }
        favored = isFavored
    }

    /// The entry card's copy (shown before page 1) lacks counts the feed's own copy has.
    func update(from fuller: ShortVideoItem) {
        likeCount = max(likeCount, fuller.likeCount)
        coinCount = max(coinCount, fuller.coinCount)
        favoriteCount = max(favoriteCount, fuller.favoriteCount)
        if !loaded { following = fuller.isFollowing }
    }

    /// 「快速收藏」: into the default folder, or out of every folder, without the picker (as on the video page).
    func quickFavorite() async {
        guard ShortVideoSocial.requireLogin("收藏"), !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let folders = try await VideoAPI.favFolders(forAid: item.aid)
            let current = folders.filter(\.isFavorited).map(\.id)
            if current.isEmpty {
                guard let target = folders.first(where: \.isDefault) ?? folders.first else {
                    throw BiliError.other("还没有收藏夹")
                }
                try await VideoAPI.updateFav(aid: item.aid, add: [target.id], remove: [])
                favoriteChanged(true)
                ToastCenter.shared.show("已收藏到「\(target.title)」")
            } else {
                try await VideoAPI.updateFav(aid: item.aid, add: [], remove: current)
                favoriteChanged(false)
                ToastCenter.shared.show("已取消收藏")
            }
        } catch {
            ShortVideoSocial.showError(error)
        }
    }

    func follow() async {
        guard ShortVideoSocial.requireLogin("关注"), item.ownerMid != 0, !following else { return }
        following = true
        do {
            try await SpaceAPI.follow(mid: item.ownerMid)
            ToastCenter.shared.show("已关注")
        } catch {
            following = false
            ShortVideoSocial.showError(error)
        }
    }

    func addToWatchLater() async {
        guard ShortVideoSocial.requireLogin("稍后再看") else { return }
        do {
            try await WatchLaterAPI.add(aid: item.aid)
            ToastCenter.shared.show("已添加到稍后再看")
        } catch {
            ShortVideoSocial.showError(error)
        }
    }

    static func requireLogin(_ action: String) -> Bool {
        if BiliHTTP.shared.isLoggedIn { return true }
        ToastCenter.shared.show("登录后才能\(action)")
        return false
    }

    static func showError(_ error: Error) {
        if ListMapping.isCancellation(error) { return }
        ToastCenter.shared.show((error as? LocalizedError)?.errorDescription ?? "操作失败")
    }
}
