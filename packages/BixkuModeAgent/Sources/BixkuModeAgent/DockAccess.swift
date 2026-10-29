import BixkuDock
import Foundation

/// What the agent may read from, and do to, the running dock besides editing
/// modes. Implemented by the app on top of the Dock engine; tests use fakes.
public protocol ModeAgentDockAccess: Sendable {
    /// The active mode, if the engine is running.
    func activeMode() async -> ModeID?
    /// Switches the active mode. `reason` is recorded with the change.
    func setActiveMode(_ id: ModeID, reason: String) async throws
    /// Most recent classified activity, newest last.
    func recentActivity(limit: Int) async -> [ClassifiedActivity]
    /// Notifications currently held or queued for the digest.
    func heldNotifications() async -> [TriagedNotification]
    /// Delivers a held notification now. Throws if it is no longer held.
    func releaseNotification(_ id: UUID) async throws
}

/// Wraps text that came from outside the user's control (notification titles and
/// bodies, window titles, app names, URLs) so the model sees it as inert data.
///
/// The text is truncated, stripped of control characters and of anything that
/// could close or forge the envelope, then enclosed in `<untrusted_data>` tags
/// that the system prompt tells the model never to follow.
public enum UntrustedText {
    public static let openTag = "<untrusted_data>"
    public static let closeTag = "</untrusted_data>"

    public static func sanitize(_ text: String, maxLength: Int = 200) -> String {
        var cleaned = String(text.unicodeScalars.map { scalar -> Character in
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                return " "
            }
            return Character(scalar)
        })
        // Neutralize anything that looks like our tags or chat-role markup.
        cleaned = cleaned.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)) + "…" }
        return cleaned
    }

    public static func wrap(_ text: String, maxLength: Int = 200) -> String {
        openTag + sanitize(text, maxLength: maxLength) + closeTag
    }
}
