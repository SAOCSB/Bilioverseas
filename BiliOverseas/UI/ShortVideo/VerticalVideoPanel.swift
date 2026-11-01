import AVFoundation
import SwiftUI
import UIKit

// The panel of 简介 and 评论 on the vertical-video screen, as in the official app. The video gives way to it: it shrinks
// into what is left above and goes on playing. Only the small line at its top resizes it, and the list inside only scrolls.

/// What its place depends on, in the window's coordinates. Taken outside SwiftUI's updates (`measured`): reading a window
/// from a view's body can lay the window out in the middle of one.
struct VerticalVideoPanelMetrics: Equatable {
    var height: CGFloat = 800
    var statusBar: CGFloat = 44
    var safeBottom: CGFloat = 0

    @MainActor static func measured() -> VerticalVideoPanelMetrics {
        guard let window = PlayerFullscreenPresenter.keyWindow() else { return VerticalVideoPanelMetrics() }
        let bar = window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        return VerticalVideoPanelMetrics(height: window.bounds.height, statusBar: bar > 0 ? bar : window.safeAreaInsets.top,
                                         safeBottom: window.safeAreaInsets.bottom)
    }

    /// About a third of the way down, what the official app leaves for the video.
    var normalTop: CGFloat { (height * 0.33).rounded() }

    func top(for detent: VerticalVideoPanelState.Detent) -> CGFloat {
        switch detent {
        case .closed: return height
        case .normal: return normalTop
        case .full: return statusBar
        }
    }

    /// How far the video has given way at this place of the panel: nothing when it is gone, all of it from where it
    /// normally stands on up.
    func progress(top: CGFloat) -> CGFloat {
        guard height > normalTop else { return 1 }
        return min(max((height - top) / (height - normalTop), 0), 1)
    }

    /// Where a picture at `picture` goes above the panel, the two in the coordinates of a page that starts under the status bar.
    func pictureMove(from picture: CGRect) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        guard picture.width > 0, picture.height > 0 else { return (1, 0, 0) }
        let area = CGRect(x: picture.minX, y: 4, width: picture.width, height: max(normalTop - statusBar - 12, 1))
        let scale = min(area.height / picture.height, area.width / picture.width, 1)
        return (scale, area.midX - picture.midX, area.midY - picture.midY)
    }
}

/// Where the panel stands.
@MainActor
final class VerticalVideoPanelState: ObservableObject {
    enum Detent { case closed, normal, full }

    @Published private(set) var detent: Detent = .closed
    @Published var tab: VideoDetailTab = .comments
    /// What changes with the finger, apart: those watching where it stands should not be rendered again for each step.
    let live = VerticalVideoPanelLive()

    var isOpen: Bool { detent != .closed }

    /// Before it goes on screen, closed.
    func prepare() {
        live.metrics = .measured()
    }

    func open(tab: VideoDetailTab = .comments) {
        self.tab = tab
        move(to: .normal)
    }

    func close() {
        guard isOpen else { return }
        move(to: .closed)
    }

    /// It has started going down.
    var onClosing: (() -> Void)?

    func toggleFull() {
        move(to: detent == .full ? .normal : .full)
    }

    fileprivate func move(to next: Detent) {
        live.dragging = false
        live.dragOffset = 0
        live.progress = next == .closed ? 0 : 1
        detent = next
        if next == .closed { onClosing?() }
    }
}

@MainActor
final class VerticalVideoPanelLive: ObservableObject {
    @Published var metrics = VerticalVideoPanelMetrics()
    /// 0: the video has the screen. 1: it is above the panel.
    @Published var progress: CGFloat = 0
    /// How far the finger has moved the panel from where it stands.
    @Published var dragOffset: CGFloat = 0
    /// The finger has it: nothing follows it with an animation of its own.
    @Published var dragging = false

    /// All of them move together, each in the view tree it is in (the pages have one each).
    var animation: Animation? { dragging ? nil : .easeOut(duration: 0.28) }
}

/// The video as the panel comes: `picture` is where it shows in a view of `size`.
struct VerticalVideoPanelPicture: ViewModifier {
    @ObservedObject var live: VerticalVideoPanelLive
    let active: Bool
    let picture: CGRect
    let size: CGSize

    func body(content: Content) -> some View {
        let move = live.metrics.pictureMove(from: picture)
        let progress = active ? live.progress : 0
        content
            .scaleEffect(1 + (move.scale - 1) * progress,
                         anchor: UnitPoint(x: size.width > 0 ? picture.midX / size.width : 0.5,
                                           y: size.height > 0 ? picture.midY / size.height : 0.5))
            .offset(x: move.dx * progress, y: move.dy * progress)
            .animation(live.animation, value: progress)
    }
}

/// What goes away as the panel comes: the bars, the danmaku.
struct VerticalVideoPanelFading: ViewModifier {
    @ObservedObject var live: VerticalVideoPanelLive
    var active = true

    func body(content: Content) -> some View {
        let progress = active ? live.progress : 0
        content
            .opacity(1 - progress)
            .allowsHitTesting(progress == 0)
            .animation(live.animation, value: progress)
    }
}

/// What the panel is about.
struct VerticalVideoPanelContent {
    let id: String
    let comments: VideoCommentsModel
    let intro: VerticalVideoIntroModel
    let onSeek: ((Double) -> Void)?
}

/// Lays the panel over the whole screen, with a catch above it: a tap on what is left of the video closes it.
struct VerticalVideoPanelHost: View {
    @ObservedObject var state: VerticalVideoPanelState
    @ObservedObject var live: VerticalVideoPanelLive
    let content: VerticalVideoPanelContent

    private static let color = Color(red: 0.106, green: 0.11, blue: 0.122)

    var body: some View {
        let metrics = live.metrics
        let top = min(max(metrics.top(for: state.detent) + live.dragOffset, metrics.statusBar), metrics.height)
        ZStack(alignment: .top) {
            if state.isOpen {
                // Over the panel at its fullest, only the status bar's black is left of the video.
                Color.black.opacity(max((metrics.normalTop - top) / max(metrics.normalTop - metrics.statusBar, 1), 0.001))
                    .frame(height: top)
                    .contentShape(Rectangle())
                    .onTapGesture { state.close() }
            }
            panel
                .frame(height: metrics.height - min(top, metrics.normalTop))
                .offset(y: top)
        }
        .animation(live.animation, value: top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        // Next time it opens on the list.
        .onChange(of: state.isOpen) { open in
            if !open { content.comments.subRepliesRoot = nil }
        }
        // An iPad turns with it open.
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _ in state.prepare() }
        })
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $state.tab) {
                VerticalVideoIntroTab(model: content.intro)
                    .tag(VideoDetailTab.intro)
                VideoCommentsListView(model: content.comments, onSeek: content.onSeek)
                    .id(ObjectIdentifier(content.comments))
                    .tag(VideoDetailTab.comments)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.bottom, live.metrics.safeBottom)
        }
        .background(Self.color)
        .environment(\.videoCommentsPanelColor, Self.color)
        .environment(\.colorScheme, .dark)
        .clipShape(UnevenCorners(radius: 14))
    }

    /// The small line and the tabs: the part that moves the panel.
    private var header: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 30, height: 3)
                .padding(.top, 7)
                .padding(.bottom, 4)
            HStack(spacing: 0) {
                tabButton(.intro, title: "简介")
                tabButton(.comments, title: "评论")
                Spacer(minLength: 8)
                resizeButton
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
        }
        .contentShape(Rectangle())
        .gesture(resizeDrag)
    }

    private func tabButton(_ tab: VideoDetailTab, title: String) -> some View {
        VerticalVideoPanelTab(selected: state.tab == tab, title: title, comments: tab == .comments ? content.comments : nil) {
            withAnimation(.easeInOut(duration: 0.2)) { state.tab = tab }
        }
    }

    private var resizeButton: some View {
        Button { state.toggleFull() } label: {
            // Apart to make it bigger, together to make it smaller again.
            VStack(spacing: 2) {
                Image(systemName: state.detent == .full ? "chevron.down" : "chevron.up")
                Image(systemName: state.detent == .full ? "chevron.up" : "chevron.down")
            }
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.1), in: Circle())
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(state.detent == .full ? "收起" : "展开"))
    }

    private var resizeDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let metrics = live.metrics
                let base = metrics.top(for: state.detent)
                let top = min(max(base + value.translation.height, metrics.statusBar), metrics.height)
                live.dragging = true
                live.dragOffset = top - base
                live.progress = metrics.progress(top: top)
            }
            .onEnded { value in
                let metrics = live.metrics
                let target = metrics.top(for: state.detent) + value.predictedEndTranslation.height
                let places: [VerticalVideoPanelState.Detent] = [.full, .normal, .closed]
                let next = places.min { abs(metrics.top(for: $0) - target) < abs(metrics.top(for: $1) - target) } ?? .normal
                state.move(to: next)
            }
    }
}

/// Rounded at the top only (`UnevenRoundedRectangle` needs iOS 16.4).
private struct UnevenCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

private struct VerticalVideoPanelTab: View {
    let selected: Bool
    let title: String
    /// 评论 says how many there are.
    let comments: VideoCommentsModel?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : .white.opacity(0.5))
                    if let comments {
                        VerticalVideoPanelTabCount(comments: comments)
                    }
                }
                Capsule()
                    .fill(selected ? Color.biliPink : .clear)
                    .frame(width: 16, height: 3)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct VerticalVideoPanelTabCount: View {
    @ObservedObject var comments: VideoCommentsModel

    var body: some View {
        if comments.totalCount > 0 {
            Text(verbatim: "(\(comments.totalCount))")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
        }
    }
}

// MARK: - 简介

/// What the 简介 side shows, asked for once.
@MainActor
final class VerticalVideoIntroModel: ObservableObject {
    let ref: VideoRef
    @Published private(set) var detail: VideoDetail?
    @Published private(set) var related: [VideoCard] = []
    @Published private(set) var didLoad = false
    private var started = false

    init(ref: VideoRef) {
        self.ref = ref
    }

    func loadIfNeeded() async {
        guard !started else { return }
        started = true
        didLoad = false
        if detail == nil { detail = try? await VideoAPI.detail(ref) }
        let aid = detail?.aid ?? ref.aid
        let bvid = detail?.bvid ?? ref.bvid
        let cards = try? await VideoAPI.related(aid: aid, bvid: bvid)
        if let cards {
            let allows = FeedFilter.liveFilter(scope: .related)
            var ids = Set<String>()
            related = cards.filter { $0.aid != aid && allows($0) && ids.insert($0.id).inserted }
        }
        didLoad = true
        // Asked again on the next look: it may have been the connection, or this side being left, which cancels these.
        if detail == nil || cards == nil { started = false }
    }
}

struct VerticalVideoIntroTab: View {
    @ObservedObject var model: VerticalVideoIntroModel
    @EnvironmentObject private var router: TabRouter
    @Environment(\.videoCommentsPanelColor) private var panelColor

    private static let dateFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.dateFormat = "yyyy年M月d日 HH:mm"
        return format
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Text(model.detail?.title ?? model.ref.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                if let detail = model.detail {
                    stats(detail)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Section {
                    grid
                } header: {
                    Text("相关视频")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(panelColor ?? Color(.systemBackground))
                }
                .padding(.top, 8)
            }
            .padding(.bottom, 16)
        }
        .task { await model.loadIfNeeded() }
    }

    private func stats(_ detail: VideoDetail) -> some View {
        HStack(spacing: 10) {
            Label(Fmt.count(detail.stat.view), systemImage: "play.rectangle")
            Label(Fmt.count(detail.stat.danmaku), systemImage: "text.bubble")
            if detail.pubdate > 0 {
                Text(Self.dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(detail.pubdate))))
            }
            Text(detail.bvid)
                .lineLimit(1)
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder private var grid: some View {
        if model.related.isEmpty {
            if !model.didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(model.related) { card in
                    Button {
                        router.push(card.route ?? .video(card.videoRef))
                    } label: {
                        VideoGridCell(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
