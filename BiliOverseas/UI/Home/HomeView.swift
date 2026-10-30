import SwiftUI
import Combine

/// Top tabs of 首页, in display order: 直播 first like the official app, 推荐 selected by default.
enum HomeTopTab: Int, CaseIterable, Identifiable, Hashable {
    case live, recommend, popular, ranking, bangumi

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .live: return "直播"
        case .recommend: return "推荐"
        case .popular: return "热门"
        case .ranking: return "排行"
        case .bangumi: return "番剧"
        }
    }

    /// Order of the `GeneralSettings.defaultHomeTab` index (0 = 推荐, 1 = 热门, 2 = 排行, 3 = 番剧, 4 = 直播).
    static let settingOrder: [HomeTopTab] = [.recommend, .popular, .ranking, .bangumi, .live]

    /// Tab for a `GeneralSettings.defaultHomeTab` value (out-of-range → 推荐).
    static func fromSetting(_ index: Int) -> HomeTopTab {
        settingOrder.indices.contains(index) ? settingOrder[index] : .recommend
    }
}

extension Notification.Name {
    /// Posted when the logged-in user taps the avatar in the 首页 top bar. `RootTabView` can observe it
    /// to switch to the 我的 tab (logged-out taps push `Route.login` instead).
    static let homeAvatarTapped = Notification.Name("BiliOverseas.homeAvatarTapped")
}

/// Keeps every home tab's list state alive while the user swipes between tabs. Edited filter rules
/// apply to the rows already shown; logging in / out (or switching accounts) reloads 推荐.
@MainActor
final class HomeTabModels: ObservableObject {
    let recommend: PagedListModel<VideoCard>
    let popular: PagedListModel<VideoCard>
    let ranking: RankingBoardModel
    let bangumi: BangumiHomeModel
    let live: LiveHomeModel
    /// Re-taps of the 首页 tab bar item, per top tab (only the page shown reacts).
    @Published private(set) var reselects: [HomeTopTab: FeedReselectSignal] = [:]

    private var cancellables: Set<AnyCancellable> = []
    /// Account 推荐 was loaded for (0 = logged out), and whether it had a TV login: together they decide
    /// which feed 推荐 shows (`FeedAPI.prefersAppFeed`).
    private var accountMid: Int64
    private var accountHasAppToken: Bool

    init() {
        recommend = PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .recommend)) { cursor in
            try await HomeTabModels.fetchRecommend(cursor: cursor, useAppFeed: AppSettings.shared.general.useAppFeed)
        }
        popular = PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .popular)) { cursor in
            try await FeedAPI.popular(page: ListCursor.page(cursor))
        }
        ranking = RankingBoardModel()
        bangumi = BangumiHomeModel()
        live = LiveHomeModel()
        accountMid = BiliHTTP.shared.mid ?? 0
        accountHasAppToken = FeedAPI.appAuth() != nil
        observe()
    }

    /// 推荐: with 「首页使用app端推荐」 the app feed when it can be personalised (TV login) or nobody is
    /// signed in, else the cookie-personalised web feed, each falling back to the other when it fails or
    /// comes back empty; without it the web feed. Both count pages from 0, so the cursor works for
    /// either. Cards without a size get one, so portrait videos open 短视频 from either feed.
    static func fetchRecommend(cursor: String?, useAppFeed: Bool) async throws -> Page<VideoCard> {
        let appFirst = FeedAPI.prefersAppFeed(useAppFeed: useAppFeed, hasAppToken: FeedAPI.appAuth() != nil,
                                              isLoggedIn: BiliHTTP.shared.isLoggedIn)
        var page = try await recommendPage(cursor: cursor, appFirst: appFirst, fallback: useAppFeed)
        if AppSettings.shared.general.portraitOpensShortVideo {
            page.items = await FeedAPI.fillVideoSizes(page.items)
        }
        return page
    }

    private static func recommendPage(cursor: String?, appFirst: Bool, fallback: Bool) async throws -> Page<VideoCard> {
        func fetch(app: Bool) async throws -> Page<VideoCard> {
            app ? try await FeedAPI.appRecommend(cursor: cursor) : try await FeedAPI.recommend(cursor: cursor)
        }
        guard fallback else { return try await fetch(app: appFirst) }
        do {
            let page = try await fetch(app: appFirst)
            if !page.items.isEmpty { return page }
        } catch {
            if ListMapping.isCancellation(error) { throw error }
        }
        return try await fetch(app: !appFirst)
    }

    func reselect(for tab: HomeTopTab) -> FeedReselectSignal {
        reselects[tab] ?? FeedReselectSignal()
    }

    func fireReselect(_ tab: HomeTopTab, forceRefresh: Bool) {
        reselects[tab, default: FeedReselectSignal()].fire(forceRefresh: forceRefresh)
    }

    private func observe() {
        let settings = AppSettings.shared
        // `@Published` emits before the value is stored; `receive(on:)` reads it once it is.
        settings.$feedFilter
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyFilters() }
            .store(in: &cancellables)
        settings.$general
            .map(\.keepRecommendOnRefresh)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] keep in self?.recommend.keepOnRefresh = keep }
            .store(in: &cancellables)
        settings.$general
            .map(\.useAppFeed)
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadRecommend() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountBlacklistStore.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyFilters() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)
            .merge(with: NotificationCenter.default.publisher(for: AuthService.appTokenDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.accountMayHaveChanged() }
            .store(in: &cancellables)
    }

    /// The 屏蔽 rules (or the synced blacklist) changed: hide matching rows already on screen.
    func reapplyFilters() {
        recommend.reapplyFilter()
        popular.reapplyFilter()
        live.rooms.reapplyFilter()
        ranking.reapplyFilter()
        bangumi.reapplyFilter()
    }

    private func accountMayHaveChanged() {
        let mid = BiliHTTP.shared.mid ?? 0
        let hasAppToken = FeedAPI.appAuth() != nil
        defer { (accountMid, accountHasAppToken) = (mid, hasAppToken) }
        // Another account, or a TV login just added: start 推荐 over. A TV login lost while scrolling (a
        // rejected token) leaves the rows alone; the next pages and refreshes already ask the web feed.
        if mid != accountMid || (hasAppToken && !accountHasAppToken) { reloadRecommend() }
    }

    /// Starts 推荐 over without keeping the old rows (another account's or another source's feed).
    private func reloadRecommend() {
        recommend.replace([])
        Task { await recommend.refresh() }
    }
}

/// 首页 tab root: avatar + search capsule (rotating 热搜 placeholder) + top tab strip
/// 直播 | 推荐 | 热门 | 排行 | 番剧 with swipe paging.
struct HomeView: View {
    @EnvironmentObject private var router: TabRouter
    @StateObject private var models = HomeTabModels()
    @ObservedObject private var auth = AuthService.shared
    @State private var selection: HomeTopTab

    init() {
        _selection = State(initialValue: HomeTopTab.fromSetting(AppSettings.shared.general.defaultHomeTab))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HomeTabStrip(tabs: HomeTopTab.allCases, selection: $selection) { $0.title }
            Divider()
            TabView(selection: $selection) {
                LiveHomeView(model: models.live, reselect: models.reselect(for: .live))
                    .tag(HomeTopTab.live)
                RecommendFeedView(model: models.recommend, reselect: models.reselect(for: .recommend))
                    .tag(HomeTopTab.recommend)
                PopularView(model: models.popular, reselect: models.reselect(for: .popular), onOpenRanking: {
                    withAnimation(.easeInOut(duration: 0.25)) { selection = .ranking }
                })
                .tag(HomeTopTab.popular)
                RankingView(model: models.ranking, reselect: models.reselect(for: .ranking))
                    .tag(HomeTopTab.ranking)
                BangumiHomeView(model: models.bangumi, reselect: models.reselect(for: .bangumi))
                    .tag(HomeTopTab.bangumi)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemBackground))
        .navigationTitle("首页")
        .toolbar(.hidden, for: .navigationBar)
        .task { await rotatePlaceholder() }
        .onReceive(NotificationCenter.default.publisher(for: .mainTabReselected)) { note in
            // Re-tapping 首页 at its root: the visible top tab scrolls up or refreshes.
            guard note.object as? MainTab == .home else { return }
            models.fireReselect(selection, forceRefresh: note.userInfo?[MainTab.forceRefreshKey] as? Bool ?? false)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: avatarTapped) {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: auth.isLoggedIn ? "我的" : "登录"))

            Button {
                router.push(.searchHome)
            } label: {
                HomeSearchCapsule(hotWords: SearchHotWordsModel.shared)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")

            HomeMessageBell()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var avatar: some View {
        if auth.isLoggedIn, let face = auth.profile?.face, !face.isEmpty {
            AvatarView(url: face, size: 30)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(.systemGray3))
                .frame(width: 30, height: 30)
        }
    }

    private func avatarTapped() {
        if auth.isLoggedIn {
            NotificationCenter.default.post(name: .homeAvatarTapped, object: nil)
        } else {
            router.push(.login)
        }
    }

    /// Loads 热搜 once and rotates the placeholder every few seconds while 首页 is visible.
    private func rotatePlaceholder() async {
        let hotWords = SearchHotWordsModel.shared
        await hotWords.loadIfNeeded()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { break }
            hotWords.advancePlaceholder()
        }
    }
}

/// The search capsule with the rotating 热搜 placeholder (its own view so only it re-renders).
private struct HomeSearchCapsule: View {
    @ObservedObject var hotWords: SearchHotWordsModel

    private var placeholder: String {
        hotWords.placeholderWord?.showName ?? "搜索"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
            ZStack(alignment: .leading) {
                Text(placeholder)
                    .lineLimit(1)
                    .id(placeholder)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Official-style top tab strip: horizontally scrollable titles, the selected one pink and bold with
/// a short underline that slides between tabs (also follows swipe paging through `selection`).
struct HomeTabStrip<Tab: Hashable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    let spacing: CGFloat
    @Binding var selection: Tab
    @Namespace private var indicatorSpace

    init(tabs: [Tab], selection: Binding<Tab>, spacing: CGFloat = 24, title: @escaping (Tab) -> String) {
        self.tabs = tabs
        self._selection = selection
        self.spacing = spacing
        self.title = title
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(tabs, id: \.self) { tab in
                        tabButton(tab)
                            .id(tab)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selection) { newValue in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .frame(height: 40)
        .animation(.easeInOut(duration: 0.25), value: selection)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { selection = tab }
        } label: {
            VStack(spacing: 5) {
                Text(title(tab))
                    .font(.system(size: isSelected ? 16 : 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.biliPink : Color.primary.opacity(0.72))
                ZStack {
                    Capsule().fill(Color.clear).frame(width: 18, height: 3)
                    if isSelected {
                        Capsule()
                            .fill(Color.biliPink)
                            .frame(width: 18, height: 3)
                            .matchedGeometryEffect(id: "indicator", in: indicatorSpace)
                    }
                }
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
