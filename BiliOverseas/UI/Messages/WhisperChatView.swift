import SwiftUI
import UIKit

// MARK: - Model

/// One 私信 conversation: the newest page first, older pages on demand, read state acknowledged up to the
/// newest message, and text sending for one-to-one conversations.
@MainActor
final class WhisperChatModel: ObservableObject {
    static let maxLength = 500

    let peer: WhisperPeer

    /// Oldest first.
    @Published private(set) var messages: [WhisperMessage] = []
    /// Emote token → URL, collected from every loaded page.
    @Published private(set) var emotes: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var hasMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var peerName: String
    @Published private(set) var peerFace: String
    /// Bumped when new messages arrive at the bottom (the view scrolls down).
    @Published private(set) var bottomToken = 0

    private var minSeqno: Int64 = 0
    private var maxSeqno: Int64 = 0
    private var ackedSeqno: Int64 = 0
    private var withdrawn: Set<String> = []
    /// Bumped by `accountChanged`: pages requested for the previous account are dropped.
    private var generation = 0

    init(peer: WhisperPeer) {
        self.peer = peer
        peerName = peer.name
        peerFace = peer.face
    }

    var title: String {
        if !peerName.isEmpty { return peerName }
        return peer.talkerId > 0 ? "UID:\(peer.talkerId)" : "私信"
    }

    var myMid: Int64 { AuthService.shared.mid }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        if peer.sessionType == 1, peerName.isEmpty || peerFace.isEmpty {
            Task { await loadPeerInfo() }
        }
        await loadLatest()
    }

    private func loadPeerInfo() async {
        guard let user = await MessageAPI.userInfos(mids: [peer.talkerId])[peer.talkerId] else { return }
        if peerName.isEmpty { peerName = user.name }
        if peerFace.isEmpty { peerFace = user.face }
    }

    /// Another account signed in (or the user signed out): this conversation belonged to the previous one.
    /// Drops everything shown; `loadIfNeeded` loads it again for the current account.
    func accountChanged() {
        generation += 1
        messages = []
        emotes = [:]
        withdrawn = []
        minSeqno = 0
        maxSeqno = 0
        ackedSeqno = 0
        hasMore = false
        didLoad = false
        errorMessage = nil
        isLoading = false
        isLoadingOlder = false
    }

    /// Loads the newest page and merges it below what is shown (first load, refresh, after sending).
    func loadLatest() async {
        isLoading = true
        errorMessage = nil
        let gen = generation
        do {
            let page = try await MessageAPI.messages(peer: peer)
            guard gen == generation else { return }
            if messages.isEmpty || page.minSeqno > maxSeqno {
                // First page, or more arrived than one page holds: start over from the newest page.
                messages = []
                withdrawn = []
                minSeqno = page.minSeqno
                hasMore = page.hasMore
            }
            merge(page)
            didLoad = true
            bottomToken += 1
            isLoading = false
            await acknowledge()
        } catch {
            guard gen == generation else { return }
            if !ListMapping.isCancellation(error) {
                if messages.isEmpty { errorMessage = error.localizedDescription } else { ToastCenter.shared.show(error: error) }
                didLoad = true
            }
            isLoading = false
        }
    }

    /// The page before the oldest shown message.
    func loadOlder() async {
        guard didLoad, hasMore, !isLoadingOlder, !isLoading, minSeqno > 0 else { return }
        isLoadingOlder = true
        let gen = generation
        do {
            let page = try await MessageAPI.messages(peer: peer, before: minSeqno)
            guard gen == generation else { return }
            let before = messages.count
            merge(page)
            if page.minSeqno > 0 { minSeqno = min(minSeqno, page.minSeqno) }
            // An older page that adds nothing (end_seqno is inclusive) is the end.
            hasMore = page.hasMore && messages.count > before
        } catch {
            guard gen == generation else { return }
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
        }
        isLoadingOlder = false
    }

    private func merge(_ page: WhisperMessagePage) {
        withdrawn.formUnion(page.withdrawnKeys)
        emotes.merge(page.emotes) { current, _ in current }
        var byId: [String: WhisperMessage] = [:]
        for m in messages { byId[m.id] = m }
        for m in page.messages { byId[m.id] = m }
        var all = Array(byId.values)
        for i in all.indices where withdrawn.contains(all[i].msgKey) { all[i].isWithdrawn = true }
        all.sort { $0.seqno != $1.seqno ? $0.seqno < $1.seqno : $0.id < $1.id }
        messages = all
        maxSeqno = max(maxSeqno, page.maxSeqno)
    }

    private func acknowledge() async {
        let seqno = maxSeqno
        let gen = generation
        guard seqno > ackedSeqno else { return }
        if await MessageAPI.ack(peer: peer, seqno: seqno), gen == generation {
            ackedSeqno = max(ackedSeqno, seqno)
            await MessageUnreadStore.shared.refresh(force: true)
        }
    }

    /// Sends `text`; true on success (the newest page is reloaded to show it).
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, peer.canSend else { return false }
        guard trimmed.count <= Self.maxLength else {
            ToastCenter.shared.show("消息不能超过\(Self.maxLength)字")
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            try await MessageAPI.sendText(trimmed, to: peer.talkerId)
        } catch {
            if !ListMapping.isCancellation(error) { ToastCenter.shared.show(error: error) }
            return false
        }
        await loadLatest()
        return true
    }
}

// MARK: - Screen

/// 私信 conversation: newest messages at the bottom, older ones load when scrolling to the top. One-to-one
/// conversations get the input bar; 应援团 groups are read-only.
struct WhisperChatView: View {
    let peer: WhisperPeer

    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var auth = AuthService.shared
    @StateObject private var model: WhisperChatModel
    @State private var draft = ""
    @State private var viewer: VideoImageViewerItem?
    @State private var thread: MessageThreadSheetItem?
    /// The first page was scrolled to the bottom; only then may the top row load older messages.
    @State private var settled = false
    /// The 「load older」 spinner at the top is on screen.
    @State private var topVisible = false
    @FocusState private var inputFocused: Bool

    private let bottomID = "whisper-bottom"

    init(peer: WhisperPeer) {
        self.peer = peer
        _model = StateObject(wrappedValue: WhisperChatModel(peer: peer))
    }

    var body: some View {
        Group {
            if auth.isLoggedIn {
                content
            } else {
                LoginRequiredView(message: "登录后查看私信")
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if peer.sessionType == 1, peer.talkerId > 0 {
                    Button {
                        router.push(.user(mid: peer.talkerId))
                    } label: {
                        Image(systemName: "person.circle")
                    }
                    .accessibilityLabel("个人空间")
                }
            }
        }
        // Login / logout / 切换账号: what is shown is the previous account's conversation.
        .onReceive(NotificationCenter.default.publisher(for: AuthService.loginStateDidChange)) { _ in
            model.accountChanged()
            settled = false
            if auth.isLoggedIn { Task { await model.loadIfNeeded() } }
        }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .onAppear {
                                topVisible = true
                                loadOlder(proxy)
                            }
                            .onDisappear { topVisible = false }
                    }
                    if let error = model.errorMessage, model.messages.isEmpty {
                        StateMessageView(systemImage: "exclamationmark.bubble", message: error) {
                            Task { await model.loadLatest() }
                        }
                        .frame(minHeight: 320)
                    } else if model.didLoad, model.messages.isEmpty {
                        Text("还没有消息，打个招呼吧")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if !model.didLoad {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        if WhisperTime.startsGroup(model.messages, at: index) {
                            Text(WhisperTime.label(message.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        messageRow(message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 8)
                        .id(bottomID)
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.bottomToken) { _ in
                scrollToBottom(proxy, settle: true)
            }
            .onChange(of: inputFocused) { focused in
                if focused { scrollToBottom(proxy, settle: false) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if peer.canSend { inputBar }
        }
        .task { await model.loadIfNeeded() }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .fullScreenCover(item: $viewer) { item in
            VideoImageViewer(item: item)
        }
        .messageThreadSheet($thread, router: router)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, settle: Bool) {
        Task { @MainActor in
            // Let the new rows lay out first.
            try? await Task.sleep(nanoseconds: 60_000_000)
            proxy.scrollTo(bottomID, anchor: .bottom)
            if settle && !settled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                settled = true
                // A first page shorter than the screen leaves the spinner visible: its onAppear came before
                // `settled` and will not fire again, so start the older page here.
                if topVisible { loadOlder(proxy) }
            }
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard settled, !model.isLoadingOlder else { return }
        let anchor = model.messages.first?.id
        Task {
            await model.loadOlder()
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func messageRow(_ message: WhisperMessage) -> some View {
        let mine = message.senderUid != 0 && message.senderUid == model.myMid
        if message.isWithdrawn {
            centeredHint(mine ? "你撤回了一条消息" : "对方撤回了一条消息")
        } else {
            switch message.body {
            case .tip(let text):
                centeredHint(text)
            case .notice(let notice):
                WhisperNoticeCard(notice: notice, open: open)
                    .padding(.vertical, 6)
            default:
                bubbleRow(message, mine: mine)
            }
        }
    }

    private func centeredHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func bubbleRow(_ message: WhisperMessage, mine: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 44)
            } else {
                avatar(model.peerFace)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                bubbleContent(message, mine: mine)
                if message.isAutoReply {
                    Text("此条消息为自动回复")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if mine {
                avatar(auth.profile?.face ?? "")
            } else {
                Spacer(minLength: 44)
            }
        }
        .padding(.vertical, 6)
    }

    private func avatar(_ url: String) -> some View {
        AvatarView(url: url, size: 36)
    }

    @ViewBuilder
    private func bubbleContent(_ message: WhisperMessage, mine: Bool) -> some View {
        switch message.body {
        case .text(let text):
            WhisperTextBubble(text: text, emotes: model.emotes, mine: mine)
        case .image(let url, let width, let height):
            let size = Self.imageSize(width: width, height: height)
            RemoteImage(url: url, width: size.width)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { viewer = VideoImageViewerItem(urls: [url], index: 0) }
        case .card(let card):
            WhisperCardView(card: card, open: open)
        default:
            WhisperTextBubble(text: "[暂不支持的消息，请在官方客户端查看]", emotes: [:], mine: mine)
                .opacity(0.7)
        }
    }

    /// Picture size in points: up to 200 wide / 240 tall, keeping the aspect ratio.
    static func imageSize(width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: 160, height: 160) }
        let ratio = CGFloat(height) / CGFloat(width)
        var w = min(200, CGFloat(width))
        var h = w * ratio
        if h > 240 {
            h = 240
            w = h / ratio
        }
        return CGSize(width: max(60, w), height: max(40, h))
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发个消息聊聊呗~", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Button(action: send) {
                Group {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Text("发送")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(minWidth: 44, minHeight: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(trimmedDraft.isEmpty ? Color.secondary : Color.biliPink)
            .disabled(trimmedDraft.isEmpty || model.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        Task {
            if await model.send(text) { draft = "" }
        }
    }

    // MARK: Links

    private func open(_ link: MessageLink) {
        if case .comments(let t) = link {
            thread = MessageThreadSheetItem(thread: t)
        } else if let route = MessageRoutes.route(for: link) {
            router.push(route)
        }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch VideoRichText.target(for: url) {
        case .route(let route):
            // bilibili.com links VideoRichText leaves to the web view may still be dynamics, threads …
            if case .web(let u) = route, let link = MessageLinks.resolve(u.absoluteString) {
                open(link)
            } else {
                router.push(route)
            }
            return .handled
        case .seek, .ignore:
            return .discarded
        case .system:
            return .systemAction
        }
    }
}

// MARK: - Pieces

/// A text bubble with inline emotes and tappable links (pink for my messages).
struct WhisperTextBubble: View {
    let text: String
    let emotes: [String: String]
    let mine: Bool

    @State private var images: [String: UIImage] = [:]

    private var usedEmotes: [String: String] {
        emotes.filter { text.contains($0.key) }
    }

    var body: some View {
        VideoRichText.text(VideoRichText.segments(text, emotes: usedEmotes, timestamps: false), emotes: images)
            .font(.system(size: 15))
            .foregroundStyle(mine ? Color.white : Color.primary)
            .tint(mine ? Color.white : Color.biliBlue)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(mine ? Color.biliPink : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                    ToastCenter.shared.show("已复制")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
            .task(id: text) {
                let used = usedEmotes
                guard !used.isEmpty else { return }
                let loaded = await VideoEmoteImages.load(used, height: 20)
                if !Task.isCancelled, !loaded.isEmpty { images = loaded }
            }
    }
}

/// Shared video / article / dynamic / live card.
struct WhisperCardView: View {
    let card: WhisperCard
    let open: (MessageLink) -> Void

    var body: some View {
        Button {
            if let link = card.link { open(link) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if !card.cover.isEmpty {
                    RemoteImage(url: card.cover, width: 240)
                        .frame(width: 240, height: card.title.isEmpty ? 240 : 135)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            if card.duration > 0 {
                                Text(Fmt.duration(card.duration))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(6)
                            }
                        }
                }
                if !card.title.isEmpty || !card.subtitle.isEmpty || !card.note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !card.title.isEmpty {
                            Text(card.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if !card.subtitle.isEmpty {
                            Text(card.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if !card.note.isEmpty {
                            Text(card.note)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(10)
                    .frame(width: 240, alignment: .leading)
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Notification card (系统消息 / 订单 …): title, text, key-value rows and its actions.
struct WhisperNoticeCard: View {
    let notice: WhisperNotice
    let open: (MessageLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !notice.title.isEmpty {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
            }
            if !notice.text.isEmpty {
                Text(notice.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            ForEach(Array(notice.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top, spacing: 10) {
                    Text(field.title)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(field.detail)
                }
                .font(.caption)
            }
            ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, action in
                Divider()
                Button {
                    if let link = action.link { open(link) }
                } label: {
                    HStack {
                        Text(action.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(action.link == nil ? Color.secondary : Color.biliBlue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(action.link == nil)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity)
    }
}
