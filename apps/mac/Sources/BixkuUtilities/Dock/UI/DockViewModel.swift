import AppKit
import BixkuDock
import Foundation
import SwiftUI

/// User-level Dock UI preferences.
protocol DockPreferences: AnyObject {
    /// Whether the always-on-top floating dock is shown. Off by default.
    var floatingDockEnabled: Bool { get set }
}

/// Keeps `DockPreferences` in the app's own `UserDefaults` domain. A plain
/// preference is enough here, and unlike module settings it is readable at launch,
/// before any view exists.
final class UserDefaultsDockPreferences: DockPreferences {
    private static let floatingDockKey = "dock.floatingDockEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var floatingDockEnabled: Bool {
        get { defaults.bool(forKey: Self.floatingDockKey) }
        set { defaults.set(newValue, forKey: Self.floatingDockKey) }
    }
}

/// An installed app the floating dock can launch.
struct DockAppItem: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String {
        bundleID
    }
}

enum DockAppResolver {
    /// The installed app with `bundleID`, or `nil` if it is not installed.
    static func resolve(_ bundleID: String) -> DockAppItem? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return DockAppItem(
            bundleID: bundleID,
            name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
            url: url
        )
    }
}

/// Feeds the Dock views from a `DockStateProviding` and forwards the user's actions.
@MainActor
final class DockViewModel: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    /// The apps the active mode prioritizes that are installed, in the mode's order.
    @Published private(set) var priorityApps: [DockAppItem] = []
    /// Whether the Dock module is running. The floating dock is never shown otherwise.
    @Published private(set) var isRunning = false
    @Published var isFloatingDockEnabled: Bool {
        didSet {
            guard isFloatingDockEnabled != oldValue else { return }
            preferences.floatingDockEnabled = isFloatingDockEnabled
        }
    }

    private let provider: any DockStateProviding
    private let preferences: any DockPreferences
    private let resolveApp: (String) -> DockAppItem?
    private var observation: Task<Void, Never>?

    init(
        provider: any DockStateProviding,
        preferences: any DockPreferences = UserDefaultsDockPreferences(),
        resolveApp: @escaping (String) -> DockAppItem? = DockAppResolver.resolve
    ) {
        self.provider = provider
        self.preferences = preferences
        self.resolveApp = resolveApp
        isFloatingDockEnabled = preferences.floatingDockEnabled
    }

    deinit {
        observation?.cancel()
    }

    // MARK: Lifecycle

    /// Starts following the provider. Idempotent.
    func start() {
        guard observation == nil else { return }
        isRunning = true
        observation = Task { [weak self, provider] in
            let stream = await provider.snapshots()
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        isRunning = false
    }

    // MARK: Derived state

    var modes: [Mode] {
        snapshot.catalog.modes
    }

    var activeMode: Mode? {
        snapshot.activeMode
    }

    /// `⌘1`…`⌘9` for the first nine modes.
    func shortcutKey(forModeAt index: Int) -> KeyEquivalent? {
        guard (0..<9).contains(index) else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    // MARK: Actions

    func select(_ id: ModeID) {
        let provider = provider
        Task { await provider.selectMode(id) }
    }

    func release(_ id: UUID) {
        let provider = provider
        Task { await provider.releaseNotification(id) }
    }

    func deliverDigest() {
        let provider = provider
        Task { await provider.deliverDigest() }
    }

    func open(_ app: DockAppItem) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Private

    private func apply(_ snapshot: DockSnapshot) {
        let previousMode = self.snapshot.activeMode?.definition.dock.prioritized
        self.snapshot = snapshot
        let prioritized = snapshot.activeMode?.definition.dock.prioritized
        if prioritized != previousMode {
            priorityApps = (prioritized ?? []).compactMap(resolveApp)
        }
    }
}
