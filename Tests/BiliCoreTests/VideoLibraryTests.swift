import XCTest
@testable import BiliCore

// MARK: - 播放全部 list

private func ref(_ aid: Int64, epId: Int64 = 0) -> VideoRef {
    VideoRef(aid: aid, bvid: aid > 0 ? "BV\(aid)" : "", epId: epId, title: "v\(aid)")
}

final class VideoPlaylistTests: XCTestCase {
    @MainActor
    func testDropsUnplayableAndDuplicateEntries() async {
        let list = VideoPlaylist(title: "稍后再看", items: [ref(1), VideoRef(), ref(2), ref(1), ref(0, epId: 9)])
        XCTAssertEqual(list.items.map(\.aid), [1, 2, 0])
        XCTAssertEqual(list.items.last?.epId, 9)
        XCTAssertFalse(list.hasMore, "no fetch closure means no more pages")
    }

    @MainActor
    func testEntryAfterMatchesByAidBvidOrEpisode() async {
        let list = VideoPlaylist(title: "收藏夹", items: [ref(1), ref(2), ref(0, epId: 9), ref(4)])
        XCTAssertEqual(list.entry(after: 1, bvid: "")?.aid, 2)
        XCTAssertEqual(list.entry(after: 0, bvid: "BV2")?.epId, 9)
        XCTAssertEqual(list.entry(after: 77, bvid: "", epId: 9)?.aid, 4)
        XCTAssertNil(list.entry(after: 4, bvid: "BV4"), "last entry")
        XCTAssertNil(list.entry(after: 3, bvid: "BV3"), "not in the list")
        XCTAssertTrue(list.entry(after: 1, bvid: "")?.playlist === list, "the next entry carries the list")
        XCTAssertNil(list.items[1].playlist, "stored entries do not nest the list")
    }

    @MainActor
    func testIdentityHashable() async {
        let a = VideoPlaylist(title: "x", items: [ref(1)])
        let b = VideoPlaylist(title: "x", items: [ref(1)])
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b)
        var r1 = ref(1)
        r1.playlist = a
        var r2 = ref(1)
        r2.playlist = a
        XCTAssertEqual(r1, r2)
        r2.playlist = b
        XCTAssertNotEqual(r1, r2)
    }

    @MainActor
    func testLoadMoreSkipsOverlapAndStopsAtEnd() async {
        var requested: [Int] = []
        let pages: [Int: Page<VideoRef>] = [
            2: Page(items: [ref(3), ref(4)], hasMore: true),        // overlaps what the list screen had
            3: Page(items: [ref(5), ref(6)], hasMore: false),
        ]
        let list = VideoPlaylist(title: "收藏夹", items: [ref(1), ref(2), ref(3), ref(4)], nextPage: 2, hasMore: true) { n in
            requested.append(n)
            return pages[n] ?? .empty
        }
        XCTAssertTrue(list.needsMore(after: 4, bvid: ""))
        XCTAssertFalse(list.needsMore(after: 1, bvid: ""))
        let added = await list.loadMore()
        XCTAssertTrue(added)
        XCTAssertEqual(requested, [2, 3], "a page with nothing new is followed by the next one")
        XCTAssertEqual(list.items.map(\.aid), [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(list.hasMore)
        let again = await list.loadMore()
        XCTAssertFalse(again)
        XCTAssertEqual(requested, [2, 3])
        XCTAssertEqual(list.entry(after: 4, bvid: "")?.aid, 5)
    }

    @MainActor
    func testLoadMoreFailureKeepsHasMore() async {
        var calls = 0
        let list = VideoPlaylist(title: "收藏夹", items: [ref(1)], nextPage: 2, hasMore: true) { _ in
            calls += 1
            if calls == 1 { throw BiliError.other("offline") }
            return Page(items: [ref(2)], hasMore: false)
        }
        let first = await list.loadMore()
        XCTAssertFalse(first)
        XCTAssertTrue(list.hasMore)
        let second = await list.loadMore()
        XCTAssertTrue(second)
        XCTAssertEqual(list.items.map(\.aid), [1, 2])
    }
}

// MARK: - Relation labels / dislike form

final class UserRelationStateTests: XCTestCase {
    func testAttributeMapping() throws {
        XCTAssertEqual(UserRelationState(attribute: 0, special: false), .notFollowing)
        XCTAssertEqual(UserRelationState(attribute: 1, special: false), .whisper)
        XCTAssertEqual(UserRelationState(attribute: 2, special: false), .followed)
        XCTAssertEqual(UserRelationState(attribute: 4, special: false), .mutual)
        XCTAssertEqual(UserRelationState(attribute: 6, special: false), .mutual)
        XCTAssertEqual(UserRelationState(attribute: 6, special: true), .special)
        XCTAssertEqual(UserRelationState(attribute: 2, special: true), .special)
        XCTAssertEqual(UserRelationState(attribute: 128, special: true), .blocked)
        XCTAssertEqual(UserRelationState(attribute: 0, special: true), .notFollowing, "special without a follow is stale")

        let json = try JSON(string: #"{"mid":2,"attribute":6,"mtime":1700000000,"tag":[-10],"special":1}"#)
        XCTAssertEqual(UserRelationState(json: json), .special)
        XCTAssertEqual(UserRelationState(json: try JSON(string: #"{"attribute":2}"#)).label, "已关注")
    }

    func testLabelsAndActions() {
        XCTAssertEqual(UserRelationState.mutual.label, "已互关")
        XCTAssertEqual(UserRelationState.whisper.label, "悄悄关注")
        XCTAssertEqual(UserRelationState.special.label, "特别关注")
        XCTAssertEqual(UserRelationState.blocked.label, "已拉黑")
        XCTAssertTrue(UserRelationState.whisper.isFollowing)
        XCTAssertFalse(UserRelationState.blocked.isFollowing)
        XCTAssertEqual(UserRelationState.whisper.unfollowAction, .unfollow)
        XCTAssertEqual(UserRelationState.mutual.unfollowAction, .unfollow)
    }

    func testDislikeForm() {
        let on = VideoAPI.dislikeForm(aid: 170001, dislike: true, auth: ["access_key": "tok"])
        XCTAssertEqual(on["aid"] as? Int64, 170001)
        XCTAssertEqual(on["dislike"] as? Int, 0, "0 = 点踩")
        XCTAssertEqual(on["access_key"] as? String, "tok")
        let off = VideoAPI.dislikeForm(aid: 170001, dislike: false, auth: [:])
        XCTAssertEqual(off["dislike"] as? Int, 1, "1 = 取消")
        XCTAssertNil(off["access_key"])
    }
}
