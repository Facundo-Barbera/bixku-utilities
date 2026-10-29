import BixkuDock
import Foundation

/// The mode agent's view of a running Dock: ``ModeAgentDockAccess`` over a
/// ``DockEngine`` and ``ModeStore`` over the store that engine reads its modes from.
///
/// Hand the same value to ``ProposalCoordinator`` as both `store` and `dock`.
/// Writes (create, adjust, delete, revert) go to the store and are pushed into the
/// engine right away with ``DockEngine/updateCatalog(_:)``, so the active mode
/// sees the change before the call returns. Mode switches use
/// ``DockEngine/activateMode(_:reason:)``, which never overrides the user's manual
/// choice.
///
/// The engine and store are resolved on every call, so an adapter built from a
/// ``DockModule`` follows the module across restarts; while it is stopped, reads
/// are empty and writes throw ``DockModuleError/notRunning``.
public struct DockEngineAccess: ModeAgentDockAccess, ModeStore {
    public typealias Running = (engine: DockEngine, store: any ModeStore)

    private let resolve: @Sendable () -> Running?

    public init(resolve: @escaping @Sendable () -> Running?) {
        self.resolve = resolve
    }

    public init(engine: DockEngine, store: any ModeStore) {
        self.init { (engine, store) }
    }

    /// Follows the engine and store of `module` while it runs.
    public init(module: DockModule) {
        self.init {
            guard let engine = module.engine, let store = module.modeStore else { return nil }
            return (engine, store)
        }
    }

    private func running() throws -> Running {
        guard let running = resolve() else { throw DockModuleError.notRunning }
        return running
    }

    // MARK: ModeAgentDockAccess

    public func activeMode() async -> ModeID? {
        resolve()?.engine.state.mode.modeID
    }

    public func setActiveMode(_ id: ModeID, reason: String) async throws {
        try await running().engine.activateMode(id, reason: reason)
    }

    public func recentActivity(limit: Int) async -> [ClassifiedActivity] {
        guard let engine = resolve()?.engine else { return [] }
        return await engine.recentActivity(limit: limit)
    }

    public func heldNotifications() async -> [TriagedNotification] {
        resolve()?.engine.state.held ?? []
    }

    public func releaseNotification(_ id: UUID) async throws {
        guard try await running().engine.releaseHeld(id) != nil else {
            throw ModeAgentError.unknownNotification(id)
        }
    }

    // MARK: ModeStore

    public func load() async throws -> ModeCatalog {
        try await running().store.load()
    }

    public func save(_ definition: ModeDefinition) async throws {
        let (engine, store) = try running()
        try await store.save(definition)
        await engine.updateCatalog(try await store.load())
    }

    public func delete(_ id: ModeID) async throws {
        let (engine, store) = try running()
        try await store.delete(id)
        await engine.updateCatalog(try await store.load())
    }

    public func changes() -> AsyncStream<ModeCatalog> {
        resolve()?.store.changes() ?? AsyncStream { $0.finish() }
    }
}
