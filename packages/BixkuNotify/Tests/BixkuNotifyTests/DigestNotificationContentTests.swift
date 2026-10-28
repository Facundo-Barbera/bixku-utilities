import BixkuDock
import Foundation
import XCTest
@testable import BixkuNotify

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func triaged(
    _ app: String, _ title: String, action: NotificationAction, at offset: TimeInterval
) -> TriagedNotification {
    TriagedNotification(
        notification: IncomingNotification(
            appBundleID: nil, appName: app, title: title, timestamp: t0.addingTimeInterval(offset)
        ),
        category: .chat,
        decision: TriageDecision(action: action, reason: "test"),
        modeID: "writing",
        triagedAt: t0.addingTimeInterval(offset)
    )
}

private func digest(_ items: [TriagedNotification], dropped: Int = 0, modeName: String = "Writing") -> NotificationDigest? {
    DigestBuilder().build(
        items, modeID: "writing", modeName: modeName, start: t0, end: t0.addingTimeInterval(2_700), droppedCount: dropped
    )
}

final class DigestNotificationContentTests: XCTestCase {
    func testNothingToReportGivesNoContent() {
        XCTAssertNil(digest([]))
    }

    func testSummarizesHeldAndGroupedNotifications() throws {
        let built = try XCTUnwrap(digest([
            triaged("Messages", "Mum", action: .hold, at: 1),
            triaged("Slack", "standup", action: .summarize, at: 2),
            triaged("Slack", "lunch?", action: .summarize, at: 3),
            triaged("News", "Headlines", action: .summarize, at: 4),
        ]))
        let content = try XCTUnwrap(DigestNotificationContent(digest: built))
        XCTAssertEqual(content.title, "4 notifications while in Writing")
        XCTAssertEqual(content.body, "Held: Messages\nSlack ×2: lunch?\nNews ×1: Headlines")
        XCTAssertEqual(content.threadIdentifier, "online.bixku.dock.digest.writing")
        XCTAssertEqual(content.identifier, "online.bixku.dock.digest.writing.\(Int(t0.timeIntervalSince1970) + 2_700)")
    }

    func testSingularTitleAndDroppedCount() throws {
        let built = try XCTUnwrap(digest([triaged("Slack", "hi", action: .summarize, at: 1)], dropped: 5))
        let content = try XCTUnwrap(DigestNotificationContent(digest: built))
        XCTAssertEqual(content.title, "6 notifications while in Writing")
        XCTAssertTrue(content.body.hasSuffix("5 more were dropped (queue full)"))

        let single = try XCTUnwrap(digest([triaged("Slack", "hi", action: .summarize, at: 1)]))
        XCTAssertEqual(DigestNotificationContent(digest: single)?.title, "1 notification while in Writing")
    }

    func testListsAreBounded() throws {
        let items = (1...10).map { triaged("App\($0)", "t\($0)", action: .summarize, at: TimeInterval($0)) }
            + (1...10).map { triaged("Held\($0)", "h\($0)", action: .hold, at: TimeInterval(20 + $0)) }
        let content = try XCTUnwrap(DigestNotificationContent(digest: try XCTUnwrap(digest(items))))
        XCTAssertTrue(content.body.contains("Held: Held1, Held2, Held3, Held4 and 6 more"))
        XCTAssertTrue(content.body.contains("and 7 more apps"))
        XCTAssertLessThanOrEqual(content.body.count, DigestNotificationContent.maxBodyLength)
        XCTAssertLessThanOrEqual(content.body.split(separator: "\n").count, 6)
    }

    func testUntrustedTextIsSanitizedAndBounded() throws {
        let nasty = "\u{202E}evil\u{1B}[31m" + String(repeating: "x", count: 500)
        let built = try XCTUnwrap(digest([triaged("Slack", nasty, action: .summarize, at: 1)], modeName: "Wri\u{200B}ting\n"))
        let content = try XCTUnwrap(DigestNotificationContent(digest: built))
        XCTAssertEqual(content.title, "1 notification while in Writing")
        XCTAssertFalse(content.body.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{1B}" })
        XCTAssertLessThanOrEqual(content.body.count, DigestNotificationContent.maxBodyLength)
    }
}

final class NotifyTextSanitizerTests: XCTestCase {
    func testKeepsEmojiSequencesAndNonLatinText() {
        let text = "👨‍👩‍👧 日本語 café"
        XCTAssertEqual(NotifyTextSanitizer.clean(text, maxLength: 100), text)
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(NotifyTextSanitizer.clean("  a \t\u{00A0} b  \n c ", maxLength: 100), "a b c")
        XCTAssertEqual(NotifyTextSanitizer.clean("a\n \nb", maxLength: 100, allowNewlines: true), "a\n\nb")
    }

    func testTruncationNeverExceedsLimit() {
        let cleaned = NotifyTextSanitizer.clean(String(repeating: "ab ", count: 100), maxLength: 10)
        XCTAssertLessThanOrEqual(cleaned.count, 10)
        XCTAssertGreaterThanOrEqual(cleaned.count, 9) // a trailing space before … is trimmed
        XCTAssertTrue(cleaned.hasSuffix("…"))
        XCTAssertEqual(NotifyTextSanitizer.clean("abc", maxLength: 0), "")
    }

    func testIsBlank() {
        XCTAssertTrue(NotifyTextSanitizer.isBlank(" \u{200B}\n"))
        XCTAssertFalse(NotifyTextSanitizer.isBlank("x"))
    }
}
