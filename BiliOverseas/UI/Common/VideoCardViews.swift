import SwiftUI

/// Official-app style grid card: 16:10 cover with play/danmaku counts and duration overlay.
struct VideoGridCell: View {
    let card: VideoCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                RemoteImage(url: card.cover, width: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(alignment: .bottom) { coverOverlay }
                    .overlay(alignment: .topTrailing) {
                        if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                    }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(card.title)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                if !card.reason.isEmpty {
                    Text(card.reason)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 3)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor.opacity(0.6), lineWidth: 0.5))
                } else if !card.ownerName.isEmpty {
                    Image(systemName: "person.crop.square").font(.caption2)
                }
                Text(card.ownerName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var coverOverlay: some View {
        HStack(spacing: 8) {
            if card.viewCount > 0 {
                Label(Fmt.count(card.viewCount), systemImage: "play.rectangle")
            }
            if card.danmakuCount > 0 {
                Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble")
            }
            Spacer(minLength: 0)
            if card.duration > 0 { Text(Fmt.duration(card.duration)) }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }
}

/// List row: cover on the left, title / owner / stats on the right (history, search, related …).
struct VideoRowCell: View {
    let card: VideoCard
    var showProgress: Bool = false
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: card.cover, width: 150)
                .frame(width: 150, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if card.duration > 0 {
                        Text(durationText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showProgress, card.duration > 0, card.progress != 0 {
                        GeometryReader { g in
                            let ratio = card.progress < 0 ? 1 : min(1, Double(card.progress) / Double(card.duration))
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * ratio, height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !card.badge.isEmpty { BadgeLabel(text: card.badge).padding(4) }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if !card.ownerName.isEmpty {
                    Label(card.ownerName, systemImage: "person.crop.square")
                        .labelStyle(CompactLabelStyle())
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let subtitle {
                        Text(subtitle)
                    } else {
                        if card.viewCount > 0 { Label(Fmt.count(card.viewCount), systemImage: "play.rectangle") }
                        if card.danmakuCount > 0 { Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble") }
                        if card.pubdate > 0 { Text(Fmt.relativeDate(card.pubdate)) }
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 94, maxHeight: 94, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var durationText: String {
        if showProgress && card.progress < 0 { return "已看完" }
        if showProgress && card.progress > 0 { return "\(Fmt.duration(card.progress))/\(Fmt.duration(card.duration))" }
        return Fmt.duration(card.duration)
    }
}

struct BadgeLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// Two-column (or settings-driven) grid of cards with infinite scroll, used by feeds.
struct VideoCardGrid: View {
    @ObservedObject var model: PagedListModel<VideoCard>
    @ObservedObject private var settings = AppSettings.shared
    var emptyText: String = "暂无视频"

    private var columns: [GridItem] {
        let n = UIDevice.current.userInterfaceIdiom == .pad ? 4 : max(1, settings.general.feedColumns)
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: n)
    }

    var body: some View {
        ScrollView {
            if settings.general.feedColumns == 1 && UIDevice.current.userInterfaceIdiom != .pad {
                LazyVStack(spacing: 12) {
                    ForEach(model.items) { card in
                        cardLink(card) { VideoRowCell(card: card) }
                    }
                }
                .padding(.horizontal, 12)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.items) { card in
                        cardLink(card) { VideoGridCell(card: card) }
                    }
                }
                .padding(.horizontal, 10)
            }
            ListFooter(isLoading: model.isLoading, hasMore: model.hasMore, isEmpty: model.isEmpty,
                       error: model.errorMessage, emptyText: emptyText) {
                Task { await model.loadMore() }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private func cardLink<Content: View>(_ card: VideoCard, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if let route = card.route {
                NavigationLink(value: route) { content() }
            } else {
                content()
            }
        }
        .buttonStyle(.plain)
        .onAppear { model.onItemAppear(card) }
    }
}
