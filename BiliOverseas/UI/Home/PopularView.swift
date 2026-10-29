import SwiftUI

/// 热门: entry row (排行榜 / 每周必看 / 入站必刷) above a single-column list of large rows with
/// recommend-reason tags. Filtered with `FeedFilter` scope `.popular`.
struct PopularView: View {
    @ObservedObject var model: PagedListModel<VideoCard>
    /// 排行榜 entry: switches the home pager to 排行 (hidden when nil).
    let onOpenRanking: (() -> Void)?

    init(model: PagedListModel<VideoCard>, onOpenRanking: (() -> Void)? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.onOpenRanking = onOpenRanking
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PopularEntryRow(onOpenRanking: onOpenRanking)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                ForEach(model.items) { card in
                    HomeRouteLink(card.route) {
                        HomeVideoRow(card: card)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .onAppear { model.onItemAppear(card) }
                }
                ListFooter(isLoading: model.isLoading, hasMore: model.hasMore, isEmpty: model.isEmpty,
                           error: model.errorMessage, emptyText: "暂无热门视频") {
                    Task { await model.loadMore() }
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}

/// The three round entries at the top of 热门.
private struct PopularEntryRow: View {
    let onOpenRanking: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let onOpenRanking {
                Button(action: onOpenRanking) {
                    PopularEntryTile(title: "排行榜", systemImage: "chart.bar.fill",
                                     tint: Color(red: 1.0, green: 0.62, blue: 0.2))
                }
                .buttonStyle(.plain)
            }
            NavigationLink(destination: PopularWeeklyView()) {
                PopularEntryTile(title: "每周必看", systemImage: "calendar",
                                 tint: Color(red: 0.98, green: 0.4, blue: 0.4))
            }
            .buttonStyle(.plain)
            NavigationLink(destination: PopularPreciousView()) {
                PopularEntryTile(title: "入站必刷", systemImage: "star.fill",
                                 tint: Color.biliPink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }
}

private struct PopularEntryTile: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint, in: RoundedRectangle(cornerRadius: 14))
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - 每周必看

@MainActor
final class PopularWeeklyModel: ObservableObject {
    @Published private(set) var issues: [PopularWeeklyIssue] = []
    @Published private(set) var current: PopularWeeklyIssue?
    @Published private(set) var cards: [VideoCard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var token = 0

    func loadIfNeeded() async {
        guard issues.isEmpty, !isLoading else { return }
        await reload()
    }

    /// Reloads the issue list and the selected (or newest) issue.
    func reload() async {
        token += 1
        let t = token
        isLoading = true
        errorMessage = nil
        do {
            let list = try await FeedAPI.weeklyList()
            guard t == token else { return }
            issues = list
            let keep = current.flatMap { c in list.first { $0.number == c.number } }
            if let target = keep ?? list.first {
                await select(target)
                return
            }
            cards = []
        } catch {
            guard t == token else { return }
            if !ListMapping.isCancellation(error) { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    func select(_ issue: PopularWeeklyIssue) async {
        token += 1
        let t = token
        current = issue
        isLoading = true
        errorMessage = nil
        do {
            let list = try await FeedAPI.weekly(number: issue.number)
            guard t == token else { return }
            let allows = FeedFilter.liveFilter(scope: .popular)
            var seen = Set<String>()
            cards = list.filter { seen.insert($0.id).inserted && allows($0) }
        } catch {
            guard t == token else { return }
            if !ListMapping.isCancellation(error) { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    func retry() async {
        if let current, !issues.isEmpty {
            await select(current)
        } else {
            await reload()
        }
    }
}

/// 每周必看: one issue at a time, issue picker in the navigation bar.
struct PopularWeeklyView: View {
    @StateObject private var model = PopularWeeklyModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let issue = model.current {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.name)
                            .font(.headline)
                        if !issue.subject.isEmpty {
                            Text(issue.subject)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                ForEach(model.cards) { card in
                    HomeRouteLink(card.route) {
                        HomeVideoRow(card: card)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                ListFooter(isLoading: model.isLoading, hasMore: false, isEmpty: model.cards.isEmpty,
                           error: model.errorMessage, emptyText: "本期暂无视频") {
                    Task { await model.retry() }
                }
            }
        }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .navigationTitle("每周必看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                issueMenu
            }
        }
    }

    private var issueMenuTitle: String {
        guard let current = model.current else { return "往期" }
        return "第\(current.number)期"
    }

    private var issueMenu: some View {
        Menu {
            ForEach(model.issues) { issue in
                Button {
                    Task { await model.select(issue) }
                } label: {
                    if issue.number == model.current?.number {
                        Label(issue.name, systemImage: "checkmark")
                    } else {
                        Text(issue.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(issueMenuTitle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
        }
        .disabled(model.issues.isEmpty)
    }
}

// MARK: - 入站必刷

/// 入站必刷: ~100 classics, each with its 「achievement」 line as the reason tag.
struct PopularPreciousView: View {
    @StateObject private var model = PagedListModel<VideoCard>(filter: FeedFilter.liveFilter(scope: .popular)) { cursor in
        try await FeedAPI.precious(page: ListCursor.page(cursor))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { card in
                    HomeRouteLink(card.route) {
                        HomeVideoRow(card: card)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .onAppear { model.onItemAppear(card) }
                }
                ListFooter(isLoading: model.isLoading, hasMore: model.hasMore, isEmpty: model.isEmpty,
                           error: model.errorMessage, emptyText: "暂无内容") {
                    Task { await model.loadMore() }
                }
            }
            .padding(.top, 6)
        }
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .navigationTitle("入站必刷")
        .navigationBarTitleDisplayMode(.inline)
    }
}
