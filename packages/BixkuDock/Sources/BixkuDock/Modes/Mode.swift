import Foundation

/// Where a mode came from.
public enum ModeProvenance: String, Codable, Sendable, CaseIterable {
    /// Shipped with the app (``DefaultModes``).
    case factory
    /// Created by the user (or their agent); no factory mode has this id.
    case user
    /// A user document replacing the factory mode with the same id.
    case userOverride = "user-override"
}

/// A mode as resolved by a ``ModeStore``: its definition plus where it came from.
public struct Mode: Sendable, Equatable, Identifiable {
    public var definition: ModeDefinition
    public var provenance: ModeProvenance

    public init(definition: ModeDefinition, provenance: ModeProvenance) {
        self.definition = definition
        self.provenance = provenance
    }

    public var id: ModeID { definition.id }
    public var name: String { definition.name }
    public var symbol: String { definition.symbol }
    public var summary: String { definition.summary }
}

/// A problem found while loading user mode documents. Invalid documents are
/// skipped (the factory mode, if any, stays in effect) and reported here.
public struct ModeLoadIssue: Sendable, Equatable, CustomStringConvertible {
    /// Document name (the mode id it is stored under).
    public var document: String
    public var message: String

    public init(document: String, message: String) {
        self.document = document
        self.message = message
    }

    public var description: String {
        "\(document): \(message)"
    }
}

/// The resolved set of modes: factory modes overlaid with the user's documents.
public struct ModeCatalog: Sendable, Equatable {
    /// Factory modes first (in shipping order), then user modes sorted by id.
    public private(set) var modes: [Mode]
    /// User documents that could not be loaded.
    public var issues: [ModeLoadIssue]

    public init(modes: [Mode], issues: [ModeLoadIssue] = []) {
        var seen = Set<ModeID>()
        self.modes = modes.filter { seen.insert($0.id).inserted }
        self.issues = issues
    }

    public var ids: [ModeID] {
        modes.map(\.id)
    }

    public var definitions: [ModeDefinition] {
        modes.map(\.definition)
    }

    public func mode(_ id: ModeID) -> Mode? {
        modes.first { $0.id == id }
    }

    public func definition(_ id: ModeID) -> ModeDefinition? {
        mode(id)?.definition
    }

    public func contains(_ id: ModeID) -> Bool {
        mode(id) != nil
    }

    /// The factory modes only.
    public static var factory: ModeCatalog {
        ModeCatalog(modes: DefaultModes.all.map { Mode(definition: $0, provenance: .factory) })
    }
}
