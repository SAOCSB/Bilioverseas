import Foundation

/// `VideoCard` mappings used by the video detail page (related list, UGC season, PGC episodes).
/// Feed / list mappings live elsewhere.
enum VideoDetailCardMapper {
    /// Archive object as returned by `/x/web-interface/archive/related` (also `view`-shaped items).
    static func archive(_ j: JSON) -> VideoCard? {
        let rawAid = j["aid"].int64Value
        var bvid = j["bvid"].stringValue
        if bvid.isEmpty, rawAid > 0 { bvid = BVConverter.av2bv(rawAid) }
        guard rawAid > 0 || !bvid.isEmpty else { return nil }
        let aid = rawAid > 0 ? rawAid : (BVConverter.bv2av(bvid) ?? 0)
        var c = VideoCard(id: bvid.isEmpty ? "av\(aid)" : bvid)
        c.aid = aid
        c.bvid = bvid
        c.cid = j["cid"].int64Value
        c.title = j["title"].stringValue.strippingHTMLTags
        c.cover = j["pic"].stringValue.biliHTTPS
        if case .string(let d) = j["duration"], d.contains(":") {
            c.duration = Fmt.parseDuration(d)
        } else {
            c.duration = j["duration"].intValue
        }
        c.ownerMid = j[path: "owner.mid"].int64Value
        c.ownerName = j[path: "owner.name"].stringValue
        c.ownerFace = j[path: "owner.face"].stringValue.biliHTTPS
        c.viewCount = j[path: "stat.view"].int64Value
        c.danmakuCount = j[path: "stat.danmaku"].int64Value
        c.likeCount = j[path: "stat.like"].int64Value
        c.pubdate = j["pubdate"].int64Value
        c.desc = j["desc"].stringValue
        c.pageCount = j["videos"].intValue
        c.progress = j["progress"].intValue
        let redirect = j["redirect_url"].stringValue
        if let ids = VideoDetail.parsePGCLink(redirect) {
            c.kind = .bangumi
            c.epId = ids.epId
            c.seasonId = ids.seasonId
            c.uri = redirect
        }
        let pgcLabel = j["pgc_label"].stringValue
        if !pgcLabel.isEmpty {
            c.badge = pgcLabel
        } else if j[path: "charging_pay.level"].intValue > 0 || j["is_upower_exclusive"].boolValue {
            c.badge = "充电专属"
        }
        return c
    }

    static func ugcEpisode(_ e: UgcEpisode) -> VideoCard {
        var c = VideoCard(id: e.bvid.isEmpty ? "av\(e.aid)" : e.bvid)
        c.aid = e.aid
        c.bvid = e.bvid
        c.cid = e.cid
        c.title = e.title
        c.cover = e.cover
        c.duration = e.duration
        c.ownerMid = e.ownerMid
        c.ownerName = e.ownerName
        c.ownerFace = e.ownerFace
        c.viewCount = e.viewCount
        c.danmakuCount = e.danmakuCount
        c.pubdate = e.pubdate
        c.badge = e.badge
        c.pageCount = e.pageCount
        return c
    }

    static func pgcEpisode(_ e: PGCEpisode, seasonId: Int64) -> VideoCard {
        var c = VideoCard(id: "ep\(e.epId)")
        c.kind = .bangumi
        c.aid = e.aid
        c.bvid = e.bvid
        c.cid = e.cid
        c.epId = e.epId
        c.seasonId = seasonId
        c.title = e.displayTitle
        c.cover = e.cover
        c.duration = e.duration
        c.pubdate = e.pubTime
        c.badge = e.badge
        c.uri = e.link
        return c
    }
}
