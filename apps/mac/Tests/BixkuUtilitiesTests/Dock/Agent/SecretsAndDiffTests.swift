import Foundation
import XCTest
@testable import BixkuUtilities

final class SecretStoreTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.secret(for: "a"))
        try store.setSecret("one", for: "a")
        try store.setSecret("two", for: "a")
        XCTAssertEqual(try store.secret(for: "a"), "two")
        try store.removeSecret(for: "a")
        XCTAssertNil(try store.secret(for: "a"))
        XCTAssertNoThrow(try store.removeSecret(for: "a"))
    }

    func testEnvironmentVariableWinsOverStoredKey() throws {
        let store = InMemorySecretStore()
        let credentials = AgentCredentials(secrets: store)
        let config = AgentProviderConfig(provider: .anthropic, environmentVariable: "MY_KEY")
        try credentials.store("  stored  ", for: .anthropic)

        XCTAssertEqual(try credentials.apiKey(for: config, environment: [:]), "stored")
        XCTAssertEqual(try credentials.apiKey(for: config, environment: ["MY_KEY": " "]), "stored")
        XCTAssertEqual(try credentials.apiKey(for: config, environment: ["MY_KEY": "from-env\n"]), "from-env")
    }

    func testKeysAreFiledPerProvider() throws {
        let credentials = AgentCredentials(secrets: InMemorySecretStore())
        try credentials.store("k", for: .openai)
        XCTAssertTrue(credentials.hasStoredKey(for: .openai))
        XCTAssertFalse(credentials.hasStoredKey(for: .anthropic))

        try credentials.store("   ", for: .openai) // blank clears
        XCTAssertFalse(credentials.hasStoredKey(for: .openai))
    }

    func testConfigPersistsWithoutSecrets() throws {
        let suite = "bixku.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AgentProviderConfig.load(from: defaults), .default)
        let config = AgentProviderConfig(provider: .openai, model: "some-model", environmentVariable: "SOME_VAR")
        config.save(to: defaults)
        XCTAssertEqual(AgentProviderConfig.load(from: defaults), config)
    }
}

final class ProposalDiffTests: XCTestCase {
    func testModifyShowsOnlyChangedFields() {
        let change = AgentChange(kind: .modify, targetID: "writing", fields: [
            AgentFieldChange(name: "summary", before: "old", after: "new"),
            AgentFieldChange(name: "symbol", before: "pencil", after: "pencil"),
            AgentFieldChange(name: "hint", before: nil, after: "added"),
            AgentFieldChange(name: "legacy", before: "gone", after: nil),
        ])
        XCTAssertEqual(change.diffLines.map(\.rendered), [
            "  mode writing",
            "-   summary: old",
            "+   summary: new",
            "+   hint: added",
            "-   legacy: gone",
        ])
    }

    func testCreateAndRemoveHeaders() {
        XCTAssertEqual(AgentChange(kind: .create, targetID: "x").diffLines.first?.kind, .added)
        XCTAssertEqual(AgentChange(kind: .remove, targetID: "x").diffLines.first?.kind, .removed)
    }

    func testProposalDiffConcatenatesChanges() {
        let proposal = AgentProposal(instruction: "i", summary: "s", changes: [
            AgentChange(kind: .create, targetID: "a"),
            AgentChange(kind: .remove, targetID: "b"),
        ])
        XCTAssertEqual(proposal.diffLines.map(\.rendered), ["+ mode a", "- mode b"])
    }
}
