import Foundation

/// Stable identifier of a mode: a lowercase slug such as `writing` or `deep-work`.
///
/// Mode ids name the JSON file a user mode is stored in, so they are restricted to
/// `[a-z0-9]` words joined by single hyphens (at most 64 characters).
public struct ModeID: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var isValid: Bool {
        Self.isValid(rawValue)
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: ModeID, rhs: ModeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func isValid(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty, rawValue.count <= 64 else { return false }
        let words = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        return words.allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            }
        }
    }
}

extension ModeID {
    public static let writing: ModeID = "writing"
    public static let building: ModeID = "building"
    public static let reading: ModeID = "reading"
    public static let meeting: ModeID = "meeting"
    public static let `break`: ModeID = "break"
    /// No focus restrictions. The default fallback mode.
    public static let free: ModeID = "free"
}
