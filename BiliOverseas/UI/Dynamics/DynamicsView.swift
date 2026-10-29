import SwiftUI
import Combine

/// 动态 tab root: 全部 | 投稿 | 番剧 | 专栏 segments, the followed-UP strip and the follow feed.
struct DynamicsView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var reselect = FeedReselectSignal()

    var body: some View {
        Group {
            if auth.isLoggedIn {
                DynamicsFeedScreen(reselect: reselect)
            } else {
                LoginRequiredView(message: "登录后查看关注的动态")
            }
        }
        .navigationTitle("动态")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .mainTabReselected)) { note in
            guard note.object as? MainTab == .dynamics else { return }
            reselect.fire(forceRefresh: note.userInfo?[MainTab.forceRefreshKey] as? Bool ?? false)
        }
    }
}

// MARK: - Unread (「检查未读动态」)

/// New dynamics since the 全部 feed was last loaded, shown as the 动态 tab badge. The feed's first 全部
/// page stores `update_baseline`; `RootTabView` runs `poll` while logged in, in the foreground and
/// switched on, checking `feed/all/update` every 5 minutes. The endpoint is [unverified]: errors are
/// ignored and only leave the badge as it was.
@MainActor
final class DynamicsUnreadModel: ObservableObject {
    static let shared = DynamicsUnreadModel()
    /// 「检查周期」 in seconds.
    static let pollInterval: UInt64 = 300

    struct PollKey: Equatable {
        var loggedIn: Bool
        var active: Bool
        var enabled: Bool
    }

    @Published private(set) var count = 0
    private var baseline: String
    private static let baselineKey = "bili.dynamics.updateBaseline"

    init() {
        baseline = UserDefaults.standard.string(forKey: DynamicsUnreadModel.baselineKey) ?? ""
    }

    /// The 全部 feed's first page arrived: everything up to `newBaseline` has been seen.
    func feedDidLoad(baseline newBaseline: String) {
        count = 0
        guard !newBaseline.isEmpty else { return }
        baseline = newBaseline
        UserDefaults.standard.set(newBaseline, forKey: DynamicsUnreadModel.baselineKey)
    }

    /// Checks now and then every `pollInterval` until cancelled (`RootTabView`'s task restarts on changes).
    func poll(_ key: PollKey) async {
        guard key.loggedIn else {
            count = 0
            baseline = ""
            UserDefaults.standard.removeObject(forKey: DynamicsUnreadModel.baselineKey)
            return
        }
        guard key.enabled else {
            count = 0
            return
        }
        guard key.active else { return }
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(nanoseconds: DynamicsUnreadModel.pollInterval * 1_000_000_000)
        }
    }

    private func check() async {
        guard !baseline.isEmpty else {
            // Nothing loaded yet on this device: the newest dynamic right now is the starting point.
            if let first = try? await DynamicsAPI.feedWithBaseline(type: "all"), !Task.isCancelled, baseline.isEmpty {
                feedDidLoad(baseline: first.updateBaseline)
            }
            return
        }
        guard let n = try? await DynamicsAPI.newCount(baseline: baseline), !Task.isCancelled else { return }
        count = max(0, n)
    }
}

// MARK: - Model

/// Thread-safe snapshot of what the feed should load (read by the list's fetch closure).
final class DynamicsFeedQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var type = "all"
    private var hostMid: Int64 = 0

    func set(type: String, hostMid: Int64) {
        lock.lock()
        self.type = type
        self.hostMid = hostMid
        lock.unlock()
    }

    var snapshot: (type: String, hostMid: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (type, hostMid)
    }

    static func fetch(_ query: DynamicsFeedQuery, cursor: String?) async throws -> Page<DynamicItem> {
        let s = query.snapshot
        if s.hostMid != 0 {
            var page = try await DynamicsAPI.feed(hostMid: s.hostMid, offset: cursor)
            guard s.type != "all" else { return page }
            // The per-UP feed has no type filter. An UP posting mostly images / text would give
            // pages without a match, which stall infinite scroll (or show 「TA还没有发布动态」 while
            // older ones exist), so skip ahead a few pages until one has a match.
            var matching = page.items.filter { matches($0, type: s.type) }
            var hops = 0
            while matching.isEmpty, page.hasMore, let next = page.next, hops < 3 {
                hops += 1
                page = try await DynamicsAPI.feed(hostMid: s.hostMid, offset: next)
                matching = page.items.filter { matches($0, type: s.type) }
            }
            page.items = matching
            return page
        }
        if s.type == "all" && cursor == nil {
            // The first 全部 page also says up to where the 动态 badge has been seen.
            let first = try await DynamicsAPI.feedWithBaseline(type: "all")
            await MainActor.run { DynamicsUnreadModel.shared.feedDidLoad(baseline: first.updateBaseline) }
            return first.page
        }
        return try await DynamicsAPI.feed(type: s.type, offset: cursor)
    }

    /// The feed `type` filter, applied client-side to the per-UP feed.
    static func matches(_ item: DynamicItem, type: String) -> Bool {
        switch type {
        case "video": return item.type == .video
        case "pgc": return item.type == .pgc
        case "article": return item.type == .article
        default: return true
        }
    }
}

@MainActor
final class DynamicsFeedModel: ObservableObject {
    enum Segment: Int, CaseIterable, Identifiable {
        case all, video, pgc, article
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .video: return "投稿"
            case .pgc: return "番剧"
            case .article: return "专栏"
            }
        }

        /// `type` of `/x/polymer/web-dynamic/v1/feed/all`.
        var apiType: String {
            switch self {
            case .all: return "all"
            case .video: return "video"
            case .pgc: return "pgc"
            case .article: return "article"
            }
        }
    }

    @Published private(set) var segment: Segment = .all
    @Published private(set) var selectedUp: DynamicUpEntry?
    @Published private(set) var ups: [DynamicUpEntry] = []

    let list: PagedListModel<DynamicItem>
    private let query: DynamicsFeedQuery
    private var upTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let q = DynamicsFeedQuery()
        query = q
        list = PagedListModel(filter: DynamicFeedFiltering.liveFilter(scope: .dynamics)) { cursor in
            try await DynamicsFeedQuery.fetch(q, cursor: cursor)
        }
        // Edited 屏蔽 rules (or a synced blacklist) also hide dynamics already on screen.
        AppSettings.shared.$feedFilter
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.list.reapplyFilter() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountBlacklistStore.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.list.reapplyFilter() }
            .store(in: &cancellables)
    }

    func loadIfNeeded() async {
        if ups.isEmpty { loadUps() }
        await list.loadIfNeeded()
    }

    /// Pull to refresh / login change: reloads the UP strip and the feed.
    func reloadAll() async {
        loadUps()
        await list.refresh()
    }

    func select(segment: Segment) {
        guard segment != self.segment else { return }
        self.segment = segment
        applyQuery()
    }

    /// nil = 全部 (every followed UP).
    func select(up: DynamicUpEntry?) {
        guard up?.id != selectedUp?.id else { return }
        selectedUp = up
        if let up, let i = ups.firstIndex(where: { $0.id == up.id }) { ups[i].hasUpdate = false }
        applyQuery()
    }

    private func applyQuery() {
        query.set(type: segment.apiType, hostMid: selectedUp?.user.mid ?? 0)
        list.replace([])
        Task { await list.refresh() }
    }

    private func loadUps() {
        upTask?.cancel()
        upTask = Task { [weak self] in
            guard let ups = try? await DynamicsAPI.upList(), !Task.isCancelled else { return }
            self?.ups = ups
        }
    }
}

// MARK: - Screen

struct DynamicsFeedScreen: View {
    @StateObject private var model = DynamicsFeedModel()
    /// Re-taps of the 动态 tab bar item (scroll to top / refresh).
    var reselect = FeedReselectSignal()

    var body: some View {
        VStack(spacing: 0) {
            Picker("动态类型", selection: Binding(get: { model.segment }, set: { model.select(segment: $0) })) {
                ForEach(DynamicsFeedModel.Segment.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            Divider()

            DynamicsFeedList(model: model, list: model.list, reselect: reselect)
        }
        .background(Color(.systemGroupedBackground))
        .task { await model.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            // Account switch while this screen is alive (logout replaces the screen entirely).
            guard AuthService.shared.isLoggedIn else { return }
            Task { await model.reloadAll() }
        }
    }
}

struct DynamicsFeedList: View {
    @ObservedObject var model: DynamicsFeedModel
    @ObservedObject var list: PagedListModel<DynamicItem>
    var reselect = FeedReselectSignal()
    @State private var topTracker = FeedTopTracker()
    @State private var isReselectRefreshing = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    FeedTopAnchor(tracker: topTracker)
                    if isReselectRefreshing { FeedRefreshingRow() }
                    LazyVStack(spacing: 8) {
                        if !model.ups.isEmpty {
                            DynamicsUpStrip(ups: model.ups, selectedMid: model.selectedUp?.user.mid) { model.select(up: $0) }
                        }
                        if let up = model.selectedUp {
                            DynamicsSelectedUpBar(up: up) { model.select(up: nil) }
                        }
                        ForEach(list.items) { item in
                            DynamicCardView(item: item)
                                .onAppear { list.onItemAppear(item) }
                        }
                        ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                                   error: list.errorMessage, emptyText: emptyText) {
                            Task {
                                if list.isEmpty { await list.refresh() } else { await list.loadMore() }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .refreshable { await model.reloadAll() }
            .feedReselect(reselect, proxy: proxy, tracker: topTracker, isRefreshing: $isReselectRefreshing) {
                await model.reloadAll()
            }
        }
    }

    private var emptyText: String {
        if model.selectedUp != nil { return "TA还没有发布动态" }
        switch model.segment {
        case .all, .video: return "关注的UP主还没有发布动态"
        case .pgc: return "追的番剧还没有更新动态"
        case .article: return "关注的UP主还没有发布专栏"
        }
    }
}

// MARK: - UP strip

/// Horizontal strip of followed UPs: 全部 first, live UPs (直播中 badge → live room) and red dots
/// for UPs with new dynamics. Tapping an UP narrows the feed to them.
struct DynamicsUpStrip: View {
    let ups: [DynamicUpEntry]
    let selectedMid: Int64?
    let onSelect: (DynamicUpEntry?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                Button {
                    onSelect(nil)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 20))
                            .foregroundColor(selectedMid == nil ? .white : .secondary)
                            .frame(width: 48, height: 48)
                            .background(selectedMid == nil ? Color.biliPink : Color(.secondarySystemFill), in: Circle())
                        Text("全部")
                            .font(.caption2)
                            .foregroundColor(selectedMid == nil ? .biliPink : .primary)
                    }
                    .frame(width: 56)
                }
                .buttonStyle(.plain)

                ForEach(ups) { up in
                    if up.isLive && up.roomId != 0 {
                        NavigationLink(value: Route.live(roomId: up.roomId)) {
                            DynamicsUpAvatarCell(up: up, isSelected: selectedMid == up.user.mid)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onSelect(up)
                            } label: {
                                Label("查看TA的动态", systemImage: "text.bubble")
                            }
                        }
                    } else {
                        Button {
                            onSelect(up)
                        } label: {
                            DynamicsUpAvatarCell(up: up, isSelected: selectedMid == up.user.mid)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }
}

struct DynamicsUpAvatarCell: View {
    let up: DynamicUpEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(url: up.user.face, size: 48)
                .padding(2)
                .overlay(
                    Circle().stroke(isSelected || up.isLive ? Color.biliPink : Color.clear, lineWidth: 2)
                )
                .overlay(alignment: .topTrailing) {
                    if up.hasUpdate && !up.isLive {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: -2, y: 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if up.isLive {
                        Text("直播中")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.biliPink, in: Capsule())
                            .offset(y: 5)
                    }
                }
            Text(up.user.name)
                .font(.caption2)
                .foregroundColor(isSelected ? .biliPink : .primary)
                .lineLimit(1)
        }
        .frame(width: 56)
    }
}

/// 「XX 的动态」 bar shown while the feed is narrowed to one UP, with a 全部 chip to reset.
struct DynamicsSelectedUpBar: View {
    let up: DynamicUpEntry
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: up.user.face, size: 24)
            Text("\(up.user.name) 的动态")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            NavigationLink(value: Route.user(mid: up.user.mid)) {
                Text("进入空间")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: onReset) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                    Text("全部")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.biliPink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.biliPink, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}
