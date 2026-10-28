import Foundation
import XCTest
@testable import BixkuUtilities

final class PlaceholderAgentTests: XCTestCase {
    private func latest(_ agent: PlaceholderAgent, after action: () async throws -> Void) async throws -> [AgentProposal] {
        var iterator = agent.proposals.makeAsyncIterator()
        _ = await iterator.next() // initial snapshot
        try await action()
        return await iterator.next() ?? []
    }

    private func next(_ iterator: inout AsyncStream<[AgentProposal]>.Iterator) async throws -> [AgentProposal] {
        let snapshot = await iterator.next()
        return try XCTUnwrap(snapshot)
    }

    func testNewSubscriptionYieldsCurrentList() async throws {
        let agent = PlaceholderAgent()
        try await agent.instruct("focus mode for writing")

        var iterator = agent.proposals.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.count, 1)
        XCTAssertEqual(snapshot?.first?.status, .pending)
    }

    func testInstructCreatesPendingProposalWithDiff() async throws {
        let agent = PlaceholderAgent()
        let proposals = try await latest(agent) { try await agent.instruct("  Deep work, no chat!  ") }

        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(proposal.instruction, "Deep work, no chat!")
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.first?.kind, .create)
        XCTAssertEqual(proposal.changes.first?.targetID, "deep-work-no")
        XCTAssertTrue(proposal.diffLines.allSatisfy { $0.kind == .added })
    }

    func testEmptyInstructionIsRejected() async {
        let agent = PlaceholderAgent()
        do {
            try await agent.instruct("   \n ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyInstruction)
        }
    }

    func testApproveThenRevert() async throws {
        let agent = PlaceholderAgent()
        try await agent.instruct("writing")
        var iterator = agent.proposals.makeAsyncIterator()
        let first = try await next(&iterator).first
        let id = try XCTUnwrap(first?.id)

        try await agent.approve(id)
        var snapshot = try await next(&iterator)
        XCTAssertEqual(snapshot.first?.status, .approved)
        XCTAssertNotNil(snapshot.first?.decidedAt)

        try await agent.revert(id)
        snapshot = try await next(&iterator)
        XCTAssertEqual(snapshot.first?.status, .reverted)
    }

    func testRejectIsFinal() async throws {
        let agent = PlaceholderAgent()
        try await agent.instruct("writing")
        var iterator = agent.proposals.makeAsyncIterator()
        let first = try await next(&iterator).first
        let id = try XCTUnwrap(first?.id)

        try await agent.reject(id)
        for action in [agent.approve, agent.reject, agent.revert] {
            do {
                try await action(id)
                XCTFail("expected an error")
            } catch let AgentError.invalidTransition(_, status) {
                XCTAssertEqual(status, .rejected)
            }
        }
    }

    func testRevertRequiresApproval() async throws {
        let agent = PlaceholderAgent()
        try await agent.instruct("writing")
        var iterator = agent.proposals.makeAsyncIterator()
        let first = try await next(&iterator).first
        let id = try XCTUnwrap(first?.id)

        do {
            try await agent.revert(id)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidTransition(action: "revert", status: .pending))
        }
    }

    func testUnknownProposal() async {
        let agent = PlaceholderAgent()
        let id = UUID()
        do {
            try await agent.approve(id)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .unknownProposal(id))
        }
    }

    func testSlug() {
        XCTAssertEqual(PlaceholderAgent.slug(from: "Hold ALL notifications, please"), "hold-all-notifications")
        XCTAssertEqual(PlaceholderAgent.slug(from: "!!!"), "new-mode")
    }
}
