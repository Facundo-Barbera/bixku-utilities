import Foundation

/// One problem in a mode definition. `path` points at the offending field in JSON
/// terms (`transitions[0].forSeconds`).
public struct ModeValidationIssue: Sendable, Equatable, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(path): \(message)"
    }
}

/// Raised when a mode definition is invalid.
public struct ModeValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var modeID: ModeID
    public var issues: [ModeValidationIssue]

    public init(modeID: ModeID, issues: [ModeValidationIssue]) {
        self.modeID = modeID
        self.issues = issues
    }

    public var description: String {
        "Mode '\(modeID)' is invalid:\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
    }
}

/// Checks mode definitions for mistakes a human or an agent is likely to make.
///
/// Validation is structural (it never consults the running system). Cross-mode
/// references (``ModeRule/from``) are checked when `knownModes` is given.
public struct ModeValidator: Sendable {
    /// Maximum transition duration (one day).
    public static let maximumTriggerSeconds: TimeInterval = 86_400

    public init() {}

    /// All problems in `definition`; empty if it is valid.
    public func issues(in definition: ModeDefinition, knownModes: Set<ModeID>? = nil) -> [ModeValidationIssue] {
        var issues: [ModeValidationIssue] = []
        func report(_ path: String, _ message: String) {
            issues.append(ModeValidationIssue(path: path, message: message))
        }

        if definition.schemaVersion != ModeDefinition.currentSchemaVersion {
            report(
                "schemaVersion",
                "expected \(ModeDefinition.currentSchemaVersion), found \(definition.schemaVersion) (migrate first)"
            )
        }
        if !definition.id.isValid {
            report("id", "'\(definition.id)' is not a valid mode id (lowercase letters, digits and single hyphens, max 64)")
        }
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { report("name", "must not be empty") }
        if definition.name.count > 64 { report("name", "must be at most 64 characters") }
        if definition.symbol.trimmingCharacters(in: .whitespaces).isEmpty { report("symbol", "must not be empty") }
        if definition.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report("description", "must describe the mode's intent (it is shown to the user and to the agent)")
        }
        if definition.summary.count > 2_000 { report("description", "must be at most 2000 characters") }

        // Dock
        for (index, id) in definition.dock.prioritized.enumerated() {
            if let problem = Self.bundleIDProblem(id) { report("dock.prioritized[\(index)]", problem) }
        }
        for (index, pattern) in definition.dock.hidden.enumerated() {
            if let problem = AppPattern.problem(with: pattern) { report("dock.hidden[\(index)]", problem) }
        }
        for id in definition.dock.prioritized where AppPattern.matchesAny(definition.dock.hidden, bundleID: id) {
            report("dock", "'\(id)' is both prioritized and hidden")
        }

        // Attention
        validate(definition.attention.focus, at: "attention.focus", report: report)
        validate(definition.attention.distractions, at: "attention.distractions", report: report)
        let focus = definition.attention.focus
        let distractions = definition.attention.distractions
        for app in Set(focus.apps.map { $0.lowercased() }).intersection(distractions.apps.map { $0.lowercased() }) {
            report("attention", "app '\(app)' is both focus and distraction")
        }
        for category in Set(focus.categories).intersection(distractions.categories).sorted() {
            report("attention", "category '\(category)' is both focus and distraction")
        }

        // Notifications
        let policy = definition.notifications
        validate(policy.alwaysAllow, at: "notifications.alwaysAllow", allowEmpty: true, report: report)
        for (index, keyword) in policy.urgent.keywords.enumerated() where keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            report("notifications.urgent.keywords[\(index)]", "must not be empty")
        }
        for (index, rule) in policy.rules.enumerated() {
            let path = "notifications.rules[\(index)]"
            if rule.match.isEmpty {
                report("\(path).match", "matches nothing; add apps, categories or keywords")
            }
            validate(rule.match, at: "\(path).match", allowEmpty: true, report: report)
            if let activity = rule.whileActivity {
                if activity.isEmpty { report("\(path).whileActivity", "is empty; remove it or add criteria") }
                validate(activity, at: "\(path).whileActivity", allowEmpty: true, report: report)
            }
        }

        // Transitions
        for (index, rule) in definition.transitions.enumerated() {
            let path = "transitions[\(index)]"
            if !(rule.forSeconds > 0) {
                report("\(path).forSeconds", "must be greater than 0")
            } else if rule.forSeconds > Self.maximumTriggerSeconds {
                report("\(path).forSeconds", "must be at most \(Int(Self.maximumTriggerSeconds)) (one day)")
            }
            switch rule.trigger {
            case .activity:
                if let match = rule.match, !match.isEmpty {
                    validate(match, at: "\(path).match", report: report)
                } else {
                    report("\(path).match", "an 'activity' trigger needs a non-empty match")
                }
            case .idle:
                if rule.match != nil { report("\(path).match", "an 'idle' trigger must not have a match") }
            }
            if let from = rule.from {
                if from.isEmpty { report("\(path).from", "is empty; remove it to allow any mode") }
                for (fromIndex, id) in from.enumerated() {
                    if !id.isValid {
                        report("\(path).from[\(fromIndex)]", "'\(id)' is not a valid mode id")
                    } else if id == definition.id {
                        report("\(path).from[\(fromIndex)]", "a mode cannot transition from itself")
                    } else if let knownModes, !knownModes.contains(id) {
                        report("\(path).from[\(fromIndex)]", "unknown mode '\(id)'")
                    }
                }
            }
        }
        return issues
    }

    /// Throws ``ModeValidationError`` if `definition` has any issue.
    public func validate(_ definition: ModeDefinition, knownModes: Set<ModeID>? = nil) throws {
        let issues = issues(in: definition, knownModes: knownModes)
        if !issues.isEmpty { throw ModeValidationError(modeID: definition.id, issues: issues) }
    }

    private func validate(
        _ matcher: ActivityMatcher,
        at path: String,
        report: (String, String) -> Void
    ) {
        for (index, pattern) in matcher.apps.enumerated() {
            if let problem = AppPattern.problem(with: pattern) { report("\(path).apps[\(index)]", problem) }
        }
        for (index, keyword) in matcher.titleKeywords.enumerated() where keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            report("\(path).titleKeywords[\(index)]", "must not be empty")
        }
        for (index, host) in matcher.urlHosts.enumerated() {
            if host.isEmpty || host.contains("/") || host.contains(where: { $0.isWhitespace }) || host.contains(":") {
                report("\(path).urlHosts[\(index)]", "'\(host)' must be a bare host such as 'github.com'")
            }
        }
    }

    private func validate(
        _ matcher: NotificationMatcher,
        at path: String,
        allowEmpty: Bool,
        report: (String, String) -> Void
    ) {
        if !allowEmpty, matcher.isEmpty { report(path, "matches nothing") }
        for (index, pattern) in matcher.apps.enumerated() {
            if let problem = AppPattern.problem(with: pattern) { report("\(path).apps[\(index)]", problem) }
        }
        for (index, keyword) in matcher.keywords.enumerated() where keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            report("\(path).keywords[\(index)]", "must not be empty")
        }
    }

    private func validate(
        _ matcher: ActivityMatcher,
        at path: String,
        allowEmpty: Bool,
        report: (String, String) -> Void
    ) {
        if !allowEmpty, matcher.isEmpty { report(path, "matches nothing") }
        validate(matcher, at: path, report: report)
    }

    static func bundleIDProblem(_ id: String) -> String? {
        if id.isEmpty { return "bundle id is empty" }
        if id.contains("*") { return "'\(id)' must be an exact bundle id (wildcards are not allowed here)" }
        if id.contains(where: { $0.isWhitespace }) { return "'\(id)' contains whitespace" }
        return nil
    }
}
