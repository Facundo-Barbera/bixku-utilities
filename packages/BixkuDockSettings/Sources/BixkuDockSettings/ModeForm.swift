import BixkuDock
import Foundation

/// One automatic-entry rule as the form shows it. Numbers stay text until
/// ``ModeForm/build(applyingTo:knownModes:)`` so a half-typed value is reported
/// instead of silently coerced.
public struct TransitionForm: Equatable, Sendable {
    public var trigger: ModeTrigger
    /// Activity criteria (ignored for `idle` triggers).
    public var apps: [String]
    public var categories: [ActivityCategory]
    public var titleKeywords: [String]
    public var urlHosts: [String]
    public var secondsText: String
    /// Mode ids the rule applies from; empty means from any mode.
    public var from: [String]
    public var priorityText: String

    public init(
        trigger: ModeTrigger = .activity,
        apps: [String] = [],
        categories: [ActivityCategory] = [],
        titleKeywords: [String] = [],
        urlHosts: [String] = [],
        secondsText: String = "300",
        from: [String] = [],
        priorityText: String = "0"
    ) {
        self.trigger = trigger
        self.apps = apps
        self.categories = categories
        self.titleKeywords = titleKeywords
        self.urlHosts = urlHosts
        self.secondsText = secondsText
        self.from = from
        self.priorityText = priorityText
    }

    public init(_ rule: ModeRule) {
        let match = rule.match ?? ActivityMatcher()
        self.init(
            trigger: rule.trigger,
            apps: match.apps,
            categories: match.categories,
            titleKeywords: match.titleKeywords,
            urlHosts: match.urlHosts,
            secondsText: Self.text(for: rule.forSeconds),
            from: rule.from?.map(\.rawValue) ?? [],
            priorityText: String(rule.priority)
        )
    }

    static func text(for seconds: TimeInterval) -> String {
        if seconds.isFinite, seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}

/// The outcome of turning a form into a definition.
public struct ModeFormResult: Sendable, Equatable {
    /// The definition the form describes. When ``issues`` is not empty it may hold
    /// fallback values for the fields that could not be read.
    public var definition: ModeDefinition
    public var issues: [ModeValidationIssue]

    public var isValid: Bool {
        issues.isEmpty
    }
}

/// The editable subset of a ``ModeDefinition``: identity, dock layout, notification
/// policy basics and transitions. Everything the form does not show (attention
/// rules, notification rules, `alwaysAllow`, …) is carried over from the definition
/// it is applied to, so editing in the form never loses data that only the JSON
/// view (or the agent) edits.
public struct ModeForm: Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var summary: String
    public var prioritized: [String]
    public var hidden: [String]
    public var defaultAction: NotificationAction
    public var allowFromFocusedApp: Bool
    public var honorTimeSensitive: Bool
    public var urgentKeywords: [String]
    public var transitions: [TransitionForm]

    public init(_ definition: ModeDefinition) {
        id = definition.id.rawValue
        name = definition.name
        symbol = definition.symbol
        summary = definition.summary
        prioritized = definition.dock.prioritized
        hidden = definition.dock.hidden
        defaultAction = definition.notifications.defaultAction
        allowFromFocusedApp = definition.notifications.allowFromFocusedApp
        honorTimeSensitive = definition.notifications.urgent.honorTimeSensitive
        urgentKeywords = definition.notifications.urgent.keywords
        transitions = definition.transitions.map(TransitionForm.init)
    }

    /// Applies the form to `base` and validates the result with ``ModeValidator``.
    ///
    /// - Parameter knownModes: ids a transition's `from` may reference; pass the
    ///   catalog's ids plus the mode being edited, or `nil` to skip that check.
    public func build(applyingTo base: ModeDefinition, knownModes: Set<ModeID>? = nil) -> ModeFormResult {
        var formIssues: [ModeValidationIssue] = []
        var definition = base
        definition.id = ModeID(rawValue: id.trimmingCharacters(in: .whitespacesAndNewlines))
        definition.name = name
        definition.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.summary = summary
        definition.dock.prioritized = prioritized
        definition.dock.hidden = hidden
        definition.notifications.defaultAction = defaultAction
        definition.notifications.allowFromFocusedApp = allowFromFocusedApp
        definition.notifications.urgent.honorTimeSensitive = honorTimeSensitive
        definition.notifications.urgent.keywords = urgentKeywords

        definition.transitions = transitions.enumerated().map { index, form in
            Self.rule(from: form, at: index, issues: &formIssues)
        }

        let reported = Set(formIssues.map(\.path))
        let validatorIssues = ModeValidator()
            .issues(in: definition, knownModes: knownModes)
            .filter { !reported.contains($0.path) }
        return ModeFormResult(definition: definition, issues: formIssues + validatorIssues)
    }

    private static func rule(from form: TransitionForm, at index: Int, issues: inout [ModeValidationIssue]) -> ModeRule {
        let path = "transitions[\(index)]"

        var seconds: TimeInterval = 0
        let secondsText = form.secondsText.trimmingCharacters(in: .whitespaces)
        if let value = Double(secondsText), value.isFinite {
            seconds = value
        } else {
            issues.append(ModeValidationIssue(path: "\(path).forSeconds", message: "'\(secondsText)' is not a number of seconds"))
        }

        var priority = 0
        let priorityText = form.priorityText.trimmingCharacters(in: .whitespaces)
        if !priorityText.isEmpty {
            if let value = Int(priorityText) {
                priority = value
            } else {
                issues.append(ModeValidationIssue(path: "\(path).priority", message: "'\(priorityText)' is not a whole number"))
            }
        }

        var match: ActivityMatcher?
        if form.trigger == .activity {
            let matcher = ActivityMatcher(
                apps: form.apps,
                categories: form.categories,
                titleKeywords: form.titleKeywords,
                urlHosts: form.urlHosts
            )
            match = matcher.isEmpty ? nil : matcher
        }

        let from = form.from.isEmpty ? nil : form.from.map { ModeID(rawValue: $0) }
        return ModeRule(trigger: form.trigger, match: match, forSeconds: seconds, from: from, priority: priority)
    }
}

/// Starting points for new modes and the symbols the picker suggests.
public enum ModeTemplates {
    /// A minimal valid mode whose id is not in `existing`.
    public static func blank(avoiding existing: Set<ModeID>) -> ModeDefinition {
        var id = ModeID(rawValue: "new-mode")
        var counter = 2
        while existing.contains(id) {
            id = ModeID(rawValue: "new-mode-\(counter)")
            counter += 1
        }
        return ModeDefinition(
            id: id,
            name: "New mode",
            symbol: "circle",
            summary: "Describe when this mode applies and what should get your attention."
        )
    }

    /// SF Symbol names offered as suggestions. Any valid symbol name can still be typed.
    public static let suggestedSymbols: [String] = [
        "pencil.line", "hammer", "book", "person.2", "cup.and.saucer", "circle",
        "moon", "bolt", "brain.head.profile", "music.note", "paintbrush", "terminal",
        "envelope", "calendar", "gamecontroller", "graduationcap", "leaf", "flame",
    ]
}
