import SwiftUI

/// Contents of one 收藏夹 (or, for a negative `folderId`, of the subscribed UGC 合集 `-folderId`;
/// see `FavoritesView`). Header, 播放全部, search, 排序, paged rows, swipe to 取消收藏 in own folders,
/// optional 已失效 items (greyed) and 清除失效内容. Opening an item plays on through the folder.
struct FavFolderDetailView: View {
    let folderId: Int64
    let title: String

    @StateObject private var model: MineFavDetailModel
    @EnvironmentObject private var router: TabRouter
    @State private var searchText = ""
    @State private var showCleanConfirm = false

    init(folderId: Int64, title: String) {
        self.folderId = folderId
        self.title = title
        _model = StateObject(wrappedValue: MineFavDetailModel(folderId: folderId))
    }

    var body: some View {
        MineFavDetailList(model: model, list: model.list, fallbackTitle: title, onPlayAll: { playAll() }) { openCard($0) }
            .id(model.generation)
            .modifier(MineFavSearchModifier(enabled: !model.isSeason, text: $searchText) {
                model.setKeyword(searchText)
            })
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty { model.setKeyword("") }
            }
            .navigationTitle(model.displayTitle(fallback: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !model.isSeason {
                        menu
                    }
                }
            }
            .confirmationDialog("清除失效内容", isPresented: $showCleanConfirm, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    Task { await model.cleanInvalid() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将从该收藏夹中移除所有已失效的视频")
            }
    }

    private var menu: some View {
        Menu {
            Section("排序") {
                Picker("排序", selection: $model.order) {
                    ForEach(MineFavDetailModel.orders, id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            }
            if model.isOwn {
                Section {
                    Toggle(isOn: $model.showInvalid) {
                        Label("显示失效内容", systemImage: "eye")
                    }
                    Button {
                        showCleanConfirm = true
                    } label: {
                        Label("清除失效内容", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("排序与更多")
    }

    private func openCard(_ card: VideoCard) {
        guard !MineFavDetailModel.isInvalid(card), let route = card.route else { return }
        if case .video(var ref) = route {
            ref.playlist = model.makePlaylist(title: model.displayTitle(fallback: title))
            router.push(.video(ref))
        } else {
            router.push(route)
        }
    }

    private func playAll() {
        let playlist = model.makePlaylist(title: model.displayTitle(fallback: title))
        guard var first = playlist.items.first else { return }
        first.playlist = playlist
        router.push(.video(first))
    }
}

// MARK: - Model

/// One sort option of a folder (`order` param).
struct MineFavOrderOption {
    let value: String
    let title: String
}

@MainActor
final class MineFavDetailModel: ObservableObject {
    static let orders: [MineFavOrderOption] = [
        MineFavOrderOption(value: "mtime", title: "最近收藏"),
        MineFavOrderOption(value: "view", title: "最多播放"),
        MineFavOrderOption(value: "pubtime", title: "最新投稿"),
    ]

    let folderId: Int64
    /// Folder header (`data.info` of the contents response); nil for 合集 and before the first page.
    @Published private(set) var info: FavFolder?
    @Published var order: String = "mtime" {
        didSet { if order != oldValue { rebuild() } }
    }
    @Published var showInvalid = false {
        didSet { if showInvalid != oldValue { rebuild() } }
    }
    @Published private(set) var keyword = ""
    @Published private(set) var list: PagedListModel<VideoCard>
    /// Bumped whenever `list` is replaced.
    @Published private(set) var generation = 0

    init(folderId: Int64) {
        self.folderId = folderId
        list = PagedListModel<VideoCard> { _ in Page<VideoCard>.empty }
        list = makeList()
    }

    /// A negative id is a subscribed UGC 合集.
    var isSeason: Bool { folderId < 0 }
    var mediaId: Int64 { folderId < 0 ? -folderId : folderId }

    /// The signed-in user owns this folder (enables 取消收藏 / 失效内容).
    var isOwn: Bool {
        guard !isSeason, let info else { return false }
        let me = AuthService.shared.mid
        return me != 0 && (info.mid == me || info.upperMid == me)
    }

    func displayTitle(fallback: String) -> String {
        if let t = info?.title, !t.isEmpty { return t }
        return fallback
    }

    static func isInvalid(_ card: VideoCard) -> Bool {
        card.kind == .other && card.badge == "已失效"
    }

    func setKeyword(_ text: String) {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k != keyword else { return }
        keyword = k
        rebuild()
    }

    /// Optimistic 取消收藏 of one item.
    func remove(_ card: VideoCard) {
        let shown = list
        shown.remove { $0.id == card.id }
        if var i = info {
            i.count = max(0, i.count - 1)
            info = i
        }
        let id = mediaId
        Task {
            do {
                try await FavAPI.removeItems(mediaId: id, cards: [card])
                ToastCenter.shared.show("已取消收藏")
            } catch {
                ToastCenter.shared.show(error: error)
                await shown.refresh()
            }
        }
    }

    /// 播放全部 list: the loaded rows (valid videos only), then the folder's further pages in the same order /
    /// search. Pages hold at most 20 rows, so `rows / 20 + 1` never skips one (`VideoPlaylist` drops overlap).
    func makePlaylist(title: String) -> VideoPlaylist {
        let refs = list.items.filter { !MineFavDetailModel.isInvalid($0) }.compactMap(MineListFormat.playlistRef)
        let id = mediaId
        let season = isSeason
        let order = self.order
        let keyword = self.keyword
        return VideoPlaylist(title: title, items: refs, nextPage: list.items.count / 20 + 1,
                             hasMore: list.hasMore) { @MainActor page in
            let p: Page<VideoCard>
            if season {
                p = try await FavAPI.seasonContents(seasonId: id, page: page)
            } else {
                p = try await FavAPI.folderContents(mediaId: id, page: page, keyword: keyword, order: order)
            }
            let items = p.items.filter { !MineFavDetailModel.isInvalid($0) }.compactMap(MineListFormat.playlistRef)
            return Page(items: items, hasMore: p.hasMore, next: p.next)
        }
    }

    func cleanInvalid() async {
        do {
            try await FavAPI.cleanInvalid(mediaId: mediaId)
            ToastCenter.shared.show("已清除失效内容")
            rebuild()
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    private func rebuild() {
        list = makeList()
        generation += 1
    }

    private func applyInfo(_ newInfo: FavFolder) {
        if info != newInfo { info = newInfo }
    }

    private func makeList() -> PagedListModel<VideoCard> {
        let id = mediaId
        let season = isSeason
        let order = self.order
        let keyword = self.keyword
        let includeInvalid = showInvalid
        return PagedListModel<VideoCard> { @MainActor [weak self] cursor in
            let page = ListCursor.page(cursor)
            if season {
                return try await FavAPI.seasonContents(seasonId: id, page: page)
            }
            // Same request as `FavAPI.folderContents`, but keeps `data.info` for the header.
            let data = try await BiliHTTP.shared.api(
                BiliHost.api + "/x/v3/fav/resource/list",
                query: [
                    "media_id": id, "pn": page, "ps": 20, "keyword": keyword, "order": order,
                    "type": 0, "tid": 0, "platform": "web",
                ])
            if let info = FavAPI.parseFolderInfo(data) { self?.applyInfo(info) }
            return FavAPI.parseContents(data, page: page, includeInvalid: includeInvalid)
        }
    }
}

// MARK: - Views

struct MineFavDetailList: View {
    @ObservedObject var model: MineFavDetailModel
    @ObservedObject var list: PagedListModel<VideoCard>
    let fallbackTitle: String
    let onPlayAll: () -> Void
    let onOpen: (VideoCard) -> Void

    var body: some View {
        List {
            MineFavDetailHeader(info: model.info, title: model.displayTitle(fallback: fallbackTitle),
                                isSeason: model.isSeason, keyword: model.keyword)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .listRowSeparator(.hidden)

            if list.items.contains(where: { !MineFavDetailModel.isInvalid($0) }) {
                Button(action: onPlayAll) {
                    Label("播放全部", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.biliPink)
                }
                .buttonStyle(.borderless)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
            }

            ForEach(list.items) { card in
                let invalid = MineFavDetailModel.isInvalid(card)
                MineSelectableVideoRow(card: card, dimmed: invalid) {
                    onOpen(card)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if model.isOwn {
                        Button(role: .destructive) {
                            model.remove(card)
                        } label: {
                            Label("取消收藏", systemImage: "star.slash")
                        }
                    }
                }
                .onAppear { list.onItemAppear(card) }
            }

            ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                       error: list.errorMessage,
                       emptyText: model.keyword.isEmpty ? "收藏夹里还没有内容" : "没有找到相关内容") {
                Task { await list.loadMore() }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .refreshable { await list.refresh() }
        .task { await list.loadIfNeeded() }
    }
}

/// Cover, title, owner, count, 私密 / 公开, intro.
struct MineFavDetailHeader: View {
    let info: FavFolder?
    let title: String
    let isSeason: Bool
    let keyword: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
                .frame(width: 128, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let info, !info.upperName.isEmpty {
                    HStack(spacing: 4) {
                        AvatarView(url: info.upperFace, size: 18)
                        Text(info.upperName).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if isSeason { MineFavTag(text: "合集") }
                    if let info {
                        Text("\(info.count)个内容")
                        if info.isPrivate {
                            Label("私密", systemImage: "lock.fill").labelStyle(CompactLabelStyle())
                        } else if !isSeason {
                            Text("公开")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let intro = info?.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !keyword.isEmpty {
                    Text("搜索：\(keyword)")
                        .font(.caption)
                        .foregroundStyle(Color.biliPink)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var cover: some View {
        if let url = info?.cover, !url.isEmpty {
            RemoteImage(url: url, width: 128)
        } else {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                Image(systemName: isSeason ? "square.stack" : "star")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Applies `.searchable` only when the folder supports keyword search (not for 合集).
struct MineFavSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let onSubmit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索收藏夹内的视频")
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}
