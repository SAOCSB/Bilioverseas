import SwiftUI

/// Result tabs: 视频 | 番剧 | 用户 | 直播.
enum SearchResultTab: Int, CaseIterable, Hashable {
    case video, bangumi, user, live

    var title: String {
        switch self {
        case .video: return "视频"
        case .bangumi: return "番剧"
        case .user: return "用户"
        case .live: return "直播"
        }
    }
}

/// State of one search: the keyword, the per-tab lists and the video / user sort options. Changing
/// the keyword or an option swaps in a fresh `PagedListModel` (captured parameters, no shared state).
@MainActor
final class SearchResultModel: ObservableObject {
    @Published private(set) var keyword: String
    @Published var tab: SearchResultTab = .video
    @Published private(set) var order: SearchVideoOrder = .totalrank
    @Published private(set) var duration: SearchDurationFilter = .all
    @Published private(set) var userOrder: SearchUserOrder = .default
    @Published private(set) var videos: PagedListModel<VideoCard>
    @Published private(set) var bangumi: PagedListModel<VideoCard>
    @Published private(set) var users: PagedListModel<UserBrief>
    @Published private(set) var live: PagedListModel<VideoCard>
    /// Follow state changed from this page (overrides `UserBrief.isFollowed`).
    @Published private(set) var followOverrides: [Int64: Bool] = [:]
    @Published private(set) var followBusy: Set<Int64> = []

    init(keyword: String) {
        self.keyword = keyword
        videos = SearchResultModel.makeVideos(keyword: keyword, order: .totalrank, duration: .all)
        bangumi = SearchResultModel.makeBangumi(keyword: keyword)
        users = SearchResultModel.makeUsers(keyword: keyword, order: .default)
        live = SearchResultModel.makeLive(keyword: keyword)
    }

    // MARK: List factories

    static func makeVideos(keyword: String, order: SearchVideoOrder, duration: SearchDurationFilter) -> PagedListModel<VideoCard> {
        PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .search)) { cursor in
            try await SearchAPI.searchVideos(keyword: keyword, page: ListCursor.page(cursor), order: order, duration: duration)
        }
    }

    static func makeBangumi(keyword: String) -> PagedListModel<VideoCard> {
        PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .search)) { cursor in
            try await SearchAPI.searchBangumi(keyword: keyword, page: ListCursor.page(cursor))
        }
    }

    static func makeUsers(keyword: String, order: SearchUserOrder) -> PagedListModel<UserBrief> {
        PagedListModel<UserBrief> { cursor in
            try await SearchAPI.searchUsers(keyword: keyword, page: ListCursor.page(cursor), order: order)
        }
    }

    static func makeLive(keyword: String) -> PagedListModel<VideoCard> {
        PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .search)) { cursor in
            try await SearchAPI.searchLive(keyword: keyword, page: ListCursor.page(cursor))
        }
    }

    // MARK: Actions

    /// Searches `newKeyword` in place (the same keyword refreshes the current tab).
    func search(_ newKeyword: String) {
        let k = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if k == keyword {
            Task { await refreshCurrentTab() }
            return
        }
        keyword = k
        followOverrides = [:]
        videos = SearchResultModel.makeVideos(keyword: k, order: order, duration: duration)
        bangumi = SearchResultModel.makeBangumi(keyword: k)
        users = SearchResultModel.makeUsers(keyword: k, order: userOrder)
        live = SearchResultModel.makeLive(keyword: k)
    }

    func refreshCurrentTab() async {
        switch tab {
        case .video: await videos.refresh()
        case .bangumi: await bangumi.refresh()
        case .user: await users.refresh()
        case .live: await live.refresh()
        }
    }

    func setOrder(_ newOrder: SearchVideoOrder) {
        guard newOrder != order else { return }
        order = newOrder
        videos = SearchResultModel.makeVideos(keyword: keyword, order: newOrder, duration: duration)
    }

    func setDuration(_ newDuration: SearchDurationFilter) {
        guard newDuration != duration else { return }
        duration = newDuration
        videos = SearchResultModel.makeVideos(keyword: keyword, order: order, duration: newDuration)
    }

    func setUserOrder(_ newOrder: SearchUserOrder) {
        guard newOrder != userOrder else { return }
        userOrder = newOrder
        users = SearchResultModel.makeUsers(keyword: keyword, order: newOrder)
    }

    func isFollowed(_ user: UserBrief) -> Bool {
        followOverrides[user.mid] ?? user.isFollowed
    }

    func toggleFollow(_ user: UserBrief) async {
        guard !followBusy.contains(user.mid) else { return }
        let follow = !isFollowed(user)
        followBusy.insert(user.mid)
        do {
            if follow {
                try await SpaceAPI.follow(mid: user.mid)
            } else {
                try await SpaceAPI.unfollow(mid: user.mid)
            }
            followOverrides[user.mid] = follow
            ToastCenter.shared.show(follow ? "关注成功" : "已取消关注")
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
        }
        followBusy.remove(user.mid)
    }
}

/// Search results (pushed): the keyword stays editable in the navigation bar (submitting
/// re-searches in place), tabs 视频 | 番剧 | 用户 | 直播 with swipe paging. A tab loads the first time it
/// becomes visible, so one search does not fire four requests at once (search is risk-controlled).
struct SearchResultView: View {
    @StateObject private var model: SearchResultModel
    @ObservedObject private var history = SearchHistoryStore.shared
    @State private var text: String
    @State private var barWidth: CGFloat = 375
    @FocusState private var fieldFocused: Bool

    init(keyword: String) {
        _model = StateObject(wrappedValue: SearchResultModel(keyword: keyword))
        _text = State(initialValue: keyword)
    }

    var body: some View {
        VStack(spacing: 0) {
            HomeTabStrip(tabs: SearchResultTab.allCases, selection: $model.tab, spacing: 30) { $0.title }
            Divider()
            TabView(selection: $model.tab) {
                SearchVideoPane(list: model.videos, order: model.order, duration: model.duration,
                                isActive: model.tab == .video,
                                onOrder: { model.setOrder($0) },
                                onDuration: { model.setDuration($0) })
                    .tag(SearchResultTab.video)
                SearchBangumiPane(list: model.bangumi, isActive: model.tab == .bangumi)
                    .tag(SearchResultTab.bangumi)
                SearchUserPane(model: model, list: model.users, isActive: model.tab == .user)
                    .tag(SearchResultTab.user)
                SearchLivePane(list: model.live, isActive: model.tab == .live)
                    .tag(SearchResultTab.live)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(SearchWidthReader(width: $barWidth))
        .background(Color(.systemBackground))
        .navigationTitle(model.keyword)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField
                    .frame(width: max(160, barWidth - 140))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("搜索") { submit() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.biliPink)
            }
        }
        .onChange(of: model.keyword) { newValue in
            if !fieldFocused { text = newValue }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $text)
                .font(.subheadline)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit { submit() }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if fieldFocused && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "清除"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func submit() {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fieldFocused = false
        guard !keyword.isEmpty else {
            text = model.keyword
            return
        }
        text = keyword
        history.add(keyword)
        model.search(keyword)
    }
}

// MARK: - Shared pane plumbing

private struct SearchPaneLoadKey: Hashable {
    let list: ObjectIdentifier
    let active: Bool
}

/// First-page loading / error (risk-control aware) / empty states around a result list. Loads the
/// list the first time its tab is active.
private struct SearchPaneContainer<Item: Identifiable, Content: View>: View {
    @ObservedObject var list: PagedListModel<Item>
    let isActive: Bool
    let emptyText: String
    let content: Content

    init(list: PagedListModel<Item>, isActive: Bool, emptyText: String, @ViewBuilder content: () -> Content) {
        _list = ObservedObject(wrappedValue: list)
        self.isActive = isActive
        self.emptyText = emptyText
        self.content = content()
    }

    var body: some View {
        Group {
            if list.items.isEmpty {
                if let error = list.errorMessage {
                    SearchErrorStateView(message: error) {
                        Task { await list.refresh() }
                    }
                } else if !list.isLoading && !list.hasMore {
                    StateMessageView(systemImage: "magnifyingglass", message: emptyText)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    content
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await list.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(list))
        .task(id: SearchPaneLoadKey(list: ObjectIdentifier(list), active: isActive)) {
            if isActive { await list.loadIfNeeded() }
        }
    }
}

/// Error with retry; the risk-control (-412 / captcha) message gets a shield icon and a hint.
private struct SearchErrorStateView: View {
    let message: String
    let retry: () -> Void

    private var isRisk: Bool {
        message == SearchAPI.riskMessage || message.contains("风控")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isRisk ? "exclamationmark.shield" : "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isRisk {
                Text("请求过于频繁触发了B站风控，稍等片刻再试；登录账号可降低被拦截的概率")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small 「综合排序 ▾」 style menu label.
private struct SearchFilterMenuLabel: View {
    let title: String
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.footnote)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(highlighted ? Color.biliPink : Color.secondary)
        .contentShape(Rectangle())
    }
}

// MARK: - 视频

private struct SearchVideoPane: View {
    @ObservedObject var list: PagedListModel<VideoCard>
    let order: SearchVideoOrder
    let duration: SearchDurationFilter
    let isActive: Bool
    let onOrder: (SearchVideoOrder) -> Void
    let onDuration: (SearchDurationFilter) -> Void

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            SearchPaneContainer(list: list, isActive: isActive, emptyText: "没有找到相关视频") {
                LazyVStack(spacing: 0) {
                    ForEach(list.items) { card in
                        HomeRouteLink(card.route) {
                            VideoRowCell(card: card)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .onAppear { list.onItemAppear(card) }
                    }
                    ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                               error: list.errorMessage, emptyText: "没有找到相关视频") {
                        Task { await list.loadMore() }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 22) {
            Menu {
                ForEach(SearchVideoOrder.allCases) { option in
                    Button {
                        onOrder(option)
                    } label: {
                        if option == order {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                SearchFilterMenuLabel(title: order.title, highlighted: order != .totalrank)
            }
            Menu {
                ForEach(SearchDurationFilter.allCases) { option in
                    Button {
                        onDuration(option)
                    } label: {
                        if option == duration {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                SearchFilterMenuLabel(title: duration.title, highlighted: duration != .all)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

// MARK: - 番剧

private struct SearchBangumiPane: View {
    @ObservedObject var list: PagedListModel<VideoCard>
    let isActive: Bool

    var body: some View {
        SearchPaneContainer(list: list, isActive: isActive, emptyText: "没有找到相关番剧或影视") {
            LazyVStack(spacing: 0) {
                ForEach(list.items) { card in
                    HomeRouteLink(card.route) {
                        HomePGCRowCell(card: card, extra: card.desc)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .onAppear { list.onItemAppear(card) }
                }
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage, emptyText: "没有找到相关番剧或影视") {
                    Task { await list.loadMore() }
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - 用户

private struct SearchUserPane: View {
    @EnvironmentObject private var router: TabRouter
    @ObservedObject var model: SearchResultModel
    @ObservedObject var list: PagedListModel<UserBrief>
    @ObservedObject private var auth = AuthService.shared
    let isActive: Bool

    init(model: SearchResultModel, list: PagedListModel<UserBrief>, isActive: Bool) {
        _model = ObservedObject(wrappedValue: model)
        _list = ObservedObject(wrappedValue: list)
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            orderBar
            Divider()
            SearchPaneContainer(list: list, isActive: isActive, emptyText: "没有找到相关用户") {
                LazyVStack(spacing: 0) {
                    ForEach(list.items) { user in
                        SearchUserRow(user: user,
                                      isFollowed: model.isFollowed(user),
                                      isBusy: model.followBusy.contains(user.mid)) {
                            follow(user)
                        }
                        .onAppear { list.onItemAppear(user) }
                        Divider().padding(.leading, 76)
                    }
                    ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                               error: list.errorMessage, emptyText: "没有找到相关用户") {
                        Task { await list.loadMore() }
                    }
                }
            }
        }
    }

    private var orderBar: some View {
        HStack {
            Menu {
                ForEach(SearchUserOrder.allCases) { option in
                    Button {
                        model.setUserOrder(option)
                    } label: {
                        if option == model.userOrder {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                SearchFilterMenuLabel(title: model.userOrder.title, highlighted: model.userOrder != .default)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func follow(_ user: UserBrief) {
        guard auth.isLoggedIn else {
            router.push(.login)
            return
        }
        Task { await model.toggleFollow(user) }
    }
}

private struct SearchUserRow: View {
    let user: UserBrief
    let isFollowed: Bool
    let isBusy: Bool
    let onFollow: () -> Void

    private var followTitle: String { isFollowed ? "已关注" : "+ 关注" }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.user(mid: user.mid)) {
                HStack(spacing: 12) {
                    AvatarView(url: user.face, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(user.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if user.level > 0 {
                                SearchLevelBadge(level: user.level)
                            }
                        }
                        Text("粉丝：\(Fmt.count(user.fans))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !user.sign.isEmpty {
                            Text(user.sign)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onFollow) {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(followTitle)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(isFollowed ? Color.secondary : Color.white)
                    }
                }
                .frame(width: 68, height: 28)
                .background(isFollowed ? Color(.secondarySystemBackground) : Color.biliPink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 「LV5」 tag in the official level colours.
private struct SearchLevelBadge: View {
    let level: Int

    private var color: Color {
        switch level {
        case 0, 1: return Color(red: 0.75, green: 0.75, blue: 0.75)
        case 2: return Color(red: 0.55, green: 0.85, blue: 0.68)
        case 3: return Color(red: 0.48, green: 0.74, blue: 0.93)
        case 4: return Color(red: 0.99, green: 0.76, blue: 0.29)
        case 5: return Color(red: 1.0, green: 0.55, blue: 0.24)
        default: return Color(red: 0.96, green: 0.31, blue: 0.31)
        }
    }

    var body: some View {
        Text("LV" + String(level))
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: - 直播

private struct SearchLivePane: View {
    @ObservedObject var list: PagedListModel<VideoCard>
    let isActive: Bool

    private var columns: [GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
    }

    var body: some View {
        SearchPaneContainer(list: list, isActive: isActive, emptyText: "没有找到相关直播间") {
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(list.items) { card in
                        HomeRouteLink(card.route) {
                            HomeLiveCardCell(card: card)
                        }
                        .onAppear { list.onItemAppear(card) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage, emptyText: "没有找到相关直播间") {
                    Task { await list.loadMore() }
                }
            }
        }
    }
}
