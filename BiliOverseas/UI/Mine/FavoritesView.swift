import SwiftUI

/// 我的收藏 / TA的收藏: 我创建的 | 我收藏的. `mid == nil` means the signed-in user.
///
/// Folder rows push `.favFolder(id:title:)`. A collected UGC 合集 (`FavFolder.isSeason`) is pushed
/// with a **negative** id (`-seasonId`), which `FavFolderDetailView` reads as "load season contents".
struct FavoritesView: View {
    let mid: Int64?
    @ObservedObject private var auth = AuthService.shared

    init(mid: Int64?) {
        self.mid = mid
    }

    private var targetMid: Int64? {
        if let mid, mid != 0 { return mid }
        return auth.isLoggedIn && auth.mid != 0 ? auth.mid : nil
    }

    private var isMine: Bool {
        guard let mid, mid != 0 else { return true }
        return auth.isLoggedIn && mid == auth.mid
    }

    var body: some View {
        Group {
            if let target = targetMid {
                MineFavoritesContent(mid: target, isMine: isMine)
                    .id(target)
            } else {
                LoginRequiredView(message: "登录后查看收藏")
            }
        }
        .navigationTitle(isMine ? "我的收藏" : "TA的收藏")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Model

@MainActor
final class MineFavoritesModel: ObservableObject {
    let mid: Int64
    @Published private(set) var created: [FavFolder] = []
    @Published private(set) var createdLoading = false
    @Published private(set) var createdLoaded = false
    @Published private(set) var createdError: String?
    /// 收藏的收藏夹 / 合集.
    let collected: PagedListModel<FavFolder>

    init(mid: Int64) {
        self.mid = mid
        collected = PagedListModel<FavFolder> { cursor in
            try await FavAPI.collectedFolders(mid: mid, page: ListCursor.page(cursor))
        }
    }

    func loadCreated(force: Bool) async {
        if createdLoading || (!force && createdLoaded) { return }
        createdLoading = true
        do {
            created = try await FavAPI.myFolders(mid: mid)
            createdLoaded = true
            createdError = nil
        } catch {
            if !ListMapping.isCancellation(error) { createdError = error.localizedDescription }
        }
        createdLoading = false
    }

    func submit(_ target: MineFavEditorTarget, title: String, intro: String, isPrivate: Bool) async -> Bool {
        switch target {
        case .create:
            return await create(title: title, intro: intro, isPrivate: isPrivate)
        case .edit(let folder):
            return await edit(folder, title: title, intro: intro, isPrivate: isPrivate)
        }
    }

    private func create(title: String, intro: String, isPrivate: Bool) async -> Bool {
        do {
            let folder = try await FavAPI.createFolder(title: title, intro: intro, isPrivate: isPrivate)
            // New folders go right after the default folder, like the official app.
            let index = created.first?.isDefault == true ? 1 : 0
            created.insert(folder, at: min(index, created.count))
            ToastCenter.shared.show("已创建收藏夹")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    private func edit(_ folder: FavFolder, title: String, intro: String, isPrivate: Bool) async -> Bool {
        do {
            try await FavAPI.editFolder(mediaId: folder.id, title: title, intro: intro, isPrivate: isPrivate)
            if let i = created.firstIndex(where: { $0.id == folder.id }) {
                created[i].title = title
                created[i].intro = intro
                created[i].isPrivate = isPrivate
            }
            ToastCenter.shared.show("已保存")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    func delete(_ folder: FavFolder) async {
        do {
            try await FavAPI.deleteFolder(mediaId: folder.id)
            created.removeAll { $0.id == folder.id }
            ToastCenter.shared.show("已删除收藏夹")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }
}

/// What the folder editor sheet is doing.
enum MineFavEditorTarget: Identifiable {
    case create
    case edit(FavFolder)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let folder): return "edit-\(folder.id)"
        }
    }

    var folder: FavFolder? {
        if case .edit(let folder) = self { return folder }
        return nil
    }
}

// MARK: - Screen

struct MineFavoritesContent: View {
    let mid: Int64
    let isMine: Bool

    @EnvironmentObject private var router: TabRouter
    @StateObject private var model: MineFavoritesModel
    @State private var segment = 0
    @State private var editorTarget: MineFavEditorTarget?
    @State private var pendingDelete: FavFolder?

    init(mid: Int64, isMine: Bool) {
        self.mid = mid
        self.isMine = isMine
        _model = StateObject(wrappedValue: MineFavoritesModel(mid: mid))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("收藏类型", selection: $segment) {
                Text(isMine ? "我创建的" : "TA创建的").tag(0)
                Text(isMine ? "我收藏的" : "TA收藏的").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if segment == 0 {
                createdList
            } else {
                MineCollectedFolderList(list: model.collected) { openFolder($0) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isMine && segment == 0 {
                    Button {
                        editorTarget = .create
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建收藏夹")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            MineFavFolderEditSheet(folder: target.folder) { title, intro, isPrivate in
                await model.submit(target, title: title, intro: intro, isPrivate: isPrivate)
            }
        }
        .confirmationDialog("删除收藏夹", isPresented: deleteDialogBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { folder in
            Button("删除", role: .destructive) {
                Task { await model.delete(folder) }
            }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text("确定删除收藏夹「\(folder.title)」吗？收藏夹内的内容将一并删除且无法恢复。")
        }
    }

    private var createdList: some View {
        List {
            ForEach(model.created) { folder in
                Button {
                    openFolder(folder)
                } label: {
                    MineFavFolderRow(folder: folder, showOwner: false)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if isMine {
                        if !folder.isDefault {
                            Button {
                                pendingDelete = folder
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        Button {
                            editorTarget = .edit(folder)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
            }
            ListFooter(isLoading: model.createdLoading || (!model.createdLoaded && model.createdError == nil),
                       hasMore: false,
                       isEmpty: model.created.isEmpty,
                       error: model.created.isEmpty ? model.createdError : nil,
                       emptyText: isMine ? "还没有创建收藏夹" : "TA还没有公开的收藏夹") {
                Task { await model.loadCreated(force: true) }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .refreshable { await model.loadCreated(force: true) }
        .task { await model.loadCreated(force: false) }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func openFolder(_ folder: FavFolder) {
        router.push(.favFolder(id: folder.isSeason ? -folder.id : folder.id, title: folder.title))
    }
}

/// 我收藏的: subscribed folders and 合集 (paged).
struct MineCollectedFolderList: View {
    @ObservedObject var list: PagedListModel<FavFolder>
    let onOpen: (FavFolder) -> Void

    var body: some View {
        List {
            ForEach(list.items) { folder in
                Button {
                    onOpen(folder)
                } label: {
                    MineFavFolderRow(folder: folder, showOwner: true)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .onAppear { list.onItemAppear(folder) }
            }
            ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                       error: list.errorMessage, emptyText: "还没有收藏的收藏夹或合集") {
                Task { await list.loadMore() }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .refreshable { await list.refresh() }
        .task { await list.loadIfNeeded() }
    }
}

/// Folder row: 16:10 cover with item count, title, 私密 / 合集 tags, owner.
struct MineFavFolderRow: View {
    let folder: FavFolder
    var showOwner: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            cover
                .frame(width: 120, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(folder.title.isEmpty ? "未命名收藏夹" : folder.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if folder.isSeason { MineFavTag(text: "合集") }
                    if folder.isPrivate {
                        Label("私密", systemImage: "lock.fill")
                            .labelStyle(CompactLabelStyle())
                    }
                    Text("\(folder.count)个内容")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showOwner, !folder.upperName.isEmpty {
                    Text("创建者：\(folder.upperName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var cover: some View {
        if folder.cover.isEmpty {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                Image(systemName: folder.isSeason ? "square.stack" : "star")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            RemoteImage(url: folder.cover, width: 120)
        }
    }
}

/// Small outlined tag ("合集").
struct MineFavTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.biliPink)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliPink.opacity(0.7), lineWidth: 0.5))
    }
}

/// 新建收藏夹 / 编辑收藏夹 sheet. `submit` returns `true` to dismiss.
struct MineFavFolderEditSheet: View {
    let folder: FavFolder?
    let submit: (String, String, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var intro: String
    @State private var isPrivate: Bool
    @State private var submitting = false

    private static let maxTitleLength = 20
    private static let maxIntroLength = 200

    init(folder: FavFolder?, submit: @escaping (String, String, Bool) async -> Bool) {
        self.folder = folder
        self.submit = submit
        _title = State(initialValue: folder?.title ?? "")
        _intro = State(initialValue: folder?.intro ?? "")
        _isPrivate = State(initialValue: folder?.isPrivate ?? false)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The default folder keeps its name.
    private var titleLocked: Bool { folder?.isDefault == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收藏夹名称（必填）", text: $title)
                        .disabled(titleLocked)
                    TextField("简介（选填）", text: $intro, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("名称最多 \(Self.maxTitleLength) 个字")
                }
                Section {
                    Toggle("设为私密", isOn: $isPrivate)
                } footer: {
                    Text("私密收藏夹仅自己可见")
                }
            }
            .navigationTitle(folder == nil ? "新建收藏夹" : "编辑收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button(folder == nil ? "创建" : "保存") {
                            save()
                        }
                        .disabled(trimmedTitle.isEmpty)
                    }
                }
            }
            .onChange(of: title) { newValue in
                if newValue.count > Self.maxTitleLength { title = String(newValue.prefix(Self.maxTitleLength)) }
            }
            .onChange(of: intro) { newValue in
                if newValue.count > Self.maxIntroLength { intro = String(newValue.prefix(Self.maxIntroLength)) }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(submitting)
    }

    private func save() {
        let t = trimmedTitle
        let i = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = isPrivate
        submitting = true
        Task { @MainActor in
            let ok = await submit(t, i, p)
            submitting = false
            if ok { dismiss() }
        }
    }
}
