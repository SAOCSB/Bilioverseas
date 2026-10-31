import SwiftUI
import UIKit

// Building blocks of the player chrome: buttons, the progress bar (buffered track, chapter ticks, SmartSkip / 片头片尾
// strips), time labels, HUD pills, the seek thumbnail and the error / buffering / prompt views.

enum PlayerFormat {
    /// 2 → "2.0", 1.25 → "1.25".
    static func rate(_ r: Double) -> String {
        let rounded = (r * 100).rounded() / 100
        let tenths = rounded * 10
        if abs(tenths - tenths.rounded()) < 0.001 { return String(format: "%.1f", rounded) }
        return String(format: "%.2f", rounded)
    }

    static func time(_ seconds: Double) -> String {
        Fmt.duration(seconds.isFinite ? max(0, seconds) : 0)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Buttons

struct PlayerIconButton: View {
    let systemName: String
    var size: CGFloat = 18
    var width: CGFloat = 36
    /// VoiceOver label (the SF Symbol name otherwise).
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.white)
                .frame(width: width, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if let label {
            button.accessibilityLabel(Text(label))
        } else {
            button
        }
    }
}

struct PlayerTextButton: View {
    let title: String
    var highlighted = false
    var fontSize: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(highlighted ? .biliPink : .white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 「弹」 toggle glyph (outlined box, struck through when off).
struct PlayerDanmakuToggleIcon: View {
    let enabled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white, lineWidth: 1.4)
                .frame(width: 22, height: 17)
            Text("弹")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            if !enabled {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 27, height: 1.6)
                    .rotationEffect(.degrees(-35))
            }
        }
        .opacity(enabled ? 1 : 0.8)
        .frame(width: 34, height: 36)
        .contentShape(Rectangle())
    }
}

// MARK: - Progress

struct PlayerProgressBar: View {
    @ObservedObject var timeline: PlayerTimeline
    let chapters: [VideoChapter]
    let segments: [AdSegment]
    let clips: [PGCClipInfo]
    var barHeight: CGFloat = 3
    var thumbSize: CGFloat = 12
    /// The touch area, with the line in its middle.
    var height: CGFloat = 28
    /// The vertical-video screen's bar: the little TV instead of the round thumb, and only sideways drags
    /// (`PlayerScrubTouchArea`), as up and down go to another video there.
    var verticalScreenStyle = false
    /// Up and down drags, where nothing under the bar gets them (the 短视频 feed's pager does): the distance so far.
    var onVerticalDragMoved: ((CGFloat) -> Void)? = nil
    /// The distance and speed when the finger lifted (0, 0 when the drag was cancelled).
    var onVerticalDragEnded: ((CGFloat, CGFloat) -> Void)? = nil
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void
    /// The drag went away without `onEnded` (touch cancelled by the system, or the bar removed mid-drag: controls
    /// hidden by a tap, lock, fullscreen hand-over). Must undo what `onScrubBegan` / `onScrubChanged` did.
    var onScrubCancelled: () -> Void = {}

    @State private var scrubFraction: Double?
    @GestureState private var isTouching = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let snap = timeline.snapshot
            let total = snap.duration
            let played = scrubFraction ?? (total > 0 ? min(1, max(0, snap.time / total)) : 0)
            let buffered = total > 0 ? min(1, max(0, snap.buffered / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: barHeight)
                Capsule().fill(Color.white.opacity(0.45)).frame(width: width * buffered, height: barHeight)
                Capsule().fill(Color.biliPink).frame(width: width * played, height: barHeight)
                if total > 0 {
                    markers(width: width, total: total)
                }
                if verticalScreenStyle {
                    VerticalVideoProgressMascot()
                        .offset(x: width * played - 9, y: -1)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: width * played - thumbSize / 2)
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(verticalScreenStyle ? nil : DragGesture(minimumDistance: 0)
                .updating($isTouching) { _, touching, _ in touching = true }
                .onChanged { value in scrub(to: Double(value.location.x / width), total: total) }
                .onEnded { value in endScrub(at: Double(value.location.x / width), total: total) }
            )
            .overlay {
                if verticalScreenStyle {
                    PlayerScrubTouchArea(onMoved: { scrub(to: Double($0), total: total) },
                                         onEnded: { endScrub(at: Double($0), total: total) },
                                         onCancelled: { cancelScrub() },
                                         onVerticalDragMoved: onVerticalDragMoved,
                                         onVerticalDragEnded: onVerticalDragEnded)
                }
            }
        }
        .frame(height: height)
        // `onEnded` is not called for a cancelled drag; without this the preview stayed on screen and the
        // auto-hide hold was never released (controls stuck visible until the next video).
        .onChange(of: isTouching) { touching in
            if !touching { cancelScrub() }
        }
        .onDisappear { cancelScrub() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("播放进度"))
        .accessibilityValue(Text("\(PlayerFormat.time(timeline.snapshot.time))/\(PlayerFormat.time(timeline.snapshot.duration))"))
        .accessibilityAdjustableAction { direction in
            let snap = timeline.snapshot
            guard snap.duration > 0 else { return }
            let step = max(10, snap.duration / 20)
            let target = direction == .increment ? snap.time + step : snap.time - step
            onScrubBegan()
            onScrubEnded(min(max(target, 0), snap.duration))
        }
    }

    private func scrub(to fraction: Double, total: Double) {
        // Unknown duration: a tap would seek to 0.
        guard total > 0 else { return }
        let f = min(1, max(0, fraction))
        if scrubFraction == nil { onScrubBegan() }
        scrubFraction = f
        onScrubChanged(f * total)
    }

    private func endScrub(at fraction: Double, total: Double) {
        guard total > 0 else { return }
        scrubFraction = nil
        onScrubEnded(min(1, max(0, fraction)) * total)
    }

    private func cancelScrub() {
        guard scrubFraction != nil else { return }
        scrubFraction = nil
        onScrubCancelled()
    }

    @ViewBuilder
    private func markers(width: CGFloat, total: Double) -> some View {
        PlayerProgressStrips(segments: segments, clips: clips, total: total, width: width, height: barHeight)
        ForEach(Array(chapters.enumerated()), id: \.offset) { pair in
            if pair.element.from > 0.5, pair.element.from < total - 0.5 {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 2, height: barHeight)
                    .offset(x: width * CGFloat(pair.element.from / total) - 1)
            }
        }
    }
}

/// The touch area of the vertical-video screen's bar. A drag that goes up or down is refused, so that it pages the
/// 短视频 feed (whose collection view's pan then gets it) instead of seeking: SwiftUI's `DragGesture` cannot let go of a
/// touch it has. The player's vertical fullscreen has nothing above this view to get it, so there it is passed on.
struct PlayerScrubTouchArea: UIViewRepresentable {
    /// The finger's position as a fraction of the width.
    let onMoved: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void
    var onVerticalDragMoved: ((CGFloat) -> Void)?
    var onVerticalDragEnded: ((CGFloat, CGFloat) -> Void)?

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.area = self
    }

    final class TouchView: UIView, UIGestureRecognizerDelegate {
        var area: PlayerScrubTouchArea?
        private let pan = UIPanGestureRecognizer()
        private let tap = UITapGestureRecognizer()
        /// A drag is under way whose end has not been reported.
        private var dragging = false
        private var dragsVertically = false

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            pan.addTarget(self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            tap.addTarget(self, action: #selector(handleTap(_:)))
            tap.delegate = self
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // UIKit also asks this view about recognizers of its ancestors: leave those alone.
            guard gestureRecognizer === pan else { return true }
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) >= abs(velocity.y) || area?.onVerticalDragMoved != nil
        }

        private func fraction(_ recognizer: UIGestureRecognizer) -> CGFloat {
            recognizer.location(in: self).x / max(bounds.width, 1)
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            area?.onMoved(fraction(g))
            area?.onEnded(fraction(g))
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                let velocity = g.velocity(in: self)
                dragging = true
                dragsVertically = abs(velocity.y) > abs(velocity.x)
                moved(g)
            case .changed:
                moved(g)
            case .ended:
                guard dragging else { return }
                dragging = false
                if dragsVertically {
                    area?.onVerticalDragEnded?(g.translation(in: self).y, g.velocity(in: self).y)
                } else {
                    area?.onEnded(fraction(g))
                }
            case .cancelled, .failed:
                cancel()
            default:
                break
            }
        }

        private func moved(_ g: UIPanGestureRecognizer) {
            guard dragging else { return }
            if dragsVertically {
                area?.onVerticalDragMoved?(g.translation(in: self).y)
            } else {
                area?.onMoved(fraction(g))
            }
        }

        private func cancel() {
            guard dragging else { return }
            dragging = false
            if dragsVertically {
                area?.onVerticalDragEnded?(0, 0)
            } else {
                area?.onCancelled()
            }
        }

        /// Taken away mid-drag (the controls changed with the video, fullscreen left): UIKit may not report the end.
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow == nil, dragging else { return }
            cancel()
            // Disabling a running recognizer cancels it; its `.cancelled` callback is a no-op now.
            pan.isEnabled = false
            pan.isEnabled = true
        }
    }
}

/// PGC 片头/片尾 and SmartSkip / 空降助手 strips over a progress track (shared by the bar and the thin line).
struct PlayerProgressStrips: View {
    let segments: [AdSegment]
    let clips: [PGCClipInfo]
    let total: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ForEach(clips, id: \.self) { clip in
            strip(from: clip.start, to: clip.end, color: Color.biliBlue.opacity(0.8))
        }
        ForEach(segments) { segment in
            strip(from: segment.start, to: segment.end, color: segment.stripColor)
        }
    }

    private func strip(from start: Double, to end: Double, color: Color) -> some View {
        let s = min(max(start, 0), total)
        let e = min(max(end, s), total)
        return Rectangle()
            .fill(color)
            .frame(width: max(2, width * CGFloat((e - s) / total)), height: height)
            .offset(x: width * CGFloat(s / total))
    }
}

/// 2 pt progress line while the controls are hidden, with the same strips as the bar (features.md §2.4 / §11.4).
struct PlayerThinProgress: View {
    @ObservedObject var timeline: PlayerTimeline
    var segments: [AdSegment] = []
    var clips: [PGCClipInfo] = []

    var body: some View {
        GeometryReader { geo in
            let snap = timeline.snapshot
            let total = snap.duration
            let played = total > 0 ? min(1, max(0, snap.time / total)) : 0
            let buffered = total > 0 ? min(1, max(0, snap.buffered / total)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.15))
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: geo.size.width * buffered)
                Rectangle().fill(Color.biliPink).frame(width: geo.size.width * played)
                if total > 0, !segments.isEmpty || !clips.isEmpty {
                    PlayerProgressStrips(segments: segments, clips: clips, total: total,
                                         width: max(geo.size.width, 1), height: 2)
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

struct PlayerTimeText: View {
    enum Style { case current, total, combined }

    @ObservedObject var timeline: PlayerTimeline
    let style: Style
    /// Scrub target (shown instead of the playback time while dragging).
    var overrideTime: Double?

    var body: some View {
        let snap = timeline.snapshot
        let current = PlayerFormat.time(overrideTime ?? snap.time)
        let total = PlayerFormat.time(snap.duration)
        let text: String
        switch style {
        case .current: text = current
        case .total: text = total
        case .combined: text = "\(current)/\(total)"
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            // Plain labels over the video: let taps through to the gesture layer (toggle controls).
            .allowsHitTesting(false)
    }
}

// MARK: - HUD pieces

struct PlayerPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

/// Volume / brightness pill.
struct PlayerLevelPill: View {
    let hud: PlayerLevelHUD

    private var icon: String {
        switch hud.kind {
        case .volume:
            if hud.value <= 0.001 { return "speaker.slash.fill" }
            return hud.value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .brightness:
            if hud.value < 1.0 / 3 { return "sun.min.fill" }
            return hud.value < 2.0 / 3 ? "sun.max" : "sun.max.fill"
        }
    }

    var body: some View {
        PlayerPill {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16))
                Text("\(Int((hud.value * 100).rounded()))%").monospacedDigit()
            }
        }
        .allowsHitTesting(false)
    }
}

/// Side indicator of a double-tap seek (「快进10秒」).
struct PlayerDoubleTapIndicator: View {
    let hint: PlayerDoubleTapHint
    let size: CGSize

    var body: some View {
        HStack(spacing: 0) {
            if hint.forward { Spacer(minLength: 0) }
            ZStack {
                LinearGradient(colors: [Color(white: 0.46, opacity: 0.53), Color(white: 0.46, opacity: 0)],
                               startPoint: hint.forward ? .trailing : .leading,
                               endPoint: hint.forward ? .leading : .trailing)
                HStack(spacing: 8) {
                    Image(systemName: hint.forward ? "forward.fill" : "backward.fill")
                        .font(.system(size: 22))
                    Text(hint.forward ? "快进\(hint.seconds)秒" : "快退\(hint.seconds)秒")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
            }
            .frame(width: size.width / 4)
            if !hint.forward { Spacer(minLength: 0) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// One videoshot tile for the scrub preview.
struct PlayerSeekThumbnail: View {
    let shot: VideoShotInfo
    let time: Double
    let height: CGFloat

    @State private var sheetURL = ""
    @State private var sheetImage: UIImage?

    var body: some View {
        let tile = shot.tile(at: time)
        let ratio = CGFloat(max(shot.tileWidth, 1)) / CGFloat(max(shot.tileHeight, 1))
        let url = tile?.image ?? ""
        return ZStack {
            Color.black.opacity(0.5)
            if let tile, let image = sheetImage, sheetURL == tile.image,
               let cropped = Self.crop(image, shot: shot, column: tile.column, row: tile.row) {
                Image(uiImage: cropped)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: height * ratio, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 1.5))
        .task(id: url) {
            guard !url.isEmpty, url != sheetURL || sheetImage == nil else { return }
            let image = await ImagePipeline.shared.image(for: url)
            guard !Task.isCancelled else { return }
            sheetURL = url
            sheetImage = image
        }
    }

    static func crop(_ image: UIImage, shot: VideoShotInfo, column: Int, row: Int) -> UIImage? {
        guard let cg = image.cgImage, shot.columns > 0, shot.tileWidth > 0, shot.tileHeight > 0 else { return nil }
        let expectedWidth = CGFloat(shot.columns * shot.tileWidth)
        let scale = expectedWidth > 0 ? CGFloat(cg.width) / expectedWidth : 1
        let tileW = CGFloat(shot.tileWidth) * scale
        let tileH = CGFloat(shot.tileHeight) * scale
        let rect = CGRect(x: CGFloat(column) * tileW, y: CGFloat(row) * tileH, width: tileW, height: tileH).integral
        guard rect.width > 0, rect.height > 0, rect.maxX <= CGFloat(cg.width) + 1, rect.maxY <= CGFloat(cg.height) + 1,
              let part = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: part)
    }
}

struct PlayerBufferingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.1)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(20)
        .background(RadialGradient(colors: [Color.black.opacity(0.26), .clear], center: .center,
                                   startRadius: 0, endRadius: 70))
        .allowsHitTesting(false)
    }
}

struct PlayerErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.85))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            Button(action: retry) {
                Text("重试")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
                    .background(Color.biliPink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 「跳过片头」 / 「跳过片尾」 capsule (PGC clips).
struct PlayerClipSkipButton: View {
    let title: String
    let onSkip: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSkip) {
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill").font(.system(size: 11, weight: .bold))
                    Text(title).font(.system(size: 14, weight: .bold))
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 18)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭跳过提示"))
        }
        .foregroundColor(.white)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
        .clipShape(Capsule())
        .fixedSize()
    }
}

/// 「已为你定位至 mm:ss」 + 「从头播放」.
struct PlayerResumeChip: View {
    let time: Double
    let onRestart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("已为你定位至 \(PlayerFormat.time(time))")
                .font(.system(size: 12))
                .foregroundColor(.white)
            Button(action: onRestart) {
                Text("从头播放")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.biliPink)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.7), in: Capsule())
        .fixedSize()
    }
}

/// 「上次看到第N P，点击跳转」 (bottom-left, like the resume chip).
struct PlayerResumePartChip: View {
    let page: Int
    let onJump: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onJump) {
                Text("上次看到第\(page)P，点击跳转")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.7), in: Capsule())
        .fixedSize()
    }
}

/// Fullscreen 点赞 / 投币 / 收藏 / 分享, right-aligned under the top bar (long press 点赞 = 一键三连).
struct PlayerFullscreenActionRow: View {
    let actions: PlayerFullscreenActions
    /// Any touch keeps the controls up.
    let onInteraction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            item(count: actions.likeCount, active: actions.liked) { symbol(actions.liked ? "hand.thumbsup.fill" : "hand.thumbsup") }
                .onTapGesture {
                    onInteraction()
                    actions.onLike()
                }
                .onLongPressGesture(minimumDuration: 0.8) {
                    onInteraction()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    actions.onTriple()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(actions.liked ? "取消点赞" : "点赞"))
                .accessibilityHint(Text("长按一键三连"))
            Button {
                onInteraction()
                actions.onCoin()
            } label: {
                item(count: actions.coinCount, active: actions.coined) { coinGlyph }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("投币"))
            Button {
                onInteraction()
                actions.onFavorite()
            } label: {
                item(count: actions.favoriteCount, active: actions.favored) { symbol(actions.favored ? "star.fill" : "star") }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("收藏"))
            if let url = actions.shareURL {
                ShareLink(item: url, subject: Text(actions.shareTitle), message: Text(actions.shareTitle)) {
                    item(count: actions.shareCount, active: false) { symbol("arrowshape.turn.up.right") }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { onInteraction() })
                .accessibilityLabel(Text("分享"))
            }
        }
    }

    private func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName).font(.system(size: 19, weight: .medium))
    }

    /// 「币」 in a circle (filled once coins were given).
    private var coinGlyph: some View {
        ZStack {
            if actions.coined {
                Circle().fill(Color.biliPink).frame(width: 20, height: 20)
            } else {
                Circle().stroke(Color.white, lineWidth: 1.6).frame(width: 19, height: 19)
            }
            Text("币")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 22, height: 22)
    }

    private func item<Icon: View>(count: Int64, active: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 1) {
            icon()
            Text(count > 0 ? Fmt.count(count) : " ")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(active ? .biliPink : .white)
        .frame(width: 42, height: 42)
        .contentShape(Rectangle())
    }
}

/// BTR statistics overlay (「加速统计」).
struct PlayerStatsOverlay: View {
    let stats: AccelerationStats
    let stream: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line(stats.accelerated ? "BTR 加速中" : "直连（未加速）")
            if !stream.isEmpty { line(stream) }
            line("线程 \(stats.threads) · 连接 \(stats.activeConnections) · \(Fmt.speed(stats.bytesPerSecond))")
            line("已缓存 \(String(format: "%.1f", stats.cachedAheadSeconds))s · 共 \(Fmt.bytes(Double(stats.totalBytes)))")
            if stats.hedgedBytes > 0 { line("对冲 \(Fmt.bytes(Double(stats.hedgedBytes)))") }
            let healthy = stats.nodes.filter { $0.state == .healthy }.count
            line("节点 \(healthy)/\(stats.nodes.count)" + (stats.fallbackActive ? " · 已回退直连" : ""))
            ForEach(Array(stats.nodes.prefix(4).enumerated()), id: \.offset) { pair in
                line("  \(pair.element.host) \(pair.element.state.rawValue) \(Fmt.speed(pair.element.bytesPerSecond))")
            }
            if !stats.autoReason.isEmpty { line(stats.autoReason) }
        }
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white)
            .lineLimit(1)
    }
}
