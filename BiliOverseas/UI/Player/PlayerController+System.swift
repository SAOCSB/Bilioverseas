import Foundation
import AVFoundation
import AVKit
import UIKit

// System integration of the video player: Picture in Picture, background play (QA1668 layer detach), audio
// interruptions and app lifecycle. Now Playing / remote commands are in PlayerNowPlaying.swift.

extension PlayerController {
    // MARK: Picture in Picture

    func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let made: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: surface.videoView.playerLayer)
        guard let made else { return }
        made.delegate = pipCoordinator
        made.canStartPictureInPictureAutomaticallyFromInline = AppSettings.shared.player.autoPiP
        pipPossibleObservation = made.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPiPPossible() }
        }
        pip = made
    }

    private func refreshPiPPossible() {
        let possible = pip?.isPictureInPicturePossible ?? false
        if possible != isPiPPossible { isPiPPossible = possible }
    }

    var supportsPiP: Bool { pip != nil }

    func syncPiPSettings() {
        guard let pip else { return }
        let auto = AppSettings.shared.player.autoPiP
        if pip.canStartPictureInPictureAutomaticallyFromInline != auto {
            pip.canStartPictureInPictureAutomaticallyFromInline = auto
        }
    }

    func togglePiP() {
        guard let pip else {
            ToastCenter.shared.show("当前设备不支持画中画")
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            ToastCenter.shared.show("视频加载完成后才能开启画中画")
        }
    }

    func pipWillStart() {
        // AVPlayer's PiP window cannot draw our danmaku overlay.
        surface.danmaku.setVisible(false)
    }

    func pipDidStart() {
        isPiPActive = true
        surface.danmaku.setVisible(false)
        if isFullscreen { exitFullscreen() }
    }

    func pipDidStop() {
        isPiPActive = false
        surface.danmaku.setVisible(true)
        if stopAfterPiP { performStop() }
    }

    func pipFailedToStart() {
        isPiPActive = false
        surface.danmaku.setVisible(true)
        ToastCenter.shared.show("画中画启动失败")
        if stopAfterPiP { performStop() }
    }

    /// The page that owned the player is gone after `stop()` during PiP: nothing to restore to.
    func pipShouldRestore() -> Bool { !stopAfterPiP }

    // MARK: Background play

    func appDidEnterBackground() {
        restoreBrightness()
        backgroundTask?.cancel()
        guard item != nil, !(pipCoordinator.isActive || pipCoordinator.isStarting) else { return }
        // A swipe under way has paused the old video, but the one it goes to will play.
        let intended = wantsToPlay || isSwitchingBySwipe
        guard intended else { return }
        let settings = AppSettings.shared.player
        if settings.autoPiP, pip != nil, isPiPPossible {
            // The system may start PiP by itself; decide once it had the chance.
            backgroundTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled, UIApplication.shared.applicationState == .background,
                      !(self.pipCoordinator.isActive || self.pipCoordinator.isStarting) else { return }
                self.continueInBackground(intended: intended)
            }
        } else {
            continueInBackground(intended: intended)
        }
    }

    private func continueInBackground(intended: Bool) {
        guard intended else { return }
        if AppSettings.shared.player.backgroundPlay {
            // QA1668: a player attached to a visible layer is paused in the background; detach it to keep audio.
            surface.videoView.playerLayer.player = nil
            if !wantsToPlay, !isSwitchingBySwipe { play() }
        } else {
            if wantsToPlay { pause() }
            pausedByBackground = true
        }
    }

    func appWillEnterForeground() {
        backgroundTask?.cancel()
        surface.reattachPlayerIfNeeded()
        if pausedByBackground {
            pausedByBackground = false
            // A switch under way: what comes next was decided when the swipe found the video playing or paused.
            if !isSwitchingBySwipe { play() }
        }
    }

    // MARK: Audio interruptions (calls, alarms …)

    func audioInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard item != nil else { return }
        switch type {
        case .began?:
            let now = ProcessInfo.processInfo.systemUptime
            let recentlyPausedBySystem = lastExternalPauseAt.map { now - $0 < 2 } ?? false
            if wantsToPlay {
                pause()
                pausedByInterruption = true
            } else if recentlyPausedBySystem {
                pausedByInterruption = true
            }
        case .ended?:
            if pausedByInterruption, shouldResume {
                play()
            }
            pausedByInterruption = false
        default:
            break
        }
    }
}

// MARK: - App event relay

/// Synchronous app notifications (the background layer detach must happen inside `didEnterBackground`).
@MainActor
final class PlayerAppEventRelay: NSObject {
    weak var owner: PlayerController?

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(orientationDidChange),
                       name: UIDevice.orientationDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }

    @objc private func didEnterBackground() {
        owner?.appDidEnterBackground()
    }

    @objc private func willEnterForeground() {
        owner?.appWillEnterForeground()
    }

    @objc private func orientationDidChange() {
        owner?.deviceOrientationChanged()
    }

    /// May be posted off the main thread.
    @objc nonisolated private func audioInterruption(_ note: Notification) {
        let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        Task { @MainActor [weak self] in
            let type = typeRaw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let resume = optionsRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            self?.owner?.audioInterruption(type: type, shouldResume: resume)
        }
    }
}

// MARK: - PiP delegate

final class PlayerPiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    weak var owner: PlayerController?
    /// Set synchronously (the background handler reads them before any hop to the main actor).
    private(set) var isStarting = false
    private(set) var isActive = false

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = true
        Task { @MainActor [weak self] in self?.owner?.pipWillStart() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = true
        Task { @MainActor [weak self] in self?.owner?.pipDidStart() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isStarting = false
        isActive = false
        Task { @MainActor [weak self] in self?.owner?.pipFailedToStart() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = false
        Task { @MainActor [weak self] in self?.owner?.pipDidStop() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self] in
            completionHandler(self?.owner?.pipShouldRestore() ?? false)
        }
    }
}

/// Keeps a controller alive while its PiP window outlives the page that created it.
@MainActor
enum PlayerPiPKeeper {
    private static var kept: [ObjectIdentifier: PlayerController] = [:]

    static func retain(_ controller: PlayerController) {
        kept[ObjectIdentifier(controller)] = controller
    }

    static func release(_ controller: PlayerController) {
        kept[ObjectIdentifier(controller)] = nil
    }

    /// Another player started: PiP windows left over from closed pages end (their controllers then stop in
    /// `pipDidStop`), so two videos never play at once.
    /// `nil` (a live room started): every leftover video PiP window ends.
    static func stopOthers(than controller: PlayerController?) {
        for other in Array(kept.values) where other !== controller {
            if other.pip?.isPictureInPictureActive == true {
                other.pip?.stopPictureInPicture()
            } else if !other.isPiPBusy {
                other.performStop()
            }
        }
    }
}
