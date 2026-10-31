import SwiftUI
import UIKit

/// Shows `ToastCenter`'s toast in its own window above everything the app presents (sheets, full-screen covers,
/// the fullscreen player, alerts), so a toast fired while a sheet is up is seen. The window:
/// - is visible only while a toast is up and never becomes key (`PlayerFullscreenPresenter.keyWindow()` keeps
///   finding the app window, the keyboard stays where it is);
/// - lets every touch through to the app except a tap on the toast's action button (「撤销」 …);
/// - takes status bar, orientation and home-indicator preferences from the app window's top controller, so showing
///   it changes nothing else on screen.
@MainActor
final class ToastWindowHost {
    static let shared = ToastWindowHost()

    private var window: ToastPassthroughWindow?
    private var hideTask: Task<Void, Never>?

    /// Creates the (hidden) window on the app's scene. Called when the root view appears and again for every
    /// toast (the scene can be replaced after a disconnect); a no-op while the window is attached.
    func install() {
        if let window, let scene = window.windowScene, scene.activationState != .unattached { return }
        guard let scene = Self.appScene() else { return }
        window?.isHidden = true
        let made = ToastPassthroughWindow(windowScene: scene)
        made.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        made.backgroundColor = .clear
        let root = ToastWindowRootController(rootView: ToastOverlay(onInteractiveFrame: { [weak made] frame in
            made?.interactiveFrame = frame
        }))
        root.view.backgroundColor = .clear
        made.rootViewController = root
        made.isHidden = true
        window = made
        ToastCenter.shared.attachWindowLayer { [weak self] visible in self?.toastChanged(visible: visible) }
    }

    /// `ToastCenter.current` changed: show the window for a toast, hide it once the slide-out has finished.
    func toastChanged(visible: Bool) {
        hideTask?.cancel()
        hideTask = nil
        if visible {
            install()
            guard let window, window.isHidden else { return }
            window.isHidden = false
            window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        } else if let window, !window.isHidden {
            hideTask = Task { [weak window] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, ToastCenter.shared.current == nil, let window else { return }
                window.isHidden = true
                window.interactiveFrame = nil
            }
        }
    }

    private static func appScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

/// Hit-tests only inside `interactiveFrame` (a toast with an action button); everything else falls through to the
/// windows below.
final class ToastPassthroughWindow: UIWindow {
    /// Window coordinates, reported by the hosted `ToastOverlay`.
    var interactiveFrame: CGRect?

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = interactiveFrame, frame.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Root of the toast window. Status bar, orientations and the home indicator follow whatever the app window
/// shows on top (the fullscreen player hides the status bar and locks landscape), so a toast never undoes them.
final class ToastWindowRootController: UIHostingController<ToastOverlay> {
    /// The controller UIKit asks in the app window: the root or the topmost controller presented full screen over
    /// it. A sheet, popover or alert leaves these preferences to the one below, e.g. 弹幕设置 over the fullscreen
    /// player keeps its hidden status bar and home indicator. The status bar moves only to a `.fullScreen`
    /// presentation or one that sets `modalPresentationCapturesStatusBarAppearance`.
    private func appTop(statusBar: Bool = false) -> UIViewController? {
        let windows = (view.window?.windowScene?.windows ?? []).filter { !($0 is ToastPassthroughWindow) }
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        var current = top
        while let presented = current?.presentedViewController, !presented.isBeingDismissed {
            let style = presented.modalPresentationStyle
            let controls = statusBar
                ? style == .fullScreen || presented.modalPresentationCapturesStatusBarAppearance
                : style == .fullScreen || style == .overFullScreen
            if controls { top = presented }
            current = presented
        }
        return top
    }

    private var statusBarHiddenSource: UIViewController? {
        var vc = appTop(statusBar: true)
        while let child = vc?.childForStatusBarHidden { vc = child }
        return vc
    }

    private var statusBarStyleSource: UIViewController? {
        var vc = appTop(statusBar: true)
        while let child = vc?.childForStatusBarStyle { vc = child }
        return vc
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        appTop()?.supportedInterfaceOrientations ?? OrientationManager.shared.mask
    }
    override var prefersStatusBarHidden: Bool { statusBarHiddenSource?.prefersStatusBarHidden ?? false }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let source = statusBarStyleSource else { return .default }
        let style = source.preferredStatusBarStyle
        // `.default` goes by the traits of whichever controller is asked, here this one: 短视频 is dark in a light app.
        guard style == .default else { return style }
        return source.traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }
    override var prefersHomeIndicatorAutoHidden: Bool {
        var vc = appTop()
        while let child = vc?.childForHomeIndicatorAutoHidden { vc = child }
        return vc?.prefersHomeIndicatorAutoHidden ?? false
    }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        var vc = appTop()
        while let child = vc?.childForScreenEdgesDeferringSystemGestures { vc = child }
        return vc?.preferredScreenEdgesDeferringSystemGestures ?? []
    }
}
