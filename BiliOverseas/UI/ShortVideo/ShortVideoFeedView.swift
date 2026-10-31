import SwiftUI

/// 短视频: the official app's vertical "story" mode. Full-screen videos with danmaku, swipe up for the next one
/// and down for the previous; tap to pause, double-tap to like, hold for 倍速. The right column likes,
/// coins, favourites, opens the comments and shares; the uploader and title sit at the bottom.
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
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if model.items.isEmpty {
                    placeholder
                } else {
                    ShortVideoPager(items: model.items, index: $model.index,
                                    onReachEnd: { Task { await model.loadMore() } }) { item, position in
                        ShortVideoPageView(item: item, isCurrent: position == model.index,
                                           safeInsets: geo.safeAreaInsets,
                                           playback: model.playback(for: item), social: model.social(for: item),
                                           actions: actions)
                    }
                    .ignoresSafeArea()
                }
                topBar
            }
            // Dark controls for this screen only: a window-wide color scheme would repaint the pages under it.
            .environment(\.colorScheme, .dark)
        }
        .background(Color.black.ignoresSafeArea())
        .background(VideoDetailPopGestureEnabler().frame(width: 0, height: 0))
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
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
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("返回")
            Spacer()
            Button {
                settings.danmaku.enabled.toggle()
            } label: {
                PlayerDanmakuToggleIcon(enabled: settings.danmaku.enabled)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.danmaku.enabled ? "关闭弹幕" : "开启弹幕")
            Button {
                showsDanmakuSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("弹幕设置")
            if let item = model.current {
                moreMenu(item)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .padding(.horizontal, 6)
    }

    private func moreMenu(_ item: ShortVideoItem) -> some View {
        Menu {
            Button { router.push(.video(item.videoRef)) } label: {
                Label("打开完整视频页", systemImage: "rectangle.on.rectangle")
            }
            Button { Task { await model.social(for: item).addToWatchLater() } } label: {
                Label("稍后再看", systemImage: "clock")
            }
            Button {
                guard ShortVideoSocial.requireLogin("发弹幕") else { return }
                if model.playback(for: item).resolvedCid != nil || item.cid != 0 {
                    danmakuFor = item
                } else {
                    ToastCenter.shared.show("视频加载中，请稍后再试")
                }
            } label: {
                Label("发弹幕", systemImage: "text.bubble")
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
            Button { Task { await model.reload() } } label: {
                Label("换一批", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }
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

/// One full-screen video with its overlay. It lays out over the whole cell and keeps its controls inside
/// `safeInsets` (the screen's), which a reused, moving cell cannot report reliably.
struct ShortVideoPageView: View {
    let item: ShortVideoItem
    let isCurrent: Bool
    let safeInsets: EdgeInsets
    @ObservedObject var playback: ShortVideoPlayback
    @ObservedObject var social: ShortVideoSocial
    let actions: ShortVideoActions

    @State private var readyForDisplay = false
    @State private var titleExpanded = false
    @State private var hearts: [ShortVideoHeart] = []
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                ShortVideoSurface(player: playback.player, fill: fills(in: geo.size), readyForDisplay: $readyForDisplay)
                if !readyForDisplay || playback.phase != .ready {
                    RemoteImage(url: item.cover, contentMode: fills(in: geo.size) ? .fill : .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                    .frame(height: 160)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .frame(height: 300)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                // Below the top bar; the controls below it stay readable over the danmaku.
                ShortVideoDanmakuLayer(danmaku: playback.danmaku)
                    .padding(.top, safeInsets.top + 44)
                    .allowsHitTesting(false)
                statusOverlay
                ForEach(hearts) { heart in
                    ShortVideoHeartView(heart: heart)
                        .position(heart.location)
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
        .ignoresSafeArea()
        .onChange(of: isCurrent) { current in
            if !current { titleExpanded = false }
        }
    }

    /// Portrait videos fill a portrait screen like the official app; anything else is letterboxed.
    private func fills(in size: CGSize) -> Bool {
        item.isPortrait && size.height > size.width
    }

    @ViewBuilder private var statusOverlay: some View {
        switch playback.phase {
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    playback.close()
                    playback.play()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(24)
        default:
            if playback.isFastForward {
                Label("\(Self.speedText)倍速播放中", systemImage: "forward.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, safeInsets.top + 52)
                    .allowsHitTesting(false)
            } else if isCurrent && (playback.isBuffering || playback.phase == .loading) {
                ProgressView()
                    .tint(.white)
                    .allowsHitTesting(false)
            } else if isCurrent && playback.isPaused && playback.phase == .ready {
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(radius: 6)
                    .allowsHitTesting(false)
            }
        }
    }

    private static var speedText: String {
        let speed = AppSettings.shared.player.longPressSpeed
        return speed == speed.rounded() ? String(Int(speed)) : String(format: "%.2g", speed)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 12) {
                info
                actionColumn
            }
            .padding(.leading, 14 + safeInsets.leading)
            .padding(.trailing, 14 + safeInsets.trailing)
            progress
                .padding(.top, 10)
        }
        .padding(.bottom, max(safeInsets.bottom, 8))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { actions.uploader(item) } label: {
                Text("@\(item.ownerName)")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(item.ownerMid == 0)
            Text(item.title)
                .font(.system(size: 15))
                .lineLimit(titleExpanded ? 6 : 2)
                .multilineTextAlignment(.leading)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { titleExpanded.toggle() } }
            HStack(spacing: 10) {
                if item.viewCount > 0 {
                    Label(Fmt.count(item.viewCount), systemImage: "play.rectangle")
                        .accessibilityLabel("\(Fmt.count(item.viewCount))播放")
                }
                Button { actions.fullVideo(item) } label: {
                    Label("完整视频页", systemImage: "rectangle.on.rectangle")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionColumn: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                Button { actions.uploader(item) } label: {
                    AvatarView(url: item.ownerFace, size: 46)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.ownerName)
                if !social.following && item.ownerMid != 0 {
                    Button { Task { await social.follow() } } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.biliPink, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(y: 10)
                    .accessibilityLabel("关注")
                }
            }
            .padding(.bottom, 6)
            actionButton("hand.thumbsup.fill", count: social.likeCount, label: "点赞", active: social.liked) {
                Task { await social.toggleLike() }
            }
            actionButton("bitcoinsign.circle.fill", count: social.coinCount, label: "投币", active: social.coins > 0) {
                actions.coin(item)
            }
            actionButton("star.fill", count: social.favoriteCount, label: "收藏", active: social.favored) {
                actions.favorite(item)
            }
            actionButton("text.bubble.fill", count: item.replyCount, label: "评论", active: false) {
                actions.comments(item)
            }
            if let url = item.shareURL {
                ShareLink(item: url, subject: Text(item.title), message: Text(item.title)) {
                    actionLabel("arrowshape.turn.up.right.fill", count: item.shareCount, label: "分享", active: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享")
            }
        }
        .frame(width: 58)
    }

    private func actionButton(_ symbol: String, count: Int64, label: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(symbol, count: count, label: label, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(count > 0 ? Fmt.count(count) : "")
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func actionLabel(_ symbol: String, count: Int64, label: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(active ? Color.biliPink : .white)
            Text(count > 0 ? Fmt.count(count) : label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.45), radius: 2)
    }

    /// A thin bar while playing; a draggable slider with times while paused. Both take the same height, so
    /// pausing does not move the overlay.
    private var progress: some View {
        let duration = max(playback.duration, 0.1)
        return ZStack(alignment: .bottom) {
            if playback.isPaused && playback.phase == .ready {
                HStack(spacing: 10) {
                    Text(Self.time(scrubbing ?? playback.position))
                    Slider(value: Binding(get: { scrubbing ?? playback.position },
                                          set: { scrubbing = $0 }),
                           in: 0...duration) { editing in
                        if !editing, let target = scrubbing {
                            playback.seek(to: target)
                            scrubbing = nil
                        }
                    }
                    .tint(.white)
                    Text(Self.time(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 14 + max(safeInsets.leading, safeInsets.trailing))
            } else {
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.25))
                        Rectangle().fill(.white.opacity(0.85))
                            .frame(width: bar.size.width * min(1, max(0, playback.position / duration)))
                    }
                }
                .frame(height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: 32, alignment: .bottom)
    }

    private static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func doubleTap(at location: CGPoint) {
        guard ShortVideoSocial.requireLogin("点赞") else { return }
        let heart = ShortVideoHeart(location: location)
        hearts.append(heart)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { hearts.removeAll { $0.id == heart.id } }
        Task { await social.toggleLike(onlyLike: true) }
    }
}

struct ShortVideoHeart: Identifiable {
    let id = UUID()
    let location: CGPoint
    let tilt = Double.random(in: -18...18)
}

/// The double-tap 点赞 burst.
private struct ShortVideoHeartView: View {
    let heart: ShortVideoHeart
    @State private var shown = false

    var body: some View {
        Image(systemName: "hand.thumbsup.fill")
            .font(.system(size: 72))
            .foregroundStyle(Color.biliPink)
            .shadow(color: .black.opacity(0.3), radius: 4)
            .rotationEffect(.degrees(heart.tilt))
            .scaleEffect(shown ? 1.15 : 0.4)
            .opacity(shown ? 0 : 1)
            .offset(y: shown ? -60 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.85)) { shown = true }
            }
    }
}
