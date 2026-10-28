import Foundation

/// Errors reading a mode document (before validation).
public enum ModeDocumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case notAnObject
    case invalidSchemaVersion(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case missingMigration(from: Int)
    case decoding(String)

    public var description: String {
        switch self {
        case .invalidJSON(let reason):
            return "not valid JSON: \(reason)"
        case .notAnObject:
            return "a mode document must be a JSON object"
        case .invalidSchemaVersion(let value):
            return "schemaVersion must be a positive integer, found \(value)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "schemaVersion \(found) is newer than this app supports (\(supported)); update the app"
        case .missingMigration(let from):
            return "no migration from schemaVersion \(from)"
        case .decoding(let reason):
            return reason
        }
    }
}

/// One schema upgrade step, from `fromVersion` to `fromVersion + 1`, applied to the
/// raw JSON object before decoding.
public struct ModeMigration: Sendable {
    public let fromVersion: Int
    public let migrate: @Sendable (inout [String: Any]) throws -> Void

    public init(fromVersion: Int, migrate: @escaping @Sendable (inout [String: Any]) throws -> Void) {
        self.fromVersion = fromVersion
        self.migrate = migrate
    }
}

/// Upgrades mode documents written by older builds to the current schema.
///
/// Documents without `schemaVersion` are treated as version 1. Documents from a
/// newer build are rejected rather than guessed at. To change the schema: bump
/// ``ModeDefinition/currentSchemaVersion``, add a ``ModeMigration`` from the previous
/// version to ``builtIn``, and add a test with a document in the old format.
public struct ModeMigrator: Sendable {
    /// Migrations shipped with this build. Schema 1 is the first public schema.
    public static let builtIn: [ModeMigration] = []

    public let currentVersion: Int
    private let migrations: [Int: ModeMigration]

    public init(
        currentVersion: Int = ModeDefinition.currentSchemaVersion,
        migrations: [ModeMigration] = ModeMigrator.builtIn
    ) {
        self.currentVersion = currentVersion
        self.migrations = Dictionary(migrations.map { ($0.fromVersion, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The result of reading a document.
    public struct Result: @unchecked Sendable {
        /// The upgraded JSON object (`schemaVersion` set to the current version).
        public var object: [String: Any]
        /// The version the document was written with.
        public var originalVersion: Int

        public var wasMigrated: Bool {
            originalVersion != (object["schemaVersion"] as? Int)
        }
    }

    /// Parses `data` and applies every migration up to ``currentVersion``.
    public func migrate(_ data: Data) throws -> Result {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ModeDocumentError.invalidJSON(Self.describe(error))
        }
        guard var object = parsed as? [String: Any] else { throw ModeDocumentError.notAnObject }
        let original = try Self.schemaVersion(of: data, object: object)
        guard original <= currentVersion else {
            throw ModeDocumentError.unsupportedSchemaVersion(found: original, supported: currentVersion)
        }
        var version = original
        while version < currentVersion {
            guard let step = migrations[version] else { throw ModeDocumentError.missingMigration(from: version) }
            try step.migrate(&object)
            version += 1
            object["schemaVersion"] = version
        }
        object["schemaVersion"] = version
        return Result(object: object, originalVersion: original)
    }

    /// Migrates and decodes a mode document.
    public func decode(_ data: Data) throws -> (definition: ModeDefinition, originalVersion: Int) {
        let result = try migrate(data)
        let upgraded = try JSONSerialization.data(withJSONObject: result.object, options: [])
        do {
            let definition = try JSONDecoder().decode(ModeDefinition.self, from: upgraded)
            return (definition, result.originalVersion)
        } catch let error as DecodingError {
            throw ModeDocumentError.decoding(Self.describe(error))
        }
    }

    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }

    /// Reads `schemaVersion` with `JSONDecoder`, which (unlike `NSNumber` bridging)
    /// rejects booleans and fractional numbers the same way on every platform.
    private static func schemaVersion(of data: Data, object: [String: Any]) throws -> Int {
        guard let raw = object["schemaVersion"] else { return 1 }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
            let version = probe.schemaVersion, version >= 1
        else {
            throw ModeDocumentError.invalidSchemaVersion("\(raw)")
        }
        return version
    }

    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError { return describe(decoding) }
        return (error as NSError).localizedDescription
    }

    /// Human-readable decoding error with a JSON-style path (`transitions[0].trigger`).
    static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            var result = ""
            for key in codingPath {
                if let index = key.intValue {
                    result += "[\(index)]"
                } else {
                    result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return result.isEmpty ? "(document)" : result
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])): required field is missing"
        case .typeMismatch(let type, let context):
            return "\(path(context.codingPath)): expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context.codingPath)): expected \(type), found null"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
