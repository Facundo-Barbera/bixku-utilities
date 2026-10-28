import Foundation

/// Linear undo/redo history of values.
///
/// Consecutive edits that share a coalescing key (typing in one text field) collapse
/// into a single undo step.
public struct UndoHistory<Value: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var present: Value
    private var past: [Value] = []
    private var future: [Value] = []
    private var lastKey: String?
    private let limit: Int

    public init(_ initial: Value, limit: Int = 200) {
        present = initial
        self.limit = max(1, limit)
    }

    public var canUndo: Bool {
        !past.isEmpty
    }

    public var canRedo: Bool {
        !future.isEmpty
    }

    /// Records `value` as the new present. Equal values are ignored.
    public mutating func push(_ value: Value, coalescingKey key: String? = nil) {
        guard value != present else { return }
        future.removeAll()
        if let key, key == lastKey {
            present = value
            return
        }
        past.append(present)
        if past.count > limit { past.removeFirst(past.count - limit) }
        present = value
        lastKey = key
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(present)
        present = previous
        lastKey = nil
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(present)
        present = next
        lastKey = nil
        return true
    }

    /// The next push starts a new undo step even if it has the same key.
    public mutating func breakCoalescing() {
        lastKey = nil
    }
}
