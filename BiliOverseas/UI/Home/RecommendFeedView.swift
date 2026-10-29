import SwiftUI

/// 推荐: two-column card grid over the app (or web) recommend feed (ads / promos / live / PGC dropped
/// by `FeedFilter` scope `.recommend`). Pull to refresh (new cards above the old ones with
/// 「保留首页推荐刷新」), infinite scroll, and the card ⋮ menu with 不感兴趣.
struct RecommendFeedView: View {
    @ObservedObject var model: PagedListModel<VideoCard>
    let reselect: FeedReselectSignal

    init(model: PagedListModel<VideoCard>, reselect: FeedReselectSignal = FeedReselectSignal()) {
        _model = ObservedObject(wrappedValue: model)
        self.reselect = reselect
    }

    var body: some View {
        VideoCardGrid(model: model, emptyText: "暂无推荐内容，下拉刷新试试", allowsDislike: true, reselect: reselect)
            .padding(.top, 8)
    }
}
