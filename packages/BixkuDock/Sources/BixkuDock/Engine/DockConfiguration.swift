import BixkuCore
import Foundation

/// Tunables of the ``DockEngine``. Every field has a sensible default; the module
/// reads overrides from `[modules.dock]` (see ``init(config:llmConfig:)``).
public struct DockConfiguration: Sendable, Equatable {
    /// Mode at startup (falls back to ``DefaultModes/fallbackModeID`` if unknown).
    public var defaultMode: ModeID
    public var smoothing: ActivitySmoother.Configuration
    /// Interruptions shorter than this do not break an automatic-transition run.
    public var transitionGrace: TimeInterval
    /// After any mode change, automatic transitions wait at least this long.
    public var minimumModeDwell: TimeInterval
    /// How often time-based rules are re-evaluated without new samples (`nil` = never).
    public var tickInterval: Duration?
    /// Bundle id patterns whose window titles, URLs and documents are dropped on
    /// arrival — they never reach classifiers, the LLM, the bus or the state.
    public var redactedApps: [String]
    /// Use the notification LLM hook (when one is provided).
    public var classifyNotifications: Bool
    /// LLM limits for activity classification and notification triage.
    public var llm: LLMUsagePolicy
    public var heldCapacity: Int
    /// Number of recent classified samples given to classifiers as context.
    public var recentContext: Int
    /// Upper bound for activity history kept for transition rules.
    public var maximumHistory: TimeInterval

    public init(
        defaultMode: ModeID = DefaultModes.fallbackModeID,
        smoothing: ActivitySmoother.Configuration = .init(),
        transitionGrace: TimeInterval = 30,
        minimumModeDwell: TimeInterval = 60,
        tickInterval: Duration? = .seconds(10),
        redactedApps: [String] = [],
        classifyNotifications: Bool = true,
        llm: LLMUsagePolicy = LLMUsagePolicy(),
        heldCapacity: Int = 500,
        recentContext: Int = 10,
        maximumHistory: TimeInterval = 4 * 3600
    ) {
        self.defaultMode = defaultMode
        self.smoothing = smoothing
        self.transitionGrace = transitionGrace
        self.minimumModeDwell = minimumModeDwell
        self.tickInterval = tickInterval
        self.redactedApps = redactedApps
        self.classifyNotifications = classifyNotifications
        self.llm = llm
        self.heldCapacity = heldCapacity
        self.recentContext = recentContext
        self.maximumHistory = maximumHistory
    }

    /// Reads overrides from the module's config table (`[modules.dock]`) and the
    /// shared `[llm]` table. Unknown or mistyped keys keep their defaults.
    ///
    /// | key | type | default |
    /// | --- | --- | --- |
    /// | `default_mode` | string | `free` |
    /// | `classify_notifications` | bool | `true` |
    /// | `privacy.redact_window_titles_for` | [string] | `[]` |
    /// | `smoothing_window_seconds` | number | 90 |
    /// | `idle_threshold_seconds` | number | 120 |
    /// | `transition_grace_seconds` | number | 30 |
    /// | `minimum_mode_dwell_seconds` | number | 60 |
    /// | `tick_interval_seconds` | number (0 disables) | 10 |
    /// | `llm_confidence_threshold` | number 0…1 | 0.6 |
    /// | `llm_max_requests_per_minute` | integer | 12 |
    /// | `[llm] request_timeout_seconds` | number | 8 |
    public init(config: any ConfigProvider, llmConfig: (any ConfigProvider)? = nil) {
        self.init()
        if let mode = config.string("default_mode") { defaultMode = ModeID(rawValue: mode) }
        if let value = config.bool("classify_notifications") { classifyNotifications = value }
        if let apps = config.strings("privacy.redact_window_titles_for") { redactedApps = apps }
        if let value = config.double("smoothing_window_seconds"), value > 0 { smoothing.window = value }
        if let value = config.double("idle_threshold_seconds"), value > 0 { smoothing.idleThreshold = value }
        if let value = config.double("transition_grace_seconds"), value >= 0 { transitionGrace = value }
        if let value = config.double("minimum_mode_dwell_seconds"), value >= 0 { minimumModeDwell = value }
        if let value = config.double("tick_interval_seconds") {
            tickInterval = value > 0 ? .milliseconds(Int64(value * 1000)) : nil
        }
        if let value = config.double("llm_confidence_threshold"), (0...1).contains(value) { llm.confidenceThreshold = value }
        if let value = config.int("llm_max_requests_per_minute"), value >= 0 { llm.maxRequestsPerMinute = value }
        if let value = llmConfig?.double("request_timeout_seconds"), value > 0 {
            llm.timeout = .milliseconds(Int64(value * 1000))
        }
    }
}
