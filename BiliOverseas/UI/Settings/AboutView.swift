import SwiftUI

/// 设置 → 关于 (route `.about`): app info, feature list, acknowledgements with license texts,
/// disclaimer and the source repository link.
struct AboutView: View {
    private struct Feature: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    private static let features: [Feature] = [
        Feature(icon: "bolt.fill", text: "海外多线程、多 CDN 智能加速"),
        Feature(icon: "text.bubble.fill", text: "可调弹幕：字号、透明度、速度、区域与屏蔽"),
        Feature(icon: "forward.fill", text: "长按倍速、双击快进快退"),
        Feature(icon: "clock.fill", text: "历史记录、收藏、稍后再看"),
        Feature(icon: "hand.raised.fill", text: "屏蔽推荐流中的广告视频"),
        Feature(icon: "forward.end.fill", text: "自动识别并跳过视频内广告"),
    ]

    var body: some View {
        Form {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Self.features) { item in
                    Label {
                        Text(verbatim: item.text)
                    } icon: {
                        Image(systemName: item.icon)
                            .foregroundStyle(Color.biliPink)
                    }
                }
            } header: {
                Text("功能")
            }

            Section {
                ForEach(AboutLicenseTexts.entries) { entry in
                    AboutLicenseRow(entry: entry)
                }
            } header: {
                Text("致谢与开源许可")
            } footer: {
                Text("感谢以上项目的作者和贡献者。点击条目查看许可证。")
            }

            Section {
                Text(verbatim: AboutLicenseTexts.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AboutLicenseTexts.repositoryURL) {
                    Label("GitHub 项目主页", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("声明")
            } footer: {
                Text(verbatim: AboutLicenseTexts.repositoryURL.absoluteString)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.biliPink)
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "tv")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.biliPink.opacity(0.35), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text("B站海外加速版")
                .font(.title2.bold())
            Text(verbatim: Self.versionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("为海外用户打造的第三方哔哩哔哩 iOS 客户端。通过多线程、多 CDN 智能调度改善海外播放卡顿、冷门视频加载慢的问题，并提供弹幕、倍速、广告屏蔽与跳过等功能。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 12)
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "版本 \(short)" : "版本 \(short) (\(build))"
    }
}

/// One acknowledgement: name, author / role and license on the label; expands to the license text.
struct AboutLicenseRow: View {
    let entry: AboutLicenseTexts.Entry
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: entry.usage)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: entry.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            // Its own row: a link inside the text row would make the whole row tappable.
            if let url = entry.url {
                Link(destination: url) {
                    Label {
                        Text(verbatim: url.absoluteString)
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } icon: {
                        Image(systemName: "link")
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .foregroundStyle(.primary)
                Text(verbatim: "\(entry.author) · \(entry.license)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Acknowledgement and license texts shown on the About page.
enum AboutLicenseTexts {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let author: String
        let license: String
        /// What this app uses from the project.
        let usage: String
        let text: String
        let url: URL?
    }

    static let repositoryURL = URL(string: "https://github.com/SAOCSB/bilbil_ios")!

    static let disclaimer = "本应用为第三方非官方客户端，与哔哩哔哩无关；不会绕过会员、地区、版权或审核限制。所有内容版权归原作者及哔哩哔哩所有。"

    static let entries: [Entry] = [
        Entry(id: "btr",
              name: "Bilibili-thread-ripper（线程撕裂者）",
              author: "Bilibili-thread-ripper contributors",
              license: "MIT",
              usage: "海外加速的多线程下载、多 CDN 选择、自动线程数与调度算法移植自该项目。",
              text: mitText(copyright: "Copyright (c) 2026 Bilibili-thread-ripper contributors"),
              url: URL(string: "https://github.com/MrTangLuyao/Bilibili-thread-ripper")),
        Entry(id: "btr-desktop",
              name: "Bilibili-thread-ripper-desktop（线程撕裂者桌面版）",
              author: "LouieTang",
              license: "MIT",
              usage: "单块请求轮换节点（inTurns）与小请求单连接规则移植自该项目。",
              text: mitText(copyright: "Copyright (c) 2026 LouieTang"),
              url: URL(string: "https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop")),
        Entry(id: "smartskip",
              name: "BiliSmartSkip（Bilibili 广告跳过助手）",
              author: "wzy403",
              license: "GPL-2.0",
              usage: "「广告跳过」根据章节、简介、字幕和弹幕识别视频内广告的算法移植自该项目。",
              text: gplNotice(program: "BiliSmartSkip", copyright: "Copyright (C) wzy403", orLater: false),
              url: URL(string: "https://github.com/wzy403/BiliSmartSkip")),
        Entry(id: "bsbsb",
              name: "BilibiliSponsorBlock（空降助手）",
              author: "hanydd 及贡献者",
              license: "社区数据 · 公开接口",
              usage: "「空降助手」通过该项目的公开接口（默认 www.bsbsb.top）获取观众提交的片段；片段类别的中文名称与说明取自该项目的 zh_CN 文案（经 PiliPlus 转引）。",
              text: sponsorBlockNotice,
              url: URL(string: "https://github.com/hanydd/BilibiliSponsorBlock")),
        Entry(id: "atv",
              name: "ATV-Bilibili-demo",
              author: "yichengchen",
              license: "GPL-2.0",
              usage: "参考了其使用 AVPlayer 播放 B 站 DASH 视频（转换为 HLS）的方案与接口用法。",
              text: gplNotice(program: "ATV-Bilibili-demo", copyright: "Copyright (C) yichengchen and contributors", orLater: false),
              url: URL(string: "https://github.com/yichengchen/ATV-Bilibili-demo")),
        Entry(id: "piliplus",
              name: "PiliPlus",
              author: "bggRGjQaUbCoE 及贡献者",
              license: "GPL-3.0",
              usage: "参考了其播放器手势、弹幕、推荐过滤与设置项的交互行为和接口协议，以及其 BTR 移植分支的代理行为（仅参考，未包含其代码）。",
              text: gpl3Notice,
              url: URL(string: "https://github.com/bggRGjQaUbCoE/PiliPlus")),
        Entry(id: "canvas-danmaku",
              name: "canvas_danmaku",
              author: "Predidit",
              license: "MIT",
              usage: "弹幕的轨道布局与滚动参数参考了该弹幕渲染库（未包含其代码）。",
              text: mitText(copyright: "Copyright (c) 2024 Predidit"),
              url: URL(string: "https://github.com/Predidit/canvas_danmaku")),
        Entry(id: "app",
              name: "B站海外加速版（本应用）",
              author: "bilbil_ios contributors",
              license: "GPL-2.0-or-later",
              usage: "本应用以 GNU 通用公共许可证第 2 版或（由你选择）任何更新版本发布，源代码见 GitHub。",
              text: gplNotice(program: "B站海外加速版 (bilbil_ios)", copyright: "Copyright (C) 2026 bilbil_ios contributors", orLater: true),
              url: repositoryURL),
    ]

    /// The MIT license text with the project's own copyright line.
    static func mitText(copyright: String) -> String {
        "MIT License\n\n\(copyright)\n\n" + mitBody
    }

    static let mitBody = """
    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """

    static func gplNotice(program: String, copyright: String, orLater: Bool) -> String {
        let version = orLater
            ? "either version 2 of the License, or (at your option) any later version"
            : "version 2 of the License"
        let licenseURL = orLater ? "https://www.gnu.org/licenses/" : "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html"
        return """
        \(program)
        \(copyright)

        This program is free software; you can redistribute it and/or modify \
        it under the terms of the GNU General Public License as published by \
        the Free Software Foundation; \(version).

        This program is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
        GNU General Public License for more details.

        You should have received a copy of the GNU General Public License \
        along with this program; if not, see \(licenseURL)
        """
    }

    static let sponsorBlockNotice = """
    BilibiliSponsorBlock
    https://github.com/hanydd/BilibiliSponsorBlock

    本应用不包含 BilibiliSponsorBlock 的程序代码，只在「空降助手」开启时（设置 → 广告跳过 → 空降助手）\
    按正在播放的视频向其服务器查询片段，不发送账号信息。片段由社区提交，内容、版权与使用条款以该项目及其服务器的说明为准。
    """

    static let gpl3Notice = """
    PiliPlus
    Copyright (C) bggRGjQaUbCoE and contributors

    This program is free software: you can redistribute it and/or modify \
    it under the terms of the GNU General Public License as published by \
    the Free Software Foundation, either version 3 of the License, or \
    (at your option) any later version.

    This program is distributed in the hope that it will be useful, \
    but WITHOUT ANY WARRANTY; without even the implied warranty of \
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License \
    along with this program; if not, see https://www.gnu.org/licenses/gpl-3.0.html
    """
}
