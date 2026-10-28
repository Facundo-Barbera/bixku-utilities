import BixkuCore
import Foundation

public enum DockModuleError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRunning

    public var description: String {
        "The Dock module is not running"
    }
}

/// The Dock as a ``BixkuModule``: wires the mode store, classifiers, triage and
/// ``DockEngine`` from the ``ModuleContext`` and the injected platform pieces.
///
/// The host (macOS app) constructs it with its ``ActivitySource`` /
/// ``NotificationSource`` and, optionally, LLM providers; everything else comes from
/// the context:
///
/// - **Modes** are stored in the injected `modeStore`, else in
///   `[modules.dock] modes_dir` if configured, else in the module's own storage.
/// - **Configuration** comes from `[modules.dock]` and `[llm]` (see
///   ``DockConfiguration/init(config:llmConfig:)``) unless `configuration` is given.
/// - A source whose `start()` throws (missing permission) is logged and skipped.
public final class DockModule: BixkuModule, @unchecked Sendable {
    public static let moduleID: ModuleID = "online.bixku.dock"

    public static let defaultManifest = ModuleManifest(
        id: moduleID,
        displayName: "Dock",
        summary: "Focus modes that follow what you are doing and hold back distracting notifications.",
        version: SemanticVersion(string: BixkuDock.version) ?? "0.1.0",
        capabilities: [.activityMonitoring, .notificationProcessing, .languageModel, .menuBar, .eventProducer],
        permissions: [.accessibility, .screenRecording, .notifications],
        ui: [
            ModuleUIDescriptor(viewID: "panel", title: "Dock", systemImage: "dock.rectangle", kind: .menuBarPanel),
            ModuleUIDescriptor(viewID: "modes", title: "Modes", systemImage: "square.stack", kind: .settings),
        ]
    )

    public let manifest: ModuleManifest

    private struct Running {
        var engine: DockEngine
        var store: any ModeStore
        var classifier: HybridClassifier
        var triage: NotificationTriage
        var watcher: Task<Void, Never>
        var commands: Task<Void, Never>
    }

    private let activitySource: (any ActivitySource)?
    private let notificationSource: (any NotificationSource)?
    private let injectedStore: (any ModeStore)?
    private let configurationOverride: DockConfiguration?
    private let summarizer: (any DigestSummarizing)?
    private let llms: Locked<(activity: (any LLMClassifying)?, notifications: (any LLMNotificationTriaging)?)>
    private let running = Locked<Running?>(nil)

    public init(
        activitySource: (any ActivitySource)? = nil,
        notificationSource: (any NotificationSource)? = nil,
        llm: (any LLMClassifying)? = nil,
        notificationLLM: (any LLMNotificationTriaging)? = nil,
        summarizer: (any DigestSummarizing)? = nil,
        modeStore: (any ModeStore)? = nil,
        configuration: DockConfiguration? = nil,
        manifest: ModuleManifest = DockModule.defaultManifest
    ) {
        self.activitySource = activitySource
        self.notificationSource = notificationSource
        self.summarizer = summarizer
        injectedStore = modeStore
        configurationOverride = configuration
        llms = Locked((llm, notificationLLM))
        self.manifest = manifest
    }

    /// The running engine (`nil` while stopped).
    public var engine: DockEngine? {
        running.withLock { $0?.engine }
    }

    /// The mode store in use (`nil` while stopped).
    public var modeStore: (any ModeStore)? {
        running.withLock { $0?.store }
    }

    public func start(context: ModuleContext) async throws {
        await stop()
        let configuration = configurationOverride
            ?? DockConfiguration(config: context.moduleConfig, llmConfig: context.config.scoped(to: "llm"))
        let store = injectedStore ?? Self.makeStore(context: context)
        let catalog = try await store.load()
        for issue in catalog.issues {
            context.logger.warning("Ignoring mode document: \(issue)")
        }
        if !catalog.contains(configuration.defaultMode) {
            context.logger.warning("default_mode '\(configuration.defaultMode)' does not exist; using '\(DefaultModes.fallbackModeID)'")
        }

        let llm = llms.withLock { $0 }
        let classifier = HybridClassifier(llm: llm.activity, policy: configuration.llm, clock: context.clock)
        let triage = NotificationTriage(
            llm: configuration.classifyNotifications ? llm.notifications : nil,
            policy: configuration.llm,
            clock: context.clock
        )
        let engine = DockEngine(
            catalog: catalog,
            classifier: classifier,
            triage: triage,
            summarizer: summarizer,
            configuration: configuration,
            eventBus: context.eventBus,
            source: context.moduleID,
            clock: context.clock
        )

        let activity = await Self.openActivity(activitySource, logger: context.logger)
        let notifications = await Self.openNotifications(notificationSource, logger: context.logger)
        await engine.start(activity: activity, notifications: notifications)

        let changes = store.changes()
        let watcher = Task { [weak engine] in
            for await catalog in changes {
                await engine?.updateCatalog(catalog)
            }
        }
        let commandStream = context.subscribe(to: DockCommand.self, buffering: .unbounded)
        let commands = Task { [weak self] in
            for await envelope in commandStream {
                guard let self else { return }
                let result = await self.execute(envelope.payload, engine: engine, store: store)
                context.publish(result)
            }
        }
        running.withLock {
            $0 = Running(engine: engine, store: store, classifier: classifier, triage: triage, watcher: watcher, commands: commands)
        }
        context.logger.info("Dock started in mode '\(engine.state.mode.modeID)' with \(catalog.modes.count) modes")
    }

    public func stop() async {
        guard let current = running.withLock({ state -> Running? in
            defer { state = nil }
            return state
        }) else { return }
        current.watcher.cancel()
        current.commands.cancel()
        await current.engine.stop()
        await activitySource?.stop()
        await notificationSource?.stop()
    }

    // MARK: Commands for the UI and the mode agent

    /// Installs (or removes) LLM providers, also while running.
    public func setLLM(activity: (any LLMClassifying)?, notifications: (any LLMNotificationTriaging)?) async {
        llms.withLock { $0 = (activity, notifications) }
        guard let current = running.withLock({ $0 }) else { return }
        await current.classifier.setLLM(activity)
        let useForNotifications = current.engine.configuration.classifyNotifications
        await current.triage.setLLM(useForNotifications ? notifications : nil)
    }

    /// Saves a mode through the store; the engine uses it as soon as this returns.
    public func saveMode(_ definition: ModeDefinition) async throws {
        guard let current = running.withLock({ $0 }) else { throw DockModuleError.notRunning }
        try await current.store.save(definition)
        await current.engine.updateCatalog(try await current.store.load())
    }

    /// Deletes a user mode (or override) through the store.
    public func deleteMode(_ id: ModeID) async throws {
        guard let current = running.withLock({ $0 }) else { throw DockModuleError.notRunning }
        try await current.store.delete(id)
        await current.engine.updateCatalog(try await current.store.load())
    }

    func execute(_ command: DockCommand, engine: DockEngine, store: any ModeStore) async -> DockCommandResult {
        do {
            switch command.action {
            case .activateMode(let id, let reason):
                try await engine.activateMode(id, reason: reason)
            case .saveMode(let definition):
                try await store.save(definition)
                await engine.updateCatalog(try await store.load())
            case .deleteMode(let id):
                try await store.delete(id)
                await engine.updateCatalog(try await store.load())
            }
            return DockCommandResult(commandID: command.id, succeeded: true)
        } catch {
            return DockCommandResult(commandID: command.id, succeeded: false, message: String(describing: error))
        }
    }

    // MARK: Helpers

    static func makeStore(context: ModuleContext) -> any ModeStore {
        if let path = context.moduleConfig.string("modes_dir"), !path.isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            return JSONModeStore(directory: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return JSONModeStore(backend: StorageModeBackend(storage: context.storage))
    }

    private static func openActivity(_ source: (any ActivitySource)?, logger: BixkuLogger) async -> AsyncStream<ActivitySample>? {
        guard let source else { return nil }
        do {
            return try await source.start()
        } catch {
            logger.error("Could not start the activity source: \(error)")
            return nil
        }
    }

    private static func openNotifications(_ source: (any NotificationSource)?, logger: BixkuLogger) async -> AsyncStream<IncomingNotification>? {
        guard let source else { return nil }
        do {
            return try await source.start()
        } catch {
            logger.error("Could not start the notification source: \(error)")
            return nil
        }
    }
}
