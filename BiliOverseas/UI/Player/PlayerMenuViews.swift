import SwiftUI

/// One row of a player menu.
struct PlayerMenuRow: Identifiable {
    enum Kind {
        case action(() -> Void)
        case toggle(Binding<Bool>)
    }

    let id: String
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    var selected = false
    var dimmed = false
    var chevron = false
    let kind: Kind
}

/// Builds the rows of each menu from the controller (shared by the sheet and the fullscreen side panel).
@MainActor
struct PlayerMenuBuilder {
    let controller: PlayerController
    let settings: AppSettings
    /// Show another panel of the same menu (「更多设置」 → 画质 …).
    let navigate: (PlayerPanel) -> Void
    /// Present a sheet (弹幕设置, 发弹幕, 播放设置).
    let openSheet: (PlayerSheet) -> Void
    let close: () -> Void

    func rows(for panel: PlayerPanel) -> [PlayerMenuRow] {
        switch panel {
        case .speed: return speedRows()
        case .quality: return qualityRows()
        case .audio: return audioRows()
        case .codec: return codecRows()
        case .subtitle: return subtitleRows()
        case .aspect: return aspectRows()
        case .sleepTimer: return sleepRows()
        case .more: return moreRows()
        }
    }

    func footer(for panel: PlayerPanel) -> String? {
        switch panel {
        case .quality:
            return "标灰画质需要登录或大会员；HDR / 杜比视界需在「播放设置」中开启且设备支持；4K 和杜比视界播放效果可能不佳"
        case .codec:
            return "HEVC 更省流量；遇到花屏或卡顿可切换为 AVC"
        default:
            return nil
        }
    }

    private func speedRows() -> [PlayerMenuRow] {
        var speeds = settings.player.speedOptions.filter { $0 > 0 }
        if !speeds.contains(where: { abs($0 - controller.rate) < 0.001 }) { speeds.append(controller.rate) }
        return speeds.sorted(by: >).map { r in
            PlayerMenuRow(id: "speed.\(r)", title: "\(PlayerFormat.rate(r))X",
                          selected: abs(r - controller.rate) < 0.001,
                          kind: .action {
                              controller.setRate(r)
                              close()
                          })
        }
    }

    private func qualityRows() -> [PlayerMenuRow] {
        controller.qualityEntries.map { entry in
            PlayerMenuRow(id: "quality.\(entry.qn)", title: entry.title, badge: entry.badge,
                          selected: entry.qn == controller.currentQuality, dimmed: !entry.playable,
                          kind: .action {
                              controller.selectQuality(entry.qn)
                              if entry.playable { close() }
                          })
        }
    }

    private func audioRows() -> [PlayerMenuRow] {
        controller.audioEntries.map { entry in
            PlayerMenuRow(id: "audio.\(entry.id)", title: entry.title, selected: entry.id == controller.currentAudioId,
                          kind: .action {
                              controller.selectAudio(entry.id)
                              close()
                          })
        }
    }

    private func codecRows() -> [PlayerMenuRow] {
        controller.codecFamilies.map { family in
            PlayerMenuRow(id: "codec.\(family)", title: PlayerStreamPicker.codecTitle(family),
                          selected: family == controller.currentCodecFamily,
                          kind: .action {
                              controller.selectCodec(family)
                              close()
                          })
        }
    }

    private func subtitleRows() -> [PlayerMenuRow] {
        var rows = [PlayerMenuRow(id: "subtitle.off", title: "关闭字幕", selected: controller.selectedSubtitleId == nil,
                                  kind: .action {
                                      controller.selectSubtitle(nil)
                                      close()
                                  })]
        rows += controller.subtitleTracks.map { track in
            PlayerMenuRow(id: "subtitle.\(track.id)", title: track.lanDoc,
                          selected: controller.selectedSubtitleId == track.id,
                          kind: .action {
                              controller.selectSubtitle(track.id)
                              close()
                          })
        }
        return rows
    }

    private func aspectRows() -> [PlayerMenuRow] {
        PlayerAspectMode.allCases.map { mode in
            PlayerMenuRow(id: "aspect.\(mode.rawValue)", title: mode.title, selected: controller.aspectMode == mode,
                          kind: .action {
                              controller.aspectMode = mode
                              close()
                          })
        }
    }

    private func sleepRows() -> [PlayerMenuRow] {
        let options: [(String, PlayerSleepTimer)] = [
            ("不开启", .off), ("15分钟", .minutes(15)), ("30分钟", .minutes(30)), ("60分钟", .minutes(60)),
            ("播完本集", .endOfEpisode),
        ]
        return options.map { title, value in
            var detail: String?
            if value == controller.sleepTimer, case .minutes = value, let left = controller.sleepRemaining {
                detail = "剩余 \(PlayerFormat.time(left))"
            }
            return PlayerMenuRow(id: "sleep.\(title)", title: title, detail: detail,
                                 selected: controller.sleepTimer == value,
                                 kind: .action {
                                     controller.setSleepTimer(value)
                                     close()
                                 })
        }
    }

    private func sleepSummary() -> String {
        switch controller.sleepTimer {
        case .off: return "不开启"
        case .endOfEpisode: return "播完本集"
        case .minutes:
            if let left = controller.sleepRemaining { return "剩余 \(PlayerFormat.time(left))" }
            return "已开启"
        }
    }

    private func moreRows() -> [PlayerMenuRow] {
        var rows: [PlayerMenuRow] = []
        let qualityTitle = controller.qualityEntries.first { $0.qn == controller.currentQuality }?.title
        if !controller.qualityEntries.isEmpty {
            rows.append(PlayerMenuRow(id: "more.quality", title: "画质", detail: qualityTitle, chevron: true,
                                      kind: .action { navigate(.quality) }))
        }
        if controller.audioEntries.count > 1 {
            rows.append(PlayerMenuRow(id: "more.audio", title: "音质",
                                      detail: controller.currentAudioId.map { DashStream.audioTitle($0) }, chevron: true,
                                      kind: .action { navigate(.audio) }))
        }
        if controller.codecFamilies.count > 1 {
            rows.append(PlayerMenuRow(id: "more.codec", title: "解码格式",
                                      detail: PlayerStreamPicker.codecTitle(controller.currentCodecFamily), chevron: true,
                                      kind: .action { navigate(.codec) }))
        }
        rows.append(PlayerMenuRow(id: "more.speed", title: "播放速度",
                                  detail: "\(PlayerFormat.rate(controller.rate))X", chevron: true,
                                  kind: .action { navigate(.speed) }))
        if !controller.subtitleTracks.isEmpty {
            let current = controller.subtitleTracks.first { $0.id == controller.selectedSubtitleId }?.lanDoc ?? "关闭"
            rows.append(PlayerMenuRow(id: "more.subtitle", title: "字幕", detail: current, chevron: true,
                                      kind: .action { navigate(.subtitle) }))
        }
        rows.append(PlayerMenuRow(id: "more.aspect", title: "画面比例", detail: controller.aspectMode.title, chevron: true,
                                  kind: .action { navigate(.aspect) }))
        rows.append(PlayerMenuRow(id: "more.sleep", title: "定时关闭", detail: sleepSummary(), chevron: true,
                                  kind: .action { navigate(.sleepTimer) }))
        rows.append(PlayerMenuRow(id: "more.danmaku", title: "弹幕设置", chevron: true,
                                  kind: .action { openSheet(.danmakuSettings) }))
        rows.append(PlayerMenuRow(id: "more.send", title: "发弹幕", chevron: true,
                                  kind: .action { openSheet(.danmakuSend) }))
        if controller.supportsPiP {
            rows.append(PlayerMenuRow(id: "more.pip", title: controller.isPiPActive ? "退出画中画" : "画中画",
                                      kind: .action {
                                          close()
                                          controller.togglePiP()
                                      }))
        }
        rows.append(PlayerMenuRow(id: "more.background", title: "后台播放",
                                  kind: .toggle(Binding(get: { settings.player.backgroundPlay },
                                                        set: { settings.player.backgroundPlay = $0 }))))
        rows.append(PlayerMenuRow(id: "more.stats", title: "加速统计",
                                  kind: .toggle(Binding(get: { settings.player.showAccelerationStats },
                                                        set: { settings.player.showAccelerationStats = $0 }))))
        rows.append(PlayerMenuRow(id: "more.reload", title: "重载视频",
                                  kind: .action {
                                      close()
                                      controller.retry()
                                  }))
        rows.append(PlayerMenuRow(id: "more.settings", title: "播放设置", chevron: true,
                                  kind: .action { openSheet(.playerSettings) }))
        return rows
    }
}

// MARK: - Fullscreen side panel (dark)

struct PlayerMenuPanel: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var overlay: PlayerOverlayModel
    @ObservedObject private var settings = AppSettings.shared
    let panel: PlayerPanel

    private var builder: PlayerMenuBuilder {
        PlayerMenuBuilder(controller: controller, settings: settings,
                          navigate: { overlay.panel = $0 },
                          openSheet: { sheet in
                              overlay.panel = nil
                              overlay.sheet = sheet
                          },
                          close: { overlay.panel = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if panel != .more {
                    Button {
                        overlay.panel = .more
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("返回"))
                }
                Text(panel.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(builder.rows(for: panel)) { row in
                        PlayerMenuDarkRow(row: row)
                    }
                    if let footer = builder.footer(for: panel) {
                        Text(footer)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

struct PlayerMenuDarkRow: View {
    let row: PlayerMenuRow

    var body: some View {
        switch row.kind {
        case .action(let action):
            Button(action: action) { content(trailing: AnyView(trailing)) }
                .buttonStyle(.plain)
        case .toggle(let binding):
            content(trailing: AnyView(Toggle("", isOn: binding).labelsHidden().tint(.biliPink)))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if let detail = row.detail {
                Text(detail).font(.system(size: 13)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
            }
            if row.selected {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.biliPink)
            }
            if row.chevron {
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private func content(trailing: AnyView) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.system(size: 14, weight: row.selected ? .semibold : .regular))
                .foregroundColor(row.selected ? .biliPink : .white.opacity(row.dimmed ? 0.4 : 1))
                .lineLimit(1)
            if let badge = row.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.biliPink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliPink, lineWidth: 0.8))
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Inline sheet (system style)

struct PlayerMenuSheet: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var panel: PlayerPanel
    private let root: PlayerPanel

    init(controller: PlayerController, root: PlayerPanel) {
        self.controller = controller
        self.root = root
        _panel = State(initialValue: root)
    }

    private var builder: PlayerMenuBuilder {
        PlayerMenuBuilder(controller: controller, settings: settings,
                          navigate: { panel = $0 },
                          openSheet: { controller.overlay.sheet = $0 },
                          close: { dismiss() })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(builder.rows(for: panel)) { row in
                        PlayerMenuListRow(row: row)
                    }
                } footer: {
                    if let footer = builder.footer(for: panel) { Text(footer) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if panel != root {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回") { panel = root }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PlayerMenuListRow: View {
    let row: PlayerMenuRow

    var body: some View {
        switch row.kind {
        case .action(let action):
            Button(action: action) { label }
                .foregroundColor(.primary)
        case .toggle(let binding):
            Toggle(row.title, isOn: binding).tint(.biliPink)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(row.title)
                .foregroundColor(row.dimmed ? .secondary : .primary)
            if let badge = row.badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.biliPink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.biliPink, lineWidth: 0.8))
            }
            Spacer(minLength: 8)
            if let detail = row.detail {
                Text(detail).foregroundColor(.secondary).lineLimit(1)
            }
            if row.selected {
                Image(systemName: "checkmark").foregroundColor(.biliPink)
            }
            if row.chevron {
                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 「播放设置」 inside the player (no navigation stack is available in fullscreen).
struct PlayerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlayerSettingsView()
                .navigationTitle("播放设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
