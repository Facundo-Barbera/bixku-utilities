import BixkuDock
import XCTest

@testable import BixkuUtilities

final class ActivityMonitorLogicTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private func sample(
        _ bundleID: String = "com.apple.Terminal",
        title: String? = nil,
        at seconds: TimeInterval,
        idle: TimeInterval = 0
    ) -> ActivitySample {
        ActivitySample(
            appBundleID: bundleID,
            windowTitle: title,
            timestamp: at(seconds),
            idleSeconds: idle
        )
    }

    // MARK: Mapping

    func testMapsReadingToSample() throws {
        let reading = ActivityReading(
            app: FrontmostApp(bundleID: "com.apple.Safari", name: "Safari", processID: 42),
            windowTitle: "  Swift Forums  ",
            idleSeconds: 12.5,
            timestamp: at(0)
        )
        let mapped = try XCTUnwrap(ActivitySampleMapper.sample(from: reading))
        XCTAssertEqual(mapped.appBundleID, "com.apple.Safari")
        XCTAssertEqual(mapped.appName, "Safari")
        XCTAssertEqual(mapped.windowTitle, "Swift Forums")
        XCTAssertEqual(mapped.idleSeconds, 12.5)
        XCTAssertEqual(mapped.timestamp, at(0))
        XCTAssertNil(mapped.url)
        XCTAssertNil(mapped.document)
    }

    func testNoFrontmostAppYieldsNoSample() {
        let reading = ActivityReading(app: nil, windowTitle: "x", idleSeconds: 0, timestamp: at(0))
        XCTAssertNil(ActivitySampleMapper.sample(from: reading))
    }

    func testBlankTitleBecomesNil() throws {
        let reading = ActivityReading(
            app: FrontmostApp(bundleID: "a.b", name: nil, processID: 1),
            windowTitle: " \n\t ",
            idleSeconds: 0,
            timestamp: at(0)
        )
        XCTAssertNil(try XCTUnwrap(ActivitySampleMapper.sample(from: reading)).windowTitle)
    }

    func testLongTitleIsTruncated() throws {
        let filter = ActivityPrivacyFilter(titleBlockedBundleIDs: [], maxTitleLength: 10)
        let reading = ActivityReading(
            app: FrontmostApp(bundleID: "a.b", name: nil, processID: 1),
            windowTitle: String(repeating: "x", count: 50),
            idleSeconds: 0,
            timestamp: at(0)
        )
        let mapped = try XCTUnwrap(ActivitySampleMapper.sample(from: reading, filter: filter))
        XCTAssertEqual(mapped.windowTitle?.count, 10)
    }

    func testInvalidIdleIsClamped() throws {
        func idle(_ value: TimeInterval) throws -> TimeInterval {
            let reading = ActivityReading(
                app: FrontmostApp(bundleID: "a.b", name: nil, processID: 1),
                windowTitle: nil,
                idleSeconds: value,
                timestamp: at(0)
            )
            return try XCTUnwrap(ActivitySampleMapper.sample(from: reading)).idleSeconds
        }
        XCTAssertEqual(try idle(-3), 0)
        XCTAssertEqual(try idle(.nan), 0)
        XCTAssertEqual(try idle(.infinity), 0)
    }

    // MARK: Privacy

    func testPasswordManagerTitlesAreNeverReadOrEmitted() throws {
        let filter = ActivityPrivacyFilter.default
        XCTAssertFalse(filter.allowsTitleRead(bundleID: "com.1Password.1Password"))
        XCTAssertTrue(filter.allowsTitleRead(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(filter.allowsTitleRead(bundleID: nil))

        let reading = ActivityReading(
            app: FrontmostApp(bundleID: "com.1password.1password", name: "1Password", processID: 1),
            windowTitle: "Bank login",
            idleSeconds: 0,
            timestamp: at(0)
        )
        let mapped = try XCTUnwrap(ActivitySampleMapper.sample(from: reading, filter: filter))
        XCTAssertNil(mapped.windowTitle)
        XCTAssertEqual(mapped.appName, "1Password")
    }

    // MARK: Emission policy

    func testFirstSampleIsEmittedImmediately() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample(at: 0)))
    }

    func testChangeWaitsForDebounce() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample("a.a", at: 0)))
        XCTAssertFalse(policy.shouldEmit(sample("b.b", at: 1)))
        XCTAssertFalse(policy.shouldEmit(sample("b.b", at: 1.4)))
        XCTAssertTrue(policy.shouldEmit(sample("b.b", at: 1.5)))
        XCTAssertFalse(policy.shouldEmit(sample("b.b", at: 2)), "unchanged: wait for the heartbeat")
    }

    func testFlickeringFocusIsSwallowed() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample("a.a", at: 0)))
        // Cmd-Tab through b and c, then back to a, before anything settles.
        XCTAssertFalse(policy.shouldEmit(sample("b.b", at: 1)))
        XCTAssertFalse(policy.shouldEmit(sample("c.c", at: 1.3)))
        XCTAssertFalse(policy.shouldEmit(sample("a.a", at: 1.6)))
        XCTAssertFalse(policy.shouldEmit(sample("a.a", at: 2.5)))
    }

    func testDebounceRestartsWhenFocusChangesAgain() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample("a.a", at: 0)))
        XCTAssertFalse(policy.shouldEmit(sample("b.b", at: 1)))
        XCTAssertFalse(policy.shouldEmit(sample("c.c", at: 1.4)))
        XCTAssertFalse(policy.shouldEmit(sample("c.c", at: 1.8)), "only 0.4s since c appeared")
        XCTAssertTrue(policy.shouldEmit(sample("c.c", at: 2)))
    }

    func testWindowTitleChangeCounts() {
        var policy = ActivityEmissionPolicy(debounce: 0, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample(title: "one", at: 0)))
        XCTAssertTrue(policy.shouldEmit(sample(title: "two", at: 1)))
    }

    func testHeartbeatReemitsUnchangedFocus() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample(at: 0)))
        XCTAssertFalse(policy.shouldEmit(sample(at: 4.9, idle: 4)))
        XCTAssertTrue(policy.shouldEmit(sample(at: 5, idle: 5)))
        XCTAssertFalse(policy.shouldEmit(sample(at: 9.9)))
        XCTAssertTrue(policy.shouldEmit(sample(at: 10)))
    }

    func testIdleAloneDoesNotTriggerEmission() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 60)
        XCTAssertTrue(policy.shouldEmit(sample(at: 0, idle: 0)))
        XCTAssertFalse(policy.shouldEmit(sample(at: 1, idle: 300)))
    }

    func testResetTreatsNextSampleAsFirst() {
        var policy = ActivityEmissionPolicy(debounce: 0.5, heartbeat: 5)
        XCTAssertTrue(policy.shouldEmit(sample("a.a", at: 0)))
        policy.reset()
        XCTAssertTrue(policy.shouldEmit(sample("b.b", at: 0.1)))
    }
}
