import BixkuDock
import Foundation

/// Errors raised by ``ModeEditing`` operations that the store itself does not cover.
public enum ModeEditingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The mode was created by the user; there is no factory version to restore.
    case noFactoryVersion(ModeID)

    public var description: String {
        switch self {
        case .noFactoryVersion(let id):
            return "'\(id)' is not a built-in mode, so there is no factory version to restore"
        }
    }
}

/// What the settings screen needs from mode persistence. The app adapts the Dock's
/// `ModeStore` to it (``ModeStoreEditor``); tests and previews can supply their own.
public protocol ModeEditing: Sendable {
    /// The resolved modes (factory modes overlaid with the user's documents).
    func loadCatalog() async throws -> ModeCatalog
    /// Validates and stores a mode (a new user mode, or an override of a factory mode).
    func save(_ definition: ModeDefinition) async throws
    /// Deletes a user mode, or drops the user's override of a factory mode.
    func delete(_ id: ModeID) async throws
    /// Drops the user's override of a factory mode so the shipped version applies again.
    func restoreFactory(_ id: ModeID) async throws
    /// Drops every override of a factory mode. User-created modes are kept.
    func restoreAllFactory() async throws
    /// Emits the new catalog after every successful change, wherever it came from
    /// (this screen, the agent, a hand-edited file).
    func catalogChanges() -> AsyncStream<ModeCatalog>
}

/// ``ModeEditing`` on top of any ``ModeStore``.
public struct ModeStoreEditor: ModeEditing {
    public let store: any ModeStore

    public init(store: any ModeStore) {
        self.store = store
    }

    public func loadCatalog() async throws -> ModeCatalog {
        try await store.load()
    }

    public func save(_ definition: ModeDefinition) async throws {
        try await store.save(definition)
    }

    public func delete(_ id: ModeID) async throws {
        try await store.delete(id)
    }

    public func restoreFactory(_ id: ModeID) async throws {
        let catalog = try await store.load()
        switch catalog.mode(id)?.provenance {
        case .userOverride:
            try await store.delete(id)
        case .factory:
            return // already the shipped version
        case .user:
            throw ModeEditingError.noFactoryVersion(id)
        case nil:
            throw ModeStoreError.unknownMode(id)
        }
    }

    public func restoreAllFactory() async throws {
        let catalog = try await store.load()
        for mode in catalog.modes where mode.provenance == .userOverride {
            try await store.delete(mode.id)
        }
    }

    public func catalogChanges() -> AsyncStream<ModeCatalog> {
        store.changes()
    }
}
