import Foundation

/// A change to one setting (`newValue == nil` means it was removed).
public struct SettingsChange: Sendable, Equatable {
    public var key: String
    public var newValue: ConfigValue?

    public init(key: String, newValue: ConfigValue?) {
        self.key = key
        self.newValue = newValue
    }
}

/// User-editable settings of one module: a flat map of keys to ``ConfigValue``s
/// that both the module and its settings UI read and write, with change
/// notifications so either side can react.
public protocol SettingsStore: Sendable {
    func value(forKey key: String) async throws -> ConfigValue?
    func allValues() async throws -> [String: ConfigValue]
    /// Sets (or with `nil`, removes) a setting and notifies subscribers.
    func setValue(_ value: ConfigValue?, forKey key: String) async throws
    /// Changes made from now on.
    func changes() -> AsyncStream<SettingsChange>
}

/// Volatile settings.
public actor InMemorySettingsStore: SettingsStore {
    private var values: [String: ConfigValue]
    private nonisolated let broadcaster = Broadcaster<SettingsChange>()

    public init(_ values: [String: ConfigValue] = [:]) {
        self.values = values
    }

    public func value(forKey key: String) -> ConfigValue? {
        values[key]
    }

    public func allValues() -> [String: ConfigValue] {
        values
    }

    public func setValue(_ value: ConfigValue?, forKey key: String) throws {
        try StorageError.validate(key)
        guard values[key] != value else { return }
        values[key] = value
        broadcaster.broadcast(SettingsChange(key: key, newValue: value))
    }

    public nonisolated func changes() -> AsyncStream<SettingsChange> {
        broadcaster.subscribe(buffering: .unbounded) { $0 }
    }
}

/// Settings persisted as a single JSON object in an injected file. The file is
/// read lazily and rewritten atomically on every change.
public actor JSONFileSettingsStore: SettingsStore {
    public nonisolated let fileURL: URL
    private var cache: [String: ConfigValue]?
    private nonisolated let broadcaster = Broadcaster<SettingsChange>()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func value(forKey key: String) throws -> ConfigValue? {
        try load()[key]
    }

    public func allValues() throws -> [String: ConfigValue] {
        try load()
    }

    public func setValue(_ value: ConfigValue?, forKey key: String) throws {
        try StorageError.validate(key)
        var values = try load()
        guard values[key] != value else { return }
        values[key] = value
        try save(values)
        cache = values
        broadcaster.broadcast(SettingsChange(key: key, newValue: value))
    }

    public nonisolated func changes() -> AsyncStream<SettingsChange> {
        broadcaster.subscribe(buffering: .unbounded) { $0 }
    }

    private func load() throws -> [String: ConfigValue] {
        if let cache { return cache }
        let values: [String: ConfigValue]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            values = try JSONDecoder().decode([String: ConfigValue].self, from: Data(contentsOf: fileURL))
        } else {
            values = [:]
        }
        cache = values
        return values
    }

    private func save(_ values: [String: ConfigValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }
}
