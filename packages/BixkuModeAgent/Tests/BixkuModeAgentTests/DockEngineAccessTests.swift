import BixkuCore
import BixkuDock
import XCTest
@testable import BixkuModeAgent

final class DockEngineAccessTests: XCTestCase {
    private struct Rig {
        let clock = ManualClock(now: t0)
        let store = JSONModeStore(backend: InMemoryModeBackend())
        let engine: DockEngine
        let access: DockEngineAccess
        let coordinator: ProposalCoordinator

        init() {
            engine = DockEngine(
                configuration: DockConfiguration(defaultMode: .writing, tickInterval: nil),
                eventBus: EventBus(clock: clock),
                clock: clock
            )
            access = DockEngineAccess(engine: engine, store: store)
            coordinator = ProposalCoordinator(store: access, dock: access, history: ModeHistory(), clock: clock)
        }
    }

    private func smsNotification(_ title: String) -> IncomingNotification {
        IncomingNotification(appBundleID: "com.apple.MobileSMS", appName: "Messages", title: title, timestamp: t0)
    }

    func testCreateAdjustAndRevertReachTheEngineImmediately() async throws {
        let rig = Rig()
        var research = makeMode("research")
        research.summary = "Reading papers"

        let created = try await rig.coordinator.submit(.create(research), justification: "asked", untrusted: false)
        try await rig.coordinator.approve(created.id)
        var engineModes = await rig.engine.modes
        XCTAssertEqual(engineModes.definition("research"), research)

        let before = try XCTUnwrap(engineModes.definition(.writing))
        var after = before
        after.summary = "Long-form writing"
        let adjusted = try await rig.coordinator.submit(.update(before: before, after: after), justification: "asked", untrusted: false)
        try await rig.coordinator.approve(adjusted.id)
        XCTAssertEqual(rig.engine.state.activeMode.summary, "Long-form writing")

        try await rig.coordinator.revertProposal(adjusted.id)
        XCTAssertEqual(rig.engine.state.activeMode, before)
        try await rig.coordinator.revertProposal(created.id)
        engineModes = await rig.engine.modes
        XCTAssertFalse(engineModes.contains("research"))
        let stored = try await rig.store.load()
        XCTAssertFalse(stored.contains("research"))
    }

    func testActivationGoesThroughTheEngineAndRespectsManualChoice() async throws {
        let rig = Rig()
        let active = await rig.access.activeMode()
        XCTAssertEqual(active, .writing)

        let switchToReading = try await rig.coordinator.submit(.activate(from: .writing, to: .reading), justification: "papers", untrusted: false)
        try await rig.coordinator.approve(switchToReading.id)
        XCTAssertEqual(rig.engine.state.mode.modeID, .reading)
        XCTAssertFalse(rig.engine.state.isManual)
        XCTAssertEqual(rig.engine.state.mode.activation, .automatic(reason: "agent: papers"))

        try await rig.engine.setMode(.free)
        let back = try await rig.coordinator.submit(.activate(from: .free, to: .writing), justification: "", untrusted: false)
        do {
            try await rig.coordinator.approve(back.id)
            XCTFail("expected the manual choice to win")
        } catch let error as DockEngineError {
            XCTAssertEqual(error, .manualModeActive(.free))
        }
        XCTAssertEqual(rig.engine.state.mode.modeID, .free)
        let status = await rig.coordinator.proposal(back.id)?.status
        XCTAssertEqual(status, .failed)
    }

    func testHeldNotificationsAndRelease() async throws {
        let rig = Rig()
        let first = await rig.engine.ingest(smsNotification("one"))
        let second = await rig.engine.ingest(smsNotification("two"))
        var held = await rig.access.heldNotifications()
        XCTAssertEqual(held.map(\.id), [first.id, second.id])

        try await rig.access.releaseNotification(first.id)
        held = await rig.access.heldNotifications()
        XCTAssertEqual(held.map(\.id), [second.id])
        do {
            try await rig.access.releaseNotification(first.id)
            XCTFail("expected unknownNotification")
        } catch let error as ModeAgentError {
            XCTAssertEqual(error, .unknownNotification(first.id))
        }
    }

    func testRecentActivityComesFromTheEngineTimeline() async {
        let rig = Rig()
        await rig.engine.ingest(ActivitySample(appBundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "App.swift", timestamp: t0))
        await rig.engine.ingest(ActivitySample(appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs", timestamp: t0.addingTimeInterval(60)))
        let recent = await rig.access.recentActivity(limit: 1)
        XCTAssertEqual(recent.map(\.sample.appBundleID), ["com.apple.Safari"])
    }

    func testStoppedDockReadsEmptyAndRefusesWrites() async throws {
        let access = DockEngineAccess { nil }
        let active = await access.activeMode()
        XCTAssertNil(active)
        let held = await access.heldNotifications()
        XCTAssertTrue(held.isEmpty)
        let recent = await access.recentActivity(limit: 5)
        XCTAssertTrue(recent.isEmpty)
        do {
            _ = try await access.load()
            XCTFail("expected notRunning")
        } catch let error as DockModuleError {
            XCTAssertEqual(error, .notRunning)
        }
        do {
            try await access.setActiveMode(.free, reason: "x")
            XCTFail("expected notRunning")
        } catch let error as DockModuleError {
            XCTAssertEqual(error, .notRunning)
        }
    }

    func testFollowsADockModuleAcrossItsLifecycle() async throws {
        let clock = ManualClock(now: t0)
        let env = ModuleEnvironment(
            eventBus: EventBus(clock: clock),
            storage: InMemoryStorageFactory(),
            config: try StaticConfigProvider(toml: ""),
            logSink: InMemoryLogSink(),
            clock: clock
        )
        let store = JSONModeStore(backend: InMemoryModeBackend())
        let module = DockModule(modeStore: store, configuration: DockConfiguration(defaultMode: .writing, tickInterval: nil))
        let access = DockEngineAccess(module: module)
        let registry = ModuleRegistry(environment: env)
        try await registry.register(module)

        _ = try await registry.startAll()
        let active = await access.activeMode()
        XCTAssertEqual(active, .writing)
        try await access.save(makeMode("research"))
        let engine = try XCTUnwrap(module.engine)
        let modes = await engine.modes
        XCTAssertTrue(modes.contains("research"))

        await registry.stopAll()
        let afterStop = await access.activeMode()
        XCTAssertNil(afterStop)
    }
}
