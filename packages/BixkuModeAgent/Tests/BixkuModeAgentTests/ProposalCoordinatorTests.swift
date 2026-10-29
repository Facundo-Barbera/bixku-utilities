import BixkuCore
import BixkuDock
import XCTest
@testable import BixkuModeAgent

final class ProposalCoordinatorTests: XCTestCase {
    func testCreateWaitsForApprovalThenApplies() async throws {
        let h = Harness()
        let events = h.bus.subscribe(.namespace("agent"))
        let proposal = try await h.coordinator.submit(.create(makeMode("research")), justification: "asked", untrusted: false)
        XCTAssertEqual(proposal.status, .pending)
        let before = try await h.store.load()
        XCTAssertFalse(before.contains("research"))

        let applied = try await h.coordinator.approve(proposal.id)
        XCTAssertEqual(applied.status, .applied)
        let after = try await h.store.load()
        XCTAssertEqual(after.mode("research")?.provenance, .user)
        let history = try await h.coordinator.history.all()
        XCTAssertEqual(history.map(\.version), [1])

        var names: [EventName] = []
        for await event in events {
            names.append(event.name)
            if names.count == 2 { break }
        }
        XCTAssertEqual(names, [.agentProposal, .agentApplied])
        await XCTAssertThrowsAsync(try await h.coordinator.approve(proposal.id))
    }

    func testRejectLeavesCatalogUntouched() async throws {
        let h = Harness()
        let proposal = try await h.coordinator.submit(.create(makeMode("research")), justification: "", untrusted: false)
        let rejected = try await h.coordinator.reject(proposal.id)
        XCTAssertEqual(rejected.status, .rejected)
        let catalog = try await h.store.load()
        XCTAssertFalse(catalog.contains("research"))
        let pending = await h.coordinator.pendingProposals
        XCTAssertTrue(pending.isEmpty)
    }

    func testInvalidProposalsAreRefused() async throws {
        let h = Harness()
        var bad = makeMode("bad")
        bad.name = ""
        await XCTAssertThrowsAsync(try await h.coordinator.submit(.create(bad), justification: "", untrusted: false)) { error in
            guard case ModeAgentError.invalidMode = error else { return XCTFail("\(error)") }
        }
        await XCTAssertThrowsAsync(try await h.coordinator.submit(.create(DefaultModes.definition(.writing)!), justification: "", untrusted: false))
        await XCTAssertThrowsAsync(try await h.coordinator.submit(.delete(DefaultModes.definition(.writing)!), justification: "", untrusted: false)) { error in
            XCTAssertEqual(error as? ModeAgentError, .cannotDeleteBuiltInMode(.writing))
        }
        await XCTAssertThrowsAsync(try await h.coordinator.submit(.activate(from: nil, to: "nope"), justification: "", untrusted: false))
        let writing = DefaultModes.definition(.writing)!
        await XCTAssertThrowsAsync(try await h.coordinator.submit(.update(before: writing, after: writing), justification: "", untrusted: false)) { error in
            XCTAssertEqual(error as? ModeAgentError, .noChanges(.writing))
        }
        let all = await h.coordinator.allProposals
        XCTAssertTrue(all.isEmpty)
    }

    func testStaleProposalFails() async throws {
        let h = Harness()
        let writing = DefaultModes.definition(.writing)!
        var a = writing
        a.name = "A"
        var b = writing
        b.name = "B"
        let first = try await h.coordinator.submit(.update(before: writing, after: a), justification: "", untrusted: false)
        let second = try await h.coordinator.submit(.update(before: writing, after: b), justification: "", untrusted: false)
        try await h.coordinator.approve(first.id)
        await XCTAssertThrowsAsync(try await h.coordinator.approve(second.id)) { error in
            XCTAssertEqual(error as? ModeAgentError, .stale(.writing))
        }
        let status = await h.coordinator.proposal(second.id)?.status
        XCTAssertEqual(status, .failed)
    }

    func testRevertRestoresEachKindOfChange() async throws {
        let h = Harness(policy: ApprovalPolicy(mode: .autoApproveLowRisk))
        let writing = DefaultModes.definition(.writing)!

        // Update of a built-in mode (auto-approved, low risk) → revert drops the override.
        var renamed = writing
        renamed.name = "Deep writing"
        let update = try await h.coordinator.submit(.update(before: writing, after: renamed), justification: "", untrusted: false)
        XCTAssertEqual(update.status, .applied)
        var catalog = try await h.store.load()
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .userOverride)
        let revert1 = try await h.coordinator.revert(1)
        XCTAssertEqual(revert1.revertsVersion, 1)
        catalog = try await h.store.load()
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .factory)
        XCTAssertEqual(catalog.definition(.writing), writing)

        // Reverting the revert re-applies the override.
        try await h.coordinator.revert(revert1.version)
        catalog = try await h.store.load()
        XCTAssertEqual(catalog.definition(.writing)?.name, "Deep writing")

        // Delete of the override → revert brings it back.
        let delete = try await h.coordinator.submit(.delete(catalog.definition(.writing)!), justification: "", untrusted: false)
        XCTAssertEqual(delete.status, .pending)
        try await h.coordinator.approve(delete.id)
        catalog = try await h.store.load()
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .factory)
        let deleteVersion = try await h.coordinator.history.all().last!.version
        try await h.coordinator.revert(deleteVersion)
        catalog = try await h.store.load()
        XCTAssertEqual(catalog.definition(.writing)?.name, "Deep writing")

        // Create → revert deletes.
        let create = try await h.coordinator.submit(.create(makeMode("research")), justification: "", untrusted: false)
        try await h.coordinator.approve(create.id)
        let createVersion = try await h.coordinator.history.all().last!.version
        try await h.coordinator.revert(createVersion)
        catalog = try await h.store.load()
        XCTAssertFalse(catalog.contains("research"))

        // A version whose result was changed since is stale.
        await XCTAssertThrowsAsync(try await h.coordinator.revert(createVersion)) { error in
            XCTAssertEqual(error as? ModeAgentError, .stale("research"))
        }
        await XCTAssertThrowsAsync(try await h.coordinator.revert(999)) { error in
            XCTAssertEqual(error as? ModeAgentError, .unknownHistoryVersion(999))
        }
    }

    func testRevertProposalById() async throws {
        let h = Harness()
        let proposal = try await h.coordinator.submit(.create(makeMode("research")), justification: "", untrusted: false)
        await XCTAssertThrowsAsync(try await h.coordinator.revertProposal(proposal.id))
        try await h.coordinator.approve(proposal.id)
        let reverted = try await h.coordinator.revertProposal(proposal.id)
        XCTAssertEqual(reverted.status, .reverted)
        let catalog = try await h.store.load()
        XCTAssertFalse(catalog.contains("research"))
        await XCTAssertThrowsAsync(try await h.coordinator.revertProposal(proposal.id))
    }

    func testHistoryPersistsAcrossInstances() async throws {
        let storage = InMemoryModuleStorage()
        let first = ModeHistory(storage: storage)
        try await first.record(modeID: "a", before: nil, beforeProvenance: nil, after: makeMode("a"), proposalID: nil, summary: "one", at: t0)
        try await first.record(modeID: "a", before: makeMode("a"), beforeProvenance: .user, after: nil, proposalID: nil, summary: "two", at: t0)
        let second = ModeHistory(storage: storage)
        let entries = try await second.all()
        XCTAssertEqual(entries.map(\.summary), ["one", "two"])
        let next = try await second.record(modeID: "a", before: nil, beforeProvenance: nil, after: nil, proposalID: nil, summary: "three", at: t0)
        XCTAssertEqual(next.version, 3)

        let bounded = ModeHistory(limit: 2)
        for index in 0..<3 {
            try await bounded.record(modeID: "a", before: nil, beforeProvenance: nil, after: nil, proposalID: nil, summary: "\(index)", at: t0)
        }
        let kept = try await bounded.all()
        XCTAssertEqual(kept.map(\.version), [2, 3])
    }
}

func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
