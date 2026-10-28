import BixkuDock
import Foundation

/// What the system notification for an end-of-mode digest says. Pure data, so the wording
/// and limits are tested here; `DigestNotifier` (apps/mac) hands it to `UserNotifications`.
///
/// Titles come from other apps' notifications, so every piece is sanitized and bounded.
public struct DigestNotificationContent: Equatable, Sendable {
    public static let maxTitleLength = 80
    public static let maxBodyLength = 400
    /// App groups listed in the body before "and N more".
    public static let maxListedGroups = 3
    /// Held apps listed in the body.
    public static let maxListedHeldApps = 4

    /// Unique per mode run, so a later digest never replaces an earlier unread one.
    public var identifier: String
    /// Groups the digests of one mode together in Notification Center.
    public var threadIdentifier: String
    public var title: String
    public var body: String

    /// `nil` when the digest has nothing to report.
    public init?(digest: NotificationDigest) {
        guard digest.totalCount > 0 else { return nil }
        let total = digest.totalCount
        let modeName = NotifyTextSanitizer.clean(digest.modeName, maxLength: 40)
        identifier = "online.bixku.dock.digest.\(digest.modeID.rawValue).\(Int(digest.end.timeIntervalSince1970))"
        threadIdentifier = "online.bixku.dock.digest.\(digest.modeID.rawValue)"
        title = NotifyTextSanitizer.clean(
            "\(total) notification\(total == 1 ? "" : "s") while in \(modeName)",
            maxLength: Self.maxTitleLength
        )

        var lines: [String] = []
        if !digest.held.isEmpty {
            var apps: [String] = []
            for item in digest.held where !apps.contains(item.notification.displayAppName) {
                apps.append(item.notification.displayAppName)
            }
            let listed = apps.prefix(Self.maxListedHeldApps).map { NotifyTextSanitizer.clean($0, maxLength: 30) }
            let more = apps.count - listed.count
            lines.append("Held: " + listed.joined(separator: ", ") + (more > 0 ? " and \(more) more" : ""))
        }
        for group in digest.groups.prefix(Self.maxListedGroups) {
            let name = NotifyTextSanitizer.clean(group.appName, maxLength: 30)
            var line = "\(name) ×\(group.count)"
            if let headline = group.headlines.first {
                line += ": " + NotifyTextSanitizer.clean(headline, maxLength: 60)
            }
            lines.append(line)
        }
        if digest.groups.count > Self.maxListedGroups {
            lines.append("and \(digest.groups.count - Self.maxListedGroups) more apps")
        }
        if digest.droppedCount > 0 {
            lines.append("\(digest.droppedCount) more were dropped (queue full)")
        }
        body = NotifyTextSanitizer.clean(
            lines.joined(separator: "\n"), maxLength: Self.maxBodyLength, allowNewlines: true
        )
    }
}
