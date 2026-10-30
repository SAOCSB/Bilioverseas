import SwiftUI

/// 消息中心 (the 首页 bell): 回复我的 / @我的 / 收到的赞 / 系统通知 entries with their unread counts, then the
/// 私信 session list (pinned first). Logged out it shows the login prompt.
struct MessagesView: View {
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var store = MessageUnreadStore.shared
    @StateObject private var sessions = PagedListModel<WhisperSession> { cursor in
        try await MessageAPI.sessions(cursor: cursor)
    }
    /// A conversation was opened: reload the sessions when coming back (new previews, read state).
    @State private var reloadOnReturn = false

    var body: some View {
        Group {
            if auth.isLoggedIn {
                content
            } else {
                LoginRequiredView(message: "登录后查看消息")
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        // Login / logout / 切换账号: the sessions shown belong to the previous account.
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            reloadOnReturn = false
            sessions.replace([])
            if auth.isLoggedIn { Task { await reloadSessions() } }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                entries
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 8)
                HStack {
                    Text("私信")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                ForEach(sessions.items) { session in
                    sessionRow(session)
                        .onAppear { sessions.onItemAppear(session) }
                    Divider().padding(.leading, 76)
                }
                ListFooter(isLoading: sessions.isLoading, hasMore: sessions.hasMore, isEmpty: sessions.isEmpty,
                           error: sessions.errorMessage, emptyText: "暂无私信") {
                    Task {
                        if sessions.isEmpty { await reloadSessions() } else { await sessions.loadMore() }
                    }
                }
            }
        }
        .pullToRefresh {
            async let counts: Void = store.refresh(force: true)
            await reloadSessions()
            await counts
        }
        .task { await store.refresh(force: true) }
        .task {
            if reloadOnReturn {
                reloadOnReturn = false
                await reloadSessions()
            } else {
                await sessions.loadIfNeeded()
            }
        }
    }

    private func reloadSessions() async {
        await sessions.refresh()
        if sessions.errorMessage == nil { store.sessionsReloaded() }
    }

    // MARK: Feed entries

    private var entries: some View {
        HStack(spacing: 0) {
            ForEach(MessageFeedKind.allCases) { kind in
                Button {
                    router.push(.messageFeed(kind))
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: Self.icon(kind))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Self.tint(kind), in: Circle())
                            .overlay(alignment: .topTrailing) {
                                MessageBadge(count: store.counts.count(for: kind))
                                    .offset(x: 6, y: -3)
                            }
                        Text(kind.title)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
    }

    static func icon(_ kind: MessageFeedKind) -> String {
        switch kind {
        case .reply: return "text.bubble.fill"
        case .at: return "at"
        case .like: return "hand.thumbsup.fill"
        case .system: return "bell.fill"
        }
    }

    static func tint(_ kind: MessageFeedKind) -> Color {
        switch kind {
        case .reply: return .biliBlue
        case .at: return Color(red: 0.35, green: 0.55, blue: 0.95)
        case .like: return .biliPink
        case .system: return .orange
        }
    }

    // MARK: Sessions

    private func sessionRow(_ session: WhisperSession) -> some View {
        let unread = store.readTalkers.contains(session.talkerId) ? 0 : session.unreadCount
        return Button {
            store.markConversationRead(session.talkerId, unread: session.isMuted ? 0 : unread)
            reloadOnReturn = true
            router.push(.whisper(session.peer))
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: session.face, size: 48)
                    .overlay(alignment: .topTrailing) {
                        MessageBadge(count: unread, dot: session.isMuted)
                            .offset(x: 4, y: -2)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.name.isEmpty ? "UID:\(session.talkerId)" : session.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if session.isSystem {
                            MessageTag(text: "官方")
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.relativeDate(session.lastTime))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        Text(session.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if session.isMuted {
                            Image(systemName: "bell.slash")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small outlined label (「官方」, 「UP主」 …).
struct MessageTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.biliBlue)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliBlue, lineWidth: 0.6))
    }
}
