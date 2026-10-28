import Foundation

/// A user notification delivered by some app, as observed by a ``NotificationSource``.
public struct IncomingNotification: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var appBundleID: String?
    public var appName: String?
    public var title: String
    public var subtitle: String?
    public var body: String?
    /// Kind of notification, if the source knows it. When `nil`, the triage infers it
    /// with ``NotificationCategorizer``.
    public var category: NotificationCategory?
    /// The OS marked it time-sensitive or critical.
    public var isTimeSensitive: Bool
    /// Conversation / thread identifier, used to group digests.
    public var threadID: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        appBundleID: String?,
        appName: String? = nil,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        category: NotificationCategory? = nil,
        isTimeSensitive: Bool = false,
        threadID: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.isTimeSensitive = isTimeSensitive
        self.threadID = threadID
        self.timestamp = timestamp
    }

    /// Title, subtitle and body joined, for keyword matching.
    public var searchableText: String {
        [title, subtitle, body].compactMap { $0 }.joined(separator: "\n")
    }

    /// Best name to show for the sending app.
    public var displayAppName: String {
        appName ?? appBundleID ?? "Unknown app"
    }
}
