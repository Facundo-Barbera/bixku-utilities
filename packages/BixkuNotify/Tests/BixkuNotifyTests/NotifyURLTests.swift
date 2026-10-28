import BixkuDock
import Foundation
import XCTest
@testable import BixkuNotify

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func parse(_ string: String, limits: NotifyLimits = .standard) -> Result<IncomingNotification, NotifyURLError> {
    guard let url = URL(string: string) else { return .failure(.malformed) }
    return NotifyURL.parse(url, now: now, limits: limits)
}

final class NotifyURLTests: XCTestCase {
    func testParsesAllFields() throws {
        let result = try parse(
            "bixku://notify?app=Slack&title=Build%20failed&subtitle=CI&body=line1%0Aline2&category=build&thread=ci-1"
        ).get()
        XCTAssertNil(result.appBundleID)
        XCTAssertEqual(result.appName, "Slack")
        XCTAssertEqual(result.title, "Build failed")
        XCTAssertEqual(result.subtitle, "CI")
        XCTAssertEqual(result.body, "line1\nline2")
        XCTAssertEqual(result.category, .build)
        XCTAssertEqual(result.threadID, "ci-1")
        XCTAssertEqual(result.timestamp, now)
        XCTAssertFalse(result.isTimeSensitive)
    }

    func testTitleOnlyIsEnough() throws {
        let result = try parse("bixku://notify?title=Hi").get()
        XCTAssertEqual(result.title, "Hi")
        XCTAssertNil(result.appName)
        XCTAssertNil(result.body)
        XCTAssertNil(result.category)
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        XCTAssertEqual(try parse("BIXKU://Notify/?title=Hi").get().title, "Hi")
    }

    func testRejectsOtherSchemesAndActions() {
        XCTAssertEqual(parse("https://notify?title=Hi"), .failure(.wrongScheme))
        XCTAssertEqual(parse("bixku://settings?title=Hi"), .failure(.unknownAction))
        XCTAssertEqual(parse("bixku://notify/extra?title=Hi"), .failure(.malformed))
        XCTAssertEqual(parse("bixku://user@notify?title=Hi"), .failure(.malformed))
        XCTAssertEqual(parse("bixku://notify:80?title=Hi"), .failure(.malformed))
        XCTAssertEqual(parse("bixku://notify?title=Hi#frag"), .failure(.malformed))
    }

    func testMissingOrBlankTitleIsRejected() {
        XCTAssertEqual(parse("bixku://notify?body=x"), .failure(.missingTitle))
        XCTAssertEqual(parse("bixku://notify?title="), .failure(.missingTitle))
        XCTAssertEqual(parse("bixku://notify?title=%20%0A%E2%80%8B"), .failure(.missingTitle))
    }

    func testInvalidPercentEncodingIsRejected() {
        XCTAssertEqual(parse("bixku://notify?title=%FF%FE"), .failure(.malformed))
        XCTAssertEqual(parse("bixku://notify?title=ok&body=%E0%A4"), .failure(.malformed))
    }

    func testPlusIsLiteral() throws {
        XCTAssertEqual(try parse("bixku://notify?title=a+b").get().title, "a+b")
    }

    func testFirstDuplicateWinsAndUnknownParametersAreIgnored() throws {
        let result = try parse("bixku://notify?title=one&title=two&evil=1&TITLE=three").get()
        XCTAssertEqual(result.title, "one")
    }

    func testUnknownCategoryIsDroppedNotRejected() throws {
        XCTAssertNil(try parse("bixku://notify?title=Hi&category=urgent-now").get().category)
        XCTAssertEqual(try parse("bixku://notify?title=Hi&category=Direct-Message").get().category, .directMessage)
    }

    func testSenderCannotClaimBundleIDOrUrgency() throws {
        let result = try parse(
            "bixku://notify?title=Hi&app=com.apple.MobileSMS&appBundleID=com.apple.MobileSMS&isTimeSensitive=true&urgent=1"
        ).get()
        XCTAssertNil(result.appBundleID)
        XCTAssertFalse(result.isTimeSensitive)
        XCTAssertEqual(result.appName, "com.apple.MobileSMS") // display text only
    }

    func testLimitsAreEnforced() throws {
        let long = String(repeating: "a", count: 1_000)
        let body = String(repeating: "b", count: 2_500)
        let result = try parse("bixku://notify?title=\(long)&body=\(body)&app=\(long)&thread=\(long)&subtitle=\(long)").get()
        XCTAssertEqual(result.title.count, NotifyLimits.standard.maxTitleLength)
        XCTAssertTrue(result.title.hasSuffix("…"))
        XCTAssertEqual(result.body?.count, NotifyLimits.standard.maxBodyLength)
        XCTAssertEqual(result.appName?.count, NotifyLimits.standard.maxAppLength)
        XCTAssertEqual(result.threadID?.count, NotifyLimits.standard.maxThreadLength)
        XCTAssertEqual(result.subtitle?.count, NotifyLimits.standard.maxSubtitleLength)
    }

    func testOversizedURLIsRejectedBeforeParsing() {
        let huge = String(repeating: "a", count: NotifyLimits.standard.maxURLLength)
        XCTAssertEqual(parse("bixku://notify?title=\(huge)"), .failure(.tooLong))
    }

    func testTooManyParameters() {
        let query = (0...NotifyLimits.standard.maxParameters).map { "p\($0)=x" }.joined(separator: "&")
        XCTAssertEqual(parse("bixku://notify?title=Hi&\(query)"), .failure(.tooManyParameters))
    }

    func testControlAndBidiCharactersAreStripped() throws {
        // ESC, NUL, RLO (U+202E), zero-width space, BOM
        let result = try parse("bixku://notify?title=a%1B%00b%E2%80%AEc%E2%80%8Bd%EF%BB%BFe&body=x%07y").get()
        XCTAssertEqual(result.title, "abcde")
        XCTAssertEqual(result.body, "xy")
    }

    func testTitleIsSingleLineAndBodyKeepsBoundedBreaks() throws {
        let result = try parse("bixku://notify?title=a%0Ab%0D%0Ac&body=a%0A%0A%0A%0Ab%0D%0Ac").get()
        XCTAssertEqual(result.title, "a b c")
        XCTAssertEqual(result.body, "a\n\nb\nc")
    }

    func testInjectionLikeContentIsKeptAsPlainText() throws {
        let payload = "%3Cscript%3Ealert(1)%3C%2Fscript%3E%20%24(rm%20-rf%20~)%20%60id%60"
        let result = try parse("bixku://notify?title=\(payload)").get()
        XCTAssertEqual(result.title, "<script>alert(1)</script> $(rm -rf ~) `id`")
    }

    // MARK: - Builder

    func testMakeRoundTripsAwkwardText() throws {
        let url = try XCTUnwrap(NotifyURL.make(
            title: "50% done & 100 ünïcode 🎉",
            body: "a=b&c=d\nnext line + plus",
            subtitle: "sub?",
            app: "My App",
            category: .directMessage,
            thread: "t/1"
        ))
        XCTAssertTrue(url.absoluteString.hasPrefix("bixku://notify?title="))
        let result = try NotifyURL.parse(url, now: now).get()
        XCTAssertEqual(result.title, "50% done & 100 ünïcode 🎉")
        XCTAssertEqual(result.body, "a=b&c=d\nnext line + plus")
        XCTAssertEqual(result.subtitle, "sub?")
        XCTAssertEqual(result.appName, "My App")
        XCTAssertEqual(result.category, .directMessage)
        XCTAssertEqual(result.threadID, "t/1")
    }

    // MARK: - Rate limiter

    func testRateLimiterSlidesWithTheWindow() {
        var limiter = NotifyRateLimiter(maxEvents: 3, window: 10)
        XCTAssertTrue(limiter.allow(at: now))
        XCTAssertTrue(limiter.allow(at: now.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allow(at: now.addingTimeInterval(2)))
        XCTAssertFalse(limiter.allow(at: now.addingTimeInterval(3)))
        XCTAssertFalse(limiter.allow(at: now.addingTimeInterval(9)))
        // The first event leaves the window at +10; rejected events were not counted.
        XCTAssertTrue(limiter.allow(at: now.addingTimeInterval(10)))
        XCTAssertFalse(limiter.allow(at: now.addingTimeInterval(10.5)))
        XCTAssertTrue(limiter.allow(at: now.addingTimeInterval(12)))
    }
}
