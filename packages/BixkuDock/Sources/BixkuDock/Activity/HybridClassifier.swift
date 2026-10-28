import BixkuCore
import Foundation

/// Limits, timeouts and caching shared by the LLM-backed components.
public struct LLMUsagePolicy: Sendable, Equatable {
    /// Ask the LLM only when the rules' confidence is below this (0…1).
    public var confidenceThreshold: Double
    /// Give up on the LLM after this long and use the rules' answer.
    public var timeout: Duration
    /// Maximum LLM requests in any 60-second window.
    public var maxRequestsPerMinute: Int
    /// How long an LLM answer is reused for the same input.
    public var cacheTTL: TimeInterval
    /// Maximum cached answers (least recently stored are evicted first).
    public var cacheCapacity: Int

    public init(
        confidenceThreshold: Double = 0.6,
        timeout: Duration = .seconds(8),
        maxRequestsPerMinute: Int = 12,
        cacheTTL: TimeInterval = 30 * 60,
        cacheCapacity: Int = 512
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.timeout = timeout
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.cacheTTL = cacheTTL
        self.cacheCapacity = cacheCapacity
    }
}

/// Counters exposed for diagnostics and tests.
public struct LLMUsageStatistics: Sendable, Equatable {
    /// Answered by rules without consulting the LLM (confident, or no LLM configured).
    public var rulesOnly = 0
    public var llmRequests = 0
    public var llmAnswers = 0
    public var cacheHits = 0
    public var timeouts = 0
    public var failures = 0
    public var rateLimited = 0

    public init() {}
}

/// Time-based cache with a capacity bound.
struct TTLCache<Value: Sendable>: Sendable {
    private var entries: [String: (value: Value, stored: Date)] = [:]
    private var order: [String] = []
    let ttl: TimeInterval
    let capacity: Int

    init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: String, now: Date) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.stored) < ttl else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        return entry.value
    }

    mutating func store(_ value: Value, for key: String, now: Date) {
        if entries[key] != nil { order.removeAll { $0 == key } }
        entries[key] = (value, now)
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    var count: Int { entries.count }
}

/// Sliding-window request limiter.
struct RateLimiter: Sendable {
    let limit: Int
    let window: TimeInterval
    private var stamps: [Date] = []

    init(limit: Int, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Records a request at `now` if allowed; returns whether it was.
    mutating func acquire(now: Date) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

/// Rules first, language model only when the rules are unsure.
///
/// 1. ``RuleBasedClassifier``; if its confidence ≥ the threshold (or no LLM is
///    configured), that is the answer.
/// 2. Otherwise a cached LLM answer for the same app/title/site, if fresh.
/// 3. Otherwise the LLM, unless rate limited, with a timeout. Concurrent requests for
///    the same input share one call.
/// 4. Any failure (timeout, error, rate limit) falls back to the rules' verdict,
///    marked ``VerdictSource/fallback``.
public actor HybridClassifier: ActivityClassifier {
    public let rules: RuleBasedClassifier
    public let policy: LLMUsagePolicy
    private var llm: (any LLMClassifying)?
    private let clock: any BixkuClock
    private var cache: TTLCache<ActivityVerdict>
    private var limiter: RateLimiter
    private var inFlight: [String: Task<ActivityVerdict?, Never>] = [:]
    /// Number of recent samples passed to the LLM.
    private let recentLimit: Int
    public private(set) var statistics = LLMUsageStatistics()

    public init(
        rules: RuleBasedClassifier = RuleBasedClassifier(),
        llm: (any LLMClassifying)?,
        policy: LLMUsagePolicy = LLMUsagePolicy(),
        clock: any BixkuClock = SystemClock(),
        recentLimit: Int = 10
    ) {
        self.rules = rules
        self.llm = llm
        self.policy = policy
        self.clock = clock
        self.recentLimit = recentLimit
        cache = TTLCache(ttl: policy.cacheTTL, capacity: policy.cacheCapacity)
        limiter = RateLimiter(limit: policy.maxRequestsPerMinute)
    }

    /// Installs or removes the LLM at runtime (e.g. when the user configures a provider).
    public func setLLM(_ llm: (any LLMClassifying)?) {
        self.llm = llm
    }

    public var hasLLM: Bool {
        llm != nil
    }

    /// Cache key: what is on screen, coarsened to the site (not the full URL).
    static func cacheKey(for sample: ActivitySample) -> String {
        [sample.appBundleID?.lowercased() ?? "", sample.windowTitle ?? "", sample.urlHost ?? "", sample.document ?? ""]
            .joined(separator: "\u{1F}")
    }

    public func classify(_ sample: ActivitySample, context: ClassificationContext) async -> ActivityVerdict {
        let ruleVerdict = rules.verdict(for: sample)
        guard let llm, ruleVerdict.confidence < policy.confidenceThreshold else {
            statistics.rulesOnly += 1
            return ruleVerdict
        }
        let key = Self.cacheKey(for: sample)
        if var cached = cache.value(for: key, now: clock.now()) {
            statistics.cacheHits += 1
            cached.source = .cache
            return cached
        }
        if let shared = inFlight[key] {
            statistics.cacheHits += 1
            guard var verdict = await shared.value else { return fallback(ruleVerdict, because: "LLM unavailable") }
            verdict.source = .cache
            return verdict
        }
        guard limiter.acquire(now: clock.now()) else {
            statistics.rateLimited += 1
            return fallback(ruleVerdict, because: "LLM rate limit reached")
        }

        statistics.llmRequests += 1
        let recent = Array(context.recent.suffix(recentLimit))
        let modes = context.modes
        let timeout = policy.timeout
        let clock = clock
        let task = Task<Result<ActivityVerdict, Error>, Never> {
            do {
                return .success(try await withDeadline(timeout, clock: clock) {
                    try await llm.classify(sample, recent: recent, modes: modes)
                })
            } catch {
                return .failure(error)
            }
        }
        let shared = Task<ActivityVerdict?, Never> { try? await task.value.get() }
        inFlight[key] = shared
        let result = await task.value
        inFlight[key] = nil

        switch result {
        case .success(var verdict):
            statistics.llmAnswers += 1
            verdict.source = .llm
            cache.store(verdict, for: key, now: clock.now())
            return verdict
        case .failure(let error as DeadlineExceeded):
            statistics.timeouts += 1
            return fallback(ruleVerdict, because: "LLM \(error)")
        case .failure(let error):
            statistics.failures += 1
            return fallback(ruleVerdict, because: "LLM failed: \(error)")
        }
    }

    private func fallback(_ verdict: ActivityVerdict, because reason: String) -> ActivityVerdict {
        var verdict = verdict
        verdict.source = .fallback
        verdict.rationale += " (\(reason))"
        return verdict
    }
}
