import Foundation

/// Creates the per-module ``ModuleStorage`` and ``SettingsStore``. Repeated calls for
/// the same module return the same instances, so a module and its settings UI share
/// one store.
public protocol ModuleStorageFactory: Sendable {
    func storage(for moduleID: ModuleID) throws -> any ModuleStorage
    func settings(for moduleID: ModuleID) throws -> any SettingsStore
}

/// Volatile stores for every module.
public final class InMemoryStorageFactory: ModuleStorageFactory, @unchecked Sendable {
    private let stores = Locked<[ModuleID: (InMemoryModuleStorage, InMemorySettingsStore)]>([:])

    public init() {}

    public func storage(for moduleID: ModuleID) throws -> any ModuleStorage {
        stores(for: moduleID).0
    }

    public func settings(for moduleID: ModuleID) throws -> any SettingsStore {
        stores(for: moduleID).1
    }

    private func stores(for moduleID: ModuleID) -> (InMemoryModuleStorage, InMemorySettingsStore) {
        stores.withLock { stores in
            if let existing = stores[moduleID] { return existing }
            let created = (InMemoryModuleStorage(), InMemorySettingsStore())
            stores[moduleID] = created
            return created
        }
    }
}

/// File-backed stores under an injected root directory:
///
/// ```
/// <root>/<module-id>/data/<key>.json     ModuleStorage
/// <root>/<module-id>/settings.json       SettingsStore
/// ```
///
/// The host picks the root (on macOS: the app's Application Support directory).
public final class FileStorageFactory: ModuleStorageFactory, @unchecked Sendable {
    public let rootDirectory: URL
    private let stores = Locked<[ModuleID: (FileModuleStorage, JSONFileSettingsStore)]>([:])

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func directory(for moduleID: ModuleID) throws -> URL {
        guard moduleID.isValid else { throw ModuleError.invalidModuleID(moduleID.rawValue) }
        return rootDirectory.appendingPathComponent(moduleID.rawValue, isDirectory: true)
    }

    public func storage(for moduleID: ModuleID) throws -> any ModuleStorage {
        try stores(for: moduleID).0
    }

    public func settings(for moduleID: ModuleID) throws -> any SettingsStore {
        try stores(for: moduleID).1
    }

    private func stores(for moduleID: ModuleID) throws -> (FileModuleStorage, JSONFileSettingsStore) {
        let directory = try directory(for: moduleID)
        return stores.withLock { stores in
            if let existing = stores[moduleID] { return existing }
            let created = (
                FileModuleStorage(directory: directory.appendingPathComponent("data", isDirectory: true)),
                JSONFileSettingsStore(fileURL: directory.appendingPathComponent("settings.json", isDirectory: false))
            )
            stores[moduleID] = created
            return created
        }
    }
}
