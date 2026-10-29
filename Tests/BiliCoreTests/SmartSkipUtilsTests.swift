// SmartSkip port tests (BiliSmartSkip by wzy403, GPL-2.0): JS-semantics layer, utils.js and
// time parsing. Upstream cases from test-branch 24d28a8 (`regression`, spec §14.1, §15).

import XCTest
@testable import BiliCore

final class SmartSkipRegexTests: XCTestCase {
    func testTranslationRules() {
        XCTAssertEqual(SmartSkipRegex.translate(#"\d{1,2}"#), "[0-9]{1,2}")
        XCTAssertEqual(SmartSkipRegex.translate(#"(?:^|\D)"#), "(?:^|[^0-9])")
        XCTAssertEqual(SmartSkipRegex.translate("a$"), #"a\z"#)
        XCTAssertEqual(SmartSkipRegex.translate("a.b"), #"a[^\n\r  ]b"#)
        XCTAssertEqual(SmartSkipRegex.translate("[.$]"), #"[.\$]"#, "inside a class . and $ are literal")
        XCTAssertEqual(SmartSkipRegex.translate(#"[:;]"#), #"[\:;]"#)
        XCTAssertEqual(SmartSkipRegex.translate(#"\(\)"#), #"\(\)"#)
    }

    func testDigitsAreASCIIOnly() {
        XCTAssertTrue(SmartSkipRegex(#"^\d+$"#).test("05"))
        XCTAssertFalse(SmartSkipRegex(#"^\d+$"#).test("０５"), "full-width digits are not \\d in JS")
        XCTAssertFalse(SmartSkipRegex(#"^\d+$"#).test("٣"), "Arabic-Indic digits are not \\d in JS")
        XCTAssertTrue(SmartSkipRegex(#"^\D$"#).test("５"))
    }

    func testDollarIsEndOfInput() {
        XCTAssertFalse(SmartSkipRegex("x$").test("x\n"))
        XCTAssertTrue(SmartSkipRegex("x$").test("x"))
    }

    func testWordBoundaryIsASCII() {
        XCTAssertTrue(SmartSkipRegex(#"\bad\b"#).test("广告ad"), "JS: boundary between 告 and a")
        XCTAssertFalse(SmartSkipRegex(#"\bad\b"#).test("download"))
        XCTAssertFalse(SmartSkipRegex(#"\bsponsor\b"#).test("sponsors"))
        XCTAssertTrue(SmartSkipRegex(#"\Bow"#).test("download"))
    }

    func testWhitespaceIsTheJSSet() {
        XCTAssertTrue(SmartSkipRegex(#"^\s$"#).test("\u{FEFF}"))
        XCTAssertTrue(SmartSkipRegex(#"^\s$"#).test("\u{3000}"))
        XCTAssertFalse(SmartSkipRegex(#"^\s$"#).test("\u{85}"), "NEL is not JS whitespace")
        XCTAssertTrue(SmartSkipRegex(#"^[\s-]$"#).test("-"))
        XCTAssertTrue(SmartSkipRegex(#"^\S$"#).test("a"))
    }

    func testDotExcludesOnlyJSLineTerminators() {
        XCTAssertFalse(SmartSkipRegex("^.$").test("\u{2028}"))
        XCTAssertFalse(SmartSkipRegex("^.$").test("\n"))
        XCTAssertTrue(SmartSkipRegex("^.$").test("\u{85}"))
    }

    func testQuantifiersCountUTF16CodeUnits() {
        XCTAssertTrue(SmartSkipRegex("^.{2}$").test("😀"), "an astral character is two code units in JS")
        XCTAssertFalse(SmartSkipRegex("^.$").test("😀"))
        XCTAssertFalse(SmartSkipRegex("^a.{0,1}b$").test("a😀b"))
        let m = SmartSkipRegex("a.{0,4}b").match("x a😀😀b y")
        XCTAssertEqual(m?[0], "a😀😀b", "match text maps back to the original string")
        XCTAssertEqual(m?.index, 2)
    }

    func testGroupsAndGlobalHelpers() {
        let m = SmartSkipRegex("(a)|(b)").match("b")
        XCTAssertNil(m?[1], "a non-participating group is undefined")
        XCTAssertEqual(m?[2], "b")
        XCTAssertEqual(SmartSkipRegex("广告|赞助").matchAll("广告赞助广告"), ["广告", "赞助", "广告"])
        XCTAssertEqual(SmartSkipRegex("[。！]").split("a。b！"), ["a", "b", ""])
        XCTAssertEqual(SmartSkipRegex("[。！]").split(""), [""])
        XCTAssertEqual(SmartSkipRegex(#"\s+"#).replaceAll(" a \u{3000}b\n😀 c", with: ""), "ab😀c")
        XCTAssertEqual(SmartSkipRegex(#"(\d):(\d\d)"#).execAll("1:23 4:56").map { $0[0] }, ["1:23", "4:56"])
    }

    func testCaseInsensitiveFlag() {
        XCTAssertTrue(SmartSkipRegex("sponsoredby", ignoreCase: true).test("SponsoredBy"))
        XCTAssertFalse(SmartSkipRegex("sponsoredby").test("SponsoredBy"))
    }

    /// V8's `i` flag (no `u`) never folds a non-ASCII character onto an ASCII letter; ICU's
    /// case-insensitive mode does (ſ U+017F ~ s, K U+212A ~ k), also inside the `\b` emulation.
    /// Expected values checked with node 22.
    func testCaseInsensitiveFlagIsASCIIOnlyLikeV8() {
        XCTAssertFalse(SmartSkipRegex("^ads$", ignoreCase: true).test("adſ"))
        XCTAssertFalse(SmartSkipRegex("^k$", ignoreCase: true).test("\u{212A}"))
        XCTAssertFalse(SmartSkipRegex("^sponsoredby$", ignoreCase: true).test("ſponsoredby"))
        XCTAssertTrue(SmartSkipRegex("^ads$", ignoreCase: true).test("ADS"))
        XCTAssertTrue(SmartSkipRegex(#"free\b"#, ignoreCase: true).test("FREEſ"), "ſ is not a JS word character")
        XCTAssertTrue(SmartSkipRegex("[a-c]x", ignoreCase: true).test("BX"))
        XCTAssertTrue(SmartSkipRegex(#"^A\x42$"#, ignoreCase: true).test("ab"), "escaped letters fold, their hex digits do not")
        XCTAssertEqual(SmartSkipRegex.translate(#"\u00a0\x41"#, ignoreCase: true), #"\u00a0[Aa]"#)
        XCTAssertEqual(SmartSkipRegex.translate("a[b-dX]", ignoreCase: true), "[aA][b-dB-DXx]")
        // Upstream getAdLabelEvidence: "ad free" followed by ſ is negated by the ad-free rule.
        XCTAssertNil(SmartSkipDetectors.getAdLabelEvidence("ad freeſponsor|~sponsor"))
    }
}

final class SmartSkipJSSemanticsTests: XCTestCase {
    func testTrimUsesTheJSWhitespaceSet() {
        XCTAssertEqual(SmartSkipJS.trim("\u{FEFF} a b \u{3000}\n"), "a b")
        XCTAssertEqual(SmartSkipJS.trim("\u{85}a"), "\u{85}a")
        XCTAssertEqual(SmartSkipJS.trim("   "), "")
    }

    func testIndexOfSliceAndIncludesAreUTF16() {
        XCTAssertEqual(SmartSkipJS.indexOf("11:205 空降1:20", "1:20"), 1, "FIRST occurrence, inside 11:205")
        XCTAssertEqual(SmartSkipJS.indexOf("abc", "x"), -1)
        XCTAssertEqual(SmartSkipJS.indexOf("😀x", "x"), 2)
        XCTAssertEqual(SmartSkipJS.slice("abcdef", 0, -1), "abcde")
        XCTAssertEqual(SmartSkipJS.slice("abcdef", 2), "cdef")
        XCTAssertEqual(SmartSkipJS.slice("abc", 5), "")
        XCTAssertEqual(SmartSkipJS.length("😀a"), 3)
        XCTAssertTrue(SmartSkipJS.includes("跳过广告", "广告"))
        XCTAssertFalse(SmartSkipJS.includes("e\u{301}", "\u{E9}"), "code-unit exact, no canonical equivalence")
    }

    func testNumberCoercion() {
        XCTAssertEqual(SmartSkipJS.number(.null), 0)
        XCTAssertEqual(SmartSkipJS.number(.string("")), 0)
        XCTAssertEqual(SmartSkipJS.number(.string("102")), 102)
        XCTAssertEqual(SmartSkipJS.number(.string("1e3")), 1000)
        XCTAssertEqual(SmartSkipJS.number(.string(" 7 ")), 7)
        XCTAssertTrue(SmartSkipJS.number(.string("7x")).isNaN)
        XCTAssertEqual(SmartSkipJS.number(.string("0x1A")), 26)
        XCTAssertEqual(SmartSkipJS.number(.bool(true)), 1)
        XCTAssertTrue(SmartSkipJS.number(.object([:])).isNaN)
        XCTAssertTrue(SmartSkipJS.isSafeInteger(9_007_199_254_740_991))
        XCTAssertFalse(SmartSkipJS.isSafeInteger(9_007_199_254_740_992))
        XCTAssertFalse(SmartSkipJS.isSafeInteger(1.5))
    }

    func testParseFloat() {
        XCTAssertEqual(SmartSkipJS.parseFloat("12.5abc"), 12.5)
        XCTAssertEqual(SmartSkipJS.parseFloat("  3,1,25"), 3)
        XCTAssertEqual(SmartSkipJS.parseFloat("-1.5e2x"), -150)
        XCTAssertEqual(SmartSkipJS.parseFloat("1e"), 1)
        XCTAssertEqual(SmartSkipJS.parseFloat(".5"), 0.5)
        XCTAssertEqual(SmartSkipJS.parseFloat("Infinity"), .infinity)
        XCTAssertTrue(SmartSkipJS.parseFloat("").isNaN)
        XCTAssertTrue(SmartSkipJS.parseFloat("abc").isNaN)
    }

    func testMathRoundAndTruthiness() {
        XCTAssertEqual(SmartSkipJS.round(2.5), 3)
        XCTAssertEqual(SmartSkipJS.round(-2.5), -2)
        XCTAssertEqual(SmartSkipJS.round(0.49999999999999994), 0)
        XCTAssertFalse(SmartSkipJS.truthy(0))
        XCTAssertFalse(SmartSkipJS.truthy(Double.nan))
        XCTAssertFalse(SmartSkipJS.truthy(nil))
        XCTAssertTrue(SmartSkipJS.truthy(-1))
        XCTAssertEqual(SmartSkipJS.or(0, 5), 5)
        XCTAssertEqual(SmartSkipJS.or(.nan, 5), 5)
        XCTAssertEqual(SmartSkipJS.or(-2, 5), -2)
    }

    func testStableSortAndOrderedUnique() {
        let items = [(1, "a"), (0, "b"), (1, "c"), (0, "d"), (1, "e")]
        XCTAssertEqual(SmartSkipJS.stableSorted(items) { Double($0.0 - $1.0) }.map(\.1), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(SmartSkipJS.stableSorted(Array(repeating: 0, count: 50).indices.map { $0 }) { _, _ in 0 },
                       Array(0..<50), "equal keys keep input order")
        XCTAssertEqual(SmartSkipJS.unique(["b", "a", "b", "c", "a"]), ["b", "a", "c"])
        XCTAssertEqual(SmartSkipJS.numberString(79), "79")
        XCTAssertEqual(SmartSkipJS.numberString(39.751), "39.751")
        XCTAssertFalse(SmartSkipJS.numberString(1e20).isEmpty, "huge integral values must not trap in Int64(_:)")
        XCTAssertFalse(AdSegment(start: 1e19, end: 2e19, requiresConfirmation: true, source: "chapters").id.isEmpty)
    }
}

final class SmartSkipTimeParsingTests: XCTestCase {
    private func time(_ text: String) -> Double? { SmartSkipUtils.extractTimeFromText(text)?.time }

    func testFormatTime() {
        XCTAssertEqual(SmartSkipUtils.formatTime(125), "2:05")
        XCTAssertEqual(SmartSkipUtils.formatTime(59.9), "0:59")
        XCTAssertEqual(SmartSkipUtils.formatTime(600), "10:00")
    }

    func testZhNumToInt() {
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("05"), 5)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("零五"), 5)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("十"), 10)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("十五"), 15)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("二十"), 20)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("二十五"), 25)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("五"), 5)
        XCTAssertEqual(SmartSkipUtils.zhNumToInt("零"), 0)
        XCTAssertTrue(SmartSkipUtils.zhNumToInt("５").isNaN, "undefined → NaN")
        XCTAssertTrue(SmartSkipUtils.zhNumToInt("百").isNaN)
    }

    /// regression: 真实弹幕回归：中文零补位保留个位秒数
    func testChineseZeroPaddingKeepsSingleSeconds() {
        XCTAssertEqual(time("我是三分零五郎"), 185)
        XCTAssertEqual(time("感谢八分零五郎"), 485)
        XCTAssertEqual(time("在下八分零三郎"), 483)
    }

    /// regression: 时刻解析支持两位分钟且不从超长工程数字截取后缀
    func testTwoDigitMinutesAndLongEngineeringCodes() {
        let parsed = SmartSkipUtils.extractTimeFromText("空降10分20秒")
        XCTAssertEqual(parsed?.time, 620)
        XCTAssertEqual(parsed?.reference, "10分20秒")
        XCTAssertNil(SmartSkipUtils.extractTimeFromText("11105工程"))
    }

    func testClockFormat() {
        XCTAssertEqual(time("5:30"), 330)
        XCTAssertEqual(time("02：36"), 156)
        XCTAssertEqual(time("2;00"), 120)
        XCTAssertEqual(time("2；00"), 120)
        XCTAssertNil(time("2:99"))
        XCTAssertNil(time("123:45"))
        XCTAssertNil(time("1:234"))
        XCTAssertEqual(SmartSkipUtils.extractTimeFromText("跳过广告到03:10")?.reference, "03:10")
    }

    func testClockMatchWithInvalidSecondsDoesNotFallThrough() {
        XCTAssertNil(time("2:99 或者 3分10秒"), "format 1 matched with seconds ≥ 60 → null, format 2 not tried")
        XCTAssertNil(time("3分70秒 705工程"), "format 2 matched with seconds ≥ 60 → null, format 3 not tried")
    }

    func testChineseFormat() {
        XCTAssertEqual(time("五分三十秒"), 330)
        XCTAssertEqual(time("5分30秒"), 330)
        XCTAssertEqual(time("二分十秒"), 130)
        XCTAssertEqual(time("2分0秒"), 120)
        XCTAssertEqual(time("十分三十秒"), 630)
        XCTAssertEqual(time("1分20"), 80)
        XCTAssertEqual(time("三分零五郎"), 185)
        XCTAssertNil(time("5分钟"))
        XCTAssertNil(time("5分"))
        XCTAssertNil(time("十分好看"))
    }

    func testEngineeringCodes() {
        XCTAssertEqual(time("705工程"), 425)
        XCTAssertEqual(time("0705工程"), 425)
        XCTAssertEqual(time("200工程"), 120)
        XCTAssertEqual(time("0200工程"), 120)
        XCTAssertEqual(time("120工程"), 80)
        XCTAssertEqual(SmartSkipUtils.extractTimeFromText("705工程")?.reference, "705工程")
        XCTAssertNil(time("790工程"), "seconds 90 ≥ 60")
    }

    func testUnsupportedFormatsLikeMaster() {
        XCTAssertNil(time("10.5分钟"), "advertised by the README but unsupported on master")
        XCTAssertNil(time("空降５：００"), "full-width digits do not parse in JS")
        XCTAssertNil(time("没有时间"))
    }

    /// regression: 区间验证：有限数值、10/180 秒以及片尾 20 秒边界
    func testCheckAdSegVaildTable() {
        let cases: [(Double, Double, Bool)] = [
            (60, 70, true), (60, 69.99, false), (59.99, 80, false),
            (60, 239.99, true), (60, 240, false),
            (450, 579.99, true), (450, 580, false),
            (.nan, 120, false), (79, .nan, false),
            (.infinity, 120, false), (79, .infinity, false),
        ]
        for (start, end, expected) in cases {
            XCTAssertEqual(SmartSkipDetectors.checkAdSegVaild(SmartSkipSegment(start: start, end: end), 600), expected, "\(start)~\(end)")
        }
    }

    func testCheckAdSegVaildEarlyAdAndUnknownDuration() {
        XCTAssertFalse(SmartSkipDetectors.checkAdSegVaild(nil, 600))
        XCTAssertFalse(SmartSkipDetectors.checkAdSegVaild(SmartSkipSegment(start: 39, end: 92), 291))
        XCTAssertTrue(SmartSkipDetectors.checkAdSegVaild(SmartSkipSegment(start: 39, end: 92), 291, true))
        XCTAssertFalse(SmartSkipDetectors.checkAdSegVaild(SmartSkipSegment(start: -1, end: 20), 291, true))
        XCTAssertTrue(SmartSkipDetectors.checkAdSegVaild(SmartSkipSegment(start: 900, end: 990), 0), "duration 0 = unknown → no end guard")
    }
}
