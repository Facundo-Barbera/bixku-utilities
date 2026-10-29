import BixkuDock
import Foundation

/// What a proposal would do once approved.
public enum ProposedAction: Codable, Sendable, Equatable {
    /// Create a new user mode.
    case create(ModeDefinition)
    /// Replace a mode (or override a built-in one). `before` is the definition the
    /// proposal was computed against; applying fails if the mode changed since.
    case update(before: ModeDefinition, after: ModeDefinition)
    /// Delete a user mode, or a user override (which restores the built-in mode).
    case delete(ModeDefinition)
    /// Switch the active mode.
    case activate(from: ModeID?, to: ModeID)
    /// Deliver a held notification now.
    case releaseNotification(id: UUID, description: String)

    public var modeID: ModeID? {
        switch self {
        case .create(let definition), .delete(let definition): return definition.id
        case .update(_, let after): return after.id
        case .activate(_, let to): return to
        case .releaseNotification: return nil
        }
    }

    /// `create`, `update`, `delete`, `activate` or `release-notification`.
    public var kind: String {
        switch self {
        case .create: return "create"
        case .update: return "update"
        case .delete: return "delete"
        case .activate: return "activate"
        case .releaseNotification: return "release-notification"
        }
    }

    /// Whether the action edits the mode catalog (and is therefore versioned and revertible).
    public var changesCatalog: Bool {
        switch self {
        case .create, .update, .delete: return true
        case .activate, .releaseNotification: return false
        }
    }
}

/// How risky a proposal is, as judged by ``ApprovalPolicy``.
public enum ProposalRisk: String, Codable, Sendable, Comparable, CaseIterable {
    case low
    case medium
    case high

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: ProposalRisk, rhs: ProposalRisk) -> Bool {
        lhs.order < rhs.order
    }
}

/// Lifecycle of a proposal.
public enum ProposalStatus: String, Codable, Sendable {
    /// Waiting for the user.
    case pending
    case applied
    case rejected
    /// Applied, then undone with ``ProposalCoordinator/revertProposal(_:)``.
    case reverted
    /// Could not be applied (the mode changed meanwhile, or the store refused it).
    case failed
}

/// A change the agent wants to make, with everything the user needs to judge it:
/// a readable diff, the agent's justification and the policy's risk assessment.
public struct ModeChangeProposal: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var action: ProposedAction
    /// The agent's reason, in its own words. Shown verbatim to the user; never
    /// used to decide anything.
    public var justification: String
    public var changes: [ModeFieldChange]
    public var risk: ProposalRisk
    /// Why the policy rated the risk as it did ("deletes a mode", …).
    public var riskReasons: [String]
    /// The run consumed untrusted text (notifications, window titles) before
    /// proposing this; such proposals are never auto-approved.
    public var influencedByUntrustedData: Bool
    public var status: ProposalStatus
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        action: ProposedAction,
        justification: String,
        changes: [ModeFieldChange],
        risk: ProposalRisk = .high,
        riskReasons: [String] = [],
        influencedByUntrustedData: Bool = false,
        status: ProposalStatus = .pending,
        createdAt: Date
    ) {
        self.id = id
        self.action = action
        self.justification = justification
        self.changes = changes
        self.risk = risk
        self.riskReasons = riskReasons
        self.influencedByUntrustedData = influencedByUntrustedData
        self.status = status
        self.createdAt = createdAt
    }

    /// One-line summary ("update 'writing' (3 changes)").
    public var title: String {
        switch action {
        case .create(let definition): return "Create mode '\(definition.id)'"
        case .update(_, let after): return "Update mode '\(after.id)' (\(changes.count) change\(changes.count == 1 ? "" : "s"))"
        case .delete(let definition): return "Delete mode '\(definition.id)'"
        case .activate(_, let to): return "Switch to mode '\(to)'"
        case .releaseNotification(_, let description): return "Deliver held notification: \(description)"
        }
    }

    /// The diff as text.
    public var renderedDiff: String {
        ModeDiff.render(changes)
    }
}
