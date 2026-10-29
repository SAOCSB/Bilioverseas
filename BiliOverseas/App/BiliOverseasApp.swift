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
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Start the local BTR proxy early so the first video does not wait for the listener.
        AccelerationEngine.shared.startIfNeeded()
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
