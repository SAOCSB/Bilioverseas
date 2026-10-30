import UIKit
import SwiftUI

/// Hosting controller of a fullscreen player: fixed orientation, no status bar, auto-hidden home indicator,
/// deferred edge gestures (an edge swipe needs two swipes, so drags near the edges reach the player).
final class PlayerFullscreenHostingController: UIHostingController<AnyView> {
    var orientationMask: UIInterfaceOrientationMask = .landscape {
        didSet { setNeedsUpdateOfSupportedInterfaceOrientations() }
    }
    var preferredOrientation: UIInterfaceOrientation = .landscapeRight

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { preferredOrientation }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    private var rotationWaiters: [(id: Int, run: () -> Void)] = []
    private var lastWaiterID = 0

    /// Calls `done` once the next rotation of this controller has finished, or after `timeout` if none comes. The
    /// closure returned calls it right away instead (a turn that will not come); `done` runs once in all.
    @discardableResult
    func afterRotation(timeout: TimeInterval, _ done: @escaping () -> Void) -> () -> Void {
        lastWaiterID += 1
        let id = lastWaiterID
        rotationWaiters.append((id, done))
        // Taken out whichever way it runs: one left behind would keep what `done` holds (this controller too)
        // alive once it has gone.
        let fire: () -> Void = { [weak self] in
            guard let self, let index = self.rotationWaiters.firstIndex(where: { $0.id == id }) else { return }
            self.rotationWaiters.remove(at: index).run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: fire)
        return fire
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            let waiters = self.rotationWaiters
            self.rotationWaiters = []
            waiters.forEach { $0.run() }
        }
    }
}

/// Root of the fullscreen presentation around the player shown (the video player's stage, the 直播间 panel). Toasts
/// show above it in `ToastWindowHost`'s window.
struct PlayerFullscreenRootView<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .preferredColorScheme(.dark)
            // Not under the app root: sheets presented from here would otherwise lose the app tint.
            .tint(.biliPink)
    }
}

/// Presents / dismisses the fullscreen hosting controller over whatever is on top, with plain transitions: entering
/// fades the player in the way the screen already stands and then turns the screen (the system rotation, of the
/// player alone); leaving turns it back first and then fades back to the page. Turning the screen while the page
/// still showed laid the page out sideways for the length of the animation.
@MainActor
final class PlayerFullscreenPresenter {
    private weak var hosting: PlayerFullscreenHostingController?
    /// The fullscreen controller still turning back or fading out after `dismiss`; a new `present` waits for it.
    private var leaving: PlayerFullscreenHostingController?
    private var leavingCompletion: (() -> Void)?
    private var pendingPresent: (() -> Void)?

    /// A dismissed fullscreen controller is still on screen, turning back or fading out.
    var isLeaving: Bool { leaving != nil }

    /// `willPresent`: right before the controller goes on screen, which waits for one still leaving to have gone (not
    /// called when the presentation is dropped). `onShown`: the player is in place and the screen stands still.
    func present<Content: View>(_ content: Content, mask: UIInterfaceOrientationMask,
                                orientation: UIInterfaceOrientation, willPresent: (() -> Void)? = nil,
                                onShown: @escaping () -> Void) -> Bool {
        guard hosting == nil else { return false }
        if leaving != nil {
            // Once that one is gone (`finishLeaving`); a `dismiss` meanwhile drops it.
            pendingPresent = { [weak self] in
                guard let self else { return }
                if !self.present(content, mask: mask, orientation: orientation, willPresent: willPresent,
                                 onShown: onShown) {
                    OrientationManager.shared.restorePortrait()
                }
            }
            return true
        }
        guard let top = Self.topViewController() else { return false }
        let vc = PlayerFullscreenHostingController(rootView: AnyView(PlayerFullscreenRootView(content: content)))
        let current = Self.interfaceOrientation()
        vc.orientationMask = Self.mask(for: current)
        vc.preferredOrientation = current
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.view.backgroundColor = .black
        hosting = vc
        let shown: () -> Void = { [weak self, weak vc] in
            guard let self, let vc, self.hosting === vc else { return }
            self.turn(vc, to: mask, orientation: orientation, then: onShown)
        }
        // A sheet or alert still going away: UIKit drops a presentation started meanwhile (the player would be
        // "fullscreen" with nothing on screen). Present it once that dismissal has finished instead.
        if let dismissing = top.presentedViewController, dismissing.isBeingDismissed,
           let coordinator = dismissing.transitionCoordinator {
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.presentDeferred(vc, willPresent: willPresent, then: shown) }
            }
            if queued { return true }
        }
        willPresent?()
        top.present(vc, animated: true, completion: shown)
        return true
    }

    /// Deferred `present`: skipped when fullscreen was left (or entered anew) meanwhile.
    private func presentDeferred(_ vc: PlayerFullscreenHostingController, willPresent: (() -> Void)?,
                                 then shown: @escaping () -> Void) {
        guard hosting === vc, vc.presentingViewController == nil, let top = Self.topViewController() else { return }
        willPresent?()
        top.present(vc, animated: true, completion: shown)
    }

    /// Turns the screen to `mask` (to `orientation` when it has to turn), then calls `done`.
    private func turn(_ vc: PlayerFullscreenHostingController, to mask: UIInterfaceOrientationMask,
                      orientation: UIInterfaceOrientation, then done: @escaping () -> Void) {
        let needsTurn = !mask.contains(Self.mask(for: Self.interfaceOrientation()))
        // The controller and the app always share an orientation: allow both, move the app, then narrow down.
        vc.orientationMask = mask.union(vc.orientationMask)
        vc.preferredOrientation = orientation
        if needsTurn {
            let finish = vc.afterRotation(timeout: 1.0, done)
            // Refused (an iPad sharing the screen, the app in the background): no turn is coming.
            OrientationManager.shared.lock(mask, rotateTo: Self.mask(for: orientation), onRefused: finish)
        } else {
            OrientationManager.shared.lock(mask)
        }
        vc.orientationMask = mask
        if !needsTurn { done() }
    }

    /// `releaseSurface`: called once the screen has turned back, right before the fade back to the page (the
    /// video stays in the fullscreen view while it turns). `completion`: the fullscreen controller is gone.
    func dismiss(releasingSurface releaseSurface: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard let vc = hosting else {
            // Left before it was shown (it waited for the previous one to go away).
            pendingPresent = nil
            releaseSurface()
            OrientationManager.shared.restorePortrait()
            completion?()
            return
        }
        hosting = nil
        // Allow portrait before the app mask goes back to portrait (no "no common orientation" moment).
        vc.orientationMask = .allButUpsideDown
        OrientationManager.shared.restorePortrait()
        // Never presented (still waiting in `present`): `presentDeferred` drops it.
        guard vc.presentingViewController != nil else {
            releaseSurface()
            completion?()
            return
        }
        leaving = vc
        leavingCompletion = completion
        let deadline = Date().addingTimeInterval(1.2)
        // Weak: the controller keeps the waiter below.
        weak let leavingVC = vc
        func fadeOutOnceUpright() {
            guard let vc = leavingVC else { return }
            guard Self.isUpright() || Date() >= deadline else {
                // Still turning (e.g. left while the entering turn was running): wait for the next one.
                vc.afterRotation(timeout: max(0.05, deadline.timeIntervalSinceNow), fadeOutOnceUpright)
                return
            }
            releaseSurface()
            fadeOut(vc)
        }
        fadeOutOnceUpright()
    }

    private func fadeOut(_ vc: PlayerFullscreenHostingController) {
        // UIKit ignores a dismissal requested while a presentation in this stack is still animating (the
        // fullscreen itself, or a sheet just opened over it).
        if let coordinator = Self.runningTransition(in: vc) {
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor in self?.dismissNow(vc) }
            }
            if queued { return }
        }
        dismissNow(vc)
    }

    /// Dismisses from the presenting controller: that also takes down a sheet shown over the fullscreen player
    /// (弹幕设置, 发弹幕 …). `vc.dismiss` would only close that sheet and leave a black fullscreen controller
    /// behind, with the surface already moved back inline and no way out.
    private func dismissNow(_ vc: PlayerFullscreenHostingController) {
        guard let presenter = vc.presentingViewController else {
            finishLeaving(vc)
            return
        }
        presenter.dismiss(animated: true) { [weak self] in self?.finishLeaving(vc) }
    }

    private func finishLeaving(_ vc: PlayerFullscreenHostingController) {
        guard leaving === vc else { return }
        leaving = nil
        let completion = leavingCompletion
        leavingCompletion = nil
        completion?()
        let next = pendingPresent
        pendingPresent = nil
        next?()
    }

    /// The scene's current interface orientation (portrait before there is a window).
    static func interfaceOrientation() -> UIInterfaceOrientation {
        let orientation = keyWindow()?.windowScene?.interfaceOrientation ?? .portrait
        return orientation == .unknown ? .portrait : orientation
    }

    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// Back the way the app stands outside fullscreen: portrait on iPhone, any way on iPad.
    private static func isUpright() -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad || interfaceOrientation() == .portrait
    }

    private static func runningTransition(in vc: UIViewController) -> UIViewControllerTransitionCoordinator? {
        var current: UIViewController? = vc
        while let candidate = current {
            if candidate.isBeingPresented || candidate.isBeingDismissed, let coordinator = candidate.transitionCoordinator {
                return coordinator
            }
            current = candidate.presentedViewController
        }
        return nil
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Something (a sheet, an alert …) is presented over the app: do not auto-rotate into fullscreen.
    static func isModalPresented() -> Bool {
        keyWindow()?.rootViewController?.presentedViewController != nil
    }
}
