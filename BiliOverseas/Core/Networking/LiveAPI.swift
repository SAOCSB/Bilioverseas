import Foundation

/// 直播: recommend feed, followed live rooms, room info, HLS play URLs, danmaku credentials.
enum LiveAPI {
    /// Headers for AVPlayer / the media proxy when loading live stream URLs.
    static let playerHeaders: [String: String] = [
        "User-Agent": BiliHTTP.webUserAgent,
        "Referer": "https://www.bilibili.com",
    ]

    static let qnNames: [Int: String] = [
        30000: "杜比", 25000: "4K原画", 20000: "4K", 15000: "2K", 10000: "原画",
        400: "蓝光", 250: "超清", 150: "高清", 80: "流畅",
    ]

    static func qnName(_ qn: Int) -> String { qnNames[qn] ?? "\(qn)" }

    // MARK: - Recommend

    /// 推荐直播. App index feed (only `small_card_v1` cards), falling back to the web
    /// `getUserRecommend` list. Pages start at 1.
    static func recommendRooms(page: Int = 1) async throws -> Page<LiveRoom> {
        do {
            var query = ListMapping.appParams()
            query["actionKey"] = "appkey"
            query["device"] = "android"
            query["device_name"] = "android"
            query["device_type"] = 0
            query["fnval"] = 912
            query["disable_rcmd"] = 0
            query["https_url_req"] = 1
            query["network"] = "wifi"
            query["page"] = page
            query["scale"] = 2
            if page == 1 { query["module_select"] = 1 }
            if BiliHTTP.shared.isLoggedIn { query["relation_page"] = 1 }
            let data = try await BiliHTTP.shared.api(
                BiliHost.live + "/xlive/app-interface/v2/index/feed", query: query,
                sign: .app(ListMapping.appKey), headers: ListMapping.appHeaders(appKeyHeader: "android"))
            let p = parseAppFeed(data, page: page)
            if !p.items.isEmpty || page > 1 { return p }
        } catch {
            if ListMapping.isCancellation(error) { throw error }
        }
        let data = try await BiliHTTP.shared.api(
            BiliHost.live + "/xlive/web-interface/v1/second/getUserRecommend",
            query: ["page": page, "page_size": 30, "platform": "web"],
            headers: ["Origin": "https://live.bilibili.com", "Referer": "https://live.bilibili.com/"])
        return parseWebRecommend(data, page: page)
    }

    /// App feed `data`: only `small_card_v1` cards are rooms (banners, idols, area entrances ignored).
    static func parseAppFeed(_ data: JSON, page: Int) -> Page<LiveRoom> {
        var rooms: [LiveRoom] = []
        var seen = Set<Int64>()
        for card in data["card_list"].arrayValue where card["card_type"].stringValue == "small_card_v1" {
            if let r = roomCard(card["card_data"]["small_card_v1"]), seen.insert(r.roomId).inserted { rooms.append(r) }
        }
        let hasMore = data["has_more"].boolValue
        return Page(items: rooms, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    /// Web `getUserRecommend` `data` (`list[]`) [unverified shape].
    static func parseWebRecommend(_ data: JSON, page: Int) -> Page<LiveRoom> {
        var seen = Set<Int64>()
        let rooms = (data["list"].array ?? data.arrayValue).compactMap(roomCard).filter { seen.insert($0.roomId).inserted }
        let hasMore: Bool
        if let more = data["has_more"].bool { hasMore = more && !rooms.isEmpty } else { hasMore = rooms.count >= 30 }
        return Page(items: rooms, hasMore: hasMore, next: ListCursor.next(page: page, hasMore: hasMore))
    }

    /// Room card shared by the app feed (`small_card_v1`), area lists and web recommend.
    static func roomCard(_ j: JSON) -> LiveRoom? {
        let id = j["roomid"].int64 ?? j["room_id"].int64 ?? j["id"].int64Value
        guard id != 0 else { return nil }
        var r = LiveRoom(roomId: id)
        r.uid = j["uid"].int64Value
        r.title = j["title"].stringValue
        let system = ListMapping.image(j["system_cover"])
        let user = ListMapping.image(j["user_cover"])
        let cover = ListMapping.image(j["cover"])
        r.cover = !system.isEmpty ? system : (!cover.isEmpty ? cover : user)
        r.keyframe = ListMapping.image(j["keyframe"])
        r.uname = j["uname"].stringValue
        r.face = ListMapping.image(j["face"])
        r.online = ListMapping.count(j["online"])
        r.watchedText = j["watched_show"]["text_large"].stringValue
        if r.online == 0 { r.online = ListMapping.count(j["watched_show"]["num"]) }
        r.areaName = j["area_name"].string ?? j["area_v2_name"].stringValue
        r.parentAreaName = j["parent_name"].string ?? j["area_v2_parent_name"].stringValue
        r.liveStatus = j["live_status"].int ?? 1
        return r
    }

    // MARK: - Followed

    /// Followed rooms that are live now (login required).
    static func followedLiving() async throws -> [LiveRoom] {
        var rooms: [LiveRoom] = []
        var seen = Set<Int64>()
        var page = 1
        while page <= 8 {
            let data = try await BiliHTTP.shared.api(
                BiliHost.live + "/xlive/web-ucenter/user/following",
                query: ["page": page, "page_size": 9, "ignoreRecord": 1, "hit_ab": "true"])
            let (live, totalPage, sawOffline) = parseFollowing(data)
            for r in live where seen.insert(r.roomId).inserted { rooms.append(r) }
            // The list is sorted live-first: stop at the first offline room.
            if sawOffline || page >= totalPage { break }
            page += 1
        }
        return rooms
    }

    static func parseFollowing(_ data: JSON) -> (rooms: [LiveRoom], totalPage: Int, sawOffline: Bool) {
        var rooms: [LiveRoom] = []
        var sawOffline = false
        for j in data["list"].arrayValue {
            let status = j["live_status"].intValue
            guard status == 1 else { sawOffline = true; continue }
            guard var r = roomCard(j) else { continue }
            let roomCover = ListMapping.image(j["room_cover"])
            if !roomCover.isEmpty { r.cover = roomCover }
            if r.watchedText.isEmpty { r.watchedText = j["text_small"].stringValue }
            r.liveStatus = 1
            rooms.append(r)
        }
        let list = data["list"].arrayValue
        return (rooms, data["totalPage"].int ?? (list.isEmpty ? 1 : 99), sawOffline || list.isEmpty)
    }

    // MARK: - Room

    /// Room header (`getH5InfoByRoom`).
    static func roomInfo(roomId: Int64) async throws -> LiveRoom {
        let data = try await BiliHTTP.shared.api(
            BiliHost.live + "/xlive/web-room/v1/index/getH5InfoByRoom", query: ["room_id": roomId])
        return parseH5Info(data, roomId: roomId)
    }

    static func parseH5Info(_ data: JSON, roomId: Int64) -> LiveRoom {
        let info = data["room_info"]
        var r = LiveRoom(roomId: info["room_id"].int64 ?? roomId)
        r.uid = info["uid"].int64Value
        r.title = info["title"].stringValue
        r.cover = ListMapping.image(info["cover"])
        r.keyframe = ListMapping.image(info["keyframe"])
        r.online = ListMapping.count(info["online"])
        r.areaName = info["area_name"].stringValue
        r.parentAreaName = info["parent_area_name"].stringValue
        r.liveStatus = info["live_status"].intValue
        let base = data["anchor_info"]["base_info"]
        r.uname = base["uname"].stringValue
        r.face = ListMapping.image(base["face"])
        r.watchedText = data["watched_show"]["text_large"].stringValue
        return r
    }

    // MARK: - Play URL

    /// HLS stream URLs (`getRoomPlayInfo`, WBI). AVPlayer cannot play FLV, so only `http_hls`
    /// streams are returned. URLs are short-lived: request again on playback error.
    static func playURL(roomId: Int64, qn: Int = 10000) async throws -> LivePlayInfo {
        let data = try await BiliHTTP.shared.api(
            BiliHost.live + "/xlive/web-room/v2/index/getRoomPlayInfo",
            query: [
                "room_id": roomId, "protocol": "0,1", "format": "0,1,2", "codec": "0,1,2", "qn": qn,
                "platform": "web", "ptype": 8, "dolby": 5, "panorama": 1, "web_location": "444.8",
            ],
            sign: .wbi,
            headers: ["Origin": "https://live.bilibili.com", "Referer": "https://live.bilibili.com/\(roomId)"])
        return parsePlayInfo(data)
    }

    /// `getRoomPlayInfo` `data` → HLS-only play info. URL = `url_info.host + codec.base_url + url_info.extra`.
    static func parsePlayInfo(_ data: JSON) -> LivePlayInfo {
        var info = LivePlayInfo()
        info.roomId = data["room_id"].int64Value
        info.uid = data["uid"].int64Value
        info.liveStatus = data["live_status"].intValue
        info.isPortrait = data["is_portrait"].boolValue
        let playurl = data["playurl_info"]["playurl"]
        var descs: [Int: String] = [:]
        for q in playurl["g_qn_desc"].arrayValue {
            if let n = q["qn"].int { descs[n] = q["desc"].string ?? qnName(n) }
        }

        struct Candidate { let format: String; let codec: JSON; let codecName: String; let rank: Int }
        var candidates: [Candidate] = []
        for stream in playurl["stream"].arrayValue where stream["protocol_name"].stringValue == "http_hls" {
            for format in stream["format"].arrayValue {
                let fname = format["format_name"].stringValue
                guard fname == "fmp4" || fname == "ts" else { continue }
                for codec in format["codec"].arrayValue {
                    let cname = codec["codec_name"].stringValue
                    let rank = (cname == "avc" ? 0 : 2) + (fname == "fmp4" ? 0 : 1)
                    candidates.append(Candidate(format: fname, codec: codec, codecName: cname, rank: rank))
                }
            }
        }
        candidates.sort { $0.rank < $1.rank }

        var urls: [String] = []
        for c in candidates {
            let base = c.codec["base_url"].stringValue
            guard !base.isEmpty else { continue }
            for u in c.codec["url_info"].arrayValue {
                let url = u["host"].stringValue + base + u["extra"].stringValue
                guard url.hasPrefix("http"), !url.lowercased().contains(".flv"), !urls.contains(url) else { continue }
                urls.append(url)
            }
        }
        info.urls = urls
        if let best = candidates.first(where: { !$0.codec["base_url"].stringValue.isEmpty }) {
            info.format = best.format
            info.codec = best.codecName
            info.currentQn = best.codec["current_qn"].intValue
            let accept = best.codec["accept_qn"].arrayValue.compactMap(\.int)
            info.qualities = accept.map { LiveQualityOption(qn: $0, desc: descs[$0] ?? qnName($0)) }
        }
        if info.qualities.isEmpty {
            info.qualities = playurl["g_qn_desc"].arrayValue.compactMap { q in
                q["qn"].int.map { LiveQualityOption(qn: $0, desc: descs[$0] ?? qnName($0)) }
            }
        }
        return info
    }

    // MARK: - Danmaku

    /// 发送直播弹幕 (`POST api.live.bilibili.com/msg/send`, WBI query `web_location=444.8`, csrf in the
    /// form, as PiliPlus `sendLiveMsg`). Login required; the server enforces length and rate limits.
    static func sendMessage(roomId: Int64, text: String, color: UInt32 = 0xFFFFFF, fontSize: Int = 25) async throws {
        let http = BiliHTTP.shared
        guard let csrf = http.csrf else { throw BiliError.notLoggedIn }
        _ = try await http.api(
            BiliHost.live + "/msg/send", method: "POST", query: ["web_location": "444.8"],
            form: [
                "bubble": 0, "msg": text, "color": Int(color & 0xFFFFFF), "mode": 1, "room_type": 0, "jumpfrom": 0,
                "reply_mid": 0, "reply_attr": 0, "replay_dmid": "", "statistics": #"{"appId":100,"platform":5}"#,
                "reply_type": 0, "reply_uname": "", "fontsize": fontSize, "rnd": Int(Date().timeIntervalSince1970),
                "roomid": roomId, "csrf": csrf, "csrf_token": csrf,
            ],
            sign: .wbi,
            headers: ["Origin": "https://live.bilibili.com", "Referer": "https://live.bilibili.com/\(roomId)"])
    }

    static func danmuInfo(roomId: Int64) async throws -> LiveDanmuInfo {
        let data = try await BiliHTTP.shared.api(
            BiliHost.live + "/xlive/web-room/v1/index/getDanmuInfo",
            query: ["id": roomId, "web_location": "444.8"], sign: .wbi,
            headers: ["Origin": "https://live.bilibili.com", "Referer": "https://live.bilibili.com/\(roomId)"])
        return parseDanmuInfo(data)
    }

    static func parseDanmuInfo(_ data: JSON) -> LiveDanmuInfo {
        let hosts: [LiveDanmuHost] = data["host_list"].arrayValue.compactMap { h in
            let host = h["host"].stringValue
            guard !host.isEmpty else { return nil }
            return LiveDanmuHost(host: host, port: h["port"].intValue, wssPort: h["wss_port"].int ?? 443,
                                 wsPort: h["ws_port"].intValue)
        }
        return LiveDanmuInfo(token: data["token"].stringValue,
                             hosts: hosts.isEmpty ? [LiveDanmuHost(host: "broadcastlv.chat.bilibili.com")] : hosts)
    }
}
