import Foundation

/// Parser for the subset of TOML used by Bixku configuration files.
///
/// Supported: comments, `[table]` / `[a.b]` headers, bare / quoted / dotted keys,
/// basic and literal strings, integers, floats, booleans, (multi-line) arrays and
/// inline tables. Not supported (rejected with an error): multi-line strings,
/// arrays of tables (`[[x]]`), dates/times, `inf`/`nan`, hex/octal/binary integers.
public enum TOMLParser {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String

        public var description: String {
            "TOML line \(line): \(message)"
        }
    }

    public static func parse(_ text: String) throws -> [String: ConfigValue] {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return try parser.parseDocument()
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var index = 0
    var line = 1

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    // MARK: Document

    mutating func parseDocument() throws -> [String: ConfigValue] {
        var root: [String: ConfigValue] = [:]
        var currentTable: [String] = []
        var declaredTables = Set<[String]>()

        while true {
            skipWhitespaceCommentsAndNewlines()
            guard let scalar = peek() else { break }
            if scalar == "[" {
                advance()
                if peek() == "[" { throw error("arrays of tables ([[...]]) are not supported") }
                skipWhitespace()
                let path = try parseKey()
                skipWhitespace()
                try expect("]")
                guard declaredTables.insert(path).inserted else {
                    throw error("table [\(path.joined(separator: "."))] is defined more than once")
                }
                try ensureTable(at: path[...], in: &root)
                currentTable = path
            } else {
                let key = try parseKey()
                skipWhitespace()
                try expect("=")
                skipWhitespace()
                let value = try parseValue()
                try insert(value, at: (currentTable + key)[...], in: &root)
            }
            try expectEndOfLine()
        }
        return root
    }

    mutating func expectEndOfLine() throws {
        skipWhitespace()
        skipComment()
        guard let scalar = peek() else { return }
        if scalar == "\n" {
            advance()
        } else if scalar == "\r", peek(offset: 1) == "\n" {
            advance()
            advance()
        } else {
            throw error("expected end of line, found '\(scalar)'")
        }
    }

    // MARK: Keys

    mutating func parseKey() throws -> [String] {
        var segments: [String] = []
        while true {
            segments.append(try parseKeySegment())
            skipWhitespace()
            guard peek() == "." else { return segments }
            advance()
            skipWhitespace()
        }
    }

    mutating func parseKeySegment() throws -> String {
        switch peek() {
        case "\"": return try parseBasicString()
        case "'": return try parseLiteralString()
        default:
            var key = String.UnicodeScalarView()
            while let scalar = peek(), Self.isBareKeyScalar(scalar) {
                key.append(scalar)
                advance()
            }
            guard !key.isEmpty else { throw error("expected a key") }
            return String(key)
        }
    }

    static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "-"
    }

    // MARK: Values

    mutating func parseValue() throws -> ConfigValue {
        guard let scalar = peek() else { throw error("expected a value") }
        switch scalar {
        case "\"":
            if peek(offset: 1) == "\"", peek(offset: 2) == "\"" { throw error("multi-line strings are not supported") }
            return .string(try parseBasicString())
        case "'":
            if peek(offset: 1) == "'", peek(offset: 2) == "'" { throw error("multi-line strings are not supported") }
            return .string(try parseLiteralString())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        default:
            return try parseScalarToken()
        }
    }

    mutating func parseArray() throws -> ConfigValue {
        try expect("[")
        var elements: [ConfigValue] = []
        while true {
            skipWhitespaceCommentsAndNewlines()
            if peek() == "]" {
                advance()
                return .array(elements)
            }
            elements.append(try parseValue())
            skipWhitespaceCommentsAndNewlines()
            if peek() == "," {
                advance()
            } else if peek() == "]" {
                advance()
                return .array(elements)
            } else {
                throw error("expected ',' or ']' in array")
            }
        }
    }

    mutating func parseInlineTable() throws -> ConfigValue {
        try expect("{")
        var table: [String: ConfigValue] = [:]
        skipWhitespace()
        if peek() == "}" {
            advance()
            return .table(table)
        }
        while true {
            skipWhitespace()
            let key = try parseKey()
            skipWhitespace()
            try expect("=")
            skipWhitespace()
            let value = try parseValue()
            try insert(value, at: key[...], in: &table)
            skipWhitespace()
            if peek() == "," {
                advance()
            } else if peek() == "}" {
                advance()
                return .table(table)
            } else {
                throw error("expected ',' or '}' in inline table")
            }
        }
    }

    mutating func parseScalarToken() throws -> ConfigValue {
        var token = ""
        while let scalar = peek(), Self.isBareKeyScalar(scalar) || scalar == "+" || scalar == "." {
            token.unicodeScalars.append(scalar)
            advance()
        }
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "": throw error("expected a value")
        default: break
        }
        let digits = token.replacingOccurrences(of: "_", with: "")
        let isFloat = digits.contains(".") || digits.contains("e") || digits.contains("E")
        if !isFloat, let integer = Int(digits) {
            return .integer(integer)
        }
        if isFloat, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || "+-.eE".unicodeScalars.contains($0) }),
            let double = Double(digits)
        {
            return .double(double)
        }
        throw error("unsupported value '\(token)'")
    }

    // MARK: Strings

    mutating func parseBasicString() throws -> String {
        try expect("\"")
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek(), scalar != "\n" else { throw error("unterminated string") }
            advance()
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                guard let escape = peek() else { throw error("unterminated string") }
                advance()
                switch escape {
                case "b": result.append("\u{08}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "f": result.append("\u{0C}")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "u": result.append(try parseUnicodeEscape(length: 4))
                case "U": result.append(try parseUnicodeEscape(length: 8))
                default: throw error("invalid escape '\\\(escape)'")
                }
            default:
                result.append(scalar)
            }
        }
    }

    mutating func parseUnicodeEscape(length: Int) throws -> Unicode.Scalar {
        var hex = ""
        for _ in 0..<length {
            guard let scalar = peek() else { throw error("unterminated unicode escape") }
            hex.unicodeScalars.append(scalar)
            advance()
        }
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
            throw error("invalid unicode escape '\(hex)'")
        }
        return scalar
    }

    mutating func parseLiteralString() throws -> String {
        try expect("'")
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek(), scalar != "\n" else { throw error("unterminated string") }
            advance()
            if scalar == "'" { return String(result) }
            result.append(scalar)
        }
    }

    // MARK: Tables

    func insert(_ value: ConfigValue, at path: ArraySlice<String>, in table: inout [String: ConfigValue]) throws {
        guard let key = path.first else { return }
        if path.count == 1 {
            guard table[key] == nil else { throw error("key '\(key)' is defined more than once") }
            table[key] = value
            return
        }
        var child: [String: ConfigValue]
        switch table[key] {
        case nil: child = [:]
        case .table(let existing)?: child = existing
        default: throw error("key '\(key)' is not a table")
        }
        try insert(value, at: path.dropFirst(), in: &child)
        table[key] = .table(child)
    }

    func ensureTable(at path: ArraySlice<String>, in table: inout [String: ConfigValue]) throws {
        guard let key = path.first else { return }
        var child: [String: ConfigValue]
        switch table[key] {
        case nil: child = [:]
        case .table(let existing)?: child = existing
        default: throw error("key '\(key)' is not a table")
        }
        try ensureTable(at: path.dropFirst(), in: &child)
        table[key] = .table(child)
    }

    // MARK: Scanning

    func peek(offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    mutating func advance() {
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else {
            throw error("expected '\(scalar)'" + (peek().map { ", found '\($0)'" } ?? " before end of file"))
        }
        advance()
    }

    mutating func skipWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" {
            advance()
        }
    }

    mutating func skipComment() {
        guard peek() == "#" else { return }
        while let scalar = peek(), scalar != "\n" {
            advance()
        }
    }

    mutating func skipWhitespaceCommentsAndNewlines() {
        while let scalar = peek() {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                advance()
            } else if scalar == "#" {
                skipComment()
            } else {
                return
            }
        }
    }

    func error(_ message: String) -> TOMLParser.ParseError {
        TOMLParser.ParseError(line: line, message: message)
    }
}
