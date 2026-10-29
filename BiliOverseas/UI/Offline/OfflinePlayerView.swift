import SwiftUI
import UIKit

/// Plays a cached part with the normal player (`PlaybackItem.localFileURL`: no playurl, proxy or heartbeat, works
/// without a network) — `Route.offlinePlayer`. Below the player: the video's info, 查看视频详情 / 删除缓存, and the
/// other cached parts of the same video (auto-next plays them in order).
struct OfflinePlayerView: View {
    @StateObject private var model: OfflinePlayerModel
    @StateObject private var player = PlayerController()
    /// Stops the player when SwiftUI drops this page's state (a pop-to-root while covered sends no `onDisappear`).
    @StateObject private var lifetime = OfflinePlayerLifetime()
    @ObservedObject private var manager = OfflineDownloadManager.shared
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    /// Navigation depth when this page first appeared (to tell "popped" from "covered").
    @State private var stackDepth: Int?
    @State private var resumeOnAppear = false
    @State private var confirmDelete = false

    init(taskId: String) {
        _model = StateObject(wrappedValue: OfflinePlayerModel(taskId: taskId))
    }

    var body: some View {
        GeometryReader { geo in
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    PlayerContainerView(controller: player)
                    if player.item == nil {
                        placeholder
                    }
                }
                .frame(width: geo.size.width, height: playerHeight(width: geo.size.width, fullHeight: fullHeight))
                ScrollView {
                    info
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("离线播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if stackDepth == nil { stackDepth = router.path.count }
            if lifetime.onRelease == nil {
                // The player too (the model only holds it weakly): it must outlive the page's state until
                // the position is saved and playback stopped.
                let pageModel = model, pagePlayer = player
                lifetime.onRelease = {
                    Task { @MainActor in
                        pageModel.close()
                        pagePlayer.stop()
                    }
                }
            }
            model.attach(player)
            if resumeOnAppear {
                resumeOnAppear = false
                // Not when the part was deleted meanwhile (离线缓存 pushed on top).
                if model.current != nil { player.play() }
            }
        }
        .onDisappear {
            // The player's own fullscreen presentation hides this page; never touch playback then.
            if player.isFullscreen { return }
            if let depth = stackDepth, router.path.count < depth {
                model.close()
                return
            }
            if player.isPiPActive { return }
            model.savePosition()
            if player.wantsToPlay {
                resumeOnAppear = true
                player.pause()
            }
        }
        .onChange(of: model.current == nil) { deleted in
            // Deleted in 离线缓存 while this page is open (covered, or playing in Picture in Picture): never go
            // on playing a removed file.
            if deleted { player.stop() }
        }
        .confirmationDialog("确定删除这个缓存吗？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除缓存", role: .destructive) {
                model.deleteCurrent()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 16:9, vertical videos taller (as on the video page), at most 65 % of the screen.
    private func playerHeight(width: CGFloat, fullHeight: CGFloat) -> CGFloat {
        let horizontal = (width * 9 / 16).rounded()
        guard fullHeight > 0 else { return horizontal }
        let cap = (fullHeight * 0.65).rounded()
        guard model.current?.isVertical == true else { return min(horizontal, cap) }
        let shortest = min(width, fullHeight)
        let longest = max(width, fullHeight)
        return min(max(horizontal, min(max(longest * 0.65, shortest), cap).rounded()), cap)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let task = model.current {
            OfflineCoverView(task: task)
                .opacity(0.45)
                .allowsHitTesting(false)
        }
    }

    // MARK: Info

    @ViewBuilder
    private var info: some View {
        if let task = model.current {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(3)
                    if !task.displayPart.isEmpty {
                        Text(task.displayPart)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Text(detailLine(task))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button {
                        router.push(.video(task.videoRef))
                    } label: {
                        Label("查看视频详情", systemImage: "play.rectangle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除缓存", systemImage: "trash")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .tint(.biliPink)
                if model.siblings.count > 1 {
                    partsList
                }
            }
            .padding(12)
        } else {
            StateMessageView(systemImage: "exclamationmark.triangle", message: "缓存已删除")
                .frame(height: 240)
        }
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已缓存的分P（\(model.siblings.count)）")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 6)
            ForEach(model.siblings) { part in
                Button {
                    model.play(part.id)
                } label: {
                    partRow(part, selected: part.id == model.currentId)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func partRow(_ part: OfflineTask, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text("P\(part.page)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(minWidth: 34, alignment: .leading)
            Text(part.partTitle.isEmpty ? "P\(part.page)" : part.partTitle)
                .font(.system(size: 14))
                .lineLimit(2)
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
            } else if part.duration > 0 {
                Text(Fmt.duration(part.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(selected ? .biliPink : .primary)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 「UP主 · 1080P 高清 · 120.3 MB · 缓存于 2026-10-29 18:30」.
    private func detailLine(_ task: OfflineTask) -> String {
        var parts: [String] = []
        if !task.ownerName.isEmpty { parts.append(task.ownerName) }
        if !task.qualityTitle.isEmpty { parts.append(task.qualityTitle) }
        if task.totalBytes > 0 { parts.append(Fmt.bytes(Double(task.totalBytes))) }
        if let at = task.completedAt { parts.append("缓存于 \(Fmt.dateTime(Int64(at.timeIntervalSince1970)))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Model

/// The part on screen, its cached siblings, playback and the saved position.
@MainActor
final class OfflinePlayerModel: ObservableObject {
    @Published private(set) var currentId: String
    private let manager: OfflineDownloadManager
    private weak var player: PlayerController?
    private var started = false

    init(taskId: String) {
        currentId = taskId
        manager = OfflineDownloadManager.shared
    }

    var current: OfflineTask? { manager.task(id: currentId) }

    /// Cached parts of the same video, in part order.
    var siblings: [OfflineTask] {
        guard let task = current else { return [] }
        return manager.completedTasks.filter { $0.aid == task.aid && $0.bvid == task.bvid }.sorted { $0.page < $1.page }
    }

    func attach(_ player: PlayerController) {
        self.player = player
        player.onEnded = { [weak self] in
            Task { @MainActor in self?.advance() }
        }
        // 列表循环 with a single cached part: the player loops it itself (the screen lock stays).
        player.loopsAtEnd = { [weak self] in self?.loopsAlone ?? false }
        guard !started else { return }
        started = true
        play(currentId)
    }

    func play(_ id: String) {
        guard let player else { return }
        guard let task = manager.task(id: id), let file = manager.localFileURL(for: task) else {
            ToastCenter.shared.show("缓存文件不存在，请重新缓存")
            return
        }
        if id != currentId { savePosition() }
        currentId = id
        player.load(Self.playbackItem(task, file: file))
        updateNext()
    }

    /// The current part finished: 「播放顺序」 as on the video page — 播完暂停 stops, 顺序播放 / 自动连播 play the next
    /// cached part, 列表循环 wraps to the first (单个循环 is replayed by the player itself).
    func advance() {
        manager.savePosition(currentId, seconds: 0)
        let next: OfflineTask?
        switch AppSettings.shared.player.playRepeat {
        case .pause, .singleCycle:
            return
        case .listOrder, .autoPlayRelated:
            next = nextPart()
        case .listCycle:
            guard current != nil else { return }
            next = nextPart() ?? siblings.first.flatMap { $0.id == currentId ? nil : $0 }
            if next == nil {
                // The only cached part (normally looped by the player, `loopsAlone`).
                player?.play()
                return
            }
        }
        guard let next else { return }
        play(next.id)
    }

    /// 列表循环 and no other cached part of this video to go to.
    private var loopsAlone: Bool {
        AppSettings.shared.player.playRepeat == .listCycle && current != nil
            && siblings.allSatisfy { $0.id == currentId }
    }

    func savePosition() {
        guard let player, let item = player.item, item.localFileURL != nil else { return }
        let id = OfflineTask.makeID(aid: item.aid, bvid: item.bvid, cid: item.cid)
        manager.savePosition(id, seconds: player.currentTime)
    }

    /// The page was popped.
    func close() {
        savePosition()
        player?.stop()
    }

    func deleteCurrent() {
        player?.stop()
        manager.delete([currentId])
    }

    private func nextPart() -> OfflineTask? {
        let list = siblings
        guard let i = list.firstIndex(where: { $0.id == currentId }), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    private func updateNext() {
        player?.onNext = nextPart() == nil ? nil : { [weak self] in
            Task { @MainActor in
                guard let self, let next = self.nextPart() else { return }
                self.play(next.id)
            }
        }
    }

    /// Contract 1: the normal player with `localFileURL` set; starts at the saved position (0 = the beginning).
    static func playbackItem(_ task: OfflineTask, file: URL) -> PlaybackItem {
        var item = PlaybackItem(aid: task.aid, bvid: task.bvid, cid: task.cid, title: task.title)
        item.subtitle = task.displayPart
        item.cover = task.cover
        item.ownerName = task.ownerName
        item.ownerMid = task.ownerMid
        item.duration = task.duration
        item.isVertical = task.isVertical
        item.startTime = task.resumePosition
        item.localFileURL = file
        return item
    }
}

/// Owned as a `@StateObject`, so it is released exactly when the page's state goes away (see
/// `VideoDetailPageLifetime`): the player is stopped and the position saved even without an `onDisappear`.
final class OfflinePlayerLifetime: ObservableObject {
    /// Set on the main actor by the page; must hop to the main actor itself.
    var onRelease: (() -> Void)?

    deinit {
        onRelease?()
    }
}
