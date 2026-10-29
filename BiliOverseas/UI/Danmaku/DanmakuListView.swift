import SwiftUI

/// 「弹幕列表」 (features.md §3.8 #16, §8.6): the danmaku on screen and those of the last 30 s before the current
/// position, newest first, as a snapshot (「刷新」 takes a new one). Rows offer 点赞 (with the count) and 举报 —
/// 撤回 for own danmaku —; a long press opens 复制, 跳转 and 屏蔽. Present it as a sheet
/// (`PlayerSheet.danmakuList`); it has its own navigation bar with 「完成」.
struct DanmakuListView: View {
    let player: PlayerController

    @Environment(\.dismiss) private var dismiss
    @State private var items: [DanmakuItem] = []
    @State private var likes: [Int64: DanmakuLikeState] = [:]
    @State private var pending: Set<Int64> = []
    @State private var snapshotTime: Double = 0
    @State private var reportTarget: DanmakuItem?
    @State private var recallTarget: DanmakuItem?

    /// Seconds before the current position that are listed.
    static let window: Double = 30

    init(player: PlayerController) {
        self.player = player
    }

    private var overlay: DanmakuOverlayView { player.surface.danmaku }
    private var cid: Int64 { player.item?.cid ?? 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        Text(AppSettings.shared.danmaku.enabled ? "这段时间没有弹幕" : "弹幕已关闭，打开弹幕后可查看")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            row(item)
                        }
                    }
                } header: {
                    Text(verbatim: "\(PlayerFormat.time(max(0, snapshotTime - DanmakuListView.window))) – \(PlayerFormat.time(snapshotTime))")
                } footer: {
                    Text("长按弹幕可复制、跳转或屏蔽。点赞、举报和撤回需要登录。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("弹幕列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("刷新", action: reload)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("举报弹幕", isPresented: isPresented($reportTarget), titleVisibility: .visible,
                                presenting: reportTarget) { item in
                ForEach(DanmakuService.reportReasons) { reason in
                    Button(reason.title) { report(item, reason: reason.id) }
                }
                Button("取消", role: .cancel) {}
            } message: { item in
                Text(verbatim: item.readableText)
            }
            .confirmationDialog("撤回这条弹幕？", isPresented: isPresented($recallTarget), titleVisibility: .visible,
                                presenting: recallTarget) { item in
                Button("撤回", role: .destructive) { recall(item) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("每天的撤回次数有限。")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: reload)
    }

    // MARK: Rows

    private func row(_ item: DanmakuItem) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: PlayerFormat.time(item.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(verbatim: item.readableText.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
                .foregroundStyle(item.isSelf ? Color.biliPink : Color.primary)
            Spacer(minLength: 4)
            if item.hasServerID {
                likeButton(item)
                if item.isSelf {
                    iconButton("arrow.uturn.backward", label: "撤回") { recallTarget = item }
                } else {
                    iconButton("exclamationmark.bubble", label: "举报") { askReport(item) }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                DanmakuActions.copy(item)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                seek(to: item.time)
            } label: {
                Label("跳转到这条弹幕", systemImage: "arrow.right.to.line")
            }
            if let target = DanmakuTimestamp.seconds(in: item.readableText, duration: player.duration) {
                Button {
                    seek(to: target)
                } label: {
                    Label("跳转到 \(PlayerFormat.time(target))", systemImage: "scope")
                }
            }
            if !item.isSelf {
                if !item.midHash.isEmpty {
                    Button(role: .destructive) {
                        DanmakuActions.blockSender(item)
                        items.removeAll { $0.midHash == item.midHash }
                    } label: {
                        Label("屏蔽发送者", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                Button(role: .destructive) {
                    DanmakuActions.blockContent(item)
                    let keyword = DanmakuActions.blockKeyword(for: item).lowercased()
                    items.removeAll { $0.readableText.lowercased().contains(keyword) }
                } label: {
                    Label("屏蔽关键词", systemImage: "text.badge.xmark")
                }
            }
        }
    }

    private func likeButton(_ item: DanmakuItem) -> some View {
        let state = likes[item.id] ?? overlay.likeState(of: item)
        return Button {
            like(item)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                if state.count > 0 {
                    Text(verbatim: "\(state.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(state.liked ? Color.biliPink : Color.secondary)
            .frame(minWidth: 34, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(pending.contains(item.id))
        .accessibilityLabel(Text(state.liked ? "取消点赞" : "点赞"))
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 30, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
    }

    // MARK: Actions

    private func reload() {
        snapshotTime = player.displayTime()
        items = overlay.recentItems(before: snapshotTime, window: DanmakuListView.window)
        likes = [:]
    }

    private func like(_ item: DanmakuItem) {
        pending.insert(item.id)
        Task { @MainActor in
            if let state = await DanmakuActions.toggleLike(item, cid: cid, overlay: overlay) { likes[item.id] = state }
            pending.remove(item.id)
        }
    }

    private func askReport(_ item: DanmakuItem) {
        guard BiliHTTP.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录")
            return
        }
        reportTarget = item
    }

    private func report(_ item: DanmakuItem, reason: Int) {
        Task { @MainActor in await DanmakuActions.report(item, cid: cid, reason: reason) }
    }

    private func recall(_ item: DanmakuItem) {
        Task { @MainActor in
            if await DanmakuActions.recall(item, cid: cid, overlay: overlay) { items.removeAll { $0.id == item.id } }
        }
    }

    private func seek(to time: Double) {
        player.seek(to: time)
        dismiss()
    }

    private func isPresented(_ target: Binding<DanmakuItem?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } })
    }
}
