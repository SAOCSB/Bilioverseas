import SwiftUI
import UIKit
import Combine

/// 我的 tab root: account header, 动态 / 关注 / 粉丝, quick entries, 最近观看 and the settings list.
struct MineView: View {
    @ObservedObject private var auth = AuthService.shared
    @StateObject private var model = MineViewModel()
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if auth.isLoggedIn {
                    loggedInHeader
                } else {
                    loggedOutHeader
                }
                quickEntries
                if auth.isLoggedIn && !model.recent.isEmpty {
                    recentSection
                }
                menuSection(MineMenuItem.services)
                menuSection(MineMenuItem.general)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .refreshable { await model.refresh(force: true) }
        .task { await model.refresh(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            model.loginStateChanged()
        }
    }

    // MARK: Header

    private var loggedOutHeader: some View {
        NavigationLink(value: Route.login) {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("点击登录")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("登录后可同步观看记录、收藏和关注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var loggedInHeader: some View {
        let profile = auth.profile
        let mid = auth.mid
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: Route.user(mid: mid)) {
                HStack(spacing: 10) {
                    MineAvatarWithPendant(face: profile?.face ?? "", pendant: profile?.pendantImage ?? "", size: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(verbatim: displayName(profile, mid: mid))
                                .font(.title3.weight(.semibold))
                                .foregroundColor(nameColor(profile))
                                .lineLimit(1)
                            if let profile {
                                MineLevelBadge(level: profile.level)
                            }
                        }
                        if let profile, profile.isVip {
                            Text(verbatim: vipLabel(profile))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 3))
                        }
                        HStack(spacing: 12) {
                            Text(verbatim: "硬币 \(MineViewModel.amountText(profile?.coins ?? 0))")
                            if let bcoin = profile?.bcoin {
                                Text(verbatim: "B币 \(MineViewModel.amountText(bcoin))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        Text("我的空间")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mid == 0)

            if let profile {
                HStack(spacing: 8) {
                    Text(verbatim: "LV\(profile.level)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MineLevelBadge.color(for: profile.level))
                    ProgressView(value: profile.levelProgress)
                        .tint(Color.biliPink)
                        .frame(maxWidth: 180)
                    Text(verbatim: profile.expText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 0) {
                statItem(count: auth.stat?.dynamicCount, label: "动态", route: .user(mid: mid))
                statItem(count: auth.stat?.following, label: "关注", route: .following(mid: mid))
                statItem(count: auth.stat?.follower, label: "粉丝", route: .fans(mid: mid))
            }
            .disabled(mid == 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(count: Int64?, label: String, route: Route) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 2) {
                Text(verbatim: count.map { Fmt.count($0) } ?? "-")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func displayName(_ profile: UserProfile?, mid: Int64) -> String {
        if let name = profile?.name, !name.isEmpty { return name }
        return mid != 0 ? "UID \(mid)" : "加载中…"
    }

    private func nameColor(_ profile: UserProfile?) -> Color {
        guard let profile, profile.isVip else { return .primary }
        return MineViewModel.color(hex: profile.vipNicknameColorHex) ?? .biliPink
    }

    private func vipLabel(_ profile: UserProfile) -> String {
        if !profile.vipLabelText.isEmpty { return profile.vipLabelText }
        return profile.isAnnualVip ? "年度大会员" : "大会员"
    }

    // MARK: Quick entries

    private var quickEntries: some View {
        HStack(alignment: .top, spacing: 0) {
            NavigationLink(value: Route.history) {
                MineQuickEntryLabel(title: "历史记录", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            NavigationLink(value: Route.favorites(mid: nil)) {
                MineQuickEntryLabel(title: "我的收藏", systemImage: "star")
            }
            .buttonStyle(.plain)
            NavigationLink(value: Route.watchLater) {
                MineQuickEntryLabel(title: "稍后再看", systemImage: "clock")
            }
            .buttonStyle(.plain)
            NavigationLink(value: Route.bangumiFollows) {
                MineQuickEntryLabel(title: "我的追番", systemImage: "tv")
            }
            .buttonStyle(.plain)
            // 离线缓存: not offered in this build.
        }
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 最近观看

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近观看")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                NavigationLink(value: Route.history) {
                    HStack(spacing: 2) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(model.recent) { card in
                        Button {
                            if let route = MineListFormat.resumeRoute(card) { router.push(route) }
                        } label: {
                            MineRecentCard(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Settings list

    private func menuSection(_ items: [MineMenuItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                NavigationLink(value: item.route) {
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 17))
                            .foregroundStyle(Color.biliPink)
                            .frame(width: 24)
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Model

@MainActor
final class MineViewModel: ObservableObject {
    /// First ~10 history items for 「最近观看」.
    @Published private(set) var recent: [VideoCard] = []
    private var lastRefresh: Date?

    /// Re-fetches the profile (nav + stat) and the recent history. Throttled unless `force`.
    func refresh(force: Bool) async {
        let auth = AuthService.shared
        guard auth.isLoggedIn else {
            recent = []
            return
        }
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 15 { return }
        lastRefresh = Date()
        async let profile: Void = auth.refreshProfile()
        await loadRecent()
        await profile
    }

    func loadRecent() async {
        guard AuthService.shared.isLoggedIn else {
            recent = []
            return
        }
        do {
            let page = try await HistoryAPI.list(cursor: nil, type: "all", pageSize: 10)
            recent = Array(page.items.prefix(10))
        } catch {
            // Keep what is shown; the row simply stays as it was.
        }
    }

    func loginStateChanged() {
        lastRefresh = nil
        recent = []
        Task { await refresh(force: true) }
    }

    /// 硬币 / B币 amounts: "123" or "123.5".
    static func amountText(_ value: Double) -> String {
        if value == value.rounded() { return String(Int64(value)) }
        return String(format: "%.1f", value)
    }

    /// "#FB7299" → Color.
    static func color(hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// One row of the 我的 settings list.
struct MineMenuItem: Identifiable {
    let title: String
    let systemImage: String
    let route: Route

    var id: String { title }

    static let services: [MineMenuItem] = [
        MineMenuItem(title: "海外加速设置", systemImage: "bolt.circle", route: .settingsAcceleration),
        MineMenuItem(title: "播放设置", systemImage: "play.rectangle", route: .settingsPlayer),
        MineMenuItem(title: "弹幕设置", systemImage: "text.bubble", route: .settingsDanmaku),
        MineMenuItem(title: "广告屏蔽", systemImage: "hand.raised", route: .settingsFeedFilter),
        MineMenuItem(title: "广告跳过", systemImage: "forward.end", route: .settingsSmartSkip),
    ]

    static let general: [MineMenuItem] = [
        MineMenuItem(title: "设置", systemImage: "gearshape", route: .settings),
    ]
}

// MARK: - Components

/// Icon above title, one quarter of the quick-entry card.
struct MineQuickEntryLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(Color.biliPink)
                .frame(height: 26)
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Avatar with the 头像挂件 drawn around it (the pendant image is ~1.6× the avatar).
struct MineAvatarWithPendant: View {
    let face: String
    let pendant: String
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            if face.isEmpty {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.white)
                    }
            } else {
                AvatarView(url: face, size: size)
            }
            if !pendant.isEmpty {
                MinePendantImage(url: pendant)
                    .frame(width: size * 1.6, height: size * 1.6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size * 1.35, height: size * 1.35)
    }
}

/// Transparent-placeholder image (pendants must not show the grey `RemoteImage` box).
struct MinePendantImage: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let u = url.biliHTTPS
            if let cached = ImagePipeline.shared.cached(u) {
                image = cached
                return
            }
            image = await ImagePipeline.shared.image(for: u)
        }
    }
}

/// 「LV5」 badge in the official level colours.
struct MineLevelBadge: View {
    let level: Int

    var body: some View {
        Text(verbatim: "LV\(level)")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(MineLevelBadge.color(for: level), in: RoundedRectangle(cornerRadius: 3))
    }

    static func color(for level: Int) -> Color {
        switch level {
        case ...1: return Color(red: 0.75, green: 0.75, blue: 0.75)
        case 2: return Color(red: 0.58, green: 0.87, blue: 0.70)
        case 3: return Color(red: 0.57, green: 0.82, blue: 0.90)
        case 4: return Color(red: 1.0, green: 0.70, blue: 0.49)
        case 5: return Color(red: 1.0, green: 0.42, blue: 0.0)
        default: return Color(red: 0.94, green: 0.0, blue: 0.0)
        }
    }
}

/// Small card of the 「最近观看」 row: cover with progress, two-line title.
struct MineRecentCard: View {
    let card: VideoCard
    private let width: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: card.cover, width: width)
                .frame(width: width, height: width * 10 / 16)
                .overlay(alignment: .bottomTrailing) {
                    if let text = coverText {
                        Text(verbatim: text)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let ratio = MineListFormat.progressRatio(card) {
                        Rectangle()
                            .fill(Color.biliPink)
                            .frame(width: width * ratio, height: 2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(card.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var coverText: String? {
        if card.progress < 0 { return "已看完" }
        if card.progress > 0 && card.duration > 0 {
            return "\(Fmt.duration(card.progress))/\(Fmt.duration(card.duration))"
        }
        return card.duration > 0 ? Fmt.duration(card.duration) : nil
    }
}
