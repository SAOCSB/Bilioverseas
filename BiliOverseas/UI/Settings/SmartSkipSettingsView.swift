// SmartSkip settings — Swift port of BiliSmartSkip by wzy403 (https://github.com/wzy403/BiliSmartSkip),
// GPL-2.0 (replaces the extension's popup: mode switch; the keyboard shortcut does not apply on
// iOS). Part of BiliOverseas (GPL-2.0-or-later).

import SwiftUI

struct SmartSkipSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    private static let projectURL = URL(string: "https://github.com/wzy403/BiliSmartSkip")!
    private static let licenseURL = URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!

    var body: some View {
        Form {
            Section {
                Toggle("启用广告跳过", isOn: $settings.smartSkip.enabled)
            } footer: {
                Text("识别视频中 UP 主插入的口播广告、恰饭片段，并在播放到时跳过或提示。本地识别全部在本机完成；「空降助手」使用观众提交的片段。")
            }

            Section {
                Toggle("本地识别", isOn: $settings.smartSkip.localDetection)
                NavigationLink(value: Route.settingsSponsorBlock) {
                    HStack {
                        Text("空降助手")
                        Spacer()
                        Text(settings.smartSkip.sponsorBlockEnabled ? "已开启" : "已关闭")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("识别来源")
            } footer: {
                Text("本地识别：分析章节、简介、弹幕和字幕（见下方「识别原理」）。空降助手：BilibiliSponsorBlock 社区提交的赞助、开场动画、片尾等片段，与本地结果合并；两者重叠时以空降助手的赞助/推广片段为准。")
            }
            .disabled(!settings.smartSkip.enabled)

            Section {
                Picker("模式", selection: $settings.smartSkip.mode) {
                    ForEach(SmartSkipMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Stepper(value: $settings.smartSkip.countdownSeconds, in: SmartSkipSettings.countdownRange) {
                    HStack {
                        Text("倒计时秒数")
                        Spacer()
                        Text("\(settings.smartSkip.countdownSeconds) 秒")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Toggle("显示跳过提示", isOn: $settings.smartSkip.showToast)
            } header: {
                Text("跳过方式")
            } footer: {
                Text(modeFooter)
            }
            .disabled(!settings.smartSkip.enabled)

            Section {
                explanationRow("list.bullet.rectangle", "视频章节",
                               "UP 主把章节标为「广告」「恰饭环节」「赞助环节」等时最可靠，可直接自动跳过；只是讨论广告的章节（如「广告的发展历史」）只显示按钮。")
                explanationRow("text.alignleft", "视频简介",
                               "简介里的时间轴，如「01:30 广告」「02:00 正片」。")
                explanationRow("captions.bubble", "弹幕「空降」",
                               "观众发送的「空降 5:30」「跳过广告到 03:10」「705工程」等跳转指令。带否定词（如「不要跳过」）或只是普通时间引用的弹幕不会触发自动跳过；「10.5分钟」这类写法暂不支持。")
                explanationRow("text.bubble", "字幕",
                               "CC / AI 字幕里的赞助声明、领券下单等口播内容，以及「回到正片」等结束语。仅凭字幕找到的片段只显示按钮。AI 字幕通常需要登录后才能获取。")
                explanationRow("checkmark.shield", "安全规则",
                               "不同来源的起止时间对不上时，即使在自动模式下也只显示按钮。每段广告只自动跳过一次，拖回广告段时会再次显示跳过按钮；跳过后可在提示中点「撤销」。识别仍可能误判或漏检。")
            } header: {
                Text("识别原理")
            }

            Section {
                Text("广告识别规则移植自开源浏览器扩展 BiliSmartSkip（作者 wzy403），该项目以 GNU 通用公共许可证第 2 版（GPL-2.0）发布。本应用中的相应部分同样以 GPL-2.0（或更高版本）授权发布。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("BiliSmartSkip 项目主页", destination: Self.projectURL)
                Link("GPL-2.0 许可证全文", destination: Self.licenseURL)
            } header: {
                Text("致谢与许可")
            }
        }
        .navigationTitle("广告跳过")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modeFooter: String {
        let countdown = "「跳过疑似广告」按钮显示 \(settings.smartSkip.countdownSeconds) 秒后自动隐藏（暂停播放时倒计时暂停），隐藏后不会跳过；「跳过广告」按钮一直显示到离开这段广告。播放时也可以在「更多设置」→「广告跳过」中切换模式或跳过识别到的片段。"
        switch settings.smartSkip.mode {
        case .auto:
            return "自动跳过：只有边界可靠的广告段（明确的广告章节或简介时间轴、观众明确的「空降」指令、完整的口播段落）会被自动跳过，其余显示「跳过疑似广告」按钮。" + countdown
        case .manual:
            return "手动：识别到的广告段只显示跳过按钮，点击后跳过。" + countdown
        }
    }

    private func explanationRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.biliPink)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
