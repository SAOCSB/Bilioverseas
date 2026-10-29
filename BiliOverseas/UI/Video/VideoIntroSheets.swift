import SwiftUI
import UIKit

// MARK: - 投币

/// Coin picker: 1 or 2 coins (reposts allow 1) and 「同时点赞内容」.
struct VideoCoinSheet: View {
    let maxCoins: Int
    let given: Int
    let onConfirm: (Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var count: Int
    @State private var alsoLike = true

    init(maxCoins: Int, given: Int, onConfirm: @escaping (Int, Bool) -> Void) {
        self.maxCoins = max(1, maxCoins)
        self.given = given
        self.onConfirm = onConfirm
        _count = State(initialValue: max(1, min(2, max(1, maxCoins) - given)))
    }

    private var remaining: Int { max(0, maxCoins - given) }

    var body: some View {
        VStack(spacing: 18) {
            Text("给UP主投上\(count)枚硬币")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 24)
            HStack(spacing: 36) {
                option(1)
                if maxCoins >= 2 { option(2) }
            }
            Toggle(isOn: $alsoLike) {
                Text("同时点赞内容").font(.system(size: 14))
            }
            .toggleStyle(.switch)
            .tint(.biliPink)
            .padding(.horizontal, 40)
            Button {
                onConfirm(count, alsoLike)
                dismiss()
            } label: {
                Text("确定")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .disabled(remaining == 0)
            .opacity(remaining == 0 ? 0.5 : 1)
            if maxCoins == 1 {
                Text("本稿件为转载稿件，最多可投1枚硬币")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if given > 0 {
                Text("已投\(given)枚硬币")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
    }

    private func option(_ n: Int) -> some View {
        let enabled = n <= remaining
        let selected = count == n
        return Button {
            count = n
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.biliPink.opacity(0.12) : Color(.secondarySystemBackground))
                        .frame(width: 76, height: 76)
                    Circle()
                        .stroke(selected ? Color.biliPink : Color.clear, lineWidth: 1.5)
                        .frame(width: 76, height: 76)
                    HStack(spacing: -6) {
                        ForEach(0..<n, id: \.self) { _ in
                            VideoCoinGlyph(filled: selected)
                                .scaleEffect(1.3)
                        }
                    }
                    .foregroundColor(.secondary)
                }
                Text("\(n)硬币")
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundColor(selected ? .biliPink : .secondary)
            }
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 收藏

/// Folder picker with membership checkmarks and 新建收藏夹; saves the difference with `VideoAPI.updateFav`.
struct VideoFavFolderSheet: View {
    let rid: Int64
    /// 2 = UGC archive (`aid`), 24 = PGC episode (`ep_id`).
    let resourceType: Int
    let onSaved: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavFolderState] = []
    @State private var selected: Set<Int64> = []
    @State private var original: Set<Int64> = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var saving = false
    @State private var creating = false
    /// The default folder preselected by `load` (nothing was favourited) and not touched since.
    @State private var autoSelected: Int64?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    StateMessageView(systemImage: "exclamationmark.triangle", message: errorText) {
                        Task { await load() }
                    }
                } else {
                    List {
                        createRow
                        ForEach(folders) { folder in
                            row(folder)
                        }
                        if folders.isEmpty {
                            Text("还没有收藏夹")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .sheet(isPresented: $creating) {
                MineFavFolderEditSheet(folder: nil) { title, intro, isPrivate in
                    await createFolder(title: title, intro: intro, isPrivate: isPrivate)
                }
            }
            .navigationTitle("添加到收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("完成") { Task { await save() } }
                            .disabled(loading || errorText != nil)
                    }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private var createRow: some View {
        Button {
            creating = true
        } label: {
            Label("新建收藏夹", systemImage: "plus")
                .font(.system(size: 15))
                .foregroundColor(.biliPink)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    private func row(_ folder: FavFolderState) -> some View {
        let isOn = selected.contains(folder.id)
        return Button {
            autoSelected = nil
            if isOn { selected.remove(folder.id) } else { selected.insert(folder.id) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(folder.title)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if folder.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(folder.isDefault ? "默认收藏夹 · \(folder.count)个内容" : "\(folder.count)个内容")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isOn ? .biliPink : Color(.tertiaryLabel))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            let list = try await VideoAPI.favFolders(forAid: rid, resourceType: resourceType)
            folders = list
            let current = Set(list.filter(\.isFavorited).map(\.id))
            original = current
            selected = current
            autoSelected = nil
            if current.isEmpty, let fallback = list.first(where: \.isDefault) ?? list.first {
                // Like the official picker: preselect the default folder when nothing is selected yet.
                selected = [fallback.id]
                autoSelected = fallback.id
            }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    /// 新建收藏夹 from the picker: listed after the default folder and selected (instead of the default folder
    /// when that was only preselected). `true` closes the editor.
    private func createFolder(title: String, intro: String, isPrivate: Bool) async -> Bool {
        do {
            let folder = try await FavAPI.createFolder(title: title, intro: intro, isPrivate: isPrivate)
            guard folder.id > 0 else { throw BiliError.other("创建收藏夹失败") }
            let state = FavFolderState(id: folder.id, title: folder.title, count: 0, isFavorited: false,
                                       isDefault: false, isPrivate: folder.isPrivate)
            let index = folders.first?.isDefault == true ? 1 : 0
            folders.insert(state, at: min(index, folders.count))
            if let auto = autoSelected, selected == [auto] { selected = [] }
            autoSelected = nil
            selected.insert(folder.id)
            ToastCenter.shared.show("已创建收藏夹")
            return true
        } catch {
            ToastCenter.shared.show(error: error)
            return false
        }
    }

    private func save() async {
        let add = selected.subtracting(original)
        let remove = original.subtracting(selected)
        guard !add.isEmpty || !remove.isEmpty else {
            dismiss()
            return
        }
        saving = true
        do {
            try await VideoAPI.updateFav(aid: rid, add: Array(add), remove: Array(remove), resourceType: resourceType)
            onSaved(!selected.isEmpty)
            ToastCenter.shared.show(selected.isEmpty ? "已取消收藏" : "收藏成功")
            saving = false
            dismiss()
        } catch {
            saving = false
            ToastCenter.shared.show(error: error)
        }
    }
}

// MARK: - 分P

/// Full part list with 正序 / 倒序.
struct VideoPartPickerSheet: View {
    let parts: [VideoPart]
    let currentCid: Int64
    let onSelect: (VideoPart) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reversed = false

    private var ordered: [VideoPart] { reversed ? parts.reversed() : parts }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(ordered) { part in
                        Button {
                            onSelect(part)
                            dismiss()
                        } label: {
                            row(part)
                        }
                        .buttonStyle(.plain)
                        .id(part.cid)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(currentCid, anchor: .center) }
                }
            }
            .navigationTitle("选集（\(parts.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(reversed ? "正序" : "倒序") { reversed.toggle() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
    }

    private func row(_ part: VideoPart) -> some View {
        let selected = part.cid == currentCid
        return HStack(spacing: 10) {
            Text("P\(part.page)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(minWidth: 34, alignment: .leading)
            Text(part.part.isEmpty ? "P\(part.page)" : part.part)
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 合集

/// Every episode of a UGC season, grouped by section.
struct VideoUgcSeasonSheet: View {
    let season: UgcSeason
    let currentAid: Int64
    let onSelect: (UgcEpisode) -> Void

    @Environment(\.dismiss) private var dismiss

    private var currentID: Int64? {
        season.allEpisodes.first(where: { $0.aid == currentAid })?.id
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !season.intro.isEmpty {
                        Text(season.intro)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    ForEach(season.sections) { section in
                        Section {
                            ForEach(section.episodes) { ep in
                                Button {
                                    onSelect(ep)
                                    dismiss()
                                } label: {
                                    row(ep)
                                }
                                .buttonStyle(.plain)
                                .id(ep.id)
                            }
                        } header: {
                            if season.sections.count > 1 {
                                Text(section.title)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    if let id = currentID {
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .navigationTitle(season.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
    }

    private func row(_ ep: UgcEpisode) -> some View {
        let selected = ep.aid == currentAid
        return HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: ep.cover, width: 112)
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    if ep.duration > 0 {
                        Text(Fmt.duration(ep.duration))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(ep.title)
                    .font(.system(size: 14))
                    .foregroundColor(selected ? .biliPink : .primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if selected {
                        Label("播放中", systemImage: "waveform")
                            .foregroundColor(.biliPink)
                    } else if ep.viewCount > 0 {
                        Label(Fmt.count(ep.viewCount), systemImage: "play.rectangle")
                    }
                    if ep.pubdate > 0 { Text(Fmt.relativeDate(ep.pubdate)) }
                }
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - PGC

/// Episode chip: 「第N话」 + long title, badge (会员 / 限免 / 预告) at the top-right.
struct VideoPGCEpisodeChip: View {
    let episode: PGCEpisode
    let isSelected: Bool
    var width: CGFloat? = 118

    private var heading: String {
        if Int(episode.title) != nil { return "第\(episode.title)话" }
        return episode.title.isEmpty ? episode.displayTitle : episode.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heading)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.trailing, episode.badge.isEmpty ? 0 : 26)
            Text(episode.longTitle.isEmpty ? " " : episode.longTitle)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .biliPink : .secondary)
                .lineLimit(1)
        }
        .foregroundColor(isSelected ? .biliPink : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.biliPink : Color.clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if !episode.badge.isEmpty {
                BadgeLabel(text: episode.badge)
                    .padding(3)
            }
        }
    }
}

/// Grid of all main episodes plus extra sections (PV / 花絮 …).
struct VideoPGCEpisodeSheet: View {
    let season: PGCSeason
    let currentEpId: Int64
    let onSelect: (PGCEpisode) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !season.episodes.isEmpty {
                            group(title: season.newEpDesc.isEmpty ? "正片" : season.newEpDesc, episodes: season.episodes)
                        }
                        ForEach(season.sections.filter { !$0.episodes.isEmpty }) { section in
                            group(title: section.title, episodes: section.episodes)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if currentEpId != 0 {
                        DispatchQueue.main.async { proxy.scrollTo(currentEpId, anchor: .center) }
                    }
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
    }

    private func group(title: String, episodes: [PGCEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(episodes) { ep in
                    Button {
                        onSelect(ep)
                        dismiss()
                    } label: {
                        VideoPGCEpisodeChip(episode: ep, isSelected: ep.epId == currentEpId, width: nil)
                    }
                    .buttonStyle(.plain)
                    .id(ep.epId)
                }
            }
        }
    }
}

/// Season 简介: rating, type / areas / styles, publish info, evaluate, actors.
struct VideoPGCInfoSheet: View {
    let season: PGCSeason

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(url: season.cover, width: 90)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(season.title)
                                .font(.system(size: 17, weight: .semibold))
                            if let rating = season.rating, rating.score > 0 {
                                Text(String(format: "%.1f分", rating.score) + (rating.count > 0 ? "  \(Fmt.count(rating.count))人评" : ""))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.0))
                            }
                            info(season.typeName + (season.areas.isEmpty ? "" : " · " + season.areas.joined(separator: "、")))
                            if !season.publishTime.isEmpty { info(season.publishTime) }
                            if !season.newEpDesc.isEmpty { info(season.newEpDesc) }
                            if !season.styles.isEmpty { info(season.styles.joined(separator: " / ")) }
                        }
                    }
                    if !season.evaluate.isEmpty {
                        section("简介", season.evaluate)
                    }
                    if !season.actors.isEmpty {
                        section("演职人员", season.actors)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .tint(.biliPink)
        .presentationDetents([.medium, .large])
    }

    private func info(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private func section(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .medium))
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = content
                        ToastCenter.shared.show("已复制")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
        }
    }
}

// MARK: - Skeleton

/// Placeholder shown while the detail loads.
struct VideoIntroSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(fill).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 110, height: 12)
                    bar(width: 70, height: 10)
                }
                Spacer()
                bar(width: 72, height: 28)
            }
            bar(width: nil, height: 16)
            bar(width: 220, height: 16)
            bar(width: 180, height: 10)
            HStack {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: 6) {
                        Circle().fill(fill).frame(width: 26, height: 26)
                        bar(width: 30, height: 8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            ForEach(0..<4, id: \.self) { _ in
                HStack(alignment: .top, spacing: 10) {
                    bar(width: 150, height: 94)
                    VStack(alignment: .leading, spacing: 8) {
                        bar(width: nil, height: 12)
                        bar(width: 120, height: 12)
                        Spacer(minLength: 0)
                        bar(width: 80, height: 10)
                    }
                    .frame(height: 94)
                }
            }
        }
        .padding(12)
        .accessibilityLabel("加载中")
    }

    private var fill: Color { Color(.secondarySystemFill) }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
