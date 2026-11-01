import UIKit
import SwiftUI
import AVFoundation
import Combine

/// `AVPlayerLayer`-backed view.
final class PlayerVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // Safe: `layerClass` guarantees the type.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The single video surface of a `PlayerController`: video layer, danmaku above it, gesture layer on top, and the
/// 「点击弹幕」 bubble / 「还原屏幕」 button above that. It is moved between the inline host and the fullscreen
/// host (the AVPlayer, its layer, the PiP controller and the danmaku state are never recreated).
final class PlayerSurfaceView: UIView {
    let videoView = PlayerVideoLayerView()
    let danmaku = DanmakuOverlayView(frame: .zero)
    let gestureView = PlayerGestureView(frame: .zero)
    private(set) weak var controller: PlayerController?

    var aspectMode: PlayerAspectMode = .fit {
        didSet { applyAspect() }
    }

    /// 双指缩放 (features.md §1.7): scales the picture only, danmaku keep their size.
    private(set) var zoomScale: CGFloat = 1
    static let zoomRange: ClosedRange<CGFloat> = 0.75...2.0

    private var bubble: DanmakuActionBubbleView?
    private let restoreButton = UIButton(type: .custom)
    private var chromeVisible = true
    private var chromeLocked = false
    private var zoomedCid: Int64?
    private var cancellables: [AnyCancellable] = []
    private var videoSizeObservation: AnyCancellable?
    /// The video a swipe goes to: its picture comes in with the finger and stays until the video shows its own.
    private let swipeCover = PlayerSwipeCoverView()
    /// What `swipeCover` shows.
    private var swipeCoverTarget: PlayerVideoSwipeTarget?
    /// The video a swipe leaves, while it has no picture of its own yet.
    private let leavingCover = PlayerSwipeCoverView()
    private var leavingCoverTarget: PlayerVideoSwipeTarget?
    /// It is what stood in for this video when the swipe began.
    private var leavingCoverHeld = false
    /// The cover standing in for the video until that shows its own picture.
    private var holdingCover: PlayerSwipeCoverView?
    var isHoldingSwipePicture: Bool { holdingCover != nil }
    /// Bumped by every swipe, so a late clean-up of the last one leaves the new one alone.
    private var swipeGeneration = 0
    /// Which edge the target's cover is coming in from.
    private var swipeCoverFromBelow = true
    /// The video's own size (zero until it is known).
    private var videoSize: CGSize = .zero
    /// Danmaku keep off the vertical-video screen's top bar.
    var danmakuTopInset: CGFloat = 0 {
        didSet {
            if danmakuTopInset != oldValue { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoView.playerLayer.videoGravity = .resizeAspect
        addSubview(videoView)
        addSubview(danmaku)
        addSubview(leavingCover)
        addSubview(swipeCover)
        addSubview(gestureView)
        setUpRestoreButton()
        danmaku.onSuspendedLost = { [weak self] in self?.removeBubbleView() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(controller: PlayerController) {
        self.controller = controller
        videoView.playerLayer.player = controller.player
        gestureView.controller = controller
        aspectMode = controller.aspectMode
        danmaku.configure { [weak controller] in
            guard let controller else { return (time: 0, rate: 1, isPlaying: false) }
            return (time: controller.displayTime(), rate: controller.player.rate, isPlaying: controller.isActuallyPlaying)
        }
        // @Published emits in willSet: use the emitted values, not the properties.
        cancellables = [
            controller.overlay.$controlsVisible.sink { [weak self] visible in
                self?.chromeVisible = visible
                self?.updateRestoreButton()
            },
            controller.overlay.$isLocked.sink { [weak self] locked in
                self?.chromeLocked = locked
                if locked { self?.dismissDanmakuBubble() }
                self?.updateRestoreButton()
            },
            // 「还原屏幕」 also happens by itself for the next video and when leaving fullscreen.
            controller.$item.sink { [weak self] item in
                guard let self, item?.cid != self.zoomedCid else { return }
                self.zoomedCid = item?.cid
                self.resetZoom(animated: false)
            },
            controller.$isFullscreen.sink { [weak self] fullscreen in
                self?.dismissDanmakuBubble()
                if !fullscreen { self?.resetZoom(animated: false) }
            },
        ]
        observeVideoSize(of: controller.player)
    }

    private func observeVideoSize(of player: AVPlayer) {
        videoSizeObservation = player.publisher(for: \.currentItem?.presentationSize).receive(on: RunLoop.main).sink { [weak self] size in
            self?.videoSize = size ?? .zero
            self?.updateVideoGravity()
            self?.setNeedsLayout()
        }
    }

    /// The controller goes on with another player (`PlayerStreamLoan`).
    func playerChanged() {
        guard let player = controller?.player else { return }
        videoView.playerLayer.player = player
        observeVideoSize(of: player)
    }

    /// After background play (the layer is detached to keep audio running).
    func reattachPlayerIfNeeded() {
        guard let player = controller?.player else { return }
        if videoView.playerLayer.player !== player { videoView.playerLayer.player = player }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateVideoGravity()
        // Bounds and centre, not frame: the zoom transform stays applied while the size changes.
        let video = videoFrame()
        videoView.bounds = CGRect(origin: .zero, size: video.size)
        videoView.center = CGPoint(x: video.midX, y: video.midY)
        // Bounds and centre here too: a swipe moves these with a transform.
        for moving in [leavingCover, swipeCover] {
            moving.bounds = CGRect(origin: .zero, size: bounds.size)
            moving.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // The page or the phone can change this size while a picture stands in for the video.
        if !swipeCover.isHidden, let swipeCoverTarget { swipeCover.show(picture(of: swipeCoverTarget)) }
        if !leavingCover.isHidden, let leavingCoverTarget { leavingCover.show(picture(of: leavingCoverTarget)) }
        var lanes = bounds.inset(by: UIEdgeInsets(top: danmakuTopInset, left: 0, bottom: 0, right: 0))
        var abovePicture: DanmakuOverlayView.AbovePicture?
        if let picture = wholePictureRect {
            (lanes, abovePicture) = VerticalVideoMetrics.danmakuPlacement(picture: picture, in: lanes)
        }
        danmaku.abovePicture = abovePicture
        danmaku.bounds = CGRect(origin: .zero, size: lanes.size)
        danmaku.center = CGPoint(x: lanes.midX, y: lanes.midY)
        gestureView.frame = bounds
        layoutRestoreButton()
    }

    // MARK: The picture moving away

    /// Over the picture, to move it over everything else (`VideoMorph`).
    func makeMorph(backdropAlpha: CGFloat) -> VideoMorph? {
        resetZoom(animated: false)
        return VideoMorph(over: videoView, layer: videoView.playerLayer, backdropAlpha: backdropAlpha)
    }

    /// `done` once the picture shows here, or after a moment if that does not come.
    func whenPictureShows(tries: Int = 15, _ done: @escaping () -> Void) {
        guard tries > 0, window == nil || !videoView.playerLayer.isReadyForDisplay else {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else {
                done()
                return
            }
            self.whenPictureShows(tries: tries - 1, done)
        }
    }

    // MARK: Swiping to another video

    func beginVideoSwipe(leavingCover cover: String?) {
        swipeGeneration += 1
        dismissDanmakuBubble()
        stopSwipeAnimations()
        swipeCover.alpha = 1
        leavingCover.alpha = 1
        swipeCover.showsSpinner = false
        // This video has no picture of its own yet: what stands in for it leaves in its place.
        if let holding = holdingCover {
            let held = holding === swipeCover ? swipeCoverTarget : leavingCoverTarget
            holdingCover = nil
            leavingCoverHeld = true
            setLeavingCover(held)
        } else {
            leavingCoverHeld = false
            setLeavingCover(cover.map { PlayerVideoSwipeTarget(cover: $0, isLandscape: controller?.isVerticalVideo == false) })
        }
    }

    private func stopSwipeAnimations() {
        for moving in [videoView, danmaku, leavingCover, swipeCover] as [UIView] { moving.layer.removeAllAnimations() }
    }

    /// `target` nil: nothing to go to (yet), so the picture only gives a little.
    func moveVideoSwipe(offset: CGFloat, target: PlayerVideoSwipeTarget?) {
        swipeCover.isHidden = target == nil
        if let target { setSwipeCover(target) }
        setVideoSwipe(offset: target == nil ? offset * 0.3 : offset, coverFromBelow: offset < 0)
    }

    private func setSwipeCover(_ target: PlayerVideoSwipeTarget) {
        swipeCoverTarget = target
        swipeCover.show(picture(of: target))
    }

    private func setLeavingCover(_ target: PlayerVideoSwipeTarget?) {
        leavingCoverTarget = target
        if let target { leavingCover.show(picture(of: target)) }
        leavingCover.isHidden = target == nil
    }

    /// The picture for `target`, placed the way the video will be (`videoFrame`, `updateVideoGravity`).
    private func picture(of target: PlayerVideoSwipeTarget) -> PlayerSwipePicture {
        let whole = onVerticalScreen && target.isLandscape
        if let still = target.still, still.surfaceSize == bounds.size {
            return PlayerSwipePicture(url: "", frame: bounds, contentMode: .scaleAspectFill, still: still)
        }
        guard !target.firstFrame.isEmpty else { return coverPicture(target.cover, whole: whole) }
        let url = PlayerSwipeCoverView.firstFrameURL(target.firstFrame)
        if whole {
            return PlayerSwipePicture(url: url, frame: VerticalVideoMetrics.wholePictureFrame(in: bounds),
                                      contentMode: .scaleAspectFit, still: nil)
        }
        switch PlayerAspectMode.stored(forVertical: !target.isLandscape) {
        case .fit:
            let fills = onVerticalScreen && VerticalVideoMetrics.fills(video: target.videoSize, area: bounds.size)
            return PlayerSwipePicture(url: url, frame: bounds, contentMode: fills ? .scaleAspectFill : .scaleAspectFit, still: nil)
        case .fill:
            return PlayerSwipePicture(url: url, frame: bounds, contentMode: .scaleAspectFill, still: nil)
        case .stretch:
            return PlayerSwipePicture(url: url, frame: bounds, contentMode: .scaleToFill, still: nil)
        case .ratio16x9:
            return PlayerSwipePicture(url: url, frame: fitted(ratio: 16.0 / 9.0), contentMode: .scaleToFill, still: nil)
        case .ratio4x3:
            return PlayerSwipePicture(url: url, frame: fitted(ratio: 4.0 / 3.0), contentMode: .scaleToFill, still: nil)
        }
    }

    /// A cover is made for any shape: it fills what the video will take, without saying what the video looks like.
    private func coverPicture(_ cover: String, whole: Bool) -> PlayerSwipePicture {
        PlayerSwipePicture(url: cover.isEmpty ? "" : RemoteImage.resolvedURL(cover, width: 640),
                           frame: whole ? VerticalVideoMetrics.wholePictureFrame(in: bounds) : bounds,
                           contentMode: whole ? .scaleAspectFit : .scaleAspectFill, still: nil)
    }

    /// The picture as it is now, to show when going back to this video.
    func pictureStill() -> PlayerPictureStill? {
        guard zoomScale == 1, let view = videoView.snapshotView(afterScreenUpdates: false) else { return nil }
        return PlayerPictureStill(view: view, frame: videoFrame(), surfaceSize: bounds.size)
    }

    private func setVideoSwipe(offset: CGFloat, coverFromBelow: Bool) {
        swipeCoverFromBelow = coverFromBelow
        let moved = CGAffineTransform(translationX: 0, y: offset)
        // A pinch zoom stays: a swipe that springs back leaves the picture as it was.
        videoView.transform = moved.scaledBy(x: zoomScale, y: zoomScale)
        danmaku.transform = moved
        leavingCover.transform = moved
        swipeCover.transform = CGAffineTransform(translationX: 0, y: offset + (coverFromBelow ? bounds.height : -bounds.height))
    }

    /// The picture leaves and the cover takes its place; `completion` then switches the video.
    func commitVideoSwipe(toNext: Bool, target: PlayerVideoSwipeTarget, completion: @escaping () -> Void) {
        setSwipeCover(target)
        // The target may have arrived after the finger's last move: then the cover is not in place yet.
        if swipeCover.isHidden {
            swipeCover.isHidden = false
            setVideoSwipe(offset: videoView.transform.ty, coverFromBelow: toNext)
        }
        // Only for a wait long enough to notice: a video made ready ahead takes no longer than the slide. After that the
        // player has a spinner of its own.
        let generation = swipeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, generation == self.swipeGeneration else { return }
            self.swipeCover.showsSpinner = true
        }
        // From where the finger put them (`beginFromCurrentState` would take what is on screen, which is older for a swipe
        // that begins and ends at once, `PlayerController.goOnAfterLanding`).
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.setVideoSwipe(offset: toNext ? -self.bounds.height : self.bounds.height, coverFromBelow: toNext)
        } completion: { _ in
            completion()
        }
        // On its way now, outside this thread, whatever keeps this thread busy next.
        CATransaction.flush()
    }

    /// Back to the video that was showing. `holdingPicture`: it still has no picture of its own, so what stood in for it
    /// goes on doing that.
    func cancelVideoSwipe(holdingPicture: Bool) {
        // Going on by itself nothing moved, and a picture standing in for this video just goes on doing that.
        if holdingCover === swipeCover { return }
        swipeGeneration += 1
        let generation = swipeGeneration
        swipeCover.showsSpinner = false
        if holdingPicture, leavingCoverHeld { holdingCover = leavingCover }
        leavingCoverHeld = false
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.setVideoSwipe(offset: 0, coverFromBelow: self.swipeCoverFromBelow)
        } completion: { _ in
            guard generation == self.swipeGeneration else { return }
            self.swipeCover.isHidden = true
            self.swipeCover.clearStill()
            if self.holdingCover !== self.leavingCover {
                self.leavingCover.isHidden = true
                self.leavingCover.clearStill()
            }
        }
    }

    /// The new video is loading: the picture is back in place. `holdingPicture`: behind the one that slid in, which stays
    /// until the video shows its own (`releaseSwipePicture`). Otherwise nothing of the swipe stays.
    func finishVideoSwipe(holdingPicture: Bool) {
        swipeGeneration += 1
        stopSwipeAnimations()
        videoView.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        danmaku.transform = .identity
        leavingCover.transform = .identity
        leavingCover.isHidden = true
        leavingCover.alpha = 1
        leavingCover.clearStill()
        swipeCover.transform = .identity
        swipeCover.alpha = 1
        swipeCover.showsSpinner = false
        leavingCoverHeld = false
        holdingCover = holdingPicture ? swipeCover : nil
        if !holdingPicture {
            swipeCover.isHidden = true
            swipeCover.clearStill()
        }
    }

    /// The video shows its own picture.
    func releaseSwipePicture() {
        guard let holding = holdingCover else { return }
        holdingCover = nil
        let generation = swipeGeneration
        UIView.animate(withDuration: 0.08) {
            holding.alpha = 0
        } completion: { _ in
            guard generation == self.swipeGeneration else { return }
            holding.isHidden = true
            holding.alpha = 1
            holding.clearStill()
        }
    }

    // MARK: Pinch zoom (双指缩放, 「还原屏幕」)

    /// Applies a pinch scale, clamped to `zoomRange`.
    func setZoom(_ scale: CGFloat) {
        let s = min(max(scale.isFinite ? scale : 1, PlayerSurfaceView.zoomRange.lowerBound),
                    PlayerSurfaceView.zoomRange.upperBound)
        guard s != zoomScale else { return }
        zoomScale = s
        videoView.transform = CGAffineTransform(scaleX: s, y: s)
        updateRestoreButton()
    }

    /// 「还原屏幕」: back to the unscaled picture (animated over 255 ms when asked).
    func resetZoom(animated: Bool) {
        guard zoomScale != 1 else { return }
        zoomScale = 1
        updateRestoreButton()
        if animated {
            UIView.animate(withDuration: 0.255, delay: 0, options: [.curveEaseOut]) {
                self.videoView.transform = .identity
            }
        } else {
            videoView.transform = .identity
        }
    }

    private func setUpRestoreButton() {
        restoreButton.setTitle("还原屏幕", for: .normal)
        restoreButton.setTitleColor(.white, for: .normal)
        restoreButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        restoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        restoreButton.backgroundColor = UIColor(white: 0.15, alpha: 0.8)
        restoreButton.layer.cornerRadius = 6
        restoreButton.isHidden = true
        restoreButton.addAction(UIAction { [weak self] _ in
            self?.resetZoom(animated: true)
            self?.controller?.overlay.poke()
        }, for: .touchUpInside)
        addSubview(restoreButton)
    }

    private var onVerticalScreen: Bool { controller?.isOnVerticalScreen == true }

    /// Shown while the picture is zoomed and the controls are visible (features.md §1.7), which on the vertical-video
    /// screen they always are.
    private func updateRestoreButton() {
        let show = zoomScale != 1 && (chromeVisible || onVerticalScreen) && !chromeLocked
        guard restoreButton.isHidden == show else { return }
        restoreButton.isHidden = !show
        if show {
            bringSubviewToFront(restoreButton)
            layoutRestoreButton()
        }
    }

    private func layoutRestoreButton() {
        guard !restoreButton.isHidden else { return }
        let title = restoreButton.titleLabel?.intrinsicContentSize ?? .zero
        let size = CGSize(width: ceil(title.width) + 30, height: ceil(title.height) + 16)
        // 95 pt above the bottom in fullscreen; the inline player is too short for that. The vertical-video screen has
        // the uploader and title there.
        let gap: CGFloat = onVerticalScreen ? VerticalVideoMetrics.infoHeight + 30
            : controller?.isFullscreen == true ? 95 : min(95, bounds.height * 0.3)
        restoreButton.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - gap - size.height,
                                     width: size.width, height: size.height)
    }

    // MARK: 点击弹幕 bubble

    var isDanmakuBubbleVisible: Bool { bubble != nil }

    /// Shows the action bubble for the danmaku frozen by `danmaku.suspendDanmaku(at:)`; `point` is the tap.
    func showDanmakuBubble(for hit: DanmakuOverlayHit, at point: CGPoint) {
        guard let controller, danmaku.hasSuspendedDanmaku else { return }
        removeBubbleView()
        let view = DanmakuActionBubbleView(frame: .zero)
        let seek = DanmakuTimestamp.seconds(in: hit.item.readableText, duration: controller.duration)
        view.configure(item: hit.item, like: danmaku.likeState(of: hit.item), seekTarget: seek)
        view.onAction = { [weak self, weak view] action in
            guard let self, let view else { return }
            self.perform(action, item: hit.item, from: view)
        }
        addSubview(view)
        view.place(anchor: danmaku.convert(hit.frame, to: self), pointX: point.x, in: bounds)
        bubble = view
        controller.overlay.danmakuBubbleOpen = true
        controller.overlay.hideControls()
    }

    /// Closes the bubble and lets the danmaku go on.
    func dismissDanmakuBubble() {
        removeBubbleView()
        danmaku.resume()
    }

    private func removeBubbleView() {
        bubble?.removeFromSuperview()
        bubble = nil
        controller?.overlay.danmakuBubbleOpen = false
    }

    private func perform(_ action: DanmakuActionBubbleView.Action, item: DanmakuItem, from view: DanmakuActionBubbleView) {
        guard let controller else { return }
        let cid = controller.item?.cid ?? 0
        let source = view.frame
        switch action {
        case .like:
            let overlay = danmaku
            Task { @MainActor [weak self] in
                await DanmakuActions.toggleLike(item, cid: cid, overlay: overlay)
                if let self, self.bubble === view { self.dismissDanmakuBubble() }
            }
        case .copy:
            DanmakuActions.copy(item)
            dismissDanmakuBubble()
        case .report:
            dismissDanmakuBubble()
            presentReportSheet(for: item, cid: cid, source: source)
        case .recall:
            dismissDanmakuBubble()
            presentRecallConfirm(for: item, cid: cid, source: source)
        case .block:
            dismissDanmakuBubble()
            presentBlockSheet(for: item, source: source)
        case .seek(let time):
            dismissDanmakuBubble()
            controller.seek(to: time)
        }
    }

    private func presentReportSheet(for item: DanmakuItem, cid: Int64, source: CGRect) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        let sheet = UIAlertController(title: "举报弹幕", message: item.readableText, preferredStyle: .actionSheet)
        for reason in DanmakuService.reportReasons {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { _ in
                Task { @MainActor in await DanmakuActions.report(item, cid: cid, reason: reason.id) }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func presentRecallConfirm(for item: DanmakuItem, cid: Int64, source: CGRect) {
        let sheet = UIAlertController(title: "撤回这条弹幕？", message: "每天的撤回次数有限。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "撤回", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await DanmakuActions.recall(item, cid: cid, overlay: self.danmaku) }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func presentBlockSheet(for item: DanmakuItem, source: CGRect) {
        let keyword = DanmakuActions.blockKeyword(for: item)
        let sheet = UIAlertController(title: "屏蔽", message: nil, preferredStyle: .actionSheet)
        if !item.midHash.isEmpty {
            sheet.addAction(UIAlertAction(title: "屏蔽发送者", style: .destructive) { _ in
                DanmakuActions.blockSender(item)
            })
        }
        if !keyword.isEmpty {
            sheet.addAction(UIAlertAction(title: "屏蔽关键词「\(keyword)」", style: .destructive) { _ in
                DanmakuActions.blockContent(item)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, source: source)
    }

    private func present(_ sheet: UIAlertController, source: CGRect) {
        guard let host = danmakuPresentingViewController else { return }
        // iPad shows action sheets as popovers: anchor it where the bubble was.
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = source
        host.present(sheet, animated: true)
    }

    private func applyAspect() {
        updateVideoGravity()
        setNeedsLayout()
    }

    /// A landscape video on the vertical-video screen shows whole, above the uploader and title, whatever 「画面比例」
    /// says for landscape fullscreen.
    private var showsWholeOnVerticalScreen: Bool { onVerticalScreen && controller?.isVerticalVideo == false }

    /// Where that picture is, once its shape is known.
    var wholePictureRect: CGRect? {
        guard showsWholeOnVerticalScreen, videoSize.width > 0, videoSize.height > 0 else { return nil }
        return AVMakeRect(aspectRatio: videoSize, insideRect: VerticalVideoMetrics.wholePictureFrame(in: bounds))
    }

    /// Where the video shows on this surface.
    var pictureRect: CGRect {
        if let wholePictureRect { return wholePictureRect }
        guard videoSize.width > 0, videoSize.height > 0, videoView.playerLayer.videoGravity == .resizeAspect else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// 自适应 on the vertical-video screen goes by the video's shape (`VerticalVideoMetrics.fills`).
    private func updateVideoGravity() {
        let gravity: AVLayerVideoGravity
        if showsWholeOnVerticalScreen {
            gravity = .resizeAspect
        } else {
            switch aspectMode {
            case .fit: gravity = onVerticalScreen && VerticalVideoMetrics.fills(video: videoSize, area: bounds.size) ? .resizeAspectFill : .resizeAspect
            case .fill: gravity = .resizeAspectFill
            case .stretch, .ratio16x9, .ratio4x3: gravity = .resize
            }
        }
        guard videoView.playerLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.playerLayer.videoGravity = gravity
        CATransaction.commit()
    }

    private func videoFrame() -> CGRect {
        if showsWholeOnVerticalScreen { return VerticalVideoMetrics.wholePictureFrame(in: bounds) }
        switch aspectMode {
        case .ratio16x9: return fitted(ratio: 16.0 / 9.0)
        case .ratio4x3: return fitted(ratio: 4.0 / 3.0)
        default: return bounds
        }
    }

    private func fitted(ratio: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, ratio > 0 else { return bounds }
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

/// What a video looked like when a swipe left it.
struct PlayerPictureStill {
    let view: UIView
    /// Where it goes on the surface.
    let frame: CGRect
    /// The surface it was taken on: of no use on one of another size.
    let surfaceSize: CGSize
}

/// A video's picture before the video shows it, placed the way the video will be.
struct PlayerSwipePicture {
    var url: String
    var frame: CGRect
    var contentMode: UIView.ContentMode
    var still: PlayerPictureStill?
}

/// A video's picture for as long as the video has none to show: where it was left, its first frame, or its cover.
final class PlayerSwipeCoverView: UIView {
    /// An image the size of the phone's screen, or nearly, would take too much memory for five videos.
    static func firstFrameURL(_ frame: String) -> String { RemoteImage.resolvedURL(frame, width: 300) }

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var url = ""
    private var still: UIView?

    var showsSpinner = false {
        didSet { showsSpinner ? spinner.startAnimating() : spinner.stopAnimating() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = .black
        clipsToBounds = true
        addSubview(imageView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ picture: PlayerSwipePicture) {
        if imageView.contentMode != picture.contentMode { imageView.contentMode = picture.contentMode }
        if imageView.frame != picture.frame { imageView.frame = picture.frame }
        setImage(picture.url)
        if let shown = picture.still {
            if still !== shown.view || shown.view.superview !== self {
                clearStill()
                still = shown.view
                insertSubview(shown.view, aboveSubview: imageView)
            }
            shown.view.frame = shown.frame
        } else {
            clearStill()
        }
    }

    /// It remains the controller's, which may show it again. Here only while it is in this view.
    func clearStill() {
        if still?.superview === self { still?.removeFromSuperview() }
        still = nil
    }

    private func setImage(_ next: String) {
        guard next != url else { return }
        url = next
        imageView.image = ImagePipeline.shared.cached(next)
        guard imageView.image == nil, !next.isEmpty else { return }
        Task { @MainActor [weak self] in
            let image = await ImagePipeline.shared.image(for: next)
            guard let self, self.url == next else { return }
            self.imageView.image = image
        }
    }
}

enum PlayerStageRole: Equatable {
    case inline, fullscreen
}

/// Holds the controller's surface while this host's role is active (inline when not fullscreen, fullscreen
/// otherwise).
final class PlayerSurfaceHostView: UIView {
    let role: PlayerStageRole
    private weak var controller: PlayerController?
    private var cancellable: AnyCancellable?
    /// The picture as it was when the other stage took the surface (`keepStill`).
    private var still: UIView?

    init(controller: PlayerController, role: PlayerStageRole) {
        self.role = role
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        // @Published emits in willSet: use the emitted value, not the property.
        cancellable = controller.$surfaceInFullscreen.sink { [weak self] fullscreen in
            self?.claim(isFullscreen: fullscreen)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func claimIfActive() {
        guard let controller else { return }
        claim(isFullscreen: controller.surfaceInFullscreen)
    }

    private func claim(isFullscreen: Bool) {
        guard let controller, (isFullscreen ? PlayerStageRole.fullscreen : .inline) == role else { return }
        let surface = controller.surface
        guard surface.superview !== self else { return }
        (surface.superview as? PlayerSurfaceHostView)?.keepStill(of: surface)
        surface.removeFromSuperview()
        still?.removeFromSuperview()
        still = nil
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }

    /// The stage the surface leaves can still be on screen, fading out or in around fullscreen: it shows a still of
    /// the picture until the surface comes back, instead of going black.
    private func keepStill(of surface: UIView) {
        still?.removeFromSuperview()
        still = surface.snapshotView(afterScreenUpdates: false)
        guard let still else { return }
        still.frame = bounds
        still.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(still)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { claimIfActive() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let surface = controller?.surface, surface.superview === self { surface.frame = bounds }
    }

    func releaseSurface() {
        cancellable = nil
        if let surface = controller?.surface, surface.superview === self { surface.removeFromSuperview() }
    }
}

struct PlayerSurfaceRepresentable: UIViewRepresentable {
    let controller: PlayerController
    let role: PlayerStageRole

    func makeUIView(context: Context) -> PlayerSurfaceHostView {
        PlayerSurfaceHostView(controller: controller, role: role)
    }

    func updateUIView(_ uiView: PlayerSurfaceHostView, context: Context) {
        uiView.claimIfActive()
    }

    static func dismantleUIView(_ uiView: PlayerSurfaceHostView, coordinator: ()) {
        uiView.releaseSurface()
    }
}

// MARK: - 画面比例 persistence

extension PlayerAspectMode {
    /// The mode stored in 「画面比例」 (`PlayerSettings.aspectMode`), for a video about to play: a stored 拉伸 shows
    /// vertical videos 自适应 instead (features.md §3.6; the stored choice stays 拉伸).
    static func stored(forVertical vertical: Bool) -> PlayerAspectMode {
        let mode = PlayerAspectMode(rawValue: AppSettings.shared.player.aspectMode) ?? .fit
        return mode == .stretch && vertical ? .fit : mode
    }
}

// MARK: - Subtitles

/// The subtitle line in the 「字幕设置」 style (features.md §3.7): 16 pt × 字体大小 (全屏字体大小 in fullscreen)
/// at 字体粗细, white on black at 背景不透明度 — with a transparent background a black 描边 instead —, kept
/// 左右边距 from the sides and 底部边距 from the bottom (raised to `minBottom` above visible controls).
struct PlayerSubtitleView: View {
    let text: String
    let style: PlayerSettings
    let fullscreen: Bool
    /// Bottom inset the visible controls need (0 while they are hidden).
    let minBottom: CGFloat

    private static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold,
                                                 .heavy, .black]

    private var fontSize: CGFloat {
        let scale = fullscreen ? style.subtitleFontScaleFullscreen : style.subtitleFontScale
        return 16 * CGFloat(min(max(scale, 0.5), 2.5))
    }

    private var weight: Font.Weight {
        PlayerSubtitleView.weights[min(max(style.subtitleFontWeight, 0), PlayerSubtitleView.weights.count - 1)]
    }

    private var backgroundOpacity: Double { min(max(style.subtitleBgOpacity, 0), 1) }

    /// Outline width; only without a background.
    private var stroke: CGFloat {
        backgroundOpacity > 0.005 ? 0 : CGFloat(min(max(style.subtitleStrokeWidth, 0), 5)) / 2
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            // Line height ≈ 1.5.
            .lineSpacing(fontSize * 0.3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: stroke, y: 0)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: -stroke, y: 0)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: 0, y: stroke)
            .shadow(color: stroke > 0 ? .black : .clear, radius: 0, x: 0, y: -stroke)
            .padding(.horizontal, CGFloat(min(max(style.subtitlePaddingH, 0), 100)))
            .padding(.bottom, max(CGFloat(min(max(style.subtitleBottomPadding, 0), 200)), minBottom))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }
}
