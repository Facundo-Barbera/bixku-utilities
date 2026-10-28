import Foundation

/// How the active mode was chosen.
public enum ModeActivation: Codable, Sendable, Equatable, CustomStringConvertible {
    /// The configured default mode at startup.
    case initial
    /// An automatic transition rule fired (its summary, e.g. "code for 5m"), or the
    /// engine resumed automatic control.
    case automatic(reason: String)
    /// The user picked the mode. Automatic transitions are suspended until `until`
    /// (or until ``DockEngine/resumeAutomatic()`` when `nil`).
    case manual(until: Date?)

    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .initial: return "initial"
        case .automatic(let reason): return "automatic: \(reason)"
        case .manual(let until): return until.map { "manual until \($0)" } ?? "manual"
        }
    }
}

/// The active mode and how it got there.
public struct ModeSelection: Codable, Sendable, Equatable {
    public var modeID: ModeID
    public var activation: ModeActivation
    /// When this mode became active.
    public var since: Date

    public init(modeID: ModeID, activation: ModeActivation, since: Date) {
        self.modeID = modeID
        self.activation = activation
        self.since = since
    }
}

/// What the user is doing, as the engine sees it.
public struct CurrentActivity: Codable, Sendable, Equatable {
    /// Latest sample (after privacy redaction).
    public var sample: ActivitySample
    /// Verdict for the latest sample.
    public var verdict: ActivityVerdict
    /// Smoothed category over the recent window (see ``ActivitySmoother``).
    public var category: ActivityCategory
    /// Whether the latest sample is on task for the active mode.
    public var attention: AttentionLevel
    /// The user has been idle past the configured threshold.
    public var isIdle: Bool

    public init(sample: ActivitySample, verdict: ActivityVerdict, category: ActivityCategory, attention: AttentionLevel, isIdle: Bool) {
        self.sample = sample
        self.verdict = verdict
        self.category = category
        self.attention = attention
        self.isIdle = isIdle
    }
}

/// Snapshot of the engine, for UIs and other modules.
public struct DockState: Sendable, Equatable {
    public var mode: ModeSelection
    /// Definition of the active mode.
    public var activeMode: ModeDefinition
    public var activity: CurrentActivity?
    /// Notifications waiting for the end of the mode, oldest first.
    public var held: [TriagedNotification]
    /// Held notifications dropped because the queue was full.
    public var heldDropped: Int
    /// The digest produced when the previous mode ended.
    public var lastDigest: NotificationDigest?
    /// A mode the classifier suggested for the current activity (advisory).
    public var suggestedMode: ModeID?
    /// Problems loading user modes (shown in settings).
    public var modeIssues: [ModeLoadIssue]

    public var isManual: Bool {
        mode.activation.isManual
    }
}
