import BixkuDock
import Foundation

/// The policy's verdict on a proposal.
public enum ApprovalDecision: Sendable, Equatable {
    /// Apply without asking.
    case autoApprove
    /// Ask the user first.
    case requireConfirmation
}

/// Decides which agent proposals may be applied without asking the user.
///
/// - The default (``Mode/confirmAll``) asks for everything.
/// - ``Mode/autoApproveLowRisk`` applies low-risk proposals directly. Low risk means
///   the change only edits presentation (name, symbol, description, dock order) or
///   *adds* focus/urgency/always-allow criteria, or switches the active mode.
/// - Some changes are never auto-approved, whatever the mode: deleting a mode,
///   silencing/holding a critical notification category, weakening urgency
///   (removing urgent keywords or categories, ignoring time-sensitive flags), and
///   any proposal made after the agent read untrusted text in the same run.
public struct ApprovalPolicy: Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case confirmAll = "confirm-all"
        case autoApproveLowRisk = "auto-approve-low-risk"
    }

    public var mode: Mode
    /// Notification categories that must keep reaching the user.
    public var criticalCategories: Set<NotificationCategory>

    public static let defaultCriticalCategories: Set<NotificationCategory> = [.directMessage, .calendar]

    public init(mode: Mode = .confirmAll, criticalCategories: Set<NotificationCategory> = ApprovalPolicy.defaultCriticalCategories) {
        self.mode = mode
        self.criticalCategories = criticalCategories
    }

    public static let `default` = ApprovalPolicy()

    /// Risk of `action` and the reasons for it.
    public func assess(_ action: ProposedAction) -> (risk: ProposalRisk, reasons: [String]) {
        switch action {
        case .delete(let definition):
            return (.high, ["deletes mode '\(definition.id)'"])
        case .activate:
            return (.low, [])
        case .releaseNotification:
            return (.low, [])
        case .create(let definition):
            var reasons = criticalReasons(before: nil, after: definition)
            if !reasons.isEmpty { return (.high, reasons) }
            reasons.append("adds a new mode")
            return (.medium, reasons)
        case .update(let before, let after):
            let critical = criticalReasons(before: before, after: after)
            if !critical.isEmpty { return (.high, critical) }
            let risky = ModeDiff.changes(from: before, to: after).filter { !Self.isLowRisk($0) }
            if risky.isEmpty { return (.low, []) }
            return (.medium, risky.map { "changes \($0.path)" })
        }
    }

    /// Whether a proposal may skip the user.
    public func decide(_ proposal: ModeChangeProposal) -> ApprovalDecision {
        guard mode == .autoApproveLowRisk, !proposal.influencedByUntrustedData else { return .requireConfirmation }
        let (risk, _) = assess(proposal.action)
        return risk == .low ? .autoApprove : .requireConfirmation
    }

    /// Critical categories whose notifications `definition` could hold, summarize or
    /// silence. Conservative: any rule mentioning the category counts, whatever
    /// its activity condition.
    public func suppressedCriticalCategories(in definition: ModeDefinition) -> Set<NotificationCategory> {
        let policy = definition.notifications
        return criticalCategories.filter { category in
            if policy.alwaysAllow.categories.contains(category) || policy.urgent.categories.contains(category) {
                return false
            }
            let ruleSuppresses = policy.rules.contains { $0.match.categories.contains(category) && $0.action != .allow }
            return ruleSuppresses || policy.defaultAction != .allow
        }
    }

    private func criticalReasons(before: ModeDefinition?, after: ModeDefinition) -> [String] {
        var reasons: [String] = []
        let newlySuppressed = suppressedCriticalCategories(in: after)
            .subtracting(before.map(suppressedCriticalCategories(in:)) ?? [])
        for category in newlySuppressed.sorted() {
            reasons.append("stops delivering critical '\(category)' notifications")
        }
        let newRules = after.notifications.rules.filter { $0.action == .silence }
        let oldRules = before?.notifications.rules.filter { $0.action == .silence } ?? []
        let startsSilencingByDefault = after.notifications.defaultAction == .silence
            && before?.notifications.defaultAction != .silence
        if newRules.count > oldRules.count || startsSilencingByDefault {
            reasons.append("silences notifications (they are dropped, not held)")
        }
        if let before {
            let oldUrgent = before.notifications.urgent
            let newUrgent = after.notifications.urgent
            let lostKeywords = Set(oldUrgent.keywords.map { $0.lowercased() }).subtracting(newUrgent.keywords.map { $0.lowercased() })
            if !lostKeywords.isEmpty { reasons.append("removes urgent keywords: \(lostKeywords.sorted().joined(separator: ", "))") }
            let lostCategories = Set(oldUrgent.categories).subtracting(newUrgent.categories)
            if !lostCategories.isEmpty {
                reasons.append("removes urgent categories: \(lostCategories.sorted().map(\.rawValue).joined(separator: ", "))")
            }
            if oldUrgent.honorTimeSensitive && !newUrgent.honorTimeSensitive {
                reasons.append("ignores time-sensitive notifications")
            }
            let old = before.notifications.alwaysAllow
            let new = after.notifications.alwaysAllow
            if !Set(old.apps).isSubset(of: new.apps) || !Set(old.categories).isSubset(of: new.categories)
                || !Set(old.keywords).isSubset(of: new.keywords)
            {
                reasons.append("narrows the always-allow exceptions")
            }
        } else if !after.notifications.urgent.honorTimeSensitive {
            reasons.append("ignores time-sensitive notifications")
        }
        return reasons
    }

    /// Fields that only affect presentation, or that add focus/urgency criteria.
    /// Additions under these paths are low risk; removals and edits of
    /// existing urgency entries are caught by ``criticalReasons(before:after:)``.
    private static let lowRiskPrefixes = [
        "name", "symbol", "description", "dock.prioritized",
        "attention.focus", "notifications.urgent.keywords", "notifications.urgent.categories",
        "notifications.alwaysAllow",
    ]

    private static func isLowRisk(_ change: ModeFieldChange) -> Bool {
        lowRiskPrefixes.contains { change.path == $0 || change.path.hasPrefix($0 + ".") || change.path.hasPrefix($0 + "[") }
    }
}
