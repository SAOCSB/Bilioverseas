import SwiftUI
import Combine

/// 我的追番 / 我的追剧 (`BangumiAPI.myFollows`). Login required. Swipe to 取消追番.
struct MyBangumiFollowsView: View {
    @ObservedObject private var auth = AuthService.shared
    @StateObject private var store = MineBangumiFollowsStore()
    @State private var type = 1

    var body: some View {
        Group {
            if auth.isLoggedIn {
                VStack(spacing: 0) {
                    Picker("类型", selection: $type) {
                        Text("追番").tag(1)
                        Text("追剧").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    MineBangumiFollowsList(list: store.list(for: type), type: type)
                        .id("\(type)-\(store.generation)")
                }
            } else {
                LoginRequiredView(message: "登录后查看追番")
            }
        }
        .navigationTitle(type == 1 ? "我的追番" : "我的追剧")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            // The cached lists belong to the previous account (e.g. session expired here, then
            // 扫码登录 from the login prompt as someone else).
            store.reset()
        }
    }
}

/// One paged list per follow type (1 追番, 2 追剧).
@MainActor
final class MineBangumiFollowsStore: ObservableObject {
    private var lists: [Int: PagedListModel<VideoCard>] = [:]
    /// Bumped by `reset()` so the shown list view is rebuilt (and reloads).
    @Published private(set) var generation = 0

    func reset() {
        lists = [:]
        generation += 1
    }

    func list(for type: Int) -> PagedListModel<VideoCard> {
        if let l = lists[type] { return l }
        let l = PagedListModel<VideoCard> { cursor in
            try await BangumiAPI.myFollows(type: type, page: ListCursor.page(cursor))
        }
        lists[type] = l
        return l
    }
}

struct MineBangumiFollowsList: View {
    @ObservedObject var list: PagedListModel<VideoCard>
    let type: Int
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        List {
            ForEach(list.items) { card in
                Button {
                    if let route = card.route { router.push(route) }
                } label: {
                    MineBangumiFollowRow(card: card)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        unfollow(card)
                    } label: {
                        Label(type == 1 ? "取消追番" : "取消追剧", systemImage: "heart.slash")
                    }
                }
                .onAppear { list.onItemAppear(card) }
            }
            ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                       error: list.errorMessage, emptyText: type == 1 ? "还没有追番" : "还没有追剧") {
                Task { await list.loadMore() }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .pullToRefresh { await list.refresh() }
        .task { await list.loadIfNeeded() }
    }

    private func unfollow(_ card: VideoCard) {
        guard card.seasonId != 0 else { return }
        let l = list
        let done = type == 1 ? "已取消追番" : "已取消追剧"
        l.remove { $0.id == card.id }
        Task { @MainActor in
            do {
                try await BangumiAPI.setFollow(seasonId: card.seasonId, follow: false)
                ToastCenter.shared.show(done)
            } catch {
                ToastCenter.shared.show(error: error)
                await l.refresh()
            }
        }
    }
}

/// Portrait (3:4) cover, title, 更新至 …, watch progress.
struct MineBangumiFollowRow: View {
    let card: VideoCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: card.cover, width: 78)
                .frame(width: 78, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !card.desc.isEmpty {
                    Text(card.desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(hasProgress ? Color.biliPink : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }

    /// `reason` is the watch progress ("看到第3话 05:12") or, when there is none, the newest episode.
    private var hasProgress: Bool { !card.reason.isEmpty && card.reason != card.desc }
    private var progressText: String { hasProgress ? card.reason : "尚未观看" }
}
