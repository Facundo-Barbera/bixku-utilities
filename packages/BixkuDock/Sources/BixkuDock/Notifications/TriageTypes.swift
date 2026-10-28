import Foundation

/// The outcome of triaging one notification.
public struct TriageDecision: Codable, Sendable, Equatable {
    public var action: NotificationAction
    /// Human-readable explanation ("Chat is summarized while writing").
    public var reason: String
    /// The notification broke through as urgent.
    public var isUrgent: Bool
    public var source: VerdictSource

    public init(action: NotificationAction, reason: String, isUrgent: Bool = false, source: VerdictSource = .rules) {
        self.action = action
        self.reason = reason
        self.isUrgent = isUrgent
        self.source = source
    }
}

/// A notification with the decision taken for it.
public struct TriagedNotification: Codable, Sendable, Equatable, Identifiable {
    public var notification: IncomingNotification
    /// Category used for the decision (given by the source or inferred).
    public var category: NotificationCategory
    public var decision: TriageDecision
    /// Mode active when it was triaged.
    public var modeID: ModeID
    public var triagedAt: Date

    public init(
        notification: IncomingNotification,
        category: NotificationCategory,
        decision: TriageDecision,
        modeID: ModeID,
        triagedAt: Date
    ) {
        self.notification = notification
        self.category = category
        self.decision = decision
        self.modeID = modeID
        self.triagedAt = triagedAt
    }

    public var id: UUID { notification.id }
}

/// A language-model notification triager. Consulted by ``NotificationTriage`` only
/// when no explicit rule decided (the mode's default action would apply).
/// Same contract as ``LLMClassifying``: fast, cancellable, throws on failure.
public protocol LLMNotificationTriaging: Sendable {
    func triage(
        _ notification: IncomingNotification,
        category: NotificationCategory,
        mode: ModeDefinition,
        activity: ClassifiedActivity?
    ) async throws -> TriageDecision
}

/// Optional prose summary of a digest (e.g. by a language model). The digest's
/// deterministic ``NotificationDigest/summary`` is used when absent or failing.
public protocol DigestSummarizing: Sendable {
    func summarize(_ digest: NotificationDigest) async throws -> String
}
