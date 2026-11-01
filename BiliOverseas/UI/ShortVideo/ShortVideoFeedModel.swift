import Combine
import SwiftUI

/// State of the 短视频 feed: the videos loaded so far, the one on screen, and its players. The current
/// video plays while the screen is visible and the app is active; the next one is prepared so a swipe
/// starts at once; the previous one keeps its player for a quick swipe back. Those further away, five each
/// way, hold only their streams, and others are released.
@MainActor
final class ShortVideoFeedModel: ObservableObject {
    @Published private(set) var items: [ShortVideoItem] = []
    @Published var index = 0 {
        didSet {
            guard index != oldValue else { return }
            userPaused = false
            landing.isSpeeding = false
            activate()
            let kept = playbacks.values
            PlaybackTrace.log("feed at \(current?.id ?? "?") kept=\(kept.count) keptMB=\(kept.reduce(0) { $0 + $1.cachedBytes } / 1_000_000)")
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// 「只看竖屏」: landscape videos are skipped.
    @Published private(set) var portraitOnly = AppSettings.shared.general.swipesOnlyPortrait
    /// 「N人正在看」 of the video on screen.
    @Published private(set) var onlineText: String?
    /// Where a swipe is coming to rest. An object of its own (`ShortVideoLanding`).
    let landing = ShortVideoLanding()

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
    /// The page a swipe coming to rest started ahead of `index` (`setLanding`).
    private var landingStarted: Int?
    /// Bumped by 换一批 so a page still loading for the old feed is dropped.
    private var generation = 0
    private var loadingGeneration: Int?
    private var onlineItemID: String?
    private var onlineTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// 全屏 of a landscape video (`ShortVideoLandscapeView`).
    private let landscapePresenter = PlayerFullscreenPresenter()
    private var isLandscape = false
    /// Where the videos ahead come from; another source replaces them.
    private var source = ShortVideoAPI.source(chosen: AppSettings.shared.general.swipeFeedSource)
    private var landscapePlayback: ShortVideoPlayback?
    /// What the page last said about itself, which while 全屏 covers it does not count until that has gone.
    private var pageVisible = false
    /// How far streams are kept each way. Less once the system said it is short of memory.
    private var streamReach = PlayerStreamPreload.swipeWindow
    /// The video whose page was last opened from here, which goes on from where it gets to there.
    private var wentToPage: (id: String, goingOn: VideoGoingOn)?

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
        center.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                self?.streamReach = 1
                self?.activate()
            }
            .store(in: &cancellables)
        // `@Published` emits before the value is stored: hop once so the players read the new settings.
        AppSettings.shared.$acceleration
            .map { [$0.enabled, $0.verticalVideosDirect] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.playbacks.values.forEach { $0.accelerationChanged() }
                    self?.activate()
                }
            }
            .store(in: &cancellables)
    }

    var current: ShortVideoItem? { items.indices.contains(index) ? items[index] : nil }

    /// What the bars around the pages act on: while a swipe comes to rest, the video it comes to, not the one leaving.
    var showing: ShortVideoItem? {
        if let landing = landing.index, items.indices.contains(landing) { return items[landing] }
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
                let page = try await ShortVideoAPI.feed(start: start, cursor: cursor, source: source)
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
        // Prepares the new next video when the one on screen was the last. A swipe coming to rest does that when it
        // lands: with the index still on the page it leaves, this would turn its early start around.
        if !fresh.isEmpty, landingStarted == nil { activate() }
        return fresh.count
    }

    /// A swipe is coming to rest on `page`: that video starts now, not when the page stands still. nil: where it lands
    /// is open again (a finger caught the page), or it has landed.
    func setLanding(_ page: Int?) {
        landing.index = page
        if let page, page != index, visible, appActive, items.indices.contains(page), let current {
            landingStarted = page
            playbacks[current.id]?.standBy()
            playback(for: items[page]).play()
        } else if let started = landingStarted {
            landingStarted = nil
            guard started != index else { return }
            if items.indices.contains(started) { playbacks[items[started].id]?.standBy() }
            activate()
        }
    }

    /// 长按倍速 on the video on screen. The bars around the pages step aside for as long as it lasts.
    func setFastForward(_ on: Bool, item: ShortVideoItem) {
        playbacks[item.id]?.setFastForward(on)
        landing.isSpeeding = on
    }

    /// Tap to pause / resume the video on screen.
    func togglePlay(_ item: ShortVideoItem) {
        // The tap waited to see if it was a double tap, and a swipe has left this video since.
        guard item.id == showing?.id, let playback = playbacks[item.id] else { return }
        if playback.isPaused {
            userPaused = false
            playback.play()
        } else {
            userPaused = true
            playback.pause()
        }
    }

    /// The videos ahead go, the one on screen stays, and the new source's come after it.
    func sourceMayHaveChanged() {
        let now = ShortVideoAPI.source(chosen: AppSettings.shared.general.swipeFeedSource)
        guard now != source else { return }
        source = now
        generation += 1
        cursor = nil
        exhausted = false
        items = Array(items.prefix(index + 1))
        activate()
        Task { await loadMore() }
    }

    /// 「只看竖屏」 on drops the landscape videos ahead (the one on screen stays); off affects later pages.
    func setPortraitOnly(_ on: Bool) {
        portraitOnly = on
        AppSettings.shared.general.swipesOnlyPortrait = on
        if on {
            items = items.enumerated().filter { $0.offset <= index || $0.element.isPortrait }.map(\.element)
            activate()
        }
        // Without a source chosen, this can change it.
        sourceMayHaveChanged()
        // A feed it had emptied, with nothing on screen to ask for more.
        if !on, items.isEmpty, !isLoading { Task { await loadMore() } }
    }

    // MARK: 全屏

    /// The landscape video on screen, turned with the phone: the same player and danmaku, so it just goes on.
    func showLandscape() {
        guard !isLandscape, let item = showing else { return }
        let playback = playback(for: item)
        isLandscape = true
        landscapePlayback = playback
        playback.danmakuInLandscape = true
        let screen = ShortVideoLandscapeView(playback: playback, title: item.title,
                                             onTogglePlay: { [weak self] in self?.togglePlay(item) },
                                             onBack: { [weak self] in self?.closeLandscape() })
        if !landscapePresenter.present(screen, mask: .landscape, orientation: .landscapeRight, onShown: {}) {
            isLandscape = false
            landscapePlayback = nil
            playback.danmakuInLandscape = false
        }
    }

    /// Also when a page was pushed under it (a link from outside): that page shows once this has gone.
    func closeLandscape() {
        guard isLandscape, let playback = landscapePlayback else { return }
        landscapePlayback = nil
        landscapePresenter.dismiss(releasingSurface: {}) { [weak self] in
            self?.isLandscape = false
            playback.danmakuInLandscape = false
            playback.danmakuHost?.claim(playback.danmaku)
            // A page back on top has said so by now, on the way here.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.pageVisible else { return }
                self.setVisible(false)
            }
        }
    }

    // MARK: 详情页

    /// The video's page, which goes on from where the video is here.
    func pageRef(for item: ShortVideoItem) -> VideoRef {
        let playback = playback(for: item)
        var ref = item.videoRef
        ref.cid = playback.resolvedCid ?? item.cid
        ref.startTime = playback.position
        let goingOn = VideoGoingOn(aid: item.aid, cid: ref.cid)
        ref.goingOn = goingOn
        wentToPage = (item.id, goingOn)
        return ref
    }

    /// That page has gone.
    private func goOnFromPage() {
        guard let wentToPage else { return }
        self.wentToPage = nil
        guard let time = wentToPage.goingOn.time, let playback = playbacks[wentToPage.id],
              abs(time - playback.position) >= 1 else { return }
        playback.seek(to: time)
    }

    // MARK: Players

    /// The player for an item on screen (created on demand; only the current video and its
    /// neighbours keep theirs).
    func playback(for item: ShortVideoItem) -> ShortVideoPlayback {
        if let existing = playbacks[item.id] { return existing }
        let made = ShortVideoPlayback(item: item)
        made.onStreamFetched = { [weak self] in self?.fetchStreamsAround() }
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
        pageVisible = isVisible
        // The fullscreen presentation covers this page, and the video goes on there.
        if !isVisible, isLandscape { return }
        // 「只看竖屏」 and the source can be changed from the video's page too, and a login changes the source.
        if isVisible, portraitOnly != AppSettings.shared.general.swipesOnlyPortrait {
            setPortraitOnly(AppSettings.shared.general.swipesOnlyPortrait)
        }
        if isVisible {
            sourceMayHaveChanged()
            goOnFromPage()
        }
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

    /// Plays the current video (when it can be seen), prepares its neighbours, pauses the previous, holds
    /// the streams further away, releases the rest, and asks for more videos near the end. Only the current
    /// one stays open while another page covers the feed.
    private func activate() {
        guard let current else { return }
        func ids(within reach: Int) -> Set<String> {
            Set((index - reach...index + reach).filter { items.indices.contains($0) }.map { items[$0].id })
        }
        let near = ids(within: visible ? 1 : 0)
        let window = visible ? ids(within: streamReach) : near
        for (id, playback) in playbacks where !window.contains(id) {
            playback.close()
            playbacks[id] = nil
        }
        for (id, playback) in playbacks where !near.contains(id) { playback.keepStreamOnly() }
        for id in socials.keys where !near.contains(id) && id != current.id { socials[id] = nil }

        // None yet after another page covered the feed.
        let before = items.indices.contains(index - 1) ? items[index - 1] : nil
        let previous = visible ? before.flatMap { streamReach >= 2 ? playback(for: $0) : playbacks[$0.id] } : nil
        previous?.standBy()
        previous?.reportHistoryIfNeeded()
        let now = playback(for: current)
        if visible && appActive && !userPaused {
            if now.isPaused { now.play() }
        } else {
            // What the viewer did not pause shows no sign of it, while a swipe back brings this into view.
            if userPaused { now.pause() } else { now.standBy() }
            now.prepare()
        }
        let next = visible && items.indices.contains(index + 1) ? playback(for: items[index + 1]) : nil
        next?.standBy()
        // Once the video on screen has started: until then they would share the connection.
        now.whenStarted { [weak self, weak previous, weak next] in
            guard let self else { return }
            for neighbour in [next, previous].compactMap({ $0 }) where self.playbacks[neighbour.item.id] === neighbour {
                neighbour.prepare()
            }
            self.fetchStreamsAround()
        }
        Task { await social(for: current).loadRelationIfNeeded() }
        Task { await social(for: current).loadFansIfNeeded(mid: current.ownerMid) }
        loadOnlineIfNeeded(current)
        // Enough for the streams kept ahead, and a little more.
        if index >= items.count - (streamReach + 2) {
            Task { await loadMore() }
        }
    }

    /// The videos further away get their streams, nearest first and a couple at a time, once this one has started.
    private func fetchStreamsAround() {
        // While a swipe lands the video it comes to is what is starting, not the one `index` still says.
        guard visible, appActive, streamReach >= 2, landingStarted == nil || landingStarted == index, let current,
              playbacks[current.id]?.isOutOfTheWay == true else { return }
        playbacks[current.id]?.markInUse()
        var fetching = playbacks.values.filter(\.isFetchingStream).count
        for distance in 2...streamReach {
            for page in [index + distance, index - distance] where fetching < 2 && items.indices.contains(page) {
                if playback(for: items[page]).fetchStream() { fetching += 1 }
            }
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

/// The page a swipe is coming to rest on (nil: none is), ahead of the model's `index`, which follows once it has stopped.
/// Apart from the model: a render in the middle of the swipe's deceleration would rebuild the visible pages for nothing.
@MainActor
final class ShortVideoLanding: ObservableObject {
    @Published var index: Int?
    /// 长按倍速 is on: the bars step aside like the page's own controls (the danmaku stay).
    @Published var isSpeeding = false
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
