import SwiftUI
import UIKit

/// 缓存 in the video page's action row (UGC videos; nothing for bangumi). Opens `OfflineCacheSheet`; shows
/// 「已缓存」 (pink) / 「缓存中」 for the part on screen.
struct OfflineCacheActionItem: View {
    @ObservedObject var model: VideoDetailModel
    @ObservedObject private var manager = OfflineDownloadManager.shared
    @EnvironmentObject private var router: TabRouter
    @State private var showsSheet = false

    var body: some View {
        if let detail = model.detail, !model.isPGC {
            let state = partState(detail)
            Button {
                open(detail, state: state)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: state == .completed ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 20))
                        .frame(width: 26, height: 26)
                    Text(title(state))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundColor(state == .completed ? .biliPink : Color.primary.opacity(0.75))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("离线缓存")
            .sheet(isPresented: $showsSheet) {
                OfflineCacheSheet(detail: detail, currentCid: model.currentCid, onShowList: { [router] in
                    router.push(.offline)
                })
            }
        }
    }

    /// The sheet while some part can still be queued; otherwise a toast leading to 离线缓存.
    private func open(_ detail: VideoDetail, state: OfflineTaskState?) {
        let cids = detail.pages.isEmpty ? [detail.cid] : detail.pages.map(\.cid)
        let queueable = cids.contains { cid in
            guard let task = manager.task(aid: detail.aid, bvid: detail.bvid, cid: cid) else { return true }
            return task.state == .paused || task.state == .failed
        }
        if queueable {
            showsSheet = true
            return
        }
        let router = self.router
        ToastCenter.shared.show(state == .completed ? "已缓存，可在「离线缓存」中观看" : "已在缓存列表中",
                                duration: 3, actionTitle: "查看") { router.push(.offline) }
    }

    private func partState(_ detail: VideoDetail) -> OfflineTaskState? {
        let cid = model.currentCid != 0 ? model.currentCid : detail.cid
        return manager.task(aid: detail.aid, bvid: detail.bvid, cid: cid)?.state
    }

    private func title(_ state: OfflineTaskState?) -> String {
        switch state {
        case .completed: return "已缓存"
        case .downloading, .waiting: return "缓存中"
        default: return "缓存"
        }
    }
}

/// The 缓存 sheet: 清晰度 (≤ 1080P, the single-file MP4's ceiling) and, for multi-part videos, which parts to cache
/// (the part on screen preselected; parts already in the list are marked).
struct OfflineCacheSheet: View {
    let detail: VideoDetail
    let currentCid: Int64
    /// 「查看」 on the confirmation toast.
    var onShowList: () -> Void = {}

    @ObservedObject private var manager = OfflineDownloadManager.shared
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var qualities = OfflineProgressiveSource.fallbackQualities
    @State private var quality: Int
    @State private var selected: Set<Int64>
    @State private var loadingQualities = true

    /// The last quality picked here (per device).
    static let qualityKey = "offline.cacheQuality"

    init(detail: VideoDetail, currentCid: Int64, onShowList: @escaping () -> Void = {}) {
        self.detail = detail
        self.currentCid = currentCid
        self.onShowList = onShowList
        let saved = UserDefaults.standard.integer(forKey: Self.qualityKey)
        let preferred = saved > 0 ? saved : AppSettings.shared.player.preferredQuality
        _quality = State(initialValue: min(preferred, OfflineProgressiveSource.maxQuality))
        _selected = State(initialValue: [currentCid != 0 ? currentCid : detail.cid])
    }

    private var parts: [VideoPart] {
        detail.pages.isEmpty ? [VideoPart(cid: detail.cid, page: 1, part: "", duration: detail.duration)] : detail.pages
    }

    /// Selected parts that would be queued (not cached or caching already).
    private var queueable: [VideoPart] {
        parts.filter { selected.contains($0.cid) && canQueue($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(qualities) { option in
                        qualityRow(option)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("清晰度")
                        if loadingQualities { ProgressView().scaleEffect(0.7) }
                    }
                } footer: {
                    Text("缓存为单个 MP4 文件（最高 1080P），通过加速线路多连接下载，没有网络时也能播放。")
                }
                if parts.count > 1 {
                    Section {
                        ForEach(parts) { part in
                            partRow(part)
                        }
                    } header: {
                        HStack {
                            Text("选择分P（\(parts.count)）")
                            Spacer()
                            Button(allSelected ? "取消全选" : "全选") { toggleAll() }
                                .font(.caption)
                                .foregroundColor(.biliPink)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("离线缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                startBar
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
        .task { await loadQualities() }
    }

    // MARK: Rows

    private func qualityRow(_ option: QualityOption) -> some View {
        let ok = playable(option)
        return Button {
            quality = option.qn
        } label: {
            HStack(spacing: 8) {
                Text(option.title)
                    .foregroundColor(ok ? .primary : .secondary)
                if let badge = badge(option) {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.biliPink)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliPink, lineWidth: 0.5))
                }
                Spacer()
                if option.qn == quality {
                    Image(systemName: "checkmark")
                        .foregroundColor(.biliPink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ok)
    }

    private func partRow(_ part: VideoPart) -> some View {
        let existing = manager.task(aid: detail.aid, bvid: detail.bvid, cid: part.cid)
        let locked = !canQueue(part)
        let on = locked || selected.contains(part.cid)
        return Button {
            if selected.contains(part.cid) { selected.remove(part.cid) } else { selected.insert(part.cid) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(locked ? .secondary : on ? .biliPink : .secondary)
                Text("P\(part.page)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 30, alignment: .leading)
                Text(part.part.isEmpty ? "P\(part.page)" : part.part)
                    .font(.system(size: 14))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let existing {
                    Text(stateLabel(existing.state))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if part.duration > 0 {
                    Text(Fmt.duration(part.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(part.cid == currentCid ? .biliPink : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private var startBar: some View {
        VStack(spacing: 6) {
            Button {
                start()
            } label: {
                Text(queueable.count > 1 ? "开始缓存（\(queueable.count)）" : "开始缓存")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(queueable.isEmpty)
            if let free = manager.freeDiskBytes {
                Text("手机剩余空间 \(OfflineFormat.storage(free))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: Logic

    private var allSelected: Bool {
        parts.filter(canQueue).allSatisfy { selected.contains($0.cid) }
    }

    private func toggleAll() {
        if allSelected {
            selected = []
        } else {
            selected = Set(parts.filter(canQueue).map(\.cid))
        }
    }

    /// A part not in the list, or one that is paused / failed (queueing resumes it).
    private func canQueue(_ part: VideoPart) -> Bool {
        guard let task = manager.task(aid: detail.aid, bvid: detail.bvid, cid: part.cid) else { return true }
        return task.state == .paused || task.state == .failed
    }

    private func playable(_ option: QualityOption) -> Bool {
        if option.needLogin && !auth.isLoggedIn { return false }
        if option.needVip && !(auth.profile?.isVip ?? false) { return false }
        return true
    }

    private func badge(_ option: QualityOption) -> String? {
        if option.needVip { return "大会员" }
        if option.needLogin && !auth.isLoggedIn { return "登录" }
        return nil
    }

    private func stateLabel(_ state: OfflineTaskState) -> String {
        switch state {
        case .completed: return "已缓存"
        case .downloading: return "缓存中"
        case .waiting: return "等待缓存"
        case .paused: return "已暂停"
        case .failed: return "缓存失败"
        }
    }

    /// The tiers playurl offers for this part (≤ 1080P); the pick falls back to the best playable one.
    private func loadQualities() async {
        manager.refreshStorage()
        defer { loadingQualities = false }
        let cid = currentCid != 0 ? currentCid : detail.cid
        guard let info = try? await VideoAPI.progressivePlayInfo(aid: detail.aid, bvid: detail.bvid, cid: cid,
                                                                 qn: OfflineProgressiveSource.maxQuality) else { return }
        let options = OfflineProgressiveSource.cacheQualities(from: info)
        qualities = options
        if !options.contains(where: { $0.qn == quality && playable($0) }) {
            let usable = options.filter(playable)
            quality = OfflineProgressiveSource.defaultQuality(usable.isEmpty ? options : usable, preferred: quality)
        }
    }

    private func start() {
        let title = qualities.first { $0.qn == quality }?.title ?? VideoQuality.title(for: quality)
        let tasks = queueable.map { OfflineTask(detail: detail, part: $0, quality: quality, qualityTitle: title) }
        guard !tasks.isEmpty else { return }
        UserDefaults.standard.set(quality, forKey: Self.qualityKey)
        manager.enqueue(tasks)
        OfflineCoverStore.save(for: tasks)
        let show = onShowList
        ToastCenter.shared.show(tasks.count > 1 ? "已加入缓存列表（\(tasks.count)个）" : "已加入缓存列表",
                                duration: 3, actionTitle: "查看", action: show)
        dismiss()
    }
}
