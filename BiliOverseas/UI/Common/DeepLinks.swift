import SwiftUI

extension BiliLinkTarget {
    /// The screen this link opens (a short link that was not expanded opens in the in-app browser).
    var route: Route {
        switch self {
        case .video(let ref): return .video(ref)
        case .user(let mid): return .user(mid: mid)
        case .live(let roomId): return .live(roomId: roomId)
        case .search(let keyword): return .search(keyword: keyword)
        case .shortLink(let url), .web(let url): return .web(url)
        }
    }
}

/// Links handed to the app from outside (`bilioverseas://…`, see `BiliLinkParser.parse(appURL:)`): resolves them
/// (b23.tv over the network) and pushes the page onto the current tab. `RootTabView` attaches the push; a link
/// that arrives before that (a cold launch from the link) waits for it.
@MainActor
final class DeepLinkCenter {
    static let shared = DeepLinkCenter()

    private var open: ((Route) -> Void)?
    private var pending: Route?

    func attach(_ open: @escaping (Route) -> Void) {
        self.open = open
        if let route = pending {
            pending = nil
            open(route)
        }
    }

    /// `onOpenURL`.
    func handle(_ url: URL) {
        Task {
            guard let target = await BiliLinkResolver.resolve(url: url) else {
                ToastCenter.shared.show("无法识别的链接")
                return
            }
            deliver(target.route)
        }
    }

    private func deliver(_ route: Route) {
        if let open {
            open(route)
        } else {
            pending = route
        }
    }
}
