import BixkuDock
import Foundation

/// One changed field between two versions of a mode, in JSON path terms.
public struct ModeFieldChange: Codable, Sendable, Equatable, CustomStringConvertible {
    /// JSON path (`notifications.rules[0].action`).
    public var path: String
    /// Compact JSON of the old value (`nil` if the field was added).
    public var before: String?
    /// Compact JSON of the new value (`nil` if the field was removed).
    public var after: String?

    public init(path: String, before: String?, after: String?) {
        self.path = path
        self.before = before
        self.after = after
    }

    public var description: String {
        switch (before, after) {
        case let (nil, after?): return "+ \(path): \(after)"
        case let (before?, nil): return "- \(path): \(before)"
        case let (before?, after?): return "~ \(path): \(before) → \(after)"
        case (nil, nil): return "  \(path)"
        }
    }
}

/// Human-readable field-level diff of two mode definitions.
///
/// Both definitions are encoded with the store's JSON encoding and flattened to
/// leaf paths, so the diff speaks the same language as the documents users edit.
public enum ModeDiff {
    public static func changes(from before: ModeDefinition?, to after: ModeDefinition?) -> [ModeFieldChange] {
        let old = before.map(flatten) ?? [:]
        let new = after.map(flatten) ?? [:]
        return Set(old.keys).union(new.keys).sorted().compactMap { path in
            let (a, b) = (old[path], new[path])
            return a == b ? nil : ModeFieldChange(path: path, before: a, after: b)
        }
    }

    /// The diff as text, one change per line.
    public static func render(_ changes: [ModeFieldChange]) -> String {
        changes.isEmpty ? "(no changes)" : changes.map(\.description).joined(separator: "\n")
    }

    /// Leaf path → compact JSON value. `schemaVersion` is left out (it is not a
    /// user-facing change).
    static func flatten(_ definition: ModeDefinition) -> [String: String] {
        guard let data = try? JSONModeStore.encode(definition),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        var result: [String: String] = [:]
        walk(object, path: "", into: &result)
        result["schemaVersion"] = nil
        return result
    }

    private static func walk(_ value: Any, path: String, into result: inout [String: String]) {
        if let dictionary = value as? [String: Any], !dictionary.isEmpty {
            for (key, child) in dictionary {
                walk(child, path: path.isEmpty ? key : "\(path).\(key)", into: &result)
            }
        } else if let array = value as? [Any], !array.isEmpty {
            for (index, child) in array.enumerated() {
                walk(child, path: "\(path)[\(index)]", into: &result)
            }
        } else {
            result[path] = compactJSON(value)
        }
    }

    private static func compactJSON(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8)
        {
            return String(text.dropFirst().dropLast())
        }
        return String(describing: value)
    }
}
