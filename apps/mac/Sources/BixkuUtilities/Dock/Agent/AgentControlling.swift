import Foundation

// Portable (Foundation-only) side of the Dock "Agent" tab: the proposal model
// and the protocol the UI talks to. The SwiftUI views and the view model live
// next to this file and depend only on these types.

/// One field of a mode that a proposal creates, changes or removes.
struct AgentFieldChange: Equatable, Sendable {
    var name: String
    /// Value before the change; `nil` when the field did not exist.
    var before: String?
    /// Value after the change; `nil` when the field is removed.
    var after: String?
}

/// A single change to one mode, as proposed by the agent.
struct AgentChange: Equatable, Sendable {
    enum Kind: String, Sendable {
        case create
        case modify
        case remove
    }

    var kind: Kind
    /// Identifier of the mode the change applies to.
    var targetID: String
    var fields: [AgentFieldChange]

    init(kind: Kind, targetID: String, fields: [AgentFieldChange] = []) {
        self.kind = kind
        self.targetID = targetID
        self.fields = fields
    }
}

/// Where a proposal is in its life cycle.
enum ProposalStatus: Equatable, Sendable {
    /// Waiting for the user's decision.
    case pending
    /// Approved and applied.
    case approved
    /// Declined; nothing was applied.
    case rejected
    /// Was applied, then undone.
    case reverted
    /// Approved but applying it failed.
    case failed(String)

    var isPending: Bool {
        self == .pending
    }

    var isApproved: Bool {
        self == .approved
    }

    /// Whether the user can still act on the proposal.
    var isFinal: Bool {
        switch self {
        case .pending, .approved:
            return false
        case .rejected, .reverted, .failed:
            return true
        }
    }
}

/// A set of mode changes the agent wants to make in answer to one instruction.
struct AgentProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The natural-language instruction that produced the proposal.
    var instruction: String
    /// One-line description of what the agent intends to do.
    var summary: String
    var changes: [AgentChange]
    var status: ProposalStatus
    var createdAt: Date
    var decidedAt: Date?

    init(
        id: UUID = UUID(),
        instruction: String,
        summary: String,
        changes: [AgentChange],
        status: ProposalStatus = .pending,
        createdAt: Date = Date(),
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.instruction = instruction
        self.summary = summary
        self.changes = changes
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

enum AgentError: Error, Equatable, LocalizedError, Sendable {
    case emptyInstruction
    case unknownProposal(UUID)
    /// The action is not allowed in the proposal's current status.
    case invalidTransition(action: String, status: ProposalStatus)
    case providerNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .emptyInstruction:
            return "Type an instruction first."
        case .unknownProposal:
            return "That proposal no longer exists."
        case let .invalidTransition(action, _):
            return "Cannot \(action) this proposal in its current state."
        case let .providerNotConfigured(reason):
            return reason
        }
    }
}

/// What the Agent tab needs from an agent. The real implementation adapts
/// `BixkuModeAgent`; ``PlaceholderAgent`` stands in until it is plugged in.
protocol AgentControlling: AnyObject, Sendable {
    /// Every proposal of the session, oldest first. Each call returns a new
    /// subscription that yields the current list immediately and again after
    /// every change.
    var proposals: AsyncStream<[AgentProposal]> { get }

    /// Turns a natural-language instruction into a pending proposal.
    func instruct(_ instruction: String) async throws

    /// Applies a pending proposal.
    func approve(_ id: AgentProposal.ID) async throws

    /// Declines a pending proposal without applying anything.
    func reject(_ id: AgentProposal.ID) async throws

    /// Undoes an approved proposal.
    func revert(_ id: AgentProposal.ID) async throws
}
