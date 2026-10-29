import SwiftUI

/// 设置 → 屏蔽设置 (feed filter / 屏蔽广告视频). Everything binds to `AppSettings.shared.feedFilter`;
/// the rules themselves live in `Core/Filter/FeedFilter.swift`.
struct FeedFilterSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let durationOptions = [0, 30, 60, 180, 300]
    private static let likeRatioOptions = [0, 1, 2, 3, 4]
    private static let playCountOptions = [0, 50, 100, 500, 1000]

    var body: some View {
        Form {
            Section {
                Toggle("屏蔽广告卡片/创作推广", isOn: $settings.feedFilter.blockAdCards)
                Toggle("屏蔽疑似恰饭视频", isOn: $settings.feedFilter.blockPromotedVideos)
            } header: {
                Text("广告")
            } footer: {
                Text("广告卡片指推荐流、热门、搜索等列表中的商业广告和 UP 主付费推广（创作推广）卡片。\n疑似恰饭视频根据标题、简介中的“商单”“恰饭”“品牌合作”“本期视频由…赞助”等字样，以及动态中的带货商品标记识别。“无广告”“非商单”“广告学”等说法不会被屏蔽，但仍可能有少量误判。")
            }

            Section {
                Toggle("屏蔽直播卡片", isOn: $settings.feedFilter.blockLiveCards)
                Toggle("屏蔽番剧/课程卡片", isOn: $settings.feedFilter.blockPGCCards)
            } header: {
                Text("推荐流")
            } footer: {
                Text("仅作用于首页推荐。")
            }

            FilterRuleListEditor(
                title: "关键词屏蔽",
                placeholder: "输入关键词",
                footer: "标题包含任一关键词的视频将被隐藏，不区分大小写。用 /…/ 包裹表示正则表达式，例如 /抽奖|开箱/。",
                rules: $settings.feedFilter.blockedKeywords,
                warning: { FeedFilter.isValidKeywordRule($0) ? nil : "正则表达式无效，此条不会生效" }
            )

            FilterRuleListEditor(
                title: "UP 主屏蔽",
                placeholder: "UP 主昵称或 UID",
                footer: "填写完整昵称或 UID（纯数字），该 UP 主的视频将被隐藏；即使已关注也会屏蔽。",
                rules: $settings.feedFilter.blockedUploaders
            )

            Section {
                Picker("最短时长", selection: $settings.feedFilter.minDuration) {
                    ForEach(Self.options(Self.durationOptions, including: settings.feedFilter.minDuration), id: \.self) { value in
                        Text(verbatim: Self.durationTitle(value)).tag(value)
                    }
                }
            } header: {
                Text("时长")
            } footer: {
                Text("隐藏短于该时长的视频，时长未知的视频不受影响。")
            }

            Section {
                Picker("最低点赞率", selection: $settings.feedFilter.minLikeRatio) {
                    ForEach(Self.options(Self.likeRatioOptions, including: settings.feedFilter.minLikeRatio), id: \.self) { value in
                        Text(verbatim: value == 0 ? "不限" : "\(value)%").tag(value)
                    }
                }
                Picker("最低播放量", selection: $settings.feedFilter.minPlayCount) {
                    ForEach(Self.options(Self.playCountOptions, including: settings.feedFilter.minPlayCount), id: \.self) { value in
                        Text(verbatim: value == 0 ? "不限" : "\(value)").tag(value)
                    }
                }
            } header: {
                Text("播放数据")
            } footer: {
                Text("仅对能获取到点赞数、播放量的视频生效（部分推荐卡片不提供点赞数），不作用于搜索结果。")
            }

            Section {
                Toggle("关注的 UP 不过滤", isOn: $settings.feedFilter.exemptFollowed)
                Toggle("应用到热门/排行/搜索/相关推荐", isOn: $settings.feedFilter.applyToAllLists)
            } header: {
                Text("其他")
            } footer: {
                Text("开启“关注的 UP 不过滤”后，已关注 UP 主的视频不受关键词、恰饭、时长等规则影响。关闭“应用到…”后，这些规则仅作用于首页推荐。广告卡片屏蔽始终生效；观看历史和收藏中的内容不会被过滤。")
            }
        }
        .navigationTitle("屏蔽设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Preset values plus the stored value when it is a custom one (so the picker never shows blank).
    private static func options(_ presets: [Int], including current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private static func durationTitle(_ seconds: Int) -> String {
        if seconds <= 0 { return "不限" }
        if seconds >= 60 && seconds % 60 == 0 { return "\(seconds / 60)分钟" }
        return "\(seconds)秒"
    }
}

/// One `Section` that edits a list of filter rules: each rule with swipe-to-delete (plus an
/// optional warning line), and an input row to add a new one. Duplicates are ignored.
struct FilterRuleListEditor: View {
    let title: String
    let placeholder: String
    let footer: String
    @Binding var rules: [String]
    /// Warning shown under a rule (e.g. an invalid regex), nil for none.
    let warning: (String) -> String?

    @State private var draft = ""

    init(title: String, placeholder: String, footer: String = "", rules: Binding<[String]>,
         warning: @escaping (String) -> String? = { _ in nil }) {
        self.title = title
        self.placeholder = placeholder
        self.footer = footer
        self._rules = rules
        self.warning = warning
    }

    var body: some View {
        Section {
            ForEach(Array(rules.enumerated()), id: \.offset) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.element)
                        .lineLimit(3)
                    if let message = warning(entry.element) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onDelete { offsets in
                rules.remove(atOffsets: offsets)
            }

            HStack(spacing: 12) {
                TextField(placeholder, text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(add)
                // Borderless: a default-style button makes the whole Form row its tap target, so a tap
                // into the text field (to correct the draft) would also run `add`.
                Button("添加", action: add)
                    .buttonStyle(.borderless)
                    .disabled(trimmedDraft.isEmpty)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !rules.isEmpty {
                    Text("\(rules.count) 条")
                }
            }
        } footer: {
            if !footer.isEmpty {
                Text(footer)
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let value = trimmedDraft
        guard !value.isEmpty else { return }
        if !rules.contains(value) {
            rules.append(value)
        }
        draft = ""
    }
}
