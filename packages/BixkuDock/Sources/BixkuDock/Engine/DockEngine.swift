import BixkuCore
import Foundation

/// Errors raised by ``DockEngine`` commands.
public enum DockEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownMode(ModeID)
    /// The user chose the mode manually; only the user can change it.
    case manualModeActive(ModeID)

    public var description: String {
        switch self {
        case .unknownMode(let id): return "No mode with id '\(id)'"
        case .manualModeActive(let id): return "The user chose '\(id)' manually; it can only be changed by the user"
        }
    }
}

/// The Dock's brain: consumes activity samples and notifications, keeps the active
/// mode, classifies activity, triages notifications and publishes what happens.
///
/// - **Activity** → privacy redaction → classifier (deduplicated per window) →
///   ``ActivitySmoother`` → attention level → automatic transitions.
///   Publishes `activity.changed` when the foreground app/window changes and
///   `dock.activity-classified` when the smoothed category or attention changes.
/// - **Notifications** → ``NotificationTriage`` for the active mode and activity →
///   held queue. Publishes `notification.received` and `notification.triaged`.
/// - **Modes**: a manual choice (``setMode(_:until:)``) always wins and suspends
///   automatic transitions until it expires or ``resumeAutomatic()``. Otherwise the
///   mode follows the modes' ``ModeRule``s. Every change publishes `mode.changed`;
///   leaving a mode with held notifications publishes `dock.digest-ready`.
///
/// Time comes from the injected clock and from sample timestamps, so tests are
/// deterministic: evaluation happens "now" = max(clock time, latest sample time).
public actor DockEngine {
    public nonisolated let source: ModuleID?
    private let eventBus: EventBus
    private let clock: any BixkuClock
    private let classifier: any ActivityClassifier
    private let triage: NotificationTriage
    private let summarizer: (any DigestSummarizing)?
    private let digestBuilder = DigestBuilder()
    public nonisolated let configuration: DockConfiguration

    private var catalog: ModeCatalog
    private var selection: ModeSelection
    /// Automatic transitions wait ``DockConfiguration/minimumModeDwell`` after this.
    private var dwellAnchor: Date
    private var smoother: ActivitySmoother
    /// Classified samples, one entry per change of focus or idleness, oldest first.
    private var timeline: [ClassifiedActivity] = []
    private var latestSample: ActivitySample?
    private var current: CurrentActivity?
    private var cachedVerdict: (focusKey: String, verdict: ActivityVerdict)?
    private var held: HeldQueue
    private var lastDigest: NotificationDigest?
    private var suggestedMode: ModeID?
    private var tasks: [Task<Void, Never>] = []

    private let snapshot: Locked<DockState>
    private let subscribers = Locked<[UUID: AsyncStream<DockState>.Continuation]>([:])

    public init(
        catalog: ModeCatalog = .factory,
        classifier: any ActivityClassifier = RuleBasedClassifier(),
        triage: NotificationTriage = NotificationTriage(),
        summarizer: (any DigestSummarizing)? = nil,
        configuration: DockConfiguration = DockConfiguration(),
        eventBus: EventBus,
        source: ModuleID? = nil,
        clock: any BixkuClock = SystemClock()
    ) {
        let catalog = Self.ensureNonEmpty(catalog)
        let initial = Self.resolveDefault(configuration.defaultMode, in: catalog)
        self.catalog = catalog
        self.classifier = classifier
        self.triage = triage
        self.summarizer = summarizer
        self.configuration = configuration
        self.eventBus = eventBus
        self.source = source
        self.clock = clock
        smoother = ActivitySmoother(configuration: configuration.smoothing)
        held = HeldQueue(capacity: configuration.heldCapacity)
        selection = ModeSelection(modeID: initial, activation: .initial, since: clock.now())
        dwellAnchor = selection.since
        snapshot = Locked(DockState(
            mode: selection,
            activeMode: catalog.definition(initial)!,
            activity: nil,
            held: [],
            heldDropped: 0,
            lastDigest: nil,
            suggestedMode: nil,
            modeIssues: catalog.issues
        ))
    }

    // MARK: Lifecycle

    /// Publishes the initial `mode.changed`, consumes the given streams until they end
    /// (or ``stop()``), and re-evaluates time-based rules every
    /// ``DockConfiguration/tickInterval``.
    public func start(
        activity: AsyncStream<ActivitySample>? = nil,
        notifications: AsyncStream<IncomingNotification>? = nil
    ) {
        stop()
        publish(ModeChanged(previousModeID: nil, modeID: selection.modeID.rawValue, reason: selection.activation.description))
        if let activity {
            tasks.append(Task { [weak self] in
                for await sample in activity {
                    guard let self else { return }
                    await self.ingest(sample)
                }
            })
        }
        if let notifications {
            tasks.append(Task { [weak self] in
                for await notification in notifications {
                    guard let self else { return }
                    await self.ingest(notification)
                }
            })
        }
        if let interval = configuration.tickInterval {
            let clock = clock
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(for: interval) } catch { return }
                    guard let self else { return }
                    await self.tick()
                }
            })
        }
    }

    /// Cancels stream consumption and ticking. State is kept; ``start(activity:notifications:)`` may be called again.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    // MARK: State

    /// Latest state, readable from any thread (e.g. the UI).
    public nonisolated var state: DockState {
        snapshot.withLock { $0 }
    }

    /// The current state followed by every change (a slow consumer skips to the
    /// newest states).
    public nonisolated func states() -> AsyncStream<DockState> {
        let (stream, continuation) = AsyncStream.makeStream(of: DockState.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [subscribers] _ in
            subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuation.yield(state)
        return stream
    }

    public var modes: ModeCatalog {
        catalog
    }

    // MARK: Activity

    /// Processes one activity sample.
    public func ingest(_ incoming: ActivitySample) async {
        var sample = incoming
        if AppPattern.matchesAny(configuration.redactedApps, bundleID: sample.appBundleID) {
            sample = sample.redacted()
        }
        if let latest = latestSample, sample.timestamp < latest.timestamp { return }

        let verdict: ActivityVerdict
        if let cached = cachedVerdict, cached.focusKey == sample.focusKey {
            verdict = cached.verdict
        } else {
            let context = ClassificationContext(
                recent: Array(timeline.suffix(configuration.recentContext)),
                modes: catalog.definitions,
                activeMode: selection.modeID
            )
            verdict = await classifier.classify(sample, context: context)
            // Another sample may have been processed while classifying.
            if let latest = latestSample, sample.timestamp < latest.timestamp { return }
            cachedVerdict = (sample.focusKey, verdict)
        }

        let previous = latestSample
        latestSample = sample
        let isIdle = sample.isIdle(threshold: configuration.smoothing.idleThreshold)
        let classified = ClassifiedActivity(sample: sample, verdict: verdict)
        let focusChanged = previous?.focusKey != sample.focusKey
        let idleChanged = previous.map { $0.isIdle(threshold: configuration.smoothing.idleThreshold) } != isIdle
        if focusChanged || idleChanged {
            timeline.append(classified)
            smoother.record(classified)
            pruneTimeline(now: sample.timestamp)
        }
        if focusChanged {
            if let suggestion = verdict.suggestedMode, suggestion != selection.modeID, catalog.contains(suggestion) {
                suggestedMode = suggestion
            } else {
                suggestedMode = nil
            }
            publish(ActivityChanged(
                appBundleID: sample.appBundleID,
                appName: sample.appName ?? sample.appBundleID ?? "Unknown",
                windowTitle: sample.windowTitle,
                detail: sample.urlHost ?? sample.document,
                category: verdict.category.rawValue,
                confidence: verdict.confidence
            ))
        }
        refreshActivity(now: now())
        evaluateTransitions(now: now())
        publishState()
    }

    /// Re-evaluates time-dependent state (smoothing, transitions, manual expiry).
    public func tick() async {
        refreshActivity(now: now())
        evaluateTransitions(now: now())
        publishState()
    }

    private func now() -> Date {
        max(clock.now(), latestSample?.timestamp ?? .distantPast)
    }

    /// Recomputes ``CurrentActivity`` and publishes `dock.activity-classified` when the
    /// smoothed category, attention or idleness changed.
    private func refreshActivity(now: Date) {
        guard let sample = latestSample, let verdict = cachedVerdict?.verdict else { return }
        let category = smoother.update(at: now) ?? verdict.category
        let attention = activeDefinition.attention.level(for: sample, category: verdict.category)
        let updated = CurrentActivity(
            sample: sample,
            verdict: verdict,
            category: category,
            attention: attention,
            isIdle: sample.isIdle(threshold: configuration.smoothing.idleThreshold)
        )
        let previous = current
        current = updated
        if previous?.category != updated.category || previous?.attention != updated.attention
            || previous?.isIdle != updated.isIdle || previous?.sample.focusKey != updated.sample.focusKey
        {
            publish(ActivityClassified(activity: updated, modeID: selection.modeID))
        }
    }

    private func pruneTimeline(now: Date) {
        let longestRule = catalog.definitions.flatMap(\.transitions).map(\.forSeconds).max() ?? 0
        let horizon = min(configuration.maximumHistory, max(configuration.smoothing.window, longestRule + configuration.transitionGrace) * 2)
        let cutoff = now.addingTimeInterval(-horizon)
        // Keep the newest entry that started before the cutoff: it spans into the horizon.
        if let firstInside = timeline.firstIndex(where: { $0.sample.timestamp >= cutoff }), firstInside > 1 {
            timeline.removeFirst(firstInside - 1)
        }
        if timeline.count > 5_000 { timeline.removeFirst(timeline.count - 5_000) }
    }

    // MARK: Transitions

    private var activeDefinition: ModeDefinition {
        catalog.definition(selection.modeID) ?? catalog.definitions[0]
    }

    private func evaluateTransitions(now: Date) {
        if case .manual(let until) = selection.activation {
            guard let until, now >= until else { return }
            selection.activation = .automatic(reason: "manual choice expired")
            dwellAnchor = .distantPast
        }
        guard now.timeIntervalSince(dwellAnchor) >= configuration.minimumModeDwell else { return }

        var best: (mode: ModeDefinition, rule: ModeRule, held: TimeInterval, order: Int)?
        for (order, mode) in catalog.definitions.enumerated() where mode.id != selection.modeID {
            for rule in mode.transitions {
                if let from = rule.from, !from.contains(selection.modeID) { continue }
                let heldFor = duration(satisfying: rule, now: now)
                guard heldFor >= rule.forSeconds else { continue }
                if let current = best {
                    let better = (rule.priority, heldFor, -order) > (current.rule.priority, current.held, -current.order)
                    if !better { continue }
                }
                best = (mode, rule, heldFor, order)
            }
        }
        if let best {
            switchMode(to: best.mode.id, activation: .automatic(reason: best.rule.summary), at: now)
        }
    }

    /// How long `rule`'s condition has held, up to `now`.
    func duration(satisfying rule: ModeRule, now: Date) -> TimeInterval {
        switch rule.trigger {
        case .idle:
            return latestSample?.idleSeconds ?? 0
        case .activity:
            guard let matcher = rule.match else { return 0 }
            return trailingRun(now: now) { entry in
                !entry.sample.isIdle(threshold: configuration.smoothing.idleThreshold)
                    && matcher.matches(entry.sample, category: entry.verdict.category)
            }
        }
    }

    /// Matching time in the most recent run of entries satisfying `predicate`.
    /// Non-matching stretches of at most ``DockConfiguration/transitionGrace`` seconds
    /// are tolerated (not counted, but they do not end the run).
    private func trailingRun(now: Date, _ predicate: (ClassifiedActivity) -> Bool) -> TimeInterval {
        var total: TimeInterval = 0
        var gap: TimeInterval = 0
        var end = now
        for entry in timeline.reversed() {
            let duration = max(0, end.timeIntervalSince(entry.sample.timestamp))
            end = entry.sample.timestamp
            if predicate(entry) {
                total += duration
                gap = 0
            } else {
                gap += duration
                if gap > configuration.transitionGrace { break }
            }
        }
        return total
    }

    // MARK: Modes

    /// Activates `id` manually. Automatic transitions stay off until `until` (if given)
    /// or until ``resumeAutomatic()``.
    public func setMode(_ id: ModeID, until: Date? = nil) throws {
        guard catalog.contains(id) else { throw DockEngineError.unknownMode(id) }
        let now = now()
        if id == selection.modeID {
            selection.activation = .manual(until: until)
            dwellAnchor = now
        } else {
            switchMode(to: id, activation: .manual(until: until), at: now)
        }
        refreshActivity(now: now)
        publishState()
    }

    /// Switches mode on behalf of an automated actor (the mode agent). Unlike
    /// ``setMode(_:until:)`` this does not pin the mode — transition rules keep
    /// running — and it is refused while the user's manual choice is in effect.
    public func activateMode(_ id: ModeID, reason: String) throws {
        guard catalog.contains(id) else { throw DockEngineError.unknownMode(id) }
        let now = now()
        if case .manual(let until) = selection.activation, until.map({ now < $0 }) ?? true {
            throw DockEngineError.manualModeActive(selection.modeID)
        }
        if id != selection.modeID {
            switchMode(to: id, activation: .automatic(reason: reason), at: now)
        }
        publishState()
    }

    /// Ends a manual choice; the mode stays until a transition rule fires.
    public func resumeAutomatic() {
        guard selection.activation.isManual else { return }
        selection.activation = .automatic(reason: "resumed automatic mode")
        // Rules may fire right away, regardless of how recently the user chose the mode.
        dwellAnchor = .distantPast
        evaluateTransitions(now: now())
        publishState()
    }

    /// Replaces the catalog (e.g. after the user or the agent edited modes). If the
    /// active mode disappeared, the default mode takes over.
    public func updateCatalog(_ newCatalog: ModeCatalog) {
        catalog = Self.ensureNonEmpty(newCatalog)
        if !catalog.contains(selection.modeID) {
            let fallback = Self.resolveDefault(configuration.defaultMode, in: catalog)
            switchMode(to: fallback, activation: .automatic(reason: "mode '\(selection.modeID)' was removed"), at: now())
        }
        if let suggestion = suggestedMode, !catalog.contains(suggestion) { suggestedMode = nil }
        refreshActivity(now: now())
        publishState()
    }

    private func switchMode(to id: ModeID, activation: ModeActivation, at now: Date) {
        let previous = selection
        let previousDefinition = catalog.definition(previous.modeID)
        selection = ModeSelection(modeID: id, activation: activation, since: now)
        dwellAnchor = now
        if suggestedMode == id { suggestedMode = nil }

        let drained = held.drain()
        if let digest = digestBuilder.build(
            drained.items,
            modeID: previous.modeID,
            modeName: previousDefinition?.name ?? previous.modeID.rawValue,
            start: previous.since,
            end: now,
            droppedCount: drained.dropped
        ) {
            lastDigest = digest
            if let summarizer {
                summarize(digest, with: summarizer)
            } else {
                publish(DigestReady(digest: digest))
            }
        }
        publish(ModeChanged(previousModeID: previous.modeID.rawValue, modeID: id.rawValue, reason: activation.description))
        // Attention is relative to the mode.
        refreshActivity(now: now)
    }

    /// Asks the summarizer for prose (bounded by the LLM timeout), then publishes.
    private func summarize(_ digest: NotificationDigest, with summarizer: any DigestSummarizing) {
        let timeout = configuration.llm.timeout
        let clock = clock
        tasks.append(Task { [weak self] in
            var summarized = digest
            if let text = try? await withDeadline(timeout, clock: clock, operation: { try await summarizer.summarize(digest) }),
                !text.isEmpty
            {
                summarized.summary = text
            }
            await self?.finishDigest(summarized)
        })
    }

    private func finishDigest(_ digest: NotificationDigest) {
        if lastDigest?.start == digest.start, lastDigest?.modeID == digest.modeID { lastDigest = digest }
        publish(DigestReady(digest: digest))
        publishState()
    }

    // MARK: Notifications

    /// Triages one notification under the active mode and returns the decision.
    @discardableResult
    public func ingest(_ notification: IncomingNotification) async -> TriagedNotification {
        publish(NotificationReceived(
            appBundleID: notification.appBundleID,
            appName: notification.appName,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        ))
        let mode = activeDefinition
        let activity = current.map { ClassifiedActivity(sample: $0.sample, verdict: $0.verdict) }
        let triaged = await triage.triage(notification, mode: mode, activity: activity)
        // If the mode changed while triaging, the decision still applies to the mode it
        // was made for; held items then go into the next digest.
        if triaged.decision.action.isDeferred {
            held.append(triaged)
        }
        publish(NotificationTriaged(triaged))
        publishState()
        return triaged
    }

    /// Removes and returns everything held, without ending the mode (e.g. "show now").
    public func releaseHeld() -> [TriagedNotification] {
        let drained = held.drain().items
        publishState()
        return drained
    }

    // MARK: Helpers

    private func publish<Payload: BixkuEventPayload>(_ payload: Payload) {
        eventBus.publish(payload, source: source)
    }

    private func publishState() {
        let state = DockState(
            mode: selection,
            activeMode: activeDefinition,
            activity: current,
            held: held.items,
            heldDropped: held.droppedCount,
            lastDigest: lastDigest,
            suggestedMode: suggestedMode,
            modeIssues: catalog.issues
        )
        let changed = snapshot.withLock { snapshot -> Bool in
            guard snapshot != state else { return false }
            snapshot = state
            return true
        }
        guard changed else { return }
        for continuation in subscribers.withLock({ Array($0.values) }) {
            continuation.yield(state)
        }
    }

    private static func ensureNonEmpty(_ catalog: ModeCatalog) -> ModeCatalog {
        catalog.modes.isEmpty ? ModeCatalog(modes: ModeCatalog.factory.modes, issues: catalog.issues) : catalog
    }

    private static func resolveDefault(_ preferred: ModeID, in catalog: ModeCatalog) -> ModeID {
        if catalog.contains(preferred) { return preferred }
        if catalog.contains(DefaultModes.fallbackModeID) { return DefaultModes.fallbackModeID }
        return catalog.ids[0]
    }
}
