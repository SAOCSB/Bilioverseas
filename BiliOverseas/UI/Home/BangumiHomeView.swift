import SwiftUI

/// 番剧 tab state: 我的追番 (logged in), 新番时间表 and 番剧排行.
@MainActor
final class BangumiHomeModel: ObservableObject {
    @Published private(set) var follows: [VideoCard] = []
    @Published private(set) var days: [BangumiDay] = []
    @Published var selectedDayID: String?
    @Published private(set) var rank: [VideoCard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var timelineError: String?
    @Published private(set) var rankError: String?
    private var hasLoaded = false

    /// Selected day, defaulting to today.
    var selectedDay: BangumiDay? {
        if let id = selectedDayID, let day = days.first(where: { $0.id == id }) { return day }
        return days.first(where: { $0.isToday }) ?? days.first
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        async let timelineResult = ListMapping.capture { try await BangumiAPI.timeline(type: 1, before: 3, after: 3) }
        async let rankResult = ListMapping.capture { try await BangumiAPI.rank(seasonType: 1) }
        let (timeline, ranked) = await (timelineResult, rankResult)

        var cancelled = false
        switch timeline {
        case .success(let list):
            days = list
            timelineError = nil
            if let id = selectedDayID, !list.contains(where: { $0.id == id }) { selectedDayID = nil }
        case .failure(let error):
            if ListMapping.isCancellation(error) { cancelled = true } else { timelineError = error.localizedDescription }
        }
        switch ranked {
        case .success(let list):
            let allows = FeedFilter.liveFilter(scope: .ranking)
            var seen = Set<String>()
            rank = list.filter { seen.insert($0.id).inserted && allows($0) }
            rankError = nil
        case .failure(let error):
            if ListMapping.isCancellation(error) { cancelled = true } else { rankError = error.localizedDescription }
        }
        if !cancelled { await loadFollows() }
        if !days.isEmpty || !rank.isEmpty { hasLoaded = true }
        isLoading = false
    }

    /// 我的追番 (first page). Cleared when logged out.
    func loadFollows() async {
        guard AuthService.shared.isLoggedIn else {
            follows = []
            return
        }
        // On failure keep whatever was shown; the row simply stays hidden when nothing loaded.
        if let page = try? await BangumiAPI.myFollows(type: 1, page: 1) {
            follows = page.items
        }
    }
}

/// 番剧: 我的追番 row, 新番时间表 (weekday chips, today selected) and 番剧排行.
struct BangumiHomeView: View {
    @ObservedObject var model: BangumiHomeModel
    @ObservedObject private var auth = AuthService.shared
    @State private var showAllRank = false

    init(model: BangumiHomeModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if auth.isLoggedIn && !model.follows.isEmpty {
                    followsSection
                }
                timelineSection
                rankSection
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .onChange(of: auth.isLoggedIn) { _ in
            Task { await model.loadFollows() }
        }
    }

    // MARK: 我的追番

    private var followsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader("我的追番")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(model.follows) { card in
                        HomeRouteLink(card.route) {
                            BangumiFollowCell(card: card)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: 新番时间表

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader("新番时间表")
            if model.days.isEmpty {
                if let error = model.timelineError {
                    BangumiInlineError(message: error) { Task { await model.reload() } }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            } else {
                dayChips
                episodeList
            }
        }
    }

    private var dayChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.days) { day in
                        dayChip(day)
                            .id(day.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                if let id = model.selectedDay?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.selectedDay?.id) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func dayChip(_ day: BangumiDay) -> some View {
        let isSelected = day.id == model.selectedDay?.id
        let title: String = day.isToday ? "今天" : day.weekdayName
        return Button {
            model.selectedDayID = day.id
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Text(day.date)
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(width: 54, height: 46)
            .background(isSelected ? Color.biliPink : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var episodeList: some View {
        let episodes = model.selectedDay?.episodes ?? []
        if episodes.isEmpty {
            Text("这一天没有番剧更新哦")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { card in
                    HomeRouteLink(card.route) {
                        BangumiTimelineRow(card: card)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: 番剧排行

    private var visibleRank: [VideoCard] {
        showAllRank ? model.rank : Array(model.rank.prefix(10))
    }

    private var rankToggleTitle: String { showAllRank ? "收起" : "查看更多" }

    private var rankSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader("番剧排行") {
                if model.rank.count > 10 {
                    Button(rankToggleTitle) {
                        withAnimation(.easeInOut(duration: 0.2)) { showAllRank.toggle() }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if model.rank.isEmpty {
                if let error = model.rankError {
                    BangumiInlineError(message: error) { Task { await model.reload() } }
                } else if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleRank.enumerated()), id: \.element.id) { index, card in
                        HomeRouteLink(card.route) {
                            HomePGCRowCell(card: card, rank: index + 1, extra: card.desc)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

/// 3:4 cover card in the 我的追番 row.
private struct BangumiFollowCell: View {
    let card: VideoCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: card.cover, width: 100)
                .frame(width: 100, height: 133)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if !card.badge.isEmpty {
                        BadgeLabel(text: card.badge).padding(4)
                    }
                }
            Text(card.title)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !card.reason.isEmpty {
                Text(card.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 100, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One episode of the 新番时间表: publish time, cover, title, episode index.
private struct BangumiTimelineRow: View {
    let card: VideoCard

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeText: String {
        if card.pubdate > 0 {
            return BangumiTimelineRow.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(card.pubdate)))
        }
        return card.reason.split(separator: " ").first.map(String.init) ?? ""
    }

    private var isPublished: Bool {
        card.pubdate > 0 && TimeInterval(card.pubdate) <= Date().timeIntervalSince1970
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(isPublished ? Color.primary : Color.secondary)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 2)
            RemoteImage(url: card.cover, width: 60)
                .frame(width: 60, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if !card.desc.isEmpty {
                        Text(card.desc)
                            .foregroundStyle(isPublished ? Color.biliPink : Color.secondary)
                    }
                    if !card.badge.isEmpty {
                        BadgeLabel(text: card.badge)
                    }
                    if card.isFollowed {
                        Text("已追番")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }
}

private struct BangumiInlineError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
