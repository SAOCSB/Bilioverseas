import SwiftUI
import Combine

/// 稍后再看: whole list with progress, 播放全部, swipe / multi-select remove, 清除已看完 / 清除失效 / 清空.
/// Login required. Opening an item plays on through the list (`VideoPlaylist`).
struct WatchLaterView: View {
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        Group {
            if auth.isLoggedIn {
                MineWatchLaterContent()
            } else {
                LoginRequiredView(message: "登录后查看稍后再看")
            }
        }
        .navigationTitle("稍后再看")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Model

@MainActor
final class MineWatchLaterModel: ObservableObject {
    @Published private(set) var items: [VideoCard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loaded = false
    @Published private(set) var errorMessage: String?

    func loadIfNeeded() async {
        if !loaded && !isLoading { await reload() }
    }

    func reload() async {
        isLoading = true
        do {
            var seen = Set<String>()
            items = try await WatchLaterAPI.list().filter { seen.insert($0.id).inserted }
            loaded = true
            errorMessage = nil
        } catch {
            if !ListMapping.isCancellation(error) { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    /// Optimistic remove; reloads when the server refuses.
    func remove(_ cards: [VideoCard]) {
        let ids = Set(cards.map(\.id))
        let aids = cards.map(\.aid).filter { $0 != 0 }
        items.removeAll { ids.contains($0.id) }
        guard !aids.isEmpty else { return }
        Task {
            do {
                try await WatchLaterAPI.remove(aids: aids)
            } catch {
                ToastCenter.shared.show(error: error)
                await reload()
            }
        }
    }

    func clearWatched() async {
        await perform(done: "已清除已看完的视频") { try await WatchLaterAPI.clearWatched() }
    }

    func clearInvalid() async {
        await perform(done: "已清除失效视频") { try await WatchLaterAPI.clearInvalid() }
    }

    func clearAll() async {
        await perform(done: "已清空稍后再看") { try await WatchLaterAPI.clearAll() }
    }

    private func perform(done: String, _ action: () async throws -> Void) async {
        do {
            try await action()
            ToastCenter.shared.show(done)
            await reload()
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }
}

// MARK: - Screen

struct MineWatchLaterContent: View {
    @EnvironmentObject private var router: TabRouter
    @StateObject private var model = MineWatchLaterModel()
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showClearAllConfirm = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        List(selection: isEditing ? $selection : .constant(Set<String>())) {
            Section {
                ForEach(model.items) { card in
                    MineSelectableVideoRow(card: card, showProgress: true, subtitle: subtitle(card),
                                           isEditing: isEditing) {
                        openCard(card)
                    }
                    .tag(card.id)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.remove([card])
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                if !model.items.isEmpty {
                    HStack {
                        Text("共 \(model.items.count) 个视频")
                        Spacer()
                        if !isEditing {
                            Button(action: playAll) {
                                Label("播放全部", systemImage: "play.circle")
                                    .font(.footnote.weight(.medium))
                                    .foregroundColor(.biliPink)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .textCase(nil)
                }
            }
            Section {
            } footer: {
                ListFooter(isLoading: model.isLoading || (!model.loaded && model.errorMessage == nil),
                           hasMore: false,
                           isEmpty: model.items.isEmpty,
                           error: model.items.isEmpty ? model.errorMessage : nil,
                           emptyText: "稍后再看列表是空的") {
                    Task { await model.reload() }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .pullToRefresh { await model.reload() }
        .task { await model.loadIfNeeded() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("完成") { setEditing(false) }
                } else {
                    Button("编辑") { setEditing(true) }
                        .disabled(model.items.isEmpty)
                    Menu {
                        Button {
                            Task { await model.clearWatched() }
                        } label: {
                            Label("清除已看完的视频", systemImage: "checkmark.circle")
                        }
                        Button {
                            Task { await model.clearInvalid() }
                        } label: {
                            Label("清除失效视频", systemImage: "exclamationmark.circle")
                        }
                        Button(role: .destructive) {
                            showClearAllConfirm = true
                        } label: {
                            Label("清空稍后再看", systemImage: "trash")
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
        .confirmationDialog("确定清空稍后再看吗？", isPresented: $showClearAllConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task { await model.clearAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除列表中的全部视频")
        }
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            selection.removeAll()
            Task { await model.reload() }
        }
    }

    /// "看到 03:12" / "已看完"; nil keeps the default play / danmaku stats line.
    private func subtitle(_ card: VideoCard) -> String? {
        guard let progress = MineListFormat.progressText(card) else { return nil }
        if card.kind == .bangumi, !card.desc.isEmpty { return "\(card.desc) · \(progress)" }
        return progress
    }

    private var allSelected: Bool {
        !model.items.isEmpty && model.items.allSatisfy { selection.contains($0.id) }
    }

    private func toggleAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(model.items.map(\.id))
        }
    }

    private func deleteSelected() {
        let cards = model.items.filter { selection.contains($0.id) }
        guard !cards.isEmpty else { return }
        model.remove(cards)
        setEditing(false)
    }

    private func setEditing(_ editing: Bool) {
        selection.removeAll()
        withAnimation { editMode = editing ? .active : .inactive }
    }

    /// The rows as a 播放全部 list (list order).
    private func makePlaylist() -> VideoPlaylist {
        VideoPlaylist(title: "稍后再看", items: model.items.compactMap(MineListFormat.playlistRef))
    }

    /// Opens the item; the video page continues with the items after it.
    private func openCard(_ card: VideoCard) {
        guard let route = MineListFormat.resumeRoute(card) else { return }
        if case .video(var ref) = route {
            ref.playlist = makePlaylist()
            router.push(.video(ref))
        } else {
            router.push(route)
        }
    }

    private func playAll() {
        let playlist = makePlaylist()
        guard var first = playlist.items.first else { return }
        first.playlist = playlist
        router.push(.video(first))
    }
}
