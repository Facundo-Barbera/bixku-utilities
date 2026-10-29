import BixkuCore
import Foundation

/// Where a proposal stands for the user reviewing it, in the vocabulary of the
/// Agent tab. It mirrors ``ProposalStatus`` with two differences: an applied
/// proposal is *approved*, and a failed one carries the reason it failed.
public enum ProposalReviewStatus: Equatable, Sendable {
    case pending
    /// Approved (by the user or by the policy) and applied.
    case approved
    case rejected
    /// Applied, then undone.
    case reverted
    /// Applying it failed; the message says why.
    case failed(String)

    /// `applied` becomes `approved`; `failed` takes `failure` as its message.
    public init(_ status: ProposalStatus, failure: String? = nil) {
        switch status {
        case .pending: self = .pending
        case .applied: self = .approved
        case .rejected: self = .rejected
        case .reverted: self = .reverted
        case .failed: self = .failed(failure ?? "The change could not be applied.")
        }
    }

    /// The agent package's status: `approved` becomes `applied`; the message of
    /// `failed` has no counterpart there and is dropped.
    public var proposalStatus: ProposalStatus {
        switch self {
        case .pending: return .pending
        case .approved: return .applied
        case .rejected: return .rejected
        case .reverted: return .reverted
        case .failed: return .failed
        }
    }
}

/// A proposal as the review UI shows it: the coordinator's proposal plus the
/// instruction that produced it, its review status and when it was decided.
public struct ReviewedProposal: Identifiable, Equatable, Sendable {
    public var proposal: ModeChangeProposal
    /// The user's instruction that led to the proposal.
    public var instruction: String
    public var status: ProposalReviewStatus
    public var decidedAt: Date?

    public init(proposal: ModeChangeProposal, instruction: String, status: ProposalReviewStatus, decidedAt: Date? = nil) {
        self.proposal = proposal
        self.instruction = instruction
        self.status = status
        self.decidedAt = decidedAt
    }

    public var id: UUID { proposal.id }
}

/// Errors of ``ModeAgentController``. Messages are written for the user.
public enum ModeAgentControllerError: Error, Equatable, Sendable, LocalizedError {
    case emptyInstruction
    /// No usable language model (no API key, no model…). The message says what to fix.
    case notConfigured(String)
    case unknownProposal(UUID)
    /// The action is not allowed in the proposal's current status.
    case invalidTransition(action: String, status: ProposalReviewStatus)
    /// Mode switches and released notifications cannot be undone.
    case notRevertible(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyInstruction: return "Type an instruction first."
        case .notConfigured(let message): return message
        case .unknownProposal: return "That proposal no longer exists."
        case .invalidTransition(let action, _): return "Cannot \(action) this proposal in its current state."
        case .notRevertible: return "Switching modes and releasing notifications cannot be undone."
        }
    }
}

/// Drives the mode agent for a review UI (the Dock's Agent tab).
///
/// Each ``instruct(_:)`` runs a fresh ``ModeAgent`` on a language model obtained
/// from `llm` at that moment, so provider settings changed by the user apply to
/// the next instruction, and a missing API key fails before anything else with
/// ``ModeAgentControllerError/notConfigured(_:)``. Proposals go through one
/// long-lived ``ProposalCoordinator`` (policy, history, revert); the controller
/// tracks them with their instruction and translates their status for the UI
/// (``ProposalReviewStatus``), keeping the reason when applying one fails.
public final class ModeAgentController: @unchecked Sendable {
    public typealias LLMProvider = @Sendable () throws -> any AgentLLM

    public let coordinator: ProposalCoordinator
    private let llm: LLMProvider
    private let clock: any BixkuClock
    private let maxSteps: Int
    private let lock = NSLock()
    private var items: [ReviewedProposal] = []
    private var subscribers: [UUID: AsyncStream<[ReviewedProposal]>.Continuation] = [:]

    public init(coordinator: ProposalCoordinator, llm: @escaping LLMProvider, clock: any BixkuClock = SystemClock(), maxSteps: Int = 12) {
        self.coordinator = coordinator
        self.llm = llm
        self.clock = clock
        self.maxSteps = maxSteps
    }

    /// Every proposal of the session, oldest first.
    public var proposals: [ReviewedProposal] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// The current proposals right away, then again after every change.
    public func updates() -> AsyncStream<[ReviewedProposal]> {
        AsyncStream { continuation in
            let token = UUID()
            lock.lock()
            subscribers[token] = continuation
            continuation.yield(items)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[token] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: - Commands

    /// Runs the agent on `instruction`. Proposals it makes appear in
    /// ``proposals``, also when the run itself fails afterwards.
    @discardableResult
    public func instruct(_ instruction: String) async throws -> AgentRunResult {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModeAgentControllerError.emptyInstruction }
        let model = try llm()
        let agent = ModeAgent(llm: model, coordinator: coordinator, clock: clock, maxSteps: maxSteps)
        do {
            let result = try await agent.run(text)
            await adoptNewProposals(instruction: text)
            return result
        } catch {
            await adoptNewProposals(instruction: text)
            throw error
        }
    }

    /// Applies a pending proposal. If applying fails the proposal becomes
    /// `failed` with the reason, and the error is rethrown.
    public func approve(_ id: UUID) async throws {
        try require(id, action: "approve") { $0 == .pending }
        do {
            try await coordinator.approve(id)
            update(id, status: .approved)
        } catch {
            if await coordinator.proposal(id)?.status == .failed {
                update(id, status: .failed(Self.describe(error)))
            }
            throw error
        }
    }

    /// Declines a pending proposal.
    public func reject(_ id: UUID) async throws {
        try require(id, action: "reject") { $0 == .pending }
        try await coordinator.reject(id)
        update(id, status: .rejected)
    }

    /// Undoes an approved catalog change. If the mode changed since, this throws
    /// and the proposal stays approved.
    public func revert(_ id: UUID) async throws {
        let item = try require(id, action: "revert") { $0 == .approved }
        guard item.proposal.action.changesCatalog else { throw ModeAgentControllerError.notRevertible(id) }
        try await coordinator.revertProposal(id)
        update(id, status: .reverted)
    }

    // MARK: - Helpers

    @discardableResult
    private func require(_ id: UUID, action: String, _ allowed: (ProposalReviewStatus) -> Bool) throws -> ReviewedProposal {
        guard let item = proposals.first(where: { $0.id == id }) else {
            throw ModeAgentControllerError.unknownProposal(id)
        }
        guard allowed(item.status) else {
            throw ModeAgentControllerError.invalidTransition(action: action, status: item.status)
        }
        return item
    }

    /// Records the coordinator's proposals this controller has not seen yet.
    private func adoptNewProposals(instruction: String) async {
        let all = await coordinator.allProposals
        let now = clock.now()
        mutate { items in
            let known = Set(items.map(\.id))
            for proposal in all where !known.contains(proposal.id) {
                let status = ProposalReviewStatus(proposal.status)
                items.append(ReviewedProposal(
                    proposal: proposal,
                    instruction: instruction,
                    status: status,
                    decidedAt: status == .pending ? nil : now
                ))
            }
        }
    }

    private func update(_ id: UUID, status: ProposalReviewStatus) {
        let now = clock.now()
        mutate { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].status = status
            items[index].proposal.status = status.proposalStatus
            items[index].decidedAt = now
        }
    }

    /// Applies `change` and publishes the new list under the lock, so subscribers
    /// see updates in order (`yield` never blocks).
    private func mutate(_ change: (inout [ReviewedProposal]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&items)
        for subscriber in subscribers.values {
            subscriber.yield(items)
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
