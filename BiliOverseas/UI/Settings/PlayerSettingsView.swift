import SwiftUI
import CoreMedia
import VideoToolbox

/// 设置 → 播放设置 (route `.settingsPlayer`). Everything binds to `AppSettings.shared.player`; the
/// player reads these values when a video opens (speed / long-press / gestures apply live).
struct PlayerSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showResetConfirm = false

    static let longPressSpeedOptions: [Double] = [1.5, 2.0, 2.5, 3.0]
    static let seekStepOptions: [Double] = [5, 10, 15, 30]
    static let slideSeekOptions: [Double] = [25, 50, 90, 100]

    /// `'av01'` FourCC; spelled out so this does not depend on the `kCMVideoCodecType_AV1` constant.
    private static let av1CodecType: CMVideoCodecType = 0x6176_3031
    static let supportsAV1HardwareDecode: Bool = VTIsHardwareDecodeSupported(av1CodecType)

    var body: some View {
        Form {
            qualitySection
            codecSection
            hdrAudioSection
            speedSection
            gestureSection
            playbackSection
            subtitleSection
            backgroundSection
            videoPageSection

            Section {
                Button("恢复播放默认设置") { showResetConfirm = true }
                    .confirmationDialog("恢复播放默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("恢复默认", role: .destructive) {
                            let stats = settings.player.showAccelerationStats
                            var defaults = PlayerSettings()
                            // The stats overlay belongs to 海外加速 and has its own reset there.
                            defaults.showAccelerationStats = stats
                            settings.player = defaults
                            ToastCenter.shared.show("已恢复默认设置")
                        }
                        Button("取消", role: .cancel) {}
                    }
            }
        }
        .navigationTitle("播放设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var qualitySection: some View {
        Section {
            Picker(selection: $settings.player.preferredQuality) {
                ForEach(qualityOptions, id: \.self) { qn in
                    Text(verbatim: VideoQuality.title(for: qn)).tag(qn)
                }
            } label: {
                Text("默认画质")
            }
            .pickerStyle(.menu)
        } header: {
            Text("画质")
        } footer: {
            Text("视频没有所选画质时，自动选择不高于它的最高画质。未登录最高 480P（部分视频可免登录看 1080P）；1080P 需要登录；1080P+、1080P60、4K、HDR、杜比视界和 8K 需要大会员。")
        }
    }

    private var codecSection: some View {
        Section {
            ForEach(VideoCodecPreference.allCases) { codec in
                SettingsChoiceRow(title: codec.title, subtitle: Self.explanation(for: codec),
                                  isSelected: settings.player.preferredCodec == codec) {
                    settings.player.preferredCodec = codec
                }
            }
        } header: {
            Text("视频编码")
        } footer: {
            Text("视频没有所选编码时，自动使用其他编码。")
        }
    }

    private var hdrAudioSection: some View {
        Section {
            SettingsToggleRow(title: "HDR / 杜比视界", subtitle: "有 HDR 或杜比视界版本时优先播放（需要大会员和支持 HDR 的屏幕）",
                              isOn: $settings.player.allowHDR)
            SettingsToggleRow(title: "无损 / 杜比全景声音频", subtitle: "有 Hi-Res 无损或杜比全景声音轨时优先播放（需要大会员，流量消耗更大）",
                              isOn: $settings.player.preferLosslessAudio)
        } header: {
            Text("HDR 与音质")
        }
    }

    private var speedSection: some View {
        Section {
            SettingsValuePicker(title: "默认播放速度", selection: $settings.player.defaultSpeed,
                                options: settings.player.speedOptions.isEmpty ? [1.0] : settings.player.speedOptions) {
                SettingsFormat.speed($0)
            }
            Toggle("长按倍速", isOn: $settings.player.longPressSpeedEnabled)
            if settings.player.longPressSpeedEnabled {
                SettingsValuePicker(title: "长按倍速倍率", selection: $settings.player.longPressSpeed,
                                    options: Self.longPressSpeedOptions) { SettingsFormat.speed($0) }
            }
        } header: {
            Text("倍速")
        } footer: {
            Text("长按播放器画面时临时加速播放，松手恢复原来的速度。在播放器中切换的倍速只对当前视频生效。经加速代理（HLS）播放时最高 2 倍速：选择 2.5x 或 3.0x 会按 2.0x 播放，只有直连 MP4 播放支持更高倍速。")
        }
    }

    private var gestureSection: some View {
        Section {
            Picker("双击操作", selection: $settings.player.doubleTapAction) {
                ForEach(DoubleTapAction.allCases) { action in
                    Text(verbatim: action.title).tag(action)
                }
            }
            .pickerStyle(.menu)
            SettingsValuePicker(title: "快进快退步长", selection: $settings.player.seekStep,
                                options: Self.seekStepOptions) { SettingsFormat.seconds($0) }
            SettingsValuePicker(title: "滑动快进/快退时长", selection: $settings.player.slideSeekSeconds,
                                options: Self.slideSeekOptions) { SettingsFormat.seconds($0) }
            SettingsToggleRow(title: "左右侧滑动调节亮度/音量", subtitle: "在画面左侧上下滑动调节亮度，右侧调节音量",
                              isOn: $settings.player.slideVolumeBrightness)
            SettingsToggleRow(title: "中间滑动进入/退出全屏", subtitle: "在画面中间上滑进入全屏，下滑退出全屏",
                              isOn: $settings.player.slideFullscreen)
        } header: {
            Text("手势")
        } footer: {
            Text("「左右快退/快进」：双击画面左侧四分之一快退、右侧四分之一快进，中间暂停/播放。")
        }
    }

    /// 「字幕设置」 (features.md §3.7), applied live to the player's subtitle line.
    private var subtitleSection: some View {
        Section {
            DanmakuSliderRow(title: "字体大小", value: $settings.player.subtitleFontScale, range: 0.5...2.5, step: 0.01,
                             format: DanmakuSliderRow.percent)
            DanmakuSliderRow(title: "全屏字体大小", value: $settings.player.subtitleFontScaleFullscreen, range: 0.5...2.5,
                             step: 0.01, format: DanmakuSliderRow.percent)
            Stepper(value: $settings.player.subtitleFontWeight, in: 0...8) {
                DanmakuValueLabel(title: "字体粗细", value: "\(settings.player.subtitleFontWeight + 1)")
            }
            DanmakuSliderRow(title: "背景不透明度", value: $settings.player.subtitleBgOpacity, range: 0...1, step: 0.01,
                             format: DanmakuSliderRow.percent)
            DanmakuSliderRow(title: "描边粗细", value: $settings.player.subtitleStrokeWidth, range: 0...5, step: 0.5,
                             format: { String(format: "%.1f", $0) })
            DanmakuSliderRow(title: "左右边距", value: $settings.player.subtitlePaddingH, range: 0...100, step: 1,
                             format: { "\(Int($0))" })
            DanmakuSliderRow(title: "底部边距", value: $settings.player.subtitleBottomPadding, range: 0...200, step: 1,
                             format: { "\(Int($0))" })
        } header: {
            Text("字幕设置")
        } footer: {
            Text("描边只在背景不透明度为 0 时显示。显示控制栏时字幕会上移，避免被遮挡。")
        }
    }

    private var playbackSection: some View {
        Section {
            SettingsToggleRow(title: "自动播放", subtitle: "打开视频页后自动开始播放",
                              isOn: $settings.player.autoPlay)
            Picker("播放顺序", selection: $settings.player.playRepeat) {
                ForEach(PlayRepeat.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            SettingsToggleRow(title: "记忆播放进度", subtitle: "从上次看到的位置继续播放",
                              isOn: $settings.player.resumeProgress)
            Toggle("默认显示字幕", isOn: $settings.player.showSubtitles)
            SettingsToggleRow(title: "横屏自动全屏", subtitle: "横屏视频旋转手机时自动进入全屏",
                              isOn: $settings.player.autoFullscreenOnRotate)
            Picker("底部细进度条", selection: $settings.player.thinProgressMode) {
                ForEach(ThinProgressMode.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Picker("番剧片头/片尾", selection: $settings.player.pgcSkipType) {
                ForEach(PGCClipSkipType.allCases) { type in
                    Text(verbatim: type.title).tag(type)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("播放")
        } footer: {
            Text("播放顺序：" + settings.player.playRepeat.explanation
                 + "番剧片头/片尾：「跳过一次」每集只自动跳过一次，「手动跳过」显示跳过按钮，「仅显示」只在进度条上标出。"
                 + "底部细进度条：控制栏隐藏时画面底部的细进度线。")
        }
    }

    private var backgroundSection: some View {
        Section {
            SettingsToggleRow(title: "后台播放", subtitle: "切到后台或锁屏后继续播放声音",
                              isOn: $settings.player.backgroundPlay)
            SettingsToggleRow(title: "自动画中画", subtitle: "播放时回到主屏幕自动进入画中画",
                              isOn: $settings.player.autoPiP)
        } header: {
            Text("后台与画中画")
        } footer: {
            Text("画中画窗口中不显示弹幕。")
        }
    }

    private var videoPageSection: some View {
        Section {
            SettingsToggleRow(title: "快速收藏", subtitle: "点击收藏直接加入默认收藏夹，长按选择收藏夹",
                              isOn: $settings.player.quickFavorite)
        } header: {
            Text("视频页")
        }
    }

    // MARK: - Helpers

    /// Highest first, like the official quality menu; keeps an unknown stored `qn` selectable.
    private var qualityOptions: [Int] {
        var list = VideoQuality.allCases.map(\.rawValue).sorted(by: >)
        let current = settings.player.preferredQuality
        if !list.contains(current) {
            list.append(current)
            list.sort(by: >)
        }
        return list
    }

    static func explanation(for codec: VideoCodecPreference) -> String {
        switch codec {
        case .avc:
            return "所有设备都能硬件解码，兼容性最好；同画质下码率最高、最费流量。"
        case .hevc:
            return "同画质更省流量，本机支持硬件解码。推荐。"
        case .av1:
            let device = supportsAV1HardwareDecode ? "本机支持 AV1 硬件解码。" : "本机不支持 AV1 硬件解码，将改用 HEVC 或 H.264。"
            return "压缩率最高、最省流量，仅 A17 Pro / M3 及以上芯片硬解。" + device
        }
    }
}
