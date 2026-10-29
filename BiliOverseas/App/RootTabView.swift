import SwiftUI

enum MainTab: Hashable {
    case home, dynamics, mine
}

struct RootTabView: View {
    @State private var tab: MainTab = .home
    @StateObject private var homeRouter = TabRouter()
    @StateObject private var dynamicsRouter = TabRouter()
    @StateObject private var mineRouter = TabRouter()

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
        .task {
            // CI self test (inactive unless launched with -BiliSmokeTest).
            SmokeTest.start(router: homeRouter)
        }
    }

    /// Re-tapping the current tab pops to its root, like the official client.
    private var tabBinding: Binding<MainTab> {
        Binding(
            get: { tab },
            set: { new in
                if new == tab {
                    switch new {
                    case .home: homeRouter.popToRoot()
                    case .dynamics: dynamicsRouter.popToRoot()
                    case .mine: mineRouter.popToRoot()
                    }
                }
                tab = new
            }
        )
    }
}
