import Foundation

/// Conversion between a list of strings and the text a user types for it: one entry
/// per line, commas also accepted (so pasting `a, b, c` works).
public enum ListText {
    /// Splits on newlines and commas, trims, drops empty entries and repeated ones
    /// (case-insensitively, keeping the first spelling). Order is preserved.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let separators = CharacterSet(charactersIn: ",\n\r")
        for part in text.components(separatedBy: separators) {
            let entry = part.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty || !seen.insert(entry.lowercased()).inserted { continue }
            result.append(entry)
        }
        return result
    }

    /// One entry per line.
    public static func format(_ items: [String]) -> String {
        items.joined(separator: "\n")
    }
}
