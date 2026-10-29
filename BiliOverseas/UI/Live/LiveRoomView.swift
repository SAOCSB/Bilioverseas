import SwiftUI
import UIKit
import Combine

/// 直播间: HLS player (CDN fallback, 清晰度 / 线路, mute, PiP, landscape fullscreen), room header
/// and the live danmaku chat (WebSocket) with an optional scrolling overlay.
struct LiveRoomView: View {
    @StateObject private var model: LiveRoomModel
    @State private var isFullscreen = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    init(roomId: Int64) {
        _model = StateObject(wrappedValue: LiveRoomModel(roomId: roomId))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                LiveRoomPlayerPanel(model: model, player: model.player, isFullscreen: isFullscreen,
                                    isLandscape: geo.size.width > geo.size.height,
                                    controlsVisible: controlsVisible,
                                    onTap: toggleControls, onInteraction: scheduleHide,
                                    onToggleFullscreen: toggleFullscreen)
                    .frame(width: geo.size.width, height: isFullscreen ? geo.size.height : playerHeight(geo.size))
                if !isFullscreen {
                    LiveRoomInfoPanel(model: model)
                    Divider()
                    LiveRoomChatPanel(chat: model.chat) { model.retryDanmaku() }
                }
            }
        }
        .background(isFullscreen ? Color.black : Color(.systemBackground))
        .ignoresSafeArea(.container, edges: isFullscreen ? .all : [])
        .navigationTitle(isFullscreen ? "" : model.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .task { await model.loadIfNeeded() }
        .onAppear {
            model.viewDidAppear()
            scheduleHide()
        }
        .onDisappear {
            if isFullscreen {
                isFullscreen = false
                OrientationManager.shared.restorePortrait()
            }
            hideTask?.cancel()
            model.viewDidDisappear()
        }
    }

    private func playerHeight(_ size: CGSize) -> CGFloat {
        if model.playInfo?.isPortrait == true { return min(size.height * 0.55, size.width * 16 / 9) }
        return min(size.width * 9 / 16, size.height * 0.5)
    }

    private func toggleFullscreen() {
        if isFullscreen {
            isFullscreen = false
            OrientationManager.shared.restorePortrait()
        } else {
            isFullscreen = true
            // Portrait streams stay portrait (full height); others rotate to landscape.
            if model.playInfo?.isPortrait != true { OrientationManager.shared.enterLandscape() }
        }
        scheduleHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    /// Shows the controls and hides them again after 4 s of playback without interaction.
    private func scheduleHide() {
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.player.phase == .playing else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }
}

// MARK: - Chat store

/// Chat lines, kept apart from the room model so busy rooms only re-render the list
/// (appends are batched every 0.25 s; at most 300 lines are kept).
@MainActor
final class LiveChatStore: ObservableObject {
    @Published private(set) var messages: [LiveDanmakuMessage] = []
    @Published var status: String = ""
    /// The socket gave up (or credentials failed); offer 重连.
    @Published var gaveUp = false

    private var pending: [LiveDanmakuMessage] = []
    private var flushScheduled = false

    func append(_ message: LiveDanmakuMessage) {
        pending.append(message)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var all = messages
        all.append(contentsOf: pending)
        pending.removeAll()
        if all.count > 300 { all.removeFirst(all.count - 200) }
        messages = all
    }
}

// MARK: - Model

@MainActor
final class LiveRoomModel: ObservableObject {
    let requestedRoomId: Int64
    let player = LivePlayerController()
    let chat = LiveChatStore()
    /// Messages for the scrolling overlay.
    let danmakuFeed = PassthroughSubject<LiveDanmakuMessage, Never>()

    @Published private(set) var room: LiveRoom?
    @Published private(set) var playInfo: LivePlayInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var isLive = false
    @Published private(set) var watchedText = ""
    @Published var showsDanmakuOverlay = true

    private var socket: LiveDanmakuSocket?
    private var socketTask: Task<Void, Never>?
    private var didLoad = false
    /// Fresh play-URL requests left after every line failed (reset once playback starts).
    private var refetchBudget = 3
    private var isVisible = false
    private var startOnAppear = false
    private var resumeOnAppear = false
    private var preferredQn: Int

    /// Last chosen live quality (qn); 10000 = 原画.
    private static let qnKey = "bili.live.preferredQn"

    init(roomId: Int64) {
        requestedRoomId = roomId
        let saved = UserDefaults.standard.integer(forKey: LiveRoomModel.qnKey)
        preferredQn = saved > 0 ? saved : 10000
        showsDanmakuOverlay = AppSettings.shared.danmaku.enabled
        player.onExhausted = { [weak self] in self?.handleExhausted() }
        player.onPlaying = { [weak self] in self?.refetchBudget = 3 }
    }

    /// The real room id (short ids resolve through getRoomPlayInfo / getH5InfoByRoom).
    var roomId: Int64 {
        if let r = playInfo?.roomId, r != 0 { return r }
        if let r = room?.roomId, r != 0 { return r }
        return requestedRoomId
    }

    var anchorMid: Int64 {
        if let uid = room?.uid, uid != 0 { return uid }
        return playInfo?.uid ?? 0
    }

    var navigationTitle: String {
        if let name = room?.uname, !name.isEmpty { return "\(name)的直播间" }
        return "直播间"
    }

    var coverURL: String {
        guard let room else { return "" }
        return room.cover.isEmpty ? room.keyframe : room.cover
    }

    var qualities: [LiveQualityOption] { playInfo?.qualities ?? [] }

    var currentQualityName: String {
        guard let qn = playInfo?.currentQn, qn != 0 else { return "画质" }
        return qualities.first { $0.qn == qn }?.desc ?? LiveAPI.qnName(qn)
    }

    // MARK: Loading

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func reload() async {
        refetchBudget = 3
        await load()
    }

    private func load() async {
        isLoading = true
        loadError = nil
        let (roomResult, playResult) = await LiveRoomModel.fetch(roomId: requestedRoomId, qn: preferredQn)
        isLoading = false
        if case .success(let r) = roomResult {
            room = r
            if !r.watchedText.isEmpty { watchedText = r.watchedText }
        }
        switch playResult {
        case .success(let info):
            apply(info)
        case .failure(let error):
            if ListMapping.isCancellation(error) {
                didLoad = false
                return
            }
            if case .success(let r) = roomResult, !r.isLive {
                isLive = false
                player.stop()
            } else {
                loadError = error.localizedDescription
            }
        }
        startDanmakuIfNeeded()
    }

    private nonisolated static func fetch(roomId: Int64, qn: Int) async
        -> (Result<LiveRoom, Error>, Result<LivePlayInfo, Error>) {
        async let r = ListMapping.capture { try await LiveAPI.roomInfo(roomId: roomId) }
        async let p = ListMapping.capture { try await LiveAPI.playURL(roomId: roomId, qn: qn) }
        return (await r, await p)
    }

    private func apply(_ info: LivePlayInfo) {
        playInfo = info
        isLive = info.isLive
        loadError = nil
        guard info.isLive else {
            player.stop()
            return
        }
        guard !info.urls.isEmpty else {
            player.stop()
            loadError = "暂无可播放的直播流"
            return
        }
        if isVisible || player.isPiPActive {
            player.play(urls: info.urls)
        } else {
            startOnAppear = true
        }
    }

    /// Every CDN line failed: the URLs are short-lived, so request fresh ones (up to 3 times).
    private func handleExhausted() {
        guard refetchBudget > 0 else { return }
        refetchBudget -= 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.refetchPlayURL(qn: nil, announce: false)
        }
    }

    private func refetchPlayURL(qn: Int?, announce: Bool) async {
        do {
            let info = try await LiveAPI.playURL(roomId: roomId, qn: qn ?? preferredQn)
            apply(info)
            if announce, let qn, info.isLive, info.currentQn != 0, info.currentQn != qn {
                ToastCenter.shared.show("该清晰度暂不可用，已切换为\(LiveAPI.qnName(info.currentQn))")
            }
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
        }
    }

    func switchQuality(_ qn: Int) {
        guard qn != playInfo?.currentQn else { return }
        preferredQn = qn
        UserDefaults.standard.set(qn, forKey: LiveRoomModel.qnKey)
        refetchBudget = 3
        Task { await refetchPlayURL(qn: qn, announce: true) }
    }

    // MARK: Visibility

    func viewDidAppear() {
        isVisible = true
        UIApplication.shared.isIdleTimerDisabled = true
        if startOnAppear {
            startOnAppear = false
            resumeOnAppear = false
            if let info = playInfo, info.isLive, !info.urls.isEmpty { player.play(urls: info.urls) }
        } else if resumeOnAppear {
            resumeOnAppear = false
            player.resume()
        }
        if let socket, !socket.isRunning, !chat.gaveUp { socket.start() }
    }

    /// Pushing another page (or popping) pauses playback and closes the socket, unless PiP is on.
    func viewDidDisappear() {
        isVisible = false
        UIApplication.shared.isIdleTimerDisabled = false
        guard !player.isPiPActive else { return }
        if player.wantsPlay {
            resumeOnAppear = true
            player.pause()
        }
        socket?.stop()
    }

    // MARK: Danmaku

    private func startDanmakuIfNeeded() {
        guard socket == nil, socketTask == nil else { return }
        let rid = roomId
        chat.status = "连接中…"
        chat.gaveUp = false
        socketTask = Task { [weak self] in
            let result = await ListMapping.capture { try await LiveAPI.danmuInfo(roomId: rid) }
            guard let self else { return }
            self.socketTask = nil
            switch result {
            case .success(let info):
                let s = LiveDanmakuSocket(roomId: rid, uid: BiliHTTP.shared.mid ?? 0, info: info)
                s.onEvent = { [weak self] event in self?.handle(event) }
                self.socket = s
                if self.isVisible || self.player.isPiPActive { s.start() }
            case .failure(let error):
                if ListMapping.isCancellation(error) { return }
                self.chat.status = "弹幕连接失败"
                self.chat.gaveUp = true
            }
        }
    }

    /// 重连: new credentials (the token may have expired) and a new socket.
    func retryDanmaku() {
        socket?.stop()
        socket = nil
        socketTask?.cancel()
        socketTask = nil
        startDanmakuIfNeeded()
    }

    private func handle(_ event: LiveDanmakuEvent) {
        switch event {
        case .connecting:
            chat.status = "连接中…"
            chat.gaveUp = false
        case .connected:
            chat.status = "已连接"
            chat.gaveUp = false
        case .disconnected(let reason):
            if let reason {
                chat.status = reason
                chat.gaveUp = true
            } else {
                chat.status = "重连中…"
            }
        case .message(let m):
            chat.append(m)
            if showsDanmakuOverlay && isLive { danmakuFeed.send(m) }
        case .watched(let text):
            watchedText = text
        case .liveStarted:
            if !isLive {
                refetchBudget = 3
                Task { await refetchPlayURL(qn: nil, announce: false) }
            }
        case .liveEnded:
            if isLive {
                isLive = false
                player.stop()
                ToastCenter.shared.show("直播已结束")
            }
        case .titleChanged(let title):
            room?.title = title
        }
    }
}

// MARK: - Player panel

struct LiveRoomPlayerPanel: View {
    @ObservedObject var model: LiveRoomModel
    @ObservedObject var player: LivePlayerController
    let isFullscreen: Bool
    let isLandscape: Bool
    let controlsVisible: Bool
    let onTap: () -> Void
    let onInteraction: () -> Void
    let onToggleFullscreen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            LivePlayerSurface(controller: player)
            if showsCover { cover }
            if model.showsDanmakuOverlay && model.isLive {
                LiveDanmakuOverlay(feed: model.danmakuFeed, isFullscreen: isFullscreen)
                    .allowsHitTesting(false)
                    .padding(.top, isFullscreen ? 12 : 4)
            }
            centerStatus
            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var showsCover: Bool {
        guard model.room != nil else { return false }
        return !model.isLive || (model.isLoading && player.phase == .idle)
    }

    private var cover: some View {
        ZStack {
            if !model.coverURL.isEmpty {
                RemoteImage(url: model.coverURL, width: 480)
                Color.black.opacity(0.5)
            }
            if !model.isLive && !model.isLoading && model.loadError == nil {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 30))
                    Text("未开播")
                        .font(.headline)
                    if model.room?.liveStatus == 2 {
                        Text("轮播中")
                            .font(.caption)
                            .opacity(0.8)
                    }
                }
                .foregroundColor(.white)
            }
        }
    }

    private var errorText: String? {
        if let e = model.loadError { return e }
        if case .failed(let message) = player.phase, model.isLive { return message }
        return nil
    }

    @ViewBuilder private var centerStatus: some View {
        if let error = errorText {
            VStack(spacing: 10) {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Button {
                    onInteraction()
                    Task { await model.reload() }
                } label: {
                    Text("重试")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding()
        } else if model.isLoading || (model.isLive && player.wantsPlay && (player.isBuffering || player.phase == .loading)) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        } else if model.isLive && !player.wantsPlay && !controlsVisible {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            if isFullscreen {
                HStack(spacing: 12) {
                    Button(action: onToggleFullscreen) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.room?.title ?? "")
                            .font(.headline)
                            .lineLimit(1)
                        if !model.watchedText.isEmpty {
                            Text(model.watchedText)
                                .font(.caption)
                                .opacity(0.8)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            }

            Spacer(minLength: 0)

            HStack(spacing: isFullscreen ? 22 : 16) {
                if model.isLive {
                    Button { act { player.togglePlay() } } label: {
                        Image(systemName: player.wantsPlay ? "pause.fill" : "play.fill")
                    }
                }
                Button { act { Task { await model.reload() } } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                if model.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("直播中").font(.caption.weight(.medium))
                    }
                }
                Spacer(minLength: 0)
                Button { act { model.showsDanmakuOverlay.toggle() } } label: {
                    LiveDanmakuToggleIcon(isOn: model.showsDanmakuOverlay)
                }
                if model.isLive && !model.qualities.isEmpty {
                    qualityMenu
                }
                Button { act { player.setMuted(!player.isMuted) } } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                if LivePlayerController.supportsPiP && model.isLive {
                    Button { act { player.togglePiP() } } label: {
                        Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter")
                    }
                    .disabled(!player.isPiPPossible && !player.isPiPActive)
                }
                Button { act(onToggleFullscreen) } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 28)
            .padding(.bottom, isFullscreen ? 18 : 8)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundColor(.white)
        .buttonStyle(.plain)
    }

    /// Clears the notch / rounded corners in landscape fullscreen.
    private var horizontalPadding: CGFloat {
        guard isFullscreen else { return 12 }
        return isLandscape ? 48 : 20
    }

    private var qualityMenu: some View {
        Menu {
            Section("清晰度") {
                ForEach(model.qualities) { q in
                    Button {
                        onInteraction()
                        model.switchQuality(q.qn)
                    } label: {
                        if q.qn == model.playInfo?.currentQn {
                            Label(q.desc, systemImage: "checkmark")
                        } else {
                            Text(q.desc)
                        }
                    }
                }
            }
            if player.urls.count > 1 {
                Section("线路") {
                    ForEach(Array(player.urls.indices), id: \.self) { i in
                        Button {
                            onInteraction()
                            player.switchLine(i)
                        } label: {
                            if i == player.urlIndex {
                                Label("线路 \(i + 1)", systemImage: "checkmark")
                            } else {
                                Text("线路 \(i + 1)")
                            }
                        }
                    }
                }
            }
        } label: {
            Text(model.currentQualityName)
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
    }

    private func act(_ action: () -> Void) {
        action()
        onInteraction()
    }
}

/// 「弹」 toggle icon for the scrolling danmaku overlay.
struct LiveDanmakuToggleIcon: View {
    let isOn: Bool

    var body: some View {
        Text("弹")
            .font(.system(size: 12, weight: .bold))
            .frame(width: 22, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: 1.3))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isOn ? .biliPink : .gray)
                    .background(Circle().fill(Color.white).padding(1))
                    .offset(x: 4, y: 4)
            }
            .opacity(isOn ? 1 : 0.75)
    }
}

// MARK: - Info panel

/// Anchor (avatar → space), title, 人气 / area, room number.
struct LiveRoomInfoPanel: View {
    @ObservedObject var model: LiveRoomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                anchorLink {
                    AvatarView(url: model.room?.face ?? "", size: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    anchorLink {
                        Text(verbatim: model.room?.uname.isEmpty == false ? model.room!.uname : " ")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(model.isLive ? "直播中" : "未开播")
                    .font(.caption.weight(.medium))
                    .foregroundColor(model.isLive ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(model.isLive ? Color.biliPink : Color(.secondarySystemFill), in: Capsule())
            }
            if let title = model.room?.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.headline)
                    .lineLimit(2)
            }
            Text(verbatim: "房间号 \(model.roomId)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        guard let room = model.room else { return model.watchedText }
        let area = [room.parentAreaName, room.areaName].filter { !$0.isEmpty }.joined(separator: "·")
        return [model.watchedText, area].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    @ViewBuilder
    private func anchorLink<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if model.anchorMid != 0 {
            NavigationLink(value: Route.user(mid: model.anchorMid)) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

// MARK: - Chat panel

struct LiveRoomChatPanel: View {
    @ObservedObject var chat: LiveChatStore
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("弹幕")
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: chat.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if chat.gaveUp {
                    Button("重连", action: onRetry)
                        .font(.caption.weight(.medium))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chat.messages) { message in
                            LiveChatRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .overlay {
                    if chat.messages.isEmpty {
                        Text("还没有弹幕哦~")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: chat.messages.last?.id) { id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct LiveChatRow: View {
    let message: LiveDanmakuMessage

    var body: some View {
        if message.kind == .superChat {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: message.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(verbatim: "¥\(message.price)")
                        .font(.caption.weight(.bold))
                }
                Text(verbatim: message.text)
                    .font(.subheadline)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        } else {
            (Text(verbatim: (message.name.isEmpty ? "匿名" : message.name) + "：").foregroundColor(.secondary)
                + Text(verbatim: message.text).foregroundColor(.primary))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
