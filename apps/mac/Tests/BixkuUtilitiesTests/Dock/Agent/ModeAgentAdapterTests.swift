import BixkuCore
import BixkuDock
import BixkuLLM
import BixkuModeAgent
import Foundation
import XCTest
@testable import BixkuUtilities

final class ModeAgentAdapterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let store = JSONModeStore(backend: InMemoryModeBackend())
        let engine: DockEngine
        let adapter: ModeAgentAdapter

        init(llm: ScriptedLLM, clock: ManualClock) {
            engine = DockEngine(
                configuration: DockConfiguration(defaultMode: .writing, tickInterval: nil),
                eventBus: EventBus(clock: clock),
                clock: clock
            )
            let access = DockEngineAccess(engine: engine, store: store)
            let coordinator = ProposalCoordinator(store: access, dock: access, clock: clock)
            adapter = ModeAgentAdapter(controller: ModeAgentController(coordinator: coordinator, llm: { LLMClientAgentLLM(client: llm) }, clock: clock))
        }
    }

    private func researchMode() -> ModeDefinition {
        ModeDefinition(id: "research", name: "Research", symbol: "book", summary: "Reading papers", notifications: NotificationPolicy(defaultAction: .allow))
    }

    private func createResearchLLM() throws -> ScriptedLLM {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mode = String(decoding: try encoder.encode(researchMode()), as: UTF8.self)
        return ScriptedLLM(responses: [
            .text(#"{"action":"call_tool","tool":"create_mode","arguments":{"mode":\#(mode),"justification":"You read papers daily"}}"#),
            .text(#"{"action":"finish","message":"Proposed a Research mode."}"#),
        ])
    }

    private func latest(_ adapter: ModeAgentAdapter) async -> [AgentProposal] {
        var iterator = adapter.proposals.makeAsyncIterator()
        return await iterator.next() ?? []
    }

    // MARK: Status and error translation

    func testStatusTranslationKeepsTheFailureMessage() {
        XCTAssertEqual(ProposalStatus(ProposalReviewStatus.pending), .pending)
        XCTAssertEqual(ProposalStatus(ProposalReviewStatus(.applied)), .approved)
        XCTAssertEqual(ProposalStatus(ProposalReviewStatus.rejected), .rejected)
        XCTAssertEqual(ProposalStatus(ProposalReviewStatus.reverted), .reverted)
        XCTAssertEqual(ProposalStatus(ProposalReviewStatus(.failed, failure: "Mode 'x' changed")), .failed("Mode 'x' changed"))
    }

    func testControllerErrorsBecomeTabErrors() {
        let id = UUID()
        XCTAssertEqual(AgentError(.emptyInstruction), .emptyInstruction)
        XCTAssertEqual(AgentError(.notConfigured("No key")), .providerNotConfigured("No key"))
        XCTAssertEqual(AgentError(.unknownProposal(id)), .unknownProposal(id))
        XCTAssertEqual(AgentError(.invalidTransition(action: "revert", status: .failed("x"))), .invalidTransition(action: "revert", status: .failed("x")))
        XCTAssertNil(AgentError(.notRevertible(id)))
    }

    // MARK: Proposal mapping

    func testProposalMapping() {
        let mode = researchMode()
        var proposal = ModeChangeProposal(
            action: .create(mode),
            justification: "  You read papers daily ",
            changes: [ModeFieldChange(path: "name", before: nil, after: "\"Research\"")],
            createdAt: t0
        )
        var mapped = AgentProposal(ReviewedProposal(proposal: proposal, instruction: "add research", status: .pending))
        XCTAssertEqual(mapped.id, proposal.id)
        XCTAssertEqual(mapped.instruction, "add research")
        XCTAssertEqual(mapped.summary, "Create mode 'research'")
        XCTAssertEqual(mapped.detail, "Agent's reason: You read papers daily")
        XCTAssertEqual(mapped.changes, [AgentChange(kind: .create, targetID: "research", fields: [
            AgentFieldChange(name: "name", before: nil, after: "\"Research\""),
        ])])
        XCTAssertEqual(mapped.createdAt, t0)
        XCTAssertEqual(mapped.status, .pending)

        proposal.action = .activate(from: .writing, to: .reading)
        proposal.justification = ""
        proposal.influencedByUntrustedData = true
        mapped = AgentProposal(ReviewedProposal(proposal: proposal, instruction: "i", status: .failed("busy"), decidedAt: t0))
        XCTAssertEqual(mapped.changes.first?.kind, .modify)
        XCTAssertEqual(mapped.changes.first?.targetID, "reading")
        XCTAssertEqual(mapped.detail, "Proposed after reading notifications or window titles; check it carefully.")
        XCTAssertEqual(mapped.status, .failed("busy"))
        XCTAssertEqual(mapped.decidedAt, t0)

        proposal.action = .delete(mode)
        XCTAssertEqual(AgentProposal(ReviewedProposal(proposal: proposal, instruction: "i", status: .pending)).changes.first?.kind, .remove)
        proposal.action = .releaseNotification(id: UUID(), description: "Chat: hi")
        XCTAssertEqual(
            AgentProposal(ReviewedProposal(proposal: proposal, instruction: "i", status: .pending)).changes.first?.fields,
            [AgentFieldChange(name: "deliver now", before: nil, after: "Chat: hi")]
        )
    }

    // MARK: End to end

    func testInstructApproveAndRevertThroughTheEngine() async throws {
        let rig = Rig(llm: try createResearchLLM(), clock: ManualClock(now: t0))
        try await rig.adapter.instruct("Add a mode for reading papers")
        var proposals = await latest(rig.adapter)
        XCTAssertEqual(proposals.map(\.status), [.pending])
        XCTAssertEqual(proposals.first?.summary, "Create mode 'research'")
        let id = try XCTUnwrap(proposals.first?.id)

        try await rig.adapter.approve(id)
        proposals = await latest(rig.adapter)
        XCTAssertEqual(proposals.map(\.status), [.approved])
        var modes = await rig.engine.modes
        XCTAssertTrue(modes.contains("research"))

        try await rig.adapter.revert(id)
        proposals = await latest(rig.adapter)
        XCTAssertEqual(proposals.map(\.status), [.reverted])
        modes = await rig.engine.modes
        XCTAssertFalse(modes.contains("research"))

        do {
            try await rig.adapter.revert(id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidTransition(action: "revert", status: .reverted))
        }
    }

    func testFailedApprovalShowsTheReason() async throws {
        let rig = Rig(llm: try createResearchLLM(), clock: ManualClock(now: t0))
        try await rig.adapter.instruct("Add a mode for reading papers")
        let pending = await latest(rig.adapter)
        let id = try XCTUnwrap(pending.first?.id)
        try await rig.store.save(researchMode())

        do {
            try await rig.adapter.approve(id)
            XCTFail("expected the approval to fail")
        } catch {}
        let status = await latest(rig.adapter).first?.status
        guard case .failed(let message)? = status else { return XCTFail("unexpected \(String(describing: status))") }
        XCTAssertTrue(message.contains("already exists"), message)
    }

    func testEmptyInstruction() async throws {
        let rig = Rig(llm: ScriptedLLM(), clock: ManualClock(now: t0))
        do {
            try await rig.adapter.instruct("  ")
            XCTFail("expected emptyInstruction")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyInstruction)
        }
    }

    // MARK: Provider settings

    func testWithoutAnAPIKeyInstructingFailsClearly() async throws {
        let suite = "bixku.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = ModeAgentAdapter.make(module: DockModule(), secrets: InMemorySecretStore(), defaults: defaults, environment: [:])

        do {
            try await adapter.instruct("Add a research mode")
            XCTFail("expected providerNotConfigured")
        } catch {
            guard case .providerNotConfigured(let message)? = error as? AgentError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(message, "No Anthropic API key is configured. Add one under Provider in the Agent tab or set the ANTHROPIC_API_KEY environment variable.")
            XCTAssertEqual(error.localizedDescription, message)
        }
        let proposals = await latest(adapter)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testSettingsSourceReadsTheTabConfiguration() throws {
        let suite = "bixku.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AgentProviderConfig(provider: .openai, model: "some-model", environmentVariable: "SOME_VAR").save(to: defaults)
        let secrets = InMemorySecretStore()

        let source = AgentSettingsSource(defaults: defaults, credentials: AgentCredentials(secrets: secrets), environment: [:])
        var settings = try source.current()
        XCTAssertEqual(settings.provider, .openAICompatible)
        XCTAssertEqual(settings.displayName, "OpenAI")
        XCTAssertEqual(settings.model, "some-model")
        XCTAssertNil(settings.apiKey)
        XCTAssertEqual(settings.environmentVariable, "SOME_VAR")

        try AgentCredentials(secrets: secrets).store("stored-key", for: .openai)
        settings = try source.current()
        XCTAssertEqual(settings.apiKey, "stored-key")
        XCTAssertNoThrow(try settings.makeLLM())
    }
}
