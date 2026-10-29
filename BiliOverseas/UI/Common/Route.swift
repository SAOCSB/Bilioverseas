import SwiftUI

/// Every push destination in the app. Views navigate with `NavigationLink(value: Route.x)` or
/// `router.push(.x)`; `RouteView` maps a route to its screen.
enum Route: Hashable {
    case video(VideoRef)
    case user(mid: Int64)
    case searchHome
    case search(keyword: String)
    case favorites(mid: Int64?)
    case favFolder(id: Int64, title: String)
    case history
    case watchLater
    case bangumiFollows
    case popularWeekly
    case popularPrecious
    case following(mid: Int64)
    case fans(mid: Int64)
    case live(roomId: Int64)
    case login
    case settings
    case settingsAcceleration
    case settingsPlayer
    case settingsDanmaku
    case settingsFeedFilter
    case settingsSmartSkip
    case about
    case web(URL)
}

extension VideoCard {
    /// Where tapping this card goes.
    var route: Route? {
        switch kind {
        case .video:
            return (aid != 0 || !bvid.isEmpty) ? .video(videoRef) : nil
        case .bangumi:
            return .video(videoRef)
        case .live:
            return roomId != 0 ? .live(roomId: roomId) : nil
        case .article, .ad, .other:
            if !bvid.isEmpty || aid != 0 { return .video(videoRef) }
            return URL(string: uri.biliHTTPS).map { .web($0) }
        }
    }
}

/// Navigation state for one tab's `NavigationStack`.
final class TabRouter: ObservableObject {
    @Published var path = NavigationPath()

    func push(_ route: Route) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path = NavigationPath() }
}

/// Resolves a route to its screen. Each screen type is implemented by its feature folder.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .video(let ref):
            VideoDetailView(ref: ref)
        case .user(let mid):
            UserSpaceView(mid: mid)
        case .searchHome:
            SearchView()
        case .search(let keyword):
            SearchResultView(keyword: keyword)
        case .favorites(let mid):
            FavoritesView(mid: mid)
        case .favFolder(let id, let title):
            FavFolderDetailView(folderId: id, title: title)
        case .history:
            HistoryView()
        case .watchLater:
            WatchLaterView()
        case .bangumiFollows:
            MyBangumiFollowsView()
        case .popularWeekly:
            PopularWeeklyView()
        case .popularPrecious:
            PopularPreciousView()
        case .following(let mid):
            RelationListView(mid: mid, kind: .following)
        case .fans(let mid):
            RelationListView(mid: mid, kind: .fans)
        case .live(let roomId):
            LiveRoomView(roomId: roomId)
        case .login:
            LoginView()
        case .settings:
            SettingsView()
        case .settingsAcceleration:
            AccelerationSettingsView()
        case .settingsPlayer:
            PlayerSettingsView()
        case .settingsDanmaku:
            DanmakuSettingsView()
        case .settingsFeedFilter:
            FeedFilterSettingsView()
        case .settingsSmartSkip:
            SmartSkipSettingsView()
        case .about:
            AboutView()
        case .web(let url):
            SafariView(url: url)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .tabBar)
        }
    }
}

enum RelationKind: String, Hashable {
    case following, fans
}
