import UIKit

/// The picture moving between two places on the screen while what is around it changes: the vertical-video screen becoming
/// the video's page and back, as in the official app, with nothing sliding in as a new window would. The view that shows the
/// video is lent to a window above everything, so it stays up while the pages change underneath: it has its picture already,
/// where a new layer on the same player can take a moment to get one, or never while that is paused.
@MainActor
final class VideoMorph {
    /// One at a time, kept until it has gone.
    private static var current: VideoMorph?

    static var isRunning: Bool { current != nil }

    private let window: UIWindow
    private let root = VideoMorphController()
    private let backdrop = UIView()
    private let moving: UIView
    private let giveBack: () -> Void
    /// Where the video is on the screen before it moves.
    private let start: CGRect
    private var finished = false
    private var isWaiting = false

    /// The video's shape.
    var pictureSize: CGSize { start.size }

    /// `moving` is in its place on the screen, `picture` is where the video shows in it. `giveBack` puts it back where it
    /// came from, when this has gone.
    init?(moving view: UIView, picture: CGRect, backdropAlpha: CGFloat, giveBack: @escaping () -> Void) {
        guard VideoMorph.current == nil, let scene = view.window?.windowScene, picture.width > 0, picture.height > 0,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        moving = view
        self.giveBack = giveBack
        start = view.convert(picture, to: nil)
        let frame = view.convert(view.bounds, to: nil)
        window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        root.view.backgroundColor = .clear
        window.rootViewController = root
        backdrop.frame = root.view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .black
        backdrop.alpha = backdropAlpha
        root.statusBarOverBlack = backdropAlpha > 0.5
        root.view.addSubview(backdrop)
        view.removeFromSuperview()
        view.transform = .identity
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        root.view.addSubview(view)
        window.isHidden = false
        VideoMorph.current = self
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

    /// Gone, over `fade`; none when what is underneath shows the same picture only once this has given it back.
    func finish(fade: TimeInterval = 0.12, done: (() -> Void)? = nil) {
        guard !finished else { return }
        finished = true
        let end = {
            self.giveBack()
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
