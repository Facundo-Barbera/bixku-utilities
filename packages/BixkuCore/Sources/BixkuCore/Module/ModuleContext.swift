import Foundation

/// Shared services the registry hands to modules (one environment per app).
///
/// Everything is injected so hosts and tests decide where data lives and what
/// the clock/logging do; nothing in the core touches fixed paths or globals.
public struct ModuleEnvironment: Sendable {
    public var eventBus: EventBus
    public var storage: any ModuleStorageFactory
    public var config: any ConfigProvider
    public var logSink: any LogSink
    public var minimumLogLevel: LogLevel
    public var clock: any BixkuClock

    public init(
        eventBus: EventBus = EventBus(),
        storage: any ModuleStorageFactory = InMemoryStorageFactory(),
        config: any ConfigProvider = StaticConfigProvider(),
        logSink: any LogSink = StandardErrorLogSink(),
        minimumLogLevel: LogLevel = .info,
        clock: any BixkuClock = SystemClock()
    ) {
        self.eventBus = eventBus
        self.storage = storage
        self.config = config
        self.logSink = logSink
        self.minimumLogLevel = minimumLogLevel
        self.clock = clock
    }

    func makeContext(for manifest: ModuleManifest) throws -> ModuleContext {
        ModuleContext(
            moduleID: manifest.id,
            eventBus: eventBus,
            storage: try storage.storage(for: manifest.id),
            settings: try storage.settings(for: manifest.id),
            config: config,
            moduleConfig: config.scoped(to: "modules.\(manifest.configKey)"),
            logger: BixkuLogger(category: manifest.id.rawValue, minimumLevel: minimumLogLevel, sink: logSink, clock: clock),
            clock: clock
        )
    }
}

/// Dependencies injected into a module when it starts.
public struct ModuleContext: Sendable {
    public let moduleID: ModuleID
    /// App-wide event bus. Prefer ``publish(_:)`` so the source is filled in.
    public let eventBus: EventBus
    /// Private, persistent key/value storage for this module only.
    public let storage: any ModuleStorage
    /// User-editable settings for this module (observable).
    public let settings: any SettingsStore
    /// Read-only app configuration (whole file).
    public let config: any ConfigProvider
    /// Read-only view of `[modules.<configKey>]`.
    public let moduleConfig: any ConfigProvider
    public let logger: BixkuLogger
    public let clock: any BixkuClock

    public init(
        moduleID: ModuleID,
        eventBus: EventBus,
        storage: any ModuleStorage,
        settings: any SettingsStore,
        config: any ConfigProvider,
        moduleConfig: any ConfigProvider,
        logger: BixkuLogger,
        clock: any BixkuClock
    ) {
        self.moduleID = moduleID
        self.eventBus = eventBus
        self.storage = storage
        self.settings = settings
        self.config = config
        self.moduleConfig = moduleConfig
        self.logger = logger
        self.clock = clock
    }

    /// Publishes `payload` on the event bus with this module as source.
    @discardableResult
    public func publish<Payload: BixkuEventPayload>(_ payload: Payload) -> BixkuEvent {
        eventBus.publish(payload, source: moduleID)
    }

    /// Subscribes to every event carrying `Payload`.
    public func subscribe<Payload: BixkuEventPayload>(
        to type: Payload.Type,
        buffering: StreamBuffering = .newest(EventBus.defaultBufferSize)
    ) -> AsyncStream<EventEnvelope<Payload>> {
        eventBus.subscribe(to: type, buffering: buffering)
    }
}
