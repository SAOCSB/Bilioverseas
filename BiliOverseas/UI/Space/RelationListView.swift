import SwiftUI

/// 关注列表 / 粉丝列表 of a user. On the signed-in user's own lists each row gets a follow toggle
/// (已关注 ↔ 关注 on 我的关注, 回关 / 已互粉 on 我的粉丝).
struct RelationListView: View {
    let mid: Int64
    let kind: RelationKind

    @StateObject private var list: PagedListModel<UserBrief>
    @ObservedObject private var auth = AuthService.shared
    /// mid → followed, after a toggle on this screen.
    @State private var overrides: [Int64: Bool] = [:]
    @State private var pending: Set<Int64> = []
    @State private var unfollowTarget: UserBrief?

    init(mid: Int64, kind: RelationKind) {
        self.mid = mid
        self.kind = kind
        _list = StateObject(wrappedValue: PagedListModel<UserBrief>(fetch: { cursor in
            let page = ListCursor.page(cursor)
            do {
                switch kind {
                case .following: return try await SpaceAPI.followings(mid: mid, page: page)
                case .fans: return try await SpaceAPI.fans(mid: mid, page: page)
                }
            } catch BiliError.api(let code, _) where code == 22007 && page > 1 {
                // Other users' lists stop after 5 pages (「访问超过5页」) although `total` says more:
                // that is the end of the list, not an error with a 重试 that can never succeed.
                return .empty
            }
        }))
    }

    private var isOwn: Bool { auth.isLoggedIn && auth.mid == mid }

    private var title: String {
        switch kind {
        case .following: return isOwn ? "我的关注" : "TA的关注"
        case .fans: return isOwn ? "我的粉丝" : "TA的粉丝"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list.items) { user in
                    row(user)
                        .onAppear { list.onItemAppear(user) }
                    Divider().padding(.leading, 68)
                }
                ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                           error: list.errorMessage,
                           emptyText: kind == .following ? "还没有关注任何人" : "还没有粉丝") {
                    Task {
                        if list.isEmpty { await list.refresh() } else { await list.loadMore() }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .pullToRefresh {
            overrides = [:]
            await list.refresh()
        }
        .task { await list.loadIfNeeded() }
        .confirmationDialog("确定不再关注TA吗？", isPresented: Binding(
            get: { unfollowTarget != nil },
            set: { if !$0 { unfollowTarget = nil } }
        ), titleVisibility: .visible, presenting: unfollowTarget) { user in
            Button("不再关注", role: .destructive) { setFollow(user, followed: false) }
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ user: UserBrief) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.user(mid: user.mid)) {
                HStack(spacing: 12) {
                    AvatarView(url: user.face, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name.isEmpty ? "UID:\(user.mid)" : user.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(user.vipLabel.isEmpty ? .primary : .biliPink)
                            .lineLimit(1)
                        Text(user.sign.isEmpty ? "这个人很神秘，什么都没有写" : user.sign)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOwn {
                followButton(user)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func isFollowed(_ user: UserBrief) -> Bool {
        overrides[user.mid] ?? user.isFollowed
    }

    @ViewBuilder
    private func followButton(_ user: UserBrief) -> some View {
        let followed = isFollowed(user)
        let busy = pending.contains(user.mid)
        Button {
            if followed {
                unfollowTarget = user
            } else {
                setFollow(user, followed: true)
            }
        } label: {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else if followed {
                    Text(kind == .fans ? "已互粉" : "已关注")
                } else {
                    Text(kind == .fans ? "回关" : "+ 关注")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundColor(followed ? .secondary : .biliPink)
            .frame(width: 64, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(followed ? Color(.separator) : Color.biliPink, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func setFollow(_ user: UserBrief, followed: Bool) {
        let target = user.mid
        guard !pending.contains(target) else { return }
        pending.insert(target)
        Task {
            do {
                if followed {
                    try await SpaceAPI.follow(mid: target)
                } else {
                    try await SpaceAPI.unfollow(mid: target)
                }
                overrides[target] = followed
                ToastCenter.shared.show(followed ? "关注成功" : "已取消关注")
            } catch {
                if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            }
            pending.remove(target)
        }
    }
}
