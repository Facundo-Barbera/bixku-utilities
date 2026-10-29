import BixkuCore
import Foundation

extension EventName {
    /// The mode agent proposed a change. Producer: ``AgentModule``.
    public static let agentProposal: EventName = "agent.proposal"
    /// A proposal (or a revert) was applied. Producer: ``AgentModule``.
    public static let agentApplied: EventName = "agent.applied"
}

/// The agent made a proposal. `requiresConfirmation` tells the UI to ask the user.
public struct AgentProposalEvent: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .agentProposal

    public var proposal: ModeChangeProposal
    public var requiresConfirmation: Bool

    public init(proposal: ModeChangeProposal, requiresConfirmation: Bool) {
        self.proposal = proposal
        self.requiresConfirmation = requiresConfirmation
    }
}

/// A change was applied: an approved proposal, or a revert of a history version.
public struct AgentAppliedEvent: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .agentApplied

    /// `nil` for reverts.
    public var proposal: ModeChangeProposal?
    /// History entry recorded for catalog changes.
    public var historyVersion: Int?
    public var autoApproved: Bool
    public var summary: String

    public init(proposal: ModeChangeProposal?, historyVersion: Int?, autoApproved: Bool, summary: String) {
        self.proposal = proposal
        self.historyVersion = historyVersion
        self.autoApproved = autoApproved
        self.summary = summary
    }
}
