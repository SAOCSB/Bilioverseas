import SwiftUI

/// One 排行榜 zone chip: a UGC zone (`FeedAPI.ranking(rid:)`) or a PGC zone (`BangumiAPI.rank(seasonType:)`).
enum RankingZone: Hashable, Identifiable {
    case ugc(rid: Int, name: String)
    case pgc(seasonType: Int, name: String)

    var id: String {
        switch self {
        case .ugc(let rid, _): return "ugc-\(rid)"
        case .pgc(let seasonType, _): return "pgc-\(seasonType)"
        }
    }

    var name: String {
        switch self {
        case .ugc(_, let name), .pgc(_, let name): return name
        }
    }

    var isPGC: Bool {
        if case .pgc = self { return true }
        return false
    }

    /// Official chip order: 全站, 番剧, 国创, the UGC zones, then 纪录片 / 电影 / 电视剧 / 综艺.
    static let all: [RankingZone] = {
        let ugc = FeedAPI.rankingZones.map { RankingZone.ugc(rid: $0.rid, name: $0.name) }
        let leadingTypes: Set<Int> = [1, 4]
        let leadingPGC = FeedAPI.pgcRankingZones
            .filter { leadingTypes.contains($0.seasonType) }
            .map { RankingZone.pgc(seasonType: $0.seasonType, name: $0.name) }
        let trailingPGC = FeedAPI.pgcRankingZones
            .filter { !leadingTypes.contains($0.seasonType) }
            .map { RankingZone.pgc(seasonType: $0.seasonType, name: $0.name) }
        guard let first = ugc.first else { return leadingPGC + trailingPGC }
        var out: [RankingZone] = [first]
        out.append(contentsOf: leadingPGC)
        out.append(contentsOf: ugc.dropFirst())
        out.append(contentsOf: trailingPGC)
        return out
    }()
}

/// A ranked card; `rank` is the server position (kept when filtered cards leave gaps).
struct RankingEntry: Identifiable, Hashable {
    let rank: Int
    let card: VideoCard
    var id: String { card.id }
}

/// 排行榜 state per zone (each zone is one ~100-item list, cached once loaded).
@MainActor
final class RankingBoardModel: ObservableObject {
    @Published var zone: RankingZone
    @Published private(set) var entries: [RankingZone: [RankingEntry]] = [:]
    /// Every loaded entry per zone before `FeedFilter`, so edited rules re-filter without a reload.
    private var rawEntries: [RankingZone: [RankingEntry]] = [:]
    @Published private(set) var loadingZones: Set<RankingZone> = []
    @Published private(set) var errors: [RankingZone: String] = [:]
    /// Latest request per zone; an older (e.g. cancelled) request never overwrites a newer one.
    private var tokens: [RankingZone: Int] = [:]

    init() {
        zone = RankingZone.all.first ?? .ugc(rid: 0, name: "全站")
    }

    func loadIfNeeded() async {
        let z = zone
        if entries[z] == nil { await load(z) }
    }

    func reload() async {
        await load(zone)
    }

    func load(_ z: RankingZone) async {
        let token = (tokens[z] ?? 0) + 1
        tokens[z] = token
        loadingZones.insert(z)
        errors[z] = nil
        do {
            let cards: [VideoCard]
            switch z {
            case .ugc(let rid, _):
                cards = try await FeedAPI.ranking(rid: rid)
            case .pgc(let seasonType, _):
                cards = try await BangumiAPI.rank(seasonType: seasonType)
            }
            guard tokens[z] == token else { return }
            var seen = Set<String>()
            var list: [RankingEntry] = []
            for (index, card) in cards.enumerated() where seen.insert(card.id).inserted {
                list.append(RankingEntry(rank: index + 1, card: card))
            }
            rawEntries[z] = list
            entries[z] = RankingBoardModel.filtered(list)
        } catch {
            guard tokens[z] == token else { return }
            if !ListMapping.isCancellation(error) {
                if entries[z] == nil {
                    errors[z] = error.localizedDescription
                } else {
                    ToastCenter.shared.show(error: error)
                }
            }
        }
        loadingZones.remove(z)
    }

    /// The 屏蔽 rules changed: filter every loaded zone again (ranks keep their server positions).
    func reapplyFilter() {
        for (z, list) in rawEntries { entries[z] = RankingBoardModel.filtered(list) }
    }

    /// Hides matching entries in every zone (card menu: 屏蔽UP主).
    func remove(where predicate: (VideoCard) -> Bool) {
        for (z, list) in rawEntries { rawEntries[z] = list.filter { !predicate($0.card) } }
        for (z, list) in entries { entries[z] = list.filter { !predicate($0.card) } }
    }

    private static func filtered(_ list: [RankingEntry]) -> [RankingEntry] {
        let allows = FeedFilter.liveFilter(scope: .ranking)
        return list.filter { allows($0.card) }
    }
}

/// 排行: zone chip bar + numbered single-column list (1 / 2 / 3 highlighted).
struct RankingView: View {
    @ObservedObject var model: RankingBoardModel
    /// Re-taps of the 首页 tab bar item (scroll to top / refresh).
    let reselect: FeedReselectSignal
    @State private var topTracker = FeedTopTracker()
    @State private var isReselectRefreshing = false

    init(model: RankingBoardModel, reselect: FeedReselectSignal = FeedReselectSignal()) {
        _model = ObservedObject(wrappedValue: model)
        self.reselect = reselect
    }

    var body: some View {
        VStack(spacing: 0) {
            HomeChipBar(items: RankingZone.all, selection: $model.zone) { $0.name }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.zone) { await model.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        let zone = model.zone
        if let list = model.entries[zone] {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        FeedTopAnchor(tracker: topTracker)
                        if isReselectRefreshing { FeedRefreshingRow() }
                        LazyVStack(spacing: 0) {
                            ForEach(list) { entry in
                                HomeRouteLink(entry.card.route) {
                                    if zone.isPGC {
                                        HomePGCRowCell(card: entry.card, rank: entry.rank, extra: entry.card.desc)
                                    } else {
                                        HomeVideoRow(card: entry.card, rank: entry.rank, showReason: false)
                                    }
                                }
                                .videoCardMenu(entry.card) { predicate, _ in model.remove(where: predicate) }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            ListFooter(isLoading: false, hasMore: false, isEmpty: list.isEmpty, error: nil,
                                       emptyText: "暂无排行数据")
                        }
                        .padding(.top, 4)
                    }
                }
                .pullToRefresh { await model.reload() }
                .feedReselect(reselect, proxy: proxy, tracker: topTracker, isRefreshing: $isReselectRefreshing) {
                    await model.reload()
                }
            }
            .id(zone)
        } else if let error = model.errors[zone] {
            StateMessageView(systemImage: "exclamationmark.triangle", message: error) {
                Task { await model.reload() }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
