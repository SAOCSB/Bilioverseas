import SwiftUI
import UIKit

// MARK: - Contract view

/// Inline player area with full controls, gestures, danmaku, SmartSkip prompts, subtitles and the stats overlay.
/// Presents / handles fullscreen itself (the same surface moves into a fullscreen hosting controller).
struct PlayerContainerView: View {
    let controller: PlayerController

    init(controller: PlayerController) {
        self.controller = controller
    }

    var body: some View {
        PlayerStageView(controller: controller, overlay: controller.overlay, role: .inline)
            .onAppear { controller.containerDidAppear() }
            .onDisappear { controller.containerDidDisappear() }
    }
}

// MARK: - Stage (inline or fullscreen)

struct PlayerStageView: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var overlay: PlayerOverlayModel
    let role: PlayerStageRole

    /// The controls (and sheets) live in exactly one stage at a time: the fullscreen one while fullscreen.
    private var isActive: Bool { (role == .fullscreen) == controller.isFullscreen }

    var body: some View {
        GeometryReader { geo in
            PlayerStageContent(controller: controller, overlay: overlay, role: role, measured: geo.size,
                               safeArea: geo.safeAreaInsets)
        }
        // The keyboard of 发弹幕 comes up in a sheet: the video stays where it is behind that.
        .ignoresSafeArea(role == .fullscreen ? .keyboard : [])
        .sheet(item: sheetBinding) { sheet in
            PlayerSheetHost(controller: controller, sheet: sheet)
        }
    }

    private var sheetBinding: Binding<PlayerSheet?> {
        Binding(get: { isActive ? overlay.sheet : nil },
                set: { overlay.sheet = $0 })
    }
}

/// What the stage draws at the size it measured. A view of its own that observes the controller itself: what a
/// GeometryReader's closure reads of it stays as it was when the size last changed.
private struct PlayerStageContent: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var overlay: PlayerOverlayModel
    let role: PlayerStageRole
    let measured: CGSize
    let safeArea: EdgeInsets

    private var isActive: Bool { (role == .fullscreen) == controller.isFullscreen }
    /// The video and what is drawn with it (cover, subtitles, loading / error) are in the stage holding the surface,
    /// which is still the fullscreen one while it turns back after leaving fullscreen.
    private var holdsSurface: Bool { (role == .fullscreen) == controller.surfaceInFullscreen }
    private var ignoredEdges: Edge.Set { role == .fullscreen ? .all : [] }

    var body: some View {
        // The vertical-video screen: the picture stays between the status bar and the bar below it. This goes by
        // the whole window, as the safe area depends on that status bar.
        let verticalScreen = role == .fullscreen && controller.isVerticalVideo
            && measured.height + safeArea.top + safeArea.bottom > measured.width
        let gap = verticalScreen ? VerticalVideoMetrics.statusBarGap : 0
        let size = CGSize(width: measured.width, height: measured.height + gap)
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea(edges: ignoredEdges)
            PlayerSurfaceRepresentable(controller: controller, role: role)
                .frame(height: verticalScreen ? max(size.height - VerticalVideoMetrics.bottomBarHeight, 0) : nil)
                .ignoresSafeArea(edges: verticalScreen ? [] : ignoredEdges)
            if isActive || holdsSurface {
                PlayerChromeView(controller: controller, overlay: overlay, size: size,
                                 fullscreen: role == .fullscreen, verticalScreen: verticalScreen,
                                 showsPicture: holdsSurface && !controller.isVideoSwipeActive,
                                 showsControls: isActive)
            }
        }
        .frame(width: size.width, height: size.height)
        .offset(y: -gap)
        .onAppear { stageChanged(verticalScreen: verticalScreen) }
        .onChange(of: verticalScreen) { stageChanged(verticalScreen: $0) }
    }

    private func stageChanged(verticalScreen: Bool) {
        if role == .fullscreen { controller.fullscreenStageChanged(verticalScreen: verticalScreen) }
    }
}

struct PlayerSheetHost: View {
    let controller: PlayerController
    let sheet: PlayerSheet

    var body: some View {
        switch sheet {
        case .danmakuSettings:
            DanmakuQuickPanel(fullscreen: controller.isFullscreen)
        case .danmakuSend:
            if let item = controller.item {
                DanmakuSendSheet(aid: item.aid, cid: item.cid,
                                 currentTime: { controller.displayTime() },
                                 isClosed: controller.surface.danmaku.isClosedByUploader,
                                 onSent: { controller.surface.danmaku.insertLocal($0) })
            } else {
                StateMessageView(systemImage: "text.bubble", message: "视频加载中，请稍后再试")
            }
        case .playerSettings:
            PlayerSettingsSheet()
        case .accelerationSettings:
            PlayerAccelerationSettingsSheet()
        case .danmakuList:
            DanmakuListView(player: controller)
        case .menu(let panel):
            PlayerMenuSheet(controller: controller, root: panel)
        case .page(let id):
            if let page = controller.pageSheet, page.id == id {
                page.content
            }
        }
    }
}

// MARK: - Chrome

/// Everything drawn over the video: `showsPicture` the layers that go with the picture, `showsControls` the rest
/// (both, except in the moment a stage holds the video without the controls, see `PlayerStageView`).
struct PlayerChromeView: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var overlay: PlayerOverlayModel
    @ObservedObject private var settings = AppSettings.shared
    let size: CGSize
    let fullscreen: Bool
    var verticalScreen = false
    var showsPicture = true
    var showsControls = true

    @State private var verticalTitleExpanded = false

    private var compact: Bool { size.width < 520 }
    private var landscape: Bool { size.width > size.height }
    private var bottomBarHeight: CGFloat { fullscreen ? 88 : 44 }
    /// The surface's height (`PlayerStageView`), which is what most layers go over.
    private var pictureHeight: CGFloat {
        verticalScreen ? max(size.height - VerticalVideoMetrics.bottomBarHeight, 0) : size.height
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if showsPicture {
                    coverLayer
                    subtitleLayer
                    centerLayer
                }
                if showsControls {
                    hudLayer
                    promptLayer
                    controlsLayer
                    statsLayer
                }
            }
            .frame(width: size.width, height: pictureHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            if showsControls {
                if verticalScreen { verticalBottomBar }
                panelLayer
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: controller.item?.cid) { _ in verticalTitleExpanded = false }
        .animation(.easeOut(duration: 0.15), value: controller.isVideoSwipeActive)
        .animation(.easeOut(duration: 0.15), value: overlay.danmakuBubbleOpen)
        .animation(.easeInOut(duration: 0.2), value: overlay.controlsVisible)
        .animation(.easeInOut(duration: 0.15), value: controller.isBoosting)
        .animation(.easeInOut(duration: 0.25), value: overlay.panel)
        .animation(.easeInOut(duration: 0.25), value: controller.skipPrompt?.segment.id)
    }

    private func act(_ action: () -> Void) {
        overlay.poke()
        action()
    }

    private func open(_ panel: PlayerPanel) {
        overlay.poke()
        overlay.open(panel, fullscreen: fullscreen)
    }

    // MARK: Layers

    @ViewBuilder
    private var coverLayer: some View {
        let listening = controller.audioOnlyStream != nil
        if !controller.hasFirstFrame || listening, let cover = controller.item?.cover, !cover.isEmpty {
            RemoteImage(url: cover, width: 640, contentMode: .fill)
                .frame(width: size.width, height: pictureHeight)
                .clipped()
                .overlay(Color.black.opacity(listening ? 0.45 : 0.25))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
        // 听视频: the cover stands in for the picture (the spinner takes the centre while loading).
        if listening, controller.status == .playing || controller.status == .paused {
            VStack(spacing: 6) {
                Image(systemName: "headphones")
                    .font(.system(size: fullscreen ? 30 : 24, weight: .medium))
                Text("听视频中")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.85))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var subtitleLayer: some View {
        if let text = controller.subtitleText {
            // 「字幕设置」 style (PlayerSurfaceView.swift).
            PlayerSubtitleView(text: text, style: settings.player, fullscreen: fullscreen,
                               minBottom: verticalScreen ? VerticalVideoMetrics.infoHeight
                                   : showsControls && overlay.controlsVisible ? bottomBarHeight + 6 : 0)
        }
    }

    @ViewBuilder
    private var centerLayer: some View {
        // A swipe pauses the video it leaves on the way, which is not the viewer pausing it.
        if controller.isVideoSwipeActive {
            EmptyView()
        } else if controller.isSwitchingBySwipe {
            // The page goes on by itself: nothing slides in to show that something is coming.
            PlayerQuietSpinner(waitBegan: controller.waitBegan)
        } else {
            switch controller.status {
            case .failed(let message):
                PlayerErrorView(message: message) { controller.retry() }
            case .ended:
                if !overlay.isLocked { replayButton }
            case .loading, .buffering:
                if controller.status == .loading || controller.wantsToPlay {
                    if controller.isVerticalVideo {
                        PlayerQuietSpinner(waitBegan: controller.status == .loading ? controller.waitBegan : nil)
                    } else {
                        PlayerBufferingView(text: bufferingText)
                    }
                }
            case .paused:
                // 听视频 has its own label there.
                if verticalScreen, overlay.seekPreview == nil, controller.audioOnlyStream == nil {
                    PlayerVerticalPausedHint(timeline: controller.timeline)
                }
            default:
                EmptyView()
            }
        }
    }

    private var bufferingText: String {
        if let message = controller.transientMessage { return message }
        return controller.networkSpeed > 0 ? Fmt.speed(controller.networkSpeed) : "加载中..."
    }

    private var replayButton: some View {
        Button {
            controller.play()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .semibold))
                Text("重新播放")
                    .font(.system(size: 12))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var hudLayer: some View {
        if let hint = overlay.doubleTapHint {
            PlayerDoubleTapIndicator(hint: hint, size: size)
                .transition(.opacity)
        }
        if controller.isBoosting {
            PlayerPill {
                HStack(spacing: 4) {
                    Image(systemName: "forward.fill").font(.system(size: 11))
                    Text("\(PlayerFormat.rate(Double(controller.playerRate)))倍速中")
                }
            }
            .padding(.top, fullscreen ? 56 : 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        if let preview = overlay.seekPreview {
            seekPreviewView(preview)
        }
        if let hud = overlay.levelHUD {
            PlayerLevelPill(hud: hud)
        }
        if let hint = overlay.hint {
            PlayerPill { Text(hint) }
                .padding(.top, fullscreen ? 96 : 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        ForEach(overlay.likeBursts) { burst in
            VerticalVideoLikeBurstView(burst: burst)
                .position(burst.location)
        }
    }

    private func seekPreviewView(_ preview: PlayerSeekPreview) -> some View {
        VStack(spacing: 8) {
            if let shot = controller.videoShot, !preview.cancelled {
                PlayerSeekThumbnail(shot: shot, time: preview.target, height: thumbnailHeight)
            }
            // The chapter the target falls into (分段信息).
            if let chapter = controller.chapters.last(where: { $0.from <= preview.target }), !chapter.title.isEmpty,
               !preview.cancelled {
                Text(chapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(maxWidth: min(size.width - 48, 360))
            }
            PlayerPill {
                Text("\(PlayerFormat.time(preview.target))/\(PlayerFormat.time(preview.duration))")
                    .monospacedDigit()
            }
            .opacity(preview.cancelled ? 0.5 : 1)
        }
        .allowsHitTesting(false)
    }

    /// 81 pt (portrait / vertical) or 108 pt (landscape fullscreen), capped at height − 140 when that is > 50.
    private var thumbnailHeight: CGFloat {
        let base: CGFloat = fullscreen && landscape ? 108 : 81
        let cap = size.height - 140
        return cap > 50 ? min(base, cap) : base
    }

    @ViewBuilder
    private var promptLayer: some View {
        let bottom = verticalScreen ? VerticalVideoMetrics.infoHeight + 10
            : (overlay.controlsVisible ? bottomBarHeight : 0) + size.height * 0.1
        // The vertical-video screen has its buttons down the right.
        let trailing: CGFloat = verticalScreen ? 70 : 24
        if !overlay.isLocked, let prompt = controller.skipPrompt {
            SmartSkipPromptView(segment: prompt.segment, remaining: prompt.remaining,
                                total: Double(settings.smartSkip.countdownSeconds),
                                onSkip: { controller.smartSkipTapped(prompt.segment) },
                                onDismiss: { controller.smartSkipDismissed(prompt.segment) },
                                onInteractionChanged: { controller.smartSkipInteraction($0) })
                .padding(.trailing, trailing)
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if !overlay.isLocked, let clip = controller.clipPrompt {
            PlayerClipSkipButton(title: PlayerController.clipTitle(clip),
                                 onSkip: { controller.skipClip() },
                                 onDismiss: { controller.dismissClip() })
                .padding(.trailing, trailing)
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        if !overlay.isLocked, controller.resumeChipTime != nil || controller.resumePartPrompt != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let prompt = controller.resumePartPrompt {
                    PlayerResumePartChip(page: prompt.page,
                                         onJump: { controller.acceptResumePart() },
                                         onDismiss: { controller.dismissResumePart() })
                }
                if let time = controller.resumeChipTime {
                    PlayerResumeChip(time: time,
                                     onRestart: { controller.restartFromBeginning() },
                                     onDismiss: { controller.dismissResumeChip() })
                }
            }
            .padding(.leading, fullscreen ? 24 : 10)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var controlsLayer: some View {
        if verticalScreen {
            verticalControls
        } else {
            regularControls
        }
    }

    @ViewBuilder
    private var regularControls: some View {
        if overlay.controlsVisible, !overlay.isLocked {
            VStack(spacing: 0) {
                topBar
                if fullscreen, let actions = controller.fullscreenActions {
                    PlayerFullscreenActionRow(actions: actions, onInteraction: { overlay.poke() })
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(.trailing, compact ? 8 : 16)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .transition(.opacity)
        }
        if fullscreen, (overlay.isLocked ? overlay.lockButtonVisible : overlay.controlsVisible) {
            lockButton
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .transition(.opacity)
        }
        if !overlay.controlsVisible || overlay.isLocked, settings.player.thinProgressMode.shows(fullscreen: fullscreen) {
            PlayerThinProgress(timeline: controller.timeline, segments: visibleSegments, clips: visibleClips)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// SmartSkip strips only while 广告跳过 is on (the analysis is kept for when it is turned on again).
    private var visibleSegments: [AdSegment] { settings.smartSkip.enabled ? controller.adSegments : [] }

    /// 片头/片尾 strips unless 「番剧片头/片尾」 is 禁用.
    private var visibleClips: [PGCClipInfo] { settings.player.pgcSkipType == .disabled ? [] : controller.pgcClips }

    @ViewBuilder
    private var statsLayer: some View {
        if let stats = controller.stats, !overlay.isLocked {
            PlayerStatsOverlay(stats: stats, stream: controller.currentStreamDescription)
                .padding(.top, verticalScreen ? VerticalVideoMetrics.topBarHeight + 8
                            : overlay.controlsVisible ? (fullscreen ? 60 : 40) : 8)
                .padding(.leading, fullscreen && !verticalScreen ? 64 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var panelLayer: some View {
        if fullscreen, let panel = overlay.panel {
            ZStack(alignment: landscape ? .trailing : .bottom) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { overlay.panel = nil }
                PlayerMenuPanel(controller: controller, overlay: overlay, panel: panel)
                    .frame(width: landscape ? min(360, size.width * 0.42) : size.width,
                           height: landscape ? size.height : size.height * 0.55)
                    .background(Color.black.opacity(0.88).ignoresSafeArea())
                    .transition(.move(edge: landscape ? .trailing : .bottom))
            }
        }
    }

    // MARK: Vertical-video screen

    /// `VerticalVideoViews.swift`. Nothing here hides by itself; while a swipe goes to another video only the top bar stays.
    private var verticalControls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .opacity(controller.isVideoSwipeActive ? 0 : 1)
            VStack(spacing: 0) {
                VerticalVideoTopBar(online: controller.onlineCount, onBack: { controller.fullscreenBack() },
                                    onSearch: controller.pageRouter.map { router in { router.push(.searchHome) } }) {
                    Button { open(.more) } label: {
                        VerticalVideoBarIcon(systemName: "ellipsis", upright: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("更多设置"))
                }
                Spacer(minLength: 0)
                verticalPageControls
            }
        }
    }

    private var verticalPageControls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                // A downloaded video has no page behind it: only its title.
                VerticalVideoInfoView(actions: controller.fullscreenActions ?? PlayerFullscreenActions(),
                                      title: controller.item?.title ?? "", expanded: $verticalTitleExpanded)
                if let actions = controller.fullscreenActions {
                    VerticalVideoActionColumn(actions: actions)
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, -VerticalVideoMetrics.progressOverlap)
            .modifier(PlayerVerticalSwipeThrough(controller: controller))
            makeProgressBar(barHeight: 2, height: 22, verticalScreenStyle: true)
                // A drag under way ends with its video.
                .id(controller.item?.cid)
                .padding(.horizontal, 12)
                .offset(y: VerticalVideoMetrics.progressOverhang)
        }
        .opacity(controller.isVideoSwipeActive || overlay.danmakuBubbleOpen ? 0 : 1)
        .allowsHitTesting(!controller.isSwitchingBySwipe && !overlay.danmakuBubbleOpen)
    }

    private var verticalBottomBar: some View {
        VerticalVideoBottomBar(danmakuOn: settings.danmaku.enabled,
                               onSend: { overlay.sheet = .danmakuSend },
                               onToggle: { controller.toggleDanmaku() },
                               onDetail: { controller.exitFullscreen() },
                               onSettings: { overlay.sheet = .danmakuSettings })
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 4) {
            if fullscreen {
                PlayerIconButton(systemName: "chevron.left", size: 18, label: "返回") { controller.fullscreenBack() }
                titleBlock
                Spacer(minLength: 8)
                if !compact { PlayerFullscreenStatusView() }
                PlayerIconButton(systemName: "slider.horizontal.3", size: 17, label: "弹幕设置") {
                    act { overlay.sheet = .danmakuSettings }
                }
            } else {
                Spacer(minLength: 0)
            }
            if controller.supportsPiP {
                PlayerIconButton(systemName: controller.isPiPActive ? "pip.exit" : "pip.enter", size: 17,
                                 label: controller.isPiPActive ? "退出画中画" : "画中画") {
                    act { controller.togglePiP() }
                }
            }
            PlayerIconButton(systemName: "ellipsis", size: 18, label: "更多设置") { open(.more) }
        }
        .padding(.horizontal, fullscreen ? 12 : 6)
        .padding(.top, fullscreen ? 6 : 2)
        .padding(.bottom, 14)
        .background(
            // Fullscreen: run under the notch / rounded corners too (the bar itself stays in the safe area).
            LinearGradient(colors: [Color.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: fullscreen ? .all : [])
                .allowsHitTesting(false)
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.item?.title ?? "")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            let secondLine = [controller.item?.subtitle ?? "", controller.onlineCount ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
            if !secondLine.isEmpty {
                Text(secondLine)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        // A tap on the (wide) title area should toggle the controls like the rest of the video.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if fullscreen {
            fullscreenBottomBar
        } else {
            inlineBottomBar
        }
    }

    private var inlineBottomBar: some View {
        HStack(spacing: 4) {
            playButton
            progressBar
            PlayerTimeText(timeline: controller.timeline, style: .combined, overrideTime: overlay.seekPreview?.target)
            danmakuToggle
            if !controller.subtitleTracks.isEmpty, size.width >= 400 {
                subtitleIconButton
            }
            PlayerTextButton(title: speedTitle, highlighted: controller.isBoosting || controller.rate != 1,
                             fontSize: 12) { open(.speed) }
            PlayerIconButton(systemName: "arrow.up.left.and.arrow.down.right", size: 15, width: 32, label: "全屏") {
                act { controller.enterFullscreen() }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var fullscreenBottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PlayerTimeText(timeline: controller.timeline, style: .current, overrideTime: overlay.seekPreview?.target)
                progressBar
                PlayerTimeText(timeline: controller.timeline, style: .total)
            }
            HStack(spacing: compact ? 4 : 12) {
                playButton
                // The vertical-video bar has no room: 上一集 / 分段 / 选集 are in ⋮ there.
                if controller.hasPrevious, !compact {
                    PlayerIconButton(systemName: "backward.end.fill", size: 18, label: "上一集") {
                        act { controller.onPrevious?() }
                    }
                }
                if controller.hasNext {
                    PlayerIconButton(systemName: "forward.end.fill", size: 18, label: "下一集") {
                        act { controller.onNext?() }
                    }
                }
                danmakuToggle
                danmakuInput
                Spacer(minLength: 4)
                if !controller.chapters.isEmpty, !compact {
                    PlayerTextButton(title: "分段") { open(.chapters) }
                }
                if controller.episodeEntries.count > 1, !compact {
                    PlayerTextButton(title: "选集") { open(.episodes) }
                }
                if !controller.subtitleTracks.isEmpty {
                    PlayerTextButton(title: "字幕", highlighted: controller.selectedSubtitleId != nil) { open(.subtitle) }
                }
                PlayerTextButton(title: fullscreenSpeedTitle,
                                 highlighted: controller.isBoosting || controller.rate != 1) { open(.speed) }
                if let quality = currentQualityEntry {
                    PlayerTextButton(title: quality.shortTitle) { open(.quality) }
                }
                PlayerIconButton(systemName: "arrow.down.right.and.arrow.up.left", size: 15, label: "退出全屏") {
                    act { controller.exitFullscreen() }
                }
            }
        }
        // Vertical-video fullscreen on a 375 pt phone with 下一集 + 字幕 + 1.25X + 1080P+ overflowed by ~7 pt at 16.
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.top, 20)
        .padding(.bottom, 2)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .all)
                .allowsHitTesting(false)
        )
    }

    // MARK: Controls

    private var playIcon: String {
        if controller.status == .ended { return "arrow.counterclockwise" }
        return controller.wantsToPlay ? "pause.fill" : "play.fill"
    }

    private var playButton: some View {
        let label = controller.status == .ended ? "重新播放" : (controller.wantsToPlay ? "暂停" : "播放")
        return PlayerIconButton(systemName: playIcon, size: fullscreen ? 22 : 18, label: label) {
            act { controller.togglePlay() }
        }
    }

    private var progressBar: some View {
        makeProgressBar()
    }

    private func makeProgressBar(barHeight: CGFloat = 3, height: CGFloat = 28,
                                 verticalScreenStyle: Bool = false) -> some View {
        PlayerProgressBar(timeline: controller.timeline, chapters: controller.chapters,
                          segments: visibleSegments, clips: visibleClips,
                          barHeight: barHeight, height: height, verticalScreenStyle: verticalScreenStyle,
                          onVerticalDragMoved: { offset in
                              if controller.canSwipeVideos, !controller.isSwitchingBySwipe {
                                  controller.videoSwipeMoved(offset: offset)
                              }
                          },
                          onVerticalDragEnded: { offset, velocity in
                              controller.videoSwipeEnded(offset: offset, velocity: velocity)
                          },
                          onScrubBegan: {
                              overlay.beginHold()
                              controller.ensureVideoShot()
                          },
                          onScrubChanged: { target in
                              overlay.seekPreview = PlayerSeekPreview(target: target, duration: controller.duration,
                                                                      delta: 0, cancelled: false)
                          },
                          onScrubEnded: { target in
                              overlay.seekPreview = nil
                              overlay.endHold()
                              controller.seek(to: target)
                          },
                          onScrubCancelled: {
                              overlay.seekPreview = nil
                              overlay.endHold()
                          })
    }

    private var danmakuToggle: some View {
        Button {
            act { controller.toggleDanmaku() }
        } label: {
            PlayerDanmakuToggleIcon(enabled: settings.danmaku.enabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(settings.danmaku.enabled ? "关闭弹幕" : "开启弹幕"))
    }

    private var danmakuInput: some View {
        Button {
            act { overlay.sheet = .danmakuSend }
        } label: {
            if compact {
                Image(systemName: "text.bubble")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            } else {
                Text("发个友善的弹幕见证当下")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 260, minHeight: 30, maxHeight: 30, alignment: .leading)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("发弹幕"))
    }

    private var subtitleIconButton: some View {
        PlayerIconButton(systemName: controller.selectedSubtitleId == nil ? "captions.bubble" : "captions.bubble.fill",
                         size: 16, width: 32, label: "字幕") { open(.subtitle) }
    }

    private var speedTitle: String {
        "\(PlayerFormat.rate(Double(controller.playerRate)))X"
    }

    private var fullscreenSpeedTitle: String {
        controller.effectiveRate == 1 ? "倍速" : speedTitle
    }

    private var currentQualityEntry: PlayerQualityEntry? {
        controller.qualityEntries.first { $0.qn == controller.currentQuality }
    }

    private var lockButton: some View {
        Button {
            overlay.toggleLock()
        } label: {
            Image(systemName: overlay.isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.27), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(overlay.isLocked ? "解锁" : "锁定"))
    }
}

/// The vertical-video screen's paused hint, with the player's position.
private struct PlayerVerticalPausedHint: View {
    @ObservedObject var timeline: PlayerTimeline

    var body: some View {
        let snap = timeline.snapshot
        VerticalVideoPausedHint(time: "\(PlayerFormat.time(snap.time)) / \(PlayerFormat.time(snap.duration))")
    }
}

/// A drag that starts on the uploader, the title or the buttons on the right, which lie over the surface's own gesture
/// view, goes to the next or previous video all the same.
private struct PlayerVerticalSwipeThrough: ViewModifier {
    let controller: PlayerController
    /// The drag goes up or down (nil: no drag, or not decided yet).
    @State private var swiping: Bool?
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        if swiping == nil {
                            let moved = value.translation
                            swiping = abs(moved.height) > 3 * abs(moved.width) && controller.canSwipeVideos
                                && !controller.isSwitchingBySwipe
                        }
                        if swiping == true { controller.videoSwipeMoved(offset: value.translation.height) }
                    }
                    .onEnded { value in
                        if swiping == true {
                            controller.videoSwipeEnded(offset: value.translation.height, velocity: velocity(of: value))
                        }
                        swiping = nil
                    }
            )
            // `onEnded` is not called for a cancelled drag, nor is anything else for one whose view goes away.
            .onChange(of: touching) { touching in
                if !touching { cancelSwipe() }
            }
            .onDisappear { cancelSwipe() }
    }

    private func cancelSwipe() {
        if swiping == true { controller.videoSwipeEnded(offset: 0, velocity: 0) }
        swiping = nil
    }

    private func velocity(of value: DragGesture.Value) -> CGFloat {
        if #available(iOS 17, *) { return value.velocity.height }
        // `predictedEnd` lies about a quarter of a second ahead at that speed.
        return (value.predictedEndTranslation.height - value.translation.height) * 4
    }
}

/// Clock and battery in the fullscreen top bar.
struct PlayerFullscreenStatusView: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 20)) { context in
            HStack(spacing: 6) {
                Text(PlayerFormat.clock.string(from: context.date))
                if let level = PlayerFullscreenStatusView.batteryPercent() {
                    Text("\(level)%")
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.9))
            .padding(.trailing, 4)
        }
        .allowsHitTesting(false)
    }

    static func batteryPercent() -> Int? {
        // Enabled before the first read: `batteryLevel` is −1 until monitoring is on (the first render used to
        // show no battery for up to 20 s).
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : nil
    }
}
