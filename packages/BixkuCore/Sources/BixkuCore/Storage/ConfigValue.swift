import Foundation

/// A configuration or settings value. Encodes to plain JSON (`"x"`, `1`, `true`, `[…]`, `{…}`).
public enum ConfigValue: Sendable, Equatable, Codable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([ConfigValue])
    case table([String: ConfigValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// Doubles, and integers widened to `Double`.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ConfigValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var tableValue: [String: ConfigValue]? {
        if case .table(let value) = self { return value }
        return nil
    }

    /// Looks up a dotted key path (`"modules.dock.enabled"`) inside nested tables.
    public subscript(keyPath keyPath: String) -> ConfigValue? {
        guard !keyPath.isEmpty else { return self }
        var current: ConfigValue? = self
        for key in keyPath.split(separator: ".", omittingEmptySubsequences: false) {
            current = current?.tableValue?[String(key)]
        }
        return current
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before numbers: JSON `true` must not become `1`.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ConfigValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ConfigValue].self) {
            self = .table(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported configuration value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .table(let value): try container.encode(value)
        }
    }
}

extension ConfigValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: ConfigValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, ConfigValue)...) {
        self = .table(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
