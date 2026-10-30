import SwiftUI
import Combine

/// 历史记录: tabs 全部 / 视频 / 直播 / 专栏, rows grouped by day, swipe / multi-select delete,
/// search, 清空 and 暂停记录. Login required.
struct HistoryView: View {
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        Group {
            if auth.isLoggedIn {
                MineHistoryContent()
            } else {
                LoginRequiredView(message: "登录后查看历史记录")
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Model

@MainActor
final class MineHistoryModel: ObservableObject {
    /// `HistoryAPI.tabs` type.
    @Published var tab: String = "all"
    @Published private(set) var isPaused = false
    /// Non-nil while showing search results.
    @Published private(set) var searchList: PagedListModel<VideoCard>?
    /// Bumped whenever the shown list object is replaced (forces the list view to reload).
    @Published private(set) var generation = 0

    private var lists: [String: PagedListModel<VideoCard>] = [:]

    var currentList: PagedListModel<VideoCard> { searchList ?? list(for: tab) }
    var listID: String { searchList != nil ? "search-\(generation)" : "\(tab)-\(generation)" }
    var isSearching: Bool { searchList != nil }

    func list(for type: String) -> PagedListModel<VideoCard> {
        if let l = lists[type] { return l }
        let l = PagedListModel<VideoCard> { cursor in
            try await HistoryAPI.list(cursor: cursor, type: type)
        }
        lists[type] = l
        return l
    }

    func search(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { endSearch(); return }
        searchList = PagedListModel<VideoCard> { cursor in
            try await HistoryAPI.search(keyword: kw, page: ListCursor.page(cursor))
        }
        generation += 1
    }

    func endSearch() {
        guard searchList != nil else { return }
        searchList = nil
        generation += 1
    }

    /// Drops every cached list (after 清空 / account switch).
    func reset() {
        lists = [:]
        searchList = nil
        generation += 1
    }

    /// Optimistic delete: removes the rows everywhere, then calls the API (reloads on failure).
    func delete(_ cards: [VideoCard]) {
        guard !cards.isEmpty else { return }
        let ids = Set(cards.map(\.id))
        for l in lists.values { l.remove { ids.contains($0.id) } }
        searchList?.remove { ids.contains($0.id) }
        let shown = currentList
        Task {
            do {
                try await HistoryAPI.delete(cards: cards)
            } catch {
                ToastCenter.shared.show(error: error)
                await shown.refresh()
            }
        }
    }

    func loadPaused() async {
        if let paused = try? await HistoryAPI.isPaused() { isPaused = paused }
    }

    func setPaused(_ paused: Bool) async {
        do {
            try await HistoryAPI.setPaused(paused)
            isPaused = paused
            ToastCenter.shared.show(paused ? "已暂停记录观看历史" : "已恢复记录观看历史")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    func clearAll() async {
        do {
            try await HistoryAPI.clear()
            reset()
            ToastCenter.shared.show("已清空观看记录")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }
}

// MARK: - Screen

struct MineHistoryContent: View {
    @EnvironmentObject private var router: TabRouter
    @StateObject private var model = MineHistoryModel()
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var showDeleteWatchedConfirm = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isSearching {
                Picker("类型", selection: $model.tab) {
                    ForEach(0..<HistoryAPI.tabs.count, id: \.self) { i in
                        Text(HistoryAPI.tabs[i].name).tag(HistoryAPI.tabs[i].type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .disabled(isEditing)
            }
            if model.isPaused && !isEditing {
                pausedBanner
            }
            MineHistoryList(
                list: model.currentList,
                grouped: !model.isSearching,
                selection: $selection,
                isEditing: isEditing,
                onOpen: { openCard($0) },
                onDelete: { model.delete($0) }
            )
            .id(model.listID)
            .environment(\.editMode, $editMode)
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索观看记录")
        .onSubmit(of: .search) {
            setEditing(false)
            model.search(searchText)
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty { model.endSearch() }
        }
        .onChange(of: model.tab) { _ in selection.removeAll() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("完成") { setEditing(false) }
                } else {
                    Button("编辑") { setEditing(true) }
                    Menu {
                        Button {
                            Task { await model.setPaused(!model.isPaused) }
                        } label: {
                            Label(model.isPaused ? "恢复观看记录" : "暂停观看记录",
                                  systemImage: model.isPaused ? "play.circle" : "pause.circle")
                        }
                        Button {
                            showDeleteWatchedConfirm = true
                        } label: {
                            Label("删除已看完的记录", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空观看记录", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .toolbar(isEditing ? .hidden : .visible, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                MineEditBottomBar(
                    selectedCount: selection.count,
                    allSelected: allSelected,
                    onToggleAll: toggleAll,
                    onDelete: deleteSelected
                )
            }
        }
        .confirmationDialog("确定清空全部观看记录吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空观看记录", role: .destructive) {
                Task { await model.clearAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后将无法恢复")
        }
        .confirmationDialog("删除已看完的记录？", isPresented: $showDeleteWatchedConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let watched = model.currentList.items.filter { $0.progress < 0 }
                if watched.isEmpty {
                    ToastCenter.shared.show("没有已看完的记录")
                } else {
                    model.delete(watched)
                    ToastCenter.shared.show("已删除 \(watched.count) 条记录")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前列表中已加载的、已看完的记录")
        }
        .task { await model.loadPaused() }
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            selection.removeAll()
            model.reset()
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Color.biliPink)
            Text("已暂停记录观看历史").font(.footnote)
            Spacer()
            Button("恢复记录") {
                Task { await model.setPaused(false) }
            }
            .font(.footnote.weight(.medium))
            .tint(Color.biliPink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.biliPink.opacity(0.08))
    }

    private var allSelected: Bool {
        let items = model.currentList.items
        return !items.isEmpty && items.allSatisfy { selection.contains($0.id) }
    }

    private func toggleAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(model.currentList.items.map(\.id))
        }
    }

    private func deleteSelected() {
        let cards = model.currentList.items.filter { selection.contains($0.id) }
        guard !cards.isEmpty else { return }
        model.delete(cards)
        selection.removeAll()
        setEditing(false)
    }

    private func setEditing(_ editing: Bool) {
        selection.removeAll()
        withAnimation { editMode = editing ? .active : .inactive }
    }

    private func openCard(_ card: VideoCard) {
        guard let route = MineListFormat.resumeRoute(card) else { return }
        router.push(route)
    }
}

/// The history list itself (observes the shown `PagedListModel`).
struct MineHistoryList: View {
    @ObservedObject var list: PagedListModel<VideoCard>
    let grouped: Bool
    @Binding var selection: Set<String>
    let isEditing: Bool
    let onOpen: (VideoCard) -> Void
    let onDelete: ([VideoCard]) -> Void

    var body: some View {
        List(selection: isEditing ? $selection : .constant(Set<String>())) {
            if grouped {
                ForEach(MineHistoryDaySection.make(list.items)) { section in
                    Section {
                        rows(section.cards)
                    } header: {
                        Text(section.title)
                    }
                }
            } else {
                rows(list.items)
            }
            Section {
            } footer: {
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage, emptyText: grouped ? "暂无观看记录" : "没有找到相关记录") {
                    Task { await list.loadMore() }
                }
            }
        }
        .listStyle(.plain)
        .pullToRefresh { await list.refresh() }
        .task { await list.loadIfNeeded() }
    }

    @ViewBuilder
    private func rows(_ cards: [VideoCard]) -> some View {
        ForEach(cards) { card in
            MineSelectableVideoRow(card: card, showProgress: true, subtitle: MineListFormat.historySubtitle(card),
                                   isEditing: isEditing) {
                onOpen(card)
            }
            .tag(card.id)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    onDelete([card])
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .onAppear { list.onItemAppear(card) }
        }
    }
}

/// 今天 / 昨天 / 更早 buckets (in that order, empty ones dropped).
struct MineHistoryDaySection: Identifiable {
    let id: String
    let cards: [VideoCard]

    var title: String { id }

    static func make(_ items: [VideoCard], now: Date = Date()) -> [MineHistoryDaySection] {
        var buckets: [String: [VideoCard]] = [:]
        for card in items {
            buckets[MineListFormat.dayTitle(card.viewAt, now: now), default: []].append(card)
        }
        return MineListFormat.dayOrder.compactMap { title in
            buckets[title].map { MineHistoryDaySection(id: title, cards: $0) }
        }
    }
}

// MARK: - Shared Mine helpers

/// A `VideoRowCell` that opens on tap (or is plain content while the list is in edit mode, so the
/// tap selects the row). `dimmed` greys out invalid items.
struct MineSelectableVideoRow: View {
    let card: VideoCard
    var showProgress: Bool = false
    var subtitle: String? = nil
    var dimmed: Bool = false
    var isEditing: Bool = false
    let onOpen: () -> Void

    var body: some View {
        if isEditing {
            cell
        } else {
            Button(action: onOpen) { cell }
                .buttonStyle(.plain)
        }
    }

    private var cell: some View {
        VideoRowCell(card: card, showProgress: showProgress, subtitle: subtitle)
            .opacity(dimmed ? 0.45 : 1)
    }
}

/// Bottom bar shown while a list is in multi-select mode (历史记录 / 稍后再看).
struct MineEditBottomBar: View {
    let selectedCount: Int
    let allSelected: Bool
    let onToggleAll: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(allSelected ? "取消全选" : "全选", action: onToggleAll)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Text(selectedCount > 0 ? "删除(\(selectedCount))" : "删除")
                    .fontWeight(.medium)
            }
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Wording / routing shared by the 我的 screens.
enum MineListFormat {
    static let dayOrder = ["今天", "昨天", "更早"]

    static func dayTitle(_ unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "更早" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        return "更早"
    }

    /// "看到 03:12" / "已看完" / nil (not started).
    static func progressText(_ card: VideoCard) -> String? {
        if card.progress < 0 { return "已看完" }
        if card.progress > 0 { return "看到 \(Fmt.duration(card.progress))" }
        return nil
    }

    /// Fraction for a cover progress bar, nil when nothing was watched.
    static func progressRatio(_ card: VideoCard) -> Double? {
        guard card.progress != 0 else { return nil }
        if card.progress < 0 { return 1 }
        guard card.duration > 0 else { return nil }
        return min(1, Double(card.progress) / Double(card.duration))
    }

    private static let timeFormatter = makeFormatter("HH:mm")
    private static let yesterdayFormatter = makeFormatter("'昨天' HH:mm")
    private static let monthDayFormatter = makeFormatter("MM-dd HH:mm")
    private static let fullDateFormatter = makeFormatter("yyyy-MM-dd")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    /// View time like the official history list: "14:05" / "昨天 14:05" / "10-21 14:05" / "2023-10-21".
    static func viewTime(_ unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        switch dayTitle(unix, now: now) {
        case "今天": return timeFormatter.string(from: date)
        case "昨天": return yesterdayFormatter.string(from: date)
        default:
            let cal = Calendar.current
            return cal.component(.year, from: date) == cal.component(.year, from: now)
                ? monthDayFormatter.string(from: date)
                : fullDateFormatter.string(from: date)
        }
    }

    /// Second line of a history row: "看到 03:12 · 14:05", "第3话 · 已看完 · 昨天 20:11", "直播 · 10-21 14:05".
    static func historySubtitle(_ card: VideoCard) -> String {
        var parts: [String] = []
        switch card.kind {
        case .live:
            parts.append("直播")
        case .article:
            parts.append("专栏")
        case .bangumi:
            if !card.desc.isEmpty { parts.append(card.desc) }
            if let p = progressText(card) { parts.append(p) }
        default:
            if let p = progressText(card) { parts.append(p) }
        }
        let time = viewTime(card.viewAt)
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    /// Where tapping a history / 稍后再看 card goes. `card.route` already resumes at `progress`
    /// (`VideoRef.startTime`); a finished video (`progress == -1`) restarts from the beginning.
    static func resumeRoute(_ card: VideoCard) -> Route? {
        guard let route = card.route else { return nil }
        if card.progress < 0, case .video(var ref) = route {
            ref.startTime = 0
            return .video(ref)
        }
        return route
    }

    /// The 播放全部 entry for `card` (resumes like `resumeRoute`); nil for cards that do not open a video.
    static func playlistRef(_ card: VideoCard) -> VideoRef? {
        guard let route = resumeRoute(card), case .video(let ref) = route else { return nil }
        return ref
    }
}
