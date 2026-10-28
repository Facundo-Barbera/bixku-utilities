import Foundation

/// Read-only access to the app configuration (`config.local.toml` on disk, or
/// anything else the host injects). Modules never write configuration; user-editable
/// state belongs in ``SettingsStore``.
public protocol ConfigProvider: Sendable {
    /// The value at a dotted key path (`"llm.model"`), or `nil` if absent.
    func value(forKeyPath keyPath: String) -> ConfigValue?
}

extension ConfigProvider {
    public func string(_ keyPath: String) -> String? {
        value(forKeyPath: keyPath)?.stringValue
    }

    public func int(_ keyPath: String) -> Int? {
        value(forKeyPath: keyPath)?.intValue
    }

    public func double(_ keyPath: String) -> Double? {
        value(forKeyPath: keyPath)?.doubleValue
    }

    public func bool(_ keyPath: String) -> Bool? {
        value(forKeyPath: keyPath)?.boolValue
    }

    public func strings(_ keyPath: String) -> [String]? {
        value(forKeyPath: keyPath)?.arrayValue?.compactMap(\.stringValue)
    }

    /// A provider whose key paths are relative to `prefix` (`"modules.dock"`).
    public func scoped(to prefix: String) -> any ConfigProvider {
        ScopedConfigProvider(base: self, prefix: prefix)
    }
}

/// Configuration backed by an in-memory table.
public struct StaticConfigProvider: ConfigProvider {
    public let root: ConfigValue

    public init(_ table: [String: ConfigValue] = [:]) {
        self.root = .table(table)
    }

    /// Parses TOML text (see ``TOMLParser`` for the supported subset).
    public init(toml: String) throws {
        self.init(try TOMLParser.parse(toml))
    }

    /// Loads a TOML file. A missing file yields an empty configuration.
    public init(contentsOf fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.init()
            return
        }
        let data = try Data(contentsOf: fileURL)
        try self.init(toml: String(decoding: data, as: UTF8.self))
    }

    public func value(forKeyPath keyPath: String) -> ConfigValue? {
        root[keyPath: keyPath]
    }
}

struct ScopedConfigProvider: ConfigProvider {
    let base: any ConfigProvider
    let prefix: String

    func value(forKeyPath keyPath: String) -> ConfigValue? {
        if keyPath.isEmpty { return base.value(forKeyPath: prefix) }
        return base.value(forKeyPath: prefix.isEmpty ? keyPath : "\(prefix).\(keyPath)")
    }
}
