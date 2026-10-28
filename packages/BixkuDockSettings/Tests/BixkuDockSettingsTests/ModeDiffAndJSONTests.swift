import BixkuDock
import XCTest
@testable import BixkuDockSettings

final class ModeDiffAndJSONTests: XCTestCase {
    private let base = ModeDefinition(
        id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.",
        dock: DockLayout(prioritized: ["com.apple.Terminal"], hidden: ["com.apple.Music"]),
        transitions: [ModeRule(trigger: .activity, match: ActivityMatcher(categories: [.code]), forSeconds: 300)]
    )

    // MARK: Diff

    func testIdenticalDefinitionsHaveNoChanges() {
        XCTAssertTrue(ModeDiff.changes(from: base, to: base).isEmpty)
    }

    func testScalarAndArrayChangesAreReportedByPath() {
        var edited = base
        edited.name = "Deep focus"
        edited.dock.hidden = ["com.apple.Music", "com.spotify.client"]
        edited.notifications.defaultAction = .hold

        let changes = ModeDiff.changes(from: base, to: edited)
        XCTAssertEqual(changes.map(\.path), ["dock.hidden", "name", "notifications.default"])
        XCTAssertTrue(changes.allSatisfy { $0.kind == .modified })

        let name = changes.first { $0.path == "name" }
        XCTAssertEqual(name?.before, "\"Focus\"")
        XCTAssertEqual(name?.after, "\"Deep focus\"")
        XCTAssertEqual(changes.first { $0.path == "dock.hidden" }?.after, "[\"com.apple.Music\",\"com.spotify.client\"]")
    }

    func testNumbersAndBooleansAreComparedNotStringified() {
        var edited = base
        edited.transitions[0].forSeconds = 600
        edited.notifications.allowFromFocusedApp = false
        let changes = ModeDiff.changes(from: base, to: edited)
        XCTAssertEqual(changes.map(\.path), ["notifications.allowFromFocusedApp", "transitions"])
        XCTAssertEqual(changes.first { $0.path == "notifications.allowFromFocusedApp" }?.after, "false")
    }

    func testNilBaselineReportsEverythingAsAdded() {
        let changes = ModeDiff.changes(from: nil, to: base)
        XCTAssertFalse(changes.isEmpty)
        XCTAssertTrue(changes.allSatisfy { $0.kind == .added && $0.before == nil && $0.after != nil })
        XCTAssertTrue(changes.contains { $0.path == "id" })
    }

    func testChangeDescriptionShowsKind() {
        var edited = base
        edited.symbol = "moon"
        let change = ModeDiff.changes(from: base, to: edited)[0]
        XCTAssertEqual(change.description, "~ symbol: \"bolt\" → \"moon\"")
    }

    // MARK: JSON

    func testTextRoundTripsThroughParse() {
        let result = ModeJSON.parse(ModeJSON.text(for: base), knownModes: ["focus"])
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertEqual(result.definition, base)
    }

    func testBrokenJSONIsReportedWithoutADefinition() {
        let result = ModeJSON.parse("{ \"id\": ")
        XCTAssertNil(result.definition)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues[0].path, "(document)")
        XCTAssertFalse(result.isValid)
    }

    func testMissingRequiredFieldIsReported() {
        let result = ModeJSON.parse(#"{ "schemaVersion": 1, "id": "focus" }"#)
        XCTAssertNil(result.definition)
        XCTAssertTrue(result.issues[0].message.contains("name"), "\(result.issues)")
    }

    func testValidationIssuesComeWithTheDecodedDefinition() {
        let text = #"""
        { "schemaVersion": 1, "id": "focus", "name": "Focus", "description": "x",
          "transitions": [ { "trigger": "idle", "forSeconds": 0 } ] }
        """#
        let result = ModeJSON.parse(text)
        XCTAssertNotNil(result.definition)
        XCTAssertEqual(result.issues.map(\.path), ["transitions[0].forSeconds"])
        XCTAssertFalse(result.isValid)
    }

    func testChangingTheIDOfAnExistingModeIsRejected() {
        var renamed = base
        renamed.id = "other"
        let result = ModeJSON.parse(ModeJSON.text(for: renamed), lockedID: "focus")
        XCTAssertEqual(result.issues.first?.path, "id")
        XCTAssertEqual(ModeJSON.parse(ModeJSON.text(for: base), lockedID: "focus").issues, [])
    }

    func testNewerSchemaVersionIsRejected() {
        let result = ModeJSON.parse(#"{ "schemaVersion": 99, "id": "focus", "name": "Focus" }"#)
        XCTAssertNil(result.definition)
        XCTAssertTrue(result.issues[0].message.contains("newer"))
    }
}
