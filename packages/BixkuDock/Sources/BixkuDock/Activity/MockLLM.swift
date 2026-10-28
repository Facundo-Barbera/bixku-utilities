import Foundation

/// Scriptable stand-in for a language model, for tests, previews and running the
/// Dock without a provider. Each capability is a closure; every call is counted.
public final class MockLLM: LLMClassifying, LLMNotificationTriaging, DigestSummarizing, @unchecked Sendable {
    public typealias ActivityHandler = @Sendable (ActivitySample, [ClassifiedActivity], [ModeDefinition]) async throws -> ActivityVerdict
    public typealias NotificationHandler = @Sendable (IncomingNotification, NotificationCategory, ModeDefinition, ClassifiedActivity?) async throws -> TriageDecision
    public typealias SummaryHandler = @Sendable (NotificationDigest) async throws -> String

    public struct Unavailable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String { "mock LLM has no handler" }
    }

    private struct Counters {
        var activity = 0
        var notifications = 0
        var summaries = 0
        var lastRecent: [ClassifiedActivity] = []
        var lastSample: ActivitySample?
    }

    private let activityHandler: ActivityHandler?
    private let notificationHandler: NotificationHandler?
    private let summaryHandler: SummaryHandler?
    private let counters = Locked(Counters())

    public init(
        activity: ActivityHandler? = nil,
        notification: NotificationHandler? = nil,
        summary: SummaryHandler? = nil
    ) {
        activityHandler = activity
        notificationHandler = notification
        summaryHandler = summary
    }

    /// Always answers `category` with `confidence`.
    public static func answering(
        _ category: ActivityCategory,
        confidence: Double = 0.9,
        suggestedMode: ModeID? = nil
    ) -> MockLLM {
        MockLLM(activity: { _, _, _ in
            ActivityVerdict(
                category: category,
                confidence: confidence,
                suggestedMode: suggestedMode,
                rationale: "mock says \(category)",
                source: .llm
            )
        })
    }

    /// Never answers (until cancelled). Exercises timeouts.
    public static var hanging: MockLLM {
        let hang: @Sendable () async throws -> Never = {
            while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        }
        return MockLLM(
            activity: { _, _, _ in try await hang() },
            notification: { _, _, _, _ in try await hang() },
            summary: { _ in try await hang() }
        )
    }

    /// Always throws `error`.
    public static func failing(_ error: Error = Unavailable()) -> MockLLM {
        MockLLM(
            activity: { _, _, _ in throw error },
            notification: { _, _, _, _ in throw error },
            summary: { _ in throw error }
        )
    }

    public var activityCalls: Int { counters.withLock { $0.activity } }
    public var notificationCalls: Int { counters.withLock { $0.notifications } }
    public var summaryCalls: Int { counters.withLock { $0.summaries } }
    /// `recent` passed to the last activity call.
    public var lastRecent: [ClassifiedActivity] { counters.withLock { $0.lastRecent } }
    /// Sample passed to the last activity call.
    public var lastSample: ActivitySample? { counters.withLock { $0.lastSample } }

    public func classify(
        _ sample: ActivitySample,
        recent: [ClassifiedActivity],
        modes: [ModeDefinition]
    ) async throws -> ActivityVerdict {
        counters.withLock {
            $0.activity += 1
            $0.lastRecent = recent
            $0.lastSample = sample
        }
        guard let activityHandler else { throw Unavailable() }
        return try await activityHandler(sample, recent, modes)
    }

    public func triage(
        _ notification: IncomingNotification,
        category: NotificationCategory,
        mode: ModeDefinition,
        activity: ClassifiedActivity?
    ) async throws -> TriageDecision {
        counters.withLock { $0.notifications += 1 }
        guard let notificationHandler else { throw Unavailable() }
        return try await notificationHandler(notification, category, mode, activity)
    }

    public func summarize(_ digest: NotificationDigest) async throws -> String {
        counters.withLock { $0.summaries += 1 }
        guard let summaryHandler else { throw Unavailable() }
        return try await summaryHandler(digest)
    }
}
