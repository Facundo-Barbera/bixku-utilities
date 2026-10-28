import Foundation

/// One line of a human-readable proposal diff.
struct DiffLine: Equatable, Sendable {
    enum Kind: Sendable {
        case context
        case added
        case removed
    }

    var kind: Kind
    var text: String

    /// The line as plain text, with a unified-diff style prefix.
    var rendered: String {
        switch kind {
        case .context: return "  \(text)"
        case .added: return "+ \(text)"
        case .removed: return "- \(text)"
        }
    }
}

extension AgentChange {
    /// The change as diff lines: a header for the mode, then one or two lines per field.
    var diffLines: [DiffLine] {
        let header: DiffLine.Kind
        switch kind {
        case .create: header = .added
        case .modify: header = .context
        case .remove: header = .removed
        }

        var lines = [DiffLine(kind: header, text: "mode \(targetID)")]
        for field in fields {
            switch (field.before, field.after) {
            case let (before?, after?):
                guard before != after else { continue }
                lines.append(DiffLine(kind: .removed, text: "  \(field.name): \(before)"))
                lines.append(DiffLine(kind: .added, text: "  \(field.name): \(after)"))
            case let (nil, after?):
                lines.append(DiffLine(kind: .added, text: "  \(field.name): \(after)"))
            case let (before?, nil):
                lines.append(DiffLine(kind: .removed, text: "  \(field.name): \(before)"))
            case (nil, nil):
                continue
            }
        }
        return lines
    }
}

extension AgentProposal {
    /// All changes of the proposal as one diff.
    var diffLines: [DiffLine] {
        changes.flatMap(\.diffLines)
    }
}
