import Foundation

/// Number of notifications of one category.
public struct CategoryCount: Codable, Sendable, Equatable {
    public var category: NotificationCategory
    public var count: Int

    public init(category: NotificationCategory, count: Int) {
        self.category = category
        self.count = count
    }
}

/// Summarized notifications of one app.
public struct DigestGroup: Codable, Sendable, Equatable {
    public var appBundleID: String?
    public var appName: String
    public var count: Int
    /// Per-category counts, largest first.
    public var categories: [CategoryCount]
    /// Titles of the most recent notifications (newest first).
    public var headlines: [String]
    /// Distinct conversation threads (0 if the app does not report threads).
    public var threadCount: Int

    public init(
        appBundleID: String?,
        appName: String,
        count: Int,
        categories: [CategoryCount],
        headlines: [String],
        threadCount: Int
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.count = count
        self.categories = categories
        self.headlines = headlines
        self.threadCount = threadCount
    }
}

/// What was held back while a mode was active, delivered when it ends.
public struct NotificationDigest: Codable, Sendable, Equatable {
    public var modeID: ModeID
    public var modeName: String
    /// When the mode started (or the first notification was held).
    public var start: Date
    public var end: Date
    /// `hold` notifications, delivered individually (oldest first).
    public var held: [TriagedNotification]
    /// `summarize` notifications, grouped by app (largest group first).
    public var groups: [DigestGroup]
    /// Notifications dropped because the held queue was full.
    public var droppedCount: Int
    /// One-paragraph text summary (deterministic, or from a ``DigestSummarizing``).
    public var summary: String

    public var summarizedCount: Int {
        groups.reduce(0) { $0 + $1.count }
    }

    public var totalCount: Int {
        held.count + summarizedCount + droppedCount
    }
}

/// Groups held notifications into a ``NotificationDigest``.
public struct DigestBuilder: Sendable {
    /// Headlines kept per app group.
    public var maxHeadlines: Int

    public init(maxHeadlines: Int = 3) {
        self.maxHeadlines = maxHeadlines
    }

    /// Builds a digest of `items` (any order), or `nil` if there is nothing to report.
    /// Items whose action is not `hold` or `summarize` are ignored.
    public func build(
        _ items: [TriagedNotification],
        modeID: ModeID,
        modeName: String,
        start: Date,
        end: Date,
        droppedCount: Int = 0
    ) -> NotificationDigest? {
        let deferred = items
            .filter { $0.decision.action.isDeferred }
            .sorted { ($0.notification.timestamp, $0.id.uuidString) < ($1.notification.timestamp, $1.id.uuidString) }
        guard !deferred.isEmpty || droppedCount > 0 else { return nil }

        let held = deferred.filter { $0.decision.action == .hold }
        let summarized = deferred.filter { $0.decision.action == .summarize }

        var order: [String] = []
        var buckets: [String: [TriagedNotification]] = [:]
        for item in summarized {
            let key = item.notification.appBundleID?.lowercased() ?? "name:" + item.notification.displayAppName
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        let groups = order.compactMap { key -> DigestGroup? in
            guard let items = buckets[key], let latest = items.last else { return nil }
            var counts: [NotificationCategory: Int] = [:]
            for item in items { counts[item.category, default: 0] += 1 }
            let categories = counts
                .map { CategoryCount(category: $0.key, count: $0.value) }
                .sorted { ($1.count, $0.category) < ($0.count, $1.category) }
            return DigestGroup(
                appBundleID: latest.notification.appBundleID,
                appName: latest.notification.displayAppName,
                count: items.count,
                categories: categories,
                headlines: items.reversed().prefix(maxHeadlines).map(\.notification.title),
                threadCount: Set(items.compactMap(\.notification.threadID)).count
            )
        }
        // Stable: larger groups first, then first-seen order.
        let ranked = groups.enumerated()
            .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
            .map(\.element)

        var digest = NotificationDigest(
            modeID: modeID,
            modeName: modeName,
            start: min(start, deferred.first?.notification.timestamp ?? start),
            end: end,
            held: held,
            groups: ranked,
            droppedCount: droppedCount,
            summary: ""
        )
        digest.summary = Self.summarize(digest)
        return digest
    }

    /// Deterministic text summary, e.g.
    /// "While in Writing (45m): 6 notifications. 2 held: Messages, Mail. Summarized: Slack ×3 (2 chat, 1 mention), News ×1."
    public static func summarize(_ digest: NotificationDigest) -> String {
        let total = digest.totalCount
        var parts = [
            "While in \(digest.modeName) (\(DurationFormat.short(digest.end.timeIntervalSince(digest.start)))): "
                + "\(total) notification\(total == 1 ? "" : "s")."
        ]
        if !digest.held.isEmpty {
            var apps: [String] = []
            for item in digest.held where !apps.contains(item.notification.displayAppName) {
                apps.append(item.notification.displayAppName)
            }
            parts.append("\(digest.held.count) held: \(apps.joined(separator: ", ")).")
        }
        if !digest.groups.isEmpty {
            let groups = digest.groups.map { group -> String in
                let detail = group.categories.count > 1
                    ? " (" + group.categories.map { "\($0.count) \($0.category)" }.joined(separator: ", ") + ")"
                    : ""
                return "\(group.appName) ×\(group.count)\(detail)"
            }
            parts.append("Summarized: \(groups.joined(separator: ", ")).")
        }
        if digest.droppedCount > 0 {
            parts.append("\(digest.droppedCount) more were dropped because the queue was full.")
        }
        return parts.joined(separator: " ")
    }
}
