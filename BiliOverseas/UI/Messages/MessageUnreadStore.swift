import SwiftUI
import UIKit

// Shared pieces of 消息中心: the unread store behind the 首页 bell, the bell itself, the count badge,
// message link → route mapping and the 评论详情 sheet used by the feeds and conversations.

// MARK: - Unread store

/// Unread counters shared by the 首页 bell and 消息中心. Refreshes are throttled; screens that clear a
/// counter (opening a feed, opening a conversation) update it locally right away.
@MainActor
final class MessageUnreadStore: ObservableObject {
    static let shared = MessageUnreadStore()

    @Published private(set) var counts = MessageUnread()
    /// Conversations opened since the session list last loaded (their rows show no unread count).
    @Published private(set) var readTalkers: Set<Int64> = []

    private var lastFetch: Date?
    private var fetching = false
    /// Bumped by local changes so a response that was already in flight cannot bring cleared counts back.
    private var generation = 0

    /// Re-fetches the counters, at most every 30 s unless `force`. Logged out: clears them.
    func refresh(force: Bool = false) async {
        guard AuthService.shared.isLoggedIn else {
            reset()
            return
        }
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 30 { return }
        guard !fetching else { return }
        fetching = true
        lastFetch = Date()
        let gen = generation
        do {
            let fresh = try await MessageAPI.unread()
            if gen == generation, AuthService.shared.isLoggedIn { counts = fresh }
        } catch {
            // Keep the last counts; the next refresh retries.
            lastFetch = nil
        }
        fetching = false
    }

    /// A feed was opened: the server clears its counter as it is read.
    func clear(_ kind: MessageFeedKind) {
        guard counts.count(for: kind) > 0 else { return }
        generation += 1
        counts.clear(kind)
    }

    /// A conversation was opened from the session list.
    func markConversationRead(_ talkerId: Int64, unread: Int) {
        readTalkers.insert(talkerId)
        guard unread > 0 else { return }
        generation += 1
        counts.whisper = max(0, counts.whisper - unread)
    }

    /// The session list reloaded, so its own unread counts are current again.
    func sessionsReloaded() {
        readTalkers = []
    }

    func reset() {
        generation += 1
        counts = MessageUnread()
        readTalkers = []
        lastFetch = nil
    }
}

// MARK: - 首页 bell

/// 「消息」 bell on the right of the 首页 top bar, with the total unread count. Pushes 消息中心, which asks
/// logged-out users to log in.
struct HomeMessageBell: View {
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var store = MessageUnreadStore.shared

    private var unread: Int { auth.isLoggedIn ? store.counts.total : 0 }

    var body: some View {
        Button {
            router.push(.messages)
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 19))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    MessageBadge(count: unread)
                        .offset(x: 7, y: -3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: unread > 0 ? "消息，\(unread)条未读" : "消息"))
        .task(id: auth.isLoggedIn) { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}

// MARK: - Badge

/// Pink unread capsule (「99+」 above 99); nothing when `count` is 0. `dot` shows a plain dot (免打扰).
struct MessageBadge: View {
    let count: Int
    var dot = false

    var body: some View {
        if count > 0 {
            if dot {
                Circle()
                    .fill(Color.biliPink)
                    .frame(width: 8, height: 8)
            } else if let text = MessageUnread.badgeText(count) {
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.biliPink, in: Capsule())
                    .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 1))
            }
        }
    }
}

// MARK: - Links

enum MessageRoutes {
    /// Screen for a message link. Dynamics and articles open their web pages (no native detail screen);
    /// comment threads are shown as a sheet instead (nil here).
    static func route(for link: MessageLink) -> Route? {
        switch link {
        case .video(let aid, let bvid):
            return .video(VideoRef(aid: aid, bvid: bvid))
        case .bangumi(let epId, let seasonId):
            return .video(VideoRef(epId: epId, seasonId: seasonId))
        case .dynamic(let id):
            return URL(string: "https://t.bilibili.com/\(id)").map { .web($0) }
        case .user(let mid):
            return .user(mid: mid)
        case .live(let roomId):
            return .live(roomId: roomId)
        case .article(let id):
            return URL(string: "https://www.bilibili.com/read/cv\(id)").map { .web($0) }
        case .comments:
            return nil
        case .web(let url):
            return .web(url)
        }
    }
}

// MARK: - 评论详情 sheet

/// A comment thread to show. `root` pre-fills the first row until the thread loads (it is replaced then).
struct MessageThreadSheetItem: Identifiable {
    let id = UUID()
    let thread: MessageCommentThread
    let root: ReplyItem

    init(thread: MessageCommentThread, root: ReplyItem? = nil) {
        self.thread = thread
        var r = root ?? ReplyItem()
        r.rpid = thread.root
        r.oid = thread.oid
        r.type = thread.type
        self.root = r
    }
}

extension View {
    /// Presents 评论详情 for `item`; links inside close the sheet and push on `router`.
    func messageThreadSheet(_ item: Binding<MessageThreadSheetItem?>, router: TabRouter) -> some View {
        sheet(item: item) { sheet in
            VideoCommentSubRepliesSheet(
                root: sheet.root, oid: sheet.thread.oid, type: sheet.thread.type, parent: nil, timestamps: false,
                navigate: { route in
                    item.wrappedValue = nil
                    router.push(route)
                },
                onSeek: nil)
        }
    }
}
