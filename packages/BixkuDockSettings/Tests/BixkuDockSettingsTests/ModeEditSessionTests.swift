import BixkuDock
import XCTest
@testable import BixkuDockSettings

final class ModeEditSessionTests: XCTestCase {
    private let base = ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down.")

    private func renamed(_ name: String) -> ModeDefinition {
        var copy = base
        copy.name = name
        return copy
    }

    func testFreshSessionIsCleanAndNewModeIsAlwaysDirty() {
        let editing = ModeEditSession(editing: base)
        XCTAssertFalse(editing.isDirty)
        XCTAssertFalse(editing.isNew)
        XCTAssertTrue(editing.changes.isEmpty)
        XCTAssertFalse(editing.canUndo)

        let creating = ModeEditSession(creating: base)
        XCTAssertTrue(creating.isNew)
        XCTAssertTrue(creating.isDirty)
        XCTAssertFalse(creating.changes.isEmpty)
    }

    func testEditUndoRedo() {
        var session = ModeEditSession(editing: base)
        session.edit(renamed("A"))
        session.edit(renamed("B"))
        XCTAssertEqual(session.draft.name, "B")
        XCTAssertTrue(session.isDirty)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.draft.name, "A")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.draft.name, "Focus")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.undo())

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.draft.name, "A")
        session.edit(renamed("C"))
        XCTAssertFalse(session.canRedo, "a new edit clears the redo stack")
    }

    func testEditsWithTheSameKeyUndoTogether() {
        var session = ModeEditSession(editing: base)
        session.edit(renamed("F"), coalescingKey: "name")
        session.edit(renamed("Fo"), coalescingKey: "name")
        session.edit(renamed("Foc"), coalescingKey: "name")
        var other = renamed("Foc")
        other.symbol = "moon"
        session.edit(other, coalescingKey: "symbol")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.draft.name, "Foc")
        XCTAssertEqual(session.draft.symbol, "bolt")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.draft.name, "Focus")
        XCTAssertFalse(session.canUndo)
    }

    func testUndoBreaksCoalescing() {
        var session = ModeEditSession(editing: base)
        session.edit(renamed("A"), coalescingKey: "name")
        session.undo()
        session.edit(renamed("B"), coalescingKey: "name")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.draft.name, "Focus")
    }

    func testDiscardChangesIsUndoable() {
        var session = ModeEditSession(editing: base)
        session.edit(renamed("Changed"))
        session.discardChanges()
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.draft, base)
        session.undo()
        XCTAssertEqual(session.draft.name, "Changed")
    }

    func testDiscardOnNewModeDoesNothing() {
        var session = ModeEditSession(creating: base)
        session.edit(renamed("Changed"))
        session.discardChanges()
        XCTAssertEqual(session.draft.name, "Changed")
    }

    func testMarkSavedMakesTheDraftTheBaseline() {
        var session = ModeEditSession(creating: base)
        session.markSaved()
        XCTAssertFalse(session.isNew)
        XCTAssertFalse(session.isDirty)
        session.edit(renamed("Next"))
        XCTAssertEqual(session.changes.map(\.path), ["name"])
        session.discardChanges()
        XCTAssertEqual(session.draft, base)
    }

    func testUndoHistoryLimitDropsOldestSteps() {
        var history = UndoHistory(0, limit: 3)
        for value in 1...10 { history.push(value) }
        var undone = 0
        while history.undo() { undone += 1 }
        XCTAssertEqual(undone, 3)
        XCTAssertEqual(history.present, 7)
    }

    func testEqualPushIsIgnored() {
        var history = UndoHistory("a")
        history.push("a")
        XCTAssertFalse(history.canUndo)
    }
}
