import SwiftUI
import UIKit

// The official app's vertical-video screen, shared by the 短视频 feed and the player's vertical fullscreen. The status
// bar stays and the picture sits between it and a black bar with 发弹幕 and the 弹幕 switch. Over the picture: back and
// 「N人正在看」 top left, search and ⋮ top right, 点赞 / 评论 / 投币 / 收藏 / 转发 down the right, the uploader and title
// bottom left, the progress line along the bottom edge. Swipes also bring landscape videos here, which show whole
// (`wholePictureFrame`), and for which the bar offers 全屏.

enum VerticalVideoMetrics {
    /// The bar below the picture, not counting the home indicator's inset.
    static let bottomBarHeight: CGFloat = 60
    /// The top bar over the picture; danmaku start below it.
    static let topBarHeight: CGFloat = 44
    /// What the uploader and title take above the picture's bottom edge: subtitles and prompts stay above it.
    static let infoHeight: CGFloat = 130
    /// How far the progress bar's touch area reaches below the picture: the line itself runs just above its edge.
    static let progressOverhang: CGFloat = 3
    /// How far the uploader, the title and the buttons reach down into that touch area, which is mostly empty.
    static let progressOverlap: CGFloat = 6

    /// How far the safe area starts below the status bar (some points on Dynamic Island phones). The picture starts
    /// right under the status bar, so the screen reaches this far above its safe area.
    @MainActor private(set) static var statusBarGap: CGFloat = 0

    /// Outside SwiftUI's updates only: reading a window's safe area from a view's body can lay the window out in the
    /// middle of one, and the cycle that makes leaves the view as it is, whatever changes later.
    @MainActor static func measureStatusBarGap() {
        guard let window = PlayerFullscreenPresenter.keyWindow(), window.windowScene?.interfaceOrientation.isPortrait == true,
              let height = window.windowScene?.statusBarManager?.statusBarFrame.height, height > 0 else { return }
        statusBarGap = max(window.safeAreaInsets.top - height, 0)
    }

    /// Where a landscape video goes in the picture area `bounds`: whole in what the uploader and title leave of it.
    static func wholePictureFrame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(bounds.height - infoHeight, 0))
    }

    /// A video about the shape of the picture area fills it, like the official app (a sliver of it is cut off); anything
    /// else shows whole.
    static func fills(video: CGSize, area: CGSize) -> Bool {
        guard video.width > 0, video.height > 0, area.width > 0, area.height > 0 else { return false }
        return abs((video.width / video.height) / (area.width / area.height) - 1) < 0.08
    }
}

/// A glyph of the bars, with the whole button as its touch area.
struct VerticalVideoBarIcon: View {
    let systemName: String
    var size: CGFloat = 20
    /// ⋮ is `ellipsis` turned upright.
    var upright = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .rotationEffect(.degrees(upright ? 90 : 0))
            .frame(width: 44, height: VerticalVideoMetrics.topBarHeight)
            .contentShape(Rectangle())
    }
}

/// Over the top of the picture. `onSearch` nil: no search button (a page without a navigation stack to search from).
struct VerticalVideoTopBar<More: View>: View {
    let online: String?
    let onBack: () -> Void
    var onSearch: (() -> Void)?
    @ViewBuilder let more: () -> More

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                VerticalVideoBarIcon(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("返回"))
            if let online {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                    Text(online)
                }
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .allowsHitTesting(false)
            }
            Spacer(minLength: 8)
            if let onSearch {
                Button(action: onSearch) {
                    VerticalVideoBarIcon(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("搜索"))
            }
            more()
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .padding(.horizontal, 2)
        .frame(height: VerticalVideoMetrics.topBarHeight)
    }
}

/// 点赞 (long press: 一键三连) / 评论 / 投币 / 收藏 / 转发, each with its count.
struct VerticalVideoActionColumn: View {
    let actions: PlayerFullscreenActions

    var body: some View {
        VStack(spacing: 16) {
            item(count: actions.likeCount, label: "点赞") { symbol("hand.thumbsup.fill", active: actions.liked) }
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.onLike)
                .onLongPressGesture(minimumDuration: 0.8) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    actions.onTriple()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(actions.liked ? "取消点赞" : "点赞"))
                .accessibilityHint(Text("长按一键三连"))
            button(count: actions.commentCount, label: "评论", action: actions.onComments) {
                symbol("ellipsis.bubble.fill", active: false)
            }
            button(count: actions.coinCount, label: "投币", action: actions.onCoin) { coinGlyph }
            button(count: actions.favoriteCount, label: "收藏", action: actions.onFavorite) {
                symbol("star.fill", active: actions.favored)
            }
            if let url = actions.shareURL {
                ShareLink(item: url, subject: Text(actions.shareTitle), message: Text(actions.shareTitle)) {
                    item(count: actions.shareCount, label: "转发") {
                        symbol("arrowshape.turn.up.right.fill", active: false)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("转发"))
            }
        }
        .frame(width: 54)
    }

    private func button<Icon: View>(count: Int64, label: String, action: @escaping () -> Void,
                                    @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) { item(count: count, label: label, icon: icon) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
    }

    private func item<Icon: View>(count: Int64, label: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 3) {
            icon()
                .frame(height: 34)
            Text(count > 0 ? Fmt.count(count) : label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .shadow(color: .black.opacity(0.45), radius: 2)
    }

    private func symbol(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 30))
            .foregroundColor(active ? .biliPink : .white)
    }

    /// 「币」 on a coin.
    private var coinGlyph: some View {
        ZStack {
            Circle().fill(actions.coined ? Color.biliPink : .white)
            Text("币")
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(actions.coined ? .white : .black.opacity(0.6))
        }
        .frame(width: 33, height: 33)
    }
}

/// Bottom left over the picture: the uploader with 关注 and 粉丝, then the title and 播放 (a tap unfolds the title).
struct VerticalVideoInfoView: View {
    let actions: PlayerFullscreenActions
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !actions.ownerName.isEmpty {
                uploader
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        titleText
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                        meta
                    }
                } else {
                    HStack(spacing: 6) {
                        titleText
                            .lineLimit(1)
                        meta
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uploader: some View {
        HStack(spacing: 10) {
            Button(action: actions.onUploader) {
                AvatarView(url: actions.ownerFace, size: 42)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(actions.ownerName))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button(action: actions.onUploader) {
                        Text(actions.ownerName)
                            .font(.system(size: 16, weight: .medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if actions.canFollow, !actions.following {
                        Button(action: actions.onFollow) {
                            Text("+ 关注")
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.biliPink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if actions.ownerFans > 0 {
                    Text("\(Fmt.count(actions.ownerFans))粉丝")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 15, weight: .medium))
    }

    private var meta: some View {
        HStack(spacing: 3) {
            if actions.viewCount > 0 {
                Text("\(Fmt.count(actions.viewCount))播放")
                    .font(.system(size: 13))
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.85))
        .fixedSize()
    }
}

/// Below the picture: 发弹幕 with the 弹幕 switch inside it (held: 弹幕设置), then 详情页 and 清屏 for a vertical video and
/// 全屏 for a landscape one. With the screen cleared, only the way back.
struct VerticalVideoBottomBar: View {
    let danmakuOn: Bool
    let landscape: Bool
    let cleared: Bool
    let onSend: () -> Void
    let onToggle: () -> Void
    let onSettings: () -> Void
    let onDetail: () -> Void
    let onClear: () -> Void
    let onFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if cleared {
                Spacer(minLength: 0)
                Button(action: onClear) {
                    Text("退出清屏")
                        .font(.system(size: 13))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(.white.opacity(0.14), in: Capsule())
                        .frame(height: VerticalVideoMetrics.bottomBarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            } else {
                danmakuField
                if landscape {
                    glyphButton("全屏", action: onFullscreen) {
                        VerticalVideoFullscreenGlyph()
                            .stroke(style: Self.glyphStroke)
                            .frame(width: 18, height: 18)
                    }
                } else {
                    detailButton
                    glyphButton("清屏", action: onClear) {
                        VerticalVideoClearGlyph()
                            .stroke(style: Self.glyphStroke)
                            .frame(width: 23, height: 18)
                    }
                }
            }
        }
        .foregroundColor(.white)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: VerticalVideoMetrics.bottomBarHeight)
    }

    private static let glyphStroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)

    private var danmakuField: some View {
        HStack(spacing: 0) {
            Button(action: onSend) {
                Text("发弹幕")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("发弹幕"))
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 18)
            VerticalVideoDanmakuSwitch(on: danmakuOn)
                .frame(width: 50, height: 32)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSettings()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(danmakuOn ? "关闭弹幕" : "开启弹幕"))
                .accessibilityAction(named: Text("弹幕设置"), onSettings)
        }
        .background(.white.opacity(0.14), in: Capsule())
        .padding(.trailing, 6)
    }

    private var detailButton: some View {
        Button(action: onDetail) {
            VStack(spacing: 1) {
                Text("详情页")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 4)
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5))
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .medium))
            }
            .frame(width: 44, height: VerticalVideoMetrics.bottomBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("详情页"))
    }

    private func glyphButton<Glyph: View>(_ label: String, action: @escaping () -> Void,
                                          @ViewBuilder glyph: () -> Glyph) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: 44, height: VerticalVideoMetrics.bottomBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// 全屏: two corners of the screen.
private struct VerticalVideoFullscreenGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.45
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        return path
    }
}

/// 清屏: a phone with its lines of text, and the rest of the screen empty.
private struct VerticalVideoClearGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 2.5
        let phone = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.5, height: rect.height)
        var path = Path()
        path.addRoundedRect(in: phone, cornerSize: CGSize(width: corner, height: corner))
        for (y, length) in [(rect.height * 0.62, 0.5), (rect.height * 0.8, 0.28)] {
            path.move(to: CGPoint(x: phone.minX + phone.width * 0.25, y: rect.minY + y))
            path.addLine(to: CGPoint(x: phone.minX + phone.width * (0.25 + length), y: rect.minY + y))
        }
        let start = phone.maxX + corner
        path.move(to: CGPoint(x: start, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: start, y: rect.maxY))
        return path
    }
}

/// 「弹」 with a pink tick while danmaku show, a grey cross while they do not.
struct VerticalVideoDanmakuSwitch: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(on ? 1 : 0.6), lineWidth: 1.4)
                    .frame(width: 24, height: 19)
                Text("弹")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(on ? 1 : 0.6))
            }
            Image(systemName: on ? "checkmark" : "xmark")
                .font(.system(size: 7, weight: .black))
                .foregroundColor(.white)
                .frame(width: 12, height: 12)
                .background(on ? Color.biliPink : Color.gray, in: Circle())
                .offset(x: 5, y: 4)
        }
    }
}

/// The middle of a paused video: the little TV with a play triangle, and where the video stands.
struct VerticalVideoPausedHint: View {
    let time: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 20) {
                    ear(tilt: -28)
                    ear(tilt: 28)
                }
                .offset(y: -31)
                RoundedRectangle(cornerRadius: 15)
                    .fill(.white.opacity(0.32))
                    .frame(width: 68, height: 54)
                Image(systemName: "play.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.top, 8)
            Text(time)
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.35), radius: 4)
        .allowsHitTesting(false)
    }

    private func ear(tilt: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.32))
            .frame(width: 4, height: 14)
            .rotationEffect(.degrees(tilt))
    }
}

/// The little TV riding the progress line.
struct VerticalVideoProgressMascot: View {
    var body: some View {
        ZStack {
            HStack(spacing: 7) {
                ear(tilt: -30)
                ear(tilt: 30)
            }
            .offset(y: -7)
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color.white)
                .frame(width: 18, height: 13)
            HStack(spacing: 4) {
                eye
                eye
            }
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.3), radius: 2)
    }

    private func ear(tilt: Double) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 1.8, height: 5)
            .rotationEffect(.degrees(tilt))
    }

    private var eye: some View {
        Capsule()
            .fill(Color.black.opacity(0.75))
            .frame(width: 2.2, height: 5)
    }
}

struct VerticalVideoLikeBurst: Identifiable {
    let id = UUID()
    let location: CGPoint
    let tilt = Double.random(in: -18...18)
}

/// The double-tap 点赞 burst.
struct VerticalVideoLikeBurstView: View {
    let burst: VerticalVideoLikeBurst
    @State private var shown = false

    var body: some View {
        Image(systemName: "hand.thumbsup.fill")
            .font(.system(size: 72))
            .foregroundColor(.biliPink)
            .shadow(color: .black.opacity(0.3), radius: 4)
            .rotationEffect(.degrees(burst.tilt))
            .scaleEffect(shown ? 1.15 : 0.4)
            .opacity(shown ? 0 : 1)
            .offset(y: shown ? -60 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.85)) { shown = true }
            }
    }
}

/// Dark traits for the screen it is placed on, the status bar included (black is behind it, so its text must be light).
/// SwiftUI's `preferredColorScheme` would repaint the whole window, the pages under this one too.
struct VerticalVideoDarkScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VerticalVideoDarkScreenController {
        VerticalVideoDarkScreenController()
    }

    func updateUIViewController(_ uiViewController: VerticalVideoDarkScreenController, context: Context) {}
}

final class VerticalVideoDarkScreenController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply()
    }

    private func apply() {
        guard navigationController != nil else { return }
        // The screen's own controller: the one the navigation stack holds.
        var screen = parent
        while let next = screen?.parent, !(next is UINavigationController) { screen = next }
        guard let screen, screen.overrideUserInterfaceStyle != .dark else { return }
        screen.overrideUserInterfaceStyle = .dark
        screen.setNeedsStatusBarAppearanceUpdate()
    }
}
