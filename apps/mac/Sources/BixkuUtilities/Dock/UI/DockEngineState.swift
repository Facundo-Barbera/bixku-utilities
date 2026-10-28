import BixkuDock
import Foundation

/// Hands notifications released by the user back to them, with the digest when
/// everything was released at once. The default does nothing: until a delivery
/// mechanism exists, releasing only clears the notification from the Dock UI.
typealias HeldNotificationDelivery = @Sendable (_ released: [TriagedNotification], _ digest: NotificationDigest?) async -> Void

/// `DockStateProviding` backed by a running `DockEngine`.
actor DockEngineState: DockStateProviding {
    private let engine: DockEngine
    private let deliver: HeldNotificationDelivery
    private var subscribers: [UUID: AsyncStream<DockSnapshot>.Continuation] = [:]
    /// Notifications released one by one. The engine can only drain its whole held
    /// queue, so single releases are hidden here and leave the engine's queue (and the
    /// end-of-mode digest) untouched. Pruned as the engine's queue drains.
    private var released: Set<UUID> = []

    init(engine: DockEngine, deliver: @escaping HeldNotificationDelivery = { _, _ in }) {
        self.engine = engine
        self.deliver = deliver
    }

    func currentSnapshot() async -> DockSnapshot {
        await makeSnapshot(engine.state)
    }

    func snapshots() async -> AsyncStream<DockSnapshot> {
        let states = engine.states()
        let id = UUID()
        var continuation: AsyncStream<DockSnapshot>.Continuation!
        let stream = AsyncStream<DockSnapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        subscribers[id] = continuation
        let forwarding = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.forward(state, to: id)
            }
        }
        continuation.onTermination = { [weak self] _ in
            forwarding.cancel()
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func selectMode(_ id: ModeID) async {
        try? await engine.setMode(id)
    }

    func resumeAutomatic() async {
        await engine.resumeAutomatic()
    }

    func releaseNotification(_ id: UUID) async {
        guard let item = engine.state.held.first(where: { $0.id == id }), !released.contains(id) else { return }
        released.insert(id)
        await republish()
        await deliver([item], nil)
    }

    func deliverDigest() async {
        let state = engine.state
        let hidden = released
        released.removeAll()
        let pending = await engine.releaseHeld().filter { !hidden.contains($0.id) }
        await republish()
        guard !pending.isEmpty else { return }
        let digest = DigestBuilder().build(
            pending,
            modeID: state.mode.modeID,
            modeName: state.activeMode.name,
            start: state.mode.since,
            end: Date(),
            droppedCount: state.heldDropped
        )
        await deliver(pending, digest)
    }

    // MARK: Private

    private func forward(_ state: DockState, to id: UUID) async {
        let snapshot = await makeSnapshot(state)
        subscribers[id]?.yield(snapshot)
    }

    /// Pushes the current state to every subscriber. Needed after changes the engine
    /// does not publish itself (single releases).
    private func republish() async {
        let snapshot = await makeSnapshot(engine.state)
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func makeSnapshot(_ state: DockState) async -> DockSnapshot {
        let catalog = await engine.modes
        released.formIntersection(state.held.map(\.id))
        return DockSnapshot(
            catalog: catalog,
            activeModeID: state.mode.modeID,
            modeStartedAt: state.mode.since,
            isManual: state.isManual,
            activity: state.activity.map(Self.activity),
            suggestedModeID: state.suggestedMode,
            held: state.held.filter { !released.contains($0.id) }
        )
    }

    private static func activity(_ current: CurrentActivity) -> DockActivity {
        DockActivity(
            appName: current.sample.appName ?? current.sample.appBundleID,
            windowTitle: current.sample.windowTitle,
            category: current.category,
            confidence: current.verdict.confidence,
            rationale: current.verdict.rationale,
            source: current.verdict.source,
            attention: current.attention,
            isIdle: current.isIdle
        )
    }
}
