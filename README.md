<div align="center">

<img src="BiliOverseas/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="120" alt="图标">

# B站海外加速版（BiliOverseas）

**原生 iOS 哔哩哔哩第三方客户端，内置「线程撕裂者」多线程多 CDN 加速，专治海外看 B 站卡顿**

Swift · SwiftUI · AVPlayer · iOS 16+ · 零第三方依赖

</div>

> [!NOTE]
> 本项目是非官方、开源的第三方客户端，与哔哩哔哩（bilibili）无关。它**不会**绕过会员、登录、地区、清晰度、审核或版权限制。

## 功能

**海外加速（移植自 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)）**
- 多线程 + 多 CDN 并发 Range 下载：一个分段拆成多块，分给多条连接、多个节点同时下，校验后按顺序拼好交给播放器
- 大陆 CDN（推荐）/ 海外 CDN / 自定义节点 / 官方分配四种模式，签名地址只发给 B 站的视频服务器
- 智能调度：按实测速度加权分配（平滑加权轮询，慢于最快节点 1/12 的节点不分主块）、90 秒测速过期重新探索、坏节点/坏地址分别拉黑
- 截止时间感知的「救援」并发副本，断点续传已校验前缀，自动线程数（8→64 阶梯，起播 16 线程、跟上后回落，412/429 冷却）
- 自研 HTTP/1.1 客户端（Network.framework，ALPN 固定 http/1.1），确保 N 个线程就是 N 条真实 TCP 连接（URLSession 的 HTTP/2 多路复用会让多线程失效）
- 本地 HLS 代理：把 B 站 DASH（分离的音视频 fMP4 + sidx）实时转成本地 HLS（EXT-X-MAP + EXT-X-BYTERANGE）供 AVPlayer 播放，分段缓存、预取、拖动不重复下载
- 下载地址到期前 2 分钟自动换新；加速失败自动降级为单连接直连
- 番剧/电影加速（可关），直播加速（实验性，默认关）

**官方客户端核心功能**
- 首页：直播 / 推荐 / 热门（每周必看、入站必刷）/ 排行榜 / 番剧（追番、新番时间表、番剧排行）
- 搜索：热搜、搜索建议、搜索历史；视频 / 番剧 / 用户 / 直播结果，排序与时长筛选
- 视频详情：简介、UP 主卡片与关注、点赞 / 投币 / 收藏 / 稍后再看 / 分享、长按一键三连、分 P、合集、相关推荐；番剧选集；评论区（热度/时间排序、楼中楼、发评论、点赞）
- 播放器：画质 / 编码（HEVC/AVC/AV1）/ 倍速 / 字幕 / 章节、**长按倍速（默认 2×）**、双击暂停/快进、左右滑动进度、左侧亮度右侧音量、横屏与竖屏全屏、锁屏、画中画、后台播放、锁屏控制、记忆播放进度、自动连播、历史记录上报
- **可调节弹幕**：开关、不透明度、字号、粗体、描边、显示区域、滚动速度、顶部/底部/滚动/彩色/高级屏蔽、合并重复、智能云屏蔽等级、同屏数量、海量弹幕、关键词/正则/用户屏蔽、发送弹幕
- 动态：全部 / 视频投稿、UP 主更新栏、图文/转发/视频卡片、点赞
- 我的：扫码登录（网页 / TV）、Cookie 登录、个人信息、历史记录、收藏夹、稍后再看、我的追番、关注/粉丝、个人空间
- 直播间：HLS 播放、清晰度与线路切换、实时弹幕（WebSocket）

**广告**
- **屏蔽广告视频**：推荐流中的广告卡片、「创作推广」卡片一键屏蔽；可选屏蔽疑似恰饭/商单视频（保守规则，默认关）、直播/番剧卡片、关键词/正则/UP 主/最短时长/点赞率/播放量过滤，关注的 UP 主默认不过滤
- **视频内广告自动跳过**：完整移植 [BiliSmartSkip](https://github.com/wzy403/BiliSmartSkip)，综合章节、简介、字幕、弹幕「空降」线索识别广告区间；自动跳过（可撤销）或显示 5 秒倒计时「跳过广告」按钮；每段只自动跳过一次。番剧使用官方片头/片尾标记跳过

## 原理（为什么海外会卡、加速怎么做）

B 站网页播放器一段数据只开一条连接。海外看冷门视频时，海外边缘节点没有缓存，要回源到大陆，单条连接往往只有几 Mbps。本应用：

1. 从 playurl 拿到 DASH 的 `baseUrl` 与 `backupUrl`，按所选模式把签名地址换到多个 `upos-sz-*` 镜像节点上（只换主机名，不动签名）；
2. 并发下载 `initialization` + `sidx`，生成本地 HLS 播放列表；
3. AVPlayer 向 `http://127.0.0.1:<port>/…` 请求分段字节范围，代理把每个分段切成 64 KiB–1 MiB 的小块，按测速加权分给各节点并发下载，严格校验 `206 + Content-Range + 长度 + 文件总长`，边下边按顺序回传；
4. 慢块在快要赶不上播放时间时，另开一个副本到更快的节点，从已收到的位置续传，先到者胜；
5. 播放器的卡顿/缓冲信号驱动自动线程数。

> 多线程救不了带宽本身不够的线路：如果你的宽带跑不动当前码率，或者所有节点共用同一个拥堵出口，请降低画质。

## 架构

```
BiliOverseas/
  App/            入口、TabView、横竖屏管理
  Core/           平台无关逻辑（Foundation / Network / CryptoKit），可在 macOS/Linux 上单元测试
    Networking/   BiliHTTP（Cookie、WBI/APP 签名、风控参数）+ 各 API 服务 + 登录/账号
    Models/       宽松 JSON 解析的数据模型
    Acceleration/ BTR 下载调度器、HTTP/1.1 客户端、本地代理、sidx→HLS、分段缓存与预取
    Danmaku/      protobuf 分段解析、过滤、轨道布局
    SmartSkip/    BiliSmartSkip 移植
    Filter/       推荐流过滤（屏蔽广告视频）
    Settings/     持久化设置
  UI/             SwiftUI 界面（首页、搜索、视频详情、播放器、动态、我的、设置……）
Tests/BiliCoreTests/  约 600 个单元测试（swift test）
project.yml       XcodeGen 工程描述
```

## 安装（侧载）

本项目没有上架 App Store。GitHub Actions 每次推送都会在 macOS 上编译出**未签名 IPA**：

1. 打开仓库的 **Actions** 页，选择最新一次成功的 *iOS Build*，下载 `BiliOverseas-unsigned-ipa` 产物（推送 `v*` 标签时也会附在 Releases 里）；
2. 用自签工具安装，例如 [SideStore](https://sidestore.io)（推荐，可在手机上续签）、[AltStore](https://altstore.io) 或 Sideloadly：工具会用你自己的 Apple ID 重新签名；
3. 免费 Apple ID 签名 7 天有效，需要定期续签。

**登录提示**：由于是在同一台手机上，二维码登录页提供「保存二维码到相册」（再用官方 App 从相册扫码）、「在哔哩哔哩 App 中打开」和「Cookie 登录」。

## 自行编译

需要 macOS + Xcode 16：

```bash
brew install xcodegen
xcodegen generate
open BiliOverseas.xcodeproj        # 选择你的开发者团队后直接运行
swift test                          # 运行 Core 单元测试
```

## 建议设置

| 情况 | CDN 模式 | 线程数 |
| --- | --- | ---: |
| ⭐ 推荐 | 大陆 CDN | 自动 |
| 手动调优 | 大陆 CDN | 8 – 32 |
| 设备发热 / 省电 | 大陆 CDN | 4 – 8 |
| 本地到大陆线路很差 | 海外 CDN | 自动 |

播放器设置里可打开「显示加速统计浮层」，实时查看线程数、速度、节点状态。

## 已知限制

- AirPlay 投屏视频不可用（电视无法访问手机上的 127.0.0.1 代理），可用屏幕镜像
- 部分番剧在海外有地区限制（-10403），本应用不绕过
- 未登录最高 1080P，字幕通常需要登录
- 弹幕在画中画中不显示；高级弹幕（mode 7–9）未渲染

## 致谢与许可

- [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)（MIT）—— 加速算法来源
- [BiliSmartSkip](https://github.com/wzy403/BiliSmartSkip)（GPL-2.0）—— 视频内广告识别算法，已移植为 Swift
- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 及其 BTR 移植分支、[ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) —— 接口与行为参考

由于包含 BiliSmartSkip 的移植代码，本项目以 **GPL-2.0-or-later** 发布（见 [LICENSE](LICENSE)）。
