import SwiftUI

/// 「弹幕设置」 full settings screen (route `.settingsDanmaku`). Changes apply live to any
/// `DanmakuOverlayView` through `AppSettings.shared.danmaku`.
struct DanmakuSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showResetConfirm = false

    private static let maxOnScreenChoices = [0, 30, 50, 80, 120, 200, 300]

    var body: some View {
        Form {
            Section {
                Toggle("显示弹幕", isOn: $settings.danmaku.enabled)
            }

            Section("显示") {
                DanmakuSliderRow(title: "不透明度", value: $settings.danmaku.opacity, range: 0...1, step: 0.01,
                                 format: DanmakuSliderRow.percent)
                DanmakuSliderRow(title: "字体大小", value: $settings.danmaku.fontScale, range: 0.5...2.5, step: 0.05,
                                 format: DanmakuSliderRow.percent)
                DanmakuSliderRow(title: "全屏字体大小", value: $settings.danmaku.fontScaleFullscreen, range: 0.5...2.5,
                                 step: 0.05, format: DanmakuSliderRow.percent)
                Toggle("粗体", isOn: $settings.danmaku.bold)
                Stepper(value: $settings.danmaku.fontWeight, in: 0...8) {
                    DanmakuValueLabel(title: "字体粗细", value: "\(settings.danmaku.fontWeight + 1)")
                }
                DanmakuSliderRow(title: "描边粗细", value: $settings.danmaku.strokeWidth, range: 0...5, step: 0.5,
                                 format: { String(format: "%.1f", $0) })
                DanmakuSliderRow(title: "弹幕行高", value: $settings.danmaku.lineHeight, range: 1...3, step: 0.1,
                                 format: { String(format: "%.1f", $0) })
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示区域")
                    DanmakuAreaPicker(area: $settings.danmaku.area)
                }
                .padding(.vertical, 2)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("弹幕速度")
                    DanmakuSpeedPicker(settings: $settings.danmaku)
                }
                .padding(.vertical, 2)
                Stepper(value: $settings.danmaku.scrollDuration, in: 1...50, step: 1) {
                    DanmakuValueLabel(title: "滚动弹幕时长", value: String(format: "%.1f 秒", settings.danmaku.scrollDuration))
                }
                Stepper(value: $settings.danmaku.fixedDuration, in: 1...50, step: 1) {
                    DanmakuValueLabel(title: "静态弹幕时长", value: String(format: "%.1f 秒", settings.danmaku.fixedDuration))
                }
                Toggle("滚动弹幕固定速度", isOn: $settings.danmaku.scrollFixedVelocity)
            } header: {
                Text("速度")
            } footer: {
                Text("时长越短速度越快；倍速播放时弹幕随视频同步加速。")
            }

            Section("按类型屏蔽") {
                Toggle("滚动弹幕", isOn: $settings.danmaku.hideScroll)
                Toggle("顶部弹幕", isOn: $settings.danmaku.hideTop)
                Toggle("底部弹幕", isOn: $settings.danmaku.hideBottom)
                Toggle("彩色弹幕", isOn: $settings.danmaku.hideColorful)
                Toggle("高级弹幕", isOn: $settings.danmaku.hideAdvanced)
            }

            Section {
                Stepper(value: $settings.danmaku.cloudBlockLevel, in: 0...11) {
                    DanmakuValueLabel(title: "智能云屏蔽",
                                      value: settings.danmaku.cloudBlockLevel == 0 ? "关闭" : "\(settings.danmaku.cloudBlockLevel) 级")
                }
                NavigationLink {
                    DanmakuBlockListView()
                } label: {
                    DanmakuValueLabel(title: "屏蔽管理", value: "\(blockRuleCount)")
                }
            } header: {
                Text("屏蔽")
            } footer: {
                Text("等级越高，屏蔽的低质量弹幕越多。关键词与用户屏蔽在加载弹幕时生效。")
            }

            Section {
                Toggle("合并重复弹幕", isOn: $settings.danmaku.mergeDuplicates)
                Toggle("海量弹幕", isOn: $settings.danmaku.allowOverlap)
                Toggle("固定转滚动", isOn: $settings.danmaku.static2Scroll)
                Toggle("显示会员彩色弹幕", isOn: $settings.danmaku.showVipColorful)
                Picker("同屏最大数量", selection: $settings.danmaku.maxOnScreen) {
                    ForEach(DanmakuSettingsView.maxOnScreenChoices, id: \.self) { n in
                        Text(n == 0 ? "不限" : "\(n) 条").tag(n)
                    }
                }
            } header: {
                Text("其他")
            } footer: {
                Text("海量弹幕：轨道已满时叠加显示，而不是丢弃。固定转滚动：放不下的顶部/底部弹幕改为滚动显示。")
            }

            Section {
                Button("恢复默认设置", role: .destructive) { showResetConfirm = true }
            }
        }
        .navigationTitle("弹幕设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复弹幕默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { settings.danmaku.resetDisplayOptions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("屏蔽关键词、正则和用户不会被清除。")
        }
    }

    private var blockRuleCount: Int {
        settings.danmaku.blockedKeywords.count + settings.danmaku.blockedUsers.count
    }
}

/// Compact danmaku sheet for the player: on/off, opacity, size, area, speed, link to everything.
/// Present it with `.sheet { DanmakuQuickPanel() }`.
struct DanmakuQuickPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("显示弹幕", isOn: $settings.danmaku.enabled)
                DanmakuSliderRow(title: "不透明度", value: $settings.danmaku.opacity, range: 0...1, step: 0.01,
                                 format: DanmakuSliderRow.percent)
                DanmakuSliderRow(title: "字体大小", value: $settings.danmaku.fontScale, range: 0.5...2.5, step: 0.05,
                                 format: DanmakuSliderRow.percent)
                Toggle("粗体", isOn: $settings.danmaku.bold)
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示区域")
                    DanmakuAreaPicker(area: $settings.danmaku.area)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("弹幕速度")
                    DanmakuSpeedPicker(settings: $settings.danmaku)
                }
                .padding(.vertical, 2)
                Toggle("合并重复弹幕", isOn: $settings.danmaku.mergeDuplicates)
                NavigationLink {
                    DanmakuSettingsView()
                } label: {
                    Text("更多弹幕设置")
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // Own toast layer: the app's lies under this sheet (e.g. 「导入账号云端屏蔽列表」 feedback).
        .overlay { ToastOverlay() }
        .presentationDetents([.medium, .large])
    }
}

/// 「弹幕屏蔽」: keyword / regex / user rules stored in `DanmakuSettings`.
struct DanmakuBlockListView: View {
    enum Kind: Int, CaseIterable, Identifiable {
        case keyword, regex, user
        var id: Int { rawValue }
    }

    @ObservedObject private var settings = AppSettings.shared
    @State private var kind: Kind = .keyword
    @State private var input = ""
    @State private var message: String?
    @State private var syncing = false

    var body: some View {
        List {
            Section {
                Picker("类型", selection: $kind) {
                    Text("关键词(\(keywordRules.count))").tag(Kind.keyword)
                    Text("正则(\(regexRules.count))").tag(Kind.regex)
                    Text("用户(\(settings.danmaku.blockedUsers.count))").tag(Kind.user)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    TextField(placeholder, text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(kind == .user ? .numberPad : .default)
                        .submitLabel(.done)
                        .onSubmit(add)
                    // Borderless: otherwise the whole row (including the text field) triggers `add`.
                    Button("添加", action: add)
                        .buttonStyle(.borderless)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section {
                if rows.isEmpty {
                    Text("暂无屏蔽规则").foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.self) { rule in
                        Text(displayText(rule)).lineLimit(2)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                Text("左滑删除。屏蔽规则在加载弹幕时生效。")
            }

            if BiliHTTP.shared.isLoggedIn {
                Section {
                    Button {
                        sync()
                    } label: {
                        HStack {
                            Text("导入账号云端屏蔽列表")
                            if syncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncing)
                }
            }
        }
        .navigationTitle("弹幕屏蔽")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) { _ in
            input = ""
            message = nil
        }
    }

    private var keywordRules: [String] {
        settings.danmaku.blockedKeywords.filter { DanmakuFilter.regexPattern(from: $0) == nil }
    }

    private var regexRules: [String] {
        settings.danmaku.blockedKeywords.filter { DanmakuFilter.regexPattern(from: $0) != nil }
    }

    private var rows: [String] {
        switch kind {
        case .keyword: return keywordRules
        case .regex: return regexRules
        case .user: return settings.danmaku.blockedUsers
        }
    }

    private var placeholder: String {
        switch kind {
        case .keyword: return "输入过滤的关键词，其它类别请切换标签页后添加"
        case .regex: return "输入//之间的正则表达式，无需包含头尾的\"/\""
        case .user: return "输入用户UID"
        }
    }

    private func displayText(_ rule: String) -> String {
        switch kind {
        case .keyword: return rule
        case .regex: return DanmakuFilter.regexPattern(from: rule).map { "/\($0)/" } ?? rule
        case .user:
            if let uid = settings.danmaku.blockedUserLabels[rule] { return "UID \(uid)" }
            return "用户 \(rule)"
        }
    }

    private func add() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        message = nil
        switch kind {
        case .keyword:
            guard !settings.danmaku.blockedKeywords.contains(t) else { message = "已存在"; return }
            settings.danmaku.blockedKeywords.append(t)
        case .regex:
            var pattern = t
            if let inner = DanmakuFilter.regexPattern(from: t) { pattern = inner }
            guard !pattern.isEmpty, DanmakuFilter.isValidRegex(pattern) else { message = "正则表达式无效"; return }
            let rule = "/\(pattern)/"
            guard !settings.danmaku.blockedKeywords.contains(rule) else { message = "已存在"; return }
            settings.danmaku.blockedKeywords.append(rule)
        case .user:
            guard let hash = DanmakuHash.normalizeUserRule(t) else { message = "请输入正确的用户UID"; return }
            guard !settings.danmaku.blockedUsers.contains(hash) else { message = "已存在"; return }
            settings.danmaku.blockedUsers.append(hash)
            if t.allSatisfy({ $0.isASCII && $0.isNumber }) { settings.danmaku.blockedUserLabels[hash] = t }
        }
        input = ""
    }

    private func delete(_ offsets: IndexSet) {
        let doomed = Set(offsets.compactMap { rows.indices.contains($0) ? rows[$0] : nil })
        switch kind {
        case .keyword, .regex:
            settings.danmaku.blockedKeywords.removeAll { doomed.contains($0) }
        case .user:
            settings.danmaku.blockedUsers.removeAll { doomed.contains($0) }
            for h in doomed { settings.danmaku.blockedUserLabels[h] = nil }
        }
    }

    private func sync() {
        syncing = true
        message = nil
        Task { @MainActor in
            do {
                let rules = try await DanmakuService.fetchCloudRules()
                var s = settings.danmaku
                let added = DanmakuCloudRule.merge(rules, into: &s)
                settings.danmaku = s
                ToastCenter.shared.show(added > 0 ? "已导入 \(added) 条屏蔽规则" : "屏蔽列表已是最新")
            } catch {
                message = error.localizedDescription
            }
            syncing = false
        }
    }
}

// MARK: - Rows

/// Title + current value on one line, slider below.
struct DanmakuSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DanmakuValueLabel(title: title, value: format(value))
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

struct DanmakuValueLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// 「显示区域」 1/4 · 半屏 · 3/4 · 满屏.
struct DanmakuAreaPicker: View {
    @Binding var area: DanmakuArea

    var body: some View {
        Picker("显示区域", selection: $area) {
            ForEach(DanmakuArea.allCases) { a in
                Text(a.title).tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// 「弹幕速度」 presets (slower ↔ faster) mapped onto `scrollDuration`.
struct DanmakuSpeedPicker: View {
    @Binding var settings: DanmakuSettings

    var body: some View {
        Picker("弹幕速度", selection: Binding(
            get: { settings.speedPresetIndex },
            set: { settings.scrollDuration = DanmakuSettings.speedPresets[$0].duration }
        )) {
            ForEach(DanmakuSettings.speedPresets.indices, id: \.self) { i in
                Text(DanmakuSettings.speedPresets[i].title).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
