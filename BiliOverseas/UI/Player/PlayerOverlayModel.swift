import Foundation
import Combine
import UIKit

/// Side panel / sheet content of the player menus.
enum PlayerPanel: String, Identifiable {
    case speed, quality, audio, codec, subtitle, aspect, sleepTimer, more
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "倍速"
        case .quality: return "画质"
        case .audio: return "音质"
        case .codec: return "解码格式"
        case .subtitle: return "字幕"
        case .aspect: return "画面比例"
        case .sleepTimer: return "定时关闭"
        case .more: return "更多设置"
        }
    }
}

enum PlayerSheet: Identifiable, Equatable {
    case danmakuSettings
    case danmakuSend
    case playerSettings
    case menu(PlayerPanel)

    var id: String {
        switch self {
        case .danmakuSettings: return "danmakuSettings"
        case .danmakuSend: return "danmakuSend"
        case .playerSettings: return "playerSettings"
        case .menu(let p): return "menu." + p.rawValue
        }
    }
}

/// Scrubbing preview (horizontal pan or progress-bar drag).
struct PlayerSeekPreview: Equatable {
    var target: Double
    var duration: Double
    /// Seconds relative to the start of the drag (pan only).
    var delta: Double
    /// In the 「松开手指，取消进退」 zone.
    var cancelled: Bool
}

struct PlayerDoubleTapHint: Equatable {
    var forward: Bool
    var seconds: Int
}

enum PlayerLevelKind: Equatable {
    case volume, brightness
}

struct PlayerLevelHUD: Equatable {
    var kind: PlayerLevelKind
    var value: Double
}

/// UI-only state of the player chrome (controls visibility, lock, HUDs, menus). Owned by `PlayerController` so it
/// survives the inline ↔ fullscreen move.
@MainActor
final class PlayerOverlayModel: ObservableObject {
    @Published private(set) var controlsVisible = true
    @Published private(set) var isLocked = false
    @Published private(set) var lockButtonVisible = false
    /// Fullscreen right-side panel.
    @Published var panel: PlayerPanel? {
        didSet {
            if panel != nil {
                hideTask?.cancel()
                controlsVisible = false
            }
        }
    }
    @Published var sheet: PlayerSheet?
    @Published var seekPreview: PlayerSeekPreview?
    @Published private(set) var doubleTapHint: PlayerDoubleTapHint?
    @Published private(set) var levelHUD: PlayerLevelHUD?
    @Published private(set) var hint: String?

    /// Auto-hide only runs while playback is (about to be) running.
    var isPlayingProvider: (() -> Bool)?

    private var holds = 0
    private var hideTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var tapHintTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?

    static let autoHideNanoseconds: UInt64 = 3_000_000_000

    // MARK: Controls

    func showControls() {
        if isLocked {
            showLockButton()
            return
        }
        controlsVisible = true
        scheduleHide()
    }

    func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
    }

    func toggleControls() {
        if isLocked {
            lockButtonVisible ? hideLockButton() : showLockButton()
        } else if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    /// Any interaction with the chrome restarts the 3 s timer.
    func poke() {
        if controlsVisible { scheduleHide() }
        if isLocked, lockButtonVisible { showLockButton() }
    }

    /// Scrubbing / long press: never auto-hide meanwhile.
    func beginHold() {
        holds += 1
        hideTask?.cancel()
    }

    func endHold() {
        holds = max(0, holds - 1)
        if holds == 0 { scheduleHide() }
    }

    func scheduleHide() {
        hideTask?.cancel()
        guard controlsVisible else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: PlayerOverlayModel.autoHideNanoseconds)
            guard let self, !Task.isCancelled else { return }
            if self.holds == 0, self.panel == nil, self.isPlayingProvider?() ?? true {
                self.controlsVisible = false
            }
        }
    }

    func playbackStateChanged(playing: Bool) {
        if playing, controlsVisible { scheduleHide() }
    }

    func playbackEnded() {
        unlock()
        controlsVisible = true
        hideTask?.cancel()
    }

    func prepareForNewItem() {
        panel = nil
        seekPreview = nil
        doubleTapHint = nil
        levelHUD = nil
        hint = nil
        holds = 0
        controlsVisible = true
        scheduleHide()
    }

    func fullscreenChanged() {
        panel = nil
        sheet = nil
        seekPreview = nil
        // Every running scrub / long press ends with the hand-over (the chrome and the surface are re-hosted); a
        // hold whose end got lost would otherwise disable auto-hide for the rest of the video.
        holds = 0
        controlsVisible = true
        scheduleHide()
    }

    func reset() {
        hideTask?.cancel()
        lockTask?.cancel()
        tapHintTask?.cancel()
        levelTask?.cancel()
        hintTask?.cancel()
        holds = 0
        isLocked = false
        lockButtonVisible = false
        panel = nil
        sheet = nil
        seekPreview = nil
        doubleTapHint = nil
        levelHUD = nil
        hint = nil
        controlsVisible = true
    }

    // MARK: Lock (fullscreen only)

    func toggleLock() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isLocked.toggle()
        if isLocked {
            hideTask?.cancel()
            controlsVisible = false
            panel = nil
            showLockButton()
            showHint("已锁定屏幕")
        } else {
            lockTask?.cancel()
            lockButtonVisible = false
            showControls()
        }
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        lockTask?.cancel()
        lockButtonVisible = false
    }

    private func showLockButton() {
        lockButtonVisible = true
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: PlayerOverlayModel.autoHideNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.lockButtonVisible = false
        }
    }

    private func hideLockButton() {
        lockTask?.cancel()
        lockButtonVisible = false
    }

    // MARK: Menus

    /// Fullscreen → right-side panel; inline → bottom sheet.
    func open(_ target: PlayerPanel, fullscreen: Bool) {
        if fullscreen {
            panel = target
        } else {
            sheet = .menu(target)
        }
    }

    // MARK: HUDs

    func showDoubleTapHint(forward: Bool, seconds: Int) {
        doubleTapHint = PlayerDoubleTapHint(forward: forward, seconds: seconds)
        tapHintTask?.cancel()
        tapHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.doubleTapHint = nil
        }
    }

    var isDoubleTapHintActive: Bool { doubleTapHint != nil }

    func showLevel(_ kind: PlayerLevelKind, value: Double) {
        levelTask?.cancel()
        levelHUD = PlayerLevelHUD(kind: kind, value: min(max(value, 0), 1))
    }

    /// Hides the volume / brightness pill `delay` seconds after the last change.
    func hideLevel(after delay: Double) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.levelHUD = nil
        }
    }

    func showHint(_ text: String, duration: Double = 1.5) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, duration) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hint = nil
        }
    }

    func clearHint() {
        hintTask?.cancel()
        hint = nil
    }
}
