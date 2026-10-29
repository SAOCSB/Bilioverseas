import SwiftUI
import UIKit

// MARK: - Filtering

/// `FeedFilter` adapter for dynamics (动态). A dynamic is judged by its embedded card (video / PGC /
/// live), or by a stand-in card built from its text and ad signals for image / text / forward posts,
/// so 广告 (`DYNAMIC_TYPE_AD`) and 带货 (goods) items follow the user's 屏蔽 settings.
enum DynamicFeedFiltering {
    static func proxyCard(for item: DynamicItem) -> VideoCard {
        if var card = item.video {
            for s in item.adSignals where !card.adSignals.contains(s) {
                if item.isAd || FeedFilter.isSoftPromotionSignal(s) { card.adSignals.append(s) }
            }
            if item.isAd { card.kind = .ad }
            return card
        }
        var c = VideoCard(id: "dyn-" + item.idStr)
        c.kind = item.isAd ? .ad : .other
        c.title = item.title
        c.desc = item.text
        c.ownerMid = item.author.mid
        c.ownerName = item.author.name
        c.isFollowed = item.author.isFollowed
        c.adSignals = item.adSignals
        return c
    }

    /// Main thread only (reads `FeedFilter.current`).
    static func allows(_ item: DynamicItem, scope: FeedScope) -> Bool {
        FeedFilter.current.allows(proxyCard(for: item), scope: scope)
    }

    /// For `PagedListModel(filter:)`; consults the latest settings on every page.
    static func liveFilter(scope: FeedScope) -> (DynamicItem) -> Bool {
        { allows($0, scope: scope) }
    }
}

// MARK: - Routes

enum DynamicRoutes {
    /// Numeric dynamic id (synthetic ids of id-less originals are not addressable).
    static func hasRealId(_ item: DynamicItem) -> Bool {
        !item.idStr.isEmpty && item.idStr.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Web detail page (full text, comments) of a dynamic.
    static func detailURL(for item: DynamicItem) -> URL? {
        if !item.jumpURL.isEmpty, let u = URL(string: item.jumpURL.biliHTTPS), u.scheme?.hasPrefix("http") == true {
            return u
        }
        guard hasRealId(item) else { return nil }
        return URL(string: "https://t.bilibili.com/\(item.idStr)")
    }

    /// Tapping the body: the embedded video / episode / live room, else the web detail.
    static func primaryRoute(for item: DynamicItem) -> Route? {
        if let r = item.video?.route { return r }
        return detailURL(for: item).map { Route.web($0) }
    }

    /// Link used by 转发 (share) and 复制链接.
    static func shareURL(for item: DynamicItem) -> URL? {
        if hasRealId(item) { return URL(string: "https://t.bilibili.com/\(item.idStr)") }
        if let v = item.video, !v.uri.isEmpty, let u = URL(string: v.uri.biliHTTPS) { return u }
        return detailURL(for: item)
    }
}

// MARK: - Like state

/// Optimistic 点赞 state shared by every dynamic list (survives cell recycling and list reloads).
@MainActor
final class DynamicLikeStore: ObservableObject {
    static let shared = DynamicLikeStore()

    struct State: Equatable {
        var liked: Bool
        var count: Int64
    }

    @Published private(set) var states: [String: State] = [:]
    private var inFlight = Set<String>()

    func state(for item: DynamicItem) -> State {
        states[item.idStr] ?? State(liked: item.stat.liked, count: item.stat.like)
    }

    func toggle(_ item: DynamicItem) {
        guard AuthService.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        guard DynamicRoutes.hasRealId(item) else { return }
        let id = item.idStr
        guard !inFlight.contains(id) else { return }
        let old = state(for: item)
        let new = State(liked: !old.liked, count: max(0, old.count + (old.liked ? -1 : 1)))
        states[id] = new
        inFlight.insert(id)
        Task {
            do {
                try await DynamicsAPI.like(dynamicId: id, like: new.liked)
            } catch {
                states[id] = old
                if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            }
            inFlight.remove(id)
        }
    }
}

// MARK: - Card

/// One dynamic in the official-app layout: author header, rich text, media, forwarded original,
/// and the 转发 / 评论 / 点赞 bar.
struct DynamicCardView: View {
    let item: DynamicItem
    /// Avatar / name open the author's space (turned off inside that space).
    var linksAuthor: Bool = true

    @State private var viewer: DynamicImageViewerPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DynamicAuthorHeader(item: item, linksAuthor: linksAuthor)
            DynamicContentView(item: item, isForwarded: false) { urls, index in
                viewer = DynamicImageViewerPayload(urls: urls, index: index)
            }
            DynamicActionBar(item: item)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .fullScreenCover(item: $viewer) { payload in
            DynamicImageViewer(urls: payload.urls, startIndex: payload.index)
        }
    }
}

/// Avatar, name, publish time · action, 置顶 tag and the ⋯ menu.
struct DynamicAuthorHeader: View {
    let item: DynamicItem
    var linksAuthor: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            authorLink {
                AvatarView(url: item.author.face, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                authorLink {
                    Text(item.author.name.isEmpty ? "未知用户" : item.author.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(item.author.vipLabel.isEmpty ? .primary : .biliPink)
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isTop {
                Text("置顶")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.biliPink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliPink, lineWidth: 0.7))
            }
            DynamicMoreMenu(item: item)
        }
    }

    private var subtitle: String {
        let time = item.pubTimeText.isEmpty ? Fmt.relativeDate(item.pubTs) : item.pubTimeText
        return [time, item.pubAction].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func authorLink<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if linksAuthor && item.author.mid != 0 {
            NavigationLink(value: Route.user(mid: item.author.mid)) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

struct DynamicMoreMenu: View {
    let item: DynamicItem

    var body: some View {
        if let url = DynamicRoutes.shareURL(for: item) {
            Menu {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    ToastCenter.shared.show("已复制链接")
                } label: {
                    Label("复制链接", systemImage: "link")
                }
                if !item.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = item.text
                        ToastCenter.shared.show("已复制")
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                }
                Link(destination: url) {
                    Label("在浏览器中打开", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }
}

/// Topic, title, rich text, images / link card, embedded card and the forwarded original.
/// Recursive through `DynamicForwardBox` (one level: Bilibili never nests forwards).
struct DynamicContentView: View {
    let item: DynamicItem
    let isForwarded: Bool
    let onOpenImages: ([String], Int) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isDeleted {
                Text(item.text.isEmpty ? "动态已被删除" : item.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                if hasTextBlock {
                    textLink {
                        VStack(alignment: .leading, spacing: 6) {
                            if !item.topic.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "number.circle.fill")
                                    Text(item.topic)
                                }
                                .font(.footnote)
                                .foregroundColor(.biliBlue)
                            }
                            if showsTitle {
                                Text(item.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                            }
                            if !item.text.isEmpty {
                                DynamicRichText(text: item.text, emojis: item.emojis,
                                                lineLimit: expanded ? nil : collapsedLines,
                                                fontSize: isForwarded ? 14 : 15)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .contextMenu {
                        if !item.text.isEmpty {
                            Button {
                                UIPasteboard.general.string = item.text
                                ToastCenter.shared.show("已复制")
                            } label: {
                                Label("复制内容", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    if needsExpand {
                        Button(expanded ? "收起" : "展开") { expanded.toggle() }
                            .font(.subheadline)
                            .foregroundColor(.biliBlue)
                            .buttonStyle(.plain)
                    }
                }
                if isLinkCard {
                    DynamicLinkCard(item: item, inForward: isForwarded)
                } else if !item.images.isEmpty {
                    DynamicImageGrid(urls: item.images) { onOpenImages(item.images, $0) }
                }
                if let card = item.video {
                    DynamicEmbeddedCard(card: card, inForward: isForwarded)
                }
                if let orig = item.forwarded {
                    DynamicForwardBox(orig: orig, onOpenImages: onOpenImages)
                } else if item.type == .forward {
                    Text("源动态已被删除")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var showsTitle: Bool { !item.title.isEmpty && !isLinkCard }
    private var hasTextBlock: Bool { !item.topic.isEmpty || showsTitle || !item.text.isEmpty }
    private var collapsedLines: Int { isForwarded ? 4 : 6 }
    private var needsExpand: Bool {
        item.text.count > (isForwarded ? 110 : 160) || item.text.filter { $0 == "\n" }.count >= collapsedLines
    }

    /// Courses / music / medialist / common link cards: title + cover + jump URL, no own media.
    private var isLinkCard: Bool {
        item.video == nil && item.type == .other && !item.title.isEmpty && !item.jumpURL.isEmpty && item.images.count <= 1
    }

    @ViewBuilder
    private func textLink<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let route = DynamicRoutes.primaryRoute(for: item) {
            NavigationLink(value: route) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

/// The forwarded original in a grey box.
struct DynamicForwardBox: View {
    let orig: DynamicItem
    let onOpenImages: ([String], Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !orig.isDeleted, orig.author.mid != 0 {
                NavigationLink(value: Route.user(mid: orig.author.mid)) {
                    Text("@" + (orig.author.name.isEmpty ? "UID:\(orig.author.mid)" : orig.author.name))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.biliBlue)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            DynamicContentView(item: orig, isForwarded: true, onOpenImages: onOpenImages)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Small link card (课程 / 音频 / 收藏夹 / 通用卡片).
struct DynamicLinkCard: View {
    let item: DynamicItem
    var inForward: Bool = false

    var body: some View {
        if let url = URL(string: item.jumpURL.biliHTTPS) {
            NavigationLink(value: Route.web(url)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if let cover = item.images.first {
                RemoteImage(url: cover, width: 96)
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inForward ? Color(.systemBackground) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var kindLabel: String {
        switch item.rawType {
        case "DYNAMIC_TYPE_COURSES_SEASON", "DYNAMIC_TYPE_COURSES": return "课程"
        case "DYNAMIC_TYPE_MUSIC": return "音频"
        case "DYNAMIC_TYPE_MEDIALIST": return "收藏夹"
        default: return "查看详情"
        }
    }
}

// MARK: - Embedded video / live card

/// Video, PGC episode or live room embedded in a dynamic.
struct DynamicEmbeddedCard: View {
    let card: VideoCard
    var inForward: Bool = false

    var body: some View {
        if let route = card.route {
            NavigationLink(value: route) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(.secondarySystemFill)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay { RemoteImage(url: card.cover, width: 360) }
                .clipped()
                .overlay(alignment: .bottom) { coverFooter }
                .overlay(alignment: .topLeading) {
                    if !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title.isEmpty ? " " : card.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if card.kind == .live, !card.desc.isEmpty {
                    Text(card.desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inForward ? Color(.systemBackground) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var badgeText: String {
        if card.kind == .live { return card.badge.isEmpty ? "直播" : card.badge }
        return card.badge
    }

    private var coverFooter: some View {
        HStack(spacing: 10) {
            if card.kind == .live {
                if !card.reason.isEmpty { Text(card.reason) }
            } else {
                if card.viewCount > 0 { Label(Fmt.count(card.viewCount), systemImage: "play.rectangle") }
                if card.danmakuCount > 0 { Label(Fmt.count(card.danmakuCount), systemImage: "text.bubble") }
            }
            Spacer(minLength: 0)
            if card.duration > 0 { Text(Fmt.duration(card.duration)) }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption.monospacedDigit())
        .foregroundColor(.white)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Images

/// 1 image: natural aspect (clamped); 2 / 4 images: 2 columns; otherwise 3 columns. At most 9 shown.
struct DynamicImageGrid: View {
    let urls: [String]
    let onTap: (Int) -> Void

    var body: some View {
        let shown = Array(urls.prefix(9))
        if shown.count == 1 {
            DynamicSingleImage(url: shown[0])
                .contentShape(Rectangle())
                .onTapGesture { onTap(0) }
        } else {
            let columns = (shown.count == 2 || shown.count == 4) ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, url in
                    Color(.secondarySystemFill)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { RemoteImage(url: url, width: columns == 2 ? 200 : 140) }
                        .clipped()
                        .overlay(alignment: .center) {
                            if index == shown.count - 1, urls.count > shown.count {
                                ZStack {
                                    Color.black.opacity(0.45)
                                    Text("+\(urls.count - shown.count)")
                                        .font(.title3.weight(.semibold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(index) }
                }
            }
            .frame(maxWidth: shown.count == 4 ? 280 : .infinity, alignment: .leading)
        }
    }
}

/// A single image shown at its own aspect ratio (clamped to 0.6 … 2.0 so long images are cropped).
struct DynamicSingleImage: View {
    let url: String
    @State private var image: UIImage?

    private var aspect: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 4.0 / 3.0 }
        return min(max(image.size.width / image.size.height, 0.6), 2.0)
    }

    private var requestURL: String {
        AppSettings.shared.general.compactImages ? Fmt.thumb(url, width: 720) : url.biliHTTPS
    }

    var body: some View {
        // Fits a 320 pt screen even inside a forwarded box.
        let width: CGFloat = aspect >= 1 ? 270 : 210
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .frame(width: width, height: width / aspect)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if let image, image.size.height / max(image.size.width, 1) > 2.2 {
                Text("长图")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5)
            }
        }
        .task(id: url) {
            let u = requestURL
            if let cached = ImagePipeline.shared.cached(u) {
                image = cached
                return
            }
            image = await ImagePipeline.shared.image(for: u)
        }
    }
}

// MARK: - Rich text

/// Dynamic text with inline emoji images (`[doge]`) and blue @mentions / #topics# / links.
struct DynamicRichText: View {
    let text: String
    var emojis: [String: String] = [:]
    var lineLimit: Int? = nil
    var fontSize: CGFloat = 15

    @State private var images: [String: UIImage]

    init(text: String, emojis: [String: String] = [:], lineLimit: Int? = nil, fontSize: CGFloat = 15) {
        self.text = text
        self.emojis = emojis
        self.lineLimit = lineLimit
        self.fontSize = fontSize
        _images = State(initialValue: DynamicRichTextBuilder.cachedEmojis(emojis, side: fontSize + 5))
    }

    var body: some View {
        DynamicRichTextBuilder.text(for: text, emojis: images)
            .font(.system(size: fontSize))
            .foregroundColor(.primary)
            .lineSpacing(3)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .task(id: text) { await loadEmojis() }
    }

    private func loadEmojis() async {
        let side = fontSize + 5
        let missing = emojis.filter { images[$0.key] == nil && text.contains($0.key) }
        guard !missing.isEmpty else { return }
        var loaded = images
        for (name, url) in missing {
            if let img = await DynamicRichTextBuilder.emoji(url: url, side: side) { loaded[name] = img }
            if Task.isCancelled { return }
        }
        images = loaded
    }
}

enum DynamicRichTextBuilder {
    /// `[emoji]`, `#topic#`, `@mention`, plain http(s) links.
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"\[[^\[\]\n]{1,20}\]|#[^#\n]{1,40}#|@[^\s@:：,，。!！?？、]{1,32}|https?://[\x21-\x7E]+"#)

    /// Resized emoji images keyed by `url@side`.
    private static let emojiCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    static func text(for text: String, emojis: [String: UIImage]) -> Text {
        guard let regex = tokenRegex, !text.isEmpty else { return Text(verbatim: text) }
        let ns = text as NSString
        var result = Text(verbatim: "")
        var cursor = 0
        for m in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                result = result + Text(verbatim: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let token = ns.substring(with: m.range)
            if token.hasPrefix("[") {
                if let img = emojis[token] {
                    result = result + Text(Image(uiImage: img)).baselineOffset(-4)
                } else {
                    result = result + Text(verbatim: token)
                }
            } else {
                result = result + Text(verbatim: token).foregroundColor(.biliBlue)
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result = result + Text(verbatim: ns.substring(from: cursor))
        }
        return result
    }

    static func cachedEmojis(_ emojis: [String: String], side: CGFloat) -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for (name, url) in emojis {
            if let img = emojiCache.object(forKey: "\(url)@\(Int(side))" as NSString) { out[name] = img }
        }
        return out
    }

    @MainActor
    static func emoji(url: String, side: CGFloat) async -> UIImage? {
        let key = "\(url)@\(Int(side))" as NSString
        if let img = emojiCache.object(forKey: key) { return img }
        guard let original = await ImagePipeline.shared.image(for: url) else { return nil }
        let img = resized(original, side: side)
        emojiCache.setObject(img, forKey: key)
        return img
    }

    @MainActor
    static func resized(_ image: UIImage, side: CGFloat) -> UIImage {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let scale = side / max(w, h)
        let size = CGSize(width: max(1, w * scale), height: max(1, h * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Action bar

/// 转发 (share) / 评论 / 点赞, each a third of the width.
struct DynamicActionBar: View {
    let item: DynamicItem
    @ObservedObject private var likes = DynamicLikeStore.shared

    var body: some View {
        let state = likes.state(for: item)
        HStack(spacing: 0) {
            shareItem
            commentItem
            Button {
                likes.toggle(item)
            } label: {
                DynamicActionLabel(systemImage: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                   text: state.count > 0 ? Fmt.count(state.count) : "点赞",
                                   tint: state.liked ? .biliPink : .secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 40)
    }

    @ViewBuilder private var shareItem: some View {
        let label = DynamicActionLabel(systemImage: "arrowshape.turn.up.right",
                                       text: item.stat.forward > 0 ? Fmt.count(item.stat.forward) : "转发")
        if let url = DynamicRoutes.shareURL(for: item) {
            ShareLink(item: url) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    @ViewBuilder private var commentItem: some View {
        let label = DynamicActionLabel(systemImage: "text.bubble",
                                       text: item.stat.comment > 0 ? Fmt.count(item.stat.comment) : "评论")
        if let route = DynamicRoutes.primaryRoute(for: item) {
            NavigationLink(value: route) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct DynamicActionLabel: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(.footnote)
        .foregroundColor(tint)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }
}
