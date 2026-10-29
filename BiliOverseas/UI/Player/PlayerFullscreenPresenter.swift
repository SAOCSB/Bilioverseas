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
        top.present(vc, animated: true)
        return true
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
        vc.dismiss(animated: true)
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
