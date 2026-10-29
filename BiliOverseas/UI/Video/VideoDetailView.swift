import SwiftUI
import UIKit

// MARK: - Page

/// Which page of the detail screen is visible.
enum VideoDetailTab: Hashable {
    case intro, comments
}

/// 视频详情页 (UGC archives and PGC episodes). Official-app layout: the player is pinned at the top
/// (navigation bar and tab bar hidden, back button overlaid), then a 简介 | 评论 strip with swipeable pages.
struct VideoDetailView: View {
    @StateObject private var model: VideoDetailModel
    @StateObject private var player = PlayerController()
    /// Stops the player when SwiftUI drops this page's state (see `VideoDetailPageLifetime`).
    @StateObject private var lifetime = VideoDetailPageLifetime()
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var tab: VideoDetailTab = .intro
    /// Navigation depth when this page first appeared (to tell "popped" from "covered").
    @State private var stackDepth: Int?
    /// Paused because another page was pushed on top / a full-screen cover appeared.
    @State private var resumeOnAppear = false

    init(ref: VideoRef) {
        _model = StateObject(wrappedValue: VideoDetailModel(ref: ref))
    }

    var body: some View {
        GeometryReader { geo in
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            VStack(spacing: 0) {
                playerArea(width: geo.size.width, height: playerHeight(width: geo.size.width, fullHeight: fullHeight))
                pageContent
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background(VideoDetailPopGestureEnabler().frame(width: 0, height: 0))
        .background(VideoCommentComposerHost(model: model.comments))
        .onAppear {
            if stackDepth == nil { stackDepth = router.path.count }
            if lifetime.onRelease == nil {
                let pageModel = model, pagePlayer = player
                lifetime.onRelease = {
                    Task { @MainActor in
                        pageModel.pageClosed()
                        pagePlayer.stop()
                    }
                }
            }
            model.pageAppeared()
            model.attach(player)
            model.startIfNeeded()
            if resumeOnAppear {
                resumeOnAppear = false
                player.play()
            }
        }
        .onDisappear {
            // The player's own fullscreen presentation can hide this page; never touch playback then.
            if player.isFullscreen { return }
            if let depth = stackDepth, router.path.count < depth {
                model.pageClosed()
                player.stop()
                return
            }
            // Covered by a pushed page / tab switch — or a swipe-back whose path update lands after this call
            // (`lifetime` stops the player once the page's state is released).
            // Picture in Picture keeps playing while the user browses elsewhere.
            if player.isPiPActive { return }
            model.pageCovered()
            // `wantsToPlay` (not only `.playing`): a page covered while its video is still starting would
            // otherwise begin playing behind the new page.
            if player.wantsToPlay {
                resumeOnAppear = true
                player.pause()
            }
        }
    }

    // MARK: Player area

    /// 16:9 for horizontal videos; vertical videos get `max(longestSide × 0.65, shortestSide)`. Both are capped at
    /// 65 % of the screen height: a landscape iPad would otherwise give a 16:9 player all but ~110 pt of it
    /// (the video is letterboxed inside the shorter area).
    private func playerHeight(width: CGFloat, fullHeight: CGFloat) -> CGFloat {
        let horizontal = (width * 9 / 16).rounded()
        guard fullHeight > 0 else { return horizontal }
        let cap = (fullHeight * 0.65).rounded()
        guard model.isVerticalVideo else { return min(horizontal, cap) }
        let shortest = min(width, fullHeight)
        let longest = max(width, fullHeight)
        let vertical = min(max(longest * 0.65, shortest), fullHeight * 0.65)
        return min(max(horizontal, vertical.rounded()), cap)
    }

    private var statusBarBackground: Color {
        colorScheme == .dark ? .black : Color(.systemBackground)
    }

    private func playerArea(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            PlayerContainerView(controller: player)
            if player.item == nil {
                playerPlaceholder
            }
            if !player.isFullscreen {
                backButton
            }
        }
        .frame(width: width, height: height)
        .background(statusBarBackground.ignoresSafeArea(edges: .top))
        .animation(.easeInOut(duration: 0.25), value: model.isVerticalVideo)
    }

    private var playerPlaceholder: some View {
        ZStack {
            if !model.coverURL.isEmpty {
                RemoteImage(url: model.coverURL, width: 480)
                    .opacity(0.45)
            }
            switch model.phase {
            case .loading:
                ProgressView().tint(.white)
            case .failed:
                Image(systemName: model.isRegionLocked ? "globe" : "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
            case .loaded:
                EmptyView()
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.3), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.top, 6)
        .accessibilityLabel("返回")
    }

    // MARK: Content

    @ViewBuilder
    private var pageContent: some View {
        if case .failed(let message) = model.phase {
            VStack(spacing: 0) {
                StateMessageView(
                    systemImage: model.isRegionLocked ? "globe" : "exclamationmark.triangle",
                    message: message,
                    retry: { model.retry() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                VideoDetailTabStrip(comments: model.comments, fallbackCount: model.counts.reply, tab: $tab) {
                    openRootComposer()
                }
                Divider()
                TabView(selection: $tab) {
                    VideoIntroView(model: model, onSeek: { player.seek(to: $0) })
                        .tag(VideoDetailTab.intro)
                    VideoCommentsListView(model: model.comments, hostsComposer: false, showsComposerBar: false,
                                          onSeek: { player.seek(to: $0) })
                        .id(ObjectIdentifier(model.comments))
                        .tag(VideoDetailTab.comments)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    private func openRootComposer() {
        guard BiliHTTP.shared.isLoggedIn else {
            router.push(.login)
            return
        }
        guard model.comments.oid > 0 else { return }
        if model.comments.inputDisabled {
            ToastCenter.shared.show("评论区已关闭")
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { tab = .comments }
        model.comments.composerTarget = VideoCommentComposerTarget()
    }
}

/// 简介 | 评论 N strip with the 「发个友善的评论吧」 fake input on the right.
struct VideoDetailTabStrip: View {
    @ObservedObject var comments: VideoCommentsModel
    let fallbackCount: Int64
    @Binding var tab: VideoDetailTab
    let onCompose: () -> Void

    private var commentCount: Int64 {
        comments.totalCount > 0 ? Int64(comments.totalCount) : fallbackCount
    }

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.intro, title: "简介", badge: nil)
            tabButton(.comments, title: "评论", badge: commentCount > 0 ? Fmt.count(commentCount) : nil)
            Spacer(minLength: 8)
            Button(action: onCompose) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                    Text(comments.inputDisabled ? "评论区已关闭" : "发个友善的评论吧")
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(comments.oid == 0)
        }
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .frame(height: 42)
    }

    private func tabButton(_ value: VideoDetailTab, title: String, badge: String?) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { tab = value }
        } label: {
            VStack(spacing: 5) {
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    if let badge {
                        Text(badge).font(.system(size: 11))
                    }
                }
                .foregroundColor(selected ? .biliPink : .secondary)
                Capsule()
                    .fill(selected ? Color.biliPink : Color.clear)
                    .frame(width: 22, height: 2.5)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model

/// State of one detail page: UGC detail or PGC season, the selected part / episode, interaction state,
/// tags, related videos, online count and the comments model. Drives `PlayerController`.
@MainActor
final class VideoDetailModel: ObservableObject {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    /// Displayed counters (adjusted locally after like / coin / favourite).
    struct Counts: Equatable {
        var view: Int64 = 0
        var danmaku: Int64 = 0
        var like: Int64 = 0
        var coin: Int64 = 0
        var favorite: Int64 = 0
        var share: Int64 = 0
        var reply: Int64 = 0
    }

    enum Action: Hashable {
        case like, dislike, coin, triple, favorite, watchLater, follow, seasonFollow
    }

    enum Content {
        case ugc(VideoDetail)
        case pgc(PGCSeason, PGCEpisode)
    }

    @Published private(set) var ref: VideoRef
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isRegionLocked = false
    /// Loading another video in place (auto-next, 合集 episode) while the old content stays visible.
    @Published private(set) var isSwitching = false
    /// Changes whenever the page content is replaced (resets the intro scroll position).
    @Published private(set) var contentID = 0

    @Published private(set) var detail: VideoDetail?
    @Published private(set) var season: PGCSeason?
    @Published private(set) var currentCid: Int64 = 0
    @Published private(set) var currentEpisode: PGCEpisode?

    @Published private(set) var counts = Counts()
    @Published private(set) var relation = VideoRelation()
    @Published private(set) var addedToWatchLater = false
    @Published private(set) var busy: Set<Action> = []

    @Published private(set) var tags: [String] = []
    @Published private(set) var related: [VideoCard] = []
    @Published private(set) var relatedLoaded = false
    /// e.g. "1000+" (shown as "1000+人在看").
    @Published private(set) var onlineText: String?

    @Published private(set) var ownerFans: Int64 = 0
    @Published private(set) var ownerArchiveCount: Int64 = 0
    @Published private(set) var ownerIsVip = false
    @Published private(set) var isFollowingOwner = false
    /// The uploader's detailed relation (`/x/relation`: 已互关 / 特别关注 / 已拉黑 …); nil until loaded.
    @Published private(set) var ownerRelation: UserRelationState?
    @Published private(set) var followedStaff: Set<Int64> = []
    @Published private(set) var isFollowingSeason = false

    @Published private(set) var comments: VideoCommentsModel

    private weak var player: PlayerController?
    private var pendingItem: PlaybackItem?
    private var started = false
    /// Another page covers this one: new items wait in `pendingItem` so a hidden page never starts playing.
    private var isCovered = false
    /// Login state the relation / follow data was loaded with (reloaded on appear after a login / logout).
    private var sideDataLoggedIn = false
    /// Bumped by every local like / coin / favourite change: a relation response requested earlier is stale.
    private var relationEdits = 0
    /// Archives played on this page (auto-next skips them in 相关推荐 so A → B → A loops do not happen).
    private var playedAids: Set<Int64> = []
    /// 播放全部 list this page was opened with (稍后再看 / 收藏夹); kept across in-place switches.
    private let playlist: VideoPlaylist?
    /// Bumped by every content load; stale responses are dropped.
    private var generation = 0
    /// Bumped by every content / part / episode change; stale side data is dropped.
    private var sideGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var sideTasks: [Task<Void, Never>] = []
    private var onlineTask: Task<Void, Never>?

    init(ref: VideoRef) {
        self.ref = ref
        let aid = ref.aid > 0 ? ref.aid : (BVConverter.bv2av(ref.bvid) ?? 0)
        comments = VideoCommentsModel(oid: ref.isPGC ? 0 : aid, type: 1)
        playlist = ref.playlist
    }

    // MARK: Derived state

    var isPGC: Bool { season != nil }
    var hasContent: Bool { detail != nil || season != nil }

    var title: String { season?.title ?? detail?.title ?? ref.title }

    var coverURL: String {
        if let ep = currentEpisode, !ep.cover.isEmpty { return ep.cover }
        if let s = season { return s.cover }
        if let d = detail { return d.cover }
        return ref.cover
    }

    /// aid used for like / coin / watch later / comments (PGC: the episode's aid).
    var interactionAid: Int64 { currentEpisode?.aid ?? detail?.aid ?? 0 }

    /// Favourite resource: `aid:2` for UGC, `ep_id:24` for PGC.
    var favoriteResource: (rid: Int64, type: Int) {
        if let ep = currentEpisode, season != nil { return (ep.epId, 24) }
        return (detail?.aid ?? 0, 2)
    }

    /// 2 for original works, 1 for reposts.
    var maxCoins: Int { detail?.maxCoins ?? 2 }

    var ownerMid: Int64 { detail?.owner.mid ?? 0 }

    var currentPart: VideoPart? { detail?.pages.first(where: { $0.cid == currentCid }) }

    var isVerticalVideo: Bool {
        if let ep = currentEpisode, season != nil {
            return VideoDetailModel.isVertical(width: ep.width, height: ep.height, rotate: ep.rotate)
        }
        guard let d = detail else { return false }
        if let p = currentPart, p.width > 0, p.height > 0 { return p.isVertical }
        return d.isVertical
    }

    var shareURL: URL? {
        if let ep = currentEpisode, season != nil {
            return URL(string: "https://www.bilibili.com/bangumi/play/ep\(ep.epId)")
        }
        guard let d = detail, !d.bvid.isEmpty else { return nil }
        if d.pages.count > 1, let p = currentPart, p.page > 1 {
            return URL(string: "https://www.bilibili.com/video/\(d.bvid)?p=\(p.page)")
        }
        return URL(string: "https://www.bilibili.com/video/\(d.bvid)")
    }

    func isFollowing(_ mid: Int64) -> Bool {
        mid == ownerMid ? isFollowingOwner : followedStaff.contains(mid)
    }

    /// What the follow button shows for `mid`: the uploader's detailed relation once `/x/relation` answered,
    /// otherwise 已关注 / 关注.
    func relationState(for mid: Int64) -> UserRelationState {
        let following = isFollowing(mid)
        if mid == ownerMid, let r = ownerRelation, r.isFollowing == following { return r }
        return following ? .followed : .notFollowing
    }

    static func isVertical(width: Int, height: Int, rotate: Int) -> Bool {
        let (w, h) = rotate == 1 ? (height, width) : (width, height)
        return h > w
    }

    // MARK: Lifecycle

    func attach(_ player: PlayerController) {
        self.player = player
        player.onEnded = { [weak self] in
            Task { @MainActor in self?.advance(manual: false) }
        }
        connectPlayerPage(player)
        refreshNextAvailability()
        if let item = pendingItem, !isCovered {
            pendingItem = nil
            player.load(item)
        }
    }

    /// The page is visible again (first appearance, back from a pushed page / another tab).
    func pageAppeared() {
        isCovered = false
        if hasContent, BiliHTTP.shared.isLoggedIn != sideDataLoggedIn {
            reloadAccountState()
        }
    }

    /// Another page was pushed on top (or another tab was selected).
    func pageCovered() {
        isCovered = true
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        load(ref, inPlace: false)
    }

    func retry() {
        load(ref, inPlace: false)
    }

    /// Replaces the page content with another video (auto-next, 合集 episodes, other seasons).
    func replace(with newRef: VideoRef) {
        load(newRef, inPlace: true)
    }

    /// The page was popped: stop background work.
    func pageClosed() {
        loadTask?.cancel()
        cancelSideTasks()
    }

    /// The user picked a part / episode of the shown content: an in-place switch still loading (auto-next,
    /// 合集 episode) must not replace the page afterwards.
    private func cancelPendingSwitch() {
        guard isSwitching else { return }
        loadTask?.cancel()
        generation += 1
        isSwitching = false
    }

    private func load(_ target: VideoRef, inPlace: Bool) {
        loadTask?.cancel()
        generation += 1
        let gen = generation
        if inPlace && hasContent {
            isSwitching = true
        } else {
            phase = .loading
            isRegionLocked = false
        }
        loadTask = Task { [weak self] in
            do {
                let content = try await VideoDetailModel.fetch(target)
                guard let self, gen == self.generation else { return }
                self.ref = target
                self.apply(content, target: target)
                self.isSwitching = false
                self.phase = .loaded
            } catch {
                guard let self, gen == self.generation else { return }
                self.isSwitching = false
                if VideoDetailModel.isCancellation(error) { return }
                if inPlace && self.hasContent {
                    ToastCenter.shared.show(error: error)
                } else {
                    let regionLocked = VideoAPI.isRegionLocked(error)
                    self.isRegionLocked = regionLocked
                    self.phase = .failed(VideoDetailModel.message(for: error, regionLocked: regionLocked, pgc: target.isPGC))
                }
            }
        }
    }

    private static func fetch(_ ref: VideoRef) async throws -> Content {
        if ref.isPGC {
            return try await fetchPGC(epId: ref.epId, seasonId: ref.seasonId, aid: ref.aid)
        }
        let detail = try await VideoAPI.detail(ref)
        if detail.isPGCRedirect {
            return try await fetchPGC(epId: detail.redirectEpId, seasonId: detail.redirectSeasonId, aid: detail.aid)
        }
        return .ugc(detail)
    }

    private static func fetchPGC(epId: Int64, seasonId: Int64, aid: Int64) async throws -> Content {
        let season = try await VideoAPI.pgcSeason(seasonId: seasonId > 0 ? seasonId : nil, epId: epId > 0 ? epId : nil)
        var candidate = season.defaultEpisode(preferredEpId: epId)
        if epId == 0, aid > 0, let match = season.allEpisodes.first(where: { $0.aid == aid }) {
            candidate = match
        }
        guard let episode = candidate else { throw BiliError.other("该剧集暂无可播放的内容") }
        return .pgc(season, episode)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? BiliError, case .cancelled = e { return true }
        return false
    }

    private static func message(for error: Error, regionLocked: Bool, pgc: Bool) -> String {
        if regionLocked { return pgc ? "该番剧在当前地区不可播放" : "该视频在当前地区不可观看" }
        if let e = error as? BiliError, case .api(_, let msg) = e, !msg.isEmpty { return msg }
        return error.localizedDescription
    }

    private func apply(_ content: Content, target: VideoRef) {
        cancelSideTasks()
        sideGeneration += 1
        contentID += 1
        relation = VideoRelation()
        addedToWatchLater = false
        tags = []
        related = []
        relatedLoaded = false
        onlineText = nil
        ownerFans = 0
        ownerArchiveCount = 0
        ownerIsVip = false
        isFollowingOwner = false
        ownerRelation = nil
        followedStaff = []

        switch content {
        case .ugc(let d):
            detail = d
            season = nil
            currentEpisode = nil
            playedAids.insert(d.aid)
            let preferred = target.cid != 0 ? d.pages.first(where: { $0.cid == target.cid }) : nil
            currentCid = (preferred ?? d.pages.first)?.cid ?? d.cid
            counts = Counts(view: d.stat.view, danmaku: d.stat.danmaku, like: d.stat.like, coin: d.stat.coin,
                            favorite: d.stat.favorite, share: d.stat.share, reply: d.stat.reply)
            followedStaff = Set(d.staff.filter { $0.user.isFollowed }.map(\.user.mid))
            isFollowingOwner = followedStaff.contains(d.owner.mid)
            tags = d.tags
        case .pgc(let s, let ep):
            detail = nil
            season = s
            currentEpisode = ep
            currentCid = ep.cid
            counts = Counts(view: s.stat.views, danmaku: s.stat.danmakus, like: s.stat.likes, coin: s.stat.coins,
                            favorite: s.stat.favorite, share: s.stat.share, reply: s.stat.reply)
            isFollowingSeason = s.userStatus.follow
        }
        resetCommentsIfNeeded()
        playCurrent(startTime: target.startTime)
        loadSideData()
    }

    private func resetCommentsIfNeeded() {
        let oid = interactionAid
        guard oid != comments.oid else { return }
        comments = VideoCommentsModel(oid: oid, type: 1)
    }

    // MARK: Playback

    private func playCurrent(startTime: Double?) {
        refreshNextAvailability()
        guard let item = makeItem(startTime: startTime) else { return }
        // A content switch that finishes while another page covers this one (auto-next, lock-screen 下一集)
        // is loaded on the next appearance instead of auto-playing behind that page.
        if let player, !isCovered {
            pendingItem = nil
            player.load(item)
        } else {
            pendingItem = item
        }
    }

    private func makeItem(startTime: Double?) -> PlaybackItem? {
        if let s = season, let ep = currentEpisode {
            var item = PlaybackItem(aid: ep.aid, bvid: ep.bvid, cid: ep.cid, title: s.title)
            item.epId = ep.epId
            item.seasonId = s.seasonId
            item.subtitle = ep.displayTitle
            item.cover = ep.cover.isEmpty ? s.cover : ep.cover
            item.ownerName = s.upInfo?.name ?? ""
            item.ownerMid = s.upInfo?.mid ?? 0
            item.duration = Double(ep.duration)
            item.desc = s.evaluate
            item.startTime = startTime
            item.isVertical = VideoDetailModel.isVertical(width: ep.width, height: ep.height, rotate: ep.rotate)
            return item
        }
        guard let d = detail else { return nil }
        let part = currentPart
        let cid = currentCid != 0 ? currentCid : d.cid
        guard cid != 0 else { return nil }
        var item = PlaybackItem(aid: d.aid, bvid: d.bvid, cid: cid, title: d.title)
        if d.pages.count > 1, let p = part {
            item.subtitle = p.part.isEmpty ? "P\(p.page)" : "P\(p.page) \(p.part)"
        }
        item.cover = d.cover
        item.ownerName = d.owner.name
        item.ownerMid = d.owner.mid
        item.duration = Double(part?.duration ?? d.duration)
        item.desc = d.desc
        item.startTime = startTime
        item.isVertical = isVerticalVideo
        return item
    }

    /// `startTime`: e.g. the 「上次看到第N P」 chip's position (nil = the usual resume rules).
    func selectPart(_ part: VideoPart, startTime: Double? = nil) {
        guard part.cid != currentCid else { return }
        cancelPendingSwitch()
        currentCid = part.cid
        sideGeneration += 1
        playCurrent(startTime: startTime)
        startOnlinePolling()
    }

    func selectEpisode(_ episode: PGCEpisode) {
        guard season != nil, episode.epId != currentEpisode?.epId else { return }
        cancelPendingSwitch()
        currentEpisode = episode
        currentCid = episode.cid
        sideGeneration += 1
        relation = VideoRelation()
        resetCommentsIfNeeded()
        playCurrent(startTime: nil)
        let gen = sideGeneration
        spawn { await $0.loadRelation(gen: gen) }
        startOnlinePolling()
    }

    /// A 合集 episode: another part of this archive, or another archive loaded in place.
    func selectSeasonEpisode(_ episode: UgcEpisode) {
        guard let d = detail else { return }
        if episode.aid == d.aid {
            if let p = d.pages.first(where: { $0.cid == episode.cid }) { selectPart(p) }
            return
        }
        replace(with: episode.videoRef)
    }

    func openSeason(_ link: PGCSeason.SeasonLink) {
        guard link.seasonId != season?.seasonId else { return }
        replace(with: VideoRef(seasonId: link.seasonId, title: link.title, cover: link.cover))
    }

    private enum NextStep {
        case part(VideoPart)
        case episode(PGCEpisode)
        case video(VideoRef)
    }

    /// Next: next part → next 播放全部 entry → next 合集 episode → next PGC episode (same list / section) → first
    /// (filtered) related video not played on this page yet. A play-all list replaces the 合集 / episode list.
    private func nextStep(includeRelated: Bool = true) -> NextStep? {
        if let s = season, let ep = currentEpisode {
            switch playlistPosition(aid: ep.aid, bvid: ep.bvid, epId: ep.epId) {
            case .next(let r)?: return .video(r)
            case .pending?, .end?: return nil
            case nil: break
            }
            let list: [PGCEpisode]
            if s.episodes.contains(where: { $0.epId == ep.epId }) {
                list = s.episodes
            } else {
                list = s.sections.first(where: { $0.episodes.contains(where: { $0.epId == ep.epId }) })?.episodes ?? []
            }
            if let i = list.firstIndex(where: { $0.epId == ep.epId }), i + 1 < list.count {
                return .episode(list[i + 1])
            }
            return nil
        }
        guard let d = detail else { return nil }
        if let i = d.pages.firstIndex(where: { $0.cid == currentCid }), i + 1 < d.pages.count {
            return .part(d.pages[i + 1])
        }
        var playlistEnded = false
        switch playlistPosition(aid: d.aid, bvid: d.bvid) {
        case .next(let r)?: return .video(r)
        case .pending?: return nil
        case .end?: playlistEnded = true
        case nil: break
        }
        if !playlistEnded, let ugc = d.ugcSeason {
            let episodes = ugc.allEpisodes
            if let i = episodes.firstIndex(where: { $0.aid == d.aid }), i + 1 < episodes.count {
                return .video(episodes[i + 1].videoRef)
            }
        }
        if includeRelated, let next = related.first(where: { !playedAids.contains($0.aid) }) ?? related.first {
            var r = next.videoRef
            r.startTime = nil
            return .video(r)
        }
        return nil
    }

    private enum PlaylistPosition {
        /// The following entry.
        case next(VideoRef)
        /// Last loaded entry; the next page is still loading (`prefetchPlaylistIfNeeded`).
        case pending
        /// Last entry of the list.
        case end
    }

    /// Where the 播放全部 list goes after the given video; nil without a list or when the video is not in it
    /// (e.g. a related video played after the list ended).
    private func playlistPosition(aid: Int64, bvid: String, epId: Int64 = 0) -> PlaylistPosition? {
        guard let playlist, playlist.index(aid: aid, bvid: bvid, epId: epId) != nil else { return nil }
        if let next = playlist.entry(after: aid, bvid: bvid, epId: epId) { return .next(next) }
        return playlist.hasMore ? .pending : .end
    }

    /// Loads the next 播放全部 page while one of the last loaded entries plays; a video that ended meanwhile
    /// advances once it arrives.
    private func prefetchPlaylistIfNeeded() {
        guard let playlist, !playlist.isLoading else { return }
        let aid = interactionAid
        let bvid = currentEpisode?.bvid ?? detail?.bvid ?? ""
        guard playlist.needsMore(after: aid, bvid: bvid, epId: currentEpisode?.epId ?? 0) else { return }
        Task { [weak self] in
            let added = await playlist.loadMore()
            guard let self, aid == self.interactionAid else { return }
            self.refreshNextAvailability()
            if added, self.player?.status == .ended { self.advance(manual: false) }
        }
    }

    /// Automatic advancing at the end follows 「播放顺序」; the 下一集 button always advances.
    private func advance(manual: Bool) {
        var next = nextStep()
        if !manual {
            // 「播放顺序」 (the player replays 单个循环 itself).
            switch AppSettings.shared.player.playRepeat {
            case .pause, .singleCycle:
                return
            case .listOrder:
                next = nextStep(includeRelated: false)
            case .listCycle:
                next = nextStep(includeRelated: false)
                if next == nil, !isPlaylistPending {
                    // Back to the first item; a single video with no list replays itself.
                    guard let first = firstListStep() else {
                        player?.play()
                        return
                    }
                    next = first
                }
            case .autoPlayRelated:
                if next == nil, !isPlaylistPending, relatedLoaded || season != nil {
                    ToastCenter.shared.show("暂无相关视频，停止连播")
                }
            }
        }
        guard let step = next else { return }
        if !manual && (comments.composerTarget != nil || comments.subRepliesRoot != nil) {
            // Switching to another comment area would close the open composer (losing the draft) or the
            // reply thread the user is reading.
            switch step {
            case .part: break
            case .episode(let ep) where ep.aid == comments.oid: break
            default: return
            }
        }
        switch step {
        case .part(let p): selectPart(p)
        case .episode(let ep): selectEpisode(ep)
        case .video(let r): replace(with: r)
        }
    }

    /// 「下一集」 (fullscreen bar, lock screen next-track) only when there is something to advance to.
    private func refreshNextAvailability() {
        guard let player else { return }
        if nextStep() == nil {
            if player.onNext != nil { player.onNext = nil }
        } else if player.onNext == nil {
            player.onNext = { [weak self] in
                Task { @MainActor in self?.advance(manual: true) }
            }
        }
        syncPlayerPage()
    }

    // MARK: Side data

    private func spawn(_ body: @escaping @MainActor (VideoDetailModel) async -> Void) {
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
        sideTasks.append(task)
    }

    private func cancelSideTasks() {
        sideTasks.forEach { $0.cancel() }
        sideTasks = []
        onlineTask?.cancel()
        onlineTask = nil
    }

    private func loadSideData() {
        let gen = sideGeneration
        sideDataLoggedIn = BiliHTTP.shared.isLoggedIn
        spawn { await $0.loadRelation(gen: gen) }
        if let d = detail {
            if d.tags.isEmpty { spawn { await $0.loadTags(gen: gen) } }
            spawn { await $0.loadRelated(gen: gen) }
            if d.owner.mid > 0 { spawn { await $0.loadOwnerCard(gen: gen) } }
            if d.owner.mid > 0 { spawn { await $0.loadOwnerRelation(gen: gen) } }
        }
        startOnlinePolling()
        prefetchPlaylistIfNeeded()
    }

    private func loadRelation(gen: Int) async {
        guard BiliHTTP.shared.isLoggedIn else { return }
        let edits = relationEdits
        do {
            let r: VideoRelation
            if season != nil, let ep = currentEpisode {
                r = try await VideoAPI.pgcEpisodeRelation(epId: ep.epId)
            } else if let d = detail {
                r = try await VideoAPI.relation(aid: d.aid, bvid: d.bvid)
            } else {
                return
            }
            guard gen == sideGeneration else { return }
            if r.followingUp, let d = detail {
                isFollowingOwner = true
                followedStaff.insert(d.owner.mid)
            }
            // A like / coin / favourite made while this was in flight is newer than the response: ask again.
            guard edits == relationEdits else {
                spawn { await $0.loadRelation(gen: gen) }
                return
            }
            relation = r
            if r.liked && counts.like == 0 { counts.like = 1 }
            if r.favored && counts.favorite == 0 { counts.favorite = 1 }
        } catch {}
    }

    /// Back on the page after logging in / out (the login page is pushed on top): the like / coin / favourite
    /// and follow state shown was loaded for the other session.
    private func reloadAccountState() {
        sideDataLoggedIn = BiliHTTP.shared.isLoggedIn
        relationEdits += 1
        relation = VideoRelation()
        addedToWatchLater = false
        ownerRelation = nil
        if !sideDataLoggedIn {
            isFollowingOwner = false
            followedStaff = []
            isFollowingSeason = false
        }
        let gen = sideGeneration
        spawn { await $0.loadRelation(gen: gen) }
        if ownerMid > 0 { spawn { await $0.loadOwnerCard(gen: gen) } }
        if ownerMid > 0 { spawn { await $0.loadOwnerRelation(gen: gen) } }
        if sideDataLoggedIn, let seasonId = season?.seasonId {
            // 追番 state comes with the season (`user_status`).
            spawn { model in
                guard let fresh = try? await VideoAPI.pgcSeason(seasonId: seasonId, epId: nil),
                      gen == model.sideGeneration, model.season?.seasonId == seasonId else { return }
                model.isFollowingSeason = fresh.userStatus.follow
            }
        }
        if comments.didLoad {
            let list = comments
            Task { await list.refresh() }   // per-user like state of the comments
        }
    }

    private func loadTags(gen: Int) async {
        guard let d = detail else { return }
        guard let t = try? await VideoAPI.tags(aid: d.aid, bvid: d.bvid, cid: currentCid), gen == sideGeneration else { return }
        tags = t
    }

    private func loadRelated(gen: Int) async {
        guard let d = detail else { return }
        let cards = (try? await VideoAPI.related(aid: d.aid, bvid: d.bvid)) ?? []
        guard gen == sideGeneration else { return }
        let allows = FeedFilter.liveFilter(scope: .related)
        var ids = Set<String>()
        related = cards.filter { $0.aid != d.aid && allows($0) && ids.insert($0.id).inserted }
        relatedLoaded = true
        refreshNextAvailability()
    }

    /// `/x/web-interface/card` → fans / videos / follow state / VIP of the uploader.
    private func loadOwnerCard(gen: Int) async {
        let mid = ownerMid
        guard mid > 0 else { return }
        guard let data = try? await BiliHTTP.shared.api(BiliHost.api + "/x/web-interface/card", query: ["mid": mid]),
              gen == sideGeneration else { return }
        ownerFans = data["follower"].int64 ?? data[path: "card.fans"].int64Value
        ownerArchiveCount = data["archive_count"].int64Value
        let vip = data[path: "card.vip"]
        ownerIsVip = (vip["vipStatus"].int ?? vip["status"].intValue) == 1
        if data["following"].boolValue {
            isFollowingOwner = true
            followedStaff.insert(mid)
        }
    }

    /// `/x/relation` for the uploader's follow button (已互关 / 悄悄关注 / 特别关注 / 已拉黑). Login only.
    private func loadOwnerRelation(gen: Int) async {
        let mid = ownerMid
        guard mid > 0, mid != BiliHTTP.shared.mid, BiliHTTP.shared.isLoggedIn else { return }
        guard let state = try? await SpaceAPI.relation(fid: mid), gen == sideGeneration, mid == ownerMid else { return }
        ownerRelation = state
        isFollowingOwner = state.isFollowing
        if state.isFollowing { followedStaff.insert(mid) } else { followedStaff.remove(mid) }
    }

    private func onlineIDs(gen: Int) -> (aid: Int64, cid: Int64, bvid: String)? {
        guard gen == sideGeneration else { return nil }
        let aid = interactionAid
        guard aid > 0, currentCid > 0 else { return nil }
        return (aid, currentCid, currentEpisode?.bvid ?? detail?.bvid ?? "")
    }

    private func setOnline(_ text: String?, gen: Int) {
        guard gen == sideGeneration else { return }
        onlineText = text
    }

    /// 「N人在看」: fetched now and refreshed every minute while the page lives.
    private func startOnlinePolling() {
        onlineTask?.cancel()
        onlineText = nil
        let gen = sideGeneration
        onlineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ids = self?.onlineIDs(gen: gen) else { return }
                let text = try? await VideoAPI.onlineCount(aid: ids.aid, cid: ids.cid, bvid: ids.bvid)
                if Task.isCancelled { return }
                self?.setOnline(text, gen: gen)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: Interactions (callers check login first)

    private func begin(_ action: Action) -> Bool {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return false
        }
        guard !busy.contains(action) else { return false }
        busy.insert(action)
        return true
    }

    private func end(_ action: Action) {
        busy.remove(action)
    }

    func toggleLike() async {
        let aid = interactionAid
        guard aid > 0, begin(.like) else { return }
        defer { end(.like) }
        let target = !relation.liked
        do {
            try await VideoAPI.like(aid: aid, like: target)
            if !target { ToastCenter.shared.show("已取消点赞") }
            // Auto-next / another episode may have replaced the page meanwhile: its state is not ours.
            guard aid == interactionAid else { return }
            relationEdits += 1
            relation.liked = target
            counts.like = max(0, counts.like + (target ? 1 : -1))
            if target { relation.disliked = false }
        } catch {
            ToastCenter.shared.show(error: error)
            // 65006 已经点过赞了 / 65004 取消点赞失败 (not liked): the shown state was wrong (relation not loaded).
            if let code = (error as? BiliError)?.apiCode, code == 65006 || code == 65004, aid == interactionAid {
                relationEdits += 1
                relation.liked = code == 65006
            }
        }
    }

    /// 点踩 / 取消点踩 (app endpoint: needs the TV QR login's `access_key`, see `VideoAPI.dislike`). Disliking
    /// also cancels a like.
    func toggleDislike() async {
        let aid = interactionAid
        guard aid > 0, begin(.dislike) else { return }
        defer { end(.dislike) }
        let target = !relation.disliked
        do {
            try await VideoAPI.dislike(aid: aid, dislike: target)
            ToastCenter.shared.show(target ? "点踩成功" : "已取消点踩")
            guard aid == interactionAid else { return }
            relationEdits += 1
            relation.disliked = target
            if target && relation.liked {
                relation.liked = false
                counts.like = max(0, counts.like - 1)
            }
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// `aid`: the video the coin sheet was opened for (it stays open when auto-next switches the page).
    func giveCoins(_ count: Int, alsoLike: Bool, aid targetAid: Int64? = nil) async {
        let aid = targetAid ?? interactionAid
        guard aid > 0, begin(.coin) else { return }
        defer { end(.coin) }
        let n = aid == interactionAid ? max(1, min(count, maxCoins - relation.coinCount)) : max(1, min(count, 2))
        do {
            let liked = try await VideoAPI.coin(aid: aid, count: n, alsoLike: alsoLike)
            ToastCenter.shared.show("投币成功")
            guard aid == interactionAid else { return }
            relationEdits += 1
            relation.coinCount += n
            counts.coin += Int64(n)
            if (alsoLike || liked) && !relation.liked {
                relation.liked = true
                relation.disliked = false
                counts.like += 1
            }
        } catch {
            ToastCenter.shared.show(error: error)
            // 34005 已达到投币上限: the coins were given before (relation not loaded) — stop offering more.
            if (error as? BiliError)?.apiCode == 34005, aid == interactionAid {
                relationEdits += 1
                relation.coinCount = maxCoins
            }
        }
    }

    /// 一键三连.
    func triple() async {
        let aid = interactionAid
        guard aid > 0 else { return }
        if relation.liked && relation.coinCount >= maxCoins && relation.favored {
            ToastCenter.shared.show("已完成三连")
            return
        }
        guard begin(.triple) else { return }
        defer { end(.triple) }
        do {
            let result: (like: Bool, coin: Bool, fav: Bool)
            if let s = season, let ep = currentEpisode {
                result = try await VideoAPI.pgcTriple(epId: ep.epId, seasonId: s.seasonId)
            } else {
                result = try await VideoAPI.triple(aid: aid, bvid: detail?.bvid ?? "")
            }
            guard aid == interactionAid else {
                ToastCenter.shared.show(result.coin ? "三连成功" : "投币失败")
                return
            }
            relationEdits += 1
            if result.like && !relation.liked {
                relation.liked = true
                relation.disliked = false
                counts.like += 1
            }
            if result.coin && relation.coinCount < maxCoins {
                counts.coin += Int64(maxCoins - relation.coinCount)
                relation.coinCount = maxCoins
            }
            if result.fav && !relation.favored {
                relation.favored = true
                counts.favorite += 1
            }
            if result.coin || relation.coinCount >= maxCoins {
                ToastCenter.shared.show("三连成功")
            } else {
                ToastCenter.shared.show("投币失败")
            }
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// Called by the folder picker after a successful save of `rid` (the resource it was opened for).
    func favoriteChanged(_ favored: Bool, rid: Int64) {
        guard rid == favoriteResource.rid else { return }
        relationEdits += 1
        guard favored != relation.favored else { return }
        relation.favored = favored
        counts.favorite = max(0, counts.favorite + (favored ? 1 : -1))
    }

    /// 「快速收藏」 tap: favourites into the default folder, or — when the video is already in folders — removes
    /// it from all of them (the folder picker stays on long press). Membership comes from the server.
    func quickFavorite() async {
        let resource = favoriteResource
        guard resource.rid > 0, begin(.favorite) else { return }
        defer { end(.favorite) }
        do {
            let folders = try await VideoAPI.favFolders(forAid: resource.rid, resourceType: resource.type)
            let current = folders.filter(\.isFavorited).map(\.id)
            if current.isEmpty {
                guard let target = folders.first(where: \.isDefault) ?? folders.first else {
                    throw BiliError.other("还没有收藏夹")
                }
                try await VideoAPI.updateFav(aid: resource.rid, add: [target.id], remove: [], resourceType: resource.type)
                favoriteChanged(true, rid: resource.rid)
                ToastCenter.shared.show("已收藏到「\(target.title)」")
            } else {
                try await VideoAPI.updateFav(aid: resource.rid, add: [], remove: current, resourceType: resource.type)
                favoriteChanged(false, rid: resource.rid)
                ToastCenter.shared.show("已取消收藏")
            }
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// 稍后再看: adds, or removes again when this page already added it.
    func toggleWatchLater() async {
        let aid = interactionAid
        guard aid > 0, begin(.watchLater) else { return }
        defer { end(.watchLater) }
        let remove = addedToWatchLater
        do {
            if remove {
                try await VideoAPI.removeFromWatchLater(aid: aid)
            } else {
                try await VideoAPI.addToWatchLater(aid: aid)
            }
            if aid == interactionAid { addedToWatchLater = !remove }
            ToastCenter.shared.show(remove ? "已从稍后再看移除" : "已添加至稍后再看")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// 关注 / 取消关注 the uploader or a staff member.
    func toggleFollow(mid: Int64) async {
        guard mid > 0, begin(.follow) else { return }
        defer { end(.follow) }
        let following = isFollowing(mid)
        let state = mid == ownerMid ? ownerRelation : nil
        do {
            if following {
                try await SpaceAPI.modifyRelation(mid: mid, action: state?.unfollowAction ?? .unfollow)
            } else {
                try await SpaceAPI.follow(mid: mid)
            }
            if following { followedStaff.remove(mid) } else { followedStaff.insert(mid) }
            if mid == ownerMid {
                isFollowingOwner = !following
                ownerRelation = following ? .notFollowing : .followed
                if ownerFans > 0 || !following { ownerFans = max(0, ownerFans + (following ? -1 : 1)) }
                if !following {
                    // A follow-back makes it 已互关: ask again once the server has settled.
                    let gen = sideGeneration
                    spawn { model in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await model.loadOwnerRelation(gen: gen)
                    }
                }
            }
            ToastCenter.shared.show(following ? "已取消关注" : "关注成功")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// 解除拉黑 the uploader (its follow button reads 已拉黑; following a blocked user fails).
    func unblockOwner() async {
        let mid = ownerMid
        guard mid > 0, begin(.follow) else { return }
        defer { end(.follow) }
        do {
            try await SpaceAPI.modifyRelation(mid: mid, action: .unblock)
            if mid == ownerMid { ownerRelation = .notFollowing }
            ToastCenter.shared.show("已解除拉黑")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// 追番 / 追剧.
    func toggleSeasonFollow() async {
        guard let s = season, begin(.seasonFollow) else { return }
        defer { end(.seasonFollow) }
        let target = !isFollowingSeason
        do {
            let toast = try await VideoAPI.pgcFollow(seasonId: s.seasonId, follow: target)
            if s.seasonId == season?.seasonId { isFollowingSeason = target }
            ToastCenter.shared.show(toast)
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }
}

// MARK: - Player integration

/// The page side of the player's 选集, 上一集, 列表循环, 分P resume chip and fullscreen 点赞 / 投币 / 收藏 / 分享
/// (`PlayerController.episodeEntries` / `onSelectEpisode`, `onPrevious`, `fullscreenActions`).
extension VideoDetailModel {
    /// From `attach`: the hooks that do not depend on the content.
    fileprivate func connectPlayerPage(_ player: PlayerController) {
        player.onSelectEpisode = { [weak self] id, startTime in
            Task { @MainActor in self?.selectPlayerEntry(id, startTime: startTime) }
        }
        // Like / coin / favourite state changes in many places: follow every change of the page.
        player.pageObservation = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFullscreenActions() }
        }
    }

    /// With every 下一集 refresh (content, part or episode change): 选集 rows, 上一集 and the fullscreen row.
    fileprivate func syncPlayerPage() {
        guard let player else { return }
        let entries = playerEpisodeEntries()
        if entries != player.episodeEntries { player.episodeEntries = entries }
        if previousStep() == nil {
            if player.onPrevious != nil { player.onPrevious = nil }
        } else if player.onPrevious == nil {
            player.onPrevious = { [weak self] in
                Task { @MainActor in self?.goPrevious() }
            }
        }
        syncFullscreenActions()
    }

    // MARK: 选集

    /// The parts, else the 合集 episodes, else the PGC list of the current episode (ids: `p<cid>`,
    /// `u<aid>-<cid>`, `e<epId>`).
    private func playerEpisodeEntries() -> [PlayerEpisodeEntry] {
        if let s = season, let ep = currentEpisode {
            let list = pgcList(of: s, containing: ep)
            guard list.count > 1 else { return [] }
            return list.map { e in
                PlayerEpisodeEntry(id: "e\(e.epId)", title: e.displayTitle, badge: e.badge.isEmpty ? nil : e.badge,
                                   isCurrent: e.epId == ep.epId)
            }
        }
        guard let d = detail else { return [] }
        if d.pages.count > 1 {
            return d.pages.map { p in
                PlayerEpisodeEntry(id: PlayerEpisodeEntry.partID(cid: p.cid),
                                   title: p.part.isEmpty ? "P\(p.page)" : "P\(p.page) \(p.part)",
                                   isCurrent: p.cid == currentCid)
            }
        }
        guard let episodes = d.ugcSeason?.allEpisodes, episodes.count > 1 else { return [] }
        let current = episodes.firstIndex { $0.aid == d.aid }
        return episodes.enumerated().map { i, e in
            PlayerEpisodeEntry(id: "u\(e.aid)-\(e.cid)", title: e.title, badge: e.badge.isEmpty ? nil : e.badge,
                               isCurrent: i == current)
        }
    }

    private func selectPlayerEntry(_ id: String, startTime: Double?) {
        let value = id.dropFirst()
        switch id.first {
        case "p"?:
            if let cid = Int64(value), let part = detail?.pages.first(where: { $0.cid == cid }) {
                selectPart(part, startTime: startTime)
            }
        case "u"?:
            let ids = value.split(separator: "-").compactMap { Int64($0) }
            if ids.count == 2,
               let ep = detail?.ugcSeason?.allEpisodes.first(where: { $0.aid == ids[0] && $0.cid == ids[1] }) {
                selectSeasonEpisode(ep)
            }
        case "e"?:
            if let epId = Int64(value), let ep = season?.allEpisodes.first(where: { $0.epId == epId }) {
                selectEpisode(ep)
            }
        default:
            break
        }
    }

    /// The PGC list an episode belongs to (正片 or its section), as `nextStep` walks it.
    private func pgcList(of s: PGCSeason, containing ep: PGCEpisode) -> [PGCEpisode] {
        if s.episodes.contains(where: { $0.epId == ep.epId }) { return s.episodes }
        return s.sections.first(where: { $0.episodes.contains(where: { $0.epId == ep.epId }) })?.episodes ?? []
    }

    // MARK: 上一集 / 列表循环

    private func playlistRef(at index: Int, in list: VideoPlaylist) -> VideoRef {
        var ref = list.items[index]
        ref.playlist = list
        return ref
    }

    /// 上一集: previous part → previous 播放全部 entry → previous 合集 episode → previous PGC episode (mirrors
    /// `nextStep`, without 相关推荐).
    private func previousStep() -> NextStep? {
        if let s = season, let ep = currentEpisode {
            if let playlist, let i = playlist.index(aid: ep.aid, bvid: ep.bvid, epId: ep.epId) {
                return i > 0 ? .video(playlistRef(at: i - 1, in: playlist)) : nil
            }
            let list = pgcList(of: s, containing: ep)
            if let i = list.firstIndex(where: { $0.epId == ep.epId }), i > 0 { return .episode(list[i - 1]) }
            return nil
        }
        guard let d = detail else { return nil }
        if let i = d.pages.firstIndex(where: { $0.cid == currentCid }), i > 0 { return .part(d.pages[i - 1]) }
        if let playlist, let i = playlist.index(aid: d.aid, bvid: d.bvid) {
            return i > 0 ? .video(playlistRef(at: i - 1, in: playlist)) : nil
        }
        if let episodes = d.ugcSeason?.allEpisodes, let i = episodes.firstIndex(where: { $0.aid == d.aid }), i > 0 {
            return .video(episodes[i - 1].videoRef)
        }
        return nil
    }

    private func goPrevious() {
        guard let step = previousStep() else {
            ToastCenter.shared.show("已经是第一集了")
            return
        }
        switch step {
        case .part(let p): selectPart(p)
        case .episode(let ep): selectEpisode(ep)
        case .video(let r): replace(with: r)
        }
    }

    /// 列表循环 after the last item: the first item of the list being played through (nil = no list, or the
    /// current video is all of it).
    private func firstListStep() -> NextStep? {
        if let s = season, let ep = currentEpisode {
            if let playlist, let i = playlist.index(aid: ep.aid, bvid: ep.bvid, epId: ep.epId) {
                return i > 0 ? .video(playlistRef(at: 0, in: playlist)) : nil
            }
            let list = pgcList(of: s, containing: ep)
            if let first = list.first, first.epId != ep.epId { return .episode(first) }
            return nil
        }
        guard let d = detail else { return nil }
        let firstPart: NextStep? = d.pages.first.flatMap { $0.cid != currentCid ? .part($0) : nil }
        if let playlist, let i = playlist.index(aid: d.aid, bvid: d.bvid) {
            return i > 0 ? .video(playlistRef(at: 0, in: playlist)) : firstPart
        }
        if let first = d.ugcSeason?.allEpisodes.first, first.aid != d.aid { return .video(first.videoRef) }
        return firstPart
    }

    /// The 播放全部 list is still loading the entries after this video (`prefetchPlaylistIfNeeded` advances then).
    fileprivate var isPlaylistPending: Bool {
        let aid = currentEpisode?.aid ?? detail?.aid ?? 0
        let bvid = currentEpisode?.bvid ?? detail?.bvid ?? ""
        if case .pending? = playlistPosition(aid: aid, bvid: bvid, epId: currentEpisode?.epId ?? 0) { return true }
        return false
    }

    // MARK: Fullscreen 点赞 / 投币 / 收藏 / 分享

    private func syncFullscreenActions() {
        guard let player else { return }
        let actions = hasContent ? makeFullscreenActions() : nil
        if player.fullscreenActions != actions { player.fullscreenActions = actions }
    }

    private func makeFullscreenActions() -> PlayerFullscreenActions {
        var a = PlayerFullscreenActions()
        a.liked = relation.liked
        a.coined = relation.coinCount > 0
        a.favored = relation.favored
        a.likeCount = counts.like
        a.coinCount = counts.coin
        a.favoriteCount = counts.favorite
        a.shareCount = counts.share
        a.shareURL = shareURL
        a.shareTitle = title
        a.onLike = { [weak self] in Task { @MainActor in await self?.toggleLike() } }
        a.onTriple = { [weak self] in Task { @MainActor in await self?.triple() } }
        a.onCoin = { [weak self] in Task { @MainActor in self?.openPlayerCoinSheet() } }
        a.onFavorite = { [weak self] in Task { @MainActor in self?.openPlayerFavoriteSheet() } }
        return a
    }

    /// The intro tab's coin sheet over the player (fullscreen hides the page; the login page cannot be pushed).
    private func openPlayerCoinSheet() {
        guard let player else { return }
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        if relation.coinCount >= maxCoins {
            ToastCenter.shared.show("达到投币上限啦~")
            return
        }
        let aid = interactionAid
        guard aid > 0 else { return }
        let sheet = VideoCoinSheet(maxCoins: maxCoins, given: relation.coinCount) { [weak self] count, alsoLike in
            Task { await self?.giveCoins(count, alsoLike: alsoLike, aid: aid) }
        }
        player.presentPageSheet(id: "coin", content: AnyView(sheet))
    }

    private func openPlayerFavoriteSheet() {
        guard let player else { return }
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        let resource = favoriteResource
        guard resource.rid > 0 else { return }
        if AppSettings.shared.player.quickFavorite {
            Task { await quickFavorite() }
            return
        }
        let rid = resource.rid
        let sheet = VideoFavFolderSheet(rid: rid, resourceType: resource.type) { [weak self] favored in
            self?.favoriteChanged(favored, rid: rid)
        }
        player.presentPageSheet(id: "favorite", content: AnyView(sheet))
    }
}

// MARK: - Page lifetime

/// Owned by the detail page as a `@StateObject`, so SwiftUI releases it exactly when the page's state goes away:
/// popped by any means — including a pop-to-root (tab re-tap) while another page covered it, which sends no
/// further `onDisappear`, and a swipe-back whose path update arrives after `onDisappear` ran. Without this the
/// player would only be released, never stopped (no final history heartbeat, stale lock-screen 正在播放,
/// Picture in Picture killed instead of finishing).
final class VideoDetailPageLifetime: ObservableObject {
    /// Set on the main actor by the page; must hop to the main actor itself.
    var onRelease: (() -> Void)?

    deinit {
        onRelease?()
    }
}

// MARK: - Interactive pop with a hidden navigation bar

/// Hiding the navigation bar disables UIKit's edge-swipe back; this re-enables it while the detail page is
/// visible and restores the system delegate afterwards.
struct VideoDetailPopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VideoDetailPopGestureController {
        VideoDetailPopGestureController()
    }

    func updateUIViewController(_ uiViewController: VideoDetailPopGestureController, context: Context) {}
}

final class VideoDetailPopGestureController: UIViewController, UIGestureRecognizerDelegate {
    private weak var installedRecognizer: UIGestureRecognizer?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uninstall()
    }

    private func install() {
        guard installedRecognizer == nil, let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
        previousDelegate = recognizer.delegate
        recognizer.delegate = self
        recognizer.isEnabled = true
        installedRecognizer = recognizer
    }

    private func uninstall() {
        guard let recognizer = installedRecognizer else { return }
        if recognizer.delegate === self { recognizer.delegate = previousDelegate }
        installedRecognizer = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }
        // Never start a pop while a push / pop animation runs (UINavigationController would get stuck).
        return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
    }

    /// A swipe from the left edge pops instead of being taken by a scroll view under it — the 简介 | 评论 pager
    /// (a paging scroll view that can rubber-band on its first page) or a horizontal chip row. Those pans wait
    /// for the edge recognizer, which fails at once for touches away from the edge.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
}
