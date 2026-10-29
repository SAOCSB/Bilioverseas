import SwiftUI

/// 回复我的 / @我的 / 收到的赞 / 系统通知 as one paged list. Tapping a row opens its comment thread (评论详情)
/// or the related video / dynamic; the thumbnail opens the related content; 回复 and 点赞 act on their comment.
struct MessageFeedView: View {
    let kind: MessageFeedKind

    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var auth = AuthService.shared
    @StateObject private var list: PagedListModel<MessageFeedItem>
    @State private var thread: MessageThreadSheetItem?
    @State private var composer: MessageReplyComposerItem?
    /// Row id → liked, after a 点赞 toggle on this screen.
    @State private var likeOverrides: [String: Bool] = [:]
    @State private var pendingLikes: Set<String> = []
    @State private var markedSystemRead = false

    init(kind: MessageFeedKind) {
        self.kind = kind
        _list = StateObject(wrappedValue: PagedListModel<MessageFeedItem> { cursor in
            try await MessageAPI.feed(kind, cursor: cursor)
        })
    }

    var body: some View {
        Group {
            if auth.isLoggedIn {
                content
            } else {
                LoginRequiredView(message: "登录后查看消息")
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        // Login / logout / 切换账号: the rows shown belong to the previous account.
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            likeOverrides = [:]
            markedSystemRead = false
            list.replace([])
            if auth.isLoggedIn { Task { await list.refresh() } }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list.items) { item in
                    row(item)
                        .onAppear { list.onItemAppear(item) }
                    Divider().padding(.leading, kind == .system ? 16 : 64)
                }
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage, emptyText: emptyText) {
                    Task {
                        if list.isEmpty { await list.refresh() } else { await list.loadMore() }
                    }
                }
            }
        }
        .refreshable {
            likeOverrides = [:]
            await list.refresh()
        }
        .task {
            MessageUnreadStore.shared.clear(kind)
            await list.loadIfNeeded()
            if kind == .system, !markedSystemRead, let newest = list.items.first?.cursor, newest > 0 {
                markedSystemRead = true
                await MessageAPI.markSystemRead(cursor: newest)
            }
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .messageThreadSheet($thread, router: router)
        .sheet(item: $composer) { item in
            VideoCommentComposerSheet(target: item.target) { text in
                await sendReply(text, item)
            }
        }
    }

    private var emptyText: String {
        switch kind {
        case .reply: return "还没有人回复你"
        case .at: return "还没有人@你"
        case .like: return "还没有收到赞"
        case .system: return "暂无系统通知"
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: MessageFeedItem) -> some View {
        switch kind {
        case .reply, .at: replyRow(item)
        case .like: likeRow(item)
        case .system: systemRow(item)
        }
    }

    private func replyRow(_ item: MessageFeedItem) -> some View {
        let user = item.users.first
        return HStack(alignment: .top, spacing: 12) {
            avatar(user)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(user?.name ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if item.isMulti {
                        Text("等人")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.content.isEmpty {
                    Text(item.content)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                }
                if let quote = quote(item) {
                    Text(quote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(.separator)).frame(width: 2)
                        }
                }
                if item.thread != nil, item.sourceRpid > 0 {
                    commentActions(item)
                }
            }
            Spacer(minLength: 0)
            subject(item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    private func likeRow(_ item: MessageFeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            likeAvatars(item.users)
            VStack(alignment: .leading, spacing: 5) {
                Text(likeNames(item))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            subject(item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    private func systemRow(_ item: MessageFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title.isEmpty ? "系统通知" : item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(timeText(item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Self.systemText(item.content)
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.85))
                .tint(.biliBlue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 系统通知 text with `#{文字}{"url"}` and bare URLs as tappable links (handled by `handle(_:)`).
    static func systemText(_ content: String) -> Text {
        var out = AttributedString()
        for segment in MessageLinks.systemSegments(content) {
            var part = AttributedString(segment.text)
            if let url = segment.url { part.link = url }
            out.append(part)
        }
        return Text(out)
    }

    // MARK: Pieces

    private func avatar(_ user: UserBrief?) -> some View {
        Button {
            if let mid = user?.mid, mid > 0 { router.push(.user(mid: mid)) }
        } label: {
            AvatarView(url: user?.face ?? "", size: 40)
        }
        .buttonStyle(.plain)
    }

    /// One avatar, or the first two overlapping when several people liked it.
    private func likeAvatars(_ users: [UserBrief]) -> some View {
        ZStack(alignment: .topLeading) {
            if users.count > 1 {
                AvatarView(url: users[1].face, size: 30)
                    .offset(x: 12, y: 12)
                AvatarView(url: users[0].face, size: 30)
            } else {
                avatar(users.first)
            }
        }
        .frame(width: 42, height: 42, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let mid = users.first?.mid, mid > 0 { router.push(.user(mid: mid)) }
        }
    }

    /// Cover of the related video / dynamic, or its title in a grey box; opens it.
    @ViewBuilder
    private func subject(_ item: MessageFeedItem) -> some View {
        let label = item.title.isEmpty ? item.targetText : item.title
        if !item.image.isEmpty || !label.isEmpty {
            Button {
                if let link = item.link { open(link) } else { open(item) }
            } label: {
                Group {
                    if !item.image.isEmpty {
                        RemoteImage(url: item.image, width: 52)
                    } else {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }

    private func commentActions(_ item: MessageFeedItem) -> some View {
        let liked = likeOverrides[item.id] ?? item.liked
        return HStack(spacing: 18) {
            Button {
                reply(item)
            } label: {
                Label("回复", systemImage: "bubble.left")
            }
            Button {
                toggleLike(item)
            } label: {
                Label("点赞", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(liked ? Color.biliPink : Color.secondary)
            }
            .disabled(pendingLikes.contains(item.id))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: Text

    private func timeText(_ item: MessageFeedItem) -> String {
        item.time > 0 ? Fmt.relativeDate(item.time) : item.timeText
    }

    private func subtitle(_ item: MessageFeedItem) -> String {
        let action = actionText(item)
        let time = timeText(item)
        return time.isEmpty ? action : "\(action) · \(time)"
    }

    private func actionText(_ item: MessageFeedItem) -> String {
        let business = item.business
        switch kind {
        case .reply:
            if item.count > 1 { return "对我的\(business.isEmpty ? "内容" : business)发布了\(item.count)条评论" }
            if business == "评论" { return "回复了我的评论" }
            return business.isEmpty ? "回复了我" : "评论了我的\(business)"
        case .at:
            return business.isEmpty ? "@了我" : "在\(business)中@了我"
        case .like:
            return "赞了我的\(business.isEmpty ? "内容" : business)"
        case .system:
            return ""
        }
    }

    /// My comment they replied to, else the root of the thread.
    private func quote(_ item: MessageFeedItem) -> String? {
        if !item.targetText.isEmpty { return item.targetText }
        if !item.rootText.isEmpty { return item.rootText }
        return nil
    }

    private func likeNames(_ item: MessageFeedItem) -> String {
        let names = item.users.prefix(2).map(\.name).filter { !$0.isEmpty }
        let total = max(item.count, item.users.count)
        let joined = names.joined(separator: "、")
        return total > names.count && total > 1 ? "\(joined) 等\(total)人" : joined
    }

    // MARK: Actions

    private func open(_ item: MessageFeedItem) {
        if let t = item.thread {
            thread = MessageThreadSheetItem(thread: t, root: rootPreview(item, thread: t))
        } else if let link = item.link {
            open(link)
        }
    }

    private func open(_ link: MessageLink) {
        if case .comments(let t) = link {
            thread = MessageThreadSheetItem(thread: t)
        } else if let route = MessageRoutes.route(for: link) {
            router.push(route)
        }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard let link = MessageLinks.resolve(url.absoluteString) else { return .systemAction }
        open(link)
        return .handled
    }

    /// What is known about the root comment before the thread loads: their comment when it is the root,
    /// else the root / my replied-to comment text.
    private func rootPreview(_ item: MessageFeedItem, thread t: MessageCommentThread) -> ReplyItem? {
        guard kind == .reply || kind == .at else { return nil }
        var r = ReplyItem()
        if item.sourceRpid == t.root, let user = item.users.first {
            r.mid = user.mid
            r.uname = user.name
            r.avatar = user.face
            r.message = item.content
            r.ctime = item.time
        } else if !item.rootText.isEmpty {
            r.message = item.rootText
        } else if !item.targetText.isEmpty, let me = auth.profile {
            // Without a separate root text the comment they answered (mine) is the root.
            r.mid = me.mid
            r.uname = me.name
            r.avatar = me.face
            r.message = item.targetText
        }
        return r
    }

    private func reply(_ item: MessageFeedItem) {
        guard let t = item.thread, item.sourceRpid > 0 else { return }
        var source = ReplyItem()
        source.rpid = item.sourceRpid
        source.root = item.sourceRoot
        source.oid = t.oid
        source.type = t.type
        source.uname = item.users.first?.name ?? ""
        composer = MessageReplyComposerItem(item: item, target: .reply(to: source))
    }

    private func sendReply(_ text: String, _ c: MessageReplyComposerItem) async -> Bool {
        guard let t = c.item.thread else { return false }
        do {
            _ = try await ReplyAPI.add(oid: t.oid, type: t.type, message: c.target.messagePrefix + text,
                                       root: c.target.root, parent: c.target.parent)
            ToastCenter.shared.show("回复成功")
            return true
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            return false
        }
    }

    private func toggleLike(_ item: MessageFeedItem) {
        guard let t = item.thread, item.sourceRpid > 0, !pendingLikes.contains(item.id) else { return }
        let target = !(likeOverrides[item.id] ?? item.liked)
        likeOverrides[item.id] = target
        pendingLikes.insert(item.id)
        Task {
            do {
                try await ReplyAPI.like(oid: t.oid, type: t.type, rpid: item.sourceRpid, like: target)
            } catch {
                likeOverrides[item.id] = !target
                if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            }
            pendingLikes.remove(item.id)
        }
    }
}

/// The 回复 composer opened from a 回复我的 / @我的 row.
struct MessageReplyComposerItem: Identifiable {
    let id = UUID()
    let item: MessageFeedItem
    let target: VideoCommentComposerTarget
}
