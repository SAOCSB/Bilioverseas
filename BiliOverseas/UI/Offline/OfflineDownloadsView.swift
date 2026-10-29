import SwiftUI
import UIKit

/// 离线缓存 (我的 → 离线缓存, `Route.offline`): 正在缓存 with progress and speed (tap to pause / continue / retry) and
/// 已缓存 (tap to play without a network), swipe to delete, and the space the cache uses.
struct OfflineDownloadsView: View {
    @ObservedObject private var manager = OfflineDownloadManager.shared
    @EnvironmentObject private var router: TabRouter
    @State private var confirmDeleteAll = false

    private let rowInsets = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)

    var body: some View {
        let pending = manager.pendingTasks
        let completed = manager.completedTasks
        List {
            if !manager.tasks.isEmpty {
                Section {
                    OfflineStorageSummary(used: manager.usedBytes, free: manager.freeDiskBytes)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { task in
                        OfflinePendingRow(task: task, speed: manager.speeds[task.id])
                            .contentShape(Rectangle())
                            .onTapGesture { manager.toggle(task.id) }
                            .listRowInsets(rowInsets)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteButton(task) }
                    }
                } header: {
                    HStack {
                        Text("正在缓存（\(pending.count)）")
                        Spacer()
                        Button(manager.isAllPaused ? "全部开始" : "全部暂停") {
                            if manager.isAllPaused { manager.resumeAll() } else { manager.pauseAll() }
                        }
                        .font(.caption)
                        .foregroundColor(.biliPink)
                    }
                }
            }
            if !completed.isEmpty {
                Section {
                    ForEach(completed) { task in
                        NavigationLink(value: Route.offlinePlayer(id: task.id)) {
                            OfflineCompletedRow(task: task)
                        }
                        .listRowInsets(rowInsets)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteButton(task) }
                        .contextMenu {
                            Button {
                                router.push(.video(task.videoRef))
                            } label: {
                                Label("查看视频详情", systemImage: "play.rectangle")
                            }
                            Button(role: .destructive) {
                                manager.delete([task.id])
                            } label: {
                                Label("删除缓存", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("已缓存（\(completed.count)）")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if manager.tasks.isEmpty {
                StateMessageView(systemImage: "arrow.down.circle",
                                 message: "还没有缓存的视频\n在视频页点击「缓存」，没有网络时也能观看")
            }
        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        manager.resumeAll()
                    } label: {
                        Label("全部开始", systemImage: "arrow.down.circle")
                    }
                    .disabled(manager.pendingTasks.isEmpty)
                    Button {
                        manager.pauseAll()
                    } label: {
                        Label("全部暂停", systemImage: "pause.circle")
                    }
                    .disabled(manager.pendingTasks.isEmpty)
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("删除全部缓存", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(manager.tasks.isEmpty)
            }
        }
        .confirmationDialog("确定删除全部缓存吗？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                manager.delete(manager.tasks.map(\.id))
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已下载的视频文件将从手机中移除")
        }
        .onAppear { manager.refreshStorage() }
    }

    private func deleteButton(_ task: OfflineTask) -> some View {
        Button(role: .destructive) {
            manager.delete([task.id])
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

// MARK: - Rows

/// 「已缓存 1.2 GB · 手机剩余 23.4 GB」 with a bar of the cache's share.
struct OfflineStorageSummary: View {
    let used: Int64
    let free: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已缓存 \(Fmt.bytes(Double(used)))")
                Spacer()
                if let free {
                    Text("手机剩余 \(OfflineFormat.storage(free))")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if let free, free + used > 0 {
                GeometryReader { geo in
                    let share = Double(used) / Double(free + used)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(Color.biliPink)
                            .frame(width: max(used > 0 ? 3 : 0, geo.size.width * share))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

/// A download in progress: cover, title, part, progress bar, state / speed and size.
struct OfflinePendingRow: View {
    let task: OfflineTask
    let speed: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OfflineCoverView(task: task)
                .overlay {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(task.displayPart.isEmpty ? 2 : 1)
                if !task.displayPart.isEmpty {
                    Text(task.displayPart)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ProgressView(value: task.progress)
                    .tint(task.state == .failed ? Color(.systemRed) : .biliPink)
                HStack(spacing: 6) {
                    Text(OfflineFormat.status(task, speed: speed))
                        .foregroundColor(task.state == .failed ? Color(.systemRed) : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(OfflineFormat.size(task))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .font(.caption2.monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: OfflineCoverView.height, maxHeight: OfflineCoverView.height,
                   alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(task.state == .paused || task.state == .failed ? "点击继续缓存" : "点击暂停")
    }

    private var stateSymbol: String {
        switch task.state {
        case .downloading: return "pause.circle"
        case .waiting: return "clock"
        case .paused: return "arrow.down.circle"
        case .failed: return "arrow.clockwise.circle"
        case .completed: return "checkmark.circle"
        }
    }
}

/// A cached part: cover with duration, title, part, quality · size and the local progress.
struct OfflineCompletedRow: View {
    let task: OfflineTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OfflineCoverView(task: task)
                .overlay(alignment: .bottomTrailing) {
                    if task.duration > 0 {
                        Text(Fmt.duration(task.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if task.resumePosition > 0, task.duration > 0 {
                        GeometryReader { g in
                            Rectangle()
                                .fill(Color.biliPink)
                                .frame(width: g.size.width * min(1, task.resumePosition / task.duration), height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(task.displayPart.isEmpty ? 2 : 1)
                if !task.displayPart.isEmpty {
                    Text(task.displayPart)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !task.ownerName.isEmpty {
                    Label(task.ownerName, systemImage: "person.crop.square")
                        .labelStyle(CompactLabelStyle())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(OfflineFormat.completedLine(task))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: OfflineCoverView.height, maxHeight: OfflineCoverView.height,
                   alignment: .leading)
        }
    }
}

/// The cover saved next to the video (shown offline), else the network image.
struct OfflineCoverView: View {
    let task: OfflineTask
    static let width: CGFloat = 128
    static let height: CGFloat = 80

    var body: some View {
        Group {
            if let image = OfflineCoverStore.image(for: task.id) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RemoteImage(url: task.cover, width: Self.width)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Text

enum OfflineFormat {
    /// 「缓存中 2.3 MB/s」 / 「等待缓存」 / 「已暂停」 / 「缓存失败：…」.
    static func status(_ task: OfflineTask, speed: Double?) -> String {
        switch task.state {
        case .downloading:
            if let speed, speed > 0 { return "缓存中 \(Fmt.speed(speed))" }
            return task.totalBytes > 0 ? "缓存中" : "正在连接…"
        case .waiting: return "等待缓存"
        case .paused: return "已暂停，点击继续"
        case .failed: return "缓存失败：\(task.errorMessage ?? "请重试")"
        case .completed: return "已缓存"
        }
    }

    /// 「45.2 MB / 120.3 MB」 (only the received bytes while the size is unknown).
    static func size(_ task: OfflineTask) -> String {
        let received = Fmt.bytes(Double(task.receivedBytes))
        guard task.totalBytes > 0 else { return task.receivedBytes > 0 ? received : "" }
        return "\(received) / \(Fmt.bytes(Double(task.totalBytes)))"
    }

    /// 「1080P 高清 · 120.3 MB · 看到 03:12」.
    static func completedLine(_ task: OfflineTask) -> String {
        var parts: [String] = []
        if !task.qualityTitle.isEmpty { parts.append(task.qualityTitle) }
        if task.totalBytes > 0 { parts.append(Fmt.bytes(Double(task.totalBytes))) }
        if task.resumePosition > 0 { parts.append("看到 \(Fmt.duration(task.resumePosition))") }
        return parts.joined(separator: " · ")
    }

    /// GB with one decimal for device storage.
    static func storage(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : Fmt.bytes(Double(bytes))
    }
}

// MARK: - Cover files

/// `cover.jpg` in each task's directory, so 离线缓存 shows covers without a network.
@MainActor
enum OfflineCoverStore {
    static let fileName = "cover.jpg"
    private static let memory = NSCache<NSString, UIImage>()
    /// Ids whose file was looked for and not found (rows re-render twice a second while downloading).
    private static var missing = Set<String>()

    private static func url(for id: String) -> URL {
        OfflineDownloadManager.shared.dependencies.layout.directory(for: id).appendingPathComponent(fileName)
    }

    static func image(for id: String) -> UIImage? {
        if let hit = memory.object(forKey: id as NSString) { return hit }
        if missing.contains(id) { return nil }
        guard let data = try? Data(contentsOf: url(for: id)), let image = UIImage(data: data) else {
            missing.insert(id)
            return nil
        }
        memory.setObject(image, forKey: id as NSString)
        return image
    }

    /// Downloads the (resized) cover once per task, in the background.
    static func save(for tasks: [OfflineTask]) {
        let targets = tasks.filter { !$0.cover.isEmpty }.map { (id: $0.id, cover: $0.cover, file: url(for: $0.id)) }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) {
            for target in targets where !FileManager.default.fileExists(atPath: target.file.path) {
                let thumb = Fmt.thumb(target.cover, width: 384)
                guard let image = await ImagePipeline.shared.image(for: thumb),
                      let data = image.jpegData(compressionQuality: 0.85) else { continue }
                try? FileManager.default.createDirectory(at: target.file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                guard (try? data.write(to: target.file, options: .atomic)) != nil else { continue }
                let id = target.id
                await MainActor.run {
                    missing.remove(id)
                    memory.setObject(image, forKey: id as NSString)
                }
            }
        }
    }
}
