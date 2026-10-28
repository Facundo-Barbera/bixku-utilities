import XCTest
@testable import BixkuCore

final class SupportTests: XCTestCase {
    func testVersionIsSemver() {
        XCTAssertNotNil(SemanticVersion(string: BixkuCore.version))
    }

    func testModuleIDs() throws {
        XCTAssertTrue(ModuleID("online.bixku.mode-agent").isValid)
        XCTAssertTrue(ModuleID("hello").isValid)
        XCTAssertFalse(ModuleID("online..bixku").isValid)
        XCTAssertEqual(ModuleID("online.bixku.dock").slug, "dock")
        XCTAssertThrowsError(try ModuleID(validating: "Nope"))
        XCTAssertEqual(try ModuleID(validating: "online.bixku.lintel").rawValue, "online.bixku.lintel")
    }

    func testSemanticVersion() throws {
        XCTAssertEqual(SemanticVersion(string: "1.2"), SemanticVersion(1, 2, 0))
        XCTAssertNil(SemanticVersion(string: "1.x"))
        XCTAssertNil(SemanticVersion(string: "1.2.3.4"))
        XCTAssertLessThan(SemanticVersion(1, 9, 9), SemanticVersion(1, 10, 0))
        let data = try JSONEncoder().encode(SemanticVersion(0, 3, 1))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"0.3.1\"")
    }

    func testManifestDefaultsAndCoding() throws {
        let manifest = ModuleManifest(
            id: "online.bixku.dock",
            displayName: "Dock",
            summary: "Focus modes",
            version: "0.1.0",
            capabilities: [.activityMonitoring],
            permissions: [.accessibility],
            ui: [ModuleUIDescriptor(viewID: "panel", title: "Dock", systemImage: "dock.rectangle", kind: .menuBarPanel)]
        )
        XCTAssertEqual(manifest.configKey, "dock")
        let decoded = try JSONDecoder().decode(ModuleManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    func testModuleStateCoding() throws {
        for state: ModuleState in [.registered, .running, .failed(reason: "x")] {
            let decoded = try JSONDecoder().decode(ModuleState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(decoded, state)
        }
        XCTAssertTrue(ModuleState.stopping.isActive)
        XCTAssertFalse(ModuleState.failed(reason: "x").isActive)
    }

    func testLoggerFiltersByLevel() {
        let sink = InMemoryLogSink()
        let clock = ManualClock(now: Date(timeIntervalSince1970: 42))
        let logger = BixkuLogger(category: "online.bixku.test", minimumLevel: .info, sink: sink, clock: clock)
        logger.debug("hidden")
        logger.info("shown", metadata: ["k": "v"])
        logger.error("also shown")
        XCTAssertEqual(sink.entries.map(\.message), ["shown", "also shown"])
        XCTAssertEqual(sink.entries.first?.metadata, ["k": "v"])
        XCTAssertEqual(sink.entries.first?.timestamp, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(LogLevel(name: "WARN"), .warning)
        XCTAssertNil(LogLevel(name: "loud"))
    }

    func testManualClockWakesSleepersWhenAdvanced() async throws {
        let clock = ManualClock()
        let woke = Locked(false)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
            woke.withLock { $0 = true }
        }
        while clock.sleeperCount == 0 {
            await Task.yield()
        }
        clock.advance(by: .seconds(5))
        XCTAssertFalse(woke.withLock { $0 })
        clock.advance(by: .seconds(5))
        try await sleeper.value
        XCTAssertTrue(woke.withLock { $0 })
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 10))
    }

    func testManualClockSleepIsCancellable() async {
        let clock = ManualClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(60))
        }
        sleeper.cancel()
        do {
            try await sleeper.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(clock.sleeperCount, 0)
    }
}
