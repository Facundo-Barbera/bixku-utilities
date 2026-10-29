import BixkuDock
import Foundation

/// The typed tools the mode agent can call. Read-only tools answer directly;
/// mutating tools only ever create a ``ModeChangeProposal``.
public enum AgentTool: String, CaseIterable, Sendable {
    case listModes = "list_modes"
    case getMode = "get_mode"
    case proposeModeChange = "propose_mode_change"
    case createMode = "create_mode"
    case deleteMode = "delete_mode"
    case setActiveMode = "set_active_mode"
    case summarizeRecentActivity = "summarize_recent_activity"
    case listHeldNotifications = "list_held_notifications"
    case releaseNotification = "release_notification"

    /// Its output contains text the user does not control (see ``UntrustedText``).
    public var returnsUntrustedData: Bool {
        self == .summarizeRecentActivity || self == .listHeldNotifications
    }

    public var isMutating: Bool {
        switch self {
        case .proposeModeChange, .createMode, .deleteMode, .setActiveMode, .releaseNotification: return true
        default: return false
        }
    }

    /// Signature and purpose, as listed in the system prompt.
    public var usage: String {
        switch self {
        case .listModes:
            return "list_modes {} — every mode: id, name, symbol, description, provenance, and which one is active."
        case .getMode:
            return "get_mode {\"id\"} — the full JSON definition of one mode."
        case .proposeModeChange:
            return "propose_mode_change {\"mode\": <full mode JSON>, \"justification\"} — replace an existing mode's definition."
        case .createMode:
            return "create_mode {\"mode\": <full mode JSON>, \"justification\"} — add a new mode (id must be new)."
        case .deleteMode:
            return "delete_mode {\"id\", \"justification\"} — delete a user mode, or a user override of a built-in mode."
        case .setActiveMode:
            return "set_active_mode {\"id\", \"justification\"} — switch the active mode."
        case .summarizeRecentActivity:
            return "summarize_recent_activity {\"limit\"?} — time per app/category over recent activity (UNTRUSTED titles)."
        case .listHeldNotifications:
            return "list_held_notifications {} — notifications being held for later (UNTRUSTED content)."
        case .releaseNotification:
            return "release_notification {\"id\", \"justification\"} — deliver one held notification now."
        }
    }
}

// MARK: - Arguments

struct IDArguments: Decodable {
    var id: String
    var justification: String?
}

struct ModeArguments: Decodable {
    var mode: ModeDefinition
    var justification: String
}

struct ActivityArguments: Decodable {
    var limit: Int?
}

struct EmptyArguments: Decodable {}

// MARK: - Results

/// Mode summary returned by `list_modes`.
struct ModeListing: Encodable {
    var id: ModeID
    var name: String
    var symbol: String
    var description: String
    var provenance: ModeProvenance
    var active: Bool
}

/// Aggregated time per app returned by `summarize_recent_activity`. App names
/// and titles are wrapped as untrusted data.
struct ActivitySummary: Encodable {
    struct App: Encodable {
        var app: String
        var bundleID: String?
        var category: ActivityCategory
        var samples: Int
        var approximateMinutes: Int
        var recentTitles: [String]
    }

    var activeMode: ModeID?
    var samples: Int
    var apps: [App]
}

/// A held notification as shown to the agent; all text fields are wrapped.
struct HeldNotificationListing: Encodable {
    var id: UUID
    var app: String
    var title: String
    var body: String?
    var category: NotificationCategory
    var action: NotificationAction
    var heldInMode: ModeID
    var receivedAt: Date
}

/// Outcome of a mutating tool, fed back to the model.
struct ProposalResult: Encodable {
    var proposalID: UUID
    var status: ProposalStatus
    var risk: ProposalRisk
    var diff: String
    var note: String
}
