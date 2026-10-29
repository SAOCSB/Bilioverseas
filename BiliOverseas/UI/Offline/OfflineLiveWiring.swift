import Foundation
import UIKit

// The app-wide 离线缓存 manager: Application Support/Offline, the html5 progressive MP4 from playurl, BTR downloaders
// (multi-CDN host swap per the 加速 settings) on the HTTP/1.1 client with the URLSession fallback, and the UIKit
// lifecycle — downloads go on for the background time iOS grants, stop (bytes kept) when it runs out, and continue
// when the app returns to the foreground.

extension OfflineDownloadManager {
    static let shared: OfflineDownloadManager = {
        let manager = OfflineDownloadManager(dependencies: .live)
        OfflineAppEventRelay.shared.attach(manager)
        return manager
    }()
}

extension OfflineDownloadManager.Dependencies {
    static var live: OfflineDownloadManager.Dependencies {
        let client = OfflineMediaClient.shared
        var tuning = BTRTuning.standard
        // No playback deadline: lemon's pace-aware hedging saves duplicate traffic on slow overseas links.
        tuning.pacedHedgeWithoutDeadline = true
        return OfflineDownloadManager.Dependencies(
            layout: OfflineStorageLayout(root: OfflineStorageLayout.defaultRoot()),
            resolveSource: { task in try await OfflineProgressiveSource.resolve(task) },
            makeDownloader: { config in BTRDownloader(config: config, client: client, auto: nil, tuning: tuning) },
            settings: { AppSettings.shared.acceleration })
    }
}

/// One upstream client for every offline download (its keep-alive pool outlives single runs).
enum OfflineMediaClient {
    static let shared: MediaHTTPClient = EngineMediaClientSwitch(
        makePrimary: { H1MediaClient() },
        makeFallback: { URLSessionMediaClient() },
        useFallback: AccelerationEngine.forceURLSessionTransport)
}

/// UIApplication notifications → the manager (delivered synchronously on the main thread).
@MainActor
final class OfflineAppEventRelay: NSObject {
    static let shared = OfflineAppEventRelay()

    private weak var manager: OfflineDownloadManager?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Ends the background time early once nothing is downloading any more.
    private var backgroundWatch: Task<Void, Never>?

    func attach(_ manager: OfflineDownloadManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willTerminate),
                       name: UIApplication.willTerminateNotification, object: nil)
    }

    /// Keeps downloading for the background time iOS grants; stops (bytes kept) when it expires.
    @objc private func didEnterBackground() {
        guard let manager else { return }
        guard manager.tasks.contains(where: { $0.state == .downloading }) else {
            manager.suspend()
            return
        }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "离线缓存") { [weak self] in
            MainActor.assumeIsolated {
                self?.manager?.suspend()
                self?.manager?.flush()
                self?.endBackgroundTask()
            }
        }
        if backgroundTask == .invalid {
            manager.suspend()
            return
        }
        backgroundWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.backgroundTask != .invalid, let manager = self.manager else { return }
                if !manager.tasks.contains(where: { $0.state == .downloading }) {
                    manager.suspend()
                    self.endBackgroundTask()
                    return
                }
            }
        }
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
        manager?.resumeAfterSuspend()
    }

    @objc private func willTerminate() {
        manager?.suspend()
        manager?.flush()
    }

    private func endBackgroundTask() {
        backgroundWatch?.cancel()
        backgroundWatch = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
