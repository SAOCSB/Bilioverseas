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

/// The single video surface of a `PlayerController`: video layer, danmaku above it, gesture layer on top. It is
/// moved between the inline host and the fullscreen host (the AVPlayer, its layer, the PiP controller and the
/// danmaku state are never recreated).
final class PlayerSurfaceView: UIView {
    let videoView = PlayerVideoLayerView()
    let danmaku = DanmakuOverlayView(frame: .zero)
    let gestureView = PlayerGestureView(frame: .zero)
    private(set) weak var controller: PlayerController?

    var aspectMode: PlayerAspectMode = .fit {
        didSet { applyAspect() }
    }

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(controller: PlayerController) {
        self.controller = controller
        videoView.playerLayer.player = controller.player
        gestureView.controller = controller
        danmaku.configure { [weak controller] in
            guard let controller else { return (time: 0, rate: 1, isPlaying: false) }
            return (time: controller.displayTime(), rate: controller.player.rate, isPlaying: controller.isActuallyPlaying)
        }
    }

    /// After background play (the layer is detached to keep audio running).
    func reattachPlayerIfNeeded() {
        guard let player = controller?.player else { return }
        if videoView.playerLayer.player !== player { videoView.playerLayer.player = player }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.frame = videoFrame()
        danmaku.frame = bounds
        gestureView.frame = bounds
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
