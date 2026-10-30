import SwiftUI

/// 直播 tab state: recommended rooms (paged) + followed anchors that are live now.
@MainActor
final class LiveHomeModel: ObservableObject {
    let rooms: PagedListModel<LiveRoom>
    @Published private(set) var followed: [LiveRoom] = []
    private var followedLoadedAt: Date?
    private var followedLoadedLoggedIn = false

    init() {
        // Rooms are shown as `.live` cards; scope `.popular` applies the ad / blocked-UP / keyword
        // rules without the recommend-only "hide live cards" switch.
        let allows = FeedFilter.liveFilter(scope: .popular)
        rooms = PagedListModel<LiveRoom>(filter: { allows($0.card) }) { cursor in
            try await LiveAPI.recommendRooms(cursor: cursor)
        }
    }

    /// Followed rooms that are live (login required). Throttled to once a minute unless `force`.
    func loadFollowed(force: Bool = false) async {
        let loggedIn = AuthService.shared.isLoggedIn
        guard loggedIn else {
            followed = []
            followedLoadedAt = nil
            followedLoadedLoggedIn = false
            return
        }
        if !force, followedLoadedLoggedIn, let at = followedLoadedAt, Date().timeIntervalSince(at) < 60 { return }
        do {
            followed = try await LiveAPI.followedLiving()
            followedLoadedAt = Date()
            followedLoadedLoggedIn = true
        } catch {
            // Keep the previous row; the recommend grid below still works.
        }
    }

    func refresh() async {
        await loadFollowed(force: true)
        await rooms.refresh()
    }
}

/// 直播: 「我的关注」 live avatars (logged in) + two-column grid of recommended rooms.
struct LiveHomeView: View {
    @ObservedObject var model: LiveHomeModel
    @ObservedObject var rooms: PagedListModel<LiveRoom>
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Re-taps of the 首页 tab bar item (scroll to top / refresh).
    let reselect: FeedReselectSignal
    @State private var topTracker = FeedTopTracker()
    @State private var isReselectRefreshing = false

    init(model: LiveHomeModel, reselect: FeedReselectSignal = FeedReselectSignal()) {
        _model = ObservedObject(wrappedValue: model)
        _rooms = ObservedObject(wrappedValue: model.rooms)
        self.reselect = reselect
    }

    private var columns: [GridItem] {
        FeedGridLayout.columns(sizeClass, compactCount: 2)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The zero-height anchor plus the stack spacing make the 12 pt top inset.
                VStack(alignment: .leading, spacing: 12) {
                    FeedTopAnchor(tracker: topTracker)
                    if isReselectRefreshing { FeedRefreshingRow() }
                    if auth.isLoggedIn && !model.followed.isEmpty {
                        followedSection
                            .padding(.bottom, 6)
                    }
                    HomeSectionHeader("推荐直播")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(rooms.items) { room in
                            NavigationLink(value: Route.live(roomId: room.roomId)) {
                                HomeLiveCardCell(card: room.card)
                            }
                            .buttonStyle(.plain)
                            .onAppear { rooms.onItemAppear(room) }
                        }
                    }
                    .padding(.horizontal, 10)
                    ListFooter(isLoading: rooms.isLoading, hasMore: rooms.hasMore, isEmpty: rooms.isEmpty,
                               error: rooms.errorMessage, emptyText: "暂无直播") {
                        Task { await rooms.loadMore() }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .feedReselect(reselect, proxy: proxy, tracker: topTracker, isRefreshing: $isReselectRefreshing) {
                await model.refresh()
            }
        }
        .task { await rooms.loadIfNeeded() }
        .task(id: auth.isLoggedIn) { await model.loadFollowed() }
    }

    private var followedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader("我的关注") {
                Text("\(model.followed.count)人正在直播")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.followed) { room in
                        NavigationLink(value: Route.live(roomId: room.roomId)) {
                            LiveFollowedAnchorCell(room: room)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }
}

/// Avatar with a pink ring and 「直播中」 tag, name below.
private struct LiveFollowedAnchorCell: View {
    let room: LiveRoom

    var body: some View {
        VStack(spacing: 8) {
            AvatarView(url: room.face, size: 52)
                .padding(3)
                .overlay { Circle().stroke(Color.biliPink, lineWidth: 1.5) }
                .overlay(alignment: .bottom) {
                    Text("直播中")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.biliPink, in: Capsule())
                        .offset(y: 5)
                }
            Text(room.uname)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 66)
        .contentShape(Rectangle())
    }
}
