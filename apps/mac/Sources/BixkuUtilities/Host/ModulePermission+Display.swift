import BixkuCore

/// User-facing explanation of the OS permissions modules can request.
extension ModulePermission {
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .network: return "Network"
        default: return rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: return "accessibility"
        case .notifications: return "bell"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "gearshape.2"
        case .network: return "network"
        default: return "lock"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: return "Read the focused app and window to understand what you are working on."
        case .notifications: return "Show notifications from this module."
        case .screenRecording: return "Read window titles of other apps."
        case .automation: return "Control other apps through Apple Events."
        case .network: return "Connect to remote services such as a language model provider."
        default: return "Required by this module."
        }
    }
}
