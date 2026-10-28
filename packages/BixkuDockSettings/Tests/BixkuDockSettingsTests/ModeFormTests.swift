import BixkuDock
import XCTest
@testable import BixkuDockSettings

final class ModeFormTests: XCTestCase {
    func testEveryFactoryModeRoundTripsThroughTheForm() {
        for definition in DefaultModes.all {
            let result = ModeForm(definition).build(applyingTo: definition, knownModes: Set(DefaultModes.all.map(\.id)))
            XCTAssertEqual(result.definition, definition, "mode \(definition.id)")
            XCTAssertTrue(result.isValid, "mode \(definition.id): \(result.issues)")
        }
    }

    func testEditsApplyAndUnshownFieldsSurvive() throws {
        let base = try XCTUnwrap(DefaultModes.definition(.writing))
        var form = ModeForm(base)
        form.name = "Deep writing"
        form.symbol = " moon "
        form.hidden = ["com.apple.Music"]
        form.defaultAction = .silence
        form.urgentKeywords = ["outage"]

        let result = form.build(applyingTo: base)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertEqual(result.definition.name, "Deep writing")
        XCTAssertEqual(result.definition.symbol, "moon")
        XCTAssertEqual(result.definition.dock.hidden, ["com.apple.Music"])
        XCTAssertEqual(result.definition.notifications.defaultAction, .silence)
        XCTAssertEqual(result.definition.notifications.urgent.keywords, ["outage"])
        // Not editable in the form, so carried over untouched.
        XCTAssertEqual(result.definition.attention, base.attention)
        XCTAssertEqual(result.definition.notifications.rules, base.notifications.rules)
        XCTAssertEqual(result.definition.notifications.alwaysAllow, base.notifications.alwaysAllow)
    }

    func testNonNumericSecondsIsReportedOnceAtTheField() throws {
        let base = ModeDefinition(
            id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.",
            transitions: [ModeRule(trigger: .activity, match: ActivityMatcher(categories: [.code]), forSeconds: 60)]
        )
        var form = ModeForm(base)
        form.transitions[0].secondsText = "five minutes"

        let result = form.build(applyingTo: base)
        XCTAssertFalse(result.isValid)
        let atField = result.issues.filter { $0.path == "transitions[0].forSeconds" }
        XCTAssertEqual(atField.count, 1)
        XCTAssertTrue(atField[0].message.contains("not a number"))
    }

    func testNonIntegerPriorityIsReportedAndEmptyMeansZero() {
        let base = ModeDefinition(
            id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.",
            transitions: [ModeRule(trigger: .idle, forSeconds: 120)]
        )
        var form = ModeForm(base)
        form.transitions[0].priorityText = "high"
        XCTAssertEqual(form.build(applyingTo: base).issues.map(\.path), ["transitions[0].priority"])

        form.transitions[0].priorityText = ""
        let result = form.build(applyingTo: base)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.definition.transitions[0].priority, 0)
    }

    func testIdleTriggerDropsMatchAndActivityTriggerWithoutCriteriaIsInvalid() {
        let base = ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.")
        var form = ModeForm(base)
        form.transitions = [TransitionForm(trigger: .idle, apps: ["com.apple.Terminal"], secondsText: "90")]
        var result = form.build(applyingTo: base)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertNil(result.definition.transitions[0].match)

        form.transitions = [TransitionForm(trigger: .activity, secondsText: "90")]
        result = form.build(applyingTo: base)
        XCTAssertEqual(result.issues.map(\.path), ["transitions[0].match"])
    }

    func testFromListBecomesModeIDsAndEmptyMeansAnyMode() {
        let base = ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.")
        var form = ModeForm(base)
        form.transitions = [TransitionForm(categories: [.code], secondsText: "60", from: ["writing", "reading"])]
        let known: Set<ModeID> = ["focus", "writing", "reading"]
        var result = form.build(applyingTo: base, knownModes: known)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertEqual(result.definition.transitions[0].from, ["writing", "reading"])

        form.transitions[0].from = ["ghost"]
        result = form.build(applyingTo: base, knownModes: known)
        XCTAssertEqual(result.issues.map(\.path), ["transitions[0].from[0]"])

        form.transitions[0].from = []
        XCTAssertNil(form.build(applyingTo: base, knownModes: known).definition.transitions[0].from)
    }

    func testIdAndBlankFieldsAreValidated() {
        let base = ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.")
        var form = ModeForm(base)
        form.id = "Not Valid"
        form.name = "   "
        form.summary = ""
        let paths = Set(form.build(applyingTo: base).issues.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: ["id", "name", "description"]), "\(paths)")
    }

    func testBlankTemplateIsValidAndAvoidsExistingIDs() {
        let first = ModeTemplates.blank(avoiding: [])
        XCTAssertEqual(first.id, "new-mode")
        XCTAssertTrue(ModeValidator().issues(in: first).isEmpty)

        let third = ModeTemplates.blank(avoiding: ["new-mode", "new-mode-2"])
        XCTAssertEqual(third.id, "new-mode-3")
    }

    func testListTextParsing() {
        XCTAssertEqual(ListText.parse("a.b, c.d\n  e.f  \n\n,a.B"), ["a.b", "c.d", "e.f"])
        XCTAssertEqual(ListText.parse("   \n,"), [])
        XCTAssertEqual(ListText.format(["x", "y"]), "x\ny")
        XCTAssertEqual(ListText.parse(ListText.format(["com.apple.*", "md.obsidian"])), ["com.apple.*", "md.obsidian"])
    }
}
