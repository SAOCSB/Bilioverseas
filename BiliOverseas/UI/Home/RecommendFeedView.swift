import SwiftUI

/// 推荐: two-column card grid over the web recommend feed (ads / promos / live / PGC dropped by
/// `FeedFilter` scope `.recommend`). Pull to refresh, infinite scroll.
struct RecommendFeedView: View {
    @ObservedObject var model: PagedListModel<VideoCard>

    init(model: PagedListModel<VideoCard>) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VideoCardGrid(model: model, emptyText: "暂无推荐内容，下拉刷新试试")
            .padding(.top, 8)
    }
}
