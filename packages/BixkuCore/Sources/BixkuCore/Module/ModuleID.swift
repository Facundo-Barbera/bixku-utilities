import Foundation

/// Stable identifier of a module, in reverse-DNS or slug form.
///
/// Valid ids are lowercase, made of dot-separated segments of `[a-z0-9]` words joined
/// by single hyphens: `online.bixku.dock`, `online.bixku.mode-agent`, `hello`.
/// The id is persisted (storage directories, settings) so it must never change once
/// a module ships.
public struct ModuleID: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Creates an id, throwing ``ModuleError/invalidModuleID(_:)`` if `rawValue` is malformed.
    public init(validating rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw ModuleError.invalidModuleID(rawValue) }
        self.rawValue = rawValue
    }

    public var isValid: Bool {
        Self.isValid(rawValue)
    }

    /// The last dot-separated segment (`online.bixku.dock` → `dock`).
    public var slug: String {
        rawValue.split(separator: ".").last.map(String.init) ?? rawValue
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: ModuleID, rhs: ModuleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func isValid(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty, rawValue.count <= 128 else { return false }
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            let words = segment.split(separator: "-", omittingEmptySubsequences: false)
            return !words.isEmpty && words.allSatisfy { word in
                !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
                    ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                }
            }
        }
    }
}
