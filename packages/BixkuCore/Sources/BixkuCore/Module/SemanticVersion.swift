import Foundation

/// `major.minor.patch` version of a module. Encoded as a string (`"1.2.3"`).
public struct SemanticVersion: Hashable, Comparable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"1.2.3"`, `"1.2"` or `"1"`. Returns `nil` for anything else.
    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0, part.allSatisfy(\.isASCII) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// Literal versions must be well formed; malformed literals trap.
    public init(stringLiteral value: String) {
        guard let version = SemanticVersion(string: value) else {
            preconditionFailure("Invalid semantic version literal: \(value)")
        }
        self = version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = SemanticVersion(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid semantic version: \(string)")
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
