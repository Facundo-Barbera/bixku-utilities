import XCTest
@testable import BixkuCore

final class ModuleRegistryTests: XCTestCase {
    func testRegisterRejectsDuplicates() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("online.bixku.a"))
        await assertThrows(ModuleError.duplicateModule("online.bixku.a")) {
            try await registry.register(TestModule("online.bixku.a"))
        }
        let ids = await registry.moduleIDs
        XCTAssertEqual(ids, ["online.bixku.a"])
    }

    func testRegisterRejectsInvalidIDs() async {
        let registry = ModuleRegistry(environment: quietEnvironment())
        for bad in ["", "Online.Bixku", "a..b", "a b", "a/b", "-a", "a-", "a_b", ".a"] {
            await assertThrows(ModuleError.invalidModuleID(bad)) {
                try await registry.register(TestModule(ModuleID(rawValue: bad)))
            }
        }
        await assertThrows(ModuleError.invalidModuleID("Bad")) {
            try await registry.register(TestModule("ok", dependsOn: ["Bad"]))
        }
    }

    func testResolvesModulesByID() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        let module = TestModule("online.bixku.a")
        try await registry.register(module)
        let resolved = await registry.module("online.bixku.a", as: TestModule.self)
        XCTAssertTrue(resolved === module)
        let missing = await registry.module("online.bixku.missing")
        XCTAssertNil(missing)
        let state = await registry.state(of: "online.bixku.a")
        XCTAssertEqual(state, .registered)
    }

    func testStartupOrderPutsDependenciesFirstAndIsDeterministic() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        // Registered out of dependency order on purpose.
        try await registry.register(TestModule("agent", dependsOn: ["dock", "core"]))
        try await registry.register(TestModule("dock", dependsOn: ["core"]))
        try await registry.register(TestModule("lintel"))
        try await registry.register(TestModule("core"))
        let order = try await registry.startupOrder()
        XCTAssertEqual(order, ["lintel", "core", "dock", "agent"])
    }

    func testMissingDependencyIsReported() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("dock", dependsOn: ["core"]))
        await assertThrows(ModuleError.missingDependency(module: "dock", dependency: "core")) {
            _ = try await registry.startupOrder()
        }
        await assertThrows(ModuleError.missingDependency(module: "dock", dependency: "core")) {
            try await registry.startAll()
        }
    }

    func testDetectsCycles() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("free"))
        try await registry.register(TestModule("a", dependsOn: ["b"]))
        try await registry.register(TestModule("b", dependsOn: ["c"]))
        try await registry.register(TestModule("c", dependsOn: ["a"]))
        try await registry.register(TestModule("d", dependsOn: ["a"]))
        await assertThrows(ModuleError.dependencyCycle(["a", "b", "c", "a"])) {
            try await registry.validate()
        }
        // Nothing is started when the graph is invalid.
        await assertThrows(ModuleError.dependencyCycle(["a", "b", "c", "a"])) {
            try await registry.startAll()
        }
        let state = await registry.state(of: "free")
        XCTAssertEqual(state, .registered)
    }

    func testDetectsSelfDependency() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("a", dependsOn: ["a"]))
        await assertThrows(ModuleError.dependencyCycle(["a", "a"])) {
            try await registry.validate()
        }
    }

    func testStartAllAndStopAllFollowDependencyOrder() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("agent", dependsOn: ["dock"], log: log))
        try await registry.register(TestModule("dock", log: log))
        let report = try await registry.startAll()
        XCTAssertEqual(report, StartReport(running: ["dock", "agent"], failures: [:]))
        XCTAssertEqual(log.entries, ["start dock", "start agent"])
        let states = await registry.states
        XCTAssertEqual(states, ["dock": .running, "agent": .running])

        // Starting again is a no-op for running modules.
        try await registry.startAll()
        XCTAssertEqual(log.entries.count, 2)

        await registry.stopAll()
        XCTAssertEqual(log.entries, ["start dock", "start agent", "stop agent", "stop dock"])
        let stopped = await registry.states
        XCTAssertEqual(stopped, ["dock": .stopped, "agent": .stopped])
    }

    func testFailedStartMarksModuleAndDependentsFailed() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("base", log: log, failOnStart: true))
        try await registry.register(TestModule("child", dependsOn: ["base"], log: log))
        try await registry.register(TestModule("other", log: log))
        let report = try await registry.startAll()
        XCTAssertEqual(report.running, ["other"])
        XCTAssertEqual(report.failures["base"], "boom")
        XCTAssertEqual(
            report.failures["child"],
            ModuleError.dependencyNotRunning(module: "child", dependency: "base").description
        )
        XCTAssertFalse(report.isSuccess)
        XCTAssertEqual(log.entries, ["start base", "start other"])
        let baseState = await registry.state(of: "base")
        XCTAssertEqual(baseState, .failed(reason: "boom"))

        // A failed module is not stopped (it cleaned up when start threw).
        await registry.stopAll()
        XCTAssertEqual(log.entries, ["start base", "start other", "stop other"])
    }

    func testStartSingleModuleStartsDependenciesFirst() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("c", dependsOn: ["b"], log: log))
        try await registry.register(TestModule("b", dependsOn: ["a"], log: log))
        try await registry.register(TestModule("a", log: log))
        try await registry.register(TestModule("unrelated", log: log))
        try await registry.start("c")
        XCTAssertEqual(log.entries, ["start a", "start b", "start c"])
        await assertThrows(ModuleError.unknownModule("nope")) {
            try await registry.start("nope")
        }
    }

    func testStopSingleModuleStopsDependentsFirst() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("a", log: log))
        try await registry.register(TestModule("b", dependsOn: ["a"], log: log))
        try await registry.register(TestModule("c", dependsOn: ["b"], log: log))
        try await registry.register(TestModule("d", log: log))
        try await registry.startAll()
        try await registry.stop("a")
        XCTAssertEqual(Array(log.entries.suffix(3)), ["stop c", "stop b", "stop a"])
        let dState = await registry.state(of: "d")
        XCTAssertEqual(dState, .running)

        // Restart after stop.
        try await registry.start("c")
        XCTAssertEqual(Array(log.entries.suffix(3)), ["start a", "start b", "start c"])
    }

    func testUnregister() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        try await registry.register(TestModule("a", log: log))
        try await registry.register(TestModule("b", dependsOn: ["a"], log: log))
        try await registry.startAll()
        await assertThrows(ModuleError.hasDependents(module: "a", dependents: ["b"])) {
            try await registry.unregister("a")
        }
        try await registry.unregister("b")
        XCTAssertEqual(log.entries.last, "stop b")
        try await registry.unregister("a")
        let ids = await registry.moduleIDs
        XCTAssertEqual(ids, [])
        await assertThrows(ModuleError.unknownModule("a")) {
            try await registry.unregister("a")
        }
    }

    func testPublishesStateChanges() async throws {
        let registry = ModuleRegistry(environment: quietEnvironment())
        let changes = registry.stateChanges()
        try await registry.register(TestModule("a"))
        try await registry.startAll()
        await registry.stopAll()
        let received = await collect(changes, count: 5).map(\.payload.state)
        XCTAssertEqual(received, [.registered, .starting, .running, .stopping, .stopped])
    }

    func testModulesGetIsolatedContexts() async throws {
        let config = StaticConfigProvider(["modules": ["a": ["enabled": true]]])
        let registry = ModuleRegistry(environment: ModuleEnvironment(config: config, logSink: DiscardingLogSink()))
        let a = TestModule("online.bixku.a")
        let b = TestModule("online.bixku.b")
        try await registry.register(a)
        try await registry.register(b)
        try await registry.startAll()
        let contextA = try XCTUnwrap(a.context)
        let contextB = try XCTUnwrap(b.context)
        XCTAssertEqual(contextA.moduleID, "online.bixku.a")
        XCTAssertEqual(contextA.logger.category, "online.bixku.a")
        XCTAssertEqual(contextA.moduleConfig.bool("enabled"), true)
        XCTAssertNil(contextB.moduleConfig.bool("enabled"))

        try await contextA.storage.setValue("only-a", forKey: "secret")
        let leaked = try await contextB.storage.value(String.self, forKey: "secret")
        XCTAssertNil(leaked)
        let own = try await contextA.storage.value(String.self, forKey: "secret")
        XCTAssertEqual(own, "only-a")
    }

    func testConcurrentLifecycleCallsAreSerialized() async throws {
        let log = LifecycleLog()
        let registry = ModuleRegistry(environment: quietEnvironment())
        for name in ["a", "b", "c"] {
            try await registry.register(TestModule(ModuleID(rawValue: name), log: log))
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try? await registry.startAll() }
            }
        }
        XCTAssertEqual(log.entries, ["start a", "start b", "start c"])
    }
}
