import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BiliCore

final class AuthParsingTests: XCTestCase {
    /// A throwaway cookie jar. Darwin: the process' shared storage (tests use unique cookie names
    /// and clean up); Linux: an isolated group storage.
    private func scratchCookieStorage() -> HTTPCookieStorage {
        #if canImport(Darwin)
        return HTTPCookieStorage.shared
        #else
        return HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "auth-tests-\(UUID().uuidString)")
        #endif
    }

    private func removeCookies(prefixed prefix: String, from storage: HTTPCookieStorage) {
        for c in storage.cookies ?? [] where c.name.hasPrefix(prefix) { storage.deleteCookie(c) }
    }

    // MARK: nav

    private let loggedInNav = #"""
    {"code":0,"message":"0","ttl":1,"data":{"isLogin":true,"email_verified":1,"face":"http://i0.hdslb.com/bfs/face/abc.jpg",
     "level_info":{"current_level":5,"current_min":10800,"current_exp":12345,"next_exp":28800},
     "mid":123456789,"mobile_verified":1,"money":321.5,"moral":70,
     "official":{"role":0,"title":"","desc":"","type":-1},"officialVerify":{"type":-1,"desc":""},
     "pendant":{"pid":0,"name":"","image":"","expire":0},"scores":0,"uname":"测试用户",
     "vipDueDate":1767196800000,"vipStatus":1,"vipType":2,"vip_pay_type":0,"vip_theme_type":0,
     "vip_label":{"path":"","text":"年度大会员","label_theme":"annual_vip"},"vip_avatar_subscript":1,
     "vip_nickname_color":"#FB7299","wallet":{"mid":123456789,"bcoin_balance":2,"coupon_balance":0},
     "has_shop":false,"shop_url":"","is_senior_member":1,
     "wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}
    """#

    private let loggedOutNav = #"""
    {"code":-101,"message":"账号未登录","ttl":1,"data":{"isLogin":false,
     "wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}
    """#

    func testNavLoggedInProfile() throws {
        let nav = AccountNavInfo(root: try JSON(string: loggedInNav))
        XCTAssertEqual(nav.code, 0)
        XCTAssertTrue(nav.isLogin)
        XCTAssertFalse(nav.isLoggedOutResponse)
        let p = try XCTUnwrap(nav.profile)
        XCTAssertEqual(p.mid, 123456789)
        XCTAssertEqual(p.name, "测试用户")
        XCTAssertEqual(p.face, "https://i0.hdslb.com/bfs/face/abc.jpg")
        XCTAssertEqual(p.level, 5)
        XCTAssertEqual(p.currentMinExp, 10800)
        XCTAssertEqual(p.currentExp, 12345)
        XCTAssertEqual(p.nextExp, 28800)
        XCTAssertEqual(p.coins, 321.5, accuracy: 0.0001)
        XCTAssertEqual(p.bcoin, 2)
        XCTAssertEqual(p.vipType, 2)
        XCTAssertEqual(p.vipStatus, 1)
        XCTAssertTrue(p.isVip)
        XCTAssertTrue(p.isAnnualVip)
        XCTAssertEqual(p.vipDueDate, 1767196800000)
        XCTAssertEqual(p.vipLabelText, "年度大会员")
        XCTAssertEqual(p.vipNicknameColorHex, "#FB7299")
        XCTAssertTrue(p.isSeniorMember)
        XCTAssertNil(p.official)
        XCTAssertEqual(p.pendantImage, "")
        XCTAssertNil(p.sign)
        XCTAssertEqual(p.expText, "12345/28800")
        XCTAssertEqual(p.levelProgress, 12345.0 / 28800.0, accuracy: 0.0001)
        XCTAssertEqual(WbiSigner.keyFromURL(nav.wbiImgURL), "7cd084941338484aae1ad9425b84077c")
        XCTAssertEqual(WbiSigner.keyFromURL(nav.wbiSubURL), "4932caff0ff746eab6f01bf08b70ac45")
    }

    func testNavLevel6AndOfficialAndIntMoney() throws {
        let json = try JSON(string: #"""
        {"code":0,"data":{"isLogin":true,"mid":2,"uname":"碧诗","face":"//i1.hdslb.com/x.jpg","money":100,
         "level_info":{"current_level":6,"current_min":28800,"current_exp":99999,"next_exp":"--"},
         "official":{"role":3,"title":"bilibili 创始人","desc":"","type":0},
         "vip":{"type":1,"status":1,"label":{"text":"大会员"},"nickname_color":"#FB7299"},
         "pendant":{"image":"http://i0.hdslb.com/bfs/garb/p.png"},
         "wbi_img":{"img_url":"a/b.png","sub_url":"c/d.png"}}}
        """#)
        let p = try XCTUnwrap(AccountNavInfo(root: json).profile)
        XCTAssertEqual(p.level, 6)
        XCTAssertNil(p.nextExp)
        XCTAssertEqual(p.levelProgress, 1)
        XCTAssertEqual(p.expText, "99999/--")
        XCTAssertEqual(p.coins, 100)
        XCTAssertNil(p.bcoin)
        XCTAssertEqual(p.face, "https://i1.hdslb.com/x.jpg")
        // Falls back to the nested `vip` object when the flat fields are absent.
        XCTAssertEqual(p.vipType, 1)
        XCTAssertEqual(p.vipStatus, 1)
        XCTAssertEqual(p.vipLabelText, "大会员")
        XCTAssertFalse(p.isAnnualVip)
        XCTAssertEqual(p.official, AccountOfficial(type: 0, role: 3, title: "bilibili 创始人", desc: ""))
        XCTAssertEqual(p.pendantImage, "https://i0.hdslb.com/bfs/garb/p.png")
    }

    func testNavLoggedOutStillCarriesWbiKeys() throws {
        let nav = AccountNavInfo(root: try JSON(string: loggedOutNav))
        XCTAssertEqual(nav.code, -101)
        XCTAssertFalse(nav.isLogin)
        XCTAssertTrue(nav.isLoggedOutResponse)
        XCTAssertNil(nav.profile)
        XCTAssertEqual(nav.wbiImgURL, "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png")
        XCTAssertEqual(nav.wbiSubURL, "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png")
        XCTAssertNil(UserProfile(nav: try JSON(string: loggedOutNav)["data"]))
    }

    func testNavRiskControlIsNotLoggedOut() throws {
        let nav = AccountNavInfo(root: try JSON(string: #"{"code":-352,"message":"风控校验失败"}"#))
        XCTAssertFalse(nav.isLogin)
        XCTAssertFalse(nav.isLoggedOutResponse)
    }

    func testUserStat() throws {
        let d = try JSON(string: #"{"code":0,"data":{"following":233,"follower":"1024","dynamic_count":7}}"#)
        let s = UserStat(json: d["data"])
        XCTAssertEqual(s, UserStat(following: 233, follower: 1024, dynamicCount: 7))
    }

    func testProfileCodableRoundTrip() throws {
        var p = UserProfile(mid: 5, name: "a", face: "https://x", level: 3)
        p.nextExp = nil
        p.official = AccountOfficial(type: 1, role: 2, title: "t", desc: "d")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: data), p)
    }

    // MARK: web QR

    func testWebQRPollStates() throws {
        func state(_ code: Int) throws -> QRLoginState {
            try LoginAPI.parseWebQRPoll(try JSON(string: #"{"code":0,"message":"0","data":{"url":"","refresh_token":"","timestamp":0,"code":\#(code),"message":"m"}}"#))
        }
        XCTAssertEqual(try state(86101), .waitingScan)
        XCTAssertEqual(try state(86090), .scannedWaitingConfirm)
        XCTAssertEqual(try state(86038), .expired)
        XCTAssertThrowsError(try state(12345)) { XCTAssertEqual(($0 as? BiliError)?.apiCode, 12345) }

        let ok = try JSON(string: #"""
        {"code":0,"message":"0","data":{"url":"https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=1","refresh_token":"rt123","timestamp":1700000000000,"code":0,"message":""}}
        """#)
        XCTAssertEqual(try LoginAPI.parseWebQRPoll(ok),
                       .success(refreshToken: "rt123",
                                crossDomainURL: "https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=1"))

        // Top-level failure (e.g. bad request) throws the top-level code.
        XCTAssertThrowsError(try LoginAPI.parseWebQRPoll(try JSON(string: #"{"code":-400,"message":"请求错误"}"#))) {
            XCTAssertEqual(($0 as? BiliError)?.apiCode, -400)
        }
    }

    func testCrossDomainURLCookies() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = "https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=123456789"
            + "&DedeUserID__ckMd5=0a1b2c3d4e5f6789&Expires=1715552000"
            + "&SESSDATA=abcd1234%2C1715552000%2Cef56%2A41&bili_jct=0123456789abcdef0123456789abcdef"
            + "&gourl=https%3A%2F%2Fwww.bilibili.com&first_domain=.bilibili.com"
        let cookies = LoginAPI.cookies(fromCrossDomainURL: url, now: now)
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"])
        XCTAssertEqual(byName["DedeUserID"]?.value, "123456789")
        XCTAssertEqual(byName["DedeUserID__ckMd5"]?.value, "0a1b2c3d4e5f6789")
        // Kept percent-encoded, exactly like the server's Set-Cookie.
        XCTAssertEqual(byName["SESSDATA"]?.value, "abcd1234%2C1715552000%2Cef56%2A41")
        XCTAssertEqual(byName["bili_jct"]?.value, "0123456789abcdef0123456789abcdef")
        for c in cookies {
            XCTAssertEqual(c.domain, ".bilibili.com")
            XCTAssertEqual(c.path, "/")
            XCTAssertEqual(c.expiresDate?.timeIntervalSince1970 ?? 0, 1715552000, accuracy: 1)
        }
        XCTAssertTrue(LoginAPI.cookies(fromCrossDomainURL: "https://x.com/no-query", now: now).isEmpty)
    }

    func testCrossDomainCookiesApplyToAPIHost() throws {
        let storage = scratchCookieStorage()
        let url = "https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=42&SESSDATA=s%2C1&bili_jct=j"
        // Same attributes as the real ones, unique names so a shared jar is not disturbed.
        for c in LoginAPI.cookies(fromCrossDomainURL: url) {
            var s = StoredCookie(c)
            s.name = "authtest_" + s.name
            if let renamed = s.httpCookie { storage.setCookie(renamed) }
        }
        let names = Set((storage.cookies(for: URL(string: "https://api.bilibili.com/x/web-interface/nav")!) ?? []).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["authtest_DedeUserID", "authtest_SESSDATA", "authtest_bili_jct"]))
        removeCookies(prefixed: "authtest_", from: storage)
    }

    // MARK: TV QR

    func testTVQRPollStates() throws {
        func state(_ code: Int) throws -> TVQRLoginState {
            try LoginAPI.parseTVQRPoll(try JSON(string: #"{"code":\#(code),"message":"m","ttl":1,"data":null}"#))
        }
        guard case .waitingScan = try state(86039) else { return XCTFail("86039") }
        guard case .scannedWaitingConfirm = try state(86090) else { return XCTFail("86090") }
        guard case .expired = try state(86038) else { return XCTFail("86038") }
        XCTAssertThrowsError(try state(-3)) { XCTAssertEqual(($0 as? BiliError)?.apiCode, -3) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = try JSON(string: #"""
        {"code":0,"message":"0","data":{"is_new":false,"mid":42,"access_token":"at_x","refresh_token":"rt_x","expires_in":15552000,
         "token_info":{"mid":42,"access_token":"at_x","refresh_token":"rt_x","expires_in":15552000},
         "cookie_info":{"cookies":[
           {"name":"SESSDATA","value":"s%2C1715552000%2Cab","http_only":1,"expires":1715552000,"secure":1},
           {"name":"bili_jct","value":"jct","http_only":0,"expires":1715552000,"secure":0},
           {"name":"DedeUserID","value":"42","http_only":0,"expires":1715552000,"secure":0},
           {"name":"sid","value":"sid1","http_only":0,"expires":0,"secure":0}],
          "domains":[".bilibili.com",".biligame.com"]}}}
        """#)
        guard case .success(let r) = try LoginAPI.parseTVQRPoll(ok, now: now) else { return XCTFail("success") }
        XCTAssertEqual(r.mid, 42)
        XCTAssertEqual(r.accessToken, "at_x")
        XCTAssertEqual(r.refreshToken, "rt_x")
        XCTAssertEqual(r.expiresIn, 15552000)
        XCTAssertEqual(r.cookies.map(\.name), ["SESSDATA", "bili_jct", "DedeUserID", "sid"])
        XCTAssertTrue(r.cookies.allSatisfy { $0.domain == ".bilibili.com" && $0.path == "/" })
        XCTAssertEqual(r.cookies[0].value, "s%2C1715552000%2Cab")
        XCTAssertEqual(r.cookies[0].expiresDate?.timeIntervalSince1970 ?? 0, 1715552000, accuracy: 1)
        // expires 0 → default lifetime.
        XCTAssertEqual(r.cookies[3].expiresDate?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + LoginAPI.defaultSessionLifetime, accuracy: 1)

        // token_info-only shape.
        let nested = try JSON(string: #"{"code":0,"data":{"token_info":{"mid":7,"access_token":"a","refresh_token":"r","expires_in":1},"cookie_info":{"cookies":[]}}}"#)
        guard case .success(let r2) = try LoginAPI.parseTVQRPoll(nested, now: now) else { return XCTFail("nested") }
        XCTAssertEqual(r2.mid, 7)
        XCTAssertEqual(r2.accessToken, "a")
    }

    func testTVAppSignVector() {
        // api-auth §5.2 vector for the TV key.
        let signed = AppSigner.sign(["local_id": "0"], key: .tv, ts: 1700000000)
        XCTAssertEqual(signed["sign"], "ebb086c9f52ae7393619a89bdc320e45")
    }

    // MARK: bili_ticket

    func testBiliTicketHexsign() {
        // python3 -c "import hmac,hashlib;print(hmac.new(b'XgwSnGZ1p',b'ts1234567890',hashlib.sha256).hexdigest())"
        XCTAssertEqual(BiliTicket.hexsign(ts: 1234567890),
                       "a7da9d971f117aa2b439c4b6cc46c7afbba8ade9f3ca959578af1bcfb37ebd2f")
        // api-auth §4.7 vector.
        XCTAssertEqual(BiliTicket.hexsign(ts: 1700000000),
                       "bb79f0d980ffbb51597aa1a3e8b55603025cc1322ac766f4c1a98852e6182514")
    }

    // MARK: cookie refresh

    func testRefreshCSRFExtraction() {
        let html = """
        <!DOCTYPE html><html><head><title>correspond</title></head><body>
        <div id="1-name">b0cc8411ded2f9db2cff2edb3123acac</div>
        <div id="2-name">other</div></body></html>
        """
        XCTAssertEqual(LoginAPI.extractRefreshCSRF(html: html), "b0cc8411ded2f9db2cff2edb3123acac")
        XCTAssertEqual(LoginAPI.extractRefreshCSRF(html: "<div id='1-name'>\n  abc  \n</div>"), "abc")
        XCTAssertNil(LoginAPI.extractRefreshCSRF(html: "<html><body>404</body></html>"))
        XCTAssertNil(LoginAPI.extractRefreshCSRF(html: #"<div id="1-name"></div>"#))
    }

    func testCorrespondKeyDecodes() throws {
        let der = try XCTUnwrap(Data(base64Encoded: LoginAPI.correspondPublicKeyPKCS1Base64))
        XCTAssertEqual(der.count, 140) // PKCS#1 RSAPublicKey for a 1024-bit modulus
        XCTAssertEqual(der.prefix(4).map { $0 }, [0x30, 0x81, 0x89, 0x02])
    }

    #if canImport(Security)
    func testCorrespondPathShape() throws {
        let path = try LoginAPI.correspondPath(timestampMs: 1700000000000)
        XCTAssertEqual(path.count, 256)
        XCTAssertTrue(path.allSatisfy { "0123456789abcdef".contains($0) })
        // OAEP is randomized.
        XCTAssertNotEqual(path, try LoginAPI.correspondPath(timestampMs: 1700000000000))
    }
    #endif

    // MARK: cookie string

    func testCookieStringParsing() {
        let pairs = LoginAPI.parseCookieString(" Cookie: SESSDATA=abc%2C123%2Cx*; bili_jct=def ;DedeUserID=42; empty=; buvid3=\"q\"; bad ")
        XCTAssertEqual(pairs.map(\.name), ["SESSDATA", "bili_jct", "DedeUserID", "buvid3"])
        XCTAssertEqual(pairs.map(\.value), ["abc%2C123%2Cx*", "def", "42", "q"])

        let multi = LoginAPI.parseCookieString("SESSDATA=a\nbili_jct=b\r\nDedeUserID=1;SESSDATA=c")
        XCTAssertEqual(multi.map(\.name), ["bili_jct", "DedeUserID", "SESSDATA"])
        XCTAssertEqual(multi.last?.value, "c")

        // DevTools "Application → Cookies" table copy.
        let devtools = LoginAPI.parseCookieString("SESSDATA\txyz%2C1\t.bilibili.com\t/\nbili_jct\tjjj\t.bilibili.com\t/")
        XCTAssertEqual(devtools.map(\.name), ["SESSDATA", "bili_jct"])
        XCTAssertEqual(devtools.map(\.value), ["xyz%2C1", "jjj"])

        // Values containing "=" keep everything after the first "=".
        XCTAssertEqual(LoginAPI.parseCookieString("a=b=c").first?.value, "b=c")
        XCTAssertTrue(LoginAPI.parseCookieString("   ").isEmpty)
    }

    func testMakeCookieAndStoredCookieRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let c = try XCTUnwrap(LoginAPI.makeCookie(name: "SESSDATA", value: "v%2C1", secure: true, httpOnly: true, now: now))
        XCTAssertEqual(c.domain, ".bilibili.com")
        XCTAssertEqual(c.path, "/")
        XCTAssertTrue(c.isSecure)
        XCTAssertEqual(c.expiresDate?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 + LoginAPI.defaultSessionLifetime, accuracy: 1)
        let stored = StoredCookie(c)
        XCTAssertEqual(stored.name, "SESSDATA")
        XCTAssertEqual(stored.value, "v%2C1")
        XCTAssertTrue(stored.secure)
        let back = try XCTUnwrap(stored.httpCookie)
        XCTAssertEqual(back.value, "v%2C1")
        XCTAssertEqual(back.domain, ".bilibili.com")
    }

    // MARK: persistence

    func testStoredSessionCodec() throws {
        let s = StoredSession(
            cookies: [StoredCookie(name: "SESSDATA", value: "x", expires: 2_000_000_000, secure: true, httpOnly: true),
                      StoredCookie(name: "b_lsid", value: "y")],
            refreshToken: "rt", accessKey: "ak", accessKeyAppKey: AppKey.tv.key,
            accessKeyExpiresAt: 2_000_000_000, appRefreshToken: "art", savedAt: 1)
        let data = try XCTUnwrap(CookiePersistence.encode(s))
        XCTAssertEqual(CookiePersistence.decode(data), s)
        XCTAssertNil(CookiePersistence.decode(Data("garbage".utf8)))
    }

    func testSnapshotAndRestoreFilterDomainsAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let storage = scratchCookieStorage()
        let restored = CookiePersistence.restore([
            StoredCookie(name: "authsnap_SESSDATA", value: "a", expires: 1_800_000_000),
            StoredCookie(name: "authsnap_old", value: "b", expires: 1_600_000_000),
            StoredCookie(name: "authsnap_x", value: "c", domain: ".example.com", expires: 1_800_000_000),
        ], into: storage, now: now)
        XCTAssertEqual(restored, 1)
        let snap = CookiePersistence.snapshot(from: storage, now: now).filter { $0.name.hasPrefix("authsnap_") }
        XCTAssertEqual(snap.map(\.name), ["authsnap_SESSDATA"])
        removeCookies(prefixed: "authsnap_", from: storage)
        XCTAssertTrue(CookiePersistence.isBiliDomain(".bilibili.com"))
        XCTAssertTrue(CookiePersistence.isBiliDomain("passport.bilibili.com"))
        XCTAssertFalse(CookiePersistence.isBiliDomain("notbilibili.com"))
    }

    // MARK: device ids

    func testWebDeviceIDFormats() {
        let b3 = WebDeviceID.localBuvid3()
        XCTAssertEqual(b3.count, 46)
        XCTAssertTrue(b3.hasSuffix("infoc"))
        XCTAssertEqual(b3.filter { $0 == "-" }.count, 4)

        let uuid = WebDeviceID.uuid(nowMs: 1_700_000_001_230)
        XCTAssertEqual(uuid.split(separator: "-").count, 5)
        // ms % 100000 = 1230 → "1230" right-padded → "12300".
        XCTAssertTrue(WebDeviceID.uuid(nowMs: 1_700_000_001_230).hasSuffix("12300infoc"))
        XCTAssertTrue(WebDeviceID.uuid(nowMs: 1_700_000_012_345).hasSuffix("12345infoc"))

        let lsid = WebDeviceID.bLsid(nowMs: 0x18C3E1C4A5B)
        XCTAssertTrue(lsid.hasSuffix("_18C3E1C4A5B"))
        XCTAssertEqual(lsid.count, 8 + 1 + 11)

        let body = WebDeviceID.exClimbWuzhiBody()
        let outer = try? JSON(data: body ?? Data())
        let inner = try? JSON(string: outer?["payload"].stringValue ?? "")
        XCTAssertEqual(inner?["3064"].intValue, 1)
        XCTAssertEqual(inner?["39c8"].stringValue, "333.1387.fp.risk")
        XCTAssertEqual(inner?[path: "3c43.bfe9"].stringValue.count, 50)
    }
}
