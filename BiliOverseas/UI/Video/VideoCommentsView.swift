import SwiftUI
import UIKit

// MARK: - Public screen

/// 评论区 for any comment area (`oid` + `type`: 1 video, 11/17 dynamics, 12 articles …). Includes the bottom
/// composer bar. The video detail page embeds `VideoCommentsListView` directly instead.
struct VideoCommentsView: View {
    @StateObject private var model: VideoCommentsModel
    private let onSeek: ((Double) -> Void)?

    init(oid: Int64, type: Int = 1, onSeek: ((Double) -> Void)? = nil) {
        _model = StateObject(wrappedValue: VideoCommentsModel(oid: oid, type: type))
        self.onSeek = onSeek
    }

    var body: some View {
        VideoCommentsListView(model: model, hostsComposer: true, showsComposerBar: true, onSeek: onSeek)
    }
}

// MARK: - Composer target

/// What the composer replies to. Root comment: all zero. Reply to a root comment: root = parent = its rpid.
/// Reply to a sub reply: root = its root, parent = its rpid, and the message gets the 「回复 @名字 :」 prefix.
struct VideoCommentComposerTarget: Identifiable {
    let id = UUID()
    var root: Int64 = 0
    var parent: Int64 = 0
    var replyToName: String = ""
    var messagePrefix: String = ""

    static func reply(to item: ReplyItem) -> VideoCommentComposerTarget {
        if item.root == 0 {
            return VideoCommentComposerTarget(root: item.rpid, parent: item.rpid, replyToName: item.uname)
        }
        return VideoCommentComposerTarget(root: item.root, parent: item.rpid, replyToName: item.uname,
                                          messagePrefix: "回复 @\(item.uname) :")
    }

    var placeholder: String { replyToName.isEmpty ? "发个友善的评论吧" : "回复 @\(replyToName)：" }
}

private func videoCommentIsCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let e = error as? BiliError, case .cancelled = e { return true }
    return false
}

// MARK: - Shared actions

/// Like / dislike with optimistic updates, shared by the main list and the sub-reply sheet.
@MainActor
protocol VideoCommentMutating: AnyObject {
    var oid: Int64 { get }
    var type: Int { get }
    func updateReply(_ rpid: Int64, _ change: (inout ReplyItem) -> Void)
}

extension VideoCommentMutating {
    func toggleLike(_ item: ReplyItem) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        let target = !item.userLiked
        let original = (liked: item.userLiked, disliked: item.userDisliked, count: item.likeCount)
        updateReply(item.rpid) { r in
            r.userLiked = target
            r.likeCount = max(0, original.count + (target ? 1 : -1))
            if target { r.userDisliked = false }
        }
        let areaOid = self.oid
        let areaType = self.type
        let rpid = item.rpid
        Task { [weak self] in
            do {
                try await ReplyAPI.like(oid: areaOid, type: areaType, rpid: rpid, like: target)
            } catch {
                self?.updateReply(rpid) { r in
                    r.userLiked = original.liked
                    r.userDisliked = original.disliked
                    r.likeCount = original.count
                }
                ToastCenter.shared.show(error: error)
            }
        }
    }

    func toggleDislike(_ item: ReplyItem) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        let target = !item.userDisliked
        let original = (liked: item.userLiked, disliked: item.userDisliked, count: item.likeCount)
        updateReply(item.rpid) { r in
            r.userDisliked = target
            if target && original.liked {
                r.userLiked = false
                r.likeCount = max(0, original.count - 1)
            }
        }
        let areaOid = self.oid
        let areaType = self.type
        let rpid = item.rpid
        Task { [weak self] in
            do {
                try await ReplyAPI.dislike(oid: areaOid, type: areaType, rpid: rpid, dislike: target)
            } catch {
                self?.updateReply(rpid) { r in
                    r.userLiked = original.liked
                    r.userDisliked = original.disliked
                    r.likeCount = original.count
                }
                ToastCenter.shared.show(error: error)
            }
        }
    }
}

// MARK: - Main list model

@MainActor
final class VideoCommentsModel: ObservableObject, VideoCommentMutating {
    let oid: Int64
    let type: Int

    @Published private(set) var sort: ReplySort
    @Published private(set) var topItems: [ReplyItem] = []
    @Published private(set) var items: [ReplyItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?
    /// `cursor.all_count` (0 until the first page arrives).
    @Published private(set) var totalCount = 0
    @Published private(set) var upperMid: Int64 = 0
    @Published private(set) var inputPlaceholder = ""
    @Published private(set) var inputDisabled = false
    /// Set to present the composer.
    @Published var composerTarget: VideoCommentComposerTarget?
    /// Set to present the sub-reply sheet.
    @Published var subRepliesRoot: ReplyItem?

    private var cursor: String?
    private var seen = Set<Int64>()
    private var generation = 0
    /// Consecutive pages that added no new row (all duplicates / pinned).
    private var emptyPages = 0

    init(oid: Int64, type: Int = 1, sort: ReplySort = .hot) {
        self.oid = oid
        self.type = type
        self.sort = sort
    }

    func loadIfNeeded() async {
        guard oid > 0, !didLoad, !isLoading else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard didLoad, hasMore, !isLoading else { return }
        await load(reset: false)
    }

    func retry() async {
        if didLoad && !(items.isEmpty && topItems.isEmpty) {
            errorMessage = nil
            await loadMore()
        } else {
            await refresh()
        }
    }

    func onItemAppear(_ item: ReplyItem) {
        guard didLoad, hasMore, !isLoading else { return }
        if items.suffix(5).contains(where: { $0.rpid == item.rpid }) {
            Task { await loadMore() }
        }
    }

    func setSort(_ newSort: ReplySort) {
        guard newSort != sort else { return }
        sort = newSort
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard oid > 0 else { return }
        if reset { generation += 1 }
        let gen = generation
        isLoading = true
        errorMessage = nil
        do {
            let page = try await ReplyAPI.mainList(oid: oid, type: type, sort: sort, cursor: reset ? nil : cursor)
            guard gen == generation else { return }
            if reset {
                topItems = page.topItems
                items = []
                seen = Set(page.topItems.map(\.rpid))
                upperMid = page.upperMid
                inputPlaceholder = page.inputPlaceholder
                inputDisabled = page.inputDisabled
            }
            var fresh: [ReplyItem] = []
            for r in page.items where seen.insert(r.rpid).inserted {
                fresh.append(r)
            }
            items.append(contentsOf: fresh)
            let previousCursor = cursor
            cursor = page.nextCursor
            // A cursor that does not move would return the same page forever.
            hasMore = page.hasMore && (reset || page.nextCursor != previousCursor)
            if page.totalCount > 0 { totalCount = page.totalCount }
            didLoad = true
            // Loading more is driven by rows appearing: a page without new rows would leave the list stuck
            // (no new row, no footer text). Fetch on, a few pages at most.
            emptyPages = fresh.isEmpty ? (reset ? 1 : emptyPages + 1) : 0
            if hasMore && fresh.isEmpty {
                if emptyPages < 3 {
                    Task { await loadMore() }   // runs after `isLoading` is cleared below
                } else {
                    hasMore = false
                }
            }
        } catch {
            guard gen == generation else { return }
            if !videoCommentIsCancellation(error) {
                errorMessage = error.localizedDescription
                didLoad = true
            }
        }
        if gen == generation { isLoading = false }
    }

    // MARK: Mutations

    func updateReply(_ rpid: Int64, _ change: (inout ReplyItem) -> Void) {
        VideoCommentsModel.update(&topItems, rpid: rpid, change)
        VideoCommentsModel.update(&items, rpid: rpid, change)
    }

    static func update(_ list: inout [ReplyItem], rpid: Int64, _ change: (inout ReplyItem) -> Void) {
        for i in list.indices {
            if list[i].rpid == rpid { change(&list[i]) }
            for j in list[i].previewReplies.indices where list[i].previewReplies[j].rpid == rpid {
                change(&list[i].previewReplies[j])
            }
        }
    }

    /// Removes a deleted comment (a root comment, or a sub reply from its root's preview).
    func removeReply(_ rpid: Int64, root: Int64) {
        if root == 0 || root == rpid {
            let before = topItems.count + items.count
            topItems.removeAll { $0.rpid == rpid }
            items.removeAll { $0.rpid == rpid }
            if topItems.count + items.count < before { totalCount = max(0, totalCount - 1) }
        } else {
            updateReply(root) { r in
                guard r.rpid == root else { return }
                r.previewReplies.removeAll { $0.rpid == rpid }
                r.replyCount = max(0, r.replyCount - 1)
                r.replyCountText = r.replyCount > 0 ? "共\(r.replyCount)条回复" : ""
            }
        }
    }

    func subReplyAdded(_ reply: ReplyItem, root: Int64) {
        updateReply(root) { r in
            guard r.rpid == root else { return }
            r.replyCount += 1
            if r.previewReplies.count < 3 { r.previewReplies.append(reply) }
            r.replyCountText = "共\(r.replyCount)条回复"
        }
    }

    func delete(_ item: ReplyItem) async {
        do {
            try await ReplyAPI.delete(oid: oid, type: type, rpid: item.rpid)
            removeReply(item.rpid, root: item.root)
            ToastCenter.shared.show("删除成功")
        } catch {
            ToastCenter.shared.show(error: error)
        }
    }

    /// Posts `text` for `target`; inserts the new comment. Returns false (after a toast) on failure.
    func send(_ text: String, target: VideoCommentComposerTarget) async -> Bool {
        do {
            var reply = try await ReplyAPI.add(oid: oid, type: type, message: target.messagePrefix + text,
                                               root: target.root, parent: target.parent)
            VideoCommentsModel.fillAuthor(&reply, upperMid: upperMid)
            if target.root == 0 {
                if seen.insert(reply.rpid).inserted || reply.rpid == 0 {
                    items.insert(reply, at: 0)
                }
                totalCount += 1
            } else {
                subReplyAdded(reply, root: target.root)
            }
            ToastCenter.shared.show("发送成功")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    /// The add endpoint may return only an rpid; fill the author from the logged-in profile.
    static func fillAuthor(_ reply: inout ReplyItem, upperMid: Int64) {
        if reply.uname.isEmpty, let p = AuthService.shared.profile {
            reply.mid = p.mid
            reply.uname = p.name
            reply.avatar = p.face
            reply.level = p.level
            reply.isVip = p.vipStatus == 1 && p.vipType > 0
            if reply.isVip { reply.vipColorHex = "#FB7299" }
        }
        if upperMid != 0 && reply.mid == upperMid { reply.isUploader = true }
        if reply.ctime == 0 { reply.ctime = Int64(Date().timeIntervalSince1970) }
    }
}

// MARK: - List view

/// The comment list (sort header, pinned items, infinite scroll, sheets). `hostsComposer == false` when an
/// ancestor presents `VideoCommentComposerHost` for the same model (the video detail page does).
struct VideoCommentsListView: View {
    @ObservedObject var model: VideoCommentsModel
    var hostsComposer: Bool = true
    var showsComposerBar: Bool = true
    var onSeek: ((Double) -> Void)? = nil

    @EnvironmentObject private var router: TabRouter
    @State private var viewer: VideoImageViewerItem?
    @State private var pendingDelete: ReplyItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.oid > 0 {
                    sortHeader
                    ForEach(model.topItems) { item in
                        row(item)
                        separator
                    }
                    ForEach(model.items) { item in
                        row(item)
                            .onAppear { model.onItemAppear(item) }
                        separator
                    }
                    ListFooter(isLoading: model.isLoading || !model.didLoad,
                               hasMore: model.hasMore,
                               isEmpty: model.didLoad && model.items.isEmpty && model.topItems.isEmpty,
                               error: model.errorMessage,
                               emptyText: model.inputDisabled ? "评论区已关闭" : "还没有评论，快来抢沙发吧~") {
                        Task { await model.retry() }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
        }
        .pullToRefresh { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .safeAreaInset(edge: .bottom) {
            if showsComposerBar { composerBar }
        }
        .sheet(item: $model.subRepliesRoot) { root in
            subRepliesSheet(root)
        }
        .background(Group {
            if hostsComposer { VideoCommentComposerHost(model: model) }
        })
        .fullScreenCover(item: $viewer) { item in
            VideoImageViewer(item: item)
        }
        .confirmationDialog("确定删除这条评论吗？", isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("删除", role: .destructive) {
                Task { await model.delete(item) }
            }
            Button("取消", role: .cancel) {}
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var separator: some View {
        Divider().padding(.leading, 56)
    }

    private var sortHeader: some View {
        HStack {
            Text(model.sort == .hot ? "热门评论" : "最新评论")
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Button {
                model.setSort(model.sort == .hot ? .time : .hot)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(model.sort.title)
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var composerBar: some View {
        Button {
            openComposer(.init())
        } label: {
            HStack {
                Text(model.inputDisabled ? "评论区已关闭" : "发个友善的评论吧")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.inputDisabled || model.oid == 0)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func row(_ item: ReplyItem) -> some View {
        VideoCommentRow(item: item, showsPreview: true, timestamps: onSeek != nil, actions: actions)
    }

    private var actions: VideoCommentRowActions {
        VideoCommentRowActions(
            like: { item in if requireLogin() { model.toggleLike(item) } },
            dislike: { item in if requireLogin() { model.toggleDislike(item) } },
            reply: { item in openComposer(.reply(to: item)) },
            openReplies: { item in model.subRepliesRoot = item },
            openUser: { mid in if mid > 0 { router.push(.user(mid: mid)) } },
            openImages: { urls, index in viewer = VideoImageViewerItem(urls: urls, index: index) },
            delete: { item in pendingDelete = item }
        )
    }

    private func requireLogin() -> Bool {
        if BiliHTTP.shared.isLoggedIn { return true }
        router.push(.login)
        return false
    }

    private func openComposer(_ target: VideoCommentComposerTarget) {
        guard requireLogin() else { return }
        if model.inputDisabled {
            ToastCenter.shared.show("评论区已关闭")
            return
        }
        model.composerTarget = target
    }

    private func subRepliesSheet(_ root: ReplyItem) -> some View {
        let seek: ((Double) -> Void)? = onSeek == nil ? nil : { t in
            model.subRepliesRoot = nil
            onSeek?(t)
        }
        return VideoCommentSubRepliesSheet(
            root: root, oid: model.oid, type: model.type, parent: model, timestamps: onSeek != nil,
            navigate: { route in
                model.subRepliesRoot = nil
                router.push(route)
            },
            onSeek: seek)
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch VideoRichText.target(for: url) {
        case .seek(let t):
            onSeek?(t)
            return .handled
        case .route(let route):
            router.push(route)
            return .handled
        case .system:
            return .systemAction
        case .ignore:
            return .discarded
        }
    }
}

/// Presents the composer for `model.composerTarget` (attach as a background of an always-visible view).
struct VideoCommentComposerHost: View {
    @ObservedObject var model: VideoCommentsModel

    var body: some View {
        Color.clear
            .sheet(item: $model.composerTarget) { target in
                VideoCommentComposerSheet(target: target) { text in
                    await model.send(text, target: target)
                }
            }
    }
}

// MARK: - Row

struct VideoCommentRowActions {
    var like: (ReplyItem) -> Void = { _ in }
    var dislike: (ReplyItem) -> Void = { _ in }
    var reply: (ReplyItem) -> Void = { _ in }
    var openReplies: (ReplyItem) -> Void = { _ in }
    var openUser: (Int64) -> Void = { _ in }
    var openImages: ([String], Int) -> Void = { _, _ in }
    var delete: (ReplyItem) -> Void = { _ in }
}

/// One comment: avatar, name (VIP pink), level, UP badge, rich content (emotes, links), pictures,
/// time · IP属地, like / dislike / reply, 「UP主觉得很赞」 and the 「共N条回复」 preview box.
struct VideoCommentRow: View {
    let item: ReplyItem
    var compact = false
    var showsPreview = true
    /// Turn "03:25" into seek links (only when a player can seek).
    var timestamps = false
    let actions: VideoCommentRowActions

    @State private var emotes: [String: UIImage] = [:]
    @State private var previewEmotes: [String: UIImage] = [:]

    private var avatarSize: CGFloat { compact ? 28 : 34 }
    private var isOwn: Bool { item.mid != 0 && item.mid == BiliHTTP.shared.mid }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { actions.openUser(item.mid) } label: {
                AvatarView(url: item.avatar, size: avatarSize)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                nameLine
                VideoExpandableText(text: contentText, lineLimit: 6)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .tint(.biliBlue)
                if !item.pictures.isEmpty {
                    VideoCommentPictureGrid(urls: item.pictures) { index in
                        actions.openImages(item.pictures, index)
                    }
                }
                footer
                if item.upLiked {
                    Text("UP主觉得很赞")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                if showsPreview && (!item.previewReplies.isEmpty || item.replyCount > 0) {
                    previewBox
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.message
                ToastCenter.shared.show("已复制")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if isOwn {
                Button(role: .destructive) {
                    actions.delete(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .task(id: item.rpid) {
            await loadEmotes()
        }
    }

    private var nameColor: Color {
        if let hex = item.vipColorHex, let c = VideoCommentRow.color(hex: hex) { return c }
        return item.isVip ? .biliPink : .secondary
    }

    private var nameLine: some View {
        HStack(spacing: 4) {
            Text(item.uname)
                .font(.system(size: 13, weight: item.isVip ? .medium : .regular))
                .foregroundColor(nameColor)
                .lineLimit(1)
            VideoCommentLevelBadge(level: item.level)
            if item.isUploader {
                VideoCommentTag(text: "UP", color: .biliPink)
            }
            if let medal = item.memberLabel, !compact {
                Text(medal)
                    .font(.system(size: 9))
                    .foregroundColor(.biliBlue)
                    .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.biliBlue.opacity(0.6), lineWidth: 0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var contentText: Text {
        let message = VideoRichText.text(VideoRichText.segments(for: item, timestamps: timestamps), emotes: emotes)
        guard item.isUpTop else { return message }
        return Text("置顶 ").font(.system(size: 13, weight: .medium)).foregroundColor(.biliPink) + message
    }

    private var timeLine: String {
        var parts: [String] = []
        let time = item.timeDesc.isEmpty ? Fmt.relativeDate(item.ctime) : item.timeDesc
        if !time.isEmpty { parts.append(time) }
        if !item.location.isEmpty { parts.append(item.location) }
        return parts.joined(separator: "  ")
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(timeLine)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { actions.like(item) } label: {
                HStack(spacing: 3) {
                    Image(systemName: item.userLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    if item.likeCount > 0 { Text(Fmt.count(item.likeCount)) }
                }
                .foregroundColor(item.userLiked ? .biliPink : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            Button { actions.dislike(item) } label: {
                Image(systemName: item.userDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundColor(item.userDisliked ? .biliPink : .secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            Button { actions.reply(item) } label: {
                Image(systemName: "bubble.left")
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
    }

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(item.previewReplies.prefix(3)) { reply in
                previewLine(reply)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.replyCount > 0 {
                HStack(spacing: 2) {
                    Text(item.replyCountText.isEmpty ? "共\(item.replyCount)条回复" : item.replyCountText)
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12))
                .foregroundColor(.biliBlue)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { actions.openReplies(item) }
    }

    private func previewLine(_ reply: ReplyItem) -> Text {
        var head = Text(reply.uname).foregroundColor(.biliBlue)
        if reply.isUploader {
            head = head + Text(" UP").font(.system(size: 10, weight: .bold)).foregroundColor(.biliPink)
        }
        return head + Text("：") + VideoRichText.text(VideoRichText.segments(for: reply, timestamps: false), emotes: previewEmotes)
    }

    private func loadEmotes() async {
        let main = await VideoEmoteImages.load(item.emotes, height: 20, large: item.largeEmotes, largeHeight: 36)
        var previewMap: [String: String] = [:]
        if showsPreview {
            for reply in item.previewReplies.prefix(3) {
                previewMap.merge(reply.emotes) { current, _ in current }
            }
        }
        let previews = await VideoEmoteImages.load(previewMap, height: 18)
        guard !Task.isCancelled, !(main.isEmpty && previews.isEmpty) else { return }
        emotes = main
        previewEmotes = previews
    }

    /// "#FB7299" → Color.
    static func color(hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// 「LV6」 badge in the official level colours.
struct VideoCommentLevelBadge: View {
    let level: Int

    private var color: Color {
        switch level {
        case 2: return Color(red: 0.58, green: 0.85, blue: 0.62)
        case 3: return Color(red: 0.49, green: 0.75, blue: 0.93)
        case 4: return Color(red: 1.0, green: 0.73, blue: 0.29)
        case 5: return Color(red: 1.0, green: 0.48, blue: 0.13)
        case 6...: return Color(red: 0.96, green: 0.25, blue: 0.25)
        default: return Color(.systemGray3)
        }
    }

    var body: some View {
        Text("LV\(max(0, level))")
            .font(.system(size: 8, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 2))
    }
}

struct VideoCommentTag: View {
    let text: String
    var color: Color = .biliPink

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 2))
    }
}

/// Comment pictures: one large thumbnail, or a 2 / 3-column grid of square crops.
struct VideoCommentPictureGrid: View {
    let urls: [String]
    let onTap: (Int) -> Void

    var body: some View {
        if urls.count == 1 {
            RemoteImage(url: urls[0], width: 180)
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { onTap(0) }
        } else {
            let columns = urls.count == 2 || urls.count == 4 ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
                      alignment: .leading, spacing: 4) {
                ForEach(urls.indices, id: \.self) { i in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(RemoteImage(url: urls[i], width: 120))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(i) }
                }
            }
            .frame(maxWidth: columns == 2 ? 220 : 320, alignment: .leading)
        }
    }
}

// MARK: - Sub replies

@MainActor
final class VideoCommentSubRepliesModel: ObservableObject, VideoCommentMutating {
    let oid: Int64
    let type: Int

    @Published private(set) var root: ReplyItem
    @Published private(set) var items: [ReplyItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalCount: Int
    @Published var composerTarget: VideoCommentComposerTarget?

    private var nextPage = 1
    private var upperMid: Int64 = 0
    private var generation = 0
    private weak var parentModel: VideoCommentsModel?

    init(root: ReplyItem, oid: Int64, type: Int, parent: VideoCommentsModel?) {
        self.root = root
        self.oid = oid
        self.type = type
        self.parentModel = parent
        self.totalCount = root.replyCount
        self.upperMid = parent?.upperMid ?? 0
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard didLoad, hasMore, !isLoading else { return }
        await load(reset: false)
    }

    func retry() async {
        if didLoad && !items.isEmpty {
            errorMessage = nil
            await loadMore()
        } else {
            await refresh()
        }
    }

    func onItemAppear(_ item: ReplyItem) {
        guard didLoad, hasMore, !isLoading else { return }
        if items.suffix(5).contains(where: { $0.rpid == item.rpid }) {
            Task { await loadMore() }
        }
    }

    private func load(reset: Bool) async {
        if reset { generation += 1 }
        let gen = generation
        isLoading = true
        errorMessage = nil
        do {
            // `nextPage` changes only with a response: a failed refresh must not rewind it under the loaded pages.
            let requested = reset ? 1 : nextPage
            let page = try await ReplyAPI.subReplies(oid: oid, type: type, root: root.rpid, page: requested)
            guard gen == generation else { return }
            if reset { items = [] }
            if page.upperMid != 0 { upperMid = page.upperMid }
            if var fresh = page.root {
                fresh.previewReplies = []
                root = fresh
            }
            let known = Set(items.map(\.rpid))
            items.append(contentsOf: page.items.filter { !known.contains($0.rpid) })
            hasMore = page.hasMore
            nextPage = page.nextCursor.flatMap({ Int($0) }) ?? requested + 1
            if page.totalCount > 0 { totalCount = page.totalCount }
            didLoad = true
        } catch {
            guard gen == generation else { return }
            if !videoCommentIsCancellation(error) {
                errorMessage = error.localizedDescription
                didLoad = true
            }
        }
        if gen == generation { isLoading = false }
    }

    func updateReply(_ rpid: Int64, _ change: (inout ReplyItem) -> Void) {
        if root.rpid == rpid { change(&root) }
        VideoCommentsModel.update(&items, rpid: rpid, change)
        parentModel?.updateReply(rpid, change)
    }

    /// Returns true when the root comment itself was deleted (the sheet should close).
    func delete(_ item: ReplyItem) async -> Bool {
        do {
            try await ReplyAPI.delete(oid: oid, type: type, rpid: item.rpid)
            ToastCenter.shared.show("删除成功")
            if item.rpid == root.rpid {
                parentModel?.removeReply(item.rpid, root: 0)
                return true
            }
            items.removeAll { $0.rpid == item.rpid }
            totalCount = max(0, totalCount - 1)
            root.replyCount = max(0, root.replyCount - 1)
            parentModel?.removeReply(item.rpid, root: root.rpid)
            return false
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    func send(_ text: String, target: VideoCommentComposerTarget) async -> Bool {
        do {
            var reply = try await ReplyAPI.add(oid: oid, type: type, message: target.messagePrefix + text,
                                               root: target.root, parent: target.parent)
            VideoCommentsModel.fillAuthor(&reply, upperMid: upperMid)
            if reply.root == 0 { reply.root = root.rpid }
            items.insert(reply, at: 0)
            totalCount += 1
            root.replyCount += 1
            parentModel?.subReplyAdded(reply, root: root.rpid)
            ToastCenter.shared.show("发送成功")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }
}

/// 「评论详情」 sheet: the root comment and its paged replies (楼中楼), with its own composer.
struct VideoCommentSubRepliesSheet: View {
    @StateObject private var model: VideoCommentSubRepliesModel
    private let timestamps: Bool
    private let navigate: (Route) -> Void
    private let onSeek: ((Double) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var viewer: VideoImageViewerItem?
    @State private var pendingDelete: ReplyItem?

    init(root: ReplyItem, oid: Int64, type: Int, parent: VideoCommentsModel?, timestamps: Bool,
         navigate: @escaping (Route) -> Void, onSeek: ((Double) -> Void)?) {
        _model = StateObject(wrappedValue: VideoCommentSubRepliesModel(root: root, oid: oid, type: type, parent: parent))
        self.timestamps = timestamps
        self.navigate = navigate
        self.onSeek = onSeek
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VideoCommentRow(item: model.root, showsPreview: false, timestamps: timestamps, actions: actions)
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(height: 8)
                    Text("相关回复共\(model.totalCount)条")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    ForEach(model.items) { reply in
                        VideoCommentRow(item: reply, compact: true, showsPreview: false, timestamps: timestamps, actions: actions)
                            .onAppear { model.onItemAppear(reply) }
                        Divider().padding(.leading, 50)
                    }
                    ListFooter(isLoading: model.isLoading || !model.didLoad,
                               hasMore: model.hasMore,
                               isEmpty: model.didLoad && model.items.isEmpty,
                               error: model.errorMessage,
                               emptyText: "暂无回复") {
                        Task { await model.retry() }
                    }
                }
            }
            .pullToRefresh { await model.refresh() }
            .task { await model.loadIfNeeded() }
            .safeAreaInset(edge: .bottom) { replyBar }
            .navigationTitle("评论详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .environment(\.openURL, OpenURLAction { url in handle(url) })
            .sheet(item: $model.composerTarget) { target in
                VideoCommentComposerSheet(target: target) { text in
                    await model.send(text, target: target)
                }
            }
            .fullScreenCover(item: $viewer) { item in
                VideoImageViewer(item: item)
            }
            .confirmationDialog("确定删除这条评论吗？", isPresented: deleteBinding, titleVisibility: .visible,
                                presenting: pendingDelete) { item in
                Button("删除", role: .destructive) {
                    Task {
                        if await model.delete(item) { dismiss() }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var replyBar: some View {
        Button {
            openComposer(.reply(to: model.root))
        } label: {
            HStack {
                Text("回复 @\(model.root.uname)：")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var actions: VideoCommentRowActions {
        VideoCommentRowActions(
            like: { item in if requireLogin() { model.toggleLike(item) } },
            dislike: { item in if requireLogin() { model.toggleDislike(item) } },
            reply: { item in openComposer(.reply(to: item)) },
            openReplies: { _ in },
            openUser: { mid in if mid > 0 { navigate(.user(mid: mid)) } },
            openImages: { urls, index in viewer = VideoImageViewerItem(urls: urls, index: index) },
            delete: { item in pendingDelete = item }
        )
    }

    private func requireLogin() -> Bool {
        if BiliHTTP.shared.isLoggedIn { return true }
        navigate(.login)
        return false
    }

    private func openComposer(_ target: VideoCommentComposerTarget) {
        guard requireLogin() else { return }
        model.composerTarget = target
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch VideoRichText.target(for: url) {
        case .seek(let t):
            if let onSeek { onSeek(t) } else { return .discarded }
            return .handled
        case .route(let route):
            navigate(route)
            return .handled
        case .system:
            return .systemAction
        case .ignore:
            return .discarded
        }
    }
}

// MARK: - Composer

/// 「发表评论」 sheet. `onSend` performs the request and returns whether it succeeded (the sheet then closes).
struct VideoCommentComposerSheet: View {
    static let maxLength = 1000

    let target: VideoCommentComposerTarget
    let onSend: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .focused($focused)
                        .font(.system(size: 15))
                        .frame(minHeight: 120)
                    if text.isEmpty {
                        Text(target.placeholder)
                            .font(.system(size: 15))
                            .foregroundColor(Color(.placeholderText))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                HStack {
                    Spacer()
                    Text("\(text.count)/\(VideoCommentComposerSheet.maxLength)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(text.count > VideoCommentComposerSheet.maxLength ? .red : .secondary)
                }
            }
            .padding(12)
            .navigationTitle(target.replyToName.isEmpty ? "发表评论" : "回复评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("发布") { send() }
                            .disabled(trimmed.isEmpty || text.count > VideoCommentComposerSheet.maxLength)
                    }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(sending)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
    }

    private func send() {
        let message = trimmed
        guard !message.isEmpty, !sending else { return }
        sending = true
        Task { @MainActor in
            let ok = await onSend(message)
            sending = false
            if ok { dismiss() }
        }
    }
}
