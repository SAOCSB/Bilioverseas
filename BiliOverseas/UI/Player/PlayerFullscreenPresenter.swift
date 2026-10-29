import UIKit
import SwiftUI

/// Hosting controller of the fullscreen player: fixed orientation, no status bar, auto-hidden home indicator,
/// deferred edge gestures (an edge swipe needs two swipes, so drags near the edges reach the player).
final class PlayerFullscreenHostingController: UIHostingController<PlayerFullscreenRootView> {
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
}

/// Root of the fullscreen presentation: the same stage as inline (the surface moves over), plus its own toast layer
/// (the app's `ToastOverlay` lives under this modal).
struct PlayerFullscreenRootView: View {
    let controller: PlayerController

    var body: some View {
        PlayerStageView(controller: controller, overlay: controller.overlay, role: .fullscreen)
            .background(Color.black.ignoresSafeArea())
            .overlay { ToastOverlay() }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .preferredColorScheme(.dark)
            // Not under the app root: sheets presented from here would otherwise lose the app tint.
            .tint(.biliPink)
    }
}

/// Presents / dismisses the fullscreen hosting controller over whatever is on top.
@MainActor
final class PlayerFullscreenPresenter {
    private weak var hosting: PlayerFullscreenHostingController?

    func present(_ controller: PlayerController, mask: UIInterfaceOrientationMask,
                 orientation: UIInterfaceOrientation) -> Bool {
        guard hosting == nil, let top = Self.topViewController() else { return false }
        let vc = PlayerFullscreenHostingController(rootView: PlayerFullscreenRootView(controller: controller))
        vc.orientationMask = mask
        vc.preferredOrientation = orientation
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.view.backgroundColor = .black
        hosting = vc
        // Leaving and re-entering fullscreen quickly: UIKit drops a presentation started while the previous
        // fullscreen is still fading out (the player would be "fullscreen" with nothing on screen). Present it
        // once that dismissal has finished instead.
        if let leaving = top.presentedViewController, leaving.isBeingDismissed,
           let coordinator = leaving.transitionCoordinator {
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.presentDeferred(vc) }
            }
            if queued { return true }
        }
        top.present(vc, animated: true)
        return true
    }

    /// Deferred `present`: skipped when fullscreen was left (or entered anew) meanwhile.
    private func presentDeferred(_ vc: PlayerFullscreenHostingController) {
        guard hosting === vc, vc.presentingViewController == nil, let top = Self.topViewController() else { return }
        top.present(vc, animated: true)
    }

    func dismiss() {
        guard let vc = hosting else {
            OrientationManager.shared.restorePortrait()
            return
        }
        hosting = nil
        // Allow portrait before the app mask goes back to portrait (no "no common orientation" moment).
        vc.orientationMask = .allButUpsideDown
        OrientationManager.shared.restorePortrait()
        // Never presented (still waiting in `present`): `presentDeferred` drops it.
        guard vc.presentingViewController != nil else { return }
        // UIKit ignores a dismissal requested while a presentation in this stack is still animating (the
        // fullscreen itself, or a sheet just opened over it).
        if let coordinator = Self.runningTransition(in: vc) {
            let queued = coordinator.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in PlayerFullscreenPresenter.dismissNow(vc) }
            }
            if queued { return }
        }
        Self.dismissNow(vc)
    }

    /// Dismisses from the presenting controller: that also takes down a sheet shown over the fullscreen player
    /// (弹幕设置, 发弹幕 …). `vc.dismiss` would only close that sheet and leave a black fullscreen controller
    /// behind, with the surface already moved back inline and no way out.
    private static func dismissNow(_ vc: UIViewController) {
        guard let presenter = vc.presentingViewController else { return }
        presenter.dismiss(animated: true)
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
