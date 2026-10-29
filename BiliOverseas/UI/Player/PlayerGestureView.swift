import UIKit
import AVFoundation
import MediaPlayer

/// Player gestures (features.md §1):
/// - single tap: toggle the controls (only the lock button while locked);
/// - double tap: quarters → seek ∓「双击快进/快退时长」 (when 「双击快退/快进」 is on), centre → play / pause;
/// - long press 0.3 s while playing: 长按倍速, released → the previous speed;
/// - horizontal pan: seek preview (90 s per full width, applied on release; top-corner cancel zone);
/// - vertical pan: left third brightness, right third volume (MPVolumeView slider), middle third fullscreen;
/// - pans starting within 25 pt of an edge are ignored (system edge gestures); direction lock at 3×.
final class PlayerGestureView: UIView, UIGestureRecognizerDelegate {
    weak var controller: PlayerController?

    static let edgeInset: CGFloat = 25
    /// A full-width horizontal swipe = 90 s.
    static let seekWindowSeconds: Double = 90

    private let singleTap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    /// Off-screen system volume control: driving its slider changes the volume without the system HUD.
    private let volumeView = MPVolumeView(frame: CGRect(x: -400, y: -400, width: 10, height: 10))
    private var volumeObservation: NSKeyValueObservation?

    private enum PanMode {
        case undecided, seek, brightness, volume, fullscreen
    }

    private var panMode: PanMode = .undecided
    private var panStartPoint: CGPoint = .zero
    private var panStartTime: Double = 0
    private var panTarget: Double = 0
    private var panCancelled = false
    private var lastTranslation: CGPoint = .zero
    private var fullscreenFired = false
    private var level: Double = 0
    private var lastVolumeWrite: CFTimeInterval = 0
    private var adjustingVolume = false
    private var boosting = false

    private var tapForward: Bool?
    private var tapAccumulated: Double = 0
    private var tapWindowEnd: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        addSubview(volumeView)

        singleTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        // The single tap waits for the double tap only while one is possible (see
        // `gestureRecognizer(_:shouldRequireFailureOf:)`): a tap on a locked player answers at once.
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let recognizers: [UIGestureRecognizer] = [singleTap, doubleTap, longPress, pan]
        for recognizer in recognizers {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Hardware volume keys: the system HUD is suppressed by the MPVolumeView, show our own pill.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = Double(session.outputVolume)
            Task { @MainActor [weak self] in self?.hardwareVolumeChanged(value) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Arbitration

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // UIKit also asks this view about recognizers of its ancestors (e.g. the page's pop gesture): leave those alone.
        let own: [UIGestureRecognizer] = [singleTap, doubleTap, longPress, pan]
        guard own.contains(where: { $0 === gestureRecognizer }) else { return true }
        guard let controller else { return false }
        if gestureRecognizer === singleTap { return true }
        if controller.overlay.isLocked { return false }
        if gestureRecognizer === doubleTap { return controller.item != nil }
        if gestureRecognizer === longPress {
            return controller.status == .playing && AppSettings.shared.player.longPressSpeedEnabled
        }
        if gestureRecognizer === pan {
            guard controller.item != nil, controller.overlay.panel == nil else { return false }
            let translation = pan.translation(in: self)
            let current = pan.location(in: self)
            let start = CGPoint(x: current.x - translation.x, y: current.y - translation.y)
            let e = Self.edgeInset
            return start.x > e && start.x < bounds.width - e && start.y > e && start.y < bounds.height - e
        }
        return true
    }

    /// §1.1: the double tap does not exist while locked (or before an item is loaded), so the single tap must not
    /// wait ~0.3 s for it to fail then. Asked once per recognition attempt.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === singleTap, otherGestureRecognizer === doubleTap else { return false }
        guard let controller else { return true }
        return !controller.overlay.isLocked && controller.item != nil
    }

    // MARK: Leaving the window

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { cancelActiveGestures() }
    }

    /// The surface leaves the window mid-gesture when it moves between the inline and fullscreen hosts (rotation
    /// while holding / scrubbing) or the page gets covered. Whether or not UIKit still delivers `.cancelled`, end a
    /// running 长按倍速 (restore the previous speed) and drop a pending scrub here, so the boost, the preview and
    /// the auto-hide hold can never stay behind.
    private func cancelActiveGestures() {
        if let controller {
            if boosting {
                boosting = false
                controller.endBoost()
                controller.overlay.endHold()
            }
            if panMode != .undecided { finishPan(committed: false, controller) }
        } else {
            boosting = false
            panMode = .undecided
        }
        for recognizer in [longPress, pan] as [UIGestureRecognizer]
        where recognizer.state == .began || recognizer.state == .changed {
            // Disabling a running recognizer cancels it; its `.cancelled` callback is a no-op now.
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }

    // MARK: Taps

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let controller, g.state == .ended else { return }
        let overlay = controller.overlay
        if overlay.isLocked {
            overlay.toggleControls()
            return
        }
        if overlay.panel != nil {
            overlay.panel = nil
            return
        }
        // A further tap on the 「快进N秒」 indicator adds another step.
        if let forward = continuingTapZone(at: g.location(in: self)) {
            stepSeek(forward: forward)
            return
        }
        overlay.toggleControls()
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let controller, g.state == .ended, !controller.overlay.isLocked else { return }
        let p = g.location(in: self)
        let w = bounds.width
        if AppSettings.shared.player.doubleTapAction == .seek, p.x < w * 0.25 || p.x >= w * 0.75 {
            stepSeek(forward: p.x >= w * 0.75)
        } else {
            controller.togglePlay()
            if controller.status == .paused { controller.overlay.showControls() }
        }
    }

    private func continuingTapZone(at p: CGPoint) -> Bool? {
        guard let forward = tapForward, CACurrentMediaTime() < tapWindowEnd,
              controller?.overlay.isDoubleTapHintActive == true else { return nil }
        let w = bounds.width
        if forward, p.x >= w * 0.75 { return true }
        if !forward, p.x < w * 0.25 { return false }
        return nil
    }

    private func stepSeek(forward: Bool) {
        guard let controller else { return }
        let step = max(1, AppSettings.shared.player.seekStep)
        let now = CACurrentMediaTime()
        if tapForward == forward, now < tapWindowEnd {
            tapAccumulated += step
        } else {
            tapForward = forward
            tapAccumulated = step
        }
        tapWindowEnd = now + 0.7
        controller.seek(by: forward ? step : -step)
        if controller.status == .paused { controller.play() }
        controller.overlay.showDoubleTapHint(forward: forward, seconds: Int(tapAccumulated))
    }

    // MARK: Long press (长按倍速)

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let controller else { return }
        switch g.state {
        case .began:
            if boosting {
                // A previous press that never reported its end: restore before starting again.
                boosting = false
                controller.endBoost()
                controller.overlay.endHold()
            }
            if controller.beginBoost() {
                boosting = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                controller.overlay.beginHold()
            }
        case .ended, .cancelled, .failed:
            if boosting {
                boosting = false
                controller.endBoost()
                controller.overlay.endHold()
            }
        default:
            break
        }
    }

    // MARK: Pan

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let controller else { return }
        let t = g.translation(in: self)
        let p = g.location(in: self)
        switch g.state {
        case .began:
            // A previous pan that never reported its end must not keep its preview / hold.
            if panMode != .undecided { finishPan(committed: false, controller) }
            panMode = .undecided
            panStartPoint = CGPoint(x: p.x - t.x, y: p.y - t.y)
            lastTranslation = .zero
            fullscreenFired = false
            panCancelled = false
            decideDirection(t, controller)
            handleMove(t, p, controller)
        case .changed:
            if panMode == .undecided { decideDirection(t, controller) }
            handleMove(t, p, controller)
        case .ended, .cancelled, .failed:
            finishPan(committed: g.state == .ended, controller)
        default:
            break
        }
    }

    private func decideDirection(_ t: CGPoint, _ controller: PlayerController) {
        let dx = abs(t.x)
        let dy = abs(t.y)
        guard dx * dx + dy * dy >= 1 else { return }
        if dx > 3 * dy {
            panMode = .seek
            panStartTime = controller.displayTime()
            panTarget = panStartTime
            controller.overlay.beginHold()
            controller.ensureVideoShot()
        } else if dy > 3 * dx {
            let w = bounds.width
            if panStartPoint.x < w / 3 {
                panMode = .brightness
                level = Double(controller.currentBrightness)
            } else if panStartPoint.x > w * 2 / 3 {
                panMode = .volume
                adjustingVolume = true
                level = Double(AVAudioSession.sharedInstance().outputVolume)
            } else {
                panMode = .fullscreen
            }
        }
        lastTranslation = .zero
        if panMode != .undecided { lastTranslation = t }
    }

    private func handleMove(_ t: CGPoint, _ p: CGPoint, _ controller: PlayerController) {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        switch panMode {
        case .undecided:
            return
        case .seek:
            let total = controller.duration
            var target = panStartTime + Self.seekWindowSeconds * Double(t.x / w)
            target = max(0, total > 0 ? min(target, total) : target)
            panTarget = target
            let inCancelZone = p.y < h * 0.125 && (p.x < w * 0.125 || p.x > w * 0.875)
            if inCancelZone != panCancelled {
                panCancelled = inCancelZone
                if inCancelZone {
                    controller.overlay.showHint("松开手指，取消进退")
                } else {
                    controller.overlay.clearHint()
                }
            }
            controller.overlay.seekPreview = PlayerSeekPreview(target: target, duration: total,
                                                               delta: target - panStartTime, cancelled: inCancelZone)
        case .brightness:
            let dy = Double(t.y - lastTranslation.y)
            level = min(max(level - dy / Double(h * 3), 0), 1)
            controller.setBrightness(CGFloat(level))
            controller.overlay.showLevel(.brightness, value: level)
        case .volume:
            let dy = Double(t.y - lastTranslation.y)
            level = min(max(level - dy / Double(h * 0.5), 0), 1)
            let now = CACurrentMediaTime()
            if now - lastVolumeWrite >= 0.02 {
                lastVolumeWrite = now
                setSystemVolume(level)
            }
            controller.overlay.showLevel(.volume, value: level)
        case .fullscreen:
            guard !fullscreenFired else { break }
            if t.y > 2.5, controller.isFullscreen {
                fullscreenFired = true
                controller.exitFullscreen()
            } else if t.y < -2.5, !controller.isFullscreen {
                fullscreenFired = true
                controller.enterFullscreen()
            }
        }
        lastTranslation = t
    }

    private func finishPan(committed: Bool, _ controller: PlayerController) {
        switch panMode {
        case .seek:
            controller.overlay.seekPreview = nil
            controller.overlay.clearHint()
            controller.overlay.endHold()
            if committed, !panCancelled {
                controller.seek(to: panTarget)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .volume:
            setSystemVolume(level)
            adjustingVolume = false
            controller.overlay.hideLevel(after: 0.2)
        case .brightness:
            controller.overlay.hideLevel(after: 0.2)
        case .undecided, .fullscreen:
            break
        }
        panMode = .undecided
        panCancelled = false
    }

    // MARK: Volume

    private func setSystemVolume(_ value: Double) {
        guard let slider = Self.findSlider(in: volumeView) else { return }
        lastVolumeWrite = CACurrentMediaTime()
        slider.value = Float(min(max(value, 0), 1))
        slider.sendActions(for: .valueChanged)
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let slider = sub as? UISlider { return slider }
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }

    private func hardwareVolumeChanged(_ value: Double) {
        // `outputVolume` reports our own slider writes asynchronously, after the pan has ended: such an echo would
        // keep the pill up for the 0.8 s hardware-key delay instead of 0.2 s.
        guard !adjustingVolume, CACurrentMediaTime() - lastVolumeWrite > 0.5,
              window != nil, let controller, controller.item != nil else { return }
        controller.overlay.showLevel(.volume, value: value)
        controller.overlay.hideLevel(after: 0.8)
    }
}
