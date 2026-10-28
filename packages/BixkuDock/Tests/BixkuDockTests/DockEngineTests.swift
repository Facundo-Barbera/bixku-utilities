import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

/// Counts classifications and delegates to the rules.
final class CountingClassifier: ActivityClassifier, @unchecked Sendable {
    private let calls = Locked<[ActivitySample]>([])
    private let rules = RuleBasedClassifier()

    var count: Int { calls.withLock { $0.count } }
    var samples: [ActivitySample] { calls.withLock { $0 } }

    func classify(_ sample: ActivitySample, context: ClassificationContext) async -> ActivityVerdict {
        calls.withLock { $0.append(sample) }
        return rules.verdict(for: sample)
    }
}

final class DockEngineTests: XCTestCase {
    var clock: ManualClock!
    var bus: EventBus!

    override func setUp() {
        clock = ManualClock(now: t0)
        bus = EventBus(clock: clock)
    }

    private func makeEngine(
        _ configuration: DockConfiguration = DockConfiguration(tickInterval: nil),
        classifier: any ActivityClassifier = RuleBasedClassifier(),
        triage: NotificationTriage = NotificationTriage(),
        summarizer: (any DigestSummarizing)? = nil,
        catalog: ModeCatalog = .factory
    ) -> DockEngine {
        DockEngine(
            catalog: catalog,
            classifier: classifier,
            triage: triage,
            summarizer: summarizer,
            configuration: configuration,
            eventBus: bus,
            source: "online.bixku.dock",
            clock: clock
        )
    }

    /// Feeds `bundleID` every `step` seconds over `[from, to]`.
    private func feed(_ engine: DockEngine, _ bundleID: String, from: TimeInterval, to: TimeInterval, step: TimeInterval = 10, title: String? = nil, idle: TimeInterval = 0) async {
        var offset = from
        while offset <= to {
            await engine.ingest(sample(bundleID, title: title, at: offset, idle: idle))
            offset += step
        }
    }

    // MARK: Basics

    func testInitialStateAndStartEvent() async {
        let engine = makeEngine()
        let state = engine.state
        XCTAssertEqual(state.mode.modeID, .free)
        XCTAssertEqual(state.mode.activation, .initial)
        XCTAssertEqual(state.mode.since, t0)
        XCTAssertNil(state.activity)
        XCTAssertFalse(state.isManual)

        let events = bus.subscribe(to: ModeChanged.self)
        await engine.start()
        let first = await collect(events, count: 1).first
        XCTAssertEqual(first?.payload, ModeChanged(previousModeID: nil, modeID: "free", reason: "initial"))
        XCTAssertEqual(first?.source, "online.bixku.dock")
        await engine.stop()
    }

    func testConfiguredDefaultModeAndUnknownFallback() async {
        XCTAssertEqual(makeEngine(DockConfiguration(defaultMode: .writing)).state.mode.modeID, .writing)
        XCTAssertEqual(makeEngine(DockConfiguration(defaultMode: "nope")).state.mode.modeID, .free)
        let custom = ModeCatalog(modes: [Mode(definition: makeMode("solo"), provenance: .user)])
        XCTAssertEqual(makeEngine(catalog: custom).state.mode.modeID, "solo")
        // An empty catalog falls back to the factory modes.
        let empty = makeEngine(catalog: ModeCatalog(modes: []))
        let ids = await empty.modes.ids
        XCTAssertEqual(ids, DefaultModes.all.map(\.id))
    }

    func testActivityChangedOnlyWhenFocusChangesAndClassifierIsDeduplicated() async {
        let classifier = CountingClassifier()
        let engine = makeEngine(classifier: classifier)
        let events = bus.subscribe(to: ActivityChanged.self)
        await engine.ingest(sample("com.apple.Terminal", title: "zsh", at: 0))
        await engine.ingest(sample("com.apple.Terminal", title: "zsh", at: 2))
        await engine.ingest(sample("com.apple.Terminal", title: "zsh", at: 4, idle: 3))
        await engine.ingest(sample("com.google.Chrome", url: "https://github.com/a/b", at: 6))
        let received = await collect(events, count: 2).map(\.payload)
        XCTAssertEqual(received.map(\.appBundleID), ["com.apple.Terminal", "com.google.Chrome"])
        XCTAssertEqual(received[0].category, "code")
        XCTAssertEqual(received[0].windowTitle, "zsh")
        XCTAssertEqual(received[1].detail, "github.com")
        XCTAssertEqual(classifier.count, 2)

        let activity = engine.state.activity
        XCTAssertEqual(activity?.verdict.category, .code)
        XCTAssertEqual(activity?.category, .code)
        XCTAssertEqual(activity?.attention, .neutral) // free mode has no attention rules
    }

    func testOutOfOrderSamplesAreIgnored() async {
        let engine = makeEngine()
        await engine.ingest(sample("com.apple.Terminal", at: 10))
        await engine.ingest(sample("md.obsidian", at: 5))
        XCTAssertEqual(engine.state.activity?.sample.appBundleID, "com.apple.Terminal")
    }

    func testPrivacyRedaction() async {
        let classifier = CountingClassifier()
        let engine = makeEngine(DockConfiguration(tickInterval: nil, redactedApps: ["com.example.vault.*"]), classifier: classifier)
        let events = bus.subscribe(to: ActivityChanged.self)
        await engine.ingest(ActivitySample(
            appBundleID: "com.example.vault.app",
            appName: "Vault",
            windowTitle: "Bank login",
            url: URL(string: "https://bank.example"),
            document: "secrets.txt",
            timestamp: t0
        ))
        let event = await collect(events, count: 1).first?.payload
        XCTAssertEqual(event?.appName, "Vault")
        XCTAssertNil(event?.windowTitle)
        XCTAssertNil(event?.detail)
        XCTAssertNil(classifier.samples.first?.windowTitle)
        XCTAssertNil(engine.state.activity?.sample.url)
    }

    // MARK: Automatic transitions

    func testEntersBuildingAfterFiveMinutesOfCode() async {
        let engine = makeEngine()
        let events = bus.subscribe(to: ModeChanged.self)
        await feed(engine, "com.apple.Terminal", from: 0, to: 290)
        XCTAssertEqual(engine.state.mode.modeID, .free)
        await engine.ingest(sample("com.apple.Terminal", at: 300))
        let state = engine.state
        XCTAssertEqual(state.mode.modeID, .building)
        XCTAssertEqual(state.mode.activation, .automatic(reason: "code for 5m"))
        XCTAssertEqual(state.mode.since, t0.addingTimeInterval(300))
        XCTAssertEqual(state.activity?.attention, .focus)
        let change = await collect(events, count: 1).first?.payload
        XCTAssertEqual(change, ModeChanged(previousModeID: "free", modeID: "building", reason: "automatic: code for 5m"))
    }

    func testBriefInterruptionsAreToleratedLongOnesResetTheRun() async {
        let engine = makeEngine(DockConfiguration(transitionGrace: 30, tickInterval: nil))
        await feed(engine, "com.apple.Terminal", from: 0, to: 100)
        await engine.ingest(sample("com.tinyspeck.slackmacgap", at: 110)) // 20 s glance
        await feed(engine, "com.apple.Terminal", from: 130, to: 300)
        // 300 s elapsed but only 280 s of code.
        XCTAssertEqual(engine.state.mode.modeID, .free)
        await engine.ingest(sample("com.apple.Terminal", at: 320))
        XCTAssertEqual(engine.state.mode.modeID, .building)

        let other = makeEngine(DockConfiguration(transitionGrace: 30, tickInterval: nil))
        await feed(other, "com.apple.Terminal", from: 0, to: 200)
        await feed(other, "com.tinyspeck.slackmacgap", from: 210, to: 260) // 60 s away
        await feed(other, "com.apple.Terminal", from: 270, to: 560)
        XCTAssertEqual(other.state.mode.modeID, .free)
        await other.ingest(sample("com.apple.Terminal", at: 570))
        XCTAssertEqual(other.state.mode.modeID, .building)
    }

    func testMinimumDwellPreventsFlipFlopping() async {
        let engine = makeEngine(DockConfiguration(minimumModeDwell: 600, tickInterval: nil))
        try? await engine.setMode(.writing)
        await engine.resumeAutomatic()
        await feed(engine, "com.apple.Terminal", from: 0, to: 300)
        XCTAssertEqual(engine.state.mode.modeID, .building)
        // Writing qualifies after 5 minutes, but the dwell time keeps building for 10.
        await feed(engine, "md.obsidian", from: 310, to: 890)
        XCTAssertEqual(engine.state.mode.modeID, .building)
        await engine.ingest(sample("md.obsidian", at: 900))
        XCTAssertEqual(engine.state.mode.modeID, .writing)
    }

    func testIdleEntersBreakAndFromRestrictionAppliesToFree() async {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, minimumModeDwell: 0, tickInterval: nil))
        // `free` only takes over from `break`.
        await feed(engine, "com.example.Mystery", from: 0, to: 1_000, step: 50)
        XCTAssertEqual(engine.state.mode.modeID, .writing)
        await engine.ingest(sample("com.example.Mystery", at: 1_100, idle: 700))
        XCTAssertEqual(engine.state.mode.modeID, .break)
        XCTAssertEqual(engine.state.mode.activation, .automatic(reason: "idle for 10m"))
        XCTAssertEqual(engine.state.activity?.isIdle, true)
        await feed(engine, "com.example.Mystery", from: 1_150, to: 2_100, step: 50)
        XCTAssertEqual(engine.state.mode.modeID, .free)
    }

    func testPriorityBreaksTies() async {
        let low = ModeRule(trigger: .activity, match: ActivityMatcher(categories: [.code]), forSeconds: 60)
        let high = ModeRule(trigger: .activity, match: ActivityMatcher(apps: ["com.apple.Terminal"]), forSeconds: 60, priority: 3)
        let catalog = ModeCatalog(modes: [
            Mode(definition: makeMode("start"), provenance: .user),
            Mode(definition: makeMode("a", transitions: [low]), provenance: .user),
            Mode(definition: makeMode("b", transitions: [high]), provenance: .user),
        ])
        let engine = makeEngine(DockConfiguration(defaultMode: "start", minimumModeDwell: 0, tickInterval: nil), catalog: catalog)
        await feed(engine, "com.apple.Terminal", from: 0, to: 60)
        XCTAssertEqual(engine.state.mode.modeID, "b")
    }

    func testTicksDriveTimeBasedRulesWithoutNewSamples() async {
        let engine = makeEngine()
        await engine.ingest(sample("com.apple.Terminal", at: 0))
        clock.advance(by: .seconds(299))
        await engine.tick()
        XCTAssertEqual(engine.state.mode.modeID, .free)
        clock.advance(by: .seconds(1))
        await engine.tick()
        XCTAssertEqual(engine.state.mode.modeID, .building)
    }

    // MARK: Manual override

    func testManualModeWinsOverRulesUntilResumed() async throws {
        let engine = makeEngine()
        let events = bus.subscribe(to: ModeChanged.self)
        try await engine.setMode(.writing)
        XCTAssertTrue(engine.state.isManual)
        await feed(engine, "com.apple.Terminal", from: 0, to: 900)
        XCTAssertEqual(engine.state.mode.modeID, .writing)
        XCTAssertEqual(engine.state.activity?.attention, .neutral)

        await engine.resumeAutomatic()
        XCTAssertEqual(engine.state.mode.modeID, .building)
        XCTAssertFalse(engine.state.isManual)
        let changes = await collect(events, count: 2).map(\.payload)
        XCTAssertEqual(changes[0].reason, "manual")
        XCTAssertEqual(changes[1], ModeChanged(previousModeID: "writing", modeID: "building", reason: "automatic: code for 5m"))
    }

    func testManualModeWithExpiry() async throws {
        let engine = makeEngine()
        try await engine.setMode(.reading, until: t0.addingTimeInterval(600))
        await feed(engine, "com.apple.Terminal", from: 0, to: 590)
        XCTAssertEqual(engine.state.mode.modeID, .reading)
        await engine.ingest(sample("com.apple.Terminal", at: 600))
        XCTAssertEqual(engine.state.mode.modeID, .building)
    }

    func testManualChoiceOfTheActiveModeJustPinsIt() async throws {
        let engine = makeEngine()
        let events = bus.subscribe(to: ModeChanged.self)
        try await engine.setMode(.free)
        XCTAssertEqual(engine.state.mode.activation, .manual(until: nil))
        await feed(engine, "com.apple.Terminal", from: 0, to: 600)
        XCTAssertEqual(engine.state.mode.modeID, .free)
        bus.publish(ModeChanged(previousModeID: nil, modeID: "sentinel"))
        let first = await collect(events, count: 1).first?.payload
        XCTAssertEqual(first?.modeID, "sentinel", "no mode.changed for pinning the active mode")
    }

    func testUnknownManualModeThrows() async {
        let engine = makeEngine()
        do {
            try await engine.setMode("ghost")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DockEngineError, .unknownMode("ghost"))
        }
    }

    // MARK: Catalog updates

    func testRemovingTheActiveModeFallsBackToDefault() async throws {
        let custom = Mode(definition: makeMode("custom"), provenance: .user)
        let engine = makeEngine(catalog: ModeCatalog(modes: ModeCatalog.factory.modes + [custom]))
        try await engine.setMode("custom")
        await engine.updateCatalog(.factory)
        XCTAssertEqual(engine.state.mode.modeID, .free)
        XCTAssertEqual(engine.state.mode.activation, .automatic(reason: "mode 'custom' was removed"))
    }

    func testUpdatedDefinitionsApplyImmediately() async throws {
        let engine = makeEngine()
        try await engine.setMode(.writing)
        var writing = DefaultModes.definition(.writing)!
        writing.notifications.defaultAction = .silence
        let catalog = ModeCatalog(modes: ModeCatalog.factory.modes.map {
            $0.id == .writing ? Mode(definition: writing, provenance: .userOverride) : $0
        })
        await engine.updateCatalog(catalog)
        XCTAssertEqual(engine.state.activeMode.notifications.defaultAction, .silence)
        let triaged = await engine.ingest(notification("com.example.App"))
        XCTAssertEqual(triaged.decision.action, .silence)
    }

    // MARK: Notifications

    func testNotificationsAreTriagedHeldAndDigestedOnModeExit() async throws {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil))
        let received = bus.subscribe(to: NotificationReceived.self)
        let triagedEvents = bus.subscribe(to: NotificationTriaged.self)
        let digests = bus.subscribe(to: DigestReady.self)

        await engine.ingest(sample("md.obsidian", at: 0))
        let chat = await engine.ingest(notification("com.tinyspeck.slackmacgap", title: "lunch?", at: 10))
        let dm = await engine.ingest(notification("com.apple.MobileSMS", title: "Sam", at: 20))
        let calendar = await engine.ingest(notification("com.apple.iCal", title: "Standup", at: 30))
        let promo = await engine.ingest(notification("com.example.Shop", body: "50% off", at: 40))
        XCTAssertEqual([chat, dm, calendar, promo].map(\.decision.action), [.summarize, .hold, .allow, .silence])
        XCTAssertEqual(engine.state.held.map(\.notification.title), ["lunch?", "Sam"])

        let receivedTitles = await collect(received, count: 4).map(\.payload.title)
        XCTAssertEqual(receivedTitles, ["lunch?", "Sam", "Standup", "Hello"])
        let triaged = await collect(triagedEvents, count: 4).map(\.payload)
        XCTAssertEqual(triaged.map(\.action), [.summarize, .hold, .allow, .silence])
        XCTAssertEqual(triaged[0].modeID, "writing")
        XCTAssertEqual(triaged[0].category, .chat)

        clock.advance(by: .seconds(1_800))
        try await engine.setMode(.free)
        let digest = await collect(digests, count: 1).first?.payload.digest
        XCTAssertEqual(digest?.modeID, .writing)
        XCTAssertEqual(digest?.held.map(\.notification.title), ["Sam"])
        XCTAssertEqual(digest?.groups.map(\.count), [1])
        XCTAssertEqual(digest?.summary, "While in Writing (30m): 2 notifications. 1 held: MobileSMS. Summarized: slackmacgap ×1.")
        XCTAssertEqual(engine.state.held, [])
        XCTAssertEqual(engine.state.lastDigest, digest)
    }

    func testTriageSeesTheCurrentActivity() async {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil))
        await engine.ingest(sample("com.tinyspeck.slackmacgap", at: 0))
        let fromSlack = await engine.ingest(notification("com.tinyspeck.slackmacgap"))
        XCTAssertEqual(fromSlack.decision.action, .allow)
        XCTAssertEqual(fromSlack.decision.reason, "from the app you are using")
    }

    func testReleaseHeld() async {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil))
        await engine.ingest(notification("com.apple.MobileSMS"))
        let released = await engine.releaseHeld()
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(engine.state.held, [])
    }

    func testSummarizerReplacesDigestText() async throws {
        let summarizer = MockLLM(summary: { digest in "You missed \(digest.totalCount) things." })
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil), summarizer: summarizer)
        let digests = bus.subscribe(to: DigestReady.self)
        await engine.ingest(notification("com.apple.MobileSMS"))
        try await engine.setMode(.free)
        let digest = await collect(digests, count: 1).first?.payload.digest
        XCTAssertEqual(digest?.summary, "You missed 1 things.")
        await eventually { engine.state.lastDigest?.summary == "You missed 1 things." }
    }

    func testFailingSummarizerKeepsDeterministicText() async throws {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil), summarizer: MockLLM.failing())
        let digests = bus.subscribe(to: DigestReady.self)
        await engine.ingest(notification("com.apple.MobileSMS"))
        try await engine.setMode(.free)
        let digest = await collect(digests, count: 1).first?.payload.digest
        XCTAssertTrue(digest?.summary.hasPrefix("While in Writing") == true)
    }

    // MARK: Classification events and suggestions

    func testActivityClassifiedEventsTrackAttention() async throws {
        let engine = makeEngine(DockConfiguration(defaultMode: .writing, tickInterval: nil))
        let events = bus.subscribe(to: ActivityClassified.self)
        await engine.ingest(sample("md.obsidian", at: 0))
        await engine.ingest(sample("md.obsidian", at: 5))
        await engine.ingest(sample("com.spotify.client", at: 10))
        let received = await collect(events, count: 2).map(\.payload)
        XCTAssertEqual(received.map(\.activity.attention), [.focus, .distraction])
        // The smoothed category resists the switch to media for now.
        XCTAssertEqual(received.map(\.activity.category), [.writing, .writing])
        XCTAssertEqual(received[1].modeID, "writing")
    }

    func testLLMSuggestionIsSurfacedButNotApplied() async {
        let hybrid = HybridClassifier(llm: MockLLM.answering(.writing, suggestedMode: .writing), clock: clock)
        let engine = makeEngine(classifier: hybrid)
        await engine.ingest(sample("com.example.Mystery", at: 0))
        XCTAssertEqual(engine.state.suggestedMode, .writing)
        XCTAssertEqual(engine.state.mode.modeID, .free)
        XCTAssertEqual(engine.state.activity?.verdict.source, .llm)
        await engine.ingest(sample("com.apple.Terminal", at: 10))
        XCTAssertNil(engine.state.suggestedMode)
    }

    // MARK: Streams

    func testConsumesSourcesAndTicksOnTheClock() async throws {
        let clock: ManualClock = self.clock
        let engine = makeEngine(DockConfiguration(tickInterval: .seconds(10)))
        let activity = ManualActivitySource()
        let notifications = ManualNotificationSource()
        let triaged = bus.subscribe(to: NotificationTriaged.self)
        await engine.start(activity: try await activity.start(), notifications: try await notifications.start())

        activity.send(sample("com.apple.Terminal", at: 0))
        await eventually { engine.state.activity != nil }
        notifications.send(notification("com.apple.MobileSMS"))
        let decision = await collect(triaged, count: 1).first?.payload
        XCTAssertEqual(decision?.action, .allow)
        XCTAssertEqual(decision?.modeID, "free")

        // Without new samples, ticks move time forward until the building rule fires.
        for _ in 0..<30 {
            await eventually { clock.sleeperCount > 0 }
            clock.advance(by: .seconds(10))
            if engine.state.mode.modeID == .building { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await eventually { engine.state.mode.modeID == .building }
        await engine.stop()
        activity.finish()
        notifications.finish()
    }

    func testStateStreamStartsWithCurrentState() async {
        let engine = makeEngine()
        let states = engine.states()
        await engine.ingest(sample("com.apple.Terminal", at: 0))
        let received = await collect(states, count: 2)
        XCTAssertNil(received[0].activity)
        XCTAssertEqual(received[1].activity?.sample.appBundleID, "com.apple.Terminal")
    }

    func testScriptedSourceDrivesTheEngine() async throws {
        let clock: ManualClock = self.clock
        let script = ScriptedActivitySource(steps: [
            .init(after: .seconds(1), sample("com.apple.Terminal", at: 1)),
            .init(after: .seconds(1), sample("md.obsidian", at: 2)),
        ], clock: clock)
        let engine = makeEngine()
        await engine.start(activity: try await script.start())
        await eventually { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(1))
        await eventually { engine.state.activity?.sample.appBundleID == "com.apple.Terminal" }
        await eventually { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(1))
        await eventually { engine.state.activity?.sample.appBundleID == "md.obsidian" }
        await engine.stop()
    }
}
