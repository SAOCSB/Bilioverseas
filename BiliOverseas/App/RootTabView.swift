import SwiftUI
import Combine

enum MainTab: Hashable {
    case home, dynamics, mine

    /// `userInfo` key of `.mainTabReselected`: a second re-tap within 0.5 s (refresh even away from the top).
    static let forceRefreshKey = "forceRefresh"
}

extension Notification.Name {
    /// Posted when the selected 首页 / 动态 tab is tapped again while it shows its root (`object`: the
    /// `MainTab`). The visible feed scrolls to the top, or refreshes when it already is there.
    static let mainTabReselected = Notification.Name("BiliOverseas.mainTabReselected")
}

struct RootTabView: View {
    @State private var tab: MainTab = .home
    @StateObject private var homeRouter = TabRouter()
    @StateObject private var dynamicsRouter = TabRouter()
    @StateObject private var mineRouter = TabRouter()
    @ObservedObject private var auth = AuthService.shared
    /// Only 「检查未读动态」 matters here; observing all of AppSettings would re-render the tabs on every settings tick.
    @State private var checkUnreadDynamics = AppSettings.shared.general.checkUnreadDynamics
    @ObservedObject private var dynamicsUnread = DynamicsUnreadModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastReselectTab: MainTab?
    @State private var lastReselectAt = Date.distantPast

    var body: some View {
        TabView(selection: tabBinding) {
            NavigationStack(path: $homeRouter.path) {
                HomeView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .environmentObject(homeRouter)
            .tabItem { Label("首页", systemImage: "house") }
            .tag(MainTab.home)

            NavigationStack(path: $dynamicsRouter.path) {
                DynamicsView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .environmentObject(dynamicsRouter)
            .tabItem { Label("动态", systemImage: "wind") }
            .badge(dynamicsUnread.count)
            .tag(MainTab.dynamics)

            NavigationStack(path: $mineRouter.path) {
                MineView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .environmentObject(mineRouter)
            .tabItem { Label("我的", systemImage: "person") }
            .tag(MainTab.mine)
        }
        .overlay { ToastOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .homeAvatarTapped)) { _ in
            tab = .mine
        }
        .onReceive(AppSettings.shared.$general.map(\.checkUnreadDynamics).removeDuplicates()) {
            checkUnreadDynamics = $0
        }
        .task {
            // Links opened from other apps (bilioverseas://…) push onto the current tab.
            DeepLinkCenter.shared.attach { route in
                switch tab {
                case .home: homeRouter.push(route)
                case .dynamics: dynamicsRouter.push(route)
                case .mine: mineRouter.push(route)
                }
            }
            // CI self test (inactive unless launched with -BiliSmokeTest).
            SmokeTest.start(router: homeRouter)
        }
        // 「检查未读动态」: every 5 minutes while logged in and in the foreground.
        .task(id: unreadPollKey) {
            await DynamicsUnreadModel.shared.poll(unreadPollKey)
        }
        // FeedFilter's 拉黑 rule follows the signed-in account's blacklist.
        .task(id: auth.isLoggedIn ? auth.mid : 0) {
            await syncAccountBlacklist()
        }
    }

    /// Re-tapping the current tab pops to its root, like the official client; at the root, 首页 / 动态
    /// scroll their feed to the top or refresh it. Opening 动态 with the unread badge loads the news.
    private var tabBinding: Binding<MainTab> {
        Binding(
            get: { tab },
            set: { new in
                if new == tab {
                    reselect(new)
                } else if new == .dynamics && dynamicsUnread.count > 0 {
                    NotificationCenter.default.post(name: .mainTabReselected, object: MainTab.dynamics,
                                                    userInfo: [MainTab.forceRefreshKey: true])
                }
                tab = new
            }
        )
    }

    private var unreadPollKey: DynamicsUnreadModel.PollKey {
        DynamicsUnreadModel.PollKey(loggedIn: auth.isLoggedIn, active: scenePhase == .active,
                                    enabled: checkUnreadDynamics)
    }

    private func router(for tab: MainTab) -> TabRouter {
        switch tab {
        case .home: return homeRouter
        case .dynamics: return dynamicsRouter
        case .mine: return mineRouter
        }
    }

    private func reselect(_ tab: MainTab) {
        let router = router(for: tab)
        guard router.path.isEmpty else {
            router.popToRoot()
            return
        }
        guard tab != .mine else { return }
        let now = Date()
        let force = lastReselectTab == tab && now.timeIntervalSince(lastReselectAt) < 0.5
        lastReselectTab = tab
        lastReselectAt = now
        NotificationCenter.default.post(name: .mainTabReselected, object: tab,
                                        userInfo: [MainTab.forceRefreshKey: force])
    }

    private func syncAccountBlacklist() async {
        guard auth.isLoggedIn else {
            AccountBlacklistStore.shared.clear()
            return
        }
        _ = try? await AccountBlacklistStore.shared.refreshFromAccount()
    }
}
