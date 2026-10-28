import BixkuCore
import Foundation
import SwiftUI

/// Bridges the portable `ModuleRegistry` to SwiftUI: registers the known modules,
/// starts/stops them, mirrors their state for the UI and resolves module views.
@MainActor
final class ModuleHost: ObservableObject {
    struct ModuleInfo: Identifiable, Equatable {
        let manifest: ModuleManifest
        var state: ModuleState

        var id: ModuleID {
            manifest.id
        }
    }

    /// Registered modules in registration order, with their current state.
    @Published private(set) var modules: [ModuleInfo] = []
    /// Last error worth showing to the user (start failures, invalid graph...).
    @Published private(set) var lastError: String?
    /// The view shown by the shared module window.
    @Published var presentedWindow: ModuleViewReference?

    let registry: ModuleRegistry
    private let logger: BixkuLogger
    private var providers: [ModuleID: any ModuleUIProvider] = [:]
    private var stateTask: Task<Void, Never>?

    init(environment: ModuleEnvironment) {
        registry = ModuleRegistry(environment: environment)
        logger = BixkuLogger(
            category: "host",
            minimumLevel: environment.minimumLogLevel,
            sink: environment.logSink,
            clock: environment.clock
        )
        let changes = registry.stateChanges()
        stateTask = Task { [weak self] in
            for await change in changes {
                self?.apply(change.payload)
            }
        }
    }

    var environment: ModuleEnvironment {
        registry.environment
    }

    var hasActiveModules: Bool {
        modules.contains { $0.state.isActive }
    }

    // MARK: Lifecycle

    /// Registers `registrations` (skipping modules disabled in the config) and starts them.
    func bootstrap(_ registrations: [ModuleRegistration]) async {
        for registration in registrations {
            let manifest = registration.module.manifest
            if environment.config.bool("modules.\(manifest.configKey).enabled") == false {
                logger.info("Module \(manifest.id) is disabled in the configuration")
                continue
            }
            await register(registration)
        }
        await startAll()
    }

    func register(_ registration: ModuleRegistration) async {
        let manifest = registration.module.manifest
        do {
            try await registry.register(registration.module)
            providers[manifest.id] = registration.ui
            if !modules.contains(where: { $0.id == manifest.id }) {
                modules.append(ModuleInfo(manifest: manifest, state: .registered))
            }
        } catch {
            report(error, context: "Could not register \(manifest.displayName)")
        }
    }

    func startAll() async {
        do {
            let result = try await registry.startAll()
            let failures = result.failures.sorted { $0.key < $1.key }
            for (id, reason) in failures {
                logger.error("Module \(id) failed to start: \(reason)")
            }
            if let first = failures.first {
                lastError = "\(first.key): \(first.value)"
            }
        } catch {
            report(error, context: "Could not start modules")
        }
    }

    func stopAll() async {
        await registry.stopAll()
    }

    func start(_ id: ModuleID) async {
        do {
            try await registry.start(id)
        } catch {
            report(error, context: "Could not start \(id)")
        }
    }

    func stop(_ id: ModuleID) async {
        do {
            try await registry.stop(id)
        } catch {
            report(error, context: "Could not stop \(id)")
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: Views

    /// Views of `kind` contributed by running modules (or all modules for `.settings`).
    func items(of kind: ModuleUIKind) -> [ModuleViewItem] {
        modules
            .filter { kind == .settings || $0.state.isRunning }
            .flatMap { info in
                info.manifest.ui
                    .filter { $0.kind == kind }
                    .map { ModuleViewItem(moduleID: info.id, descriptor: $0) }
            }
    }

    func settingsItems(for id: ModuleID) -> [ModuleViewItem] {
        items(of: .settings).filter { $0.moduleID == id }
    }

    func item(for reference: ModuleViewReference) -> ModuleViewItem? {
        guard let info = modules.first(where: { $0.id == reference.moduleID }),
            let descriptor = info.manifest.ui.first(where: { $0.viewID == reference.viewID })
        else { return nil }
        return ModuleViewItem(moduleID: info.id, descriptor: descriptor)
    }

    func view(for item: ModuleViewItem) -> AnyView {
        let context = ModuleUIContext(
            host: self,
            moduleID: item.moduleID,
            settings: try? environment.storage.settings(for: item.moduleID)
        )
        if let view = providers[item.moduleID]?.makeView(for: item.descriptor, context: context) {
            return view
        }
        return AnyView(
            Text("This view is not available.")
                .foregroundStyle(.secondary)
        )
    }

    // MARK: Private

    private func apply(_ change: ModuleStateChanged) {
        guard let index = modules.firstIndex(where: { $0.id == change.moduleID }) else { return }
        modules[index].state = change.state
    }

    private func report(_ error: Error, context: String) {
        let message = "\(context): \(error)"
        logger.error(message)
        lastError = message
    }
}

extension ModuleHost {
    /// The production host: file-backed storage under Application Support and the
    /// optional user config file. No paths are hard-coded beyond the app's own folder.
    static func makeDefault() -> ModuleHost {
        let locations = AppLocations.resolve()
        let config = locations.loadConfig()
        let level = config.string("general.log_level").flatMap(LogLevel.init(name:)) ?? .info
        let environment = ModuleEnvironment(
            eventBus: EventBus(),
            storage: FileStorageFactory(rootDirectory: locations.dataDirectory(config: config).appendingPathComponent("modules", isDirectory: true)),
            config: config,
            logSink: StandardErrorLogSink(),
            minimumLogLevel: level,
            clock: SystemClock()
        )
        return ModuleHost(environment: environment)
    }
}

/// Where the app keeps its files. Resolved at runtime from the user's own
/// Application Support directory; overridable with environment variables.
struct AppLocations {
    /// `~/Library/Application Support/BixkuUtilities` (resolved by the OS).
    let supportDirectory: URL
    /// `$BIXKU_CONFIG`, or `config.toml` inside `supportDirectory`.
    let configFile: URL

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppLocations {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let support = base.appendingPathComponent("BixkuUtilities", isDirectory: true)
        let configFile: URL
        if let override = environment["BIXKU_CONFIG"], !override.isEmpty {
            configFile = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            configFile = support.appendingPathComponent("config.toml", isDirectory: false)
        }
        return AppLocations(supportDirectory: support, configFile: configFile)
    }

    /// The parsed config file, or an empty config if it is missing or invalid.
    func loadConfig() -> StaticConfigProvider {
        do {
            return try StaticConfigProvider(contentsOf: configFile)
        } catch {
            FileHandle.standardError.write(Data("Ignoring invalid config file \(configFile.lastPathComponent): \(error)\n".utf8))
            return StaticConfigProvider()
        }
    }

    /// `general.data_dir` from the config (with `~` expanded), else `supportDirectory`.
    func dataDirectory(config: any ConfigProvider) -> URL {
        if let custom = config.string("general.data_dir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return supportDirectory
    }
}
