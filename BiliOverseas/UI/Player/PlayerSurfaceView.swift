import UIKit
import SwiftUI
import AVFoundation
import Combine

/// `AVPlayerLayer`-backed view.
final class PlayerVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // Safe: `layerClass` guarantees the type.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The single video surface of a `PlayerController`: video layer, danmaku above it, gesture layer on top, and the
/// 「点击弹幕」 bubble / 「还原屏幕」 button above that. It is moved between the inline host and the fullscreen
/// host (the AVPlayer, its layer, the PiP controller and the danmaku state are never recreated).
final class PlayerSurfaceView: UIView {
    let videoView = PlayerVideoLayerView()
    let danmaku = DanmakuOverlayView(frame: .zero)
    let gestureView = PlayerGestureView(frame: .zero)
    private(set) weak var controller: PlayerController?

    var aspectMode: PlayerAspectMode = .fit {
        didSet { applyAspect() }
    }

    /// 双指缩放 (features.md §1.7): scales the picture only, danmaku keep their size.
    private(set) var zoomScale: CGFloat = 1
    static let zoomRange: ClosedRange<CGFloat> = 0.75...2.0

    private var bubble: DanmakuActionBubbleView?
    private let restoreButton = UIButton(type: .custom)
    private var chromeVisible = true
    private var chromeLocked = false
    private var zoomedCid: Int64?
    private var cancellables: [AnyCancellable] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoView.playerLayer.videoGravity = .resizeAspect
        addSubview(videoView)
        addSubview(danmaku)
        addSubview(gestureView)
        setUpRestoreButton()
        danmaku.onSuspendedLost = { [weak self] in self?.removeBubbleView() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(controller: PlayerController) {
        self.controller = controller
        videoView.playerLayer.player = controller.player
        gestureView.controller = controller
        aspectMode = controller.aspectMode
        danmaku.configure { [weak controller] in
            guard let controller else { return (time: 0, rate: 1, isPlaying: false) }
            return (time: controller.displayTime(), rate: controller.player.rate, isPlaying: controller.isActuallyPlaying)
        }
        // @Published emits in willSet: use the emitted values, not the properties.
        cancellables = [
            controller.overlay.$controlsVisible.sink { [weak self] visible in
                self?.chromeVisible = visible
                self?.updateRestoreButton()
            },
            controller.overlay.$isLocked.sink { [weak self] locked in
                self?.chromeLocked = locked
                if locked { self?.dismissDanmakuBubble() }
                self?.updateRestoreButton()
            },
            // 「还原屏幕」 also happens by itself for the next video and when leaving fullscreen.
            controller.$item.sink { [weak self] item in
                guard let self, item?.cid != self.zoomedCid else { return }
                self.zoomedCid = item?.cid
                self.resetZoom(animated: false)
            },
            controller.$isFullscreen.sink { [weak self] fullscreen in
                self?.dismissDanmakuBubble()
                if !fullscreen { self?.resetZoom(animated: false) }
            },
        ]
    }

    /// After background play (the layer is detached to keep audio running).
    func reattachPlayerIfNeeded() {
        guard let player = controller?.player else { return }
        if videoView.playerLayer.player !== player { videoView.playerLayer.player = player }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: the zoom transform stays applied while the size changes.
        let video = videoFrame()
        videoView.bounds = CGRect(origin: .zero, size: video.size)
        videoView.center = CGPoint(x: video.midX, y: video.midY)
        danmaku.frame = bounds
        gestureView.frame = bounds
        layoutRestoreButton()
    }

    // MARK: Pinch zoom (双指缩放, 「还原屏幕」)

    /// Applies a pinch scale, clamped to `zoomRange`.
    func setZoom(_ scale: CGFloat) {
        let s = min(max(scale.isFinite ? scale : 1, PlayerSurfaceView.zoomRange.lowerBound),
                    PlayerSurfaceView.zoomRange.upperBound)
        guard s != zoomScale else { return }
        zoomScale = s
        videoView.transform = CGAffineTransform(scaleX: s, y: s)
        updateRestoreButton()
    }

    /// 「还原屏幕」: back to the unscaled picture (animated over 255 ms when asked).
    func resetZoom(animated: Bool) {
        guard zoomScale != 1 else { return }
        zoomScale = 1
        updateRestoreButton()
        if animated {
            UIView.animate(withDuration: 0.255, delay: 0, options: [.curveEaseOut]) {
                self.videoView.transform = .identity
            }
        } else {
            videoView.transform = .identity
        }
    }

    private func setUpRestoreButton() {
        restoreButton.setTitle("还原屏幕", for: .normal)
        restoreButton.setTitleColor(.white, for: .normal)
        restoreButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        restoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        restoreButton.backgroundColor = UIColor(white: 0.15, alpha: 0.8)
        restoreButton.layer.cornerRadius = 6
        restoreButton.isHidden = true
        restoreButton.addAction(UIAction { [weak self] _ in
            self?.resetZoom(animated: true)
            self?.controller?.overlay.poke()
        }, for: .touchUpInside)
        addSubview(restoreButton)
    }

    /// Shown while the picture is zoomed and the controls are visible (features.md §1.7).
    private func updateRestoreButton() {
        let show = zoomScale != 1 && chromeVisible && !chromeLocked
        guard restoreButton.isHidden == show else { return }
        restoreButton.isHidden = !show
        if show {
            bringSubviewToFront(restoreButton)
            layoutRestoreButton()
        }
    }

    private func layoutRestoreButton() {
        guard !restoreButton.isHidden else { return }
        let title = restoreButton.titleLabel?.intrinsicContentSize ?? .zero
        let size = CGSize(width: ceil(title.width) + 30, height: ceil(title.height) + 16)
        // 95 pt above the bottom in fullscreen; the inline player is too short for that.
        let gap: CGFloat = controller?.isFullscreen == true ? 95 : min(95, bounds.height * 0.3)
        restoreButton.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - gap - size.height,
                                     width: size.width, height: size.height)
    }

    // MARK: 点击弹幕 bubble

    var isDanmakuBubbleVisible: Bool { bubble != nil }

    /// Shows the action bubble for the danmaku frozen by `danmaku.suspendDanmaku(at:)`; `point` is the tap.
    func showDanmakuBubble(for hit: DanmakuOverlayHit, at point: CGPoint) {
        guard let controller, danmaku.hasSuspendedDanmaku else { return }
        removeBubbleView()
        let view = DanmakuActionBubbleView(frame: .zero)
        let seek = DanmakuTimestamp.seconds(in: hit.item.readableText, duration: controller.duration)
        view.configure(item: hit.item, like: danmaku.likeState(of: hit.item), seekTarget: seek)
        view.onAction = { [weak self, weak view] action in
            guard let self, let view else { return }
            self.perform(action, item: hit.item, from: view)
        }
        addSubview(view)
        // The danmaku layer fills the surface, so its frames are surface coordinates.
        view.place(anchor: hit.frame, pointX: point.x, in: bounds)
        bubble = view
        controller.overlay.hideControls()
    }

    /// Closes the bubble and lets the danmaku go on.
    func dismissDanmakuBubble() {
        removeBubbleView()
        danmaku.resume()
    }

    private func removeBubbleView() {
        bubble?.removeFromSuperview()
        bubble = nil
    }

    private func perform(_ action: DanmakuActionBubbleView.Action, item: DanmakuItem, from view: DanmakuActionBubbleView) {
        guard let controller else { return }
        let cid = controller.item?.cid ?? 0
        let source = view.frame
        switch action {
        case .like:
            let overlay = danmaku
            Task { @MainActor [weak self] in
                await DanmakuActions.toggleLike(item, cid: cid, overlay: overlay)
                if let self, self.bubble === view { self.dismissDanmakuBubble() }
            }
        case .copy:
            DanmakuActions.copy(item)
            dismissDanmakuBubble()
        case .report:
            dismissDanmakuBubble()
            presentReportSheet(for: item, cid: cid, source: source)
        case .recall:
            dismissDanmakuBubble()
            presentRecallConfirm(for: item, cid: cid, source: source)
        case .block:
            dismissDanmakuBubble()
            presentBlockSheet(for: item, source: source)
        case .seek(let time):
            dismissDanmakuBubble()
            controller.seek(to: time)
        }
    }

    private func presentReportSheet(for item: DanmakuItem, cid: Int64, source: CGRect) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        let sheet = UIAlertController(title: "举报弹幕", message: item.readableText, preferredStyle: .actionSheet)
        for reason in DanmakuService.reportReasons {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { _ in
                Task { @MainActor in await DanmakuActions.report(item, cid: cid, reason: reason.id) }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func presentRecallConfirm(for item: DanmakuItem, cid: Int64, source: CGRect) {
        let sheet = UIAlertController(title: "撤回这条弹幕？", message: "每天的撤回次数有限。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "撤回", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await DanmakuActions.recall(item, cid: cid, overlay: self.danmaku) }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func presentBlockSheet(for item: DanmakuItem, source: CGRect) {
        let keyword = DanmakuActions.blockKeyword(for: item)
        let sheet = UIAlertController(title: "屏蔽", message: nil, preferredStyle: .actionSheet)
        if !item.midHash.isEmpty {
            sheet.addAction(UIAlertAction(title: "屏蔽发送者", style: .destructive) { _ in
                DanmakuActions.blockSender(item)
            })
        }
        if !keyword.isEmpty {
            sheet.addAction(UIAlertAction(title: "屏蔽关键词「\(keyword)」", style: .destructive) { _ in
                DanmakuActions.blockContent(item)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func present(_ sheet: UIAlertController, source: CGRect) {
        guard let host = danmakuPresentingViewController else { return }
        // iPad shows action sheets as popovers: anchor it where the bubble was.
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = source
        host.present(sheet, animated: true)
    }

    private func applyAspect() {
        let gravity: AVLayerVideoGravity
        switch aspectMode {
        case .fit: gravity = .resizeAspect
        case .fill: gravity = .resizeAspectFill
        case .stretch, .ratio16x9, .ratio4x3: gravity = .resize
        }
        videoView.playerLayer.videoGravity = gravity
        setNeedsLayout()
    }

    private func videoFrame() -> CGRect {
        switch aspectMode {
        case .ratio16x9: return fitted(ratio: 16.0 / 9.0)
        case .ratio4x3: return fitted(ratio: 4.0 / 3.0)
        default: return bounds
        }
    }

    private func fitted(ratio: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, ratio > 0 else { return bounds }
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

enum PlayerStageRole: Equatable {
    case inline, fullscreen
}

/// Holds the controller's surface while this host's role is active (inline when not fullscreen, fullscreen
/// otherwise).
final class PlayerSurfaceHostView: UIView {
    let role: PlayerStageRole
    private weak var controller: PlayerController?
    private var cancellable: AnyCancellable?

    init(controller: PlayerController, role: PlayerStageRole) {
        self.role = role
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        // @Published emits in willSet: use the emitted value, not the property.
        cancellable = controller.$isFullscreen.sink { [weak self] fullscreen in
            self?.claim(isFullscreen: fullscreen)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func claimIfActive() {
        guard let controller else { return }
        claim(isFullscreen: controller.isFullscreen)
    }

    private func claim(isFullscreen: Bool) {
        guard let controller, (isFullscreen ? PlayerStageRole.fullscreen : .inline) == role else { return }
        let surface = controller.surface
        guard surface.superview !== self else { return }
        surface.removeFromSuperview()
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { claimIfActive() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let surface = controller?.surface, surface.superview === self { surface.frame = bounds }
    }

    func releaseSurface() {
        cancellable = nil
        if let surface = controller?.surface, surface.superview === self { surface.removeFromSuperview() }
    }
}

struct PlayerSurfaceRepresentable: UIViewRepresentable {
    let controller: PlayerController
    let role: PlayerStageRole

    func makeUIView(context: Context) -> PlayerSurfaceHostView {
        PlayerSurfaceHostView(controller: controller, role: role)
    }

    func updateUIView(_ uiView: PlayerSurfaceHostView, context: Context) {
        uiView.claimIfActive()
    }

    static func dismantleUIView(_ uiView: PlayerSurfaceHostView, coordinator: ()) {
        uiView.releaseSurface()
    }
}

// MARK: - 画面比例 persistence

extension PlayerAspectMode {
    /// The mode stored in 「画面比例」 (`PlayerSettings.aspectMode`), for a video about to play: a stored 拉伸 shows
    /// vertical videos 自适应 instead (features.md §3.6; the stored choice stays 拉伸).
    static func stored(forVertical vertical: Bool) -> PlayerAspectMode {
        let mode = PlayerAspectMode(rawValue: AppSettings.shared.player.aspectMode) ?? .fit
        return mode == .stretch && vertical ? .fit : mode
    }
}

// MARK: - Subtitles

/// The subtitle line in the 「字幕设置」 style (features.md §3.7): 16 pt × 字体大小 (全屏字体大小 in fullscreen)
/// at 字体粗细, white on black at 背景不透明度 — with a transparent background a black 描边 instead —, kept
/// 左右边距 from the sides and 底部边距 from the bottom (raised to `minBottom` above visible controls).
struct PlayerSubtitleView: View {
    let text: String
    let style: PlayerSettings
    let fullscreen: Bool
    /// Bottom inset the visible controls need (0 while they are hidden).
    let minBottom: CGFloat

    private static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold,
                                                 .heavy, .black]

    private var fontSize: CGFloat {
        let scale = fullscreen ? style.subtitleFontScaleFullscreen : style.subtitleFontScale
        return 16 * CGFloat(min(max(scale, 0.5), 2.5))
    }

    private var weight: Font.Weight {
        PlayerSubtitleView.weights[min(max(style.subtitleFontWeight, 0), PlayerSubtitleView.weights.count - 1)]
    }

    private var backgroundOpacity: Double { min(max(style.subtitleBgOpacity, 0), 1) }

    /// Outline width; only without a background.
    private var stroke: CGFloat {
        backgroundOpacity > 0.005 ? 0 : CGFloat(min(max(style.subtitleStrokeWidth, 0), 5)) / 2
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            // Line height ≈ 1.5.
            .lineSpacing(fontSize * 0.3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: stroke, y: 0)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: -stroke, y: 0)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: 0, y: stroke)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: 0, y: -stroke)
            .padding(.horizontal, CGFloat(min(max(style.subtitlePaddingH, 0), 100)))
            .padding(.bottom, max(CGFloat(min(max(style.subtitleBottomPadding, 0), 200)), minBottom))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }
}
