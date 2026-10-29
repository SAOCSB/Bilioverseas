import SwiftUI
import UIKit

// Shared building blocks of the video detail page: rich text (emotes, @, links, BV/av ids, timestamps),
// expandable text, a flow layout for chips, and the full-screen picture viewer.

// MARK: - Rich text

/// One run of a comment / description: plain text, a tappable link or an emote token.
struct VideoRichSegment: Hashable {
    enum Kind: Hashable {
        case text
        case link(URL)
        /// `text` is the emote token, e.g. "[doge]".
        case emote(url: String, large: Bool)
    }

    var text: String
    var kind: Kind
}

/// What tapping a rich-text link does.
enum VideoLinkTarget {
    case route(Route)
    case seek(Double)
    /// Let the system open it (non-http schemes).
    case system
    case ignore
}

/// Splits Bilibili text into `VideoRichSegment`s and renders them as one `Text` (emotes inline as images).
/// Internal links use the `bilioverseas-internal://<kind>?v=<value>` scheme; resolve them with `target(for:)`.
enum VideoRichText {
    static let scheme = "bilioverseas-internal"

    private static let emoteRegex = try? NSRegularExpression(pattern: #"\[[^\[\]\n]{1,32}\]"#)
    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#)
    private static let bvRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])BV1[1-9A-HJ-NP-Za-km-z]{9}(?![A-Za-z0-9])"#)
    private static let avRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])av\d{2,12}(?![0-9])"#)
    private static let timeRegex = try? NSRegularExpression(pattern: #"(?<![\d:：])(?:\d{1,2}:)?\d{1,2}:[0-5]\d(?![\d:])"#)

    private static let cache = NSCache<NSString, VideoRichSegmentsBox>()

    static func internalURL(_ kind: String, _ value: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = kind
        c.queryItems = [URLQueryItem(name: "v", value: value)]
        return c.url
    }

    /// Cached segments of a comment.
    static func segments(for item: ReplyItem, timestamps: Bool) -> [VideoRichSegment] {
        let key = "\(item.rpid)|\(timestamps ? 1 : 0)|\(item.message.utf16.count)" as NSString
        if item.rpid != 0, let hit = cache.object(forKey: key) { return hit.value }
        let value = segments(item.message, emotes: item.emotes, largeEmotes: item.largeEmotes,
                             atMembers: item.atMembers, jumpLinks: item.jumpLinks, timestamps: timestamps)
        if item.rpid != 0 { cache.setObject(VideoRichSegmentsBox(value), forKey: key) }
        return value
    }

    static func segments(_ message: String, emotes: [String: String] = [:], largeEmotes: Set<String> = [],
                         atMembers: [String: Int64] = [:], jumpLinks: [String: String] = [:],
                         timestamps: Bool = true) -> [VideoRichSegment] {
        guard !message.isEmpty else { return [] }
        let ns = message as NSString
        var out: [VideoRichSegment] = []
        var cursor = 0
        if !emotes.isEmpty, let regex = emoteRegex {
            for m in regex.matches(in: message, options: [], range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: m.range)
                guard let url = emotes[token], m.range.location >= cursor else { continue }
                if m.range.location > cursor {
                    let plain = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    out += linkSegments(plain, atMembers: atMembers, jumpLinks: jumpLinks, timestamps: timestamps)
                }
                out.append(VideoRichSegment(text: token, kind: .emote(url: url, large: largeEmotes.contains(token))))
                cursor = m.range.location + m.range.length
            }
        }
        if cursor < ns.length {
            out += linkSegments(ns.substring(from: cursor), atMembers: atMembers, jumpLinks: jumpLinks, timestamps: timestamps)
        }
        return out
    }

    private static func linkSegments(_ text: String, atMembers: [String: Int64], jumpLinks: [String: String],
                                     timestamps: Bool) -> [VideoRichSegment] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(range: NSRange, url: URL)] = []

        if let regex = urlRegex {
            for m in regex.matches(in: text, options: [], range: full) {
                var raw = ns.substring(with: m.range)
                while let last = raw.last, ".,;:!?)]'".contains(last) { raw.removeLast() }
                let length = (raw as NSString).length
                if length > 8, let url = URL(string: raw) {
                    found.append((NSRange(location: m.range.location, length: length), url))
                }
            }
        }
        if let regex = bvRegex {
            for m in regex.matches(in: text, options: [], range: full) {
                if let url = internalURL("video", ns.substring(with: m.range)) { found.append((m.range, url)) }
            }
        }
        if let regex = avRegex {
            for m in regex.matches(in: text, options: [], range: full) {
                if let url = internalURL("video", ns.substring(with: m.range)) { found.append((m.range, url)) }
            }
        }
        if timestamps, let regex = timeRegex {
            for m in regex.matches(in: text, options: [], range: full) {
                let seconds = Fmt.parseDuration(ns.substring(with: m.range))
                if let url = internalURL("seek", String(seconds)) { found.append((m.range, url)) }
            }
        }
        for (name, mid) in atMembers where mid > 0 && !name.isEmpty {
            let needle = "@" + name
            var searchStart = 0
            while searchStart < ns.length {
                let r = ns.range(of: needle, options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard r.location != NSNotFound else { break }
                if let url = internalURL("user", String(mid)) { found.append((r, url)) }
                searchStart = r.location + r.length
            }
        }
        for (keyword, link) in jumpLinks where !keyword.isEmpty {
            let r = ns.range(of: keyword)
            guard r.location != NSNotFound else { continue }
            let url = link.hasPrefix("http") ? URL(string: link) : internalURL("search", keyword)
            if let url { found.append((r, url)) }
        }

        guard !found.isEmpty else { return [VideoRichSegment(text: text, kind: .text)] }
        found.sort { a, b in
            a.range.location != b.range.location ? a.range.location < b.range.location : a.range.length > b.range.length
        }
        var out: [VideoRichSegment] = []
        var cursor = 0
        for f in found where f.range.location >= cursor && f.range.length > 0 {
            if f.range.location > cursor {
                out.append(VideoRichSegment(text: ns.substring(with: NSRange(location: cursor, length: f.range.location - cursor)),
                                            kind: .text))
            }
            out.append(VideoRichSegment(text: ns.substring(with: f.range), kind: .link(f.url)))
            cursor = f.range.location + f.range.length
        }
        if cursor < ns.length {
            out.append(VideoRichSegment(text: ns.substring(from: cursor), kind: .text))
        }
        return out
    }

    /// Renders segments as one `Text`. Emotes found in `emotes` (keyed by token) are inline images,
    /// others fall back to their `[名称]` text. Apply `.tint(.biliBlue)` to colour links.
    static func text(_ segments: [VideoRichSegment], emotes: [String: UIImage] = [:]) -> Text {
        var result = Text(verbatim: "")
        for segment in segments {
            switch segment.kind {
            case .text:
                result = result + Text(verbatim: segment.text)
            case .link(let url):
                var attributed = AttributedString(segment.text)
                attributed.link = url
                result = result + Text(attributed)
            case .emote(_, let large):
                if let image = emotes[segment.text] {
                    result = result + Text(Image(uiImage: image)).baselineOffset(large ? -8 : -4)
                } else {
                    result = result + Text(verbatim: segment.text)
                }
            }
        }
        return result
    }

    /// Resolves a tapped link (internal scheme or bilibili.com URLs) to an in-app action.
    static func target(for url: URL) -> VideoLinkTarget {
        if url.scheme == scheme {
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value ?? ""
            switch url.host ?? "" {
            case "seek":
                if let s = Double(value) { return .seek(s) }
            case "user":
                if let mid = Int64(value), mid > 0 { return .route(.user(mid: mid)) }
            case "video":
                if value.hasPrefix("BV") { return .route(.video(.bvid(value))) }
                if value.lowercased().hasPrefix("av"), let aid = Int64(value.dropFirst(2)), aid > 0 {
                    return .route(.video(.aid(aid)))
                }
            case "search":
                if !value.isEmpty { return .route(.search(keyword: value)) }
            default:
                break
            }
            return .ignore
        }
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return .system }
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            if host == "space.bilibili.com", let first = url.pathComponents.dropFirst().first, let mid = Int64(first) {
                return .route(.user(mid: mid))
            }
            if let r = path.range(of: #"BV1[1-9A-HJ-NP-Za-km-z]{9}"#, options: .regularExpression) {
                return .route(.video(.bvid(String(path[r]))))
            }
            if let r = path.range(of: #"/video/av\d+"#, options: .regularExpression),
               let aid = Int64(path[r].dropFirst("/video/av".count)) {
                return .route(.video(.aid(aid)))
            }
            if path.contains("/bangumi/play/"), let ids = VideoDetail.parsePGCLink(path) {
                return .route(.video(VideoRef(epId: ids.epId, seasonId: ids.seasonId)))
            }
        }
        return .route(.web(url))
    }
}

final class VideoRichSegmentsBox {
    let value: [VideoRichSegment]
    init(_ value: [VideoRichSegment]) { self.value = value }
}

/// Emote images resized for inline use in `Text` (cached per URL and height).
enum VideoEmoteImages {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(url: String, height: CGFloat) async -> UIImage? {
        guard !url.isEmpty else { return nil }
        let key = "\(url)#\(Int(height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let source = Fmt.thumb(url, width: Int(height * 3))
        var raw = await ImagePipeline.shared.image(for: source)
        if raw == nil, source != url { raw = await ImagePipeline.shared.image(for: url) }
        guard let loaded = raw else { return nil }
        let image = resized(loaded, height: height)
        cache.setObject(image, forKey: key)
        return image
    }

    static func resized(_ image: UIImage, height: CGFloat) -> UIImage {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let size = CGSize(width: max(1, (height * ratio).rounded()), height: height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Loads every emote of `emotes` (token → URL) at `height`.
    static func load(_ emotes: [String: String], height: CGFloat, large: Set<String> = [], largeHeight: CGFloat = 36) async -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for (token, url) in emotes {
            if Task.isCancelled { break }
            if let image = await image(url: url, height: large.contains(token) ? largeHeight : height) {
                out[token] = image
            }
        }
        return out
    }
}

// MARK: - Expandable text

private struct VideoTextFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct VideoTextLimitedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Text collapsed to `lineLimit` lines with a 「展开」/「收起」 toggle shown only when it is truncated.
struct VideoExpandableText: View {
    let text: Text
    var lineLimit: Int = 6
    var toggleFont: Font = .system(size: 13)

    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            text
                .lineLimit(expanded || lineLimit <= 0 ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: VideoTextLimitedHeightKey.self, value: g.size.height)
                })
                .background(
                    text
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .background(GeometryReader { g in
                            Color.clear.preference(key: VideoTextFullHeightKey.self, value: g.size.height)
                        })
                )
                .onPreferenceChange(VideoTextLimitedHeightKey.self) { limitedHeight = $0 }
                .onPreferenceChange(VideoTextFullHeightKey.self) { fullHeight = $0 }
            if lineLimit > 0 && (expanded || fullHeight > limitedHeight + 1) {
                Button(expanded ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(toggleFont)
                .foregroundColor(.biliBlue)
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Flow layout

/// Left-aligned wrapping layout (tags, stats).
struct VideoFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = measure(view, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
        return CGSize(width: width, height: subviews.isEmpty ? 0 : y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = measure(view, maxWidth: bounds.width)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func measure(_ view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, ideal.width > maxWidth else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

// MARK: - Picture viewer

struct VideoImageViewerItem: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

/// Full-screen paged picture viewer (pinch / double-tap zoom, tap to close, save to album).
struct VideoImageViewer: View {
    let urls: [String]
    @State private var index: Int
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    init(item: VideoImageViewerItem) {
        urls = item.urls
        _index = State(initialValue: min(max(0, item.index), max(0, item.urls.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { i in
                    VideoZoomableImage(url: urls[i], onSingleTap: { dismiss() })
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                    Spacer()
                    if urls.count > 1 {
                        Text("\(index + 1)/\(urls.count)")
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                    }
                    Spacer()
                    Button { save() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                }
                .foregroundColor(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if let notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .padding(.bottom, 40)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
    }

    private func save() {
        guard urls.indices.contains(index) else { return }
        let url = urls[index]
        Task { @MainActor in
            if let image = await ImagePipeline.shared.image(for: url) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                show("已保存到相册")
            } else {
                show("图片加载失败")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

/// UIScrollView-backed zoomable image page.
struct VideoZoomableImage: UIViewRepresentable {
    let url: String
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> VideoZoomScrollView {
        let view = VideoZoomScrollView(frame: .zero)
        view.onSingleTap = onSingleTap
        view.load(url)
        return view
    }

    func updateUIView(_ uiView: VideoZoomScrollView, context: Context) {
        uiView.onSingleTap = onSingleTap
        if uiView.loadedURL != url { uiView.load(url) }
    }
}

final class VideoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onSingleTap: (() -> Void)?
    private(set) var loadedURL = ""
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ url: String) {
        loadedURL = url
        loadTask?.cancel()
        setZoomScale(minimumZoomScale, animated: false)
        if let cached = ImagePipeline.shared.cached(url) {
            imageView.image = cached
            spinner.stopAnimating()
            return
        }
        imageView.image = nil
        spinner.startAnimating()
        loadTask = Task { @MainActor [weak self] in
            let image = await ImagePipeline.shared.image(for: url)
            guard let self, !Task.isCancelled, self.loadedURL == url else { return }
            self.spinner.stopAnimating()
            self.imageView.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale + 0.001 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: true)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }
}
