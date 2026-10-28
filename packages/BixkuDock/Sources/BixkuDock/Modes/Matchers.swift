import Foundation

/// Matching of bundle identifier patterns.
///
/// A pattern is either an exact bundle id (`com.apple.Terminal`), a prefix wildcard
/// (`com.jetbrains.*` matches `com.jetbrains.intellij` but not `com.jetbrainsx`), or
/// `*` (any app). Comparison is case-insensitive.
public enum AppPattern {
    public static func matches(_ pattern: String, bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return false }
        let pattern = pattern.lowercased()
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            let prefix = pattern.dropLast(1) // keep the dot
            return bundleID.hasPrefix(prefix)
        }
        return bundleID == pattern
    }

    public static func matchesAny(_ patterns: [String], bundleID: String?) -> Bool {
        patterns.contains { matches($0, bundleID: bundleID) }
    }

    /// `nil` if `pattern` is well formed, otherwise why it is not.
    public static func problem(with pattern: String) -> String? {
        if pattern.isEmpty { return "app pattern is empty" }
        if pattern == "*" { return nil }
        if pattern.contains(where: { $0.isWhitespace }) { return "app pattern '\(pattern)' contains whitespace" }
        let body = pattern.hasSuffix(".*") ? String(pattern.dropLast(2)) : pattern
        if body.isEmpty || body.contains("*") {
            return "app pattern '\(pattern)' may only use '*' alone or as a trailing '.*'"
        }
        return nil
    }
}

/// Matching of URL hosts: `github.com` matches `github.com` and any subdomain
/// (`gist.github.com`), but not `notgithub.com`.
public enum HostPattern {
    public static func matches(_ pattern: String, host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        var pattern = pattern.lowercased()
        if pattern.hasPrefix(".") { pattern.removeFirst() }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}

/// How specifically a matcher matched; app/title/host hits beat category hits.
public enum MatchStrength: Int, Comparable, Sendable {
    case category = 1
    case specific = 2

    public static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Selects activities. Criteria are alternatives: a sample matches if any app
/// pattern, category, title keyword or URL host matches. An empty matcher matches
/// nothing.
public struct ActivityMatcher: Codable, Sendable, Equatable {
    /// Bundle id patterns (see ``AppPattern``).
    public var apps: [String]
    public var categories: [ActivityCategory]
    /// Case-insensitive substrings of the window title or document.
    public var titleKeywords: [String]
    /// URL hosts (see ``HostPattern``).
    public var urlHosts: [String]

    public init(
        apps: [String] = [],
        categories: [ActivityCategory] = [],
        titleKeywords: [String] = [],
        urlHosts: [String] = []
    ) {
        self.apps = apps
        self.categories = categories
        self.titleKeywords = titleKeywords
        self.urlHosts = urlHosts
    }

    private enum CodingKeys: String, CodingKey {
        case apps, categories, titleKeywords, urlHosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
        categories = try container.decodeIfPresent([ActivityCategory].self, forKey: .categories) ?? []
        titleKeywords = try container.decodeIfPresent([String].self, forKey: .titleKeywords) ?? []
        urlHosts = try container.decodeIfPresent([String].self, forKey: .urlHosts) ?? []
    }

    public var isEmpty: Bool {
        apps.isEmpty && categories.isEmpty && titleKeywords.isEmpty && urlHosts.isEmpty
    }

    /// The strongest way `sample` (classified as `category`) matches, or `nil`.
    public func match(_ sample: ActivitySample, category: ActivityCategory?) -> MatchStrength? {
        if AppPattern.matchesAny(apps, bundleID: sample.appBundleID) { return .specific }
        if let host = sample.urlHost, urlHosts.contains(where: { HostPattern.matches($0, host: host) }) {
            return .specific
        }
        if !titleKeywords.isEmpty {
            let haystack = [sample.windowTitle, sample.document].compactMap { $0 }.joined(separator: "\n")
            if titleKeywords.contains(where: { !$0.isEmpty && haystack.localizedCaseInsensitiveContains($0) }) {
                return .specific
            }
        }
        if let category, categories.contains(category) { return .category }
        return nil
    }

    public func matches(_ sample: ActivitySample, category: ActivityCategory?) -> Bool {
        match(sample, category: category) != nil
    }
}

/// Selects notifications. Criteria are alternatives (any match). An empty matcher
/// matches nothing.
public struct NotificationMatcher: Codable, Sendable, Equatable {
    /// Bundle id patterns of the sending app (see ``AppPattern``).
    public var apps: [String]
    public var categories: [NotificationCategory]
    /// Case-insensitive substrings of the title, subtitle or body.
    public var keywords: [String]

    public init(apps: [String] = [], categories: [NotificationCategory] = [], keywords: [String] = []) {
        self.apps = apps
        self.categories = categories
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey {
        case apps, categories, keywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
        categories = try container.decodeIfPresent([NotificationCategory].self, forKey: .categories) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }

    public var isEmpty: Bool {
        apps.isEmpty && categories.isEmpty && keywords.isEmpty
    }

    public func matches(_ notification: IncomingNotification, category: NotificationCategory) -> Bool {
        if AppPattern.matchesAny(apps, bundleID: notification.appBundleID) { return true }
        if categories.contains(category) { return true }
        if !keywords.isEmpty {
            let text = notification.searchableText
            return keywords.contains { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
        }
        return false
    }
}
