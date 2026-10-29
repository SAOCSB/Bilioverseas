import XCTest
@testable import BiliCore

final class BiliLinkParserTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testExactIDs() {
        XCTAssertEqual(BiliLinkParser.parse(text: "BV1GJ411x7h7"), .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(text: "  bv1GJ411x7h7\n"), .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(text: "av170001"), .video(.aid(170001)))
        XCTAssertEqual(BiliLinkParser.parse(text: "AV170001"), .video(.aid(170001)))
        // Not ids: ordinary keywords stay a search.
        XCTAssertNil(BiliLinkParser.parse(text: "BV1GJ411x7h7 合集"))
        XCTAssertNil(BiliLinkParser.parse(text: "BV1GJ411x7hO"))
        XCTAssertNil(BiliLinkParser.parse(text: "av0"))
        XCTAssertNil(BiliLinkParser.parse(text: "avatar"))
        XCTAssertNil(BiliLinkParser.parse(text: "原神"))
        XCTAssertNil(BiliLinkParser.parse(text: ""))
    }

    func testShareTextAndURLs() {
        XCTAssertEqual(BiliLinkParser.parse(text: "【标题-哔哩哔哩】 https://b23.tv/AbCdEfG"),
                       .shortLink(url("https://b23.tv/AbCdEfG")))
        XCTAssertEqual(BiliLinkParser.parse(text: "b23.tv/AbCdEfG"), .shortLink(url("https://b23.tv/AbCdEfG")))
        XCTAssertNil(BiliLinkParser.parse(text: "https://b23.tv/"))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://www.bilibili.com/video/BV1GJ411x7h7/?share_source=copy_web"),
                       .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(text: "www.bilibili.com/video/av170001"), .video(.aid(170001)))
        var withTime = VideoRef.bvid("BV1GJ411x7h7")
        withTime.startTime = 95
        XCTAssertEqual(BiliLinkParser.parse(text: "https://m.bilibili.com/video/BV1GJ411x7h7?p=1&t=95"), .video(withTime))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://www.bilibili.com/list/watchlater?bvid=BV1GJ411x7h7"),
                       .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://space.bilibili.com/2/dynamic"), .user(mid: 2))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://m.bilibili.com/space/12345"), .user(mid: 12345))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://live.bilibili.com/h5/21452505?broadcast_type=0"),
                       .live(roomId: 21452505))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://www.bilibili.com/bangumi/play/ep331423"),
                       .video(VideoRef(epId: 331423, seasonId: 0)))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://search.bilibili.com/all?keyword=%E5%8E%9F%E7%A5%9E"),
                       .search(keyword: "原神"))
        XCTAssertEqual(BiliLinkParser.parse(text: "https://www.bilibili.com/read/cv123"),
                       .web(url("https://www.bilibili.com/read/cv123")))
        // Other sites, and look-alike hosts, are not Bilibili links.
        XCTAssertNil(BiliLinkParser.parse(text: "https://example.com/video/BV1GJ411x7h7"))
        XCTAssertNil(BiliLinkParser.parse(text: "https://notbilibili.com/video/BV1GJ411x7h7"))
        XCTAssertNil(BiliLinkParser.parse(url: url("https://bilibili.com.example.org/video/BV1GJ411x7h7")))
    }

    func testAppAndOfficialSchemes() {
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://video/BV1GJ411x7h7")), .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://BV1GJ411x7h7")), .video(.bvid("BV1GJ411x7h7")))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://video/av170001")), .video(.aid(170001)))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://video/170001")), .video(.aid(170001)))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://space/2")), .user(mid: 2))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://live/21452505")), .live(roomId: 21452505))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://bangumi/ss12548")),
                       .video(VideoRef(epId: 0, seasonId: 12548)))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://search?keyword=%E5%8E%9F%E7%A5%9E")),
                       .search(keyword: "原神"))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://open?url=https%3A%2F%2Fb23.tv%2FAbCdEfG")),
                       .shortLink(url("https://b23.tv/AbCdEfG")))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilioverseas://open?url=BV1GJ411x7h7")), .video(.bvid("BV1GJ411x7h7")))
        XCTAssertNil(BiliLinkParser.parse(url: url("bilioverseas://open?url=https%3A%2F%2Fexample.com")))
        XCTAssertNil(BiliLinkParser.parse(url: url("bilioverseas://settings")))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilibili://video/170001")), .video(.aid(170001)))
        XCTAssertEqual(BiliLinkParser.parse(url: url("bilibili://space/2")), .user(mid: 2))
        XCTAssertNil(BiliLinkParser.parse(url: url("bilibili://home")))
    }

    func testRedirectTarget() {
        let short = url("https://b23.tv/AbCdEfG")
        XCTAssertEqual(BiliLinkResolver.redirectTarget(status: 302, location: "https://www.bilibili.com/video/BV1GJ411x7h7?share_source=copy",
                                                       finalURL: short, requested: short),
                       url("https://www.bilibili.com/video/BV1GJ411x7h7?share_source=copy"))
        XCTAssertEqual(BiliLinkResolver.redirectTarget(status: 301, location: "/AbCdEfG2", finalURL: short, requested: short),
                       url("https://b23.tv/AbCdEfG2"))
        // Redirect already followed by the transport: the final URL counts once it left the short-link domain.
        XCTAssertEqual(BiliLinkResolver.redirectTarget(status: 412, location: nil,
                                                       finalURL: url("https://www.bilibili.com/video/BV1GJ411x7h7"),
                                                       requested: short),
                       url("https://www.bilibili.com/video/BV1GJ411x7h7"))
        XCTAssertNil(BiliLinkResolver.redirectTarget(status: 200, location: nil, finalURL: short, requested: short))
        XCTAssertNil(BiliLinkResolver.redirectTarget(status: 302, location: "bilibili://video/1", finalURL: short, requested: short))
    }
}
