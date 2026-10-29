// Test support for the SmartSkip port (BiliSmartSkip by wzy403, GPL-2.0): Swift equivalents of
// upstream `tests/fixtures.cjs` and `tests/harness.cjs` @ test-branch 24d28a8 (matches master).

import XCTest
@testable import BiliCore

/// Upstream `tests/fixtures.cjs` (synthetic cases only).
enum SSFixtures {
    static func transcript(_ first: String, _ second: String, start: Double = 79, gap: Double = 20) -> [SubtitleLine] {
        [
            SubtitleLine(from: 10, to: 13, content: "今天继续介绍我们的主题"),
            SubtitleLine(from: 30, to: 33, content: "先看这个例子"),
            SubtitleLine(from: start, to: start + 4, content: first),
            SubtitleLine(from: start + gap, to: start + gap + 4, content: second),
            SubtitleLine(from: start + gap + 10, to: start + gap + 13, content: "接下来回到刚才的问题"),
        ]
    }

    static let weakSubtitles = transcript("这个工具是免费的", "然后搜索你想了解的内容")
    static let strongSubtitles = transcript("本期视频由某品牌赞助", "点击下方蓝链领取优惠券")

    static func timestamp(_ text: String = "跳过广告 2:00", _ time: Double = 74) -> SmartSkipDanmaku {
        SmartSkipDanmaku(time: time, textContent: text)
    }

    /// `line(from, content, length = 2)` of subtitle-local tests.
    static func line(_ from: Double, _ content: String, _ length: Double = 2) -> SubtitleLine {
        SubtitleLine(from: from, to: from + length, content: content)
    }

    /// `line(from, to, content)` of segment-detector tests.
    static func row(_ from: Double, _ to: Double, _ content: String) -> SubtitleLine {
        SubtitleLine(from: from, to: to, content: content)
    }

    static func chapter(_ from: Double, _ to: Double, _ content: String = "") -> VideoChapter {
        VideoChapter(from: from, to: to, title: content)
    }
}

/// Upstream harness defaults: `{ cid: 14, desc: '', duration: 600, ...videoInfo }`, bvid `BV_fixture`.
struct SSFixture {
    var cid: Int64 = 14
    var desc = ""
    var duration: Double = 600
    var title = ""
    var chapters: [VideoChapter] = []
    var subtitles: [SubtitleLine] = []
    var danmaku: [SmartSkipDanmaku] = []

    var inputs: SmartSkipInputs {
        SmartSkipInputs(bvid: "BV_fixture", cid: cid, duration: duration, title: title, desc: desc,
                        chapters: chapters, danmaku: danmaku, subtitles: subtitles)
    }
}

/// Plays the role of the `<video>` element + skip button: records seeks and the visible prompt.
final class SSHarness {
    let tracker: SmartSkipTracker
    private(set) var seeks: [Double] = []
    private(set) var autoSkips: [AdSegment] = []
    private(set) var prompt: (segment: AdSegment, remaining: Double)?
    private(set) var position: Double = 0
    private(set) var now: Double = 0
    var playing = true

    init(segments: [AdSegment], mode: SmartSkipMode = .auto, countdown: Double = 5) {
        tracker = SmartSkipTracker(segments: segments, mode: mode, countdownSeconds: countdown)
    }

    convenience init(_ segments: [SmartSkipSegment], mode: SmartSkipMode = .auto) {
        self.init(segments: segments.map(AdSegment.init), mode: mode)
    }

    /// `detectAndAttach(mode)`: primary cascade only (`getSkipSegment`), then attach.
    static func detectAndAttach(_ fixture: SSFixture, mode: SmartSkipMode = .auto) -> (SmartSkipSegment?, SSHarness) {
        let segment = SmartSkipPipeline.getSkipSegment(fixture.inputs)
        return (segment, SSHarness(segment.map { [$0] } ?? [], mode: mode))
    }

    /// `detectAllAndAttach(mode)`: the production pipeline (`getSkipSegments`).
    static func detectAllAndAttach(_ fixture: SSFixture, mode: SmartSkipMode = .auto) -> ([SmartSkipSegment], SSHarness) {
        let segments = SmartSkipPipeline.getSkipSegments(fixture.inputs)
        return (segments, SSHarness(segments, mode: mode))
    }

    func setMode(_ mode: SmartSkipMode) { tracker.mode = mode }

    /// `tick(t)`: set currentTime and fire timeupdate.
    func tick(_ time: Double) {
        position = time
        apply(tracker.update(time: time, isPlaying: playing, now: now))
    }

    /// `advanceTimers(ms)`: wall clock moves on; the periodic observer keeps reporting the
    /// current position every 0.25 s.
    func advance(_ seconds: Double) {
        var left = seconds
        while left > 1e-9 {
            let step = min(0.25, left)
            now += step
            left -= step
            apply(tracker.update(time: position, isPlaying: playing, now: now))
        }
    }

    /// Clock moves without any update (e.g. the observer is silent).
    func advanceSilently(_ seconds: Double) { now += seconds }

    /// `video.dispatch('seeked')`.
    func seeked() { tracker.didSeek(to: position) }

    /// `button.click()`.
    func click() {
        guard let p = prompt else { return }
        if let target = tracker.userSkipped(p.segment) { seek(target) }
        prompt = nil
    }

    func dismiss() {
        guard let p = prompt else { return }
        tracker.userDismissed(p.segment)
        prompt = nil
    }

    func seek(_ target: Double) {
        seeks.append(target)
        position = target
    }

    func apply(_ action: SmartSkipAction?) {
        switch action {
        case .autoSkip(let segment)?:
            autoSkips.append(segment)
            prompt = nil
            seek(segment.seekTarget)
        case .showPrompt(let segment, let remaining)?:
            prompt = (segment, remaining)
        case .hidePrompt?:
            prompt = nil
        case nil:
            break
        }
    }

    /// `button.parentElement != null`.
    var buttonVisible: Bool { prompt != nil }
    /// `/疑似广告/.test(button.textContent)`.
    var buttonIsSuspicious: Bool { prompt?.segment.requiresConfirmation == true }
}

func XCTAssertSeeks(_ h: SSHarness, _ expected: [Double], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(h.seeks.count, expected.count, "seeks \(h.seeks) != \(expected) \(message)", file: file, line: line)
    for (a, b) in zip(h.seeks, expected) {
        XCTAssertEqual(a, b, accuracy: 1e-9, "seeks \(h.seeks) != \(expected) \(message)", file: file, line: line)
    }
}

/// A scripted `SmartSkipTransport` recording every request.
final class SSFakeTransport: SmartSkipTransport, @unchecked Sendable {
    struct Request: Equatable {
        var url: String
        var query: [String: String]
        var credentials: SmartSkipCredentials
        var wbi: Bool
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var active = 0
    private(set) var peakConcurrency = 0
    let handler: (Request) async throws -> Data

    init(_ handler: @escaping (Request) async throws -> Data) {
        self.handler = handler
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

    func get(_ url: String, query: [String: String], credentials: SmartSkipCredentials, wbi: Bool) async throws -> Data {
        let request = Request(url: url, query: query, credentials: credentials, wbi: wbi)
        begin(request)
        defer { end() }
        return try await handler(request)
    }

    // NSLock is not callable directly from async functions under the Swift 6 compiler.
    private func begin(_ request: Request) {
        lock.lock()
        _requests.append(request)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        lock.unlock()
    }

    private func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    /// Upstream `protobuf(time, text)` fixture: element `[0x10, varint(ms), 0x3A, varint(len), utf8…]`
    /// wrapped as field 1.
    static func protobuf(_ items: [(time: Double, text: String)]) -> Data {
        var out: [UInt8] = []
        for item in items {
            var element = ProtobufWriter()
            element.write(2, int64: Int64((item.time * 1000).rounded()))
            element.write(7, string: item.text)
            var message = ProtobufWriter()
            message.write(1, bytes: element.bytes)
            out += message.bytes
        }
        return Data(out)
    }
}

/// The logged-in mid seen by `SmartSkipAnalyzer` (its cache key), switchable from a test.
final class SSAccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _mid: Int64 = 0
    var mid: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _mid }
        set { lock.lock(); _mid = newValue; lock.unlock() }
    }
}
