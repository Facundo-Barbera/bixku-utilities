import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

final class ModeModelTests: XCTestCase {
    func testFactoryModesDecodeAndValidate() throws {
        let modes = DefaultModes.all
        XCTAssertEqual(modes.map(\.id), [.writing, .building, .reading, .meeting, .break, .free])
        let ids = Set(modes.map(\.id))
        for mode in modes {
            XCTAssertEqual(ModeValidator().issues(in: mode, knownModes: ids), [], "\(mode.id)")
            XCTAssertEqual(mode.schemaVersion, ModeDefinition.currentSchemaVersion)
        }
        XCTAssertNotNil(DefaultModes.definition(DefaultModes.fallbackModeID))
    }

    func testRoundTripPreservesEverything() throws {
        for mode in DefaultModes.all {
            let data = try JSONModeStore.encode(mode)
            let decoded = try JSONDecoder().decode(ModeDefinition.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testEncodesDescriptionKeyAndDefaultKey() throws {
        let data = try JSONModeStore.encode(DefaultModes.definition(.writing)!)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["description"])
        XCTAssertNil(object["summary"])
        let notifications = try XCTUnwrap(object["notifications"] as? [String: Any])
        XCTAssertEqual(notifications["default"] as? String, "hold")
    }

    func testMinimalDocumentGetsDefaults() throws {
        let (mode, version) = try ModeMigrator().decode(json(#"{"schemaVersion":1,"id":"deep-work","name":"Deep work"}"#))
        XCTAssertEqual(version, 1)
        XCTAssertEqual(mode.id, "deep-work")
        XCTAssertEqual(mode.symbol, "circle")
        XCTAssertEqual(mode.notifications, NotificationPolicy())
        XCTAssertEqual(mode.notifications.defaultAction, .allow)
        XCTAssertTrue(mode.notifications.urgent.honorTimeSensitive)
        XCTAssertEqual(mode.transitions, [])
        // Missing description is a validation (not decoding) problem.
        XCTAssertEqual(ModeValidator().issues(in: mode).map(\.path), ["description"])
    }

    func testDecodingErrorsHaveReadablePaths() {
        let document = #"""
        {"schemaVersion":1,"id":"x","name":"X","description":"d",
         "transitions":[{"trigger":"activity","match":{"categories":["coding"]},"forSeconds":10}]}
        """#
        XCTAssertThrowsError(try ModeMigrator().decode(json(document))) { error in
            guard case ModeDocumentError.decoding(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("transitions[0].match.categories[0]"), message)
        }
        XCTAssertThrowsError(try ModeMigrator().decode(json(#"{"schemaVersion":1,"id":"x"}"#))) { error in
            XCTAssertEqual(error as? ModeDocumentError, .decoding("name: required field is missing"))
        }
    }

    // MARK: Validation

    func testValidatorReportsEveryProblem() {
        var mode = makeMode("ok")
        mode.id = "Bad ID"
        mode.name = " "
        mode.summary = ""
        mode.dock = DockLayout(prioritized: ["com.example.App", "com.bad.*"], hidden: ["com.example.*", "a*b"])
        mode.attention = AttentionRules(
            focus: ActivityMatcher(apps: ["com.example.Editor"], categories: [.code], urlHosts: ["https://x.com"]),
            distractions: ActivityMatcher(apps: ["COM.EXAMPLE.EDITOR"], categories: [.code])
        )
        mode.notifications.rules = [NotificationRule(match: NotificationMatcher(), action: .hold)]
        mode.transitions = [
            ModeRule(trigger: .activity, forSeconds: 0),
            ModeRule(trigger: .idle, match: ActivityMatcher(categories: [.other]), forSeconds: 100_000),
            ModeRule(trigger: .activity, match: ActivityMatcher(categories: [.code]), forSeconds: 10, from: ["Bad ID", "nope", "free"]),
        ]
        let issues = ModeValidator().issues(in: mode, knownModes: ["free", "writing"])
        let paths = issues.map(\.path)
        XCTAssertTrue(paths.contains("id"))
        XCTAssertTrue(paths.contains("name"))
        XCTAssertTrue(paths.contains("description"))
        XCTAssertTrue(paths.contains("dock.prioritized[1]"))
        XCTAssertTrue(paths.contains("dock.hidden[1]"))
        XCTAssertTrue(issues.contains { $0.path == "dock" && $0.message.contains("com.example.App") })
        XCTAssertTrue(paths.contains("attention.focus.urlHosts[0]"))
        XCTAssertEqual(issues.filter { $0.path == "attention" }.count, 2)
        XCTAssertTrue(paths.contains("notifications.rules[0].match"))
        XCTAssertTrue(paths.contains("transitions[0].forSeconds"))
        XCTAssertTrue(paths.contains("transitions[0].match"))
        XCTAssertTrue(paths.contains("transitions[1].forSeconds"))
        XCTAssertTrue(paths.contains("transitions[1].match"))
        XCTAssertTrue(paths.contains("transitions[2].from[0]"))
        XCTAssertTrue(issues.contains { $0.path == "transitions[2].from[1]" && $0.message == "unknown mode 'nope'" })
        XCTAssertFalse(paths.contains("transitions[2].from[2]"))

        XCTAssertThrowsError(try ModeValidator().validate(mode)) { error in
            let error = error as? ModeValidationError
            XCTAssertEqual(error?.modeID, "Bad ID")
            XCTAssertTrue(error?.description.contains("transitions[0].forSeconds: must be greater than 0") == true)
        }
    }

    func testValidatorRejectsSelfTransitionAndWrongSchema() {
        var mode = makeMode("loop", transitions: [ModeRule(trigger: .idle, forSeconds: 60, from: ["loop"])])
        mode.schemaVersion = 7
        let paths = ModeValidator().issues(in: mode).map(\.path)
        XCTAssertEqual(paths, ["schemaVersion", "transitions[0].from[0]"])
    }

    func testModeIDValidation() {
        XCTAssertTrue(ModeID("deep-work-2").isValid)
        for bad in ["", "Deep", "deep--work", "-deep", "deep work", "deep_work", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ModeID(rawValue: bad).isValid, bad)
        }
    }

    // MARK: Migration

    func testMissingSchemaVersionIsTreatedAsVersionOne() throws {
        let result = try ModeMigrator().migrate(json(#"{"id":"legacy","name":"Legacy"}"#))
        XCTAssertEqual(result.originalVersion, 1)
        XCTAssertEqual(result.object["schemaVersion"] as? Int, 1)
    }

    func testRejectsNewerAndMalformedVersions() {
        let migrator = ModeMigrator()
        XCTAssertThrowsError(try migrator.migrate(json(#"{"schemaVersion":2,"id":"x"}"#))) {
            XCTAssertEqual($0 as? ModeDocumentError, .unsupportedSchemaVersion(found: 2, supported: 1))
        }
        for bad in ["true", "\"1\"", "1.5", "0", "-1"] {
            XCTAssertThrowsError(try migrator.migrate(json(#"{"schemaVersion":\#(bad)}"#)), bad) {
                guard case ModeDocumentError.invalidSchemaVersion = $0 else { return XCTFail("\(bad): \($0)") }
            }
        }
        XCTAssertThrowsError(try migrator.migrate(json("[1,2]"))) {
            XCTAssertEqual($0 as? ModeDocumentError, .notAnObject)
        }
        XCTAssertThrowsError(try migrator.migrate(json("{nope"))) {
            guard case ModeDocumentError.invalidJSON = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAppliesMigrationChainInOrder() throws {
        let migrator = ModeMigrator(currentVersion: 3, migrations: [
            ModeMigration(fromVersion: 1) { object in
                object["name"] = object.removeValue(forKey: "title")
            },
            ModeMigration(fromVersion: 2) { object in
                let name = object["name"] as? String ?? ""
                object["name"] = name.uppercased()
            },
        ])
        let fromOne = try migrator.migrate(json(#"{"schemaVersion":1,"title":"Focus"}"#))
        XCTAssertEqual(fromOne.originalVersion, 1)
        XCTAssertTrue(fromOne.wasMigrated)
        XCTAssertEqual(fromOne.object["name"] as? String, "FOCUS")
        XCTAssertNil(fromOne.object["title"])
        XCTAssertEqual(fromOne.object["schemaVersion"] as? Int, 3)

        let fromTwo = try migrator.migrate(json(#"{"schemaVersion":2,"name":"focus"}"#))
        XCTAssertEqual(fromTwo.object["name"] as? String, "FOCUS")

        let current = try migrator.migrate(json(#"{"schemaVersion":3,"name":"focus"}"#))
        XCTAssertFalse(current.wasMigrated)
        XCTAssertEqual(current.object["name"] as? String, "focus")
    }

    func testMissingMigrationStep() {
        let migrator = ModeMigrator(currentVersion: 3, migrations: [ModeMigration(fromVersion: 1) { _ in }])
        XCTAssertThrowsError(try migrator.migrate(json(#"{"schemaVersion":1}"#))) {
            XCTAssertEqual($0 as? ModeDocumentError, .missingMigration(from: 2))
        }
    }

    // MARK: Matching

    func testAppPatterns() {
        XCTAssertTrue(AppPattern.matches("com.jetbrains.*", bundleID: "com.jetbrains.intellij"))
        XCTAssertFalse(AppPattern.matches("com.jetbrains.*", bundleID: "com.jetbrainsx.app"))
        XCTAssertTrue(AppPattern.matches("COM.apple.Terminal", bundleID: "com.apple.terminal"))
        XCTAssertTrue(AppPattern.matches("*", bundleID: "anything"))
        XCTAssertFalse(AppPattern.matches("*", bundleID: nil))
        XCTAssertNil(AppPattern.problem(with: "com.example.*"))
        XCTAssertNotNil(AppPattern.problem(with: "com.*.x"))
        XCTAssertNotNil(AppPattern.problem(with: ".*"))
        XCTAssertTrue(HostPattern.matches("github.com", host: "gist.github.com"))
        XCTAssertFalse(HostPattern.matches("github.com", host: "notgithub.com"))
    }

    func testAttentionLevels() {
        let rules = AttentionRules(
            focus: ActivityMatcher(apps: ["com.example.Editor"], categories: [.writing]),
            distractions: ActivityMatcher(categories: [.media], urlHosts: ["video.example"])
        )
        XCTAssertEqual(rules.level(for: sample("com.example.Editor", at: 0), category: .media), .focus)
        XCTAssertEqual(rules.level(for: sample("com.example.Other", at: 0), category: .writing), .focus)
        XCTAssertEqual(rules.level(for: sample("com.example.Other", at: 0), category: .media), .distraction)
        // A specific distraction (host) beats a category focus.
        let browsingVideo = sample("com.example.Browser", url: "https://www.video.example/watch", at: 0)
        XCTAssertEqual(rules.level(for: browsingVideo, category: .writing), .distraction)
        XCTAssertEqual(rules.level(for: sample("com.example.Other", at: 0), category: .code), .neutral)
    }

    func testDockArrangement() {
        let layout = DockLayout(prioritized: ["com.b", "com.missing", "com.a"], hidden: ["com.hidden.*"])
        XCTAssertEqual(
            layout.arrange(["com.a", "com.hidden.x", "com.c", "com.b"]),
            ["com.b", "com.a", "com.c"]
        )
    }

    func testRuleSummary() {
        XCTAssertEqual(DefaultModes.definition(.building)!.transitions[0].summary, "code for 5m")
        XCTAssertEqual(DefaultModes.definition(.break)!.transitions[0].summary, "idle for 10m")
        XCTAssertEqual(DurationFormat.short(5_400), "1h 30m")
        XCTAssertEqual(DurationFormat.short(90), "1m 30s")
    }
}
