import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

final class FailingActivitySource: ActivitySource, @unchecked Sendable {
    struct PermissionDenied: Error {}
    func start() async throws -> AsyncStream<ActivitySample> { throw PermissionDenied() }
    func stop() async {}
}

final class DockModuleTests: XCTestCase {
    private func environment(toml: String = "", clock: ManualClock, logs: InMemoryLogSink = InMemoryLogSink()) throws -> ModuleEnvironment {
        ModuleEnvironment(
            eventBus: EventBus(clock: clock),
            storage: InMemoryStorageFactory(),
            config: try StaticConfigProvider(toml: toml),
            logSink: logs,
            minimumLogLevel: .debug,
            clock: clock
        )
    }

    func testManifest() {
        let manifest = DockModule().manifest
        XCTAssertEqual(manifest.id, "online.bixku.dock")
        XCTAssertTrue(manifest.id.isValid)
        XCTAssertEqual(manifest.configKey, "dock")
        XCTAssertTrue(manifest.permissions.contains(.accessibility))
        XCTAssertEqual(manifest.ui.map(\.viewID), ["panel", "modes"])
    }

    func testRunsInsideTheRegistryWithConfigAndSources() async throws {
        let clock = ManualClock(now: t0)
        let env = try environment(toml: """
        [modules.dock]
        default_mode = "writing"
        tick_interval_seconds = 0
        minimum_mode_dwell_seconds = 0

        [modules.dock.privacy]
        redact_window_titles_for = ["com.example.Vault"]
        """, clock: clock)
        let activity = ManualActivitySource()
        let notifications = ManualNotificationSource()
        let module = DockModule(activitySource: activity, notificationSource: notifications)
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)

        let modeEvents = env.eventBus.subscribe(to: ModeChanged.self)
        let activityEvents = env.eventBus.subscribe(to: ActivityChanged.self)
        let report = try await registry.startAll()
        XCTAssertTrue(report.isSuccess, "\(report.failures)")

        let engine = try XCTUnwrap(module.engine)
        XCTAssertEqual(engine.state.mode.modeID, .writing)
        XCTAssertEqual(engine.configuration.redactedApps, ["com.example.Vault"])
        XCTAssertEqual(engine.configuration.tickInterval, nil)
        let initial = await collect(modeEvents, count: 1).first
        XCTAssertEqual(initial?.payload.modeID, "writing")
        XCTAssertEqual(initial?.source, "online.bixku.dock")

        XCTAssertTrue(activity.send(sample("com.example.Vault", title: "secret", at: 0)))
        let event = await collect(activityEvents, count: 1).first
        XCTAssertEqual(event?.source, "online.bixku.dock")
        XCTAssertNil(event?.payload.windowTitle)

        notifications.send(notification("com.apple.MobileSMS"))
        await eventually { engine.state.held.count == 1 }

        await registry.stopAll()
        XCTAssertNil(module.engine)
        XCTAssertFalse(activity.isStarted)
    }

    func testModesPersistInModuleStorageAndReloadTheEngine() async throws {
        let clock = ManualClock(now: t0)
        let env = try environment(clock: clock)
        let module = DockModule(configuration: DockConfiguration(tickInterval: nil))
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)
        try await registry.startAll()

        try await module.saveMode(makeMode("deep-work"))
        let engine = try XCTUnwrap(module.engine)
        await eventually { await engine.modes.contains("deep-work") }
        try await engine.setMode("deep-work")

        let keys = try await env.storage.storage(for: DockModule.moduleID).keys()
        XCTAssertEqual(keys, ["mode.deep-work"])

        // Deleting the active mode falls back to the default.
        try await module.deleteMode("deep-work")
        await eventually { engine.state.mode.modeID == .free }

        do {
            try await module.saveMode(makeMode("Bad Id"))
            XCTFail("expected an error")
        } catch {
            guard case ModeStoreError.invalid = error else { return XCTFail("\(error)") }
        }

        // Restarting loads what was saved.
        try await module.saveMode(makeMode("kept"))
        await registry.stopAll()
        do {
            try await module.saveMode(makeMode("late"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DockModuleError, .notRunning)
        }
        try await registry.startAll()
        let restarted = try XCTUnwrap(module.engine)
        let hasKept = await restarted.modes.contains("kept")
        XCTAssertTrue(hasKept)
        await registry.stopAll()
    }

    func testCommandsOverTheEventBus() async throws {
        let clock = ManualClock(now: t0)
        let env = try environment(clock: clock)
        let module = DockModule(configuration: DockConfiguration(tickInterval: nil))
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)
        try await registry.startAll()
        let engine = try XCTUnwrap(module.engine)
        let results = env.eventBus.subscribe(to: DockCommandResult.self)

        let save = DockCommand(.saveMode(makeMode("focus")))
        let invalid = DockCommand(.saveMode(makeMode("Not Valid")))
        let activate = DockCommand(.activateMode("focus", reason: "agent: deadline"))
        let delete = DockCommand(.deleteMode(.writing))
        for command in [save, invalid, activate, delete] {
            env.eventBus.publish(command, source: "online.bixku.mode-agent")
        }
        let received = await collect(results, count: 4).map(\.payload)
        XCTAssertEqual(received.map(\.commandID), [save.id, invalid.id, activate.id, delete.id])
        XCTAssertEqual(received.map(\.succeeded), [true, false, true, false])
        XCTAssertTrue(received[1].message?.contains("'Not Valid' is not a valid mode id") == true)
        XCTAssertEqual(received[3].message, ModeStoreError.cannotDeleteFactoryMode(.writing).description)
        XCTAssertEqual(engine.state.mode.modeID, "focus")
        XCTAssertEqual(engine.state.mode.activation, .automatic(reason: "agent: deadline"))

        // Commands are JSON-codable (they may be logged or come from an LLM tool call).
        let data = try JSONEncoder().encode(activate)
        XCTAssertEqual(try JSONDecoder().decode(DockCommand.self, from: data), activate)
        await registry.stopAll()
    }

    func testModesDirectoryFromConfig() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONModeStore.encode(makeMode("from-disk")).write(to: directory.appendingPathComponent("from-disk.json"))
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let clock = ManualClock(now: t0)
        let logs = InMemoryLogSink()
        let env = try environment(toml: """
        [modules.dock]
        modes_dir = "\(directory.path)"
        default_mode = "from-disk"
        """, clock: clock, logs: logs)
        let module = DockModule()
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)
        try await registry.startAll()
        let engine = try XCTUnwrap(module.engine)
        XCTAssertEqual(engine.state.mode.modeID, "from-disk")
        XCTAssertEqual(engine.state.modeIssues.map(\.document), ["broken"])
        XCTAssertTrue(logs.entries.contains { $0.level == .warning && $0.message.contains("broken") })
        await registry.stopAll()
    }

    func testFailingSourceIsLoggedAndSkipped() async throws {
        let clock = ManualClock(now: t0)
        let logs = InMemoryLogSink()
        let env = try environment(clock: clock, logs: logs)
        let module = DockModule(activitySource: FailingActivitySource(), configuration: DockConfiguration(tickInterval: nil))
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)
        let report = try await registry.startAll()
        XCTAssertTrue(report.isSuccess)
        XCTAssertNotNil(module.engine)
        XCTAssertTrue(logs.entries.contains { $0.level == .error && $0.message.contains("activity source") })
        await registry.stopAll()
    }

    func testLLMCanBeInstalledWhileRunning() async throws {
        let clock = ManualClock(now: t0)
        let env = try environment(clock: clock)
        let module = DockModule(configuration: DockConfiguration(tickInterval: nil))
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)
        try await registry.startAll()
        let engine = try XCTUnwrap(module.engine)

        await module.setLLM(activity: MockLLM.answering(.writing), notifications: nil)
        await engine.ingest(sample("com.example.Mystery", at: 0))
        XCTAssertEqual(engine.state.activity?.verdict.category, .writing)
        XCTAssertEqual(engine.state.activity?.verdict.source, .llm)
        await registry.stopAll()
    }

    func testConfigurationParsing() throws {
        let config = try StaticConfigProvider(toml: """
        [modules.dock]
        default_mode = "building"
        classify_notifications = false
        smoothing_window_seconds = 45
        idle_threshold_seconds = 300
        transition_grace_seconds = 10
        minimum_mode_dwell_seconds = 5
        tick_interval_seconds = 2.5
        llm_confidence_threshold = 0.75
        llm_max_requests_per_minute = 3

        [modules.dock.privacy]
        redact_window_titles_for = ["com.example.*"]

        [llm]
        request_timeout_seconds = 20
        """)
        let parsed = DockConfiguration(config: config.scoped(to: "modules.dock"), llmConfig: config.scoped(to: "llm"))
        XCTAssertEqual(parsed.defaultMode, .building)
        XCTAssertFalse(parsed.classifyNotifications)
        XCTAssertEqual(parsed.smoothing.window, 45)
        XCTAssertEqual(parsed.smoothing.idleThreshold, 300)
        XCTAssertEqual(parsed.transitionGrace, 10)
        XCTAssertEqual(parsed.minimumModeDwell, 5)
        XCTAssertEqual(parsed.tickInterval, .milliseconds(2_500))
        XCTAssertEqual(parsed.llm.confidenceThreshold, 0.75)
        XCTAssertEqual(parsed.llm.maxRequestsPerMinute, 3)
        XCTAssertEqual(parsed.llm.timeout, .seconds(20))
        XCTAssertEqual(parsed.redactedApps, ["com.example.*"])

        let defaults = DockConfiguration(config: StaticConfigProvider())
        XCTAssertEqual(defaults, DockConfiguration())
    }
}
