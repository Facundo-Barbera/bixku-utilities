import BixkuCore
import BixkuDock
import BixkuLLM
import XCTest
@testable import BixkuModeAgent

final class ModeAgentControllerTests: XCTestCase {
    private func controller(_ h: Harness, _ llm: ScriptedLLM, maxSteps: Int = 12) -> ModeAgentController {
        ModeAgentController(coordinator: h.coordinator, llm: { LLMClientAgentLLM(client: llm) }, clock: h.clock, maxSteps: maxSteps)
    }

    private func researchMode() -> ModeDefinition {
        var research = makeMode("research")
        research.summary = "Reading papers"
        return research
    }

    private func createResearch() -> ScriptedLLM {
        scripted([callTool("create_mode", modeArguments(researchMode(), "asked")), finish("Proposed it.")])
    }

    // MARK: Status translation

    func testStatusTranslation() {
        XCTAssertEqual(ProposalReviewStatus(.pending), .pending)
        XCTAssertEqual(ProposalReviewStatus(.applied), .approved)
        XCTAssertEqual(ProposalReviewStatus(.rejected), .rejected)
        XCTAssertEqual(ProposalReviewStatus(.reverted), .reverted)
        XCTAssertEqual(ProposalReviewStatus(.failed, failure: "stale"), .failed("stale"))
        XCTAssertEqual(ProposalReviewStatus(.failed), .failed("The change could not be applied."))

        XCTAssertEqual(ProposalReviewStatus.approved.proposalStatus, .applied)
        XCTAssertEqual(ProposalReviewStatus.failed("x").proposalStatus, .failed)
        for status in [ProposalStatus.pending, .applied, .rejected, .reverted, .failed] {
            XCTAssertEqual(ProposalReviewStatus(status).proposalStatus, status)
        }
    }

    // MARK: Instructions

    func testInstructionBecomesAPendingProposalWithItsInstruction() async throws {
        let h = Harness()
        let llm = createResearch()
        let controller = controller(h, llm)
        var updates = controller.updates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, [])

        let result = try await controller.instruct("  Add a mode for reading papers \n")
        XCTAssertEqual(result.message, "Proposed it.")
        let items = controller.proposals
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.instruction, "Add a mode for reading papers")
        XCTAssertEqual(items.first?.status, .pending)
        XCTAssertNil(items.first?.decidedAt)
        XCTAssertEqual(items.first?.proposal.title, "Create mode 'research'")
        let published = await updates.next()
        XCTAssertEqual(published, items)
    }

    func testEmptyInstructionIsRejectedWithoutCallingTheModel() async {
        let h = Harness()
        let llm = scripted([])
        do {
            try await controller(h, llm).instruct("   ")
            XCTFail("expected emptyInstruction")
        } catch {
            XCTAssertEqual(error as? ModeAgentControllerError, .emptyInstruction)
        }
        XCTAssertEqual(llm.callCount, 0)
    }

    func testMissingAPIKeyFailsWithAClearMessage() async {
        let h = Harness()
        let settings = AgentProviderSettings(
            provider: .anthropic, displayName: "Anthropic", model: "claude-sonnet-5-5", apiKey: nil, environmentVariable: "ANTHROPIC_API_KEY"
        )
        let controller = ModeAgentController(coordinator: h.coordinator, llm: { try settings.makeLLM() }, clock: h.clock)
        do {
            try await controller.instruct("Add a research mode")
            XCTFail("expected notConfigured")
        } catch {
            guard case .notConfigured(let message)? = error as? ModeAgentControllerError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(error.localizedDescription, message)
            XCTAssertTrue(message.contains("No Anthropic API key"), message)
            XCTAssertTrue(message.contains("ANTHROPIC_API_KEY"), message)
        }
        XCTAssertTrue(controller.proposals.isEmpty)
    }

    func testProviderSettingsValidation() throws {
        var settings = AgentProviderSettings(provider: .openAICompatible, displayName: "OpenAI", model: "gpt-4o-mini", apiKey: "  ")
        XCTAssertThrowsError(try settings.makeLLM()) {
            XCTAssertEqual($0 as? ModeAgentControllerError, .notConfigured("No OpenAI API key is configured. Add one under Provider in the Agent tab."))
        }
        settings.apiKey = "test-key"
        settings.model = " "
        XCTAssertThrowsError(try settings.makeLLM()) {
            XCTAssertEqual($0 as? ModeAgentControllerError, .notConfigured("Set the OpenAI model under Provider in the Agent tab."))
        }
        settings.model = "gpt-4o-mini"
        XCTAssertTrue(try settings.makeLLM().client is OpenAICompatibleClient)
        settings.provider = .anthropic
        XCTAssertTrue(try settings.makeLLM().client is AnthropicClient)
        settings.provider = .none
        XCTAssertThrowsError(try settings.makeLLM())
    }

    func testModelFailureIsReportedReadably() async {
        let h = Harness()
        let llm = ScriptedLLM([.fail(LLMError.http(status: 401, message: "invalid x-api-key", retryAfter: nil))])
        do {
            try await controller(h, llm).instruct("Add a research mode")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.hasPrefix("The language model is unavailable"))
        }
    }

    func testProposalsSurviveARunThatFailsLater() async throws {
        let h = Harness()
        let llm = scripted([
            callTool("create_mode", modeArguments(researchMode())),
            callTool("list_modes"),
        ])
        let controller = controller(h, llm, maxSteps: 2)
        do {
            try await controller.instruct("Add a research mode")
            XCTFail("expected tooManySteps")
        } catch {
            XCTAssertEqual(error as? ModeAgentError, .tooManySteps(2))
        }
        XCTAssertEqual(controller.proposals.map(\.status), [.pending])
        XCTAssertEqual(controller.proposals.first?.instruction, "Add a research mode")
    }

    func testAutoApprovedProposalsShowAsApproved() async throws {
        let h = Harness(policy: ApprovalPolicy(mode: .autoApproveLowRisk))
        var edited = DefaultModes.definition(.writing)!
        edited.attention.focus.apps.append("com.example.editor")
        let llm = scripted([callTool("propose_mode_change", modeArguments(edited)), finish()])
        let controller = controller(h, llm)
        try await controller.instruct("My editor counts as writing")
        XCTAssertEqual(controller.proposals.map(\.status), [.approved])
        XCTAssertEqual(controller.proposals.first?.decidedAt, t0)
    }

    // MARK: Decisions

    func testApproveThenRevert() async throws {
        let h = Harness()
        let controller = controller(h, createResearch())
        try await controller.instruct("Add a research mode")
        let id = try XCTUnwrap(controller.proposals.first?.id)

        try await controller.approve(id)
        XCTAssertEqual(controller.proposals.first?.status, .approved)
        XCTAssertEqual(controller.proposals.first?.proposal.status, .applied)
        XCTAssertNotNil(controller.proposals.first?.decidedAt)
        var catalog = try await h.store.load()
        XCTAssertTrue(catalog.contains("research"))

        do {
            try await controller.approve(id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? ModeAgentControllerError, .invalidTransition(action: "approve", status: .approved))
        }

        try await controller.revert(id)
        XCTAssertEqual(controller.proposals.first?.status, .reverted)
        catalog = try await h.store.load()
        XCTAssertFalse(catalog.contains("research"))
    }

    func testReject() async throws {
        let h = Harness()
        let controller = controller(h, createResearch())
        try await controller.instruct("Add a research mode")
        let id = try XCTUnwrap(controller.proposals.first?.id)
        try await controller.reject(id)
        XCTAssertEqual(controller.proposals.first?.status, .rejected)
        let coordinatorStatus = await h.coordinator.proposal(id)?.status
        XCTAssertEqual(coordinatorStatus, .rejected)
        do {
            try await controller.revert(id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? ModeAgentControllerError, .invalidTransition(action: "revert", status: .rejected))
        }
    }

    func testFailedApprovalKeepsTheReason() async throws {
        let h = Harness()
        let controller = controller(h, createResearch())
        try await controller.instruct("Add a research mode")
        let id = try XCTUnwrap(controller.proposals.first?.id)
        // The user creates the same mode by hand before approving.
        try await h.store.save(researchMode())

        do {
            try await controller.approve(id)
            XCTFail("expected the approval to fail")
        } catch {
            XCTAssertEqual(error as? ModeAgentError, .modeAlreadyExists("research"))
        }
        let status = try XCTUnwrap(controller.proposals.first?.status)
        XCTAssertEqual(status, .failed(ModeAgentError.modeAlreadyExists("research").description))
        XCTAssertEqual(controller.proposals.first?.proposal.status, .failed)
    }

    func testModeSwitchesCannotBeReverted() async throws {
        let h = Harness()
        let llm = scripted([callTool("set_active_mode", #"{"id":"reading","justification":"papers"}"#), finish()])
        let controller = controller(h, llm)
        try await controller.instruct("Switch to reading")
        let id = try XCTUnwrap(controller.proposals.first?.id)
        try await controller.approve(id)
        let active = await h.dock.activeMode()
        XCTAssertEqual(active, .reading)
        do {
            try await controller.revert(id)
            XCTFail("expected notRevertible")
        } catch {
            XCTAssertEqual(error as? ModeAgentControllerError, .notRevertible(id))
        }
        XCTAssertEqual(controller.proposals.first?.status, .approved)
    }

    func testUnknownProposal() async {
        let h = Harness()
        let id = UUID()
        do {
            try await controller(h, scripted([])).reject(id)
            XCTFail("expected unknownProposal")
        } catch {
            XCTAssertEqual(error as? ModeAgentControllerError, .unknownProposal(id))
        }
    }
}
