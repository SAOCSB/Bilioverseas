import SwiftUI

/// 我的 → 设置 (route `.settings`). Grouped list like the official client; every sub-page is pushed
/// through `Route` so it works inside any tab's `NavigationStack`.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var searchHistory = SearchHistoryStore.shared

    @State private var cacheBytes: Int64?
    @State private var showClearCacheConfirm = false
    @State private var showResetConfirm = false
    @State private var showLogoutConfirm = false
    @State private var isLoggingOut = false

    var body: some View {
        Form {
            accelerationSection
            playbackSection
            adSection
            appearanceSection
            privacySection
            storageSection
            aboutSection
            resetSection
            if auth.isLoggedIn {
                logoutSection
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
    }

    // MARK: - Sections

    private var accelerationSection: some View {
        Section {
            NavigationLink(value: Route.settingsAcceleration) {
                SettingsIconLabel("海外加速", systemImage: "bolt.fill", tint: .biliPink, subtitle: accelerationSummary)
            }
        } footer: {
            Text("多线程 + 多 CDN 智能调度，改善海外观看卡顿、冷门视频加载慢的问题。")
        }
    }

    private var playbackSection: some View {
        Section {
            NavigationLink(value: Route.settingsPlayer) {
                SettingsIconLabel("播放设置", systemImage: "play.rectangle.fill", tint: .blue,
                                  detail: VideoQuality.title(for: settings.player.preferredQuality))
            }
            NavigationLink(value: Route.settingsDanmaku) {
                SettingsIconLabel("弹幕设置", systemImage: "text.bubble.fill", tint: .cyan,
                                  detail: settings.danmaku.enabled ? "已开启" : "已关闭")
            }
        } header: {
            Text("播放")
        }
    }

    private var adSection: some View {
        Section {
            NavigationLink(value: Route.settingsFeedFilter) {
                SettingsIconLabel("广告屏蔽", systemImage: "hand.raised.fill", tint: .orange,
                                  subtitle: "屏蔽广告卡片和恰饭视频",
                                  detail: settings.feedFilter.blockAdCards ? "已开启" : "已关闭")
            }
            NavigationLink(value: Route.settingsSmartSkip) {
                SettingsIconLabel("广告跳过", systemImage: "forward.end.fill", tint: .green,
                                  subtitle: "跳过视频内的口播广告",
                                  detail: smartSkipSummary)
            }
        } header: {
            Text("广告")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("主题", selection: $settings.general.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(verbatim: theme.title).tag(theme)
                }
            }
            .pickerStyle(.menu)
            SettingsValuePicker(title: "首页列数", selection: $settings.general.feedColumns, options: [1, 2]) { n in
                n <= 1 ? "单列" : "双列"
            }
            SettingsToggleRow(title: "省流量封面", subtitle: "加载较小尺寸的封面和头像，节省流量",
                              isOn: $settings.general.compactImages)
        } header: {
            Text("外观")
        }
    }

    private var privacySection: some View {
        Section {
            SettingsToggleRow(title: "记录观看历史", subtitle: "向 B 站上报播放进度，用于「历史记录」和续播",
                              isOn: $settings.general.reportHistory)
            Toggle("保存搜索历史", isOn: $settings.general.saveSearchHistory)
            if !searchHistory.keywords.isEmpty {
                Button("清空搜索历史") {
                    searchHistory.clear()
                    ToastCenter.shared.show("已清空搜索历史")
                }
            }
        } header: {
            Text("隐私")
        } footer: {
            Text("关闭「记录观看历史」后，观看的视频不会出现在 B 站历史记录中，也无法在其他设备上继续播放。")
        }
    }

    private var storageSection: some View {
        Section {
            Button {
                showClearCacheConfirm = true
            } label: {
                HStack {
                    Text("清除图片缓存")
                    Spacer()
                    if let cacheBytes {
                        Text(verbatim: Fmt.bytes(Double(cacheBytes)))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .confirmationDialog("清除图片缓存？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
                Button("清除", role: .destructive) { clearImageCache() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("封面、头像等图片之后会重新下载。")
            }
        } header: {
            Text("存储")
        } footer: {
            Text("只清除封面、头像等图片缓存，不影响设置、登录状态和观看记录。")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink(value: Route.about) {
                SettingsIconLabel("关于", systemImage: "info.circle.fill", tint: .gray, detail: Self.appVersion)
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("恢复默认设置") { showResetConfirm = true }
                .confirmationDialog("恢复默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("恢复默认", role: .destructive) {
                        settings.resetAll()
                        ToastCenter.shared.show("已恢复默认设置")
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("加速、播放、弹幕、屏蔽、广告跳过和外观设置都会恢复为默认值，弹幕与推荐的屏蔽词、屏蔽用户也会被清空。登录状态不受影响。")
                }
        }
    }

    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                HStack {
                    Spacer()
                    if isLoggingOut {
                        ProgressView()
                    } else {
                        Text("退出登录")
                    }
                    Spacer()
                }
            }
            .disabled(isLoggingOut)
            .confirmationDialog("确定退出登录吗？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { logout() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后，观看历史、收藏和稍后再看将不再同步到此设备。")
            }
        } footer: {
            if let name = auth.profile?.name, !name.isEmpty {
                Text(verbatim: "当前账号：\(name)")
            }
        }
    }

    // MARK: - Summaries

    private var accelerationSummary: String {
        let a = settings.acceleration
        guard a.enabled else { return "已关闭" }
        let mode: String
        switch a.cdnMode {
        case .mainland: mode = "大陆 CDN"
        case .overseas: mode = "海外 CDN"
        case .custom: mode = a.customHosts.isEmpty ? "自定义（未选服务器）" : "自定义 \(a.customHosts.count) 个服务器"
        case .original: mode = "官方分配"
        }
        let threads = a.autoConcurrency ? "自动线程" : "\(a.manualConcurrency) 线程"
        return "\(mode) · \(threads)"
    }

    private var smartSkipSummary: String {
        guard settings.smartSkip.enabled else { return "已关闭" }
        return settings.smartSkip.mode == .auto ? "自动" : "手动"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        return short
    }

    // MARK: - Actions

    @MainActor
    private func refreshCacheSize() async {
        let bytes = await Task.detached(priority: .utility) { SettingsImageCache.diskUsage() }.value
        cacheBytes = bytes
    }

    private func clearImageCache() {
        SettingsImageCache.clear()
        cacheBytes = 0
        ToastCenter.shared.show("已清除图片缓存")
        Task { await refreshCacheSize() }
    }

    private func logout() {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        Task { @MainActor in
            await AuthService.shared.logout()
            isLoggingOut = false
            ToastCenter.shared.show("已退出登录")
        }
    }
}
