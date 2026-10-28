import AppKit
import BixkuCore
import SwiftUI

/// Identifiers of the app's window scenes.
enum SceneID {
    static let settings = "settings"
    static let moduleWindow = "module-window"
}

@main
struct BixkuUtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Created at launch so Sparkle can run its scheduled checks (no-op in local builds).
    @StateObject private var updater = UpdaterController.shared

    var body: some Scene {
        MenuBarExtra("Bixku Utilities", systemImage: "square.grid.2x2") {
            MenuBarContentView(host: appDelegate.host)
        }
        .menuBarExtraStyle(.window)

        Window("Bixku Utilities Settings", id: SceneID.settings) {
            SettingsView(host: appDelegate.host)
        }
        .defaultSize(width: 760, height: 480)

        Window("Module", id: SceneID.moduleWindow) {
            ModuleWindowView(host: appDelegate.host)
        }
    }
}

/// Owns the `ModuleHost`: registers and starts the known modules at launch and
/// stops them before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var host: ModuleHost = ModuleHost.makeDefault()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = host
        Task { @MainActor in
            await host.bootstrap(KnownModules.all())
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard host.hasActiveModules else { return .terminateNow }
        let host = host
        Task { @MainActor in
            await host.stopAll()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
