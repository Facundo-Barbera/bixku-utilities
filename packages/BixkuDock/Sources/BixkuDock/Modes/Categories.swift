import Foundation

/// What kind of work the foreground activity is.
public enum ActivityCategory: String, Codable, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    /// IDEs, terminals, code hosting, documentation for developers.
    case code
    /// Editors, word processors, note taking.
    case writing
    /// General web browsing that is not obviously anything else.
    case browsing
    /// Chat, email, social messaging.
    case communication
    /// Video, music, streaming, games.
    case media
    /// Video calls and conferencing.
    case meeting
    /// Anything unclassified.
    case other

    public var description: String {
        rawValue
    }

    public static func < (lhs: ActivityCategory, rhs: ActivityCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coarse kind of a user notification, used by notification policies.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    /// A message addressed to the user (DM, SMS, iMessage).
    case directMessage = "direct-message"
    /// The user was mentioned in a shared channel.
    case mention
    /// Messages in shared channels / groups.
    case chat
    case email
    /// Calendar alerts and meeting reminders.
    case calendar
    /// CI, builds, deploys, monitoring alerts.
    case build
    /// OS and device notifications (battery, updates).
    case system
    /// Social networks and feeds.
    case social
    /// Marketing and promotional content.
    case promotion
    case other

    public var description: String {
        rawValue
    }

    public static func < (lhs: NotificationCategory, rhs: NotificationCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
