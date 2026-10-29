// 「空降助手」 settings: the BilibiliSponsorBlock source of 广告跳过 (features.md §11.3, §12.7). The segments
// are merged with the local BiliSmartSkip detections in `SmartSkipAnalyzer`. Part of BiliOverseas
// (GPL-2.0-or-later).

import SwiftUI

struct SponsorBlockSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var serverDraft = ""
    @State private var serverError: String?

    private static let projectURL = URL(string: "https://github.com/hanydd/BilibiliSponsorBlock")!

    private var isOn: Bool { settings.smartSkip.enabled && settings.smartSkip.sponsorBlockEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("启用空降助手", isOn: $settings.smartSkip.sponsorBlockEnabled)
                    .disabled(!settings.smartSkip.enabled)
            } footer: {
                Text(settings.smartSkip.enabled
                     ? "从 BilibiliSponsorBlock 社区数据库获取观众提交的片段（恰饭、开场动画、片尾、三连提醒等），与本地识别的结果合并，按下方设置跳过或标注。请求只包含视频的 BV 号和 cid，不包含账号信息；服务器无法访问时不影响本地识别。"
                     : "「广告跳过」已关闭，空降助手也不会生效。")
            }

            Section {
                ForEach(SponsorBlockCategory.rangeCategories) { category in
                    Picker(selection: skipTypeBinding(category)) {
                        ForEach(SponsorBlockSkipType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    } label: {
                        categoryLabel(category)
                    }
                }
            } header: {
                Text("片段类别")
            } footer: {
                Text("总是跳过：每次播放到都跳过。跳过一次：每个片段只自动跳过一次，拖回片段时显示跳过按钮。手动跳过：只显示「跳过: 片段名」按钮。仅显示：只在进度条上用对应颜色标出。禁用：不显示。「广告跳过」的模式为「手动」时，所有片段都只显示按钮。")
            }
            .disabled(!isOn)

            Section {
                Stepper(value: $settings.smartSkip.sponsorBlockMinDuration,
                        in: SmartSkipSettings.sponsorBlockMinDurationRange, step: 1) {
                    HStack {
                        Text("最短片段时长")
                        Spacer()
                        Text("\(Int(settings.smartSkip.sponsorBlockMinDuration)) 秒")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("忽略短于此时长的片段：只在进度条上标出，不跳过。")
            }
            .disabled(!isOn)

            Section {
                HStack {
                    TextField(SmartSkipSettings.defaultSponsorBlockServer, text: $serverDraft)
                        .font(.subheadline.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveServer)
                    Button("保存", action: saveServer)
                        .buttonStyle(.borderless)
                        .disabled(serverDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.smartSkip.sponsorBlockServer)
                }
                if let serverError {
                    Text(verbatim: serverError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("重置") {
                    settings.smartSkip.sponsorBlockServer = SmartSkipSettings.defaultSponsorBlockServer
                    serverDraft = SmartSkipSettings.defaultSponsorBlockServer
                    serverError = nil
                }
                .disabled(settings.smartSkip.sponsorBlockServer == SmartSkipSettings.defaultSponsorBlockServer)
            } header: {
                Text("服务器地址")
            } footer: {
                Text(verbatim: "当前：\(settings.smartSkip.sponsorBlockServer)")
            }
            .disabled(!isOn)

            Section {
                Link("BilibiliSponsorBlock 项目主页", destination: Self.projectURL)
            } footer: {
                Text("片段由社区用户提交和投票，可能不准确。片段投票与提交暂不支持。")
            }
        }
        .navigationTitle("空降助手")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { serverDraft = settings.smartSkip.sponsorBlockServer }
    }

    private func skipTypeBinding(_ category: SponsorBlockCategory) -> Binding<SponsorBlockSkipType> {
        Binding(get: { settings.smartSkip.sponsorBlockSkipType(for: category) },
                set: { settings.smartSkip.setSponsorBlockSkipType($0, for: category) })
    }

    private func categoryLabel(_ category: SponsorBlockCategory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(category.displayColor)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveServer() {
        guard let server = SponsorBlockClient.normalizedServer(serverDraft) else {
            serverError = "请输入有效的服务器地址，例如 \(SmartSkipSettings.defaultSponsorBlockServer)"
            return
        }
        serverError = nil
        serverDraft = server
        settings.smartSkip.sponsorBlockServer = server
    }
}

// MARK: - Segment colours (also used by the player's progress bars)

extension SponsorBlockCategory {
    /// The category's strip / dot colour.
    var displayColor: Color { sponsorBlockColor(color) }
}

extension AdSegment {
    /// Progress-bar strip: the 空降助手 category colour, otherwise green (may auto-skip) / yellow (button only).
    var stripColor: Color {
        if let color { return sponsorBlockColor(color).opacity(0.9) }
        return requiresConfirmation ? Color.yellow.opacity(0.75) : Color.green.opacity(0.85)
    }
}

/// `0xRRGGBB` → `Color`.
private func sponsorBlockColor(_ rgb: UInt32) -> Color {
    Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
}
