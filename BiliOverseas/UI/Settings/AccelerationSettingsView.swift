import SwiftUI

/// 设置 → 海外加速 (route `.settingsAcceleration`). Port of the Bilibili-thread-ripper (BTR) settings
/// panel: master switch, CDN mode, custom servers, thread count, PGC switch and buffer target (live
/// acceleration is not implemented, so its row only says 「暂未支持」).
/// Everything binds to `AppSettings.shared.acceleration`; the engine picks up every change at once
/// (`AppSettings.accelerationDidChange`), so it applies to the next media pieces without restarting playback.
struct AccelerationSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showResetConfirm = false

    static let concurrencyOptions = [4, 8, 16, 32, 64, 128]
    static let bufferOptions: [Double] = [15, 30, 45, 60, 90, 120]

    var body: some View {
        Form {
            Section {
                AccelerationIntroCard()
            }

            Section {
                SettingsToggleRow(title: "启用海外加速", subtitle: "多线程、多节点同时下载视频",
                                  isOn: $settings.acceleration.enabled)
            } footer: {
                Text("关闭后直接使用 B 站分配的地址、单条连接播放。")
            }

            Group {
                cdnModeSection
                if settings.acceleration.cdnMode == .custom {
                    AccelerationHostEditor(hosts: $settings.acceleration.customHosts)
                }
                threadSection
                contentSection
            }
            .disabled(!settings.acceleration.enabled)

            // The forward buffer applies to every playback, accelerated or not.
            bufferSection

            Section {
                SettingsToggleRow(title: "显示加速统计浮层", subtitle: "在播放器上显示实时速度、线程数和所用节点",
                                  isOn: $settings.player.showAccelerationStats)
            } header: {
                Text("调试")
            }

            Section {
                Button("恢复加速默认设置") { showResetConfirm = true }
                    .confirmationDialog("恢复加速默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("恢复默认", role: .destructive) {
                            settings.acceleration = AccelerationSettings()
                            settings.player.showAccelerationStats = PlayerSettings().showAccelerationStats
                            ToastCenter.shared.show("已恢复默认设置")
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将恢复为大陆 CDN、自动线程数等默认值，自定义服务器列表会被清空。")
                    }
            } footer: {
                Text("隐私：本应用不上传任何数据。加速全部在本机完成，视频地址只发给 B 站自己的视频服务器（bilivideo.com、akamaized.net 等），不会发给其他网站，也不会携带你的登录信息。")
            }
        }
        .navigationTitle("海外加速")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var cdnModeSection: some View {
        Section {
            ForEach(CDNMode.allCases) { mode in
                SettingsChoiceRow(title: mode.title, subtitle: Self.explanation(for: mode),
                                  isSelected: settings.acceleration.cdnMode == mode) {
                    settings.acceleration.cdnMode = mode
                }
            }
        } header: {
            Text("CDN 模式")
        } footer: {
            AccelerationAdviceTable()
        }
    }

    private var threadSection: some View {
        Section {
            SettingsToggleRow(title: "自动线程数（推荐）", subtitle: "智能选择需要的线程数",
                              isOn: $settings.acceleration.autoConcurrency)
            if !settings.acceleration.autoConcurrency {
                SettingsValuePicker(title: "线程加载数", selection: $settings.acceleration.manualConcurrency,
                                    options: Self.concurrencyOptions) { "\($0) 线程" }
                if settings.acceleration.manualConcurrency > 32 {
                    SettingsNoticeRow(text: "超过 32 线程会明显增加耗电和发热，通常不会更快。")
                }
            }
        } header: {
            Text("线程")
        } footer: {
            Text("自动模式会根据实测速度自动增减线程数（8 线程起，iPhone 最多 32，iPad 最多 64）。线程数是并发上限，缓冲充足时实际连接会变少。手动调优建议 8～32，设备性能较弱时选 4～8。")
        }
    }

    private var contentSection: some View {
        Section {
            SettingsToggleRow(title: "竖屏视频禁用加速", subtitle: "短视频和竖屏视频用单条连接直接播放，起播通常更快；经常卡顿时可以关闭",
                              isOn: $settings.acceleration.verticalVideosDirect)
            SettingsToggleRow(title: "剧集加速", subtitle: "加速番剧、电影、纪录片等剧集",
                              isOn: $settings.acceleration.accelerateBangumi)
            // Not implemented: live rooms always play straight from the CDN (`accelerateLive` is never read).
            SettingsToggleRow(title: "直播加速", subtitle: "暂未支持，直播始终直连播放", isOn: .constant(false))
                .disabled(true)
        } header: {
            Text("加速范围")
        }
    }

    private var bufferSection: some View {
        Section {
            SettingsValuePicker(title: "预缓冲时长", selection: $settings.acceleration.forwardBufferSeconds,
                                options: Self.bufferOptions) { SettingsFormat.seconds($0) }
        } header: {
            Text("缓冲")
        } footer: {
            Text("播放器尽量提前缓冲的时长，关闭加速时同样生效。越长越不容易卡顿，但占用更多内存和流量。")
        }
    }

    static func explanation(for mode: CDNMode) -> String {
        switch mode {
        case .mainland:
            return "直接从大陆节点下载。大陆节点存有全部视频，配合多线程弥补距离，海外看冷门视频也流畅。"
        case .overseas:
            return "使用 B 站海外、香港节点。仅在你所在地连大陆网络很差时尝试。"
        case .custom:
            return "只使用下面选择的服务器。"
        case .original:
            return "使用 B 站分配的地址，不替换节点。"
        }
    }
}

/// Header card: what BTR acceleration does and what it does not do.
struct AccelerationIntroCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.biliPink, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("海外加速")
                    .font(.headline)
                Text("移植自「Bilibili 线程撕裂者」（BTR）：把视频切成小块，用多条连接、多个 CDN 节点同时下载，再按顺序交给播放器，解决海外看 B 站卡顿、冷门视频加载慢的问题。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("只加速你本来就有权观看的内容，不会绕过会员、地区或版权限制。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// BTR README 「建议设置」 table, shown under the CDN mode choices.
struct AccelerationAdviceTable: View {
    private struct Advice: Identifiable {
        let id: Int
        let situation: String
        let mode: String
        let threads: String
    }

    private static let rows: [Advice] = [
        Advice(id: 0, situation: "推荐", mode: "大陆 CDN", threads: "自动"),
        Advice(id: 1, situation: "手动调优", mode: "大陆 CDN", threads: "8～32"),
        Advice(id: 2, situation: "设备性能弱", mode: "大陆 CDN", threads: "4～8"),
        Advice(id: 3, situation: "连大陆网络太差", mode: "海外 CDN", threads: "自动"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("建议设置")
                .fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("情况").fontWeight(.medium)
                    Text("CDN 模式").fontWeight(.medium)
                    Text("线程数").fontWeight(.medium)
                }
                Divider()
                ForEach(Self.rows) { row in
                    GridRow {
                        HStack(spacing: 3) {
                            if row.id == 0 {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(Color.biliPink)
                                    .imageScale(.small)
                            }
                            Text(verbatim: row.situation)
                        }
                        Text(verbatim: row.mode)
                        Text(verbatim: row.threads)
                    }
                }
            }
            Text("以上仅供参考，每个人的网络差别很大，以实际播放是否流畅为准。海外边缘节点通常只缓存热门视频，冷门视频要绕回国内获取，因此即使在海外也推荐大陆 CDN + 自动线程。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// 「自定义」 server list: pick from the known BTR mainland / overseas node lists (multi-select) or add
/// hosts by hand. Input is sanitized with BTR's `normalizeCdnHost` (lower-case, scheme / port / path
/// stripped, DNS-label check, Bilibili media-host whitelist), so only Bilibili video servers can be saved.
struct AccelerationHostEditor: View {
    @Binding var hosts: [String]

    @State private var draft = ""
    @State private var message: String?

    /// `BTRCDN.customServers` uses at most this many.
    static let maxHosts = 32

    var body: some View {
        Section {
            if hosts.isEmpty {
                SettingsNoticeRow(text: "还没选服务器，暂时按大陆 CDN 下载。", systemImage: "info.circle.fill", tint: .blue)
            } else {
                ForEach(hosts, id: \.self) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: host)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if BTRRangeCore.normalizeCdnHost(host) != host {
                            Text("地址无效，将被忽略")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(verbatim: Self.groupName(of: host))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    hosts.remove(atOffsets: offsets)
                }
            }
        } header: {
            HStack {
                Text(verbatim: "已选服务器（\(hosts.count)/\(Self.maxHosts)）")
                Spacer()
                if !hosts.isEmpty {
                    Button("清空") { hosts.removeAll() }
                        .textCase(nil)
                }
            }
        } footer: {
            Text("左滑删除。只能使用 B 站的视频服务器（bilivideo.com、akamaized.net 等），视频的下载地址不会发给别的网站。")
        }

        knownHostSection(title: "大陆节点", list: BTRCDN.mainlandHosts)
        knownHostSection(title: "海外节点", list: BTRCDN.overseasHosts)

        Section {
            HStack {
                TextField("例如 upos-sz-mirrorali.bilivideo.com", text: $draft)
                    .font(.subheadline.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addDraft)
                Button("添加", action: addDraft)
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("手动添加")
        } footer: {
            Text("可粘贴完整视频地址，会自动去掉协议、端口和路径，只保留服务器名。多个地址用空格、逗号或换行分隔。")
        }
    }

    private func knownHostSection(title: String, list: [String]) -> some View {
        Section {
            ForEach(list, id: \.self) { host in
                Button {
                    toggle(host)
                } label: {
                    HStack {
                        Text(verbatim: host)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 8)
                        Image(systemName: hosts.contains(host) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(hosts.contains(host) ? Color.biliPink : Color.secondary)
                            .imageScale(.large)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(hosts.contains(host) ? .isSelected : [])
            }
        } header: {
            HStack {
                Text(verbatim: title)
                Spacer()
                let allSelected = list.allSatisfy { hosts.contains($0) }
                Button(allSelected ? "取消全选" : "全选") {
                    if allSelected {
                        hosts.removeAll { list.contains($0) }
                    } else {
                        for host in list where !hosts.contains(host) && hosts.count < Self.maxHosts {
                            hosts.append(host)
                        }
                    }
                    message = nil
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Editing

    private func toggle(_ host: String) {
        message = nil
        if let index = hosts.firstIndex(of: host) {
            hosts.remove(at: index)
        } else if hosts.count >= Self.maxHosts {
            message = "最多选择 \(Self.maxHosts) 个服务器"
        } else {
            hosts.append(host)
        }
    }

    private func addDraft() {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；、"))
        let entries = draft.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !entries.isEmpty else { return }

        var added = 0
        var invalid: [String] = []
        var duplicate = 0
        var full = false
        var list = hosts
        for entry in entries {
            let host = BTRRangeCore.normalizeCdnHost(entry)
            if host.isEmpty {
                invalid.append(entry)
            } else if list.contains(host) {
                duplicate += 1
            } else if list.count >= Self.maxHosts {
                full = true
            } else {
                list.append(host)
                added += 1
            }
        }
        if added > 0 { hosts = list }

        if !invalid.isEmpty {
            // Keep the rejected input so the user can fix it.
            draft = invalid.joined(separator: " ")
            message = "不是 B 站视频服务器：\(invalid.prefix(3).joined(separator: "、"))\(invalid.count > 3 ? " 等" : "")。只支持 bilivideo.com/.cn/.net、akamaized.net 等 B 站媒体域名。"
        } else if full {
            draft = ""
            message = "最多选择 \(Self.maxHosts) 个服务器"
        } else if added == 0 && duplicate > 0 {
            draft = ""
            message = "已在列表中"
        } else {
            draft = ""
            message = nil
        }
        if added > 0 {
            ToastCenter.shared.show("已添加 \(added) 个服务器")
        }
    }

    static func groupName(of host: String) -> String {
        if BTRCDN.mainlandHosts.contains(host) { return "大陆节点" }
        if BTRCDN.overseasHosts.contains(host) { return "海外节点" }
        return "手动添加"
    }
}
