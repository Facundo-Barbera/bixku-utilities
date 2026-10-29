import BixkuDock
import XCTest
@testable import BixkuModeAgent

final class ApprovalPolicyTests: XCTestCase {
    let writing = DefaultModes.definition(.writing)!
    let auto = ApprovalPolicy(mode: .autoApproveLowRisk)

    private func proposal(_ action: ProposedAction, untrusted: Bool = false) -> ModeChangeProposal {
        ModeChangeProposal(action: action, justification: "", changes: [], influencedByUntrustedData: untrusted, createdAt: t0)
    }

    func testDefaultPolicyAlwaysAsks() {
        var renamed = writing
        renamed.name = "Deep writing"
        XCTAssertEqual(ApprovalPolicy.default.decide(proposal(.update(before: writing, after: renamed))), .requireConfirmation)
        XCTAssertEqual(ApprovalPolicy.default.decide(proposal(.activate(from: nil, to: .building))), .requireConfirmation)
    }

    func testCosmeticAndAdditiveChangesAreLowRisk() {
        var after = writing
        after.name = "Deep writing"
        after.symbol = "pencil"
        after.attention.focus.apps.append("com.example.editor")
        after.notifications.urgent.keywords.append("pager")
        XCTAssertEqual(auto.assess(.update(before: writing, after: after)).risk, .low)
        XCTAssertEqual(auto.decide(proposal(.update(before: writing, after: after))), .autoApprove)
        XCTAssertEqual(auto.decide(proposal(.activate(from: .writing, to: .building))), .autoApprove)
    }

    func testBehaviorChangesNeedConfirmation() {
        var after = writing
        after.transitions = []
        let (risk, reasons) = auto.assess(.update(before: writing, after: after))
        XCTAssertEqual(risk, .medium)
        XCTAssertTrue(reasons.contains { $0.contains("transitions") })
        XCTAssertEqual(auto.decide(proposal(.update(before: writing, after: after))), .requireConfirmation)
    }

    func testDeletingIsNeverAutoApproved() {
        let mode = makeMode("custom")
        XCTAssertEqual(auto.assess(.delete(mode)).risk, .high)
        XCTAssertEqual(auto.decide(proposal(.delete(mode))), .requireConfirmation)
    }

    func testSuppressingCriticalCategoryIsHighRisk() {
        var after = writing
        after.notifications.alwaysAllow.categories = []
        let (risk, reasons) = auto.assess(.update(before: writing, after: after))
        XCTAssertEqual(risk, .high)
        XCTAssertTrue(reasons.contains { $0.contains("calendar") }, "\(reasons)")

        let free = makeMode("open")
        var silencing = free
        silencing.notifications.rules = [NotificationRule(match: NotificationMatcher(categories: [.directMessage]), action: .silence)]
        let assessment = auto.assess(.update(before: free, after: silencing))
        XCTAssertEqual(assessment.risk, .high)
        XCTAssertTrue(assessment.reasons.contains { $0.contains("direct-message") })
        XCTAssertTrue(assessment.reasons.contains { $0.contains("silences") })
    }

    func testWeakeningUrgencyIsHighRisk() {
        var after = writing
        after.notifications.urgent.keywords.removeAll { $0 == "outage" }
        XCTAssertEqual(auto.assess(.update(before: writing, after: after)).risk, .high)
        after = writing
        after.notifications.urgent.honorTimeSensitive = false
        XCTAssertEqual(auto.assess(.update(before: writing, after: after)).risk, .high)
    }

    func testUntrustedRunsAreNeverAutoApproved() {
        var after = writing
        after.name = "Renamed"
        XCTAssertEqual(auto.decide(proposal(.update(before: writing, after: after), untrusted: true)), .requireConfirmation)
    }

    func testCreatingAModeIsNotLowRisk() {
        XCTAssertEqual(auto.assess(.create(makeMode("open"))).risk, .medium)
        XCTAssertEqual(auto.assess(.create(makeMode("quiet", defaultAction: .hold))).risk, .high)
    }

    func testDiffIsReadable() {
        var after = writing
        after.name = "Deep writing"
        after.notifications.rules.removeLast()
        let changes = ModeDiff.changes(from: writing, to: after)
        XCTAssertTrue(changes.contains(ModeFieldChange(path: "name", before: "\"Writing\"", after: "\"Deep writing\"")), "\(changes)")
        XCTAssertTrue(changes.contains { $0.path == "notifications.rules[1].action" && $0.after == nil })
        XCTAssertTrue(ModeDiff.render(changes).contains("~ name: \"Writing\" → \"Deep writing\""))
        XCTAssertEqual(ModeDiff.render([]), "(no changes)")
        XCTAssertTrue(ModeDiff.changes(from: writing, to: writing).isEmpty)
        XCTAssertTrue(ModeDiff.changes(from: nil, to: writing).allSatisfy { $0.before == nil })
        let flags = ModeDiff.flatten(writing)
        XCTAssertEqual(flags["notifications.urgent.honorTimeSensitive"], "true")
    }
}
