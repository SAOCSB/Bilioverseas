import XCTest
@testable import BiliCore

private func desc(_ e: Error) -> String { (e as? BiliError)?.errorDescription ?? "\(e)" }

private final class IntBox { var values: [Int] = [] }

private func fixture(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> JSON {
    do { return try JSON(string: s) } catch {
        XCTFail("bad fixture JSON: \(error)", file: file, line: line)
        return .null
    }
}

// MARK: - Playurl

final class VideoAPIPlayurlParsingTests: XCTestCase {
    /// camelCase keys, `SegmentBase` with capital letters, dolby list + flac object.
    let camelDash = #"""
    {"from":"local","result":"suee","quality":80,"format":"flv","timelength":215040,
     "accept_format":"hdflv2,flv,flv720,flv480,mp4",
     "accept_description":["1080P 高码率","1080P 高清","720P 高清","480P 清晰","360P 流畅"],
     "accept_quality":[112,80,64,32,16],"video_codecid":7,
     "support_formats":[
       {"quality":112,"format":"hdflv2","new_description":"1080P 高码率","display_desc":"1080P","superscript":"高码率","codecs":["avc1.640032","hev1.1.6.L150.90"],"need_vip":true},
       {"quality":80,"format":"flv","new_description":"1080P 高清","display_desc":"1080P","codecs":["avc1.640032","hev1.1.6.L150.90","av01.0.08M.08.0.110.01.01.01.0"]},
       {"quality":64,"format":"flv720","new_description":"720P 高清","display_desc":"720P","codecs":["avc1.640028"],"need_login":true},
       {"quality":32,"format":"flv480","new_description":"480P 清晰","display_desc":"480P","codecs":["avc1.64001F"]},
       {"quality":16,"format":"mp4","new_description":"360P 流畅","display_desc":"360P","codecs":["avc1.64001E"]}],
     "dash":{"duration":215,"minBufferTime":1.5,
       "video":[
         {"id":32,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/32.m4s","backupUrl":["https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/32.m4s"],
          "bandwidth":400000,"mimeType":"video/mp4","codecs":"avc1.64001F","width":852,"height":480,"frameRate":"29.970","sar":"1:1","startWithSap":1,
          "SegmentBase":{"Initialization":"0-900","indexRange":"901-1400"},"codecid":7},
         {"id":80,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/80avc.m4s","backupUrl":["https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/80avc.m4s","https://upos-hz-mirrorakam.akamaized.net/upgcxcode/80avc.m4s?hdnts=x"],
          "bandwidth":2100000,"mimeType":"video/mp4","codecs":"avc1.640032","width":1920,"height":1080,"frameRate":"30000/1001",
          "SegmentBase":{"Initialization":"0-1012","indexRange":"1013-1612"},"codecid":7},
         {"id":80,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/80hevc.m4s","backupUrl":null,
          "bandwidth":1200000,"mimeType":"video/mp4","codecs":"hev1.1.6.L150.90","width":1920,"height":1080,"frameRate":"30",
          "SegmentBase":{"Initialization":"0-1100","indexRange":"1101-1700"},"codecid":12},
         {"id":16,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/16.m4s","bandwidth":200000,"mimeType":"video/mp4","codecs":"avc1.64001E","width":640,"height":360,"frameRate":"30","SegmentBase":{"Initialization":"0-800","indexRange":"801-1300"},"codecid":7}],
       "audio":[
         {"id":30216,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/30216.m4s","bandwidth":67000,"mimeType":"audio/mp4","codecs":"mp4a.40.2","SegmentBase":{"Initialization":"0-907","indexRange":"908-1507"},"codecid":0},
         {"id":30280,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/30280.m4s","bandwidth":319000,"mimeType":"audio/mp4","codecs":"mp4a.40.2","SegmentBase":{"Initialization":"0-907","indexRange":"908-1507"},"codecid":0},
         {"id":30232,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/30232.m4s","bandwidth":132000,"mimeType":"audio/mp4","codecs":"mp4a.40.2","SegmentBase":{"Initialization":"0-907","indexRange":"908-1507"},"codecid":0}],
       "dolby":{"type":1,"audio":[{"id":30250,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/30250.m4s","bandwidth":448000,"mimeType":"audio/mp4","codecs":"ec-3","SegmentBase":{"Initialization":"0-1200","indexRange":"1201-1800"}}]},
       "flac":{"display":true,"audio":{"id":30251,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/30251.m4s","bandwidth":1300000,"mimeType":"audio/mp4","codecs":"fLaC","SegmentBase":{"Initialization":"0-1500","indexRange":"1501-2100"}}}},
     "last_play_time":125000,"last_play_cid":279786}
    """#

    /// snake_case-only keys (the shape PGC `video_info` may use).
    let snakeDash = #"""
    {"quality":64,"timelength":1420000,"accept_quality":[80,64,32],"accept_description":["1080P 高清","720P 高清","480P 清晰"],
     "dash":{"duration":0,"min_buffer_time":1.5,
       "video":[{"id":64,"base_url":"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/64.m4s","backup_url":["https://cn-hk-eq-01-01.bilivideo.com/upgcxcode/64.m4s"],
                 "bandwidth":900000,"mime_type":"video/mp4","codecs":"avc1.640028","width":1280,"height":720,"frame_rate":"29.412",
                 "segment_base":{"initialization":"0-929","index_range":"930-1653"},"codecid":7}],
       "audio":[{"id":30280,"base_url":"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/a.m4s","backup_url":[],"bandwidth":320000,"mime_type":"audio/mp4","codecs":"mp4a.40.2",
                 "segment_base":{"initialization":"0-819","index_range":"820-1300"}}],
       "dolby":{"type":0,"audio":null},"flac":null}}
    """#

    let durlOnly = #"""
    {"quality":32,"format":"mp4","timelength":60500,"accept_quality":[80,32],"accept_description":["1080P 高清 试看","480P 清晰"],
     "dash":null,
     "durl":[{"order":1,"length":30000,"size":1048576,"ahead":"","vhead":"","url":"https://upos-sz-mirrorali.bilivideo.com/a-1.mp4","backup_url":["https://upos-sz-mirrorcos.bilivideo.com/a-1.mp4"]},
             {"order":2,"length":30500,"size":1048000,"url":"https://upos-sz-mirrorali.bilivideo.com/a-2.mp4","backup_url":null}]}
    """#

    func testCamelCaseDash() {
        let info = VideoAPI.parsePlayInfo(fixture(camelDash))
        XCTAssertTrue(info.isDash)
        XCTAssertEqual(info.quality, 80)
        XCTAssertEqual(info.duration, 215)
        XCTAssertEqual(info.videos.map(\.id), [80, 80, 32, 16])
        let avc = info.videos[0]
        XCTAssertEqual(avc.codecs, "avc1.640032")
        XCTAssertEqual(avc.codecFamily, "avc")
        XCTAssertEqual(avc.backupURLs.count, 2)
        XCTAssertEqual(avc.initRange, "0-1012")
        XCTAssertEqual(avc.indexRange, "1013-1612")
        XCTAssertEqual(avc.frameRate, 30000.0 / 1001.0, accuracy: 0.001)
        XCTAssertEqual(avc.mimeType, "video/mp4")
        XCTAssertEqual(avc.width, 1920)
        XCTAssertEqual(info.videos[1].codecFamily, "hevc")
        XCTAssertEqual(info.videos[1].frameRate, 30)
        XCTAssertEqual(info.videos[1].backupURLs, [])
        XCTAssertEqual(info.videos[2].frameRate, 29.97, accuracy: 0.001)

        XCTAssertEqual(info.audios.map(\.id), [30280, 30232, 30216])
        XCTAssertEqual(info.dolbyAudios.map(\.id), [30250])
        XCTAssertTrue(info.dolbyAudios[0].isDolbyAudio)
        XCTAssertEqual(info.flacAudios.map(\.id), [30251])
        XCTAssertTrue(info.flacAudios[0].isFlacAudio)
        XCTAssertEqual(info.flacAudios[0].initRange, "0-1500")

        XCTAssertEqual(info.qualities.map(\.qn), [112, 80, 64, 32, 16])
        XCTAssertEqual(info.qualities[0].title, "1080P 高码率")
        XCTAssertTrue(info.qualities[0].needVip)
        XCTAssertTrue(info.qualities[2].needLogin)
        XCTAssertEqual(info.qualities[1].codecs.count, 3)
        XCTAssertEqual(info.lastPlayTime, 125)
        XCTAssertEqual(info.lastPlayCid, 279786)
        XCTAssertFalse(info.isTrial)
        XCTAssertEqual(VideoAPI.missingQualityBelowHighest(info), 64)
    }

    func testSnakeCaseDash() {
        let info = VideoAPI.parsePlayInfo(fixture(snakeDash))
        XCTAssertEqual(info.videos.count, 1)
        let v = info.videos[0]
        XCTAssertEqual(v.baseURL, "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/64.m4s")
        XCTAssertEqual(v.backupURLs, ["https://cn-hk-eq-01-01.bilivideo.com/upgcxcode/64.m4s"])
        XCTAssertEqual(v.mimeType, "video/mp4")
        XCTAssertEqual(v.initRange, "0-929")
        XCTAssertEqual(v.indexRange, "930-1653")
        XCTAssertEqual(v.frameRate, 29.412, accuracy: 0.0001)
        XCTAssertEqual(info.audios.first?.indexRange, "820-1300")
        XCTAssertTrue(info.dolbyAudios.isEmpty)
        XCTAssertTrue(info.flacAudios.isEmpty)
        // dash.duration 0 → timelength ms
        XCTAssertEqual(info.duration, 1420)
        // no support_formats → accept_quality + accept_description
        XCTAssertEqual(info.qualities.map(\.qn), [80, 64, 32])
        XCTAssertEqual(info.qualities[1].title, "720P 高清")
        XCTAssertEqual(VideoAPI.missingQualityBelowHighest(info), 32)
    }

    func testDurlOnly() {
        let info = VideoAPI.parsePlayInfo(fixture(durlOnly))
        XCTAssertFalse(info.isDash)
        XCTAssertEqual(info.durl.count, 2)
        XCTAssertEqual(info.durl[0].order, 1)
        XCTAssertEqual(info.durl[0].backupURLs.count, 1)
        XCTAssertEqual(info.durl[1].lengthMs, 30500)
        XCTAssertEqual(info.durl[1].size, 1048000)
        XCTAssertEqual(info.duration, 60.5)
        XCTAssertTrue(info.isTrial)
    }

    func testMergeSupplementedStreams() {
        var a = DashStream(kind: .video, id: 80, baseURL: "a")
        a.codecId = 7
        var b = DashStream(kind: .video, id: 32, baseURL: "b")
        b.codecId = 7
        var dup = DashStream(kind: .video, id: 80, baseURL: "dup")
        dup.codecId = 7
        var c = DashStream(kind: .video, id: 64, baseURL: "c")
        c.codecId = 12
        let merged = VideoAPI.mergeVideoStreams([a, b], [dup, c])
        XCTAssertEqual(merged.map(\.baseURL), ["a", "c", "b"])
    }

    /// 30255 is the second Dolby Atmos id (spec §4.4); it used to be labelled "30255" and, without a
    /// codecs string, not recognised as Dolby (so it could be offered as a plain AAC track).
    func testDolby30255IsDolby() throws {
        let data = fixture(#"""
        {"dash":{"duration":10,"video":[{"id":80,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/v.m4s","codecs":"avc1.640032","codecid":7}],
          "audio":[{"id":30280,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/a.m4s","codecs":"mp4a.40.2"}],
          "dolby":{"type":1,"audio":[{"id":30255,"baseUrl":"https://upos-sz-mirrorali.bilivideo.com/d.m4s","codecs":""}]}}}
        """#)
        let info = VideoAPI.parsePlayInfo(data)
        let dolby = try XCTUnwrap(info.dolbyAudios.first)
        XCTAssertEqual(dolby.id, 30255)
        XCTAssertTrue(dolby.isDolbyAudio)
        XCTAssertFalse(info.audios[0].isDolbyAudio)
        XCTAssertEqual(DashStream.audioTitle(30255), "杜比全景声")
        XCTAssertEqual(VideoAPI.audioRank(30255), VideoAPI.audioRank(30250))
    }

    func testFrameRateVariants() {
        XCTAssertEqual(VideoAPI.parseFrameRate(.string("30")), 30)
        XCTAssertEqual(VideoAPI.parseFrameRate(.string("30000/1001")), 29.97, accuracy: 0.01)
        XCTAssertEqual(VideoAPI.parseFrameRate(.int(60)), 60)
        XCTAssertEqual(VideoAPI.parseFrameRate(.null), 0)
    }

    func testUgcPlayQueryHasRiskParamsAndTryLook() {
        let anon = VideoAPI.ugcPlayQuery(aid: 170001, bvid: "BV17x411w7KC", cid: 279786, qn: 129, loggedIn: false)
        XCTAssertEqual(anon["fnval"] as? Int, 4048)
        XCTAssertEqual(anon["fourk"] as? Int, 1)
        XCTAssertEqual(anon["fnver"] as? Int, 0)
        XCTAssertEqual(anon["try_look"] as? Int, 1)
        XCTAssertEqual(anon["gaia_source"] as? String, "pre-load")
        XCTAssertNotNil(anon["dm_img_str"])
        XCTAssertEqual(anon["web_location"] as? String, "1315873")
        let logged = VideoAPI.ugcPlayQuery(aid: 0, bvid: "BV17x411w7KC", cid: 1, qn: 80, epId: 9, seasonId: 7, loggedIn: true)
        XCTAssertNil(logged["try_look"])
        XCTAssertNil(logged["avid"])
        XCTAssertEqual(logged["ep_id"] as? Int64, 9)
        XCTAssertEqual(logged["season_id"] as? Int64, 7)
    }

    // MARK: PGC

    let pgcPlayView = #"""
    {"video_info":{"quality":80,"timelength":1420000,"is_drm":false,"is_preview":1,
       "accept_quality":[80,64],"accept_description":["1080P","720P"],
       "support_formats":[{"quality":80,"new_description":"1080P 高清","display_desc":"1080P","codecs":["avc1.640032"]},{"quality":64,"new_description":"720P 准高清","display_desc":"720P","codecs":["avc1.640028"]}],
       "dash":{"duration":1420,"video":[{"id":80,"base_url":"https://upos-sz-mirrorcos.bilivideo.com/ogv/80.m4s","backup_url":[],"bandwidth":1500000,"mime_type":"video/mp4","codecs":"avc1.640032","width":1920,"height":1080,"frame_rate":"23.976","segment_base":{"initialization":"0-999","index_range":"1000-2999"},"codecid":7}],
               "audio":[{"id":30280,"base_url":"https://upos-sz-mirrorcos.bilivideo.com/ogv/a.m4s","bandwidth":192000,"mime_type":"audio/mp4","codecs":"mp4a.40.2","segment_base":{"initialization":"0-800","index_range":"801-1300"}}]},
       "clip_info_list":[{"start":90,"end":180,"clipType":"CLIP_TYPE_OP"},{"start":1330,"end":1420,"clipType":"CLIP_TYPE_ED"},{"start":0,"end":0,"clipType":"CLIP_TYPE_OP"}]},
     "watch_progress":{"current_watch_progress":600000,"last_ep_id":0},
     "play_view_business_info":{}}
    """#

    func testPGCPlayView() throws {
        let info = try VideoAPI.parsePGCPlayView(fixture(pgcPlayView))
        XCTAssertTrue(info.isDash)
        XCTAssertTrue(info.isPreview)
        XCTAssertFalse(info.isDRM)
        XCTAssertEqual(info.videos.first?.initRange, "0-999")
        XCTAssertEqual(info.videos.first?.frameRate ?? 0, 23.976, accuracy: 0.001)
        XCTAssertEqual(info.qualities.map(\.title), ["1080P 高清", "720P 准高清"])
        XCTAssertEqual(info.clips.count, 2)
        XCTAssertEqual(info.clips[0].kind, .opening)
        XCTAssertEqual(info.clips[1].kind, .ending)
        XCTAssertEqual(info.lastPlayTime, 600) // ms → s
    }

    func testPGCNotPlayable() {
        let data = fixture(#"{"video_info":null,"not_playable_reason":{"code":-10403,"message":"抱歉您所在地区不可观看！"}}"#)
        XCTAssertThrowsError(try VideoAPI.parsePGCPlayView(data)) { err in
            XCTAssertEqual((err as? BiliError)?.apiCode, -10403)
            XCTAssertTrue(VideoAPI.isRegionLocked(err))
        }
        let mapped = VideoAPI.preferredPGCError([BiliError.api(code: -352, message: "风控"),
                                                 BiliError.api(code: -10403, message: "大会员专享限制")])
        XCTAssertEqual((mapped as? BiliError)?.apiCode, -10403)
        XCTAssertTrue(desc(mapped).contains("该番剧在当前地区不可播放"))
        let other = VideoAPI.preferredPGCError([BiliError.api(code: -352, message: "x"), BiliError.api(code: 6002, message: "需要大会员")])
        XCTAssertEqual((other as? BiliError)?.apiCode, 6002)
    }

    func testPGCLegacyResultShapes() {
        let direct = VideoAPI.parsePGCLegacyResult(fixture(#"{"quality":64,"is_drm":true,"durl":[{"order":1,"length":1000,"size":10,"url":"https://x/1.flv"}]}"#))
        XCTAssertTrue(direct.isDRM)
        XCTAssertEqual(direct.durl.count, 1)
        let v2 = VideoAPI.parsePGCLegacyResult(fixture(#"{"video_info":{"quality":80,"dash":{"duration":10,"video":[{"id":80,"baseUrl":"https://x/v.m4s","codecid":7}],"audio":[]}}}"#))
        XCTAssertEqual(v2.videos.count, 1)
    }

    func testProgressUnitHeuristic() {
        XCTAssertEqual(VideoAPI.normalizeProgress(600_000, duration: 1420), 600)
        XCTAssertEqual(VideoAPI.normalizeProgress(600, duration: 1420), 600)
        XCTAssertEqual(VideoAPI.normalizeProgress(5000, duration: 0), 5)
    }

    func testErrorMapping() {
        let e = VideoAPI.mapError(BiliError.api(code: -404, message: "啥都木有"))
        XCTAssertEqual((e as? BiliError)?.apiCode, -404)
        XCTAssertTrue(desc(e).contains("视频不存在或已被删除"))
        XCTAssertTrue(desc(VideoAPI.mapError(BiliError.api(code: 62004, message: ""))).contains("审核中"))
        XCTAssertTrue(desc(VideoAPI.mapError(BiliError.api(code: 34005, message: ""))).contains("投币上限"))
        XCTAssertTrue(desc(VideoAPI.mapError(BiliError.api(code: 65006, message: ""))).contains("点过赞"))
        XCTAssertTrue(desc(VideoAPI.mapError(BiliError.api(code: -10403, message: ""), context: .pgc)).contains("该番剧在当前地区不可播放"))
        XCTAssertEqual(VideoAPI.mapError(BiliError.api(code: 12345, message: "原样")) as? BiliError, BiliError.api(code: 12345, message: "原样"))
    }
}

// MARK: - Detail / player info / misc

final class VideoAPIDetailParsingTests: XCTestCase {
    let view = #"""
    {"bvid":"BV1xx411c7mD","aid":2,"videos":2,"tid":17,"tname":"单机游戏","copyright":2,
     "pic":"http://i0.hdslb.com/bfs/archive/cover.jpg","title":"测试视频","pubdate":1700000000,"ctime":1699990000,
     "desc":"-","desc_v2":[{"raw_text":"简介第一行","type":1,"biz_id":0}],
     "duration":600,"cid":1001,"season_id":5555,"is_upower_exclusive":false,
     "rights":{"is_stein_gate":0,"no_reprint":1,"is_cooperation":1,"ugc_pay":0,"is_360":0},
     "owner":{"mid":100,"name":"UP主A","face":"//i1.hdslb.com/bfs/face/a.jpg"},
     "stat":{"aid":2,"view":12345,"danmaku":67,"reply":89,"favorite":10,"coin":20,"share":3,"like":456,"dislike":0,"his_rank":12},
     "argue_info":{"argue_msg":"该视频含有争议内容","argue_type":0},
     "dimension":{"width":1080,"height":1920,"rotate":0},
     "pages":[{"cid":1001,"page":1,"from":"vupload","part":"P1 开始","duration":300,"vid":"","dimension":{"width":1920,"height":1080,"rotate":0},"first_frame":"http://i0.hdslb.com/ff1.jpg"},
              {"cid":1002,"page":2,"part":"P2 竖屏","duration":300,"dimension":{"width":1920,"height":1080,"rotate":1}}],
     "ugc_season":{"id":5555,"title":"合集·测试","cover":"http://i0.hdslb.com/season.jpg","mid":100,"intro":"","ep_count":3,
       "sections":[{"season_id":5555,"id":1,"title":"正片","type":1,"episodes":[
           {"season_id":5555,"section_id":1,"id":11,"aid":2,"cid":1001,"title":"第一集","bvid":"BV1xx411c7mD",
            "arc":{"aid":2,"pic":"http://i0.hdslb.com/ep1.jpg","title":"第一集 arc","pubdate":1700000000,"duration":600,"author":{"mid":100,"name":"UP主A","face":""},"stat":{"view":12345,"danmaku":67}},
            "page":{"cid":1001,"page":1,"part":"P1","duration":300},"pages":[{"cid":1001},{"cid":1002}]},
           {"season_id":5555,"section_id":1,"id":12,"aid":3,"cid":2001,"title":"第二集","bvid":"",
            "arc":{"aid":3,"pic":"//i0.hdslb.com/ep2.jpg","duration":120,"stat":{"view":10}},"page":{"cid":2001,"duration":120}}]},
         {"id":2,"title":"番外","episodes":[{"id":13,"aid":4,"cid":3001,"title":"番外一","bvid":"BV1y","arc":{"aid":4,"duration":60}}]}]},
     "staff":[{"mid":100,"title":"UP主","name":"UP主A","face":"//i1.hdslb.com/a.jpg","vip":{"type":2,"status":1,"label":{"text":"年度大会员"}},"follower":1000},
              {"mid":101,"title":"剪辑","name":"B","face":"","follower":5}],
     "honor_reply":{"honor":[{"aid":2,"type":3,"desc":"全站排行榜最高第12名","weekly_recommend_num":0}]},
     "redirect_url":"https://www.bilibili.com/bangumi/play/ep123456"}
    """#

    func testViewDetail() {
        let d = VideoAPI.parseDetail(fixture(view))
        XCTAssertEqual(d.aid, 2)
        XCTAssertEqual(d.bvid, "BV1xx411c7mD")
        XCTAssertEqual(d.cid, 1001)
        XCTAssertEqual(d.desc, "简介第一行")
        XCTAssertEqual(d.cover, "https://i0.hdslb.com/bfs/archive/cover.jpg")
        XCTAssertEqual(d.copyright, 2)
        XCTAssertEqual(d.maxCoins, 1)
        XCTAssertEqual(d.owner.mid, 100)
        XCTAssertEqual(d.owner.face, "https://i1.hdslb.com/bfs/face/a.jpg")
        XCTAssertEqual(d.stat.view, 12345)
        XCTAssertEqual(d.stat.like, 456)
        XCTAssertEqual(d.stat.dislike, 0)
        XCTAssertEqual(d.stat.hisRank, 12)
        XCTAssertTrue(d.rights.noReprint)
        XCTAssertTrue(d.rights.isCooperation)
        XCTAssertFalse(d.rights.isSteinGate)
        XCTAssertEqual(d.argueText, "该视频含有争议内容")
        XCTAssertEqual(d.honorText, "全站排行榜最高第12名")
        XCTAssertTrue(d.isVertical)
        XCTAssertEqual(d.pages.count, 2)
        XCTAssertFalse(d.pages[0].isVertical)
        XCTAssertTrue(d.pages[1].isVertical) // rotate == 1 swaps
        XCTAssertEqual(d.pages[0].firstFrame, "https://i0.hdslb.com/ff1.jpg")
        XCTAssertEqual(d.part(for: 1002)?.part, "P2 竖屏")
        XCTAssertEqual(d.staff.map(\.title), ["UP主", "剪辑"])
        XCTAssertEqual(d.staff[0].user.vipLabel, "年度大会员")
        XCTAssertEqual(d.redirectEpId, 123456)
        XCTAssertTrue(d.isPGCRedirect)

        let season = try? XCTUnwrap(d.ugcSeason)
        XCTAssertEqual(season?.id, 5555)
        XCTAssertEqual(season?.sections.count, 2)
        XCTAssertEqual(season?.episodeCount, 3)
        let eps = season?.allEpisodes ?? []
        XCTAssertEqual(eps.count, 3)
        XCTAssertEqual(eps[0].title, "第一集")
        XCTAssertEqual(eps[0].cover, "https://i0.hdslb.com/ep1.jpg")
        XCTAssertEqual(eps[0].duration, 600)
        XCTAssertEqual(eps[0].pageCount, 2)
        XCTAssertEqual(eps[1].bvid, BVConverter.av2bv(3)) // filled from aid
        XCTAssertEqual(eps[1].cover, "https://i0.hdslb.com/ep2.jpg")
        XCTAssertEqual(season?.sectionIndex(containing: 4), 1)
        let card = VideoDetailCardMapper.ugcEpisode(eps[0])
        XCTAssertEqual(card.id, "BV1xx411c7mD")
        XCTAssertEqual(card.viewCount, 12345)
    }

    func testPGCLinkParsing() {
        XCTAssertEqual(VideoDetail.parsePGCLink("https://www.bilibili.com/bangumi/play/ss28747?from=x")?.seasonId, 28747)
        XCTAssertEqual(VideoDetail.parsePGCLink("https://www.bilibili.com/bangumi/play/ep123")?.epId, 123)
        XCTAssertNil(VideoDetail.parsePGCLink(""))
        XCTAssertNil(VideoDetail.parsePGCLink("https://www.bilibili.com/video/BV1xx"))
    }

    let playerV2 = #"""
    {"aid":2,"bvid":"BV1xx411c7mD","cid":1001,"last_play_time":42000,"last_play_cid":1002,"need_login_subtitle":false,"online_count":3,
     "subtitle":{"allow_submit":false,"lan":"","lan_doc":"","subtitles":[
        {"id":1,"lan":"ai-zh","lan_doc":"中文（自动生成）","is_lock":false,"subtitle_url":"//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/1?auth_key=abc","type":1,"id_str":"1","ai_type":0,"ai_status":2},
        {"id":2,"lan":"en-US","lan_doc":"English","subtitle_url":"//i0.hdslb.com/bfs/subtitle/en.json","type":0},
        {"id":3,"lan":"zh-CN","lan_doc":"中文（中国）","subtitle_url":"https://i0.hdslb.com/bfs/subtitle/zh.json","type":0},
        {"id":4,"lan":"ja","lan_doc":"日本語","subtitle_url":"","type":0}]},
     "view_points":[{"type":2,"from":0,"to":95,"content":"开场","imgUrl":"http://i0.hdslb.com/vp1.jpg"},{"type":2,"from":95,"to":600,"content":"正文"}],
     "interaction":{"graph_version":12345,"history_node":{"node_id":1,"title":"开始","cid":1001}}}
    """#

    func testPlayerExtra() {
        let x = VideoAPI.parsePlayerExtra(fixture(playerV2))
        XCTAssertEqual(x.subtitles.map(\.lan), ["zh-CN", "ai-zh", "en-US"])
        XCTAssertEqual(x.subtitles[1].url, "https://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/1?auth_key=abc")
        XCTAssertTrue(x.subtitles[1].isAI)
        XCTAssertTrue(x.subtitles[1].lanDoc.hasSuffix("（AI）"))
        XCTAssertFalse(x.subtitles[0].isAI)
        XCTAssertEqual(x.subtitles[2].url, "https://i0.hdslb.com/bfs/subtitle/en.json")
        XCTAssertEqual(x.chapters.count, 2)
        XCTAssertEqual(x.chapters[1].title, "正文")
        XCTAssertEqual(x.chapters[1].from, 95)
        XCTAssertEqual(x.lastPlayTime, 42)
        XCTAssertEqual(x.lastPlayCid, 1002)
        XCTAssertEqual(x.steinGraphVersion, 12345)
        XCTAssertEqual(x.onlineHint, "3人在看")
        XCTAssertFalse(x.needLoginSubtitle)

        let noChapters = VideoAPI.parsePlayerExtra(fixture(#"{"view_points":[{"type":1,"from":0,"to":10,"content":"x"}],"need_login_subtitle":true}"#))
        XCTAssertTrue(noChapters.chapters.isEmpty)
        XCTAssertTrue(noChapters.needLoginSubtitle)
    }

    func testSubtitleBody() {
        let body = fixture(#"""
        {"font_size":0.4,"font_color":"#FFFFFF","background_alpha":0.5,"Stroke":"none","type":"AIsubtitle","lang":"zh",
         "body":[{"from":3.5,"to":5.25,"sid":2,"location":2,"content":"  第二句 ","music":0},
                 {"from":0.5,"to":3.0,"sid":1,"location":2,"content":"第一句"},
                 {"from":6,"to":7,"content":"   "}]}
        """#)
        let lines = VideoAPI.parseSubtitleBody(body)
        XCTAssertEqual(lines.map(\.content), ["第一句", "第二句"])
        XCTAssertEqual(lines[1].to, 5.25)
    }

    func testRelation() {
        let r = VideoRelation(json: fixture(#"{"attention":true,"favorite":false,"season_fav":true,"like":true,"dislike":false,"coin":2}"#))
        XCTAssertTrue(r.liked)
        XCTAssertTrue(r.followingUp)
        XCTAssertTrue(r.seasonFav)
        XCTAssertFalse(r.favored)
        XCTAssertEqual(r.coinCount, 2)
        let p = VideoRelation(pgcJSON: fixture(#"{"coin_number":1,"favorite":1,"is_original":0,"like":0}"#))
        XCTAssertEqual(p.coinCount, 1)
        XCTAssertTrue(p.favored)
        XCTAssertFalse(p.liked)
        let t = VideoAPI.parseTriple(fixture(#"{"like":true,"coin":false,"fav":true,"multiply":0}"#))
        XCTAssertTrue(t.like)
        XCTAssertFalse(t.coin)
        XCTAssertTrue(t.fav)
    }

    func testFavFolders() {
        let list = VideoAPI.parseFavFolders(fixture(#"""
        {"count":2,"list":[{"id":1001,"fid":10,"mid":100,"attr":0,"title":"默认收藏夹","fav_state":1,"media_count":12},
                          {"id":1002,"fid":11,"mid":100,"attr":3,"title":"私密","fav_state":0,"media_count":0}]}
        """#))
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].isDefault)
        XCTAssertTrue(list[0].isFavorited)
        XCTAssertEqual(list[0].count, 12)
        XCTAssertFalse(list[1].isDefault)
        XCTAssertTrue(list[1].isPrivate)
        XCTAssertFalse(list[1].isFavorited)
    }

    func testRelatedCards() {
        let cards = VideoAPI.parseRelated(fixture(#"""
        [{"aid":170001,"bvid":"BV17x411w7KC","cid":279786,"videos":1,"title":"相关<em class=\"keyword\">视频</em>","pic":"http://i2.hdslb.com/r.jpg","pubdate":1600000000,
          "desc":"d","duration":233,"owner":{"mid":5,"name":"UP","face":"//i0.hdslb.com/f.jpg"},"stat":{"view":"1.2万","danmaku":3,"like":4}},
         {"aid":0,"bvid":"","title":"broken"},
         {"aid":300,"bvid":"BV1PGC","title":"番剧","redirect_url":"https://www.bilibili.com/bangumi/play/ep999","pgc_label":"番剧","duration":"23:40"}]
        """#))
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].id, "BV17x411w7KC")
        XCTAssertEqual(cards[0].title, "相关视频")
        XCTAssertEqual(cards[0].viewCount, 12000)
        XCTAssertEqual(cards[0].cover, "https://i2.hdslb.com/r.jpg")
        XCTAssertEqual(cards[0].ownerFace, "https://i0.hdslb.com/f.jpg")
        XCTAssertEqual(cards[1].kind, .bangumi)
        XCTAssertEqual(cards[1].epId, 999)
        XCTAssertEqual(cards[1].badge, "番剧")
        XCTAssertEqual(cards[1].duration, 23 * 60 + 40)
    }

    func testPGCSeason() {
        let s = VideoAPI.parsePGCSeason(fixture(#"""
        {"season_id":28747,"media_id":28229002,"title":"测试番剧","season_title":"第一季","cover":"http://i0.hdslb.com/pgc.jpg","evaluate":"简介","type":1,
         "areas":[{"id":2,"name":"日本"}],"styles":["热血","奇幻"],
         "new_ep":{"desc":"已完结, 全12话","id":300,"title":"12"},"publish":{"pub_time_show":"2020年04月开播","is_finish":1},
         "rating":{"count":1234,"score":9.6},
         "stat":{"coins":100,"danmakus":200,"favorite":300,"favorites":400,"likes":500,"reply":600,"share":700,"views":800},
         "up_info":{"avatar":"//i0.hdslb.com/up.jpg","mid":928123,"uname":"官方号"},
         "episodes":[{"aid":11,"bvid":"BV1ep1","cid":111,"ep_id":301,"id":301,"badge":"","cover":"//i0.hdslb.com/e1.jpg","duration":1420000,"title":"1","long_title":"出发","show_title":"第1话 出发","pub_time":1586000000,"status":2,"dimension":{"width":1920,"height":1080,"rotate":0}},
                     {"aid":12,"bvid":"BV1ep2","cid":112,"ep_id":302,"id":302,"badge":"会员","cover":"","duration":1400500,"title":"2","long_title":"到达","status":13}],
         "section":[{"id":9,"title":"预告花絮","type":1,"episodes":[{"aid":13,"cid":113,"id":303,"title":"PV1","duration":90000}]}],
         "seasons":[{"season_id":28748,"media_id":1,"season_title":"第二季","cover":"//i0.hdslb.com/s2.jpg"}],
         "user_status":{"follow":1,"pay":0,"vip":0,"area_limit":0,"progress":{"last_ep_id":302,"last_ep_index":"2","last_time":120}}}
        """#))
        XCTAssertEqual(s.seasonId, 28747)
        XCTAssertEqual(s.title, "测试番剧")
        XCTAssertEqual(s.areas, ["日本"])
        XCTAssertEqual(s.styles, ["热血", "奇幻"])
        XCTAssertEqual(s.newEpDesc, "已完结, 全12话")
        XCTAssertEqual(s.rating?.score, 9.6)
        XCTAssertEqual(s.stat.views, 800)
        XCTAssertEqual(s.stat.danmakus, 200)
        XCTAssertEqual(s.stat.coins, 100)
        XCTAssertEqual(s.stat.likes, 500)
        XCTAssertEqual(s.stat.favorites, 400)
        XCTAssertEqual(s.upInfo?.name, "官方号")
        XCTAssertEqual(s.episodes.count, 2)
        XCTAssertEqual(s.episodes[0].duration, 1420) // ms → s
        XCTAssertEqual(s.episodes[0].displayTitle, "第1话 出发")
        XCTAssertEqual(s.episodes[1].displayTitle, "第2话 到达")
        XCTAssertTrue(s.episodes[1].isVipOnly)
        XCTAssertEqual(s.episodes[0].cover, "https://i0.hdslb.com/e1.jpg")
        XCTAssertEqual(s.sections.first?.episodes.first?.epId, 303)
        XCTAssertTrue(s.sections.first?.episodes.first?.isPreview ?? false)
        XCTAssertFalse(s.episodes[0].isPreview)
        XCTAssertTrue(s.userStatus.follow)
        XCTAssertEqual(s.userStatus.progressEpId, 302)
        XCTAssertEqual(s.userStatus.progressTime, 120)
        XCTAssertEqual(s.defaultEpisode()?.epId, 302)
        XCTAssertEqual(s.defaultEpisode(preferredEpId: 303)?.epId, 303)
        XCTAssertEqual(s.seasons.first?.title, "第二季")
        XCTAssertEqual(s.followVerb, "追番")
        let card = VideoDetailCardMapper.pgcEpisode(s.episodes[0], seasonId: s.seasonId)
        XCTAssertEqual(card.kind, .bangumi)
        XCTAssertEqual(card.videoRef.epId, 301)
        XCTAssertTrue(card.videoRef.isPGC)
    }

    func testOnlineAndVideoshot() {
        XCTAssertEqual(VideoAPI.parseOnlineTotal(fixture(#"{"total":"1000+","count":"1000+","show_switch":{"total":true}}"#)), "1000+")
        XCTAssertNil(VideoAPI.parseOnlineTotal(fixture(#"{"total":"","count":"0"}"#)))
        let shot = VideoAPI.parseVideoShot(fixture(#"""
        {"pvdata":"//i0.hdslb.com/pv.bin","img_x_len":10,"img_y_len":10,"img_x_size":160,"img_y_size":90,
         "image":["//i0.hdslb.com/s1.jpg","//i0.hdslb.com/s2.jpg"],"index":[0,5,10,15,20]}
        """#))
        XCTAssertEqual(shot.images.first, "https://i0.hdslb.com/s1.jpg")
        XCTAssertEqual(shot.tile(at: 12)?.column, 2)
        XCTAssertEqual(shot.tile(at: 12)?.row, 0)
        XCTAssertEqual(shot.tile(at: 999)?.column, 4)
    }

    func testHeartbeatForm() {
        let ugc = VideoAPI.heartbeatForm(aid: 2, bvid: "BV1xx", cid: 3, epId: 0, seasonId: 0, playedTime: 15,
                                         realPlayedTime: 14, type: 3, subType: 0, startTs: 1700000000)
        XCTAssertEqual(ugc["bvid"] as? String, "BV1xx")
        XCTAssertNil(ugc["aid"])
        XCTAssertEqual(ugc["played_time"] as? Int, 15)
        XCTAssertEqual(ugc["real_played_time"] as? Int, 14)
        XCTAssertNil(ugc["epid"])
        let pgc = VideoAPI.heartbeatForm(aid: 2, bvid: "BV1xx", cid: 3, epId: 301, seasonId: 28747, playedTime: -1,
                                         realPlayedTime: 0, type: 4, subType: 1, startTs: 0)
        XCTAssertEqual(pgc["epid"] as? Int64, 301)
        XCTAssertEqual(pgc["sid"] as? Int64, 28747)
        XCTAssertEqual(pgc["sub_type"] as? Int, 1)
        XCTAssertEqual(pgc["played_time"] as? Int, -1)
    }
}

// MARK: - Heartbeat reporter

final class VideoAPIHeartbeatReporterTests: XCTestCase {
    private func makeReporter(allowed: Bool = true) -> (HeartbeatReporter, () -> [Int]) {
        let box = IntBox()
        let reporter = HeartbeatReporter(isAllowed: { allowed }, now: { Date() }, sender: { _ in })
        reporter.observer = { box.values.append($0.playedTime) }
        return (reporter, { box.values })
    }

    func testPlaybackPauseSeekFinish() {
        let (r, sent) = makeReporter()
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 2, duration: 100))
        for t in 0...10 { r.tick(position: Double(t), isPlaying: true) }
        XCTAssertEqual(sent(), [5, 10])
        r.tick(position: 13, isPlaying: true)
        r.tick(position: 13.4, isPlaying: false) // pause, 3 s since last → report
        r.tick(position: 13.4, isPlaying: false)
        r.tick(position: 13.4, isPlaying: true)  // resume, < 2 s → nothing
        XCTAssertEqual(sent(), [5, 10, 13])
        r.seeked(to: 90)
        for t in 91...95 { r.tick(position: Double(t), isPlaying: true) }
        XCTAssertEqual(sent(), [5, 10, 13, 95])
        r.finished(position: 99.6)
        r.stop()
        XCTAssertEqual(sent(), [5, 10, 13, 95, -1])
    }

    func testEarlyFinishAndStopReportPosition() {
        let (r, sent) = makeReporter()
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 2, duration: 100))
        r.tick(position: 1, isPlaying: true)
        r.finished(position: 50) // not really at the end
        XCTAssertEqual(sent(), [50])
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 3, duration: 100), position: 20)
        r.tick(position: 20, isPlaying: true)
        r.tick(position: 22, isPlaying: true)
        r.stop(position: 23)
        XCTAssertEqual(sent(), [50, 23])
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 4, duration: 0))
        r.stop() // position 0 is never reported
        XCTAssertEqual(sent(), [50, 23])
    }

    /// AVPlayer's `currentTime().seconds` is NaN before the item is ready; `Int(.nan)` / `Int(.infinity)`
    /// used to trap in `tick` / `stop` / `finished`.
    func testNonFinitePositionsAreIgnored() {
        let (r, sent) = makeReporter()
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 2, duration: 100), position: .nan)
        r.tick(position: .nan, isPlaying: true)
        r.tick(position: .infinity, isPlaying: true)
        r.seeked(to: -.infinity)
        r.stop()
        XCTAssertEqual(sent(), [], "nothing valid was played")
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 3, duration: 100))
        for t in 0...6 { r.tick(position: Double(t), isPlaying: true) }
        r.tick(position: .nan, isPlaying: true)
        r.finished(position: .nan) // falls back to the last finite position (6)
        r.stop(position: .infinity)
        XCTAssertEqual(sent(), [5, 6])
    }

    func testDisabledReportsNothing() {
        let (r, sent) = makeReporter(allowed: false)
        r.start(.ugc(aid: 1, bvid: "BV1", cid: 2, duration: 100))
        for t in 0...20 { r.tick(position: Double(t), isPlaying: true) }
        r.finished(position: 100)
        r.stop()
        XCTAssertEqual(sent(), [])
    }
}

// MARK: - Replies

final class VideoAPIReplyParsingTests: XCTestCase {
    let mainPage = #"""
    {"cursor":{"is_begin":true,"prev":1,"next":2,"is_end":false,"all_count":1234,"mode":3,"mode_text":"热门评论",
               "pagination_reply":{"next_offset":"{\"type\":1,\"direction\":1,\"session_id\":\"1735\",\"data\":{}}"},"session_id":"1735","support_mode":[2,3],"name":"热门评论"},
     "replies":[
       {"rpid":5001,"oid":2,"type":1,"mid":200,"root":0,"parent":0,"dialog":0,"count":12,"rcount":12,"state":0,"like":321,"ctime":1700000100,"action":1,
        "member":{"mid":"200","uname":"评论者","sex":"保密","avatar":"http://i0.hdslb.com/face/200.jpg","level_info":{"current_level":6},
                  "vip":{"vipType":2,"vipStatus":1,"nickname_color":"#FB7299","label":{"text":"年度大会员"}},
                  "fans_detail":{"uid":200,"medal_id":1,"medal_name":"粉丝牌","level":12}},
        "content":{"message":"太好看了[doge][大笑] @UP主A","members":[{"mid":"100","uname":"UP主A"}],
                   "emote":{"[doge]":{"id":1,"package_id":1,"text":"[doge]","url":"http://i0.hdslb.com/bfs/emote/doge.png","meta":{"size":1}},
                            "[大笑]":{"id":2,"text":"[大笑]","url":"https://i0.hdslb.com/bfs/emote/laugh.png","meta":{"size":2}}},
                   "jump_url":{"关键词":{"title":"关键词","pc_url":"https://search.bilibili.com/all?keyword=x"}},
                   "pictures":[{"img_src":"http://i0.hdslb.com/bfs/new_dyn/p.jpg","img_width":100,"img_height":100}]},
        "replies":[{"rpid":5002,"oid":2,"type":1,"mid":100,"root":5001,"parent":5001,"like":5,"ctime":1700000200,
                    "member":{"mid":"100","uname":"UP主A","avatar":"//i0.hdslb.com/face/100.jpg","level_info":{"current_level":5},"vip":{"vipType":0,"vipStatus":0}},
                    "content":{"message":"谢谢"},"reply_control":{"location":"IP属地：上海"}}],
        "up_action":{"like":true,"reply":true},
        "reply_control":{"max_line":6,"time_desc":"3天前发布","location":"IP属地：广东","sub_reply_entry_text":"共12条回复"}},
       {"rpid":6001,"oid":2,"type":1,"mid":300,"like":1,"ctime":1700000300,"rcount":0,"member":{"uname":"另一位","avatar":"","level_info":{"current_level":3}},"content":{"message":"沙发"},"reply_control":{}},
       {"rpid":7001,"oid":2,"type":1,"mid":100,"like":99,"rcount":0,"member":{"mid":"100","uname":"UP主A"},"content":{"message":"置顶说明"},"reply_control":{}}],
     "top":{"admin":null,"upper":{"rpid":7001,"oid":2,"type":1,"mid":100,"like":99,"member":{"mid":"100","uname":"UP主A"},"content":{"message":"置顶说明"},"reply_control":{"is_up_top":true}},"vote":null},
     "top_replies":[{"rpid":7001,"oid":2,"type":1,"mid":100,"member":{"mid":"100","uname":"UP主A"},"content":{"message":"置顶说明"}}],
     "upper":{"mid":100},
     "control":{"input_disable":false,"root_input_text":"发一条友善的评论","child_input_text":"回复"}}
    """#

    func testMainPage() {
        let page = ReplyAPI.parseMainPage(fixture(mainPage), isFirstPage: true)
        XCTAssertEqual(page.totalCount, 1234)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, #"{"type":1,"direction":1,"session_id":"1735","data":{}}"#)
        XCTAssertEqual(page.upperMid, 100)
        XCTAssertEqual(page.topItems.map(\.rpid), [7001])
        XCTAssertTrue(page.topItems[0].isUpTop)
        XCTAssertTrue(page.topItems[0].isUploader)
        XCTAssertEqual(page.items.map(\.rpid), [5001, 6001]) // pinned one removed from the list
        XCTAssertEqual(page.inputPlaceholder, "发一条友善的评论")

        let r = page.items[0]
        XCTAssertEqual(r.mid, 200)
        XCTAssertEqual(r.uname, "评论者")
        XCTAssertEqual(r.avatar, "https://i0.hdslb.com/face/200.jpg")
        XCTAssertEqual(r.level, 6)
        XCTAssertTrue(r.isVip)
        XCTAssertEqual(r.vipColorHex, "#FB7299")
        XCTAssertEqual(r.memberLabel, "粉丝牌 12")
        XCTAssertEqual(r.emotes["[doge]"], "https://i0.hdslb.com/bfs/emote/doge.png")
        XCTAssertEqual(r.emotes.count, 2)
        XCTAssertTrue(r.largeEmotes.contains("[大笑]"))
        XCTAssertEqual(r.atMembers["UP主A"], 100)
        XCTAssertEqual(r.jumpLinks["关键词"], "https://search.bilibili.com/all?keyword=x")
        XCTAssertEqual(r.pictures, ["https://i0.hdslb.com/bfs/new_dyn/p.jpg"])
        XCTAssertEqual(r.likeCount, 321)
        XCTAssertEqual(r.replyCount, 12)
        XCTAssertEqual(r.replyCountText, "共12条回复")
        XCTAssertEqual(r.location, "IP属地：广东")
        XCTAssertEqual(r.timeDesc, "3天前发布")
        XCTAssertTrue(r.upLiked)
        XCTAssertTrue(r.upReplied)
        XCTAssertTrue(r.userLiked)
        XCTAssertFalse(r.isUploader)
        XCTAssertEqual(r.previewReplies.count, 1)
        XCTAssertTrue(r.previewReplies[0].isUploader)
        XCTAssertEqual(r.previewReplies[0].root, 5001)
        XCTAssertEqual(r.previewReplies[0].location, "IP属地：上海")

        let r2 = page.items[1]
        XCTAssertEqual(r2.mid, 300)
        XCTAssertFalse(r2.isVip)
        XCTAssertNil(r2.vipColorHex)
        XCTAssertEqual(r2.replyCountText, "")
        XCTAssertFalse(r2.userLiked)

        // Later pages never carry pinned replies.
        let later = ReplyAPI.parseMainPage(fixture(mainPage), isFirstPage: false)
        XCTAssertTrue(later.topItems.isEmpty)
        XCTAssertEqual(later.items.count, 3)
    }

    func testEndOfList() {
        let page = ReplyAPI.parseMainPage(fixture(#"{"cursor":{"is_end":true,"all_count":3,"pagination_reply":{}},"replies":[]}"#), isFirstPage: false)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.totalCount, 3)
    }

    func testPaginationStringEscaping() throws {
        XCTAssertEqual(ReplyAPI.paginationString(offset: nil), #"{"offset":""}"#)
        let offset = #"{"type":1,"direction":1,"session_id":"17","data":{"cursor":"a\b"}}"#
        let s = ReplyAPI.paginationString(offset: offset)
        let parsed = try JSON(string: s)
        XCTAssertEqual(parsed["offset"].stringValue, offset)
        let q = ReplyAPI.mainListQuery(oid: 2, type: 1, sort: .time, cursor: offset)
        XCTAssertEqual(q["mode"] as? Int, 2)
        XCTAssertNil(q["seek_rpid"])
        let encoded = BiliHTTP.encodeQuery(["pagination_str": s], sorted: true)
        XCTAssertFalse(encoded.contains("\""))
        XCTAssertTrue(encoded.hasPrefix("pagination_str=%7B%22offset%22%3A%22%7B%5C%22type"))
        XCTAssertEqual(ReplyAPI.mainListQuery(oid: 2, type: 1, sort: .hot, cursor: nil)["mode"] as? Int, 3)
    }

    func testSubPage() {
        let page = ReplyAPI.parseSubPage(fixture(#"""
        {"page":{"num":1,"size":20,"count":45},"upper":{"mid":100},
         "root":{"rpid":5001,"mid":200,"member":{"uname":"评论者"},"content":{"message":"根评论"},"rcount":45},
         "replies":[{"rpid":5002,"root":5001,"parent":5001,"mid":100,"member":{"uname":"UP主A"},"content":{"message":"回复1"}},
                    {"rpid":5003,"root":5001,"parent":5002,"mid":300,"member":{"uname":"C"},"content":{"message":"回复 @UP主A :好"}}],
         "control":{"child_input_text":"回复 @评论者"}}
        """#), page: 1)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.root?.message, "根评论")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "2")
        XCTAssertEqual(page.totalCount, 45)
        XCTAssertTrue(page.items[0].isUploader)
        XCTAssertEqual(page.items[1].parent, 5002)
        XCTAssertEqual(page.inputPlaceholder, "回复 @评论者")

        let last = ReplyAPI.parseSubPage(fixture(#"{"page":{"num":3,"size":20,"count":45},"replies":[{"rpid":9,"content":{"message":"x"}}]}"#), page: 3)
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.nextCursor)
    }

    func testAddResultAndErrors() {
        let added = ReplyAPI.parseAddResult(fixture(#"{"success_toast":"发送成功","reply":{"rpid":8001,"oid":2,"type":1,"mid":200,"member":{"uname":"我"},"content":{"message":"新评论"}}}"#),
                                            oid: 2, type: 1, message: "新评论", root: 0, parent: 0)
        XCTAssertEqual(added.rpid, 8001)
        XCTAssertEqual(added.uname, "我")
        let fallback = ReplyAPI.parseAddResult(fixture(#"{"rpid":8002}"#), oid: 2, type: 1, message: "m", root: 5001, parent: 5001)
        XCTAssertEqual(fallback.rpid, 8002)
        XCTAssertEqual(fallback.root, 5001)
        XCTAssertEqual(fallback.message, "m")
        XCTAssertTrue(desc(ReplyAPI.mapError(BiliError.api(code: 12002, message: ""))).contains("评论区已关闭"))
    }
}
