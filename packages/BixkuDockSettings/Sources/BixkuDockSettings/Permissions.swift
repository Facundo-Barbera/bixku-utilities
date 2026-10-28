import Foundation

/// A system permission the Dock relies on.
public enum DockPermission: String, CaseIterable, Sendable, Identifiable {
    /// Needed to read the active app's window title and document.
    case accessibility
    /// Needed to deliver held notifications and end-of-mode digests.
    case notifications

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        }
    }

    public var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .notifications: return "bell.badge"
        }
    }

    /// Why the Dock asks for it, in the words shown to the user.
    public var rationale: String {
        switch self {
        case .accessibility:
            return "Lets the Dock see which app and window is in front, so it can tell what you are working on."
        case .notifications:
            return "Lets the Dock deliver notifications it held back and the digest when a mode ends."
        }
    }

    /// The System Settings pane for this permission (macOS 13 and later).
    public var settingsURLString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .notifications:
            return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
    }

    /// Opened when ``settingsURLString`` is not available (older System Settings).
    public var fallbackSettingsURLString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security"
        case .notifications:
            return "x-apple.systempreferences:com.apple.preference.notifications"
        }
    }

    public var settingsURL: URL? {
        URL(string: settingsURLString)
    }

    public var fallbackSettingsURL: URL? {
        URL(string: fallbackSettingsURLString)
    }
}

/// Whether the user has granted a permission.
public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    /// The system has not asked yet.
    case notDetermined
    /// The app could not find out.
    case unknown

    public var isGranted: Bool {
        self == .granted
    }

    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .notDetermined: return "Not requested yet"
        case .unknown: return "Unknown"
        }
    }
}
