import AVFoundation
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
    /// 清屏: nothing but the picture, also on the videos swiped to; a tap brings the rest back.
    @State private var cleared = false
    /// Navigation depth when this page first appeared: back at it, the pages opened from here have gone.
    @State private var stackDepth: Int?

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
                                    onLanding: { model.setLanding($0) }) { item, position in
                        ShortVideoPageView(item: item, isCurrent: position == model.index,
                                           playback: model.playback(for: item), social: model.social(for: item),
                                           actions: actions, cleared: cleared)
                    }
                }
                if !cleared { topBar }
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
        .onAppear {
            let depth = stackDepth ?? router.path.count
            stackDepth = depth
            // A swipe back brings this on while the video's page above it still plays, and may stop halfway. Its path update
            // lands when it is done.
            if router.path.count <= depth { model.setVisible(true) }
        }
        .onDisappear { model.setVisible(false) }
        // A push from inside the comments (a commenter's space, login…) lands under the sheet: close it.
        .onChange(of: router.path.count) { count in
            if commentsFor != nil { commentsFor = nil }
            model.closeLandscape()
            if count == stackDepth { model.setVisible(true) }
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
            fastForward: { model.setFastForward($1, item: $0) },
            restoreControls: { cleared = false },
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
            fullVideo: { item in router.push(.video(model.pageRef(for: item))) },
            dislike: { item, reason in Task { await model.dislike(item, reason: reason) } }
        )
    }

    @ViewBuilder private var feedMenuItems: some View {
        Toggle(isOn: Binding(get: { model.portraitOnly }, set: { model.setPortraitOnly($0) })) {
            Label("只看竖屏", systemImage: "rectangle.portrait")
        }
        Picker(selection: Binding(get: { ShortVideoAPI.source(chosen: settings.general.swipeFeedSource) }, set: { source in
            settings.general.swipeFeedSource = source
            // `@Published` emits before the value is stored; here it has been.
            model.sourceMayHaveChanged()
        })) {
            ForEach(SwipeFeedSource.allCases) { source in
                Text(source.title).tag(source)
            }
        } label: {
            Label("推荐来源", systemImage: "sparkles")
        }
        .pickerStyle(.menu)
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
                Text(model.portraitOnly && ShortVideoAPI.source(chosen: settings.general.swipeFeedSource) == .web
                     ? ShortVideoAPI.webHasNoPortraitNote : "暂时没有短视频")
                    .multilineTextAlignment(.center)
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
                } else {
                    // What emptied the feed can be changed here too.
                    Menu {
                        feedMenuItems
                    } label: {
                        VerticalVideoBarIcon(systemName: "ellipsis", upright: true)
                    }
                }
            }
            .modifier(ShortVideoSpeedingHidden(speeding: model.landing.isSpeeding))
        }
    }

    private var bottomBar: some View {
        ShortVideoLandingReader(landing: model.landing) {
            VerticalVideoBottomBar(danmakuOn: settings.danmaku.enabled, landscape: model.showing?.isPortrait == false,
                                   cleared: cleared,
                                   onSend: sendDanmaku,
                                   onToggle: { settings.danmaku.enabled.toggle() },
                                   onSettings: { showsDanmakuSettings = true },
                                   onDetail: {
                                       if let item = model.showing { actions.fullVideo(item) }
                                   },
                                   onClear: { cleared.toggle() },
                                   onFullscreen: { model.showLandscape() })
                .modifier(ShortVideoSpeedingHidden(speeding: model.landing.isSpeeding))
        }
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
            feedMenuItems
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

/// 长按倍速 clears the screen like 清屏, with no way back to show: it lasts as long as the finger.
private struct ShortVideoSpeedingHidden: ViewModifier {
    let speeding: Bool

    func body(content: Content) -> some View {
        content
            .opacity(speeding ? 0 : 1)
            .allowsHitTesting(!speeding)
            .animation(.easeInOut(duration: 0.15), value: speeding)
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
    var fastForward: (ShortVideoItem, Bool) -> Void
    var restoreControls: () -> Void
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
    let cleared: Bool

    @State private var readyForDisplay = false
    @State private var titleExpanded = false
    @State private var bursts: [VerticalVideoLikeBurst] = []
    @State private var scrubbing: Double?
    /// A tap that a second one may turn into a double tap.
    @State private var pendingTap: DispatchWorkItem?
    /// That second one is on the screen.
    @State private var secondTouch = false

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
            guard !current else { return }
            titleExpanded = false
            pendingTap?.cancel()
            pendingTap = nil
            secondTouch = false
        }
    }

    private func page(in geo: GeometryProxy) -> some View {
        ZStack {
            Color.black
            let pictureHeight = item.isPortrait ? geo.size.height
                : VerticalVideoMetrics.wholePictureFrame(in: CGRect(origin: .zero, size: geo.size)).height
            ShortVideoSurface(player: playback.player, fill: fills(in: geo.size), readyForDisplay: $readyForDisplay)
                .frame(height: pictureHeight)
                .frame(maxHeight: .infinity, alignment: .top)
            if !readyForDisplay || playback.phase != .ready {
                RemoteImage(url: item.cover, contentMode: fills(in: geo.size) ? .fill : .fit)
                    .frame(width: geo.size.width, height: pictureHeight)
                    .clipped()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            if !showsCleared {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .frame(height: 300)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
            // Below the top bar; the controls below it stay readable over the danmaku.
            let lanes = danmakuLanes(in: geo.size, pictureHeight: pictureHeight)
            ShortVideoDanmakuLayer(playback: playback, abovePicture: lanes.above)
                .frame(width: lanes.frame.width, height: lanes.frame.height)
                .position(x: lanes.frame.midX, y: lanes.frame.midY)
                .allowsHitTesting(false)
            statusOverlay
            ForEach(bursts) { burst in
                VerticalVideoLikeBurstView(burst: burst)
                    .position(burst.location)
            }
            if !showsCleared { overlay }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .contentShape(Rectangle())
        // The long press first: after a tap gesture it would wait for that to give up, about 0.8 s after the touch. For the
        // same reason there is one tap gesture, which tells a double tap by the time between them.
        // Not when it cannot speed anything up: a slower tap is still a tap then.
        .onLongPressGesture(minimumDuration: canSpeedUp ? 0.3 : 3600, maximumDistance: 12, perform: {
            guard canSpeedUp else { return }
            actions.fastForward(item, true)
        }, onPressingChanged: { pressing in
            if pressing {
                // A second touch in time: how it ends decides.
                if let first = pendingTap {
                    first.cancel()
                    pendingTap = nil
                    secondTouch = true
                }
            } else {
                // A tap has been told by now (`tapped`). This was something else, and the first tap goes with it.
                secondTouch = false
                if playback.isFastForward { actions.fastForward(item, false) }
            }
        })
        .onTapGesture(coordinateSpace: .local) { location in tapped(at: location) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(playback.isPaused ? "播放" : "暂停")) { actions.togglePlay(item) }
    }

    /// 清屏, which 长按倍速 does too for as long as it lasts (the danmaku stay).
    private var showsCleared: Bool { cleared || playback.isFastForward }

    private func fills(in size: CGSize) -> Bool {
        item.isPortrait && VerticalVideoMetrics.fills(video: CGSize(width: item.width, height: item.height), area: size)
    }

    /// A landscape video's go in the black above its picture (`VerticalVideoMetrics.danmakuPlacement`).
    private func danmakuLanes(in size: CGSize, pictureHeight: CGFloat) -> (frame: CGRect, above: DanmakuOverlayView.AbovePicture?) {
        let page = CGRect(origin: .zero, size: size).inset(by: UIEdgeInsets(top: VerticalVideoMetrics.topBarHeight, left: 0, bottom: 0, right: 0))
        guard !item.isPortrait else { return (page, nil) }
        let area = CGRect(x: 0, y: 0, width: size.width, height: pictureHeight)
        let picture = AVMakeRect(aspectRatio: CGSize(width: item.width, height: item.height), insideRect: area)
        return VerticalVideoMetrics.danmakuPlacement(picture: picture, in: page)
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
                PlayerQuietSpinner()
            } else if isCurrent && playback.isPaused && !playback.isStandingBy && playback.phase == .ready {
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

    private var canSpeedUp: Bool { AppSettings.shared.player.longPressSpeedEnabled && !playback.isPaused }

    private func tapped(at location: CGPoint) {
        if secondTouch {
            secondTouch = false
            doubleTap(at: location)
            return
        }
        let single = DispatchWorkItem {
            pendingTap = nil
            if cleared {
                actions.restoreControls()
            } else {
                actions.togglePlay(item)
            }
        }
        pendingTap = single
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: single)
    }

    private func doubleTap(at location: CGPoint) {
        guard ShortVideoSocial.requireLogin("点赞") else { return }
        let burst = VerticalVideoLikeBurst(location: location)
        bursts.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { bursts.removeAll { $0.id == burst.id } }
        Task { await social.toggleLike(onlyLike: true) }
    }
}
