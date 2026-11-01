import AVFoundation
import UIKit

/// The picture moving between two places on the screen while what is around it changes: the vertical-video screen becoming
/// the video's page and back, as in the official app, with nothing sliding in as a new window would. A layer of its own on
/// the same player, in a window above everything, lines up over the picture and moves from there, so the video plays on
/// throughout whatever the pages underneath do. Moving the layer that shows it from one window to another would leave a frame
/// with nothing in it.
@MainActor
final class VideoMorph {
    /// One at a time, kept until it has gone.
    private static var current: VideoMorph?

    static var isRunning: Bool { current != nil }

    private let window: UIWindow
    private let root = VideoMorphController()
    private let backdrop = UIView()
    private let moving = PlayerVideoLayerView()
    /// Where the video is on the screen before it moves.
    let start: CGRect
    private let startBackdrop: CGFloat
    private var readyObservation: NSKeyValueObservation?
    private var onReady: (() -> Void)?
    private var finished = false
    private var isWaiting = false

    /// The video's shape.
    var pictureSize: CGSize { start.size }

    /// Over `view`, which shows the video in `layer`. `backdropAlpha`: how much black it starts with once it has the picture.
    init?(over view: UIView, layer: AVPlayerLayer, backdropAlpha: CGFloat) {
        guard VideoMorph.current == nil, let scene = view.window?.windowScene, let player = layer.player,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let shown = layer.videoRect
        start = view.convert(shown.isEmpty ? view.bounds : shown, to: nil)
        guard start.width > 0, start.height > 0 else { return nil }
        startBackdrop = backdropAlpha
        let frame = view.convert(view.bounds, to: nil)
        window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        root.view.backgroundColor = .clear
        root.statusBarOverBlack = backdropAlpha > 0.5
        window.rootViewController = root
        backdrop.frame = root.view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        root.view.addSubview(backdrop)
        moving.isUserInteractionEnabled = false
        moving.bounds = CGRect(origin: .zero, size: frame.size)
        moving.center = CGPoint(x: frame.midX, y: frame.midY)
        moving.playerLayer.videoGravity = layer.videoGravity
        moving.playerLayer.player = player
        root.view.addSubview(moving)
        window.isHidden = false
        // A paused player gives a layer just put on it nothing to show.
        if player.rate == 0 { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
        VideoMorph.current = self
    }

    /// `go` once it shows the picture, which until then it leaves to what is underneath.
    func whenReady(_ go: @escaping () -> Void) {
        onReady = go
        readyObservation = moving.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.becomeReady() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.becomeReady() }
    }

    private func becomeReady() {
        readyObservation = nil
        guard let go = onReady, !finished else { return }
        onReady = nil
        backdrop.alpha = startBackdrop
        go()
    }

    /// `target`: where the video goes on the screen. `backdropAlpha`: how much black is left around it there.
    func move(to target: CGRect, backdropAlpha: CGFloat, duration: TimeInterval = 0.3, done: @escaping () -> Void) {
        let scale = min(target.width / start.width, target.height / start.height)
        // It scales about its centre, which is not where the video's is when that does not fill it.
        let center = moving.center
        let dx = target.midX - center.x - (start.midX - center.x) * scale
        let dy = target.midY - center.y - (start.midY - center.y) * scale
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            self.moving.transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy))
            self.backdrop.alpha = backdropAlpha
            self.root.statusBarOverBlack = backdropAlpha > 0.5
        } completion: { _ in
            done()
        }
    }

    /// What is underneath can be touched while the picture waits for the page's own.
    func letTouchesThrough() {
        window.isUserInteractionEnabled = false
        isWaiting = true
    }

    /// Something was done on that page before its picture came: the picture goes, and what was done goes as if this were over.
    static func endWaiting() {
        guard let current, current.isWaiting else { return }
        current.finish(fade: 0)
    }

    /// Gone, over `fade`, into the same picture underneath.
    func finish(fade: TimeInterval = 0.12, done: (() -> Void)? = nil) {
        guard !finished else { return }
        finished = true
        let end = {
            self.readyObservation = nil
            self.moving.playerLayer.player = nil
            self.window.isHidden = true
            if VideoMorph.current === self { VideoMorph.current = nil }
            done?()
        }
        guard fade > 0 else {
            end()
            return
        }
        UIView.animate(withDuration: fade) {
            self.window.alpha = 0
        } completion: { _ in
            end()
        }
    }
}

private final class VideoMorphController: UIViewController {
    /// As the top window this says what the status bar looks like, over the black or over the page it is leaving for.
    var statusBarOverBlack = true {
        didSet { setNeedsStatusBarAppearanceUpdate() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarOverBlack ? .lightContent : .default }
}
