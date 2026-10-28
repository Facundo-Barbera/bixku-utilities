import Foundation
import Intents

/// Reads whether a Focus (Do Not Disturb, Work, ...) is on, through `INFocusStatusCenter`,
/// the only public API for it.
///
/// Limits, all imposed by macOS:
/// - It is a yes/no answer. Which Focus is active, its filters and its schedule are not exposed.
/// - It is read-only; an app cannot turn a Focus on or off.
/// - The user must allow it twice: the permission prompt, and the per-app "Focus Status"
///   switch in System Settings > Focus. Until then ``current()`` is ``Status/unknown``.
/// Needs `NSFocusStatusUsageDescription` in Info.plist.
struct FocusStatusReader {
    enum Status: Equatable {
        case focused
        case notFocused
        /// Not authorized, or the user does not share their Focus status with this app.
        case unknown
    }

    private var center: INFocusStatusCenter { INFocusStatusCenter.default }

    var isAuthorized: Bool {
        center.authorizationStatus == .authorized
    }

    /// Shows the system prompt the first time. Returns whether access was granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = center
        return await withCheckedContinuation { continuation in
            center.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func current() -> Status {
        guard isAuthorized, let isFocused = center.focusStatus.isFocused else { return .unknown }
        return isFocused ? .focused : .notFocused
    }
}
