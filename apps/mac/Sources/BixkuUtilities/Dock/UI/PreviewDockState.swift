import BixkuDock
import Foundation

/// A `DockStateProviding` backed by made-up data. It lets the UI run before (or
/// without) the real Dock engine; actions mutate the sample state locally.
actor PreviewDockState: DockStateProviding {
    private var snapshot: DockSnapshot
    private var continuations: [UUID: AsyncStream<DockSnapshot>.Continuation] = [:]

    init(now: Date = Date()) {
        snapshot = Self.sample(now: now)
    }

    func currentSnapshot() -> DockSnapshot {
        snapshot
    }

    func snapshots() -> AsyncStream<DockSnapshot> {
        var continuation: AsyncStream<DockSnapshot>.Continuation!
        let stream = AsyncStream<DockSnapshot> { continuation = $0 }
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    func selectMode(_ id: ModeID) {
        guard snapshot.catalog.contains(id), id != snapshot.activeModeID else { return }
        snapshot.activeModeID = id
        snapshot.modeStartedAt = Date()
        publish()
    }

    func releaseNotification(_ id: UUID) {
        snapshot.held.removeAll { $0.id == id }
        publish()
    }

    func deliverDigest() {
        snapshot.held.removeAll()
        publish()
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private static func sample(now: Date) -> DockSnapshot {
        let sample = ActivitySample(
            appBundleID: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "DockPanelView.swift",
            timestamp: now
        )
        let verdict = ActivityVerdict(
            category: .code,
            confidence: 0.92,
            suggestedMode: .building,
            rationale: "An IDE is in the foreground.",
            source: .rules
        )
        return DockSnapshot(
            activeModeID: .writing,
            modeStartedAt: now.addingTimeInterval(-25 * 60),
            activity: ClassifiedActivity(sample: sample, verdict: verdict),
            suggestedModeID: .building,
            held: [
                triaged("Alex", app: "Messages", bundleID: "com.apple.MobileSMS", category: .directMessage, action: .hold, now: now, age: 240),
                triaged("Build #42 passed", app: "Example CI", bundleID: "com.example.ci", category: .build, action: .summarize, now: now, age: 150),
                triaged("3 new messages in #general", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", category: .chat, action: .summarize, now: now, age: 60),
            ]
        )
    }

    private static func triaged(
        _ title: String,
        app: String,
        bundleID: String,
        category: NotificationCategory,
        action: NotificationAction,
        now: Date,
        age: TimeInterval
    ) -> TriagedNotification {
        let timestamp = now.addingTimeInterval(-age)
        return TriagedNotification(
            notification: IncomingNotification(
                appBundleID: bundleID,
                appName: app,
                title: title,
                category: category,
                timestamp: timestamp
            ),
            category: category,
            decision: TriageDecision(action: action, reason: "\(category) waits while writing"),
            modeID: .writing,
            triagedAt: timestamp
        )
    }
}
