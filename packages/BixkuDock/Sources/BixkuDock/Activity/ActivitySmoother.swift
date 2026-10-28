import Foundation

/// Turns a stream of per-sample verdicts into a stable "current category".
///
/// - **Duration weighting**: each verdict counts for as long as it stayed in the
///   foreground (until the next sample, or until now for the latest one), multiplied
///   by its confidence, within a sliding window.
/// - **Hysteresis**: the current category only changes when another category's share
///   of the window exceeds it by ``Configuration/switchMargin``. Glancing at chat for a
///   few seconds while coding does not flip the category.
/// - Idle time does not count.
public struct ActivitySmoother: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Length of the sliding window, in seconds.
        public var window: TimeInterval
        /// Share advantage (0…1) a challenger needs to replace the current category.
        public var switchMargin: Double
        /// Samples whose idle time is at least this many seconds count as idle.
        public var idleThreshold: TimeInterval
        /// Floor applied to confidences so low-confidence time still counts a little.
        public var minimumWeight: Double

        public init(window: TimeInterval = 90, switchMargin: Double = 0.2, idleThreshold: TimeInterval = 120, minimumWeight: Double = 0.1) {
            self.window = window
            self.switchMargin = switchMargin
            self.idleThreshold = idleThreshold
            self.minimumWeight = minimumWeight
        }
    }

    private struct Entry: Sendable {
        var start: Date
        var category: ActivityCategory
        var weight: Double
        var idle: Bool
    }

    public var configuration: Configuration
    private var entries: [Entry] = []
    /// The smoothed category (`nil` until the first sample).
    public private(set) var current: ActivityCategory?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Records a classified sample. Samples must arrive in time order; older ones are ignored.
    public mutating func record(_ activity: ClassifiedActivity) {
        if let last = entries.last, activity.sample.timestamp < last.start { return }
        entries.append(Entry(
            start: activity.sample.timestamp,
            category: activity.verdict.category,
            weight: max(configuration.minimumWeight, activity.verdict.confidence),
            idle: activity.sample.isIdle(threshold: configuration.idleThreshold)
        ))
    }

    /// Share of weighted, non-idle time per category in the window ending at `now`
    /// (values sum to 1, or the result is empty).
    public func shares(at now: Date) -> [ActivityCategory: Double] {
        let windowStart = now.addingTimeInterval(-configuration.window)
        var totals: [ActivityCategory: Double] = [:]
        for (index, entry) in entries.enumerated() where !entry.idle {
            let end = index + 1 < entries.count ? entries[index + 1].start : now
            let duration = min(end, now).timeIntervalSince(max(entry.start, windowStart))
            if duration > 0 { totals[entry.category, default: 0] += duration * entry.weight }
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return [:] }
        return totals.mapValues { $0 / sum }
    }

    /// Re-evaluates the current category at `now` and returns it.
    @discardableResult
    public mutating func update(at now: Date) -> ActivityCategory? {
        prune(before: now.addingTimeInterval(-configuration.window))
        let shares = shares(at: now)
        guard let current else {
            // Nothing established yet: adopt the leader, or the newest sample.
            self.current = Self.leader(of: shares) ?? entries.last(where: { !$0.idle })?.category
            return self.current
        }
        guard let leader = Self.leader(of: shares), leader != current else { return current }
        if shares[leader, default: 0] - shares[current, default: 0] >= configuration.switchMargin {
            self.current = leader
        }
        return self.current
    }

    /// Forgets everything (e.g. after the user was away).
    public mutating func reset() {
        entries.removeAll()
        current = nil
    }

    private static func leader(of shares: [ActivityCategory: Double]) -> ActivityCategory? {
        shares.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Drops entries that ended before `windowStart` (keeps the one spanning it).
    private mutating func prune(before windowStart: Date) {
        guard let firstInWindow = entries.firstIndex(where: { $0.start >= windowStart }) else {
            if entries.count > 1 { entries.removeFirst(entries.count - 1) }
            return
        }
        let keepFrom = max(0, firstInWindow - 1)
        if keepFrom > 0 { entries.removeFirst(keepFrom) }
    }
}
