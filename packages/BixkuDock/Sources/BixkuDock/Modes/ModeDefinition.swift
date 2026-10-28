import Foundation

/// The JSON document describing one focus mode.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "building",
///   "name": "Building",
///   "symbol": "hammer",
///   "description": "Shipping code. IDE and terminal up front, chat waits.",
///   "dock": { "prioritized": ["com.apple.Terminal"], "hidden": ["com.apple.Music"] },
///   "attention": { "focus": { "categories": ["code"] }, "distractions": { "categories": ["media"] } },
///   "notifications": { "default": "hold", "rules": [], "alwaysAllow": {}, "urgent": {} },
///   "transitions": [ { "trigger": "activity", "match": { "categories": ["code"] }, "forSeconds": 300 } ]
/// }
/// ```
///
/// Every section except the identity fields is optional in JSON and defaults to
/// "no rules". Documents are validated by ``ModeValidator`` and upgraded from older
/// schema versions by ``ModeMigrator`` before decoding.
public struct ModeDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Schema version written by this build.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: ModeID
    /// Display name ("Building").
    public var name: String
    /// SF Symbol name used by the UI ("hammer").
    public var symbol: String
    /// Natural-language description of the mode's intent. Shown to the user and given
    /// to language models as the mode's "prompt". Encoded as `description`.
    public var summary: String
    public var dock: DockLayout
    public var attention: AttentionRules
    public var notifications: NotificationPolicy
    /// Automatic entry rules for this mode.
    public var transitions: [ModeRule]

    public init(
        schemaVersion: Int = ModeDefinition.currentSchemaVersion,
        id: ModeID,
        name: String,
        symbol: String,
        summary: String,
        dock: DockLayout = DockLayout(),
        attention: AttentionRules = AttentionRules(),
        notifications: NotificationPolicy = NotificationPolicy(),
        transitions: [ModeRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.dock = dock
        self.attention = attention
        self.notifications = notifications
        self.transitions = transitions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, symbol
        case summary = "description"
        case dock, attention, notifications, transitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(ModeID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "circle"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        dock = try container.decodeIfPresent(DockLayout.self, forKey: .dock) ?? DockLayout()
        attention = try container.decodeIfPresent(AttentionRules.self, forKey: .attention) ?? AttentionRules()
        notifications = try container.decodeIfPresent(NotificationPolicy.self, forKey: .notifications)
            ?? NotificationPolicy()
        transitions = try container.decodeIfPresent([ModeRule].self, forKey: .transitions) ?? []
    }
}

// MARK: - Dock layout

/// Which apps the dock emphasizes or hides while the mode is active.
public struct DockLayout: Codable, Sendable, Equatable {
    /// Bundle ids shown first, in order.
    public var prioritized: [String]
    /// Bundle id patterns hidden from the dock.
    public var hidden: [String]

    public init(prioritized: [String] = [], hidden: [String] = []) {
        self.prioritized = prioritized
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case prioritized, hidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prioritized = try container.decodeIfPresent([String].self, forKey: .prioritized) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
    }

    /// Orders `bundleIDs` for display: prioritized apps first (in their declared
    /// order), then the rest in their original order; hidden apps are dropped.
    public func arrange(_ bundleIDs: [String]) -> [String] {
        let visible = bundleIDs.filter { !AppPattern.matchesAny(hidden, bundleID: $0) }
        let first = prioritized.filter { id in visible.contains { $0.lowercased() == id.lowercased() } }
        let firstSet = Set(first.map { $0.lowercased() })
        return first + visible.filter { !firstSet.contains($0.lowercased()) }
    }
}

// MARK: - Attention

/// Whether an activity serves the mode's purpose.
public enum AttentionLevel: String, Codable, Sendable, CaseIterable {
    case focus
    case neutral
    case distraction
}

/// What is "on task" and what is a distraction in a mode.
public struct AttentionRules: Codable, Sendable, Equatable {
    public var focus: ActivityMatcher
    public var distractions: ActivityMatcher

    public init(focus: ActivityMatcher = ActivityMatcher(), distractions: ActivityMatcher = ActivityMatcher()) {
        self.focus = focus
        self.distractions = distractions
    }

    private enum CodingKeys: String, CodingKey {
        case focus, distractions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focus = try container.decodeIfPresent(ActivityMatcher.self, forKey: .focus) ?? ActivityMatcher()
        distractions = try container.decodeIfPresent(ActivityMatcher.self, forKey: .distractions) ?? ActivityMatcher()
    }

    /// Classifies an activity. A specific match (app, title, host) beats a category
    /// match; on a tie, focus wins.
    public func level(for sample: ActivitySample, category: ActivityCategory?) -> AttentionLevel {
        let focusMatch = focus.match(sample, category: category)
        let distractionMatch = distractions.match(sample, category: category)
        switch (focusMatch, distractionMatch) {
        case (nil, nil): return .neutral
        case (.some, nil): return .focus
        case (nil, .some): return .distraction
        case let (.some(f), .some(d)): return d > f ? .distraction : .focus
        }
    }
}

// MARK: - Notifications

/// What to do with a notification.
public enum NotificationAction: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    /// Deliver now.
    case allow
    /// Keep it and deliver it individually when the mode ends.
    case hold
    /// Keep it and fold it into the end-of-mode digest (grouped, counted).
    case summarize
    /// Drop it (it is still recorded in the triage event).
    case silence

    public var description: String {
        rawValue
    }

    /// Whether the notification goes to the held queue.
    public var isDeferred: Bool {
        self == .hold || self == .summarize
    }
}

/// One notification rule. Rules are evaluated in order; the first match wins.
public struct NotificationRule: Codable, Sendable, Equatable {
    public var match: NotificationMatcher
    public var action: NotificationAction
    /// If set, the rule only applies while the current activity matches.
    public var whileActivity: ActivityMatcher?
    /// Optional explanation shown in triage reasons ("Chat can wait while writing").
    public var note: String?

    public init(
        match: NotificationMatcher,
        action: NotificationAction,
        whileActivity: ActivityMatcher? = nil,
        note: String? = nil
    ) {
        self.match = match
        self.action = action
        self.whileActivity = whileActivity
        self.note = note
    }
}

/// Which notifications break through any rule.
public struct UrgencyPolicy: Codable, Sendable, Equatable {
    /// Case-insensitive keywords that mark a notification as urgent ("urgent", "outage").
    public var keywords: [String]
    /// Categories always treated as urgent.
    public var categories: [NotificationCategory]
    /// Honor the OS time-sensitive / critical flag.
    public var honorTimeSensitive: Bool

    public init(keywords: [String] = [], categories: [NotificationCategory] = [], honorTimeSensitive: Bool = true) {
        self.keywords = keywords
        self.categories = categories
        self.honorTimeSensitive = honorTimeSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case keywords, categories, honorTimeSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        categories = try container.decodeIfPresent([NotificationCategory].self, forKey: .categories) ?? []
        honorTimeSensitive = try container.decodeIfPresent(Bool.self, forKey: .honorTimeSensitive) ?? true
    }

    /// Why `notification` is urgent, or `nil` if it is not.
    public func urgencyReason(for notification: IncomingNotification, category: NotificationCategory) -> String? {
        if honorTimeSensitive, notification.isTimeSensitive { return "marked time-sensitive" }
        if categories.contains(category) { return "\(category) is always urgent" }
        let text = notification.searchableText
        if let keyword = keywords.first(where: { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }) {
            return "contains urgent keyword '\(keyword)'"
        }
        return nil
    }
}

/// How a mode treats incoming notifications.
///
/// Evaluation order (see ``NotificationTriage``): `alwaysAllow` exceptions, urgency,
/// the focused-app shortcut, `rules` (first match wins), then `default`.
public struct NotificationPolicy: Codable, Sendable, Equatable {
    /// Action when nothing else matches.
    public var defaultAction: NotificationAction
    public var rules: [NotificationRule]
    /// Exceptions that are always delivered (specific people's apps, calendar…).
    public var alwaysAllow: NotificationMatcher
    public var urgent: UrgencyPolicy
    /// Deliver notifications from the app the user is currently using.
    public var allowFromFocusedApp: Bool

    public init(
        defaultAction: NotificationAction = .allow,
        rules: [NotificationRule] = [],
        alwaysAllow: NotificationMatcher = NotificationMatcher(),
        urgent: UrgencyPolicy = UrgencyPolicy(),
        allowFromFocusedApp: Bool = true
    ) {
        self.defaultAction = defaultAction
        self.rules = rules
        self.alwaysAllow = alwaysAllow
        self.urgent = urgent
        self.allowFromFocusedApp = allowFromFocusedApp
    }

    private enum CodingKeys: String, CodingKey {
        case defaultAction = "default"
        case rules, alwaysAllow, urgent, allowFromFocusedApp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultAction = try container.decodeIfPresent(NotificationAction.self, forKey: .defaultAction) ?? .allow
        rules = try container.decodeIfPresent([NotificationRule].self, forKey: .rules) ?? []
        alwaysAllow = try container.decodeIfPresent(NotificationMatcher.self, forKey: .alwaysAllow)
            ?? NotificationMatcher()
        urgent = try container.decodeIfPresent(UrgencyPolicy.self, forKey: .urgent) ?? UrgencyPolicy()
        allowFromFocusedApp = try container.decodeIfPresent(Bool.self, forKey: .allowFromFocusedApp) ?? true
    }
}

// MARK: - Transitions

/// What starts an automatic transition.
public enum ModeTrigger: String, Codable, Sendable, CaseIterable {
    /// Activity matching ``ModeRule/match`` has been in the foreground for
    /// ``ModeRule/forSeconds`` (short interruptions tolerated).
    case activity
    /// The user has been idle for ``ModeRule/forSeconds``.
    case idle
}

/// An automatic entry rule: "switch to this mode when …".
///
/// Example: enter `building` when an IDE or terminal has been frontmost for 5 minutes:
/// `{ "trigger": "activity", "match": { "categories": ["code"] }, "forSeconds": 300 }`.
public struct ModeRule: Codable, Sendable, Equatable {
    public var trigger: ModeTrigger
    /// Required for `activity`, must be absent for `idle`.
    public var match: ActivityMatcher?
    /// How long the condition must hold, in seconds.
    public var forSeconds: TimeInterval
    /// Only switch from these modes (`nil` = from any mode).
    public var from: [ModeID]?
    /// Higher wins when several rules fire at once.
    public var priority: Int

    public init(
        trigger: ModeTrigger,
        match: ActivityMatcher? = nil,
        forSeconds: TimeInterval,
        from: [ModeID]? = nil,
        priority: Int = 0
    ) {
        self.trigger = trigger
        self.match = match
        self.forSeconds = forSeconds
        self.from = from
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, match, forSeconds, from, priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decode(ModeTrigger.self, forKey: .trigger)
        match = try container.decodeIfPresent(ActivityMatcher.self, forKey: .match)
        forSeconds = try container.decode(TimeInterval.self, forKey: .forSeconds)
        from = try container.decodeIfPresent([ModeID].self, forKey: .from)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    /// Short description for reasons and logs ("code for 5m").
    public var summary: String {
        let duration = DurationFormat.short(forSeconds)
        switch trigger {
        case .idle:
            return "idle for \(duration)"
        case .activity:
            return "\(match.map(DurationFormat.describe) ?? "activity") for \(duration)"
        }
    }
}

/// Small formatting helpers shared by reasons and digests.
enum DurationFormat {
    /// `90` → `1m 30s`, `3600` → `1h`, `5400` → `1h 30m`.
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m" }
        return "\(secs)s"
    }

    static func describe(_ matcher: ActivityMatcher) -> String {
        let parts = matcher.categories.map(\.rawValue) + matcher.apps + matcher.urlHosts
            + matcher.titleKeywords.map { "\"\($0)\"" }
        return parts.isEmpty ? "activity" : parts.joined(separator: "/")
    }
}
