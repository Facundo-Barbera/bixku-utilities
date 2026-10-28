import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

final class RuleBasedClassifierTests: XCTestCase {
    let classifier = RuleBasedClassifier()

    func testKnownApps() {
        XCTAssertEqual(classifier.verdict(for: sample("com.apple.Terminal", at: 0)).category, .code)
        XCTAssertEqual(classifier.verdict(for: sample("com.jetbrains.pycharm", at: 0)).category, .code)
        XCTAssertEqual(classifier.verdict(for: sample("md.obsidian", at: 0)).category, .writing)
        XCTAssertEqual(classifier.verdict(for: sample("com.tinyspeck.slackmacgap", at: 0)).category, .communication)
        XCTAssertEqual(classifier.verdict(for: sample("us.zoom.xos", at: 0)).category, .meeting)
        XCTAssertEqual(classifier.verdict(for: sample("com.spotify.client", at: 0)).category, .media)
        let terminal = classifier.verdict(for: sample("com.apple.Terminal", at: 0))
        XCTAssertGreaterThanOrEqual(terminal.confidence, 0.9)
        XCTAssertEqual(terminal.source, .rules)
        XCTAssertEqual(terminal.rationale, "app Terminal → code")
    }

    func testBrowserIsRefinedBySiteAndTitle() {
        let plain = classifier.verdict(for: sample("com.apple.Safari", title: "Some article", at: 0))
        XCTAssertEqual(plain.category, .browsing)
        XCTAssertLessThan(plain.confidence, 0.6)

        let github = classifier.verdict(for: sample("com.google.Chrome", url: "https://github.com/org/repo/pull/1", at: 0))
        XCTAssertEqual(github.category, .code)
        XCTAssertEqual(github.rationale, "site github.com → code")

        let video = classifier.verdict(for: sample("com.apple.Safari", url: "https://www.youtube.com/watch?v=1", at: 0))
        XCTAssertEqual(video.category, .media)

        let docs = classifier.verdict(for: sample("org.mozilla.firefox", title: "Draft - Google Docs", at: 0))
        XCTAssertEqual(docs.category, .writing)
        XCTAssertEqual(docs.rationale, "title contains \"Google Docs\" → writing")
    }

    func testUnknownAndEmptySamples() {
        let unknown = classifier.verdict(for: sample("com.example.Mystery", at: 0))
        XCTAssertEqual(unknown.category, .other)
        XCTAssertEqual(unknown.confidence, 0.2)
        let empty = classifier.verdict(for: sample(nil, at: 0))
        XCTAssertEqual(empty.category, .other)
        XCTAssertEqual(empty.confidence, 0.1)
    }

    func testCustomRulesTakePrecedenceOnTies() {
        let custom = RuleBasedClassifier(ruleSet: CategoryRuleSet.standard.adding([
            CategoryRule(.writing, confidence: 0.9, match: ActivityMatcher(apps: ["com.apple.Terminal"])),
        ]))
        XCTAssertEqual(custom.verdict(for: sample("com.apple.Terminal", at: 0)).category, .writing)
    }

    func testRuleSetIsCodable() throws {
        let data = try JSONEncoder().encode(CategoryRuleSet.standard)
        XCTAssertEqual(try JSONDecoder().decode(CategoryRuleSet.self, from: data), .standard)
    }
}

final class ActivitySmootherTests: XCTestCase {
    private func record(_ smoother: inout ActivitySmoother, _ category: ActivityCategory, at offset: TimeInterval, confidence: Double = 0.9, idle: TimeInterval = 0) {
        smoother.record(ClassifiedActivity(
            sample: sample("app.\(category)", at: offset, idle: idle),
            verdict: ActivityVerdict(category: category, confidence: confidence, rationale: "test")
        ))
    }

    func testFirstSampleIsAdoptedImmediately() {
        var smoother = ActivitySmoother()
        record(&smoother, .code, at: 0)
        XCTAssertEqual(smoother.update(at: t0), .code)
    }

    func testBriefInterruptionsDoNotFlip() {
        var smoother = ActivitySmoother()
        record(&smoother, .code, at: 0)
        smoother.update(at: t0)
        record(&smoother, .communication, at: 60)
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(65)), .code)
        record(&smoother, .code, at: 70)
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(75)), .code)
        // Alternating every few seconds never builds a lead.
        for step in 0..<20 {
            let offset = 75 + TimeInterval(step) * 4
            record(&smoother, step.isMultiple(of: 2) ? .media : .code, at: offset)
            XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(offset + 2)), .code, "step \(step)")
        }
    }

    func testSustainedChangeFlipsAfterMarginIsReached() {
        var smoother = ActivitySmoother(configuration: .init(window: 90, switchMargin: 0.2))
        record(&smoother, .code, at: 0)
        smoother.update(at: t0)
        smoother.update(at: t0.addingTimeInterval(90)) // a full window of code
        record(&smoother, .writing, at: 90)
        // At +130: writing 40s vs code 50s → no switch.
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(130)), .code)
        // At +150: writing 60s vs code 30s → share 0.67 vs 0.33 → switch.
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(150)), .writing)
        let shares = smoother.shares(at: t0.addingTimeInterval(150))
        XCTAssertEqual(shares[.writing] ?? 0, 2.0 / 3.0, accuracy: 0.001)
    }

    func testLowConfidenceTimeCountsLess() {
        var smoother = ActivitySmoother(configuration: .init(window: 100, switchMargin: 0.2, minimumWeight: 0.1))
        record(&smoother, .code, at: 0, confidence: 0.9)
        smoother.update(at: t0)
        record(&smoother, .other, at: 40, confidence: 0.2)
        // other lasted 60s at weight 0.2 = 12 vs code 40s at 0.9 = 36.
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(100)), .code)
    }

    func testIdleTimeIsIgnored() {
        var smoother = ActivitySmoother(configuration: .init(window: 90, idleThreshold: 60))
        record(&smoother, .code, at: 0)
        smoother.update(at: t0)
        record(&smoother, .media, at: 10, idle: 300)
        XCTAssertEqual(smoother.update(at: t0.addingTimeInterval(80)), .code)
        XCTAssertNil(smoother.shares(at: t0.addingTimeInterval(80))[.media])
    }

    func testOldEntriesArePrunedButSpanningEntryIsKept() {
        var smoother = ActivitySmoother(configuration: .init(window: 60))
        record(&smoother, .writing, at: 0)
        smoother.update(at: t0.addingTimeInterval(1_000))
        // The writing sample still spans the whole window.
        XCTAssertEqual(smoother.shares(at: t0.addingTimeInterval(1_000)), [.writing: 1])
        smoother.reset()
        XCTAssertNil(smoother.current)
    }
}

final class HybridClassifierTests: XCTestCase {
    func testConfidentRulesSkipTheLLM() async {
        let llm = MockLLM.answering(.media)
        let hybrid = HybridClassifier(llm: llm, clock: ManualClock(now: t0))
        let verdict = await hybrid.classify(sample("com.apple.Terminal", at: 0), context: ClassificationContext())
        XCTAssertEqual(verdict.category, .code)
        XCTAssertEqual(verdict.source, .rules)
        XCTAssertEqual(llm.activityCalls, 0)
    }

    func testNoLLMMeansRulesOnly() async {
        let hybrid = HybridClassifier(llm: nil)
        let verdict = await hybrid.classify(sample("com.example.Mystery", at: 0), context: ClassificationContext())
        XCTAssertEqual(verdict.source, .rules)
        let hasLLM = await hybrid.hasLLM
        XCTAssertFalse(hasLLM)
    }

    func testLowConfidenceAsksTheLLMWithContextAndCaches() async {
        let clock = ManualClock(now: t0)
        let llm = MockLLM.answering(.writing, confidence: 0.8, suggestedMode: .writing)
        let hybrid = HybridClassifier(llm: llm, policy: LLMUsagePolicy(confidenceThreshold: 0.6, cacheTTL: 60), clock: clock, recentLimit: 2)
        let recent = (0..<5).map { index in
            ClassifiedActivity(sample: sample("com.apple.Terminal", at: Double(index)), verdict: ActivityVerdict(category: .code, confidence: 0.9, rationale: ""))
        }
        let mystery = sample("com.example.Mystery", title: "Chapter 3", at: 10)
        let first = await hybrid.classify(mystery, context: ClassificationContext(recent: recent, modes: DefaultModes.all))
        XCTAssertEqual(first.category, .writing)
        XCTAssertEqual(first.source, .llm)
        XCTAssertEqual(first.suggestedMode, .writing)
        XCTAssertEqual(llm.lastRecent.count, 2)

        // Same app/title (different timestamp and idle) → cache.
        var again = mystery
        again.timestamp = t0.addingTimeInterval(30)
        again.idleSeconds = 5
        let second = await hybrid.classify(again, context: ClassificationContext())
        XCTAssertEqual(second.source, .cache)
        XCTAssertEqual(second.category, .writing)
        XCTAssertEqual(llm.activityCalls, 1)

        // A different title is a different key.
        _ = await hybrid.classify(sample("com.example.Mystery", title: "Chapter 4", at: 31), context: ClassificationContext())
        XCTAssertEqual(llm.activityCalls, 2)

        // After the TTL the answer is refreshed.
        clock.advance(by: .seconds(61))
        let third = await hybrid.classify(mystery, context: ClassificationContext())
        XCTAssertEqual(third.source, .llm)
        XCTAssertEqual(llm.activityCalls, 3)
        let stats = await hybrid.statistics
        XCTAssertEqual(stats.llmRequests, 3)
        XCTAssertEqual(stats.cacheHits, 1)
    }

    func testThresholdIsConfigurable() async {
        let llm = MockLLM.answering(.code)
        // Browsers are 0.5 confident: below 0.6 but above 0.4.
        let strict = HybridClassifier(llm: llm, policy: LLMUsagePolicy(confidenceThreshold: 0.4))
        let verdict = await strict.classify(sample("com.apple.Safari", at: 0), context: ClassificationContext())
        XCTAssertEqual(verdict.category, .browsing)
        XCTAssertEqual(llm.activityCalls, 0)

        let eager = HybridClassifier(llm: llm, policy: LLMUsagePolicy(confidenceThreshold: 0.6))
        let refined = await eager.classify(sample("com.apple.Safari", at: 0), context: ClassificationContext())
        XCTAssertEqual(refined.category, .code)
        XCTAssertEqual(llm.activityCalls, 1)
    }

    func testTimeoutFallsBackToRules() async {
        let clock = ManualClock(now: t0)
        let hybrid = HybridClassifier(llm: MockLLM.hanging, policy: LLMUsagePolicy(timeout: .seconds(5)), clock: clock)
        let task = Task { await hybrid.classify(sample("com.example.Mystery", at: 0), context: ClassificationContext()) }
        await eventually { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(5))
        let verdict = await task.value
        XCTAssertEqual(verdict.category, .other)
        XCTAssertEqual(verdict.source, .fallback)
        XCTAssertTrue(verdict.rationale.contains("timed out after 5s"), verdict.rationale)
        let stats = await hybrid.statistics
        XCTAssertEqual(stats.timeouts, 1)
    }

    func testTimeoutEvenIfTheLLMIgnoresCancellation() async {
        let clock = ManualClock(now: t0)
        let gate = Locked(false)
        let stubborn = MockLLM(activity: { _, _, _ in
            // Ignores cancellation: spins until the test opens the gate.
            while !gate.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            return ActivityVerdict(category: .media, confidence: 1, rationale: "late")
        })
        let hybrid = HybridClassifier(llm: stubborn, policy: LLMUsagePolicy(timeout: .seconds(1)), clock: clock)
        let task = Task { await hybrid.classify(sample("com.example.Mystery", at: 0), context: ClassificationContext()) }
        await eventually { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(1))
        let verdict = await task.value
        XCTAssertEqual(verdict.source, .fallback)
        gate.withLock { $0 = true }
    }

    func testErrorsFallBackToRules() async {
        let hybrid = HybridClassifier(llm: MockLLM.failing(), clock: ManualClock(now: t0))
        let verdict = await hybrid.classify(sample("com.example.Mystery", at: 0), context: ClassificationContext())
        XCTAssertEqual(verdict.source, .fallback)
        XCTAssertTrue(verdict.rationale.contains("LLM failed"), verdict.rationale)
        let stats = await hybrid.statistics
        XCTAssertEqual(stats.failures, 1)
    }

    func testRateLimit() async {
        let clock = ManualClock(now: t0)
        let llm = MockLLM.answering(.writing)
        let hybrid = HybridClassifier(llm: llm, policy: LLMUsagePolicy(maxRequestsPerMinute: 2), clock: clock)
        for index in 0..<3 {
            _ = await hybrid.classify(sample("com.example.App\(index)", at: 0), context: ClassificationContext())
        }
        XCTAssertEqual(llm.activityCalls, 2)
        let limited = await hybrid.classify(sample("com.example.App9", at: 0), context: ClassificationContext())
        XCTAssertEqual(limited.source, .fallback)
        XCTAssertTrue(limited.rationale.contains("rate limit"))
        clock.advance(by: .seconds(60))
        let allowed = await hybrid.classify(sample("com.example.App9", at: 0), context: ClassificationContext())
        XCTAssertEqual(allowed.source, .llm)
        let stats = await hybrid.statistics
        XCTAssertEqual(stats.rateLimited, 2)
    }

    func testConcurrentIdenticalRequestsShareOneCall() async {
        let clock = ManualClock(now: t0)
        let llm = MockLLM(activity: { _, _, _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return ActivityVerdict(category: .writing, confidence: 0.8, rationale: "slow")
        })
        let hybrid = HybridClassifier(llm: llm, clock: clock)
        let mystery = sample("com.example.Mystery", at: 0)
        async let first = hybrid.classify(mystery, context: ClassificationContext())
        async let second = hybrid.classify(mystery, context: ClassificationContext())
        let results = await [first, second]
        XCTAssertEqual(results.map(\.category), [.writing, .writing])
        XCTAssertEqual(Set(results.map(\.source)), [.llm, .cache])
        XCTAssertEqual(llm.activityCalls, 1)
    }

    func testLLMCanBeInstalledLater() async {
        let hybrid = HybridClassifier(llm: nil)
        await hybrid.setLLM(MockLLM.answering(.code))
        let verdict = await hybrid.classify(sample("com.example.Mystery", at: 0), context: ClassificationContext())
        XCTAssertEqual(verdict.category, .code)
    }
}
