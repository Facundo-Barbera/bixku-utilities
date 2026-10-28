import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle 2 auto-updates (`SPUStandardUpdaterController`).
///
/// Only active when the bundle's Info.plist carries an https `SUFeedURL` and a valid `SUPublicEDKey`; release
/// builds get them from `apps/mac/release/render-plist.py` (see docs/release.md). Local builds (`swift build`)
/// have no Info.plist values, so the updater stays disabled — no errors, no prompts — and
/// "Check for Updates…" is disabled. The other Sparkle settings (`SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`, …) also live in the Info.plist.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// UserDefaults key: also receive the `beta` channel of the appcast.
    nonisolated static let betaDefaultsKey = "BixkuReceiveBetaUpdates"

    /// Is there a usable feed URL and public key? Otherwise no Sparkle controller is created.
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false
    @Published var receiveBetas: Bool {
        didSet { UserDefaults.standard.set(receiveBetas, forKey: Self.betaDefaultsKey) }
    }

    private let delegate = UpdaterDelegate()
    private var controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    private init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        isConfigured = Self.isUsable(feedURL: info["SUFeedURL"], publicKey: info["SUPublicEDKey"])
        receiveBetas = UserDefaults.standard.bool(forKey: Self.betaDefaultsKey)
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        self.controller = controller
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// An https feed URL and an EdDSA public key (base64 of 32 bytes), with no unexpanded `$(VAR)` left.
    nonisolated static func isUsable(feedURL: Any?, publicKey: Any?) -> Bool {
        guard let feed = (feedURL as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = (publicKey as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              feed.lowercased().hasPrefix("https://"), !feed.contains("$("),
              let data = Data(base64Encoded: key), data.count == 32
        else { return false }
        return true
    }

    func checkForUpdates() {
        // Menu-bar app (LSUIElement): bring the update window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle delegates. Separate `NSObject` because Sparkle keeps its delegates weakly and calls them on the main thread.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Allowed channels: stable (implicit) plus `beta` when the user opted in or already runs a prerelease.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let wantsBetas = UserDefaults.standard.bool(forKey: UpdaterController.betaDefaultsKey)
        return (wantsBetas || version.contains("-")) ? ["beta"] : []
    }

    /// Background (menu-bar) apps should not steal focus for scheduled update alerts.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// "Check for Updates…" (and the beta toggle) for the menu-bar menu.
struct CheckForUpdatesMenuItems: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        if updater.isConfigured {
            Toggle("Receive Beta Updates", isOn: $updater.receiveBetas)
        }
    }
}
