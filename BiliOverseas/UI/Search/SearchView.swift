import SwiftUI

/// 热搜 words, shared by the 首页 search capsule (rotating placeholder) and the search page.
@MainActor
final class SearchHotWordsModel: ObservableObject {
    static let shared = SearchHotWordsModel()

    @Published private(set) var words: [HotSearchWord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var placeholderIndex = 0
    private var loadedAt: Date?
    /// The running fetch. It belongs to the shared model, not to the view task that started it:
    /// pushing the search page cancels 首页's task, and a second caller must wait for the same
    /// fetch instead of returning with an empty list and no spinner / error.
    private var loadTask: Task<Void, Never>?

    /// How many leading words rotate through the placeholder.
    private static let placeholderPool = 10

    /// The word currently shown as the search placeholder (searching an empty field uses it).
    var placeholderWord: HotSearchWord? {
        let pool = Array(words.prefix(SearchHotWordsModel.placeholderPool))
        guard !pool.isEmpty else { return nil }
        return pool[placeholderIndex % pool.count]
    }

    /// Loads unless a list younger than 10 minutes is already there.
    func loadIfNeeded() async {
        if !words.isEmpty, let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        await reload()
    }

    func reload() async {
        if let running = loadTask {
            await running.value
            return
        }
        let task = Task { await self.fetchWords() }
        loadTask = task
        await task.value
    }

    private func fetchWords() async {
        isLoading = true
        defer {
            isLoading = false
            loadTask = nil
        }
        do {
            let list = try await SearchAPI.hotWords(limit: 30)
            words = list
            loadedAt = Date()
            errorMessage = nil
            placeholderIndex = 0
        } catch {
            if !ListMapping.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func advancePlaceholder() {
        let count = min(words.count, SearchHotWordsModel.placeholderPool)
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            placeholderIndex = (placeholderIndex + 1) % count
        }
    }
}

/// Search page (pushed): auto-focused field in the navigation bar, suggestions while typing,
/// 搜索历史 chips and the 大家都在搜 trending list. Submitting pushes `Route.search(keyword:)`.
struct SearchView: View {
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var hot = SearchHotWordsModel.shared
    @ObservedObject private var history = SearchHistoryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var resolvingLink = false
    @State private var didAutoFocus = false
    @State private var showAllHot = false
    @State private var confirmClear = false
    @State private var barWidth: CGFloat = 375
    @FocusState private var fieldFocused: Bool

    init() {}

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmed.isEmpty {
                landing
            } else {
                suggestionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SearchWidthReader(width: $barWidth))
        .background(Color(.systemBackground))
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField
                    .frame(width: max(160, barWidth - 140))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("搜索") { submit(text) }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.biliPink)
            }
        }
        .task { await autoFocusOnce() }
        .task { await hot.loadIfNeeded() }
        .task(id: trimmed) { await loadSuggestions(for: trimmed) }
        .confirmationDialog("确认清空全部搜索历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Field

    private var placeholderText: String {
        hot.placeholderWord?.showName ?? "搜索"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholderText, text: $text)
                .font(.subheadline)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit { submit(text) }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !text.isEmpty {
                Button {
                    text = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "清除"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    // MARK: - Landing (history + trending)

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !history.keywords.isEmpty || !settings.general.saveSearchHistory {
                    historySection
                }
                hotSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var recordTitle: String { settings.general.saveSearchHistory ? "记录搜索" : "无痕搜索" }
    private var recordIcon: String { settings.general.saveSearchHistory ? "clock.arrow.circlepath" : "eye.slash" }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("搜索历史")
                    .font(.headline)
                Spacer()
                Button(action: toggleRecording) {
                    Label(recordTitle, systemImage: recordIcon)
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if !history.keywords.isEmpty {
                    Button("清空") { confirmClear = true }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if history.keywords.isEmpty {
                Text("无痕搜索中，新的搜索不会被记录")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                SearchChipFlowLayout(spacing: 8, lineSpacing: 10) {
                    ForEach(history.keywords, id: \.self) { keyword in
                        Button {
                            submit(keyword)
                        } label: {
                            SearchHistoryChip(text: keyword)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                history.remove(keyword)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var hotEntries: [SearchHotEntry] {
        var rank = 0
        let source = showAllHot ? hot.words : Array(hot.words.prefix(10))
        return source.map { word in
            if word.isTop { return SearchHotEntry(rank: nil, word: word) }
            rank += 1
            return SearchHotEntry(rank: rank, word: word)
        }
    }

    private var hotToggleTitle: String { showAllHot ? "收起" : "完整榜单" }

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("大家都在搜")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await hot.reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(hot.isLoading)
            }
            if hot.words.isEmpty {
                if hot.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if let error = hot.errorMessage {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await hot.reload() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .leading),
                                    GridItem(.flexible(), spacing: 16, alignment: .leading)],
                          alignment: .leading, spacing: 16) {
                    ForEach(hotEntries) { entry in
                        Button {
                            submit(entry.word.keyword)
                        } label: {
                            SearchHotWordCell(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if hot.words.count > 10 {
                    Button(hotToggleTitle) {
                        withAnimation(.easeInOut(duration: 0.2)) { showAllHot.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Suggestions

    /// The typed text first, then the server's suggestions.
    private var displayedSuggestions: [String] {
        let term = trimmed
        var list = [term]
        for s in suggestions where s.caseInsensitiveCompare(term) != .orderedSame && !list.contains(s) {
            list.append(s)
        }
        return list
    }

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayedSuggestions, id: \.self) { suggestion in
                    suggestionRow(suggestion)
                    Divider().padding(.leading, 42)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func suggestionRow(_ suggestion: String) -> some View {
        HStack(spacing: 0) {
            Button {
                submit(suggestion)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    highlighted(suggestion, term: trimmed)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 16)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                text = suggestion
                fieldFocused = true
            } label: {
                Image(systemName: "arrow.up.left")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "填入搜索框"))
        }
    }

    /// `text` with the first case-insensitive occurrence of `term` in pink.
    private func highlighted(_ text: String, term: String) -> Text {
        guard !term.isEmpty, let range = text.range(of: term, options: .caseInsensitive) else {
            return Text(text).foregroundColor(Color.primary)
        }
        return Text(String(text[..<range.lowerBound])).foregroundColor(Color.primary)
            + Text(String(text[range])).foregroundColor(Color.biliPink)
            + Text(String(text[range.upperBound...])).foregroundColor(Color.primary)
    }

    // MARK: - Actions

    private func submit(_ raw: String) {
        var keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty, let fallback = hot.placeholderWord?.keyword {
            keyword = fallback
        }
        guard !keyword.isEmpty else { return }
        // A BV / av id or a bilibili.com / b23.tv link (also inside pasted share text) opens that page instead.
        if BiliLinkParser.parse(text: keyword) != nil {
            // A b23.tv link resolves over the network: a second submit meanwhile must not push the page twice.
            guard !resolvingLink else { return }
            resolvingLink = true
            fieldFocused = false
            let text = keyword
            Task {
                let target = await BiliLinkResolver.resolve(text: text)
                resolvingLink = false
                router.push(target?.route ?? .search(keyword: text))
            }
            return
        }
        history.add(keyword)
        fieldFocused = false
        router.push(.search(keyword: keyword))
    }

    private func toggleRecording() {
        settings.general.saveSearchHistory.toggle()
        let message = settings.general.saveSearchHistory ? "已开启记录搜索" : "已开启无痕搜索，新的搜索不会被记录"
        ToastCenter.shared.show(message)
    }

    private func autoFocusOnce() async {
        guard !didAutoFocus else { return }
        didAutoFocus = true
        // Focusing during the push animation is ignored; wait for it to settle.
        try? await Task.sleep(nanoseconds: 450_000_000)
        if !Task.isCancelled { fieldFocused = true }
    }

    /// Debounced (250 ms) suggestions; `.task(id:)` cancels the previous term's request. With
    /// 「搜索建议」 off only the typed text is offered.
    private func loadSuggestions(for term: String) async {
        guard !term.isEmpty, AppSettings.shared.general.searchSuggestion else {
            suggestions = []
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let list = (try? await SearchAPI.suggest(term: term)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = list
    }
}

/// One trending entry with its display rank (nil for pinned `top_list` entries).
struct SearchHotEntry: Identifiable, Hashable {
    let rank: Int?
    let word: HotSearchWord
    var id: String { word.id }
}

private struct SearchHotWordCell: View {
    let entry: SearchHotEntry

    var body: some View {
        HStack(spacing: 8) {
            if let rank = entry.rank {
                Text(String(rank))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(rank <= 3 ? HomeRankBadge.color(for: rank) : Color.secondary)
                    .frame(minWidth: 18, alignment: .leading)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.biliPink)
                    .frame(minWidth: 18, alignment: .leading)
            }
            Text(entry.word.showName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !entry.word.icon.isEmpty {
                RemoteImage(url: entry.word.icon, contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else if entry.word.showLiveIcon {
                Text("直播")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct SearchHistoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

/// Reports the width of the view it is a background of (for sizing the navigation-bar search field).
struct SearchWidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { width = $0 }
        }
    }
}

/// Left-aligned wrapping layout for chips (iOS 16 `Layout`).
struct SearchChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Placement {
        var origin: CGPoint
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = arrange(subviews, maxWidth: maxWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : result.size.width, height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() where index < result.placements.count {
            let p = result.placements[index]
            subview.place(at: CGPoint(x: bounds.minX + p.origin.x, y: bounds.minY + p.origin.y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(p.size))
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (placements: [Placement], size: CGSize) {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if maxWidth.isFinite { size.width = min(size.width, maxWidth) }
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        let height = placements.isEmpty ? 0 : y + lineHeight
        return (placements, CGSize(width: usedWidth, height: height))
    }
}
