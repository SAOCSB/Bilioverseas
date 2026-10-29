import Foundation

/// 播放全部 list (稍后再看 / 收藏夹) carried by the `VideoRef` pushed from that list. The video page plays through
/// it after the current video's parts and before 合集 / 相关推荐 (list source priority: parts → play-all list →
/// UGC season). A reference type, so the page keeps one copy across in-place switches and later pages fetched
/// from the source list are seen by everyone holding it. Main actor only (list screens and `VideoDetailModel`).
@MainActor
final class VideoPlaylist: Hashable {
    /// Fetches page `n` (1-based) of the source list.
    typealias Fetch = (_ page: Int) async throws -> Page<VideoRef>

    /// Source list name (「稍后再看」 / the folder title).
    let title: String
    private(set) var items: [VideoRef]
    /// More pages can be fetched with `loadMore()`.
    private(set) var hasMore: Bool
    private(set) var isLoading = false
    private var nextPage: Int
    private let fetch: Fetch?

    /// `items`: the entries in play order. `nextPage`: the first source page that may hold entries `items` lacks
    /// (overlap is fine, `loadMore` skips entries it already has).
    init(title: String, items: [VideoRef], nextPage: Int = 1, hasMore: Bool = false, fetch: Fetch? = nil) {
        self.title = title
        var list: [VideoRef] = []
        for ref in items where VideoPlaylist.isPlayable(ref) && !list.contains(where: { VideoPlaylist.isSame($0, ref) }) {
            list.append(VideoPlaylist.entry(ref))
        }
        self.items = list
        self.nextPage = max(1, nextPage)
        self.hasMore = hasMore && fetch != nil
        self.fetch = fetch
    }

    /// Position of the video `aid` / `bvid` (or PGC episode `epId`) in the loaded entries.
    func index(aid: Int64, bvid: String, epId: Int64 = 0) -> Int? {
        items.firstIndex { VideoPlaylist.matches($0, aid: aid, bvid: bvid, epId: epId) }
    }

    /// The entry after that video, with this list attached; nil when the video is not in the list or is the last
    /// loaded entry (see `needsMore`).
    func entry(after aid: Int64, bvid: String, epId: Int64 = 0) -> VideoRef? {
        guard let i = index(aid: aid, bvid: bvid, epId: epId), i + 1 < items.count else { return nil }
        var next = items[i + 1]
        next.playlist = self
        return next
    }

    /// The video is one of the last `margin` loaded entries while the source has more pages.
    func needsMore(after aid: Int64, bvid: String, epId: Int64 = 0, margin: Int = 2) -> Bool {
        guard hasMore, let i = index(aid: aid, bvid: bvid, epId: epId) else { return false }
        return items.count - 1 - i < max(1, margin)
    }

    /// Appends the next source page (skipping entries already listed; up to a few pages until one adds
    /// something). Returns whether entries were added. A failed request keeps `hasMore`, so a later call retries.
    @discardableResult
    func loadMore() async -> Bool {
        guard hasMore, !isLoading, let fetch else { return false }
        isLoading = true
        defer { isLoading = false }
        var added = false
        var attempts = 0
        while hasMore && !added && attempts < 5 {
            attempts += 1
            guard let page = try? await fetch(nextPage) else { break }
            nextPage += 1
            hasMore = page.hasMore
            for ref in page.items where VideoPlaylist.isPlayable(ref) && !items.contains(where: { VideoPlaylist.isSame($0, ref) }) {
                items.append(VideoPlaylist.entry(ref))
                added = true
            }
        }
        return added
    }

    // MARK: Matching

    /// Something the video page can open (cards without any id are skipped).
    nonisolated static func isPlayable(_ ref: VideoRef) -> Bool {
        ref.aid > 0 || !ref.bvid.isEmpty || ref.isPGC
    }

    nonisolated static func matches(_ ref: VideoRef, aid: Int64, bvid: String, epId: Int64) -> Bool {
        if epId > 0 && ref.epId == epId { return true }
        if aid > 0 && ref.aid == aid { return true }
        return !bvid.isEmpty && ref.bvid == bvid
    }

    /// Two entries for the same video.
    nonisolated static func isSame(_ a: VideoRef, _ b: VideoRef) -> Bool {
        if a.epId > 0 || b.epId > 0 { return a.epId == b.epId }
        return matches(b, aid: a.aid, bvid: a.bvid, epId: 0)
    }

    /// Stored entries never hold a list themselves (`entry(after:)` attaches this one).
    private nonisolated static func entry(_ ref: VideoRef) -> VideoRef {
        var r = ref
        r.playlist = nil
        return r
    }

    // MARK: Hashable (identity: it rides along in `Route.video`)

    nonisolated static func == (lhs: VideoPlaylist, rhs: VideoPlaylist) -> Bool { lhs === rhs }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
