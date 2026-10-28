import BixkuCore
import Foundation

/// Infers a ``NotificationCategory`` when the source did not provide one.
/// Keyword rules run first (a CI bot posting in a chat app is `build`), then
/// well-known apps.
public struct NotificationCategorizer: Sendable {
    public var keywordRules: [(keywords: [String], category: NotificationCategory)]
    public var appRules: [(apps: [String], category: NotificationCategory)]

    public init(
        keywordRules: [(keywords: [String], category: NotificationCategory)] = NotificationCategorizer.standardKeywordRules,
        appRules: [(apps: [String], category: NotificationCategory)] = NotificationCategorizer.standardAppRules
    ) {
        self.keywordRules = keywordRules
        self.appRules = appRules
    }

    public static let standardKeywordRules: [(keywords: [String], category: NotificationCategory)] = [
        (["mentioned you", "@here", "@channel", "replied to you", "tagged you"], .mention),
        (["build failed", "build succeeded", "build passed", "pipeline", "deploy", "workflow run", "checks failed", "checks passed"], .build),
        (["% off", "sale ends", "limited offer", "newsletter", "promo code", "discount"], .promotion),
    ]

    public static let standardAppRules: [(apps: [String], category: NotificationCategory)] = [
        (["com.apple.iCal", "com.flexibits.fantastical2.mac", "com.apple.reminders"], .calendar),
        (["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron"], .email),
        (["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.apple.FaceTime"], .directMessage),
        (["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2"], .chat),
        (["com.github.GitHubClient", "com.apple.dt.Xcode", "com.docker.docker"], .build),
        (["com.twitter.twitter-mac", "com.facebook.archon", "com.linkedin.*"], .social),
        (["com.apple.*"], .system),
    ]

    public func category(for notification: IncomingNotification) -> NotificationCategory {
        if let category = notification.category { return category }
        let text = notification.searchableText
        for rule in keywordRules where rule.keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return rule.category
        }
        for rule in appRules where AppPattern.matchesAny(rule.apps, bundleID: notification.appBundleID) {
            return rule.category
        }
        return .other
    }
}

/// Decides what to do with each notification given the active mode and activity.
///
/// Rule order (first that applies wins):
/// 1. the mode's `alwaysAllow` exceptions → allow;
/// 2. urgency (time-sensitive flag, urgent categories or keywords) → allow;
/// 3. `allowFromFocusedApp` and the notification comes from the frontmost app → allow;
/// 4. the mode's `rules`, in order (respecting `whileActivity`);
/// 5. the mode's default action. Only in this case is the optional LLM consulted
///    (rate limited, cached, with a timeout; failures keep the default).
public actor NotificationTriage {
    public let categorizer: NotificationCategorizer
    public let policy: LLMUsagePolicy
    private var llm: (any LLMNotificationTriaging)?
    private let clock: any BixkuClock
    private var cache: TTLCache<TriageDecision>
    private var limiter: RateLimiter
    public private(set) var statistics = LLMUsageStatistics()

    public init(
        categorizer: NotificationCategorizer = NotificationCategorizer(),
        llm: (any LLMNotificationTriaging)? = nil,
        policy: LLMUsagePolicy = LLMUsagePolicy(),
        clock: any BixkuClock = SystemClock()
    ) {
        self.categorizer = categorizer
        self.llm = llm
        self.policy = policy
        self.clock = clock
        cache = TTLCache(ttl: policy.cacheTTL, capacity: policy.cacheCapacity)
        limiter = RateLimiter(limit: policy.maxRequestsPerMinute)
    }

    public func setLLM(_ llm: (any LLMNotificationTriaging)?) {
        self.llm = llm
    }

    public func triage(
        _ notification: IncomingNotification,
        mode: ModeDefinition,
        activity: ClassifiedActivity?
    ) async -> TriagedNotification {
        let category = categorizer.category(for: notification)
        var (decision, isDefault) = Self.ruleDecision(for: notification, category: category, mode: mode, activity: activity)
        if isDefault, let llm {
            decision = await consult(llm, notification: notification, category: category, mode: mode, activity: activity, fallback: decision)
        } else {
            statistics.rulesOnly += 1
        }
        return TriagedNotification(
            notification: notification,
            category: category,
            decision: decision,
            modeID: mode.id,
            triagedAt: clock.now()
        )
    }

    /// The rules' decision and whether it is just the mode's default.
    public static func ruleDecision(
        for notification: IncomingNotification,
        category: NotificationCategory,
        mode: ModeDefinition,
        activity: ClassifiedActivity?
    ) -> (decision: TriageDecision, isDefault: Bool) {
        let policy = mode.notifications
        if policy.alwaysAllow.matches(notification, category: category) {
            return (TriageDecision(action: .allow, reason: "always allowed in \(mode.name)"), false)
        }
        if let urgency = policy.urgent.urgencyReason(for: notification, category: category) {
            return (TriageDecision(action: .allow, reason: "urgent: \(urgency)", isUrgent: true), false)
        }
        if policy.allowFromFocusedApp, let app = notification.appBundleID?.lowercased(),
            activity?.sample.appBundleID?.lowercased() == app
        {
            return (TriageDecision(action: .allow, reason: "from the app you are using"), false)
        }
        for (index, rule) in policy.rules.enumerated() where rule.match.matches(notification, category: category) {
            if let whileActivity = rule.whileActivity {
                guard let activity, whileActivity.matches(activity.sample, category: activity.verdict.category) else {
                    continue
                }
            }
            let reason = rule.note ?? "\(mode.name) rule \(index + 1): \(category) → \(rule.action)"
            return (TriageDecision(action: rule.action, reason: reason), false)
        }
        return (TriageDecision(action: policy.defaultAction, reason: "\(mode.name) default: \(policy.defaultAction)"), true)
    }

    private func consult(
        _ llm: any LLMNotificationTriaging,
        notification: IncomingNotification,
        category: NotificationCategory,
        mode: ModeDefinition,
        activity: ClassifiedActivity?,
        fallback: TriageDecision
    ) async -> TriageDecision {
        let key = [mode.id.rawValue, notification.appBundleID?.lowercased() ?? "", category.rawValue, notification.title]
            .joined(separator: "\u{1F}")
        if var cached = cache.value(for: key, now: clock.now()) {
            statistics.cacheHits += 1
            cached.source = .cache
            return cached
        }
        guard limiter.acquire(now: clock.now()) else {
            statistics.rateLimited += 1
            return Self.fallback(fallback, because: "LLM rate limit reached")
        }
        statistics.llmRequests += 1
        do {
            var decision = try await withDeadline(policy.timeout, clock: clock) {
                try await llm.triage(notification, category: category, mode: mode, activity: activity)
            }
            statistics.llmAnswers += 1
            decision.source = .llm
            cache.store(decision, for: key, now: clock.now())
            return decision
        } catch let error as DeadlineExceeded {
            statistics.timeouts += 1
            return Self.fallback(fallback, because: "LLM \(error)")
        } catch {
            statistics.failures += 1
            return Self.fallback(fallback, because: "LLM failed: \(error)")
        }
    }

    private static func fallback(_ decision: TriageDecision, because reason: String) -> TriageDecision {
        var decision = decision
        decision.source = .fallback
        decision.reason += " (\(reason))"
        return decision
    }
}

/// Held notifications waiting for the end of a mode, oldest first. Bounded: when
/// full, the oldest item is dropped and counted.
public struct HeldQueue: Sendable, Equatable {
    public private(set) var items: [TriagedNotification] = []
    public private(set) var droppedCount = 0
    public let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool {
        items.isEmpty && droppedCount == 0
    }

    public mutating func append(_ item: TriagedNotification) {
        items.append(item)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
            droppedCount += 1
        }
    }

    /// Removes and returns everything.
    public mutating func drain() -> (items: [TriagedNotification], dropped: Int) {
        defer {
            items.removeAll()
            droppedCount = 0
        }
        return (items, droppedCount)
    }
}
