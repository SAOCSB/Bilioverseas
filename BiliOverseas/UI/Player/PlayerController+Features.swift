import Foundation
import UIKit

// Side features of the player: player/wbi/v2 side data (subtitles, chapters, preview toast), SmartSkip (UGC) and
// PGC 片头/片尾 clips, the resume chip, online count, seek thumbnails, the stats overlay, 定时关闭 and brightness.

extension PlayerController {
    // MARK: Side data

    func loadSideData(_ target: PlaybackItem, generation gen: Int) async {
        let fetched = try? await VideoAPI.playerExtra(aid: target.aid, cid: target.cid, bvid: target.bvid,
                                                      epId: target.epId, seasonId: target.seasonId)
        guard gen == loadGeneration, !Task.isCancelled else { return }
        extra = fetched
        chapters = target.chapters ?? fetched?.chapters ?? []
        subtitleTracks = fetched?.subtitles ?? []
        if let toast = fetched?.previewToast, playInfo?.isTrial != true {
            ToastCenter.shared.show(toast, duration: 3)
        }
        autoSelectSubtitle()
        startSmartSkip(target, extra: fetched, generation: gen)
        fetchOnlineCount(target, generation: gen)
    }

    func cancelFeatureTasks() {
        smartSkipTask?.cancel()
        smartSkipTask = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        videoShotTask?.cancel()
        videoShotTask = nil
        onlineTask?.cancel()
        onlineTask = nil
        resumeChipTask?.cancel()
        resumeChipTask = nil
        for task in subtitleFetches.values { task.cancel() }
        subtitleFetches = [:]
    }

    /// Per-video feature state (the sleep timer survives part changes on purpose).
    func resetFeatureState() {
        chapters = []
        subtitleTracks = []
        selectedSubtitleId = nil
        subtitleText = nil
        subtitleLines = []
        subtitleCache = [:]
        adSegments = []
        skipPrompt = nil
        tracker = nil
        pgcClips = []
        clipPrompt = nil
        dismissedClips = []
        resumeChipTime = nil
        onlineCount = nil
        lastOnlineFetch = nil
        stats = nil
        networkSpeed = 0
        videoShot = nil
    }

    // MARK: Subtitles

    private func autoSelectSubtitle() {
        guard AppSettings.shared.player.showSubtitles, selectedSubtitleId == nil,
              let track = subtitleTracks.first(where: { !$0.isAI }) else { return }
        selectSubtitle(track.id)
    }

    /// nil = 关闭字幕.
    func selectSubtitle(_ id: Int64?) {
        subtitleTask?.cancel()
        selectedSubtitleId = id
        subtitleLines = []
        subtitleText = nil
        guard let id, let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        let gen = loadGeneration
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            let lines = await self.subtitleLines(for: track)
            guard !Task.isCancelled, gen == self.loadGeneration, self.selectedSubtitleId == id else { return }
            self.subtitleLines = lines
            if lines.isEmpty { ToastCenter.shared.show("字幕加载失败") }
            self.updateSubtitle(at: self.displayTime())
        }
    }

    /// Subtitle body of a track, fetched once per video (shared by the display and SmartSkip).
    func subtitleLines(for track: SubtitleTrack) async -> [SubtitleLine] {
        if let cached = subtitleCache[track.id] { return cached }
        if let running = subtitleFetches[track.id] { return await running.value }
        let url = track.url
        let gen = loadGeneration
        let task = Task<[SubtitleLine], Never> {
            (try? await VideoAPI.subtitleLines(url: url)) ?? []
        }
        subtitleFetches[track.id] = task
        let lines = await task.value
        guard gen == loadGeneration else { return lines }
        subtitleFetches[track.id] = nil
        if !lines.isEmpty { subtitleCache[track.id] = lines }
        return lines
    }

    func updateSubtitle(at t: Double) {
        guard !subtitleLines.isEmpty else {
            if subtitleText != nil { subtitleText = nil }
            return
        }
        var lo = 0
        var hi = subtitleLines.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if subtitleLines[mid].from <= t {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        var text: String?
        if let i = found, t < subtitleLines[i].to { text = subtitleLines[i].content }
        if text != subtitleText { subtitleText = text }
    }

    // MARK: SmartSkip (UGC only)

    private func startSmartSkip(_ target: PlaybackItem, extra info: PlayerExtraInfo?, generation gen: Int) {
        guard target.epId == 0, AppSettings.shared.smartSkip.enabled else { return }
        smartSkipTask?.cancel()
        smartSkipTask = Task { [weak self] in
            // nil = "fetch it yourself", [] = "known empty" (SmartSkipVideoContext contract).
            let tracks: [SubtitleTrack]? = info?.subtitles
            var lines: [SubtitleLine]?
            if let tracks {
                if let chosen = SmartSkipDataLoader.chooseSubtitleTrack(tracks) {
                    lines = await self?.subtitleLines(for: chosen)
                } else {
                    lines = []
                }
            }
            guard let self, gen == self.loadGeneration, !Task.isCancelled else { return }
            let total = target.duration > 0 ? target.duration : (self.playInfo?.duration ?? 0)
            let context = SmartSkipVideoContext(aid: target.aid, bvid: target.bvid, cid: target.cid, page: 1,
                                                duration: total, title: target.title, desc: target.desc,
                                                chapters: target.chapters ?? info?.chapters,
                                                subtitleTracks: tracks, subtitleLines: lines, danmaku: nil)
            let segments = await SmartSkipAnalyzer.shared.analyze(context)
            guard gen == self.loadGeneration, !Task.isCancelled else { return }
            self.adSegments = segments
            let s = AppSettings.shared.smartSkip
            self.tracker = segments.isEmpty ? nil
                : SmartSkipTracker(segments: segments, mode: s.mode, countdownSeconds: Double(s.countdownSeconds))
            self.smartSkipTick(time: self.displayTime(), playing: self.isActuallyPlaying)
        }
    }

    func smartSkipTick(time: Double, playing: Bool) {
        guard let tracker else { return }
        let s = AppSettings.shared.smartSkip
        guard s.enabled else {
            if skipPrompt != nil { skipPrompt = nil }
            return
        }
        tracker.mode = s.mode
        tracker.countdownSeconds = Double(s.countdownSeconds)
        guard startupDone, !isSeeking,
              let action = tracker.update(time: time, isPlaying: playing, now: ProcessInfo.processInfo.systemUptime)
        else { return }
        switch action {
        case .autoSkip(let segment):
            skipPrompt = nil
            performSeek(to: segment.seekTarget, origin: .smartSkip)
            if s.showToast {
                let gen = loadGeneration
                ToastCenter.shared.show("已跳过广告", duration: 4, actionTitle: "撤销") { [weak self] in
                    // Not into another video loaded since (segment ids are just "start:end").
                    guard let self, gen == self.loadGeneration else { return }
                    self.undoSmartSkip(segment)
                }
            }
        case .showPrompt(let segment, let remaining):
            let next = PlayerSkipPrompt(segment: segment, remaining: remaining)
            if next != skipPrompt { skipPrompt = next }
        case .hidePrompt:
            skipPrompt = nil
        }
    }

    func smartSkipTapped(_ segment: AdSegment) {
        skipPrompt = nil
        if let target = tracker?.userSkipped(segment) { performSeek(to: target, origin: .smartSkip) }
    }

    func smartSkipDismissed(_ segment: AdSegment) {
        tracker?.userDismissed(segment)
        skipPrompt = nil
    }

    func smartSkipInteraction(_ active: Bool) {
        tracker?.setInteracting(active, now: ProcessInfo.processInfo.systemUptime)
    }

    private func undoSmartSkip(_ segment: AdSegment) {
        if let target = tracker?.undo(segment) { performSeek(to: target, origin: .smartSkip) }
    }

    // MARK: PGC 片头 / 片尾

    static func clipKey(_ clip: PGCClipInfo) -> String { "\(clip.rawType):\(clip.start)-\(clip.end)" }

    static func clipTitle(_ clip: PGCClipInfo) -> String {
        switch clip.kind {
        case .opening: return "跳过片头"
        case .ending: return "跳过片尾"
        case .other: return "跳过"
        }
    }

    func clipTick(time t: Double) {
        guard !pgcClips.isEmpty, startupDone else {
            if clipPrompt != nil, pgcClips.isEmpty { clipPrompt = nil }
            return
        }
        let active = pgcClips.first { t >= $0.start && t < $0.end - 1 && !dismissedClips.contains(Self.clipKey($0)) }
        if active != clipPrompt { clipPrompt = active }
    }

    func skipClip() {
        guard let clip = clipPrompt else { return }
        dismissedClips.insert(Self.clipKey(clip))
        clipPrompt = nil
        performSeek(to: clip.end, origin: .user)
        ToastCenter.shared.show(clip.kind == .ending ? "已跳过片尾" : "已跳过片头")
    }

    func dismissClip() {
        guard let clip = clipPrompt else { return }
        dismissedClips.insert(Self.clipKey(clip))
        clipPrompt = nil
    }

    // MARK: Resume chip 「已为你定位至 mm:ss」

    func showResumeChip(at t: Double) {
        resumeChipTask?.cancel()
        resumeChipTime = t
        let gen = loadGeneration
        resumeChipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, gen == self.loadGeneration else { return }
            self.resumeChipTime = nil
        }
    }

    func dismissResumeChip() {
        resumeChipTask?.cancel()
        resumeChipTime = nil
    }

    /// 「从头播放」.
    func restartFromBeginning() {
        dismissResumeChip()
        performSeek(to: 0, origin: .user)
    }

    // MARK: Online count 「N人正在看」

    func fetchOnlineCount(_ target: PlaybackItem, generation gen: Int) {
        guard target.aid > 0, target.cid > 0 else { return }
        lastOnlineFetch = Date()
        onlineTask?.cancel()
        onlineTask = Task { [weak self] in
            let text = try? await VideoAPI.onlineCount(aid: target.aid, cid: target.cid, bvid: target.bvid)
            guard let self, !Task.isCancelled, gen == self.loadGeneration else { return }
            if let text { self.onlineCount = "\(text)人正在看" }
        }
    }

    func onlineCountTick() {
        guard let target = item, containerVisible || isFullscreen, let last = lastOnlineFetch,
              Date().timeIntervalSince(last) >= 60 else { return }
        fetchOnlineCount(target, generation: loadGeneration)
    }

    // MARK: Seek thumbnails (videoshot)

    /// Loads the sprite sheets once per video, the first time the user scrubs.
    func ensureVideoShot() {
        guard videoShot == nil, videoShotTask == nil, let target = item, target.cid > 0 else { return }
        let gen = loadGeneration
        videoShotTask = Task { [weak self] in
            let shot = try? await VideoAPI.videoshot(aid: target.aid, bvid: target.bvid, cid: target.cid)
            guard let self, !Task.isCancelled, gen == self.loadGeneration else { return }
            if let shot, !shot.isEmpty { self.videoShot = shot }
        }
    }

    // MARK: Acceleration stats / network speed

    func refreshStats() {
        let show = AppSettings.shared.player.showAccelerationStats
        let buffering = status == .loading || status == .buffering
        guard show || buffering else {
            if stats != nil { stats = nil }
            return
        }
        guard let s = sessionStats else { return }
        // Every assignment re-renders the detail page (it observes the controller): only publish changes.
        if networkSpeed != s.bytesPerSecond { networkSpeed = s.bytesPerSecond }
        if show {
            stats = s
        } else if stats != nil {
            stats = nil
        }
    }

    // MARK: 定时关闭

    func setSleepTimer(_ timer: PlayerSleepTimer) {
        sleepTimer = timer
        switch timer {
        case .off:
            sleepDeadline = nil
            sleepRemaining = nil
            ToastCenter.shared.show("已取消定时关闭")
        case .minutes(let m):
            sleepDeadline = Date().addingTimeInterval(Double(m) * 60)
            sleepRemaining = Double(m) * 60
            ToastCenter.shared.show("设置 \(m)分钟 后定时关闭")
        case .endOfEpisode:
            sleepDeadline = nil
            sleepRemaining = nil
            ToastCenter.shared.show("将在播完本集后暂停")
        }
    }

    func sleepTimerTick() {
        guard let deadline = sleepDeadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            sleepDeadline = nil
            sleepRemaining = nil
            sleepTimer = .off
            if wantsToPlay { pause() }
            ToastCenter.shared.show("定时时间已到，已暂停")
        } else {
            sleepRemaining = left
        }
    }

    // MARK: Danmaku

    var danmakuEnabled: Bool { AppSettings.shared.danmaku.enabled }

    /// 「开启弹幕」/「关闭弹幕」 (persisted, like the official app).
    func toggleDanmaku() {
        AppSettings.shared.danmaku.enabled.toggle()
        ToastCenter.shared.show(AppSettings.shared.danmaku.enabled ? "弹幕已开启" : "弹幕已关闭")
    }

    // MARK: Brightness (restored when the page closes / the app goes to the background)

    private var activeScreen: UIScreen? {
        if let screen = surface.window?.windowScene?.screen { return screen }
        return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    var currentBrightness: CGFloat { activeScreen?.brightness ?? 0.5 }

    func setBrightness(_ value: CGFloat) {
        guard let screen = activeScreen else { return }
        if originalBrightness == nil { originalBrightness = screen.brightness }
        screen.brightness = min(max(value, 0), 1)
    }

    func restoreBrightness() {
        guard let original = originalBrightness else { return }
        originalBrightness = nil
        activeScreen?.brightness = original
    }
}
