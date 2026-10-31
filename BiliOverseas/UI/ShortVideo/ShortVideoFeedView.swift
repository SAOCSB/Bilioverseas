import SwiftUI

/// 短视频: the official app's vertical "story" mode (`VerticalVideoViews.swift`). Videos with danmaku between the
/// status bar and the 发弹幕 bar, swipe up for the next one and down for the previous; tap to pause, double-tap to
/// like, hold for 倍速.
struct ShortVideoFeedView: View {
    @StateObject private var model: ShortVideoFeedModel
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var commentsFor: ShortVideoItem?
    @State private var coinFor: ShortVideoItem?
    @State private var favoriteFor: ShortVideoItem?
    @State private var danmakuFor: ShortVideoItem?
    @State private var showsDanmakuSettings = false

    init(start: ShortVideoItem? = nil) {
        _model = StateObject(wrappedValue: ShortVideoFeedModel(start: start))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.items.isEmpty {
                    placeholder
                } else {
                    ShortVideoPager(items: model.items, index: $model.index,
                                    onReachEnd: { Task { await model.loadMore() } },
                                    onLanding: { model.landing.index = $0 }) { item, position in
                        ShortVideoPageView(item: item, isCurrent: position == model.index,
                                           playback: model.playback(for: item), social: model.social(for: item),
                                           actions: actions)
                    }
                }
                topBar
            }
            bottomBar
        }
        .padding(.top, -VerticalVideoMetrics.statusBarGap)
        // Dark controls for this screen only: a window-wide color scheme would repaint the pages under it.
        .environment(\.colorScheme, .dark)
        // The keyboard of 发弹幕 comes up in a sheet: the video stays where it is behind that.
        .ignoresSafeArea(.keyboard)
        .background(Color.black.ignoresSafeArea())
        .background(VideoDetailPopGestureEnabler().frame(width: 0, height: 0))
        .background(VerticalVideoDarkScreen().frame(width: 0, height: 0))
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await model.loadInitialIfNeeded() }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        // A push from inside the comments (a commenter's space, login…) lands under the sheet: close it.
        .onChange(of: router.path.count) { _ in
            if commentsFor != nil { commentsFor = nil }
        }
        .sheet(item: $commentsFor) { item in
            NavigationStack {
                VideoCommentsView(oid: item.aid, type: 1)
                    .navigationTitle("评论")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .environmentObject(router)
            .presentationDetents([.fraction(0.7), .large])
        }
        .sheet(item: $coinFor) { item in
            let social = model.social(for: item)
            VideoCoinSheet(maxCoins: item.maxCoins, given: social.coins) { count, alsoLike in
                Task { await social.coin(count, alsoLike: alsoLike) }
            }
        }
        .sheet(item: $favoriteFor) { item in
            let social = model.social(for: item)
            VideoFavFolderSheet(rid: item.aid, resourceType: 2) { favored in
                social.favoriteChanged(favored)
            }
        }
        .sheet(item: $danmakuFor) { item in
            let playback = model.playback(for: item)
            DanmakuSendSheet(aid: item.aid, cid: playback.resolvedCid ?? item.cid,
                             currentTime: { playback.position }, isClosed: playback.danmaku.isClosedByUploader,
                             onSent: { playback.danmaku.insertLocal($0) })
        }
        // The video keeps playing above the sheet, so a change shows at once.
        .sheet(isPresented: $showsDanmakuSettings) {
            DanmakuQuickPanel(fullscreen: true)
        }
    }

    private var actions: ShortVideoActions {
        ShortVideoActions(
            togglePlay: { model.togglePlay($0) },
            comments: { commentsFor = $0 },
            coin: { item in
                guard ShortVideoSocial.requireLogin("投币") else { return }
                if model.social(for: item).coins >= item.maxCoins {
                    ToastCenter.shared.show("达到投币上限啦~")
                } else {
                    coinFor = item
                }
            },
            favorite: { item in
                guard ShortVideoSocial.requireLogin("收藏") else { return }
                if AppSettings.shared.player.quickFavorite {
                    Task { await model.social(for: item).quickFavorite() }
                } else {
                    favoriteFor = item
                }
            },
            uploader: { item in
                if item.ownerMid != 0 { router.push(.user(mid: item.ownerMid)) }
            },
            fullVideo: { item in router.push(.video(item.videoRef)) },
            dislike: { item, reason in Task { await model.dislike(item, reason: reason) } }
        )
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            if let error = model.errorText {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                Text(error)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.biliPink)
            } else if model.isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Text("暂时没有短视频")
                Button("刷新") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        ShortVideoLandingReader(landing: model.landing) {
            VerticalVideoTopBar(online: model.onlineText, onBack: { dismiss() }, onSearch: { router.push(.searchHome) }) {
                if let item = model.showing {
                    moreMenu(item)
                }
            }
        }
    }

    private var bottomBar: some View {
        VerticalVideoBottomBar(danmakuOn: settings.danmaku.enabled,
                               onSend: sendDanmaku,
                               onToggle: { settings.danmaku.enabled.toggle() },
                               onDetail: {
                                   if let item = model.showing { actions.fullVideo(item) }
                               },
                               onSettings: { showsDanmakuSettings = true })
    }

    private func sendDanmaku() {
        guard let item = model.showing, ShortVideoSocial.requireLogin("发弹幕") else { return }
        if model.playback(for: item).resolvedCid != nil || item.cid != 0 {
            danmakuFor = item
        } else {
            ToastCenter.shared.show("视频加载中，请稍后再试")
        }
    }

    private func moreMenu(_ item: ShortVideoItem) -> some View {
        Menu {
            Button { showsDanmakuSettings = true } label: {
                Label("弹幕设置", systemImage: "slider.horizontal.3")
            }
            Button { Task { await model.social(for: item).addToWatchLater() } } label: {
                Label("稍后再看", systemImage: "clock")
            }
            if let url = item.shareURL {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    ToastCenter.shared.show("链接已复制")
                } label: {
                    Label("复制链接", systemImage: "link")
                }
            }
            // Like the feed cards' menu: only offered when the card's feed can be told (`FeedAPI.canReport`).
            if let feedback = item.feedback, !feedback.reasons.isEmpty, FeedAPI.canReport(feedback) {
                Menu {
                    ForEach(feedback.reasons, id: \.self) { reason in
                        Button(reason.name) { actions.dislike(item, reason) }
                    }
                } label: {
                    Label("不感兴趣", systemImage: "hand.thumbsdown")
                }
            }
            Toggle(isOn: Binding(get: { model.portraitOnly }, set: { model.setPortraitOnly($0) })) {
                Label("只看竖屏", systemImage: "rectangle.portrait")
            }
            if settings.acceleration.enabled {
                Toggle(isOn: Binding(get: { settings.acceleration.verticalVideosDirect }, set: { direct in
                    settings.acceleration.verticalVideosDirect = direct
                    ToastCenter.shared.show(direct ? "竖屏视频已禁用加速" : "竖屏视频已开启加速")
                })) {
                    Label("禁用加速", systemImage: "bolt.slash")
                }
            }
            Button { Task { await model.reload() } } label: {
                Label("换一批", systemImage: "arrow.clockwise")
            }
        } label: {
            VerticalVideoBarIcon(systemName: "ellipsis", upright: true)
        }
        .accessibilityLabel("更多")
    }
}

/// Rebuilds its content when a swipe starts coming to rest on another page, without rebuilding the pages.
private struct ShortVideoLandingReader<Content: View>: View {
    @ObservedObject var landing: ShortVideoLanding
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// What the page's buttons do; navigation, sheets and the play state belong to the feed screen.
struct ShortVideoActions {
    var togglePlay: (ShortVideoItem) -> Void
    var comments: (ShortVideoItem) -> Void
    var coin: (ShortVideoItem) -> Void
    var favorite: (ShortVideoItem) -> Void
    var uploader: (ShortVideoItem) -> Void
    var fullVideo: (ShortVideoItem) -> Void
    var dislike: (ShortVideoItem, FeedDislikeReason) -> Void
}

/// One video with its overlay, filling the area between the status bar and the 发弹幕 bar. The bars themselves stay
/// where they are while the pages slide.
struct ShortVideoPageView: View {
    let item: ShortVideoItem
    let isCurrent: Bool
    @ObservedObject var playback: ShortVideoPlayback
    @ObservedObject var social: ShortVideoSocial
    let actions: ShortVideoActions

    @State private var readyForDisplay = false
    @State private var titleExpanded = false
    @State private var bursts: [VerticalVideoLikeBurst] = []
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                page(in: geo)
                // Beside the page, not in it: the page's gestures would take a finger held still on the bar.
                progress
            }
        }
        .ignoresSafeArea()
        .onChange(of: isCurrent) { current in
            if !current { titleExpanded = false }
        }
    }

    private func page(in geo: GeometryProxy) -> some View {
        ZStack {
            Color.black
            ShortVideoSurface(player: playback.player, fill: fills(in: geo.size), readyForDisplay: $readyForDisplay)
            if !readyForDisplay || playback.phase != .ready {
                RemoteImage(url: item.cover, contentMode: fills(in: geo.size) ? .fill : .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .frame(height: 300)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            // Below the top bar; the controls below it stay readable over the danmaku.
            ShortVideoDanmakuLayer(danmaku: playback.danmaku)
                .padding(.top, VerticalVideoMetrics.topBarHeight)
                .allowsHitTesting(false)
            statusOverlay
            ForEach(bursts) { burst in
                VerticalVideoLikeBurstView(burst: burst)
                    .position(burst.location)
            }
            overlay
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, coordinateSpace: .local) { location in doubleTap(at: location) }
        .onTapGesture { actions.togglePlay(item) }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 12, perform: {
            guard AppSettings.shared.player.longPressSpeedEnabled, !playback.isPaused else { return }
            playback.setFastForward(true)
        }, onPressingChanged: { pressing in
            if !pressing, playback.isFastForward { playback.setFastForward(false) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(playback.isPaused ? "播放" : "暂停")) { actions.togglePlay(item) }
    }

    private func fills(in size: CGSize) -> Bool {
        VerticalVideoMetrics.fills(video: CGSize(width: item.width, height: item.height), area: size)
    }

    @ViewBuilder private var statusOverlay: some View {
        switch playback.phase {
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("重试") { playback.retry() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(24)
        default:
            if playback.isFastForward {
                Label("\(speedText)倍速播放中", systemImage: "forward.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)
                    .allowsHitTesting(false)
            } else if let scrubbing {
                PlayerPill { Text("\(PlayerFormat.time(scrubbing))/\(PlayerFormat.time(playback.duration))").monospacedDigit() }
                    .allowsHitTesting(false)
            } else if isCurrent && (playback.isBuffering || playback.phase == .loading) {
                ProgressView()
                    .tint(.white)
                    .allowsHitTesting(false)
            } else if isCurrent && playback.isPaused && playback.phase == .ready {
                VerticalVideoPausedHint(time: "\(PlayerFormat.time(playback.position)) / \(PlayerFormat.time(playback.duration))")
            }
        }
    }

    private var speedText: String {
        let speed = playback.fastSpeed
        return speed == speed.rounded() ? String(Int(speed)) : String(format: "%.2g", speed)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                VerticalVideoInfoView(actions: videoActions, title: item.title, expanded: $titleExpanded)
                VerticalVideoActionColumn(actions: videoActions)
            }
            .padding(.leading, 12)
            .padding(.bottom, 22 - VerticalVideoMetrics.progressOverlap)
        }
    }

    private var progress: some View {
        PlayerProgressBar(timeline: playback.timeline, chapters: [], segments: [], clips: [], barHeight: 2,
                          height: 22, verticalScreenStyle: true,
                          onScrubBegan: {},
                          onScrubChanged: { scrubbing = $0 },
                          onScrubEnded: { target in
                              scrubbing = nil
                              playback.seek(to: target)
                          },
                          onScrubCancelled: { scrubbing = nil })
            .padding(.horizontal, 12)
            .offset(y: VerticalVideoMetrics.progressOverhang)
    }

    private var videoActions: PlayerFullscreenActions {
        var a = PlayerFullscreenActions()
        a.liked = social.liked
        a.coined = social.coins > 0
        a.favored = social.favored
        a.likeCount = social.likeCount
        a.commentCount = item.replyCount
        a.coinCount = social.coinCount
        a.favoriteCount = social.favoriteCount
        a.shareCount = item.shareCount
        a.viewCount = item.viewCount
        a.shareURL = item.shareURL
        a.shareTitle = item.title
        a.ownerName = item.ownerName
        a.ownerFace = item.ownerFace
        a.ownerFans = social.ownerFans
        a.following = social.following
        a.canFollow = item.ownerMid != 0 && item.ownerMid != BiliHTTP.shared.mid
        a.onLike = { Task { await social.toggleLike() } }
        a.onTriple = { Task { await social.triple(maxCoins: item.maxCoins) } }
        a.onComments = { actions.comments(item) }
        a.onCoin = { actions.coin(item) }
        a.onFavorite = { actions.favorite(item) }
        a.onFollow = { Task { await social.follow() } }
        a.onUploader = { actions.uploader(item) }
        return a
    }

    private func doubleTap(at location: CGPoint) {
        guard ShortVideoSocial.requireLogin("点赞") else { return }
        let burst = VerticalVideoLikeBurst(location: location)
        bursts.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { bursts.removeAll { $0.id == burst.id } }
        Task { await social.toggleLike(onlyLike: true) }
    }
}
