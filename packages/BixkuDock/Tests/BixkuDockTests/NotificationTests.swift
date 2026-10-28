import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

final class NotificationCategorizerTests: XCTestCase {
    let categorizer = NotificationCategorizer()

    func testCategories() {
        XCTAssertEqual(categorizer.category(for: notification("com.apple.mail")), .email)
        XCTAssertEqual(categorizer.category(for: notification("com.apple.iCal", title: "Standup in 5 minutes")), .calendar)
        XCTAssertEqual(categorizer.category(for: notification("com.apple.MobileSMS")), .directMessage)
        XCTAssertEqual(categorizer.category(for: notification("com.tinyspeck.slackmacgap")), .chat)
        XCTAssertEqual(categorizer.category(for: notification("com.tinyspeck.slackmacgap", title: "Alex mentioned you in #general")), .mention)
        XCTAssertEqual(categorizer.category(for: notification("com.tinyspeck.slackmacgap", body: "Build failed on main")), .build)
        XCTAssertEqual(categorizer.category(for: notification("com.apple.Safari", body: "30% off today only")), .promotion)
        XCTAssertEqual(categorizer.category(for: notification("com.apple.systempreferences")), .system)
        XCTAssertEqual(categorizer.category(for: notification("com.example.Unknown")), .other)
        // The source's category wins.
        XCTAssertEqual(categorizer.category(for: notification("com.apple.mail", category: .social)), .social)
    }
}

final class NotificationTriageTests: XCTestCase {
    let writing = DefaultModes.definition(.writing)!
    let building = DefaultModes.definition(.building)!

    private func activity(_ bundleID: String, _ category: ActivityCategory) -> ClassifiedActivity {
        ClassifiedActivity(sample: sample(bundleID, at: 0), verdict: ActivityVerdict(category: category, confidence: 0.9, rationale: ""))
    }

    func testDefaultModesPolicy() async {
        let triage = NotificationTriage(clock: ManualClock(now: t0))
        let editor = activity("md.obsidian", .writing)

        let calendar = await triage.triage(notification("com.apple.iCal"), mode: writing, activity: editor)
        XCTAssertEqual(calendar.decision.action, .allow)
        XCTAssertEqual(calendar.decision.reason, "always allowed in Writing")

        let chat = await triage.triage(notification("com.tinyspeck.slackmacgap"), mode: writing, activity: editor)
        XCTAssertEqual(chat.decision.action, .summarize)
        XCTAssertEqual(chat.category, .chat)
        XCTAssertEqual(chat.modeID, .writing)
        XCTAssertEqual(chat.triagedAt, t0)

        let promo = await triage.triage(notification("com.example.Shop", body: "Newsletter: 20% off"), mode: writing, activity: editor)
        XCTAssertEqual(promo.decision.action, .silence)

        let dm = await triage.triage(notification("com.apple.MobileSMS"), mode: writing, activity: editor)
        XCTAssertEqual(dm.decision.action, .hold)
        XCTAssertEqual(dm.decision.reason, "Writing default: hold")

        let ci = await triage.triage(notification("com.example.CI", title: "Build failed"), mode: building, activity: nil)
        XCTAssertEqual(ci.decision.action, .allow)
        XCTAssertEqual(ci.decision.reason, "Build and CI results are part of the work")
    }

    func testUrgencyBreaksThrough() async {
        let triage = NotificationTriage()
        let keyword = await triage.triage(notification("com.apple.MobileSMS", body: "URGENT: call me"), mode: writing, activity: nil)
        XCTAssertEqual(keyword.decision.action, .allow)
        XCTAssertTrue(keyword.decision.isUrgent)
        XCTAssertEqual(keyword.decision.reason, "urgent: contains urgent keyword 'urgent'")

        let flagged = await triage.triage(notification("com.example.Pager", timeSensitive: true), mode: writing, activity: nil)
        XCTAssertTrue(flagged.decision.isUrgent)

        var ignoreFlag = writing
        ignoreFlag.notifications.urgent.honorTimeSensitive = false
        let ignored = await triage.triage(notification("com.example.Pager", timeSensitive: true), mode: ignoreFlag, activity: nil)
        XCTAssertEqual(ignored.decision.action, .hold)
    }

    func testFocusedAppShortcut() async {
        let triage = NotificationTriage()
        let inSlack = activity("com.tinyspeck.slackmacgap", .communication)
        let fromSlack = await triage.triage(notification("com.tinyspeck.slackmacgap"), mode: writing, activity: inSlack)
        XCTAssertEqual(fromSlack.decision.action, .allow)
        XCTAssertEqual(fromSlack.decision.reason, "from the app you are using")
        // The meeting mode disables the shortcut (no pop-ups over a shared screen).
        let meeting = DefaultModes.definition(.meeting)!
        let inZoom = activity("us.zoom.xos", .meeting)
        let fromZoom = await triage.triage(notification("us.zoom.xos"), mode: meeting, activity: inZoom)
        XCTAssertEqual(fromZoom.decision.action, .hold)
    }

    func testRulesRespectWhileActivity() async {
        let mode = makeMode("custom", policy: NotificationPolicy(
            defaultAction: .allow,
            rules: [
                NotificationRule(match: NotificationMatcher(categories: [.email]), action: .silence, whileActivity: ActivityMatcher(categories: [.meeting])),
                NotificationRule(match: NotificationMatcher(apps: ["com.apple.mail"]), action: .hold),
            ]
        ))
        let triage = NotificationTriage()
        let duringMeeting = await triage.triage(notification("com.apple.mail"), mode: mode, activity: activity("us.zoom.xos", .meeting))
        XCTAssertEqual(duringMeeting.decision.action, .silence)
        let otherwise = await triage.triage(notification("com.apple.mail"), mode: mode, activity: activity("md.obsidian", .writing))
        XCTAssertEqual(otherwise.decision.action, .hold)
        XCTAssertEqual(otherwise.decision.reason, "Custom rule 2: email → hold")
        let noActivity = await triage.triage(notification("com.apple.mail"), mode: mode, activity: nil)
        XCTAssertEqual(noActivity.decision.action, .hold)
    }

    func testLLMOnlyDecidesWhenRulesFallToTheDefault() async {
        let llm = MockLLM(notification: { notification, _, mode, _ in
            TriageDecision(action: .silence, reason: "\(notification.title) is noise in \(mode.id)")
        })
        let triage = NotificationTriage(llm: llm, clock: ManualClock(now: t0))
        let ruled = await triage.triage(notification("com.tinyspeck.slackmacgap"), mode: writing, activity: nil)
        XCTAssertEqual(ruled.decision.source, .rules)
        XCTAssertEqual(llm.notificationCalls, 0)

        let decided = await triage.triage(notification("com.example.App", title: "Weekly stats"), mode: writing, activity: nil)
        XCTAssertEqual(decided.decision.action, .silence)
        XCTAssertEqual(decided.decision.source, .llm)
        XCTAssertEqual(decided.decision.reason, "Weekly stats is noise in writing")

        let cached = await triage.triage(notification("com.example.App", title: "Weekly stats"), mode: writing, activity: nil)
        XCTAssertEqual(cached.decision.source, .cache)
        XCTAssertEqual(llm.notificationCalls, 1)
    }

    func testLLMFailureKeepsTheDefault() async {
        let clock = ManualClock(now: t0)
        let triage = NotificationTriage(llm: MockLLM.hanging, policy: LLMUsagePolicy(timeout: .seconds(2)), clock: clock)
        let task = Task { await triage.triage(notification("com.example.App"), mode: writing, activity: nil) }
        await eventually { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(2))
        let result = await task.value
        XCTAssertEqual(result.decision.action, .hold)
        XCTAssertEqual(result.decision.source, .fallback)
        XCTAssertTrue(result.decision.reason.hasPrefix("Writing default: hold (LLM timed out"), result.decision.reason)

        let failing = NotificationTriage(llm: MockLLM.failing())
        let failed = await failing.triage(notification("com.example.App"), mode: writing, activity: nil)
        XCTAssertEqual(failed.decision.action, .hold)
        XCTAssertEqual(failed.decision.source, .fallback)
    }
}

final class DigestTests: XCTestCase {
    private func triaged(_ n: IncomingNotification, _ action: NotificationAction, _ category: NotificationCategory) -> TriagedNotification {
        TriagedNotification(notification: n, category: category, decision: TriageDecision(action: action, reason: "test"), modeID: .writing, triagedAt: n.timestamp)
    }

    func testBuildsGroupedDigest() {
        let items = [
            triaged(notification("com.tinyspeck.slackmacgap", title: "a", thread: "t1", at: 10), .summarize, .chat),
            triaged(notification("com.apple.MobileSMS", title: "Sam", at: 20), .hold, .directMessage),
            triaged(notification("com.tinyspeck.slackmacgap", title: "b", thread: "t2", at: 30), .summarize, .mention),
            triaged(notification("com.example.News", title: "n", at: 40), .summarize, .other),
            triaged(notification("com.tinyspeck.slackmacgap", title: "c", thread: "t1", at: 50), .summarize, .chat),
            triaged(notification("com.example.Ignored", at: 60), .allow, .other),
            triaged(notification("com.example.Dropped", at: 70), .silence, .other),
        ]
        let digest = DigestBuilder(maxHeadlines: 2).build(
            items.reversed(), modeID: .writing, modeName: "Writing", start: t0, end: t0.addingTimeInterval(2_700)
        )!
        XCTAssertEqual(digest.held.map(\.notification.title), ["Sam"])
        XCTAssertEqual(digest.groups.map(\.appName), ["slackmacgap", "News"])
        let slack = digest.groups[0]
        XCTAssertEqual(slack.count, 3)
        XCTAssertEqual(slack.categories, [CategoryCount(category: .chat, count: 2), CategoryCount(category: .mention, count: 1)])
        XCTAssertEqual(slack.headlines, ["c", "b"])
        XCTAssertEqual(slack.threadCount, 2)
        XCTAssertEqual(digest.totalCount, 5)
        XCTAssertEqual(
            digest.summary,
            "While in Writing (45m): 5 notifications. 1 held: MobileSMS. Summarized: slackmacgap ×3 (2 chat, 1 mention), News ×1."
        )
    }

    func testEmptyDigestIsNil() {
        let allowed = [triaged(notification("com.example.App"), .allow, .other)]
        XCTAssertNil(DigestBuilder().build(allowed, modeID: .writing, modeName: "Writing", start: t0, end: t0))
    }

    func testDroppedCountIsReported() {
        let digest = DigestBuilder().build([], modeID: .free, modeName: "Free", start: t0, end: t0.addingTimeInterval(60), droppedCount: 4)
        XCTAssertEqual(digest?.summary, "While in Free (1m): 4 notifications. 4 more were dropped because the queue was full.")
    }

    func testHeldQueueIsBounded() {
        var queue = HeldQueue(capacity: 2)
        XCTAssertTrue(queue.isEmpty)
        for index in 0..<3 {
            queue.append(triaged(notification("com.example.App", title: "\(index)"), .hold, .other))
        }
        XCTAssertEqual(queue.items.map(\.notification.title), ["1", "2"])
        XCTAssertEqual(queue.droppedCount, 1)
        let drained = queue.drain()
        XCTAssertEqual(drained.items.count, 2)
        XCTAssertEqual(drained.dropped, 1)
        XCTAssertTrue(queue.isEmpty)
    }
}
