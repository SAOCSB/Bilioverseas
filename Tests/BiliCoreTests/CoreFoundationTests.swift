import XCTest
@testable import BiliCore

final class JSONTests: XCTestCase {
    func testLenientAccessors() throws {
        let json = try JSON(string: #"{"a":"12","b":3.0,"c":true,"d":"1.5万","e":null,"big":9007199254740993,"arr":[1,"x"],"n":{"m":{"k":"v"}}}"#)
        XCTAssertEqual(json["a"].intValue, 12)
        XCTAssertEqual(json["b"].int64, 3)
        XCTAssertEqual(json["c"].boolValue, true)
        XCTAssertEqual(json["d"].int64Value, 15000)
        XCTAssertFalse(json["e"].exists)
        XCTAssertFalse(json["missing"]["deeper"].exists)
        XCTAssertEqual(json["big"].int64, 9007199254740993)
        XCTAssertEqual(json["arr"][1].stringValue, "x")
        XCTAssertEqual(json["arr"][5].stringValue, "")
        XCTAssertEqual(json[path: "n.m.k"].stringValue, "v")
        XCTAssertEqual(json[path: "arr.0"].intValue, 1)
    }

    func testUnwrapEnvelope() throws {
        let ok = try JSON(string: #"{"code":0,"message":"0","data":{"x":1}}"#)
        XCTAssertEqual(try BiliHTTP.unwrap(ok)["x"].intValue, 1)
        let pgc = try JSON(string: #"{"code":0,"result":{"y":2}}"#)
        XCTAssertEqual(try BiliHTTP.unwrap(pgc)["y"].intValue, 2)
        let bad = try JSON(string: #"{"code":-101,"message":"账号未登录"}"#)
        XCTAssertThrowsError(try BiliHTTP.unwrap(bad)) { err in
            XCTAssertEqual((err as? BiliError)?.apiCode, -101)
        }
    }
}

final class SignerTests: XCTestCase {
    func testWbiMixinKeyAndSignature() {
        let mixin = WbiSigner.mixinKey(imgKey: "7cd084941338484aae1ad9425b84077c",
                                       subKey: "4932caff0ff746eab6f01bf08b70ac45")
        XCTAssertEqual(mixin, "ea1db124af3c7062474693fa704f4ff8")
        let signed = WbiSigner.sign(["foo": "114", "bar": "514", "zab": "1919810"], mixinKey: mixin, wts: 1702204169)
        XCTAssertEqual(signed["w_rid"], "8f6f2b5b3d485fe1886cec6a0be8c5d4")
        XCTAssertEqual(signed["wts"], "1702204169")
    }

    func testWbiStripsBannedCharacters() {
        let signed = WbiSigner.sign(["keyword": "a!b'c(d)e*f"], mixinKey: "k", wts: 1)
        XCTAssertEqual(signed["keyword"], "abcdef")
    }

    func testWbiKeyFromURL() {
        XCTAssertEqual(WbiSigner.keyFromURL("https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png"),
                       "7cd084941338484aae1ad9425b84077c")
    }

    func testAppSign() {
        let signed = AppSigner.sign(["foo": "bar baz"], key: .android, ts: 1700000000)
        XCTAssertEqual(signed["sign"], "e2870bb5b456c525a484e220b43f9cdd")
        XCTAssertEqual(signed["appkey"], "1d8b6e7d45233436")
    }

    func testQueryEncodingMatchesEncodeURIComponentForUnreserved() {
        XCTAssertEqual(BiliHTTP.encodeQuery(["k": "中 文&="], sorted: true), "k=%E4%B8%AD%20%E6%96%87%26%3D")
    }

    /// api-auth §5.1 / §5.2 vectors (space must be `%20`, keys byte-sorted).
    func testSpecSigningVectors() {
        let mixin = "ea1db124af3c7062474693fa704f4ff8"
        XCTAssertEqual(WbiSigner.sign(["mid": "2", "keyword": "a b"], mixinKey: mixin, wts: 1702204169)["w_rid"],
                       "de095135c21c73f0b5ceea70e647cd05")
        let dfca = AppKey(key: "dfca71928277209b", secret: "b5475a8825547a4fc26c7d518eaaa02e")
        XCTAssertEqual(ListMapping.appKey, dfca)
        XCTAssertEqual(AppSigner.sign(["auth_code": "abc", "local_id": "0"], key: dfca, ts: 1700000000)["sign"],
                       "77ac440a7f4c033d8f62ea07505fa64f")
        XCTAssertEqual(AppSigner.sign(["id": "1"], key: .android, ts: 1700000000)["sign"],
                       "1bb92841ca97bc9f7e4b2c533fd254ff")
    }

    /// `Int64(Double)` traps on ±∞ / ≥ 2^63; query stringification must not.
    func testStringifyNonIntegralDoubles() {
        XCTAssertEqual(BiliHTTP.stringify(3.0), "3")
        XCTAssertEqual(BiliHTTP.stringify(444.8), "444.8")
        XCTAssertEqual(BiliHTTP.stringify(Double.infinity), "inf")
        XCTAssertEqual(BiliHTTP.stringify(1e20), "1e+20")
        XCTAssertEqual(BiliHTTP.stringify(true), "1")
        XCTAssertEqual(BiliHTTP.stringify(Int64(9007199254740993)), "9007199254740993")
    }
}

final class FormatterTests: XCTestCase {
    func testCounts() {
        XCTAssertEqual(Fmt.count(Int64(999)), "999")
        XCTAssertEqual(Fmt.count(Int64(12_345)), "1.2万")
        XCTAssertEqual(Fmt.count(Int64(10_000)), "1万")
        XCTAssertEqual(Fmt.count(Int64(250_000_000)), "2.5亿")
    }

    func testDurations() {
        XCTAssertEqual(Fmt.duration(75), "01:15")
        XCTAssertEqual(Fmt.duration(3725), "1:02:05")
        XCTAssertEqual(Fmt.parseDuration("1:02:05"), 3725)
        XCTAssertEqual(Fmt.parseDuration("12:34"), 754)
    }

    func testThumb() {
        XCTAssertEqual(Fmt.thumb("//i0.hdslb.com/bfs/archive/a.jpg", width: 320),
                       "https://i0.hdslb.com/bfs/archive/a.jpg@320w.webp")
        XCTAssertEqual(Fmt.thumb("http://i1.hdslb.com/x.png", width: 100, height: 60),
                       "https://i1.hdslb.com/x.png@100w_60h_1c.webp")
    }

    func testBVConversion() {
        XCTAssertEqual(BVConverter.av2bv(170001), "BV17x411w7KC")
        XCTAssertEqual(BVConverter.bv2av("BV17x411w7KC"), 170001)
        XCTAssertEqual(BVConverter.av2bv(1054803170), "BV1mH4y1u7UA")
        XCTAssertEqual(BVConverter.bv2av("BV1mH4y1u7UA"), 1054803170)
        XCTAssertNil(BVConverter.bv2av("BV1"))
    }
}

final class SettingsStoreTests: XCTestCase {
    struct Sample: SettingsGroup {
        var a: Int = 1
        var nested: Inner = Inner()
        struct Inner: Codable, Equatable { var x: String = "x"; var y: Bool = true }
    }

    func testDeepMergeKeepsNewDefaults() throws {
        let suite = UserDefaults(suiteName: "SettingsStoreTests")!
        suite.removePersistentDomain(forName: "SettingsStoreTests")
        let old = SettingsStore.defaults
        SettingsStore.defaults = suite
        defer { SettingsStore.defaults = old }

        // Simulate an older save missing `nested.y`.
        let saved = try JSONSerialization.data(withJSONObject: ["a": 5, "nested": ["x": "saved"]])
        suite.set(saved, forKey: "k")
        let loaded: Sample = SettingsStore.load(key: "k")
        XCTAssertEqual(loaded.a, 5)
        XCTAssertEqual(loaded.nested.x, "saved")
        XCTAssertEqual(loaded.nested.y, true)
    }
}
