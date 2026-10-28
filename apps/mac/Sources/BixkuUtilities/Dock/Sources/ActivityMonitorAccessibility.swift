import AppKit
import ApplicationServices

/// The Accessibility (AX) permission the activity monitor needs to read window titles.
/// Without it the monitor still reports the frontmost app and idle time.
enum AccessibilityPermission {
    /// Whether this process is allowed to use the Accessibility API. Never prompts.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that leads to System Settings when not yet trusted.
    /// Returns the current trust state (the user's answer arrives later: poll `isTrusted`).
    @discardableResult
    static func requestPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Opens System Settings at Privacy & Security > Accessibility.
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AccessibilityWindowReader {
    /// Title of the focused window of a process, or `nil` when there is none, the app does
    /// not expose it, or the permission is missing. Blocking IPC to the target app, so call
    /// it off the main thread; a short messaging timeout keeps a hung app from stalling us.
    static func focusedWindowTitle(processID: pid_t, timeout: Float = 0.25) -> String? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, timeout)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }
        return titleRef as? String
    }
}
