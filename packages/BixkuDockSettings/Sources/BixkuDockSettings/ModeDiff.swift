import BixkuDock
import Foundation

/// One difference between two versions of a mode.
public struct ModeChange: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case added
        case removed
        case modified
    }

    /// JSON-style path of the field (`dock.hidden`, `notifications.default`).
    public var path: String
    public var kind: Kind
    /// Compact JSON of the old value (`nil` when added).
    public var before: String?
    /// Compact JSON of the new value (`nil` when removed).
    public var after: String?

    public var description: String {
        switch kind {
        case .added: return "+ \(path): \(after ?? "")"
        case .removed: return "- \(path): \(before ?? "")"
        case .modified: return "~ \(path): \(before ?? "") → \(after ?? "")"
        }
    }
}

/// Field-by-field comparison of mode definitions, used to show what an edit changed
/// and to tell whether there is anything to save.
public enum ModeDiff {
    /// The changes needed to go from `old` to `new`, sorted by path. A `nil` `old`
    /// (a mode that was never saved) reports every field as added.
    ///
    /// Objects are compared key by key; arrays are compared as a whole, so
    /// reordering the dock's prioritized apps is one `modified` entry.
    public static func changes(from old: ModeDefinition?, to new: ModeDefinition) -> [ModeChange] {
        let oldLeaves = old.map(leaves) ?? [:]
        let newLeaves = leaves(of: new)
        var result: [ModeChange] = []
        for path in Set(oldLeaves.keys).union(newLeaves.keys).sorted() {
            switch (oldLeaves[path], newLeaves[path]) {
            case let (before?, after?):
                if before != after { result.append(ModeChange(path: path, kind: .modified, before: before, after: after)) }
            case let (nil, after?):
                result.append(ModeChange(path: path, kind: .added, before: nil, after: after))
            case let (before?, nil):
                result.append(ModeChange(path: path, kind: .removed, before: before, after: nil))
            case (nil, nil):
                break
            }
        }
        return result
    }

    private static func leaves(of definition: ModeDefinition) -> [String: String] {
        guard let data = try? JSONModeStore.encode(definition),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        flatten(object, prefix: "", into: &result)
        return result
    }

    private static func flatten(_ object: [String: Any], prefix: String, into result: inout [String: String]) {
        for (key, value) in object {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: path, into: &result)
            } else {
                result[path] = compact(value)
            }
        }
    }

    /// Compact, key-sorted JSON of a scalar or an array.
    private static func compact(_ value: Any) -> String {
        // Wrapped in an array so scalars are valid top-level JSON on every platform.
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return String(text.dropFirst().dropLast())
    }
}
