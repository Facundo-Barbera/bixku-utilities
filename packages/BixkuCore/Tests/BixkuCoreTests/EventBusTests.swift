import XCTest
@testable import BixkuCore

private struct Ping: BixkuEventPayload, Equatable {
    static let eventName: EventName = "test.ping"
    var n: Int
}

final class EventBusTests: XCTestCase {
    func testTypedSubscriptionReceivesOnlyItsPayloadInOrder() async {
        let bus = EventBus()
        let pings = bus.subscribe(to: Ping.self)
        bus.publish(ModeChanged(previousModeID: nil, modeID: "writing"))
        for n in 1...3 {
            bus.publish(Ping(n: n), source: "online.bixku.test")
        }
        let received = await collect(pings, count: 3)
        XCTAssertEqual(received.map(\.payload.n), [1, 2, 3])
        XCTAssertEqual(received.first?.source, "online.bixku.test")
    }

    func testEverySubscriberGetsEachEvent() async {
        let bus = EventBus()
        let first = bus.subscribe(to: ActivityChanged.self)
        let second = bus.subscribe(to: ActivityChanged.self)
        let activity = ActivityChanged(appBundleID: "com.example.editor", appName: "Editor", windowTitle: "notes.md")
        bus.publish(activity)
        let a = await collect(first, count: 1)
        let b = await collect(second, count: 1)
        XCTAssertEqual(a.map(\.payload), [activity])
        XCTAssertEqual(b.map(\.payload), [activity])
    }

    func testUntypedFilters() async {
        let bus = EventBus()
        let all = bus.subscribe()
        let modeOnly = bus.subscribe(.names([.modeChanged]))
        let activityNamespace = bus.subscribe(.namespace("activity"))
        bus.publish(ActivityChanged(appBundleID: nil, appName: "Terminal"))
        bus.publish(NotificationReceived(appBundleID: "com.example.chat", title: "Hi"))
        bus.publish(ModeChanged(previousModeID: "writing", modeID: "building", reason: "user"))

        let allNames = await collect(all, count: 3).map(\.name)
        XCTAssertEqual(allNames, [.activityChanged, .notificationReceived, .modeChanged])
        let modes = await collect(modeOnly, count: 1)
        XCTAssertEqual(modes.first?.payload(as: ModeChanged.self)?.modeID, "building")
        let activities = await collect(activityNamespace, count: 1)
        XCTAssertEqual(activities.map(\.name), [.activityChanged])
    }

    func testNoReplayOfEarlierEvents() async {
        let bus = EventBus()
        bus.publish(Ping(n: 0))
        let stream = bus.subscribe(to: Ping.self)
        bus.publish(Ping(n: 1))
        let received = await collect(stream, count: 1)
        XCTAssertEqual(received.map(\.payload.n), [1])
    }

    func testCancellingTheConsumerUnsubscribes() async {
        let bus = EventBus()
        let started = expectation(description: "consumer started")
        let task = Task {
            var iterator = bus.subscribe(to: Ping.self).makeAsyncIterator()
            started.fulfill()
            while await iterator.next() != nil {}
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(bus.subscriberCount, 1)
        task.cancel()
        await task.value
        XCTAssertEqual(bus.subscriberCount, 0)
        bus.publish(Ping(n: 1))  // No subscribers: must not crash.
    }

    func testDroppingTheStreamUnsubscribes() {
        let bus = EventBus()
        do {
            _ = bus.subscribe(to: Ping.self)
        }
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testShutdownFinishesStreams() async {
        let bus = EventBus()
        let stream = bus.subscribe()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        bus.publish(Ping(n: 1))
        bus.shutdown()
        let count = await consumer.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bus.subscriberCount, 0)

        // Subscriptions after shutdown end immediately.
        var late = bus.subscribe().makeAsyncIterator()
        let next = await late.next()
        XCTAssertNil(next)
    }

    func testBufferDropsOldestWhenFull() async {
        let bus = EventBus()
        let stream = bus.subscribe(to: Ping.self, buffering: .newest(2))
        for n in 1...5 {
            bus.publish(Ping(n: n))
        }
        let received = await collect(stream, count: 2)
        XCTAssertEqual(received.map(\.payload.n), [4, 5])
    }

    func testEventMetadataAndEncoding() throws {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_000))
        let bus = EventBus(clock: clock)
        let event = bus.publish(ModeChanged(previousModeID: nil, modeID: "writing"), source: "online.bixku.dock")
        XCTAssertEqual(event.name, "mode.changed")
        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1_000))
        let decoded = try JSONDecoder().decode(ModeChanged.self, from: event.encodedPayload())
        XCTAssertEqual(decoded.modeID, "writing")
    }

    func testContextPublishSetsSource() async throws {
        let bus = EventBus()
        let stream = bus.subscribe(to: Ping.self)
        let registry = ModuleRegistry(environment: quietEnvironment(eventBus: bus))
        let module = TestModule("online.bixku.sender")
        try await registry.register(module)
        try await registry.startAll()
        try XCTUnwrap(module.context).publish(Ping(n: 7))
        let received = await collect(stream, count: 1)
        XCTAssertEqual(received.first?.source, "online.bixku.sender")
    }
}
