import SwiftUI
import UIKit

/// 个人空间: banner, avatar, name / level / VIP / 认证, sign, 粉丝 · 关注 · 获赞, 关注 button,
/// and the 投稿 | 动态 tabs. The ⋯ menu also links to TA的收藏.
struct UserSpaceView: View {
    let mid: Int64
    @StateObject private var model: UserSpaceModel
    @State private var tab: UserSpaceTab
    @EnvironmentObject private var router: TabRouter

    init(mid: Int64, initialTab: UserSpaceTab = .videos) {
        self.mid = mid
        _model = StateObject(wrappedValue: UserSpaceModel(mid: mid))
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                UserSpaceHeader(model: model)
                Section {
                    switch tab {
                    case .videos:
                        UserSpaceVideosSection(model: model, list: model.videos)
                    case .dynamics:
                        UserSpaceDynamicsSection(list: model.dynamics)
                    }
                } header: {
                    UserSpaceTabBar(tab: $tab, archiveCount: model.info?.archiveCount ?? 0)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.info?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        router.push(.favorites(mid: mid))
                    } label: {
                        Label(model.isSelf ? "我的收藏" : "TA的收藏", systemImage: "star")
                    }
                    Button {
                        UIPasteboard.general.string = String(mid)
                        ToastCenter.shared.show("已复制UID")
                    } label: {
                        Label("复制UID", systemImage: "number")
                    }
                    if let url = URL(string: "https://space.bilibili.com/\(mid)") {
                        ShareLink(item: url) {
                            Label("分享主页", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh(tab: tab) }
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            // 关注 while logged out pushes 登录; back here the relation (已关注 or not) must be the
            // new account's, or 关注 fails with 「已经关注用户」 / 取消关注 is offered wrongly.
            Task { await model.loadInfo() }
        }
    }
}

enum UserSpaceTab: Int, CaseIterable, Identifiable {
    case videos, dynamics
    var id: Int { rawValue }
}

// MARK: - Model

/// Thread-safe snapshot of the 投稿 list's order / keyword (read by the fetch closure).
final class SpaceVideoQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var order: SpaceVideoOrder = .pubdate
    private var keyword = ""

    func set(order: SpaceVideoOrder, keyword: String) {
        lock.lock()
        self.order = order
        self.keyword = keyword
        lock.unlock()
    }

    var snapshot: (order: SpaceVideoOrder, keyword: String) {
        lock.lock()
        defer { lock.unlock() }
        return (order, keyword)
    }
}

@MainActor
final class UserSpaceModel: ObservableObject {
    let mid: Int64
    @Published private(set) var info: SpaceInfo?
    @Published private(set) var infoError: String?
    @Published private(set) var isFollowed = false
    /// Detailed relation (`/x/relation`: 已互关 / 悄悄关注 / 特别关注 / 已拉黑); nil when logged out / not loaded.
    @Published private(set) var relation: UserRelationState?
    @Published private(set) var isUpdatingFollow = false
    @Published private(set) var order: SpaceVideoOrder = .pubdate
    @Published private(set) var keyword = ""

    let videos: PagedListModel<VideoCard>
    let dynamics: PagedListModel<DynamicItem>
    private let videoQuery: SpaceVideoQuery
    private var didLoadInfo = false

    init(mid: Int64) {
        self.mid = mid
        let q = SpaceVideoQuery()
        videoQuery = q
        videos = PagedListModel(filter: FeedFilter.liveFilter(scope: .space)) { cursor in
            let s = q.snapshot
            return try await SpaceAPI.videos(mid: mid, cursor: cursor, order: s.order, keyword: s.keyword)
        }
        dynamics = PagedListModel(filter: DynamicFeedFiltering.liveFilter(scope: .space)) { cursor in
            try await DynamicsAPI.spaceFeed(mid: mid, offset: cursor)
        }
    }

    var isSelf: Bool {
        AuthService.shared.isLoggedIn && AuthService.shared.mid == mid
    }

    /// What the follow button shows: `relation` while it agrees with `isFollowed`, else 已关注 / 关注.
    var followState: UserRelationState {
        if let relation, relation.isFollowing == isFollowed { return relation }
        return isFollowed ? .followed : .notFollowing
    }

    func loadIfNeeded() async {
        guard !didLoadInfo else { return }
        didLoadInfo = true
        await loadInfo()
    }

    func loadInfo() async {
        infoError = nil
        async let detailedRelation = fetchRelation()
        do {
            let i = try await SpaceAPI.info(mid: mid)
            info = i
            let r = await detailedRelation
            relation = r
            isFollowed = r?.isFollowing ?? i.isFollowed
        } catch {
            if ListMapping.isCancellation(error) {
                didLoadInfo = false
                return
            }
            // acc/info is risk-controlled (-352); SpaceAPI already fell back to the card API, so
            // reaching here means both failed. Keep showing an older header if we have one.
            if info == nil { infoError = error.localizedDescription }
        }
    }

    private func fetchRelation() async -> UserRelationState? {
        guard AuthService.shared.isLoggedIn, !isSelf else { return nil }
        return try? await SpaceAPI.relation(fid: mid)
    }

    func refresh(tab: UserSpaceTab) async {
        let infoTask = Task { await loadInfo() }
        switch tab {
        case .videos: await videos.refresh()
        case .dynamics: await dynamics.refresh()
        }
        await infoTask.value
    }

    func setOrder(_ order: SpaceVideoOrder) {
        guard order != self.order else { return }
        self.order = order
        applyVideoQuery()
    }

    func search(_ text: String) {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k != keyword else { return }
        keyword = k
        applyVideoQuery()
    }

    private func applyVideoQuery() {
        videoQuery.set(order: order, keyword: keyword)
        videos.replace([])
        Task { await videos.refresh() }
    }

    /// 关注 / 取消关注 (login required; the caller confirms unfollowing).
    func toggleFollow() async {
        guard !isUpdatingFollow else { return }
        guard AuthService.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        isUpdatingFollow = true
        let target = !isFollowed
        do {
            if target {
                try await SpaceAPI.follow(mid: mid)
            } else {
                try await SpaceAPI.modifyRelation(mid: mid, action: followState.unfollowAction)
            }
            isFollowed = target
            relation = target ? .followed : .notFollowing
            if var i = info {
                i.isFollowed = target
                i.user.isFollowed = target
                i.fans = max(0, i.fans + (target ? 1 : -1))
                info = i
            }
            ToastCenter.shared.show(target ? "关注成功" : "已取消关注")
            if target {
                // A follow-back makes it 已互关: ask again once the server has settled.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, let r = await self.fetchRelation(), self.isFollowed == r.isFollowing else { return }
                    self.relation = r
                }
            }
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
        }
        isUpdatingFollow = false
    }

    /// 拉黑 / 解除拉黑 (`/x/relation/modify` act 5 / 6). Blocking also ends a follow.
    func setBlocked(_ blocked: Bool) async {
        guard !isUpdatingFollow else { return }
        guard AuthService.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        isUpdatingFollow = true
        do {
            try await SpaceAPI.modifyRelation(mid: mid, action: blocked ? .block : .unblock)
            if blocked && isFollowed, var i = info {
                i.isFollowed = false
                i.user.isFollowed = false
                i.fans = max(0, i.fans - 1)
                info = i
            }
            if blocked { isFollowed = false }
            relation = blocked ? .blocked : .notFollowing
            ToastCenter.shared.show(blocked ? "已拉黑" : "已解除拉黑")
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
        }
        isUpdatingFollow = false
    }
}

// MARK: - Header

struct UserSpaceHeader: View {
    @ObservedObject var model: UserSpaceModel
    @ObservedObject private var auth = AuthService.shared
    @State private var confirmUnfollow = false
    @State private var confirmUnblock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            if let info = model.info {
                content(info)
            } else if let error = model.infoError {
                VStack(spacing: 10) {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await model.loadInfo() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
            }
        }
        .background(Color(.systemBackground))
        .confirmationDialog("确定不再关注TA吗？", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("不再关注", role: .destructive) { Task { await model.toggleFollow() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("已将TA拉黑，解除拉黑后才能关注", isPresented: $confirmUnblock, titleVisibility: .visible) {
            Button("解除拉黑", role: .destructive) { Task { await model.setBlocked(false) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var banner: some View {
        ZStack {
            LinearGradient(colors: [Color.biliPink.opacity(0.35), Color.biliBlue.opacity(0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let photo = model.info?.topPhoto, !photo.isEmpty {
                RemoteImage(url: photo, width: UIScreen.main.bounds.width)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipped()
    }

    @ViewBuilder
    private func content(_ info: SpaceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                avatar(info)
                    .padding(.top, -30)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    stats(info)
                    if !model.isSelf { followButton }
                }
                .frame(maxWidth: 230)
                .padding(.top, 10)
            }

            HStack(spacing: 6) {
                Text(info.name)
                    .font(.title3.weight(.bold))
                    .foregroundColor(info.vipLabel.isEmpty ? .primary : .biliPink)
                    .lineLimit(1)
                if info.level > 0 || info.mid != 0 {
                    UserSpaceLevelBadge(level: info.level)
                }
                if !info.vipLabel.isEmpty {
                    Text(info.vipLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 3))
                }
                if info.sex == "男" || info.sex == "女" {
                    Text(info.sex == "男" ? "♂" : "♀")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(info.sex == "男" ? .biliBlue : .biliPink)
                }
            }

            if !info.officialTitle.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundColor(info.officialType == 1 ? .biliBlue : .orange)
                    Text(info.officialTitle)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .font(.caption)
            }

            Text(info.sign.isEmpty ? "这个人很神秘，什么都没有写" : info.sign)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if info.isLive {
                NavigationLink(value: Route.live(roomId: info.liveRoomId)) {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("直播中")
                            .fontWeight(.semibold)
                        Text(info.liveTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .font(.footnote)
                    .foregroundColor(.biliPink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.biliPink.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func avatar(_ info: SpaceInfo) -> some View {
        let image = AvatarView(url: info.face, size: 76)
            .padding(3)
            .background(Circle().fill(Color(.systemBackground)))
            .overlay(alignment: .bottom) {
                if info.isLive {
                    Text("直播中")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.biliPink, in: Capsule())
                        .offset(y: 4)
                }
            }
        if info.isLive {
            NavigationLink(value: Route.live(roomId: info.liveRoomId)) { image }
                .buttonStyle(.plain)
        } else {
            image
        }
    }

    private func stats(_ info: SpaceInfo) -> some View {
        HStack(spacing: 0) {
            statItem(count: info.fans, label: "粉丝", route: .fans(mid: model.mid))
            statItem(count: info.following, label: "关注", route: .following(mid: model.mid))
            statItem(count: info.likes, label: "获赞", route: nil)
        }
    }

    @ViewBuilder
    private func statItem(count: Int64, label: String, route: Route?) -> some View {
        let content = VStack(spacing: 2) {
            Text(Fmt.count(count))
                .font(.headline.monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        if let route {
            NavigationLink(value: route) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private var followButton: some View {
        if auth.isLoggedIn {
            Button {
                switch model.followState {
                case .blocked: confirmUnblock = true
                case .notFollowing: Task { await model.toggleFollow() }
                default: confirmUnfollow = true
                }
            } label: {
                followLabel(model.followState)
            }
            .buttonStyle(.plain)
            .disabled(model.isUpdatingFollow)
        } else {
            NavigationLink(value: Route.login) {
                followLabel(.notFollowing)
            }
            .buttonStyle(.plain)
        }
    }

    /// 「+ 关注」 / 已关注 / 悄悄关注 / 已互关 / 特别关注 / 已拉黑.
    private func followLabel(_ state: UserRelationState) -> some View {
        let plain = state == .notFollowing
        return HStack(spacing: 4) {
            if model.isUpdatingFollow {
                ProgressView()
                    .controlSize(.small)
            } else if plain {
                Image(systemName: "plus")
            }
            Text(state.label)
        }
        .font(.subheadline.weight(.medium))
        .foregroundColor(plain ? .white : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(plain ? Color.biliPink : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct UserSpaceLevelBadge: View {
    let level: Int

    var body: some View {
        Text("LV\(level)")
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }

    private var color: Color {
        switch level {
        case 2: return Color(red: 0.55, green: 0.82, blue: 0.53)
        case 3: return Color(red: 0.42, green: 0.72, blue: 0.95)
        case 4: return Color(red: 0.98, green: 0.76, blue: 0.27)
        case 5: return Color(red: 0.98, green: 0.55, blue: 0.24)
        case 6, 7, 8, 9: return Color(red: 0.94, green: 0.31, blue: 0.29)
        default: return Color(.systemGray3)
        }
    }
}

// MARK: - Tabs

struct UserSpaceTabBar: View {
    @Binding var tab: UserSpaceTab
    let archiveCount: Int64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(UserSpaceTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        VStack(spacing: 6) {
                            Text(title(t))
                                .font(.subheadline.weight(tab == t ? .semibold : .regular))
                                .foregroundColor(tab == t ? .biliPink : .primary)
                            Capsule()
                                .fill(tab == t ? Color.biliPink : Color.clear)
                                .frame(width: 22, height: 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Divider()
        }
        .background(Color(.systemBackground))
    }

    private func title(_ t: UserSpaceTab) -> String {
        switch t {
        case .videos: return archiveCount > 0 ? "投稿 \(Fmt.count(archiveCount))" : "投稿"
        case .dynamics: return "动态"
        }
    }
}

/// 投稿: search field, order menu (最新发布 / 最多播放 / 最多收藏), video rows.
struct UserSpaceVideosSection: View {
    @ObservedObject var model: UserSpaceModel
    @ObservedObject var list: PagedListModel<VideoCard>
    @State private var searchText = ""

    var body: some View {
        LazyVStack(spacing: 0) {
            controls
            ForEach(list.items) { card in
                NavigationLink(value: card.route ?? Route.video(card.videoRef)) {
                    VideoRowCell(card: card)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .onAppear { list.onItemAppear(card) }
            }
            ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                       error: list.errorMessage,
                       emptyText: model.keyword.isEmpty ? "TA还没有投过稿" : "没有找到相关视频") {
                Task {
                    if list.isEmpty { await list.refresh() } else { await list.loadMore() }
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear { if searchText.isEmpty { searchText = model.keyword } }
        .task { await list.loadIfNeeded() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索TA的视频", text: $searchText)
                    .submitLabel(.search)
                    .onSubmit { model.search(searchText) }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        model.search("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(.secondarySystemBackground), in: Capsule())

            Menu {
                Picker("排序", selection: Binding(get: { model.order }, set: { model.setOrder($0) })) {
                    ForEach(SpaceVideoOrder.allCases) { o in
                        Text(o.title).tag(o)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(model.order.title)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 动态: the UP's own dynamics (WBI + risk control; errors show in the footer with 重试).
struct UserSpaceDynamicsSection: View {
    @ObservedObject var list: PagedListModel<DynamicItem>

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(list.items) { item in
                DynamicCardView(item: item, linksAuthor: false)
                    .onAppear { list.onItemAppear(item) }
            }
            ListFooter(isLoading: list.isLoading, hasMore: list.hasMore, isEmpty: list.isEmpty,
                       error: list.errorMessage, emptyText: "TA还没有发过动态") {
                Task {
                    if list.isEmpty { await list.refresh() } else { await list.loadMore() }
                }
            }
        }
        .padding(.top, 8)
        .task { await list.loadIfNeeded() }
    }
}
