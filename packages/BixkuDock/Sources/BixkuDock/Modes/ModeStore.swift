import BixkuCore
import Foundation

/// Errors raised by ``ModeStore`` writes.
public enum ModeStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(ModeValidationError)
    case unknownMode(ModeID)
    /// Factory modes can be overridden but not deleted.
    case cannotDeleteFactoryMode(ModeID)

    public var description: String {
        switch self {
        case .invalid(let error):
            return error.description
        case .unknownMode(let id):
            return "No mode with id '\(id)'"
        case .cannotDeleteFactoryMode(let id):
            return "'\(id)' is a built-in mode; it can be edited (overridden) but not deleted"
        }
    }
}

/// Persistence of modes. Implementations overlay user documents on the factory
/// modes: a user document with a factory id replaces that factory mode.
public protocol ModeStore: Sendable {
    /// Resolves the catalog. Invalid user documents are skipped and reported in
    /// ``ModeCatalog/issues``; this only throws if the backend itself fails.
    func load() async throws -> ModeCatalog
    /// Validates and stores a user mode (creating it or overriding a factory mode).
    func save(_ definition: ModeDefinition) async throws
    /// Removes a user mode, or a user override (restoring the factory mode).
    func delete(_ id: ModeID) async throws
    /// Emits the new catalog after every successful ``save(_:)`` / ``delete(_:)``.
    func changes() -> AsyncStream<ModeCatalog>
}

/// Raw storage of user mode documents (one JSON document per mode id).
public protocol ModeDocumentBackend: Sendable {
    func documentIDs() async throws -> [String]
    func readDocument(_ id: String) async throws -> Data?
    func writeDocument(_ data: Data, id: String) async throws
    func removeDocument(_ id: String) async throws
}

/// `<directory>/<mode-id>.json`. The directory is injected (the app passes a folder
/// inside its Application Support directory) and created on first write.
public struct FileModeBackend: ModeDocumentBackend {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func documentIDs() throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    public func readDocument(_ id: String) throws -> Data? {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func writeDocument(_ data: Data, id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(id), options: .atomic)
    }

    public func removeDocument(_ id: String) throws {
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }
}

/// Stores mode documents in a module's ``ModuleStorage`` under `mode.<id>` keys.
public struct StorageModeBackend: ModeDocumentBackend {
    public static let keyPrefix = "mode."
    public let storage: any ModuleStorage

    public init(storage: any ModuleStorage) {
        self.storage = storage
    }

    public func documentIDs() async throws -> [String] {
        try await storage.keys()
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { String($0.dropFirst(Self.keyPrefix.count)) }
            .sorted()
    }

    public func readDocument(_ id: String) async throws -> Data? {
        try await storage.data(forKey: Self.keyPrefix + id)
    }

    public func writeDocument(_ data: Data, id: String) async throws {
        try await storage.setData(data, forKey: Self.keyPrefix + id)
    }

    public func removeDocument(_ id: String) async throws {
        try await storage.setData(nil, forKey: Self.keyPrefix + id)
    }
}

/// Volatile backend for tests and previews.
public actor InMemoryModeBackend: ModeDocumentBackend {
    private var documents: [String: Data]

    public init(documents: [String: Data] = [:]) {
        self.documents = documents
    }

    public func documentIDs() -> [String] {
        documents.keys.sorted()
    }

    public func readDocument(_ id: String) -> Data? {
        documents[id]
    }

    public func writeDocument(_ data: Data, id: String) {
        documents[id] = data
    }

    public func removeDocument(_ id: String) {
        documents[id] = nil
    }
}

/// The standard ``ModeStore``: factory modes overlaid with JSON user documents kept
/// in a ``ModeDocumentBackend``. Documents are migrated and validated on load;
/// saves always write the current schema.
public actor JSONModeStore: ModeStore {
    public nonisolated let backend: any ModeDocumentBackend
    public nonisolated let factoryModes: [ModeDefinition]
    private let migrator: ModeMigrator
    private let validator: ModeValidator
    private let subscribers = Locked<[UUID: AsyncStream<ModeCatalog>.Continuation]>([:])

    public init(
        backend: any ModeDocumentBackend,
        factoryModes: [ModeDefinition] = DefaultModes.all,
        migrator: ModeMigrator = ModeMigrator(),
        validator: ModeValidator = ModeValidator()
    ) {
        self.backend = backend
        self.factoryModes = factoryModes
        self.migrator = migrator
        self.validator = validator
    }

    /// Modes stored as `<directory>/<mode-id>.json`.
    public init(directory: URL, factoryModes: [ModeDefinition] = DefaultModes.all) {
        self.init(backend: FileModeBackend(directory: directory), factoryModes: factoryModes)
    }

    public func load() async throws -> ModeCatalog {
        let factoryIDs = Set(factoryModes.map(\.id))
        var userModes: [ModeID: ModeDefinition] = [:]
        var issues: [ModeLoadIssue] = []

        let documents = try await backend.documentIDs()
        // First pass: decode everything so cross references can see every mode id.
        var decoded: [(document: String, definition: ModeDefinition)] = []
        for document in documents {
            guard let data = try await backend.readDocument(document) else { continue }
            do {
                let (definition, _) = try migrator.decode(data)
                guard definition.id.rawValue == document else {
                    issues.append(ModeLoadIssue(
                        document: document,
                        message: "id '\(definition.id)' does not match the document name '\(document)'"
                    ))
                    continue
                }
                decoded.append((document, definition))
            } catch let error as ModeDocumentError {
                issues.append(ModeLoadIssue(document: document, message: error.description))
            }
        }
        let knownIDs = factoryIDs.union(decoded.map(\.definition.id))
        for (document, definition) in decoded {
            let problems = validator.issues(in: definition, knownModes: knownIDs)
            if problems.isEmpty {
                userModes[definition.id] = definition
            } else {
                issues.append(ModeLoadIssue(document: document, message: problems.map(\.description).joined(separator: "; ")))
            }
        }

        var modes = factoryModes.map { factory -> Mode in
            if let override = userModes[factory.id] {
                return Mode(definition: override, provenance: .userOverride)
            }
            return Mode(definition: factory, provenance: .factory)
        }
        modes += userModes.values
            .filter { !factoryIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map { Mode(definition: $0, provenance: .user) }
        return ModeCatalog(modes: modes, issues: issues)
    }

    public func save(_ definition: ModeDefinition) async throws {
        var definition = definition
        definition.schemaVersion = ModeDefinition.currentSchemaVersion
        let current = try await load()
        let known = Set(current.ids).union([definition.id])
        do {
            try validator.validate(definition, knownModes: known)
        } catch let error as ModeValidationError {
            throw ModeStoreError.invalid(error)
        }
        try await backend.writeDocument(try Self.encode(definition), id: definition.id.rawValue)
        try await notify()
    }

    public func delete(_ id: ModeID) async throws {
        let exists = try await backend.readDocument(id.rawValue) != nil
        guard exists else {
            if factoryModes.contains(where: { $0.id == id }) { throw ModeStoreError.cannotDeleteFactoryMode(id) }
            throw ModeStoreError.unknownMode(id)
        }
        try await backend.removeDocument(id.rawValue)
        try await notify()
    }

    public nonisolated func changes() -> AsyncStream<ModeCatalog> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModeCatalog.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [subscribers] _ in
            subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Pretty, key-sorted JSON (stable diffs if the user keeps modes in git).
    public static func encode(_ definition: ModeDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(definition)
    }

    private func notify() async throws {
        let catalog = try await load()
        for continuation in subscribers.withLock({ Array($0.values) }) {
            continuation.yield(catalog)
        }
    }
}
