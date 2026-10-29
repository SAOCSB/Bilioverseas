import SwiftUI

/// Official-app style grid card: 16:10 cover with play/danmaku counts and duration overlay.
struct VideoGridCell: View {
    let card: VideoCard
    /// Leaves room at the end of the owner line for the ⋮ button `VideoCardGrid` lays over it.
    var reservesMenuSpace: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                RemoteImage(url: card.cover, width: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(alignment: .bottom) { coverOverlay }
                    .overlay(alignment: .topTrailing) {
                        if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                    }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(card.title)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                if !card.reason.isEmpty {
                    Text(card.reason)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 3)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor.opacity(0.6), lineWidth: 0.5))
                } else if !card.ownerName.isEmpty {
                    Image(systemName: "person.crop.square").font(.caption2)
                }
                Text(card.ownerName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, reservesMenuSpace ? 24 : 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var coverOverlay: some View {
        HStack(spacing: 8) {
            if card.viewCount > 0 {
                Label(Fmt.count(card.viewCount), systemImage: "play.rectangle")
            }
            if card.danmakuCount > 0 {
                Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble")
            }
            Spacer(minLength: 0)
            if card.duration > 0 { Text(Fmt.duration(card.duration)) }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }
}

/// List row: cover on the left, title / owner / stats on the right (history, search, related …).
struct VideoRowCell: View {
    let card: VideoCard
    var showProgress: Bool = false
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: card.cover, width: 150)
                .frame(width: 150, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if card.duration > 0 {
                        Text(durationText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showProgress, card.duration > 0, card.progress != 0 {
                        GeometryReader { g in
                            let ratio = card.progress < 0 ? 1 : min(1, Double(card.progress) / Double(card.duration))
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * ratio, height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if !card.ownerName.isEmpty {
                    Label(card.ownerName, systemImage: "person.crop.square")
                        .labelStyle(CompactLabelStyle())
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let subtitle {
                        Text(subtitle)
                    } else {
                        if card.viewCount > 0 { Label(Fmt.count(card.viewCount), systemImage: "play.rectangle") }
                        if card.danmakuCount > 0 { Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble") }
                        if card.pubdate > 0 { Text(Fmt.relativeDate(card.pubdate)) }
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 94, maxHeight: 94, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var durationText: String {
        if showProgress && card.progress < 0 { return "已看完" }
        if showProgress && card.progress > 0 { return "\(Fmt.duration(card.progress))/\(Fmt.duration(card.duration))" }
        return Fmt.duration(card.duration)
    }
}

struct BadgeLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Card menu (稍后再看 / 不感兴趣 / 屏蔽UP主)

/// Actions behind a video card's ⋮ button and long-press menu. `remove` drops cards from the list on
/// screen (e.g. `{ model.remove(where: $0) }`); the 首页 lists also re-apply `FeedFilter` when the
/// rules change, so a newly blocked UP disappears from them either way.
@MainActor
enum VideoCardActions {
    typealias Remove = @MainActor (_ predicate: (VideoCard) -> Bool) -> Void

    static func canWatchLater(_ card: VideoCard) -> Bool {
        card.kind == .video && (card.aid != 0 || !card.bvid.isEmpty)
    }

    static func canBlockUploader(_ card: VideoCard) -> Bool {
        card.ownerMid != 0 || !card.ownerName.isEmpty
    }

    /// Whether the menu has anything to offer for this card.
    static func hasActions(_ card: VideoCard, allowsDislike: Bool) -> Bool {
        canWatchLater(card) || canBlockUploader(card) || allowsDislike
    }

    static func addToWatchLater(_ card: VideoCard) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        Task {
            do {
                if card.aid != 0 {
                    try await WatchLaterAPI.add(aid: card.aid)
                } else {
                    try await WatchLaterAPI.add(bvid: card.bvid)
                }
                ToastCenter.shared.show("已添加至稍后再看")
            } catch {
                if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            }
        }
    }

    /// Adds the card's UP to 「UP 主屏蔽」 (`UID:<mid>` when the mid is known) and hides their cards here.
    static func blockUploader(_ card: VideoCard, remove: Remove?) {
        let rule = card.ownerMid != 0 ? "UID:\(card.ownerMid)" : card.ownerName
        let name = card.ownerName.isEmpty ? rule : card.ownerName
        let added = FeedFilter(settings: AppSettings.shared.feedFilter).matchUploader(card) == nil
        if added { AppSettings.shared.feedFilter.blockedUploaders.append(rule) }
        let mid = card.ownerMid
        let lowerName = card.ownerName.lowercased()
        withAnimation(.easeInOut(duration: 0.2)) {
            remove? { c in mid != 0 ? c.ownerMid == mid : (!c.ownerName.isEmpty && c.ownerName.lowercased() == lowerName) }
        }
        if added {
            ToastCenter.shared.show("已屏蔽UP主「\(name)」", duration: 3, actionTitle: "撤销") {
                AppSettings.shared.feedFilter.blockedUploaders.removeAll { $0 == rule }
            }
        } else {
            ToastCenter.shared.show("已屏蔽UP主「\(name)」")
        }
    }

    /// 不感兴趣 with one of the app feed's reasons: hides the card and reports it (TV-login token).
    static func dislike(_ card: VideoCard, reason: FeedDislikeReason, remove: Remove?) {
        guard let feedback = card.feedback else { return }
        let id = card.id
        withAnimation(.easeInOut(duration: 0.2)) { remove? { $0.id == id } }
        Task {
            do {
                try await FeedAPI.dislike(feedback, reason: reason)
                let fallback = reason.isFeedback ? "感谢反馈" : "将减少相似内容推荐"
                ToastCenter.shared.show(reason.toast.isEmpty ? fallback : reason.toast)
            } catch {
                if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            }
        }
    }

    /// 不感兴趣 without server reasons (web feed, or no TV-login token): hides the card in this list.
    static func hide(_ card: VideoCard, remove: Remove?) {
        let id = card.id
        withAnimation(.easeInOut(duration: 0.2)) { remove? { $0.id == id } }
        ToastCenter.shared.show("已隐藏该视频")
    }
}

/// The card menu's items, shared by the ⋮ `Menu` and the long-press `.contextMenu`.
struct VideoCardMenuItems: View {
    let card: VideoCard
    /// Offer 不感兴趣 (home 推荐).
    var allowsDislike = false
    var remove: VideoCardActions.Remove?

    var body: some View {
        if VideoCardActions.canWatchLater(card) {
            Button {
                VideoCardActions.addToWatchLater(card)
            } label: {
                Label("稍后再看", systemImage: "clock")
            }
        }
        if allowsDislike {
            dislikeItems
        }
        if VideoCardActions.canBlockUploader(card) {
            Button(role: .destructive) {
                VideoCardActions.blockUploader(card, remove: remove)
            } label: {
                Label("屏蔽UP主：\(uploaderName)", systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }

    private var uploaderName: String {
        card.ownerName.isEmpty ? "UID \(card.ownerMid)" : card.ownerName
    }

    @ViewBuilder private var dislikeItems: some View {
        if let feedback = card.feedback, FeedAPI.appAuth() != nil {
            Menu {
                ForEach(feedback.reasons) { reason in
                    Button(reason.name) { VideoCardActions.dislike(card, reason: reason, remove: remove) }
                }
                if !feedback.feedbacks.isEmpty {
                    Section("反馈") {
                        ForEach(feedback.feedbacks) { reason in
                            Button(reason.name) { VideoCardActions.dislike(card, reason: reason, remove: remove) }
                        }
                    }
                }
            } label: {
                Label("不感兴趣", systemImage: "hand.thumbsdown")
            }
        } else {
            Button {
                VideoCardActions.hide(card, remove: remove)
            } label: {
                Label("不感兴趣", systemImage: "hand.thumbsdown")
            }
        }
    }
}

/// The ⋮ of a grid card. `VideoCardGrid` lays it over the card's owner line, outside the card's
/// `NavigationLink`, so tapping it opens the menu instead of the video.
struct VideoCardMenuButton: View {
    let card: VideoCard
    var allowsDislike = false
    var remove: VideoCardActions.Remove?

    var body: some View {
        Menu {
            VideoCardMenuItems(card: card, allowsDislike: allowsDislike, remove: remove)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }
}

extension View {
    /// Long-press menu with the card actions (稍后再看 / 不感兴趣 / 屏蔽UP主) for any video row or card.
    func videoCardMenu(_ card: VideoCard, allowsDislike: Bool = false,
                       remove: VideoCardActions.Remove? = nil) -> some View {
        contextMenu {
            VideoCardMenuItems(card: card, allowsDislike: allowsDislike, remove: remove)
        }
    }
}

extension PagedListModel {
    /// Runs `filter` again over the rows already shown (the user changed the rules).
    func reapplyFilter() {
        guard let filter else { return }
        remove(where: { !filter($0) })
    }
}

// MARK: - Re-tapping the tab (scroll to top / refresh)

/// A re-tap of the active 首页 / 动态 tab, handed down to the visible feed: it scrolls to the top, or
/// refreshes when it is already there (and always on a second re-tap within 0.5 s).
struct FeedReselectSignal: Equatable {
    private(set) var serial = 0
    private(set) var forceRefresh = false

    mutating func fire(forceRefresh: Bool) {
        serial += 1
        self.forceRefresh = forceRefresh
    }
}

/// Whether a feed's `ScrollView` shows its top. A plain object, so scrolling never re-renders the feed.
final class FeedTopTracker {
    var isAtTop = true
}

private struct FeedTopOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// First view of a feed's scroll content: the target of `scrollTo` and the probe for `FeedTopTracker`.
struct FeedTopAnchor: View {
    static let id = "feed-top-anchor"
    static let space = "feed-scroll"
    let tracker: FeedTopTracker

    var body: some View {
        Color.clear
            .frame(height: 0)
            .id(FeedTopAnchor.id)
            .background(GeometryReader { geo in
                Color.clear.preference(key: FeedTopOffsetKey.self,
                                       value: geo.frame(in: .named(FeedTopAnchor.space)).minY)
            })
            .onPreferenceChange(FeedTopOffsetKey.self) { tracker.isAtTop = $0 > -8 }
    }
}

/// Spinner row under the anchor while a re-tap refresh runs (pull to refresh has its own).
struct FeedRefreshingRow: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

extension View {
    /// Re-tap handling for a feed `ScrollView` (inside `ScrollViewReader`) whose content starts with
    /// `FeedTopAnchor(tracker:)`: scrolls up when away from the top, refreshes when already there.
    func feedReselect(_ signal: FeedReselectSignal, proxy: ScrollViewProxy, tracker: FeedTopTracker,
                      isRefreshing: Binding<Bool>, refresh: @escaping () async -> Void) -> some View {
        coordinateSpace(name: FeedTopAnchor.space)
            .onChange(of: signal) { s in
                let atTop = tracker.isAtTop
                if !atTop {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(FeedTopAnchor.id, anchor: .top) }
                }
                guard atTop || s.forceRefresh, !isRefreshing.wrappedValue else { return }
                isRefreshing.wrappedValue = true
                Task {
                    await refresh()
                    isRefreshing.wrappedValue = false
                }
            }
    }
}

// MARK: - Grid

/// Grid columns of the feeds: phones, and iPads in a compact-width window (Split View / Slide Over),
/// get `compactCount` equal columns; a regular-width iPad fits as many ≥ `minimumWidth` columns as its
/// window allows.
@MainActor
enum FeedGridLayout {
    static func isWide(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    static func columns(_ sizeClass: UserInterfaceSizeClass?, compactCount: Int, minimumWidth: CGFloat = 220) -> [GridItem] {
        if isWide(sizeClass) {
            return [GridItem(.adaptive(minimum: minimumWidth, maximum: 420), spacing: 10, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: max(1, compactCount))
    }
}

/// 「上次看到这里」 between the cards of the latest refresh and the older ones; tap = back up and refresh.
struct FeedLastSeenDivider: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
                Text("上次看到这里，点击刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Settings-driven grid (or single-column rows) of cards with infinite scroll, used by feeds. Every card
/// has the long-press menu; grid cards also get the ⋮ button.
struct VideoCardGrid: View {
    @ObservedObject var model: PagedListModel<VideoCard>
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    var emptyText: String = "暂无视频"
    /// Offer 不感兴趣 in the card menus (home 推荐).
    var allowsDislike: Bool = false
    /// Re-taps of the tab bar item (scroll to top / refresh).
    var reselect = FeedReselectSignal()
    @State private var topTracker = FeedTopTracker()
    @State private var isReselectRefreshing = false

    private var usesRows: Bool {
        settings.general.feedColumns == 1 && !FeedGridLayout.isWide(sizeClass)
    }

    private var columns: [GridItem] {
        FeedGridLayout.columns(sizeClass, compactCount: settings.general.feedColumns)
    }

    /// Where the 「上次看到这里」 divider goes (never above the first card).
    private var lastSeenIndex: Int? {
        guard settings.general.showLastSeenHint, let id = model.lastSeenID,
              let index = model.items.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return index
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    FeedTopAnchor(tracker: topTracker)
                    if isReselectRefreshing { FeedRefreshingRow() }
                    VStack(spacing: 14) {
                        if let split = lastSeenIndex {
                            cards(model.items[..<split])
                            FeedLastSeenDivider { refreshFromDivider(proxy) }
                            cards(model.items[split...])
                        } else {
                            cards(model.items[...])
                        }
                    }
                    ListFooter(isLoading: model.isLoading, hasMore: model.hasMore, isEmpty: model.isEmpty,
                               error: model.errorMessage, emptyText: emptyText) {
                        Task { await model.loadMore() }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .feedReselect(reselect, proxy: proxy, tracker: topTracker, isRefreshing: $isReselectRefreshing) {
                await model.refresh()
            }
        }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder private func cards(_ slice: ArraySlice<VideoCard>) -> some View {
        if usesRows {
            LazyVStack(spacing: 12) {
                ForEach(slice) { card in
                    cardLink(card, menuButton: false) { VideoRowCell(card: card) }
                }
            }
            .padding(.horizontal, 12)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(slice) { card in
                    cardLink(card, menuButton: true) { VideoGridCell(card: card, reservesMenuSpace: true) }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var removeCards: VideoCardActions.Remove {
        let model = model
        return { predicate in model.remove(where: predicate) }
    }

    private func refreshFromDivider(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(FeedTopAnchor.id, anchor: .top) }
        guard !isReselectRefreshing else { return }
        isReselectRefreshing = true
        Task {
            await model.refresh()
            isReselectRefreshing = false
        }
    }

    @ViewBuilder
    private func cardLink<Content: View>(_ card: VideoCard, menuButton: Bool,
                                         @ViewBuilder content: () -> Content) -> some View {
        Group {
            if let route = card.route {
                NavigationLink(value: route) { content() }
            } else {
                content()
            }
        }
        .buttonStyle(.plain)
        .videoCardMenu(card, allowsDislike: allowsDislike, remove: removeCards)
        .overlay(alignment: .bottomTrailing) {
            if menuButton && VideoCardActions.hasActions(card, allowsDislike: allowsDislike) {
                VideoCardMenuButton(card: card, allowsDislike: allowsDislike, remove: removeCards)
                    .offset(x: 4, y: 2)
            }
        }
        .onAppear { model.onItemAppear(card) }
    }
}
