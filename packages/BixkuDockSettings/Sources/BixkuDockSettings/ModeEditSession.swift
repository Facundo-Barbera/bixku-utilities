import BixkuDock
import Foundation

/// The state of editing one mode: the saved version (if any), the draft, and the
/// undo history. Pure value type; the view model owns one per selected mode.
public struct ModeEditSession: Equatable, Sendable {
    /// The last saved version, or `nil` for a mode that was never saved.
    public private(set) var original: ModeDefinition?
    private var history: UndoHistory<ModeDefinition>

    /// Starts editing a saved mode.
    public init(editing original: ModeDefinition) {
        self.original = original
        history = UndoHistory(original)
    }

    /// Starts a new, not yet saved mode.
    public init(creating draft: ModeDefinition) {
        original = nil
        history = UndoHistory(draft)
    }

    public var draft: ModeDefinition {
        history.present
    }

    public var isNew: Bool {
        original == nil
    }

    /// Whether saving would change anything. A new mode always counts as changed.
    public var isDirty: Bool {
        original != draft
    }

    /// What differs between the saved version and the draft.
    public var changes: [ModeChange] {
        ModeDiff.changes(from: original, to: draft)
    }

    public var canUndo: Bool {
        history.canUndo
    }

    public var canRedo: Bool {
        history.canRedo
    }

    /// Replaces the draft. Pass the same `key` for a run of edits to one field so
    /// they undo together.
    public mutating func edit(_ draft: ModeDefinition, coalescingKey key: String? = nil) {
        history.push(draft, coalescingKey: key)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        history.undo()
    }

    @discardableResult
    public mutating func redo() -> Bool {
        history.redo()
    }

    /// Goes back to the saved version. This is itself an undoable step. A new mode
    /// has no saved version, so nothing happens.
    public mutating func discardChanges() {
        guard let original else { return }
        history.push(original)
    }

    /// Records that the current draft was saved.
    public mutating func markSaved() {
        original = draft
        history.breakCoalescing()
    }
}
