import Foundation

/// Engine of the Dock module: focus modes, activity classification and
/// notification triage.
///
/// Everything here is portable (Foundation only) so it builds and tests on Linux.
/// The macOS app provides the platform pieces (``ActivitySource``,
/// ``NotificationSource``, UI) and the LLM provider (``LLMClassifying``).
public enum BixkuDock {
    public static let version = "0.1.0"
}
