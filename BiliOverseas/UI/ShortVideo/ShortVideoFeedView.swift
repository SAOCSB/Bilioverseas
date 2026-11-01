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
    /// 简介 and 评论 of the video on screen, which gives way to them.
    @StateObject private var panel = VerticalVideoPanelState()
    @State private var panelContent: VerticalVideoPanelContent?
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
        ZStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    if model.items.isEmpty {
                        placeholder
                    } else {
                        ShortVideoPager(items: model.items, index: $model.index,
                                        onReachEnd: { Task { await model.loadMore() } },
                                        onLanding: { model.setLanding($0) },
                                        scrollEnabled: !panel.isOpen) { item, position in
                            ShortVideoPageView(item: item, isCurrent: position == model.index,
                                               playback: model.playback(for: item), social: model.social(for: item),
                                               actions: actions, cleared: cleared, panel: panel.live, landing: model.landing)
                        }
                    }
                    if !cleared {
                        topBar
                            .modifier(VerticalVideoPanelFading(live: panel.live))
                    }
                }
                bottomBar
                    .modifier(VerticalVideoPanelFading(live: panel.live))
            }
            .padding(.top, -VerticalVideoMetrics.statusBarGap)
            if let panelContent {
                VerticalVideoPanelHost(state: panel, live: panel.live, content: panelContent)
            }
        }
        // Once it has gone down: the lists go with it.
        .onChange(of: panel.isOpen) { open in
            guard !open else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !panel.isOpen { panelContent = nil }
            }
        }
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
            // A swipe back begins with this.
            VideoMorph.endWaiting()
            let depth = stackDepth ?? router.path.count
            stackDepth = depth
            // A swipe back brings this on while the video's page above it still plays, and may stop halfway. Its path update
            // lands when it is done.
            if router.path.count <= depth { model.setVisible(true) }
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: router.path.count) { count in
            model.closeLandscape()
            if count == stackDepth { model.setVisible(true) }
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
            comments: { item in
                panelContent = model.panelContent(for: item)
                panel.prepare()
                // On the next turn: it comes up from below, and has to be there first.
                DispatchQueue.main.async { panel.open(tab: .comments) }
            },
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
            fullVideo: { item in model.openPage(of: item, router: router) },
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
            ZStack {
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
                if model.landing.isSpeedLocked {
                    VerticalVideoSpeedLockCatch {
                        if let item = model.showing { model.setFastForward(false, item: item) }
                    }
                } else if model.landing.isSpeeding, !model.landing.isPressSeeking {
                    VerticalVideoSpeedLockHint(active: model.landing.isOverSpeedLock)
                }
            }
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

/// Tap, double tap and the long press with what the finger does while it holds, which SwiftUI's long press cannot follow.
/// The bars over it have their own touches, and the pages' scrolling goes on around it until the press has begun.
struct ShortVideoGestureLayer: UIViewRepresentable {
    let canSpeedUp: () -> Bool
    let onTap: () -> Void
    let onDoubleTap: (CGPoint) -> Void
    let onPressBegan: (CGPoint) -> Void
    let onPressMoved: (CGPoint, CGSize) -> Void
    let onPressEnded: (_ cancelled: Bool) -> Void

    func makeUIView(context: Context) -> GestureView { GestureView() }

    func updateUIView(_ view: GestureView, context: Context) {
        view.gestures = self
    }

    final class GestureView: UIView, UIGestureRecognizerDelegate {
        var gestures: ShortVideoGestureLayer?
        private let singleTap = UITapGestureRecognizer()
        private let doubleTap = UITapGestureRecognizer()
        private let longPress = UILongPressGestureRecognizer()
        private var pressing = false

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            singleTap.addTarget(self, action: #selector(tapped))
            doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            singleTap.require(toFail: doubleTap)
            longPress.addTarget(self, action: #selector(pressed(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.delegate = self
            for recognizer in [singleTap, doubleTap, longPress] as [UIGestureRecognizer] { addGestureRecognizer(recognizer) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer !== longPress || gestures?.canSpeedUp() == true
        }

        @objc private func tapped() { gestures?.onTap() }

        @objc private func doubleTapped(_ g: UITapGestureRecognizer) { gestures?.onDoubleTap(g.location(in: self)) }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                pressing = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                gestures?.onPressBegan(g.location(in: self))
            case .changed:
                if pressing { gestures?.onPressMoved(g.location(in: self), bounds.size) }
            case .ended, .cancelled, .failed:
                guard pressing else { return }
                pressing = false
                gestures?.onPressEnded(g.state != .ended)
            default:
                break
            }
        }

        /// The cell is reused or the page is covered with the finger still down.
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow == nil, pressing else { return }
            pressing = false
            gestures?.onPressEnded(true)
            longPress.isEnabled = false
            longPress.isEnabled = true
        }
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
    let panel: VerticalVideoPanelLive
    let landing: ShortVideoLanding

    @State private var readyForDisplay = false
    @State private var titleExpanded = false
    @State private var bursts: [VerticalVideoLikeBurst] = []
    @State private var scrubbing: Double?
    /// A finger holding 倍速.
    @State private var press: VerticalVideoPressSeek?
    /// Where it drags the progress to.
    @State private var pressTarget: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                page(in: geo)
                // Beside the page, not in it: the page's gestures would take a finger held still on the bar.
                if let pressTarget {
                    VerticalVideoSeekBar(target: pressTarget, duration: playback.duration, shot: playback.videoShot,
                                         pictureRatio: item.height > item.width && item.width > 0
                                             ? CGFloat(item.width) / CGFloat(item.height) : nil)
                        .offset(y: VerticalVideoMetrics.progressOverhang)
                } else {
                    progress
                        .modifier(VerticalVideoPanelFading(live: panel, active: isCurrent))
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: isCurrent) { current in
            guard !current else { return }
            titleExpanded = false
            press = nil
            pressTarget = nil
        }
        // A speed the finger locked would keep the bars away from a video that needs them.
        .onChange(of: playback.phase) { phase in
            if case .failed = phase, playback.isFastForward { actions.fastForward(item, false) }
        }
    }

    /// Where the picture shows on the page, when the video's shape is known.
    private func pictureRect(in size: CGSize, height: CGFloat) -> CGRect {
        let area = CGRect(x: 0, y: 0, width: size.width, height: height)
        guard item.width > 0, item.height > 0, !fills(in: size) else { return area }
        return AVMakeRect(aspectRatio: CGSize(width: item.width, height: item.height), insideRect: area)
    }

    private func page(in geo: GeometryProxy) -> some View {
        ZStack {
            Color.black
            let pictureHeight = item.isPortrait ? geo.size.height
                : VerticalVideoMetrics.wholePictureFrame(in: CGRect(origin: .zero, size: geo.size)).height
            ZStack {
                ShortVideoSurface(player: playback.player, fill: fills(in: geo.size), readyForDisplay: $readyForDisplay,
                                  onView: { playback.surfaceView = $0 })
                    .frame(height: pictureHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                if !readyForDisplay || playback.phase != .ready {
                    RemoteImage(url: item.cover, contentMode: fills(in: geo.size) ? .fill : .fit)
                        .frame(width: geo.size.width, height: pictureHeight)
                        .clipped()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            .modifier(VerticalVideoPanelPicture(live: panel, active: isCurrent,
                                                picture: pictureRect(in: geo.size, height: pictureHeight), size: geo.size))
            ZStack {
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
                ShortVideoGestureLayer(canSpeedUp: { canSpeedUp }, onTap: tapped, onDoubleTap: doubleTap,
                                       onPressBegan: pressBegan, onPressMoved: pressMoved, onPressEnded: pressEnded)
                statusOverlay
                ForEach(bursts) { burst in
                    VerticalVideoLikeBurstView(burst: burst)
                        .position(burst.location)
                }
                if !showsCleared { overlay }
            }
            .modifier(VerticalVideoPanelFading(live: panel, active: isCurrent))
        }
        .frame(width: geo.size.width, height: geo.size.height)
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
            if playback.isFastForward, press != nil {
                VerticalVideoSpeedPill(mode: pressTarget != nil ? .seeking : .speed(speedText))
            } else if let scrubbing {
                PlayerPill { Text("\(PlayerFormat.time(scrubbing))/\(PlayerFormat.time(playback.duration))").monospacedDigit() }
                    .allowsHitTesting(false)
            } else if isCurrent && (playback.isBuffering || playback.phase == .loading) {
                PlayerQuietSpinner()
            } else if isCurrent && playback.isPaused && !playback.isStandingBy && playback.phase == .ready {
                VerticalVideoPausedHint(time: "\(PlayerFormat.time(playback.position)) / \(PlayerFormat.time(playback.duration))")
            } else if playback.isFastForward {
                VerticalVideoSpeedPill(mode: .locked(speedText))
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

    private func tapped() {
        if playback.isFastForward {
            // The speed the finger locked, on a video a call may have paused meanwhile.
            actions.fastForward(item, false)
            if playback.isPaused { actions.togglePlay(item) }
        } else if cleared {
            actions.restoreControls()
        } else {
            actions.togglePlay(item)
        }
    }

    private func pressBegan(at location: CGPoint) {
        press = VerticalVideoPressSeek(start: location)
        actions.fastForward(item, true)
    }

    private func pressMoved(to location: CGPoint, in size: CGSize) {
        guard var moving = press else { return }
        let target = moving.moved(to: location, width: size.width, time: { playback.position }, duration: playback.duration)
        press = moving
        if let target {
            if pressTarget == nil {
                playback.ensureVideoShot()
                landing.isPressSeeking = true
            }
            pressTarget = target
        }
        let overLock = !moving.isSeeking && location.y >= size.height - 8
        if landing.isOverSpeedLock != overLock { landing.isOverSpeedLock = overLock }
    }

    private func pressEnded(cancelled: Bool) {
        let target = press?.releaseTarget
        let locks = !cancelled && landing.isOverSpeedLock
        press = nil
        pressTarget = nil
        if locks {
            landing.isOverSpeedLock = false
            landing.isSpeedLocked = true
            return
        }
        actions.fastForward(item, false)
        if let target, !cancelled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playback.seek(to: target)
        }
    }

    private func doubleTap(at location: CGPoint) {
        guard ShortVideoSocial.requireLogin("点赞") else { return }
        let burst = VerticalVideoLikeBurst(location: location)
        bursts.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { bursts.removeAll { $0.id == burst.id } }
        Task { await social.toggleLike(onlyLike: true) }
    }
}
