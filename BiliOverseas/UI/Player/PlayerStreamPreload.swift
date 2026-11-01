import Foundation

/// A video's stream, ready before a swipe goes to it or a page opening it has the detail: the playurl answer, then a
/// session with its first seconds in the proxy's cache. Or a video a swipe left, which has all that already.
/// `PlayerController.load` takes it over; until then nothing plays and little is downloaded.
@MainActor
final class PlayerStreamPreload {
    /// How many videos each way are kept ready on the swipes.
    static let swipeWindow = 5
    /// How far ahead a video that may never play downloads, when the next swipe goes to it.
    static let prefetchSeconds = 8.0
    /// And when it is further away: enough to start at once, more when it is next.
    static let farPrefetchSeconds = 4.0
    /// What a video left holds at most, around where it would go on.
    static let leftBytes: Int64 = 24 * 1024 * 1024
    /// An older playurl answer has signed URLs about to run out (`installStreams` replaces such an answer too).
    private static let maxAge: TimeInterval = 20 * 60

    let aid: Int64
    let bvid: String
    let cid: Int64
    /// The video a swipe left, as opposed to the one the next swipe goes to.
    let wasLeft: Bool
    private var info: PlayInfo?
    private var fetchedAt: Date?
    private var session: PlaybackSession?
    private var choice: PlayerStreamChoice?
    private var accelerated = false
    private var prefetch: Double
    private var task: Task<Void, Never>?
    private var closed = false
    /// Still getting its answer and its session.
    private(set) var isPreparing = false
    /// When that came to nothing, which trying again a while later may change.
    private var cameToNothingAt: Date?
    private static let tryAgainAfter: TimeInterval = 30

    /// Starts on the video a swipe would go to. `start` says where it would start, once the answer is in.
    init(item: PlaybackItem, constraints: PlayerStreamConstraints, quality: Int, accelerate: Bool, allowHDR: Bool,
         prefetch: Double, start: @escaping (PlayInfo) -> Double) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
        wasLeft = false
        self.prefetch = prefetch
        isPreparing = true
        task = Task { [weak self] in
            await self?.prepare(item, constraints: constraints, quality: quality, accelerate: accelerate,
                                allowHDR: allowHDR, start: start)
        }
    }

    /// What a swipe left behind: the session stays as it is, holding what it has.
    init(left item: PlaybackItem, info: PlayInfo, fetchedAt: Date, session: PlaybackSession,
         choice: PlayerStreamChoice, accelerated: Bool) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
        wasLeft = true
        self.info = info
        self.fetchedAt = fetchedAt
        self.session = session
        self.choice = choice
        self.accelerated = accelerated
        prefetch = Self.prefetchSeconds
    }

    private func prepare(_ item: PlaybackItem, constraints: PlayerStreamConstraints, quality: Int, accelerate: Bool,
                         allowHDR: Bool, start: (PlayInfo) -> Double) async {
        defer {
            isPreparing = false
            if session == nil { cameToNothingAt = Date() }
        }
        let began = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime - began) * 1000) }
        let answer: PlayInfo
        do {
            answer = try await PlayerStreamPicker.fetchPlayInfo(aid: item.aid, bvid: item.bvid, cid: item.cid, epId: 0,
                                                                seasonId: 0, quality: quality)
        } catch {
            if !closed { PlaybackTrace.log("preload \(item.bvid) playurl failed \(PlaybackTrace.describe(error))") }
            return
        }
        // Protected content is left to the normal load, which says so.
        guard !closed, !answer.isDRM else { return }
        info = answer
        fetchedAt = Date()
        guard answer.isDash, let picked = PlayerStreamPicker.choose(answer, constraints) else { return }
        let total = answer.duration > 0 ? answer.duration : item.duration
        let request = PlaybackRequest(
            routeKey: PlayerStreamPicker.routeKey(aid: item.aid, bvid: item.bvid, cid: item.cid, epId: 0),
            video: picked.video, audio: picked.audio, duration: total, accelerate: accelerate, allowHDR: allowHDR,
            refreshURLs: PlayerStreamPicker.makeRefresher(aid: item.aid, bvid: item.bvid, cid: item.cid, epId: 0,
                                                          seasonId: 0, choice: picked))
        do {
            let made = try await AccelerationEngine.shared.prepare(request)
            guard !closed else {
                made.close()
                return
            }
            made.limitPrefetch(toSeconds: prefetch)
            made.playerWillSeek(to: start(answer), outsideBuffer: true)
            session = made
            choice = picked
            accelerated = accelerate
            PlaybackTrace.log("preload \(item.bvid) ready \(elapsed())ms accel=\(accelerate) "
                + "route=[\(made.routeDescription)] \(PlaybackTrace.describe(picked))")
        } catch {
            if !closed { PlaybackTrace.log("preload \(item.bvid) session failed \(PlaybackTrace.describe(error))") }
        }
    }

    /// What it holds now, for the playback log.
    var cachedBytes: Int64 { session?.store.cachedByteCount ?? 0 }

    func setPrefetch(seconds: Double) {
        guard seconds != prefetch else { return }
        prefetch = seconds
        session?.limitPrefetch(toSeconds: seconds)
    }

    func matches(_ item: PlaybackItem) -> Bool {
        guard item.epId == 0, item.cid == cid, !closed, session?.isEndpointValid != false,
              (aid != 0 && item.aid == aid) || (!bvid.isEmpty && item.bvid == bvid) else { return false }
        if let cameToNothingAt, Date().timeIntervalSince(cameToNothingAt) > Self.tryAgainAfter { return false }
        return fetchedAt.map { Date().timeIntervalSince($0) < Self.maxAge } ?? true
    }

    /// The playurl answer, once this has got as far as it gets.
    func answer() async -> (info: PlayInfo, fetchedAt: Date)? {
        await task?.value
        guard let info, let fetchedAt, !closed else { return nil }
        return (info, fetchedAt)
    }

    /// The session, when it is the one the player would open itself (the settings may have changed since).
    func takeSession(for picked: PlayerStreamChoice, accelerate: Bool) -> PlaybackSession? {
        guard let session, choice == picked, accelerated == accelerate, session.isEndpointValid else { return nil }
        self.session = nil
        session.limitPrefetch(toSeconds: nil)
        return session
    }

    func close() {
        closed = true
        task?.cancel()
        session?.close()
        session = nil
    }
}
