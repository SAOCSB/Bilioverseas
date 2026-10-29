// 「空降助手」 — BilibiliSponsorBlock segment lookup (features.md §11.1, API:
// https://github.com/hanydd/BilibiliSponsorBlock/wiki/API). Not part of the BiliSmartSkip port.
// Part of BiliOverseas (GPL-2.0-or-later).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET {server}/api/skipSegments?videoID={bvid}&cid={cid}`. Third-party server: requests go through the
/// cookie-less transport (`.omit`), never with the Bilibili account cookies. Fails soft: any error is
/// `nil` (nothing skipped, the local detectors are unaffected), a 404 means "no segments".
struct SponsorBlockClient {
    var transport: SmartSkipTransport

    init(transport: SmartSkipTransport = SmartSkipBiliTransport()) {
        self.transport = transport
    }

    /// `https://www.bsbsb.top/` → `https://www.bsbsb.top`; a bare host gets `https://`. `nil` if unusable.
    static func normalizedServer(_ server: String) -> String? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return s
    }

    /// The query: the spec's `videoID` + `cid`, plus the categories / action types this app can use.
    /// SponsorBlock-derived servers return only `sponsor` / `skip` rows unless asked for more.
    static func query(bvid: String, cid: Int64, filtered: Bool) -> [String: String] {
        var query = ["videoID": bvid, "cid": String(cid)]
        if filtered {
            query["categories"] = jsonArray(SponsorBlockCategory.rangeCategories.map(\.rawValue))
            query["actionTypes"] = jsonArray([SponsorBlockActionType.skip.rawValue, SponsorBlockActionType.mute.rawValue])
        }
        return query
    }

    private static func jsonArray(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// Every segment of the part (all range categories; the per-category settings are applied later, so
    /// a settings change needs no new request). `[]` = none (404 or an empty list); `nil` = failed.
    func skipSegments(bvid: String, cid: Int64, server: String) async -> [SponsorBlockSegment]? {
        guard !bvid.isEmpty, cid > 0, let base = Self.normalizedServer(server) else { return nil }
        let url = base + "/api/skipSegments"
        // A server that rejects the filters (400) gets the plain request of the spec once.
        for filtered in [true, false] {
            do {
                let data = try await transport.get(url, query: Self.query(bvid: bvid, cid: cid, filtered: filtered),
                                                   credentials: .omit, wbi: false)
                return try Self.parseSegments(data)
            } catch {
                let status = SmartSkipDataLoader.httpStatus(of: error)
                if status == 404 { return [] }
                if filtered, status == 400, !Task.isCancelled { continue }
                SmartSkipUtils.log("sponsorblock skipSegments failed:", error)
                return nil
            }
        }
        return nil
    }

    /// Parses the JSON array; rows without a numeric `[start, end]` are skipped. A non-array body throws.
    static func parseSegments(_ data: Data) throws -> [SponsorBlockSegment] {
        let json = try JSON(data: data)
        guard let rows = json.array else { throw BiliError.decoding("skipSegments: not an array") }
        return rows.compactMap { row in
            let range = row["segment"].arrayValue
            guard range.count >= 2, let start = range[0].double, let end = range[1].double else { return nil }
            return SponsorBlockSegment(uuid: row["UUID"].stringValue,
                                       category: row["category"].stringValue,
                                       actionType: row["actionType"].string ?? SponsorBlockActionType.skip.rawValue,
                                       start: start, end: end,
                                       votes: row["votes"].intValue,
                                       videoDuration: row["videoDuration"].doubleValue)
        }
    }
}
