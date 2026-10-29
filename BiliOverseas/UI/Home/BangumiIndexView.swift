import SwiftUI

/// 番剧索引 state: one paged list per season type, created when its segment is first shown.
@MainActor
final class BangumiIndexModel: ObservableObject {
    struct SeasonType: Identifiable, Hashable {
        /// `st` / `season_type` of `/pgc/season/index/result`.
        let id: Int
        let name: String
    }

    /// Segments in display order.
    static let seasonTypes: [SeasonType] = [
        SeasonType(id: 1, name: "番剧"), SeasonType(id: 4, name: "国创"), SeasonType(id: 2, name: "电影"),
        SeasonType(id: 5, name: "电视剧"), SeasonType(id: 3, name: "纪录片"),
    ]

    @Published var seasonType: Int
    private var lists: [Int: PagedListModel<VideoCard>] = [:]

    init(seasonType: Int) {
        self.seasonType = BangumiIndexModel.seasonTypes.contains { $0.id == seasonType } ? seasonType : 1
    }

    func list(for type: Int) -> PagedListModel<VideoCard> {
        if let list = lists[type] { return list }
        let order = BangumiIndexModel.order(for: type)
        let list = PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .ranking)) { cursor in
            try await BangumiAPI.index(seasonType: type, page: ListCursor.page(cursor), order: order)
        }
        lists[type] = list
        return list
    }

    /// The index's default sort: 追番人数 (3) for 番剧 / 国创, 播放数量 (2) for the 影视 types.
    static func order(for type: Int) -> Int {
        type == 1 || type == 4 ? 3 : 2
    }
}

/// 番剧索引 (pushed from the 番剧 tab): 番剧 | 国创 | 电影 | 电视剧 | 纪录片, each a paged list of seasons,
/// most followed / played first.
struct BangumiIndexView: View {
    @StateObject private var model: BangumiIndexModel

    init(seasonType: Int = 1) {
        _model = StateObject(wrappedValue: BangumiIndexModel(seasonType: seasonType))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $model.seasonType) {
                ForEach(BangumiIndexModel.seasonTypes) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            BangumiIndexList(list: model.list(for: model.seasonType))
                .id(model.seasonType)
        }
        .navigationTitle("番剧索引")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BangumiIndexList: View {
    @ObservedObject var list: PagedListModel<VideoCard>

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list.items) { card in
                    HomeRouteLink(card.route) {
                        HomePGCRowCell(card: card, extra: card.desc)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .onAppear { list.onItemAppear(card) }
                }
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage, emptyText: "暂无内容") {
                    Task { await list.loadMore() }
                }
            }
            .padding(.top, 4)
        }
        .refreshable { await list.refresh() }
        .task { await list.loadIfNeeded() }
    }
}
