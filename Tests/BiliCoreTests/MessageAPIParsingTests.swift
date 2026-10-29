import XCTest
@testable import BiliCore

/// Parsing tests for 消息中心 (`MessageAPI`, `MessageLinks`), with fixtures modelled on the web responses of
/// `/x/msgfeed/*`, `sys-msg/query_notify_list` and the `api.vc` whisper endpoints (PiliPlus `http/msg.dart`).
final class MessageAPIParsingTests: XCTestCase {
    private func json(_ s: String) -> JSON {
        do { return try JSON(string: s) } catch { XCTFail("bad fixture: \(error)"); return .null }
    }

    // MARK: - Unread

    func testUnreadSumsFeedAndWhisperCounters() {
        let feed = json(#"{"at":2,"chat":0,"like":5,"reply":3,"sys_msg":1,"up":7}"#)
        let whisper = json(#"""
        {"unfollow_unread":4,"follow_unread":6,"unfollow_push_msg":1,"dustbin_push_msg":9,"dustbin_unread":9,
         "biz_msg_unfollow_unread":0,"biz_msg_follow_unread":2,"custom_unread":0}
        """#)
        let u = MessageAPI.parseUnread(feed: feed, whisper: whisper)
        XCTAssertEqual(u.reply, 3)
        XCTAssertEqual(u.at, 2)
        XCTAssertEqual(u.like, 5)
        XCTAssertEqual(u.system, 1)
        XCTAssertEqual(u.whisper, 13, "followed + unfollowed + push + business; the 垃圾箱 is not counted")
        XCTAssertEqual(u.total, 24)
        XCTAssertEqual(u.count(for: .like), 5)

        let noWhisper = MessageAPI.parseUnread(feed: feed, whisper: .null)
        XCTAssertEqual(noWhisper.whisper, 0)
        XCTAssertEqual(noWhisper.total, 11)

        var cleared = u
        cleared.clear(.reply)
        XCTAssertEqual(cleared.reply, 0)
        XCTAssertEqual(cleared.total, 21)
        XCTAssertNil(MessageUnread.badgeText(0))
        XCTAssertEqual(MessageUnread.badgeText(7), "7")
        XCTAssertEqual(MessageUnread.badgeText(100), "99+")
    }

    // MARK: - msgfeed

    func testFeedCursorRoundTrip() {
        XCTAssertEqual(MessageAPI.encodeFeedCursor(id: 123, time: 1_700_000_000), "123|1700000000")
        let c = MessageAPI.decodeFeedCursor("123|1700000000")
        XCTAssertEqual(c.id, 123)
        XCTAssertEqual(c.time, 1_700_000_000)
        XCTAssertEqual(MessageAPI.decodeFeedCursor(nil).id, 0)
        XCTAssertEqual(MessageAPI.decodeFeedCursor("garbage").time, 0)
        XCTAssertEqual(MessageAPI.timeParameter(.reply), "reply_time")
        XCTAssertEqual(MessageAPI.timeParameter(.at), "at_time")
        XCTAssertEqual(MessageAPI.timeParameter(.like), "like_time")
    }

    func testReplyFeedPage() {
        let data = json(#"""
        {"cursor":{"is_end":false,"id":9001,"time":1700000500},"last_view_at":1700000000,
         "items":[
          {"id":9002,"user":{"mid":11,"fans":0,"nickname":"小明","avatar":"http://i0.hdslb.com/bfs/face/a.jpg","follow":true},
           "item":{"subject_id":170001,"root_id":0,"source_id":5551,"target_id":0,"type":"reply","business_id":1,
                   "business":"视频","title":"我的视频","image":"//i0.hdslb.com/bfs/archive/c.jpg",
                   "uri":"https://www.bilibili.com/video/BV1xx411c7mD","native_uri":"bilibili://video/170001",
                   "root_reply_content":"","source_content":"拍得真好","target_reply_content":"","like_state":1},
           "counts":1,"is_multi":0,"reply_time":1700000600},
          {"id":9001,"user":{"mid":12,"nickname":"小红","avatar":""},
           "item":{"subject_id":832703053858603029,"root_id":7770,"source_id":7772,"target_id":7771,"type":"reply",
                   "business_id":17,"business":"评论","title":"今天的动态","image":"",
                   "uri":"https://t.bilibili.com/832703053858603029",
                   "native_uri":"bilibili://comment/detail/17/832703053858603029/7770/?anchor=7772",
                   "root_reply_content":"根评论","source_content":"回复 @我 :同意","target_reply_content":"我的评论"},
           "counts":2,"is_multi":1,"reply_time":1700000500},
          {"id":0,"item":{}}
         ]}
        """#)
        let page = MessageAPI.parseFeedPage(data, kind: .reply)
        XCTAssertEqual(page.items.count, 2, "rows without an id are dropped")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "9001|1700000500")

        let first = page.items[0]
        XCTAssertEqual(first.id, "reply_9002")
        XCTAssertEqual(first.users.first?.name, "小明")
        XCTAssertEqual(first.users.first?.face, "https://i0.hdslb.com/bfs/face/a.jpg")
        XCTAssertEqual(first.users.first?.isFollowed, true)
        XCTAssertEqual(first.time, 1_700_000_600)
        XCTAssertEqual(first.business, "视频")
        XCTAssertEqual(first.content, "拍得真好")
        XCTAssertEqual(first.image, "https://i0.hdslb.com/bfs/archive/c.jpg")
        XCTAssertTrue(first.liked)
        XCTAssertFalse(first.isMulti)
        XCTAssertEqual(first.link, .video(aid: 170001, bvid: ""))
        XCTAssertEqual(first.thread, MessageCommentThread(oid: 170001, type: 1, root: 5551),
                       "a root comment is its own thread")
        XCTAssertEqual(first.sourceRpid, 5551)
        XCTAssertEqual(first.sourceRoot, 0)

        let second = page.items[1]
        XCTAssertTrue(second.isMulti)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.targetText, "我的评论")
        XCTAssertEqual(second.rootText, "根评论")
        XCTAssertEqual(second.thread, MessageCommentThread(oid: 832703053858603029, type: 17, root: 7770))
        XCTAssertEqual(second.sourceRoot, 7770)
        XCTAssertEqual(second.link, .dynamic(id: "832703053858603029"),
                       "a comment-detail native_uri falls back to the dynamic of comment area 17")
    }

    func testReplyFeedEnd() {
        let data = json(#"{"cursor":{"is_end":true,"id":1,"time":2},"items":[{"id":5,"user":{"mid":1,"nickname":"a"},"item":{}}]}"#)
        let page = MessageAPI.parseFeedPage(data, kind: .reply)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.next)
        XCTAssertFalse(MessageAPI.parseFeedPage(json(#"{"cursor":{"is_end":false,"id":1,"time":2},"items":[]}"#),
                                                kind: .at).hasMore, "an empty page ends the list")
    }

    func testAtFeedFromDynamicHasNoThread() {
        let data = json(#"""
        {"cursor":{"is_end":false,"id":300,"time":1700000100},
         "items":[
          {"id":301,"user":{"mid":21,"nickname":"阿伟","avatar":"https://i0.hdslb.com/f.jpg"},
           "item":{"type":"dynamic","business":"动态","business_id":0,"subject_id":0,"source_id":0,
                   "title":"","image":"","source_content":"@我 快来看","uri":"https://t.bilibili.com/900",
                   "native_uri":"bilibili://following/detail/900"},"at_time":1700000200},
          {"id":300,"user":{"mid":22,"nickname":"小李"},
           "item":{"type":"reply","business":"评论","business_id":1,"subject_id":4242,"source_id":66,"root_id":60,
                   "source_content":"@我 看这个","native_uri":"bilibili://video/4242?comment_root_id=60"},"at_time":1700000100}
         ]}
        """#)
        let page = MessageAPI.parseFeedPage(data, kind: .at)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.next, "300|1700000100")
        XCTAssertEqual(page.items[0].time, 1_700_000_200)
        XCTAssertNil(page.items[0].thread)
        XCTAssertEqual(page.items[0].sourceRpid, 0)
        XCTAssertEqual(page.items[0].link, .dynamic(id: "900"))
        XCTAssertEqual(page.items[1].thread, MessageCommentThread(oid: 4242, type: 1, root: 60))
        XCTAssertEqual(page.items[1].link, .video(aid: 4242, bvid: ""))
    }

    func testLikeFeedMergesLatestAndTotal() {
        let data = json(#"""
        {"latest":{"items":[
            {"id":801,"users":[{"mid":1,"nickname":"甲","avatar":"//i0.hdslb.com/1.jpg"},{"mid":2,"nickname":"乙","avatar":""}],
             "item":{"item_id":555,"type":"reply","business":"评论","title":"我的精彩评论","image":"",
                     "uri":"https://www.bilibili.com/video/BV1xx411c7mD",
                     "native_uri":"bilibili://comment/detail/1/170001/555/?subType=0&anchor=555&enterUri=bilibili://video/170001"},
             "counts":5,"like_time":1700000900,"notice_state":0}],"last_view_at":1700000000},
         "total":{"cursor":{"is_end":false,"id":700,"time":1699990000},"items":[
            {"id":700,"users":[{"mid":3,"nickname":"丙"}],
             "item":{"type":"video","business":"视频","title":"我的视频","image":"http://i0.hdslb.com/v.jpg",
                     "uri":"https://www.bilibili.com/video/av170001","native_uri":"bilibili://video/170001"},
             "counts":1,"like_time":1699990000}]}}
        """#)
        let page = MessageAPI.parseFeedPage(data, kind: .like)
        XCTAssertEqual(page.items.map(\.id), ["like_801", "like_700"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "700|1699990000")

        let latest = page.items[0]
        XCTAssertEqual(latest.users.map(\.name), ["甲", "乙"])
        XCTAssertEqual(latest.count, 5)
        XCTAssertTrue(latest.isMulti)
        XCTAssertEqual(latest.time, 1_700_000_900)
        XCTAssertEqual(latest.title, "我的精彩评论")
        XCTAssertEqual(latest.thread, MessageCommentThread(oid: 170001, type: 1, root: 555))
        XCTAssertEqual(latest.link, .video(aid: 0, bvid: "BV1xx411c7mD"), "the web uri is the related video")

        let video = page.items[1]
        XCTAssertFalse(video.isMulti)
        XCTAssertNil(video.thread)
        XCTAssertEqual(video.link, .video(aid: 170001, bvid: ""))
        XCTAssertEqual(video.image, "https://i0.hdslb.com/v.jpg")

        let end = json(#"{"latest":{"items":[]},"total":{"cursor":{"is_end":false,"id":1,"time":1},"items":[]}}"#)
        XCTAssertFalse(MessageAPI.parseFeedPage(end, kind: .like).hasMore, "an empty total ends the list")
    }

    // MARK: - 系统通知

    func testSystemPage() {
        let data = json(#"""
        [{"id":41,"cursor":1700000300000,"type":1,"title":"投稿通过",
          "content":"{\"web\":\"你的稿件【BV1xx411c7mD】已通过审核 #{点击查看}{\\\"https://www.bilibili.com/video/BV1xx411c7mD\\\"}\"}",
          "time_at":"2023-11-15 06:13:20"},
         {"id":40,"cursor":1700000200000,"title":"系统消息","content":"欢迎来到 https://www.bilibili.com/blackboard/x.html。",
          "time_at":"bad"}]
        """#)
        let page = MessageAPI.parseSystemPage(data)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "1700000200000")
        let first = page.items[0]
        XCTAssertEqual(first.id, "system_41")
        XCTAssertEqual(first.title, "投稿通过")
        XCTAssertEqual(first.content, #"你的稿件【BV1xx411c7mD】已通过审核 #{点击查看}{"https://www.bilibili.com/video/BV1xx411c7mD"}"#)
        XCTAssertEqual(first.time, 1_700_000_000, "time_at is Beijing time")
        XCTAssertEqual(page.items[1].time, 0)
        XCTAssertEqual(page.items[1].timeText, "bad")
        XCTAssertFalse(MessageAPI.parseSystemPage(json("[]")).hasMore)
        XCTAssertEqual(MessageAPI.systemContent("plain"), "plain")
    }

    func testSystemSegments() {
        let segments = MessageLinks.systemSegments(
            #"稿件已通过 #{点击查看}{"https://www.bilibili.com/video/BV1xx411c7mD"} 详见 https://www.bilibili.com/read/cv123。谢谢"#)
        XCTAssertEqual(segments.map(\.text), ["稿件已通过 ", "点击查看", " 详见 ", "网页链接", "。谢谢"])
        XCTAssertEqual(segments[1].link, .video(aid: 0, bvid: "BV1xx411c7mD"))
        XCTAssertEqual(segments[3].link, .article(id: 123))
        XCTAssertEqual(segments[1].url, URL(string: "https://www.bilibili.com/video/BV1xx411c7mD"))
        XCTAssertEqual(segments[3].url, URL(string: "https://www.bilibili.com/read/cv123"))
        XCTAssertNil(segments[0].link)
        XCTAssertNil(segments[0].url)

        let trailing = MessageLinks.systemSegments("见 https://example.com/a.html).")
        XCTAssertEqual(trailing.map(\.text), ["见 ", "网页链接", ")."])
        XCTAssertEqual(trailing[1].link, .web(URL(string: "https://example.com/a.html")!))
        XCTAssertEqual(MessageLinks.systemSegments("纯文本"), [MessageTextSegment(text: "纯文本", link: nil)])
        XCTAssertTrue(MessageLinks.systemSegments("").isEmpty)
    }

    // MARK: - Links

    func testLinkResolution() {
        XCTAssertEqual(MessageLinks.resolve("bilibili://video/170001?page=0"), .video(aid: 170001, bvid: ""))
        XCTAssertEqual(MessageLinks.resolve("bilibili://video/BV1xx411c7mD"), .video(aid: 0, bvid: "BV1xx411c7mD"))
        XCTAssertEqual(MessageLinks.resolve("bilibili://pgc/season/ep/1234"), .bangumi(epId: 1234, seasonId: 0))
        XCTAssertEqual(MessageLinks.resolve("bilibili://pgc/season/88"), .bangumi(epId: 0, seasonId: 88))
        XCTAssertEqual(MessageLinks.resolve("bilibili://bangumi/season/99"), .bangumi(epId: 0, seasonId: 99))
        XCTAssertEqual(MessageLinks.resolve("bilibili://space/2333?from=x"), .user(mid: 2333))
        XCTAssertEqual(MessageLinks.resolve("bilibili://live/6"), .live(roomId: 6))
        XCTAssertEqual(MessageLinks.resolve("bilibili://following/detail/832703053858603029"),
                       .dynamic(id: "832703053858603029"))
        XCTAssertEqual(MessageLinks.resolve("bilibili://following/detail/cv777"), .article(id: 777))
        XCTAssertEqual(MessageLinks.resolve("bilibili://opus/detail/123"), .dynamic(id: "123"))
        XCTAssertEqual(MessageLinks.resolve("bilibili://article/40679479?jump_opus=1"), .article(id: 40679479))
        XCTAssertEqual(MessageLinks.resolve("bilibili://comment/detail/17/832703053858603029/238686570016/?anchor=1"),
                       .comments(MessageCommentThread(oid: 832703053858603029, type: 17, root: 238686570016)))
        XCTAssertEqual(MessageLinks.resolve("bilibili://comment/msg_fold/1/22222/33333/11111/?enterUri=bilibili://video/22222"),
                       .comments(MessageCommentThread(oid: 22222, type: 1, root: 33333)))
        XCTAssertNil(MessageLinks.resolve("bilibili://comment/detail/x/1/2"))
        XCTAssertNil(MessageLinks.resolve("bilibili://unknown/1"))
        XCTAssertNil(MessageLinks.resolve(""))
        XCTAssertNil(MessageLinks.resolve("?from=msg"))
        XCTAssertNil(MessageLinks.resolve("mailto:a@b.c"))

        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/video/BV1xx411c7mD/?p=2"),
                       .video(aid: 0, bvid: "BV1xx411c7mD"))
        XCTAssertEqual(MessageLinks.resolve("https://m.bilibili.com/video/av170001"), .video(aid: 170001, bvid: ""))
        XCTAssertEqual(MessageLinks.resolve("//space.bilibili.com/2333/dynamic"), .user(mid: 2333))
        XCTAssertEqual(MessageLinks.resolve("https://live.bilibili.com/h5/6"), .live(roomId: 6))
        XCTAssertEqual(MessageLinks.resolve("https://t.bilibili.com/900?tab=2"), .dynamic(id: "900"))
        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/opus/901"), .dynamic(id: "901"))
        XCTAssertEqual(MessageLinks.resolve("https://m.bilibili.com/dynamic/902"), .dynamic(id: "902"))
        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/bangumi/play/ep321"), .bangumi(epId: 321, seasonId: 0))
        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/bangumi/play/ss654"), .bangumi(epId: 0, seasonId: 654))
        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/read/cv123"), .article(id: 123))
        XCTAssertEqual(MessageLinks.resolve("https://www.bilibili.com/h5/comment/sub?oid=5&pageType=1&root=9"),
                       .comments(MessageCommentThread(oid: 5, type: 1, root: 9)))
        XCTAssertEqual(MessageLinks.resolve("bilibili://browser?url=https%3A%2F%2Fwww.bilibili.com%2Fread%2Fcv5"),
                       .article(id: 5))
        let other = MessageLinks.resolve("https://www.bilibili.com/blackboard/activity.html")
        XCTAssertEqual(other, .web(URL(string: "https://www.bilibili.com/blackboard/activity.html")!))
        XCTAssertEqual(MessageLinks.resolve("https://example.com/x"), .web(URL(string: "https://example.com/x")!))
    }

    func testContentLinkPrefersAppLinkThenCommentArea() {
        let thread = MessageLink.comments(MessageCommentThread(oid: 1, type: 1, root: 2))
        XCTAssertEqual(MessageAPI.contentLink(native: .video(aid: 5, bvid: ""), web: nil, businessId: 17, subjectId: 9),
                       .video(aid: 5, bvid: ""))
        XCTAssertEqual(MessageAPI.contentLink(native: thread, web: nil, businessId: 12, subjectId: 9), .article(id: 9))
        XCTAssertEqual(MessageAPI.contentLink(native: thread, web: .dynamic(id: "3"), businessId: 11, subjectId: 9),
                       .dynamic(id: "3"))
        XCTAssertNil(MessageAPI.contentLink(native: thread, web: thread, businessId: 0, subjectId: 0))
    }

    // MARK: - 私信 sessions

    func testSessionsPage() {
        let data = json(#"""
        {"session_list":[
          {"talker_id":1001,"session_type":1,"top_ts":1700000000000000,"unread_count":2,"is_follow":1,"is_dnd":0,
           "session_ts":1700000500000000,"max_seqno":40,"system_msg_type":0,
           "last_msg":{"sender_uid":1001,"receiver_type":1,"receiver_id":9,"msg_type":1,
                       "content":"{\"content\":\"你好\\n在吗\"}","msg_seqno":40,"timestamp":1700000500,"msg_key":7000000000000000001}},
          {"talker_id":1002,"session_type":1,"unread_count":0,"session_ts":1700000400000000,"is_dnd":1,
           "last_msg":{"sender_uid":9,"msg_type":2,"content":"{\"url\":\"http://i0.hdslb.com/p.jpg\",\"width\":10,\"height\":20}",
                       "msg_seqno":7,"timestamp":1700000400}},
          {"talker_id":844424930131966,"session_type":1,"system_msg_type":1,"unread_count":1,"session_ts":1700000300000000,
           "account_info":{"name":"哔哩哔哩直播小助手","pic_url":"//i0.hdslb.com/sys.png"},
           "last_msg":{"sender_uid":844424930131966,"msg_type":10,"content":"{\"title\":\"开播提醒\",\"text\":\"x\"}",
                       "msg_seqno":3,"timestamp":1700000300}},
          {"talker_id":55,"session_type":2,"group_name":"粉丝团","group_cover":"https://i0.hdslb.com/g.jpg",
           "session_ts":1700000200000000,
           "last_msg":{"sender_uid":1001,"msg_type":5,"content":"7000000000000000001","msg_seqno":2,"timestamp":1700000200}},
          {"talker_id":0,"session_type":3}
         ],"has_more":1}
        """#)
        let page = MessageAPI.parseSessions(data)
        XCTAssertEqual(page.items.map(\.talkerId), [1001, 1002, 844424930131966, 55])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "1700000200000000", "the oldest unpinned session_ts")

        let pinned = page.items[0]
        XCTAssertTrue(pinned.isPinned)
        XCTAssertTrue(pinned.isFollowed)
        XCTAssertEqual(pinned.unreadCount, 2)
        XCTAssertEqual(pinned.preview, "你好 在吗")
        XCTAssertEqual(pinned.lastTime, 1_700_000_500)
        XCTAssertEqual(pinned.maxSeqno, 40)
        XCTAssertTrue(pinned.name.isEmpty, "user names come from user_infos")
        XCTAssertEqual(pinned.peer, WhisperPeer(talkerId: 1001, sessionType: 1, name: "", face: ""))

        XCTAssertEqual(page.items[1].preview, "[图片]")
        XCTAssertTrue(page.items[1].isMuted)

        let system = page.items[2]
        XCTAssertTrue(system.isSystem)
        XCTAssertEqual(system.name, "哔哩哔哩直播小助手")
        XCTAssertEqual(system.face, "https://i0.hdslb.com/sys.png")
        XCTAssertEqual(system.preview, "开播提醒")

        let group = page.items[3]
        XCTAssertEqual(group.name, "粉丝团")
        XCTAssertEqual(group.face, "https://i0.hdslb.com/g.jpg")
        XCTAssertEqual(group.preview, "你撤回了一条消息")
        XCTAssertFalse(group.peer.canSend)
        XCTAssertTrue(pinned.peer.canSend)

        let named = MessageAPI.applyUser(UserBrief(mid: 1001, name: "老王", face: "https://i0.hdslb.com/w.jpg"), to: pinned)
        XCTAssertEqual(named.name, "老王")
        XCTAssertEqual(named.face, "https://i0.hdslb.com/w.jpg")
        XCTAssertEqual(MessageAPI.applyUser(UserBrief(mid: 1, name: "别人"), to: system).name, "哔哩哔哩直播小助手")

        let last = MessageAPI.parseSessions(json(#"{"session_list":[],"has_more":0}"#))
        XCTAssertFalse(last.hasMore)
        XCTAssertTrue(last.items.isEmpty)
    }

    func testUserInfos() {
        let users = MessageAPI.parseUserInfos(json(#"""
        [{"mid":1001,"name":"老王","face":"http://i0.hdslb.com/w.jpg","sign":"签名"},{"mid":0,"name":"x"}]
        """#))
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[1001]?.name, "老王")
        XCTAssertEqual(users[1001]?.face, "https://i0.hdslb.com/w.jpg")
        XCTAssertEqual(users[1001]?.sign, "签名")
    }

    // MARK: - 私信 messages

    func testConversationPage() {
        let data = json(#"""
        {"messages":[
          {"sender_uid":9,"receiver_id":1001,"msg_type":5,"content":"7000000000000000002","msg_seqno":46,"timestamp":1700000960,"msg_key":7000000000000000006},
          {"sender_uid":1001,"receiver_id":9,"msg_type":18,"msg_source":18,
           "content":"{\"content\":\"[{\\\"text\\\":\\\"对方主动回复或关注你前，最多发送1条消息\\\"}]\"}","msg_seqno":45,"timestamp":1700000950,"msg_key":7000000000000000005},
          {"sender_uid":1001,"receiver_id":9,"msg_type":11,
           "content":"{\"title\":\"新视频\",\"cover\":\"//i0.hdslb.com/c.jpg\",\"times\":125,\"bvid\":\"BV1xx411c7mD\",\"rid\":170001,\"attach_msg\":{\"content\":\"快来看\"}}",
           "msg_seqno":44,"timestamp":1700000900,"msg_key":7000000000000000004},
          {"sender_uid":1001,"receiver_id":9,"msg_type":7,
           "content":"{\"author\":\"UP\",\"id\":\"900\",\"source\":11,\"thumb\":\"\",\"title\":\"一条动态\"}",
           "msg_seqno":43,"timestamp":1700000800,"msg_key":7000000000000000003},
          {"sender_uid":9,"receiver_id":1001,"msg_type":1,"content":"{\"content\":\"[doge] 收到\"}","msg_seqno":42,
           "timestamp":1700000700,"msg_key":7000000000000000002,"msg_source":0},
          {"sender_uid":1001,"receiver_id":9,"msg_type":2,"msg_status":0,
           "content":"{\"url\":\"http://i0.hdslb.com/bfs/im/p.png\",\"width\":300,\"height\":200,\"imageType\":\"png\"}",
           "msg_seqno":41,"timestamp":1700000600,"msg_key":7000000000000000001,"msg_source":9},
          {"sender_uid":1001,"receiver_id":9,"msg_type":10,
           "content":"{\"title\":\"订单通知\",\"text\":\"已发货\",\"modules\":[{\"title\":\"单号\",\"detail\":\"123\"}],\"jump_text\":\"查看\",\"jump_uri\":\"https://www.bilibili.com/read/cv5\",\"jump_uri_2\":\"\"}",
           "msg_seqno":40,"timestamp":1700000500,"msg_key":7000000000000000000},
          {"sender_uid":1001,"receiver_id":9,"msg_type":99,"content":"{}","msg_seqno":39,"timestamp":1700000400,"msg_key":69}
         ],
         "has_more":1,"min_seqno":39,"max_seqno":46,
         "e_infos":[{"text":"[doge]","url":"http://i0.hdslb.com/emote/doge.png","size":1}]}
        """#)
        let page = MessageAPI.parseMessages(data)
        XCTAssertEqual(page.messages.map(\.seqno), [39, 40, 41, 42, 43, 44, 45], "oldest first, 撤回 marker removed")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.minSeqno, 39)
        XCTAssertEqual(page.maxSeqno, 46)
        XCTAssertEqual(page.withdrawnKeys, ["7000000000000000002"])
        XCTAssertEqual(page.emotes["[doge]"], "https://i0.hdslb.com/emote/doge.png")

        let byType = Dictionary(page.messages.map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byType[99]?.body, .unsupported(type: 99))
        XCTAssertEqual(byType[10]?.body, .notice(WhisperNotice(
            title: "订单通知", text: "已发货", fields: [.init(title: "单号", detail: "123")],
            actions: [.init(text: "查看", link: .article(id: 5))])))
        XCTAssertEqual(byType[2]?.body, .image(url: "https://i0.hdslb.com/bfs/im/p.png", width: 300, height: 200))
        XCTAssertEqual(byType[2]?.isAutoReply, true)
        XCTAssertEqual(byType[1]?.body, .text("[doge] 收到"))
        XCTAssertEqual(byType[1]?.isWithdrawn, true, "withdrawn by the later type-5 marker")
        XCTAssertEqual(byType[1]?.id, "7000000000000000002")
        XCTAssertEqual(byType[7]?.body, .card(WhisperCard(title: "一条动态", subtitle: "UP · 动态", link: .dynamic(id: "900"))))
        XCTAssertEqual(byType[11]?.body, .card(WhisperCard(
            title: "新视频", cover: "https://i0.hdslb.com/c.jpg", subtitle: "视频", duration: 125, note: "快来看",
            link: .video(aid: 170001, bvid: "BV1xx411c7mD"))))
        XCTAssertEqual(byType[18]?.body, .tip("对方主动回复或关注你前，最多发送1条消息"))

        XCTAssertEqual(MessageAPI.previewText(byType[1]!, talkerId: 9), "对方撤回了一条消息")
        XCTAssertEqual(MessageAPI.previewText(byType[11]!, talkerId: 9), "[视频] 新视频")
        XCTAssertEqual(MessageAPI.previewText(byType[7]!, talkerId: 9), "[分享] 一条动态")
        XCTAssertEqual(MessageAPI.previewText(byType[99]!, talkerId: 9), "[暂不支持的消息]")
    }

    func testExpiredVideoCardAndOtherCards() {
        XCTAssertEqual(MessageAPI.messageBody(type: 11, content: .string(#"{"title":"x","times":0,"bvid":"BV1xx411c7mD"}"#)),
                       .card(WhisperCard(title: "内容已失效", subtitle: "视频")))
        XCTAssertEqual(MessageAPI.messageBody(type: 1, content: .string("not json")), .text("not json"))
        XCTAssertEqual(MessageAPI.messageBody(type: 2, content: .string("{}")), .unsupported(type: 2))
        XCTAssertEqual(MessageAPI.messageBody(type: 14, content: .string(
            #"{"source":"直播","sourceID":6,"title":"直播间","cover":"//i0.hdslb.com/l.jpg","author":"主播"}"#)),
            .card(WhisperCard(title: "直播间", cover: "https://i0.hdslb.com/l.jpg", subtitle: "主播 · 直播", link: .live(roomId: 6))))
        XCTAssertEqual(MessageAPI.messageBody(type: 7, content: .string(#"{"source":5,"id":"170001","title":"视频","thumb":"//a/b.jpg"}"#)),
                       .card(WhisperCard(title: "视频", cover: "https:" + "//a/b.jpg", subtitle: "视频",
                                         link: .video(aid: 170001, bvid: ""))))
        XCTAssertEqual(MessageAPI.messageBody(type: 12, content: .string(#"{"rid":77,"title":"专栏","summary":"摘要","image_urls":["//i0.hdslb.com/a.jpg"]}"#)),
                       .card(WhisperCard(title: "专栏", cover: "https://i0.hdslb.com/a.jpg", subtitle: "摘要", link: .article(id: 77))))
        XCTAssertEqual(MessageAPI.messageBody(type: 5, content: .string("\"123\"")), .withdraw(msgKey: "123"))
        XCTAssertEqual(MessageAPI.tipText(.string("纯提示")), "纯提示")
    }

    func testChatTimeLabels() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-15 06:13:20 +08:00
        XCTAssertEqual(WhisperTime.label(1_699_999_000, now: now, timeZone: tz), "05:56")
        XCTAssertEqual(WhisperTime.label(1_699_950_000, now: now, timeZone: tz), "昨天 16:20")
        XCTAssertEqual(WhisperTime.label(1_690_000_000, now: now, timeZone: tz), "07-22 12:26")
        XCTAssertEqual(WhisperTime.label(1_600_000_000, now: now, timeZone: tz), "2020-09-13 20:26")
        XCTAssertEqual(WhisperTime.label(0, now: now, timeZone: tz), "")

        func msg(_ t: Int64) -> WhisperMessage { var m = WhisperMessage(); m.timestamp = t; return m }
        let list = [msg(1000), msg(1100), msg(1500), msg(1600)]
        XCTAssertEqual((0..<4).map { WhisperTime.startsGroup(list, at: $0) }, [true, false, true, false])
        XCTAssertFalse(WhisperTime.startsGroup(list, at: 9))
    }

    // MARK: - Send

    func testSendTextRequest() throws {
        let r = MessageAPI.sendTextRequest("你好 \"世界\"", sender: 9, receiver: 1001, deviceId: "DEV-1",
                                           timestamp: 1_700_000_000, csrf: "jct")
        XCTAssertEqual(r.query["w_sender_uid"] as? Int64, 9)
        XCTAssertEqual(r.query["w_receiver_id"] as? Int64, 1001)
        XCTAssertEqual(r.query["w_dev_id"] as? String, "DEV-1")
        XCTAssertEqual(r.form["msg[sender_uid]"] as? Int64, 9)
        XCTAssertEqual(r.form["msg[receiver_id]"] as? Int64, 1001)
        XCTAssertEqual(r.form["msg[receiver_type]"] as? Int, 1)
        XCTAssertEqual(r.form["msg[msg_type]"] as? Int, 1)
        XCTAssertEqual(r.form["msg[dev_id]"] as? String, "DEV-1")
        XCTAssertEqual(r.form["msg[timestamp]"] as? Int64, 1_700_000_000)
        XCTAssertEqual(r.form["csrf"] as? String, "jct")
        XCTAssertEqual(r.form["csrf_token"] as? String, "jct")
        let content = try XCTUnwrap(r.form["msg[content]"] as? String)
        XCTAssertEqual(try JSON(string: content)["content"].stringValue, "你好 \"世界\"")
    }
}
