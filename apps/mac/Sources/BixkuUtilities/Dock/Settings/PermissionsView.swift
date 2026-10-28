import AppKit
import BixkuDockSettings
import SwiftUI
import UserNotifications

/// Reads the current state of the permissions the Dock needs and opens the System
/// Settings panes where the user grants them.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [DockPermission: PermissionStatus] = [:]

    func status(of permission: DockPermission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    func refresh() async {
        statuses[.accessibility] = AccessibilityPermission.isTrusted ? .granted : .denied
        statuses[.notifications] = await notificationStatus()
    }

    /// Opens the System Settings pane for `permission`.
    func openSettings(for permission: DockPermission) {
        if let url = permission.settingsURL, NSWorkspace.shared.open(url) { return }
        if let fallback = permission.fallbackSettingsURL {
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Shows the system's Accessibility prompt (which links to System Settings).
    func requestAccessibility() {
        AccessibilityPermission.requestPrompt()
    }

    /// Asks for notification permission (only possible while the system has not asked yet).
    func requestNotifications() async {
        guard Self.canUseNotificationCenter else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    /// `UNUserNotificationCenter` raises an exception in a process that is not an
    /// app bundle (for example a bare `swift run` binary).
    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func notificationStatus() async -> PermissionStatus {
        guard Self.canUseNotificationCenter else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}

/// The "Permissions" tab: one row per permission with its state and a button that
/// opens the matching pane of System Settings.
struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        Form {
            Section {
                ForEach(DockPermission.allCases) { permission in
                    PermissionRow(permission: permission, model: model)
                }
            } footer: {
                Text("Granting a permission happens in System Settings. This screen updates when you come back to the app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct PermissionRow: View {
    let permission: DockPermission
    @ObservedObject var model: PermissionsModel

    var body: some View {
        let status = model.status(of: permission)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(permission.title, systemImage: permission.symbol)
                    .font(.headline)
                Spacer()
                Label(status.label, systemImage: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(status.isGranted ? Color.green : Color.orange)
            }
            Text(permission.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !status.isGranted {
                    switch permission {
                    case .accessibility:
                        Button("Request…") { model.requestAccessibility() }
                    case .notifications where status == .notDetermined:
                        Button("Request…") { Task { await model.requestNotifications() } }
                    case .notifications:
                        EmptyView()
                    }
                }
                Button("Open System Settings") { model.openSettings(for: permission) }
            }
        }
        .padding(.vertical, 4)
    }
}
