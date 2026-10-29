import SwiftUI
import AVFoundation

@main
struct BiliOverseasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var auth = AuthService.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
                .environmentObject(auth)
                .preferredColorScheme(colorScheme)
                .tint(.biliPink)
                .onAppear {
                    // Toasts get their own window above every sheet / full-screen cover.
                    ToastWindowHost.shared.install()
                    applyInterfaceStyle(settings.general.theme)
                }
                .onChange(of: settings.general.theme) { applyInterfaceStyle($0) }
                // bilioverseas://video/BV…, bilioverseas://open?url=<bilibili.com or b23.tv link> …
                .onOpenURL { DeepLinkCenter.shared.handle($0) }
                .task {
                    await auth.bootstrap()
                }
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.general.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// `preferredColorScheme(nil)` does not reliably hand an explicit light / dark choice back to the
    /// system (the window can keep the last forced style until relaunch), so the window-level override
    /// is set as well; `.unspecified` follows the system again.
    private func applyInterfaceStyle(_ theme: AppTheme) {
        let style: UIUserInterfaceStyle
        switch theme {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // iPads have the thermal/battery headroom for BTR's full ladder; iPhones stop at 32 threads.
        AccelerationEngine.maxAutoThreads = UIDevice.current.userInterfaceIdiom == .pad ? 64 : 32
        // Start the local BTR proxy early so the first video does not wait for the listener.
        AccelerationEngine.shared.startIfNeeded()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            AccelerationEngine.shared.applicationWillEnterForeground()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            AccelerationEngine.shared.applicationDidEnterBackground()
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            AccelerationEngine.shared.applicationDidReceiveMemoryWarning()
        }
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationManager.shared.mask
    }
}

/// Portrait-first like the official app; the player unlocks / forces landscape for fullscreen.
final class OrientationManager {
    static let shared = OrientationManager()

    private(set) var mask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    /// Restrict the app to `mask` and rotate to `preferred` if given.
    func lock(_ mask: UIInterfaceOrientationMask, rotateTo preferred: UIInterfaceOrientationMask? = nil) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred ?? mask)) { _ in }
    }

    func enterLandscape() {
        lock(.landscape, rotateTo: .landscapeRight)
    }

    func restorePortrait() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            lock(.all)
        } else {
            lock(.portrait, rotateTo: .portrait)
        }
    }

    /// Allow free rotation (used while a video page is visible so rotating the phone goes fullscreen).
    func allowAll() {
        lock(UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown, rotateTo: nil)
    }
}
