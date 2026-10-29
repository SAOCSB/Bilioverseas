import SwiftUI

// Cells and small building blocks shared by the 首页 tabs (推荐 / 热门 / 排行 / 番剧 / 直播) and the
// search result tabs.

/// Pushes `route` when there is one; otherwise shows the content without a tap action.
struct HomeRouteLink<Content: View>: View {
    let route: Route?
    let content: Content

    init(_ route: Route?, @ViewBuilder content: () -> Content) {
        self.route = route
        self.content = content()
    }

    var body: some View {
        if let route {
            NavigationLink(value: route) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Rank number drawn on a cover's top-left corner. 1 / 2 / 3 are highlighted.
struct HomeRankBadge: View {
    let rank: Int

    init(rank: Int) { self.rank = rank }

    var body: some View {
        Text(String(rank))
            .font(.system(size: rank < 100 ? 12 : 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 18)
            .background(HomeRankBadge.color(for: rank), in: RoundedRectangle(cornerRadius: 4))
    }

    static func color(for rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.996, green: 0.341, blue: 0.341)
        case 2: return Color(red: 1.0, green: 0.525, blue: 0.243)
        case 3: return Color(red: 0.98, green: 0.71, blue: 0.2)
        default: return Color.black.opacity(0.45)
        }
    }
}

/// Orange recommend-reason tag (「百万播放」「很多人点赞」…).
struct HomeReasonTag: View {
    let text: String

    init(text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.orange)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Large single-column video row (热门 / 排行榜 / 每周必看 / 入站必刷): cover left, title, reason tag,
/// UP name and stats right. Optional rank badge on the cover.
struct HomeVideoRow: View {
    let card: VideoCard
    let rank: Int?
    let showReason: Bool

    init(card: VideoCard, rank: Int? = nil, showReason: Bool = true) {
        self.card = card
        self.rank = rank
        self.showReason = showReason
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if showReason, !card.reason.isEmpty {
                    HomeReasonTag(text: card.reason)
                }
                Spacer(minLength: 0)
                if !card.ownerName.isEmpty {
                    Label(card.ownerName, systemImage: "person.crop.square")
                        .labelStyle(CompactLabelStyle())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if card.viewCount > 0 {
                        Label(Fmt.count(card.viewCount), systemImage: "play.rectangle")
                    }
                    if card.danmakuCount > 0 {
                        Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble")
                    }
                    if card.pubdate > 0 {
                        Text(Fmt.relativeDate(card.pubdate))
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 94, maxHeight: 94, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var cover: some View {
        RemoteImage(url: card.cover, width: 150)
            .frame(width: 150, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if card.duration > 0 {
                    Text(Fmt.duration(card.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if let rank {
                    HomeRankBadge(rank: rank).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !card.badge.isEmpty {
                    BadgeLabel(text: card.badge).padding(4)
                }
            }
    }
}

/// PGC (番剧 / 影视) row: 3:4 cover, title, badge, meta lines. Used by 排行 PGC zones, 番剧排行 and
/// 番剧 search results.
struct HomePGCRowCell: View {
    let card: VideoCard
    let rank: Int?
    /// Extra muted line under the meta (rating, description …).
    let extra: String

    init(card: VideoCard, rank: Int? = nil, extra: String = "") {
        self.card = card
        self.rank = rank
        self.extra = extra
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: card.cover, width: 84)
                .frame(width: 84, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if !card.badge.isEmpty {
                        BadgeLabel(text: card.badge).padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rank {
                        HomeRankBadge(rank: rank).padding(4)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(card.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !card.ownerName.isEmpty {
                    Text(card.ownerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !card.reason.isEmpty {
                    Text(card.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if card.viewCount > 0 || card.danmakuCount > 0 {
                    HStack(spacing: 10) {
                        if card.viewCount > 0 {
                            Label(Fmt.count(card.viewCount), systemImage: "play.rectangle")
                        }
                        if card.danmakuCount > 0 {
                            Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble")
                        }
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if !extra.isEmpty {
                    Text(extra)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }
}

/// Live room card (直播 tab, 直播 search results): 16:10 cover with anchor name and audience on the
/// bottom gradient, area tag top-left, one-line title below. Takes a `.live` VideoCard
/// (`LiveRoom.card` or `SearchAPI.searchLive`): `desc` = area, `viewCount` / `reason` = audience.
struct HomeLiveCardCell: View {
    let card: VideoCard

    init(card: VideoCard) { self.card = card }

    private var audienceText: String {
        card.viewCount > 0 ? Fmt.count(card.viewCount) : card.reason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                RemoteImage(url: card.cover, width: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(alignment: .bottom) { coverFooter }
                    .overlay(alignment: .topLeading) {
                        if !card.desc.isEmpty {
                            Text(card.desc)
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.4), in: Capsule())
                                .padding(5)
                        }
                    }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(card.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var coverFooter: some View {
        HStack(spacing: 4) {
            Text(card.ownerName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !audienceText.isEmpty {
                Label(audienceText, systemImage: "person.2.fill")
                    .labelStyle(CompactLabelStyle())
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }
}

/// Section title row with an optional trailing accessory.
struct HomeSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
    }
}

extension HomeSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Horizontal chip selector (排行榜 zones). Keeps the selected chip scrolled into view.
struct HomeChipBar<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    init(items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String) {
        self.items = items
        self._selection = selection
        self.title = title
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        chip(item)
                            .id(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { newValue in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func chip(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            selection = item
        } label: {
            Text(title(item))
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.biliPink : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(isSelected ? Color.biliPink.opacity(0.12) : Color(.secondarySystemBackground),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
