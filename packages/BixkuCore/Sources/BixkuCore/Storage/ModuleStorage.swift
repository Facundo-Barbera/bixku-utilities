import Foundation

/// Errors raised by storage and settings implementations.
public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Keys must match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}` (they become file names).
    case invalidKey(String)

    public var description: String {
        switch self {
        case .invalidKey(let key):
            return "Invalid storage key '\(key)' (allowed: letters, digits, '.', '_', '-'; must start with a letter or digit)"
        }
    }

    static func validate(_ key: String) throws {
        guard isValid(key) else { throw StorageError.invalidKey(key) }
    }

    static func isValid(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= 128, isAlphanumeric(first) else {
            return false
        }
        return key.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// Private persistent key/value storage of one module (state, caches, user-made
/// content such as Dock modes). Values are JSON documents.
public protocol ModuleStorage: Sendable {
    /// Raw JSON stored under `key`, or `nil`.
    func data(forKey key: String) async throws -> Data?
    /// Stores `data` (JSON) under `key`; `nil` removes the key.
    func setData(_ data: Data?, forKey key: String) async throws
    /// All stored keys, sorted.
    func keys() async throws -> [String]
}

extension ModuleStorage {
    /// Decodes the value stored under `key`, or returns `nil` if absent.
    public func value<Value: Decodable>(_ type: Value.Type, forKey key: String) async throws -> Value? {
        guard let data = try await data(forKey: key) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Encodes `value` as JSON and stores it under `key`.
    public func setValue<Value: Encodable>(_ value: Value, forKey key: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await setData(try encoder.encode(value), forKey: key)
    }

    public func removeValue(forKey key: String) async throws {
        try await setData(nil, forKey: key)
    }
}

/// Volatile storage (tests, previews, ephemeral sessions).
public actor InMemoryModuleStorage: ModuleStorage {
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) throws -> Data? {
        try StorageError.validate(key)
        return values[key]
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        try StorageError.validate(key)
        values[key] = data
    }

    public func keys() -> [String] {
        values.keys.sorted()
    }
}

/// Storage backed by one `<key>.json` file per key inside an injected directory.
/// The directory is created on first write; writes are atomic.
public actor FileModuleStorage: ModuleStorage {
    public nonisolated let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func data(forKey key: String) throws -> Data? {
        let url = try fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        let url = try fileURL(forKey: key)
        if let data {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func keys() throws -> [String] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .filter(StorageError.isValid)
            .sorted()
    }

    private func fileURL(forKey key: String) throws -> URL {
        try StorageError.validate(key)
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }
}
