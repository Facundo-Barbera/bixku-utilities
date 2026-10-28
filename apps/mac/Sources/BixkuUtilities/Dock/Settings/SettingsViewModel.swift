import BixkuDock
import BixkuDockSettings
import Foundation

/// What is selected in the mode list.
enum ModeSelection: Hashable {
    case mode(ModeID)
    /// The mode being created, which has not been saved yet.
    case newMode
}

enum ModeEditorTab: Hashable {
    case form
    case json
}

/// State of the Dock settings screen: the mode list, one edit session per mode that
/// was opened, and the form/JSON editors. All the rules (conversion, validation,
/// undo, diff) live in `BixkuDockSettings`; this class only wires them to the UI.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var catalog = ModeCatalog(modes: [])
    @Published private(set) var selection: ModeSelection?
    @Published var tab: ModeEditorTab = .form
    /// The form for the selected mode (`nil` when nothing is selected).
    @Published private(set) var form: ModeForm?
    @Published private(set) var jsonText = ""
    /// Problems with the current draft; saving is blocked while there are any.
    @Published private(set) var issues: [ModeValidationIssue] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    /// Edit sessions of saved modes. Switching modes keeps unsaved edits.
    @Published private var sessions: [ModeID: ModeEditSession] = [:]
    @Published private var newSession: ModeEditSession?

    private let editing: any ModeEditing
    private var didSelectInitialMode = false

    init(editing: any ModeEditing) {
        self.editing = editing
    }

    // MARK: Loading

    /// Loads the modes, then keeps the list current until the task is cancelled.
    func start() async {
        let changes = editing.catalogChanges()
        await reload()
        for await updated in changes {
            apply(updated)
        }
    }

    func reload() async {
        do {
            apply(try await editing.loadCatalog())
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func apply(_ catalog: ModeCatalog) {
        let draftBefore = currentSession?.draft
        self.catalog = catalog
        for (id, session) in sessions {
            guard let definition = catalog.definition(id) else {
                if !session.isDirty { sessions[id] = nil }
                continue
            }
            if session.original != definition, !session.isDirty {
                sessions[id] = ModeEditSession(editing: definition)
            }
        }
        if !didSelectInitialMode, selection == nil, let first = catalog.modes.first {
            didSelectInitialMode = true
            select(.mode(first.id))
            return
        }
        if case .mode(let id) = selection, sessions[id] == nil {
            if catalog.contains(id) {
                select(.mode(id))
            } else {
                select(nil)
            }
            return
        }
        // Refresh the editors only if the draft itself changed underneath them.
        if currentSession?.draft != draftBefore { resync() }
    }

    // MARK: Selection

    func select(_ newSelection: ModeSelection?) {
        selection = newSelection
        statusMessage = nil
        errorMessage = nil
        if case .mode(let id) = newSelection, sessions[id] == nil, let definition = catalog.definition(id) {
            sessions[id] = ModeEditSession(editing: definition)
        }
        resync()
    }

    /// Creates a new, unsaved mode and selects it.
    func createMode() {
        guard newSession == nil else {
            select(.newMode)
            statusMessage = "Save or discard the new mode first."
            return
        }
        newSession = ModeEditSession(creating: ModeTemplates.blank(avoiding: Set(catalog.ids)))
        select(.newMode)
    }

    /// Starts a new mode from a copy of the selected one.
    func duplicateCurrent() {
        guard let session = currentSession else { return }
        guard newSession == nil else {
            select(.newMode)
            statusMessage = "Save or discard the new mode first."
            return
        }
        var copy = session.draft
        copy.id = uniqueID(basedOn: copy.id)
        copy.name += " copy"
        newSession = ModeEditSession(creating: copy)
        select(.newMode)
    }

    /// Throws away the unsaved new mode.
    func discardNewMode() {
        guard case .newMode = selection else { return }
        newSession = nil
        select(catalog.modes.first.map { .mode($0.id) })
    }

    // MARK: Current session

    private var currentSession: ModeEditSession? {
        switch selection {
        case .mode(let id): return sessions[id]
        case .newMode: return newSession
        case nil: return nil
        }
    }

    private func setCurrentSession(_ session: ModeEditSession) {
        switch selection {
        case .mode(let id): sessions[id] = session
        case .newMode: newSession = session
        case nil: break
        }
    }

    var isNewMode: Bool {
        currentSession?.isNew ?? false
    }

    var currentProvenance: ModeProvenance? {
        guard case .mode(let id) = selection else { return nil }
        return catalog.mode(id)?.provenance
    }

    var canUndo: Bool {
        currentSession?.canUndo ?? false
    }

    var canRedo: Bool {
        currentSession?.canRedo ?? false
    }

    var isDirty: Bool {
        currentSession?.isDirty ?? false
    }

    var canSave: Bool {
        isDirty && issues.isEmpty && !isBusy
    }

    /// What differs from the saved version, as short lines.
    var changeSummary: [String] {
        currentSession?.changes.map(\.description) ?? []
    }

    func isDirty(_ candidate: ModeSelection) -> Bool {
        switch candidate {
        case .mode(let id): return sessions[id]?.isDirty ?? false
        case .newMode: return newSession != nil
        }
    }

    // MARK: Editing

    /// Applies `mutate` to the form and updates the draft. Edits with the same `key`
    /// in a row undo together.
    func editForm(key: String, _ mutate: (inout ModeForm) -> Void) {
        guard var session = currentSession, var form else { return }
        mutate(&form)
        self.form = form
        let id = ModeID(rawValue: form.id.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = form.build(applyingTo: session.draft, knownModes: knownIDs(adding: id))
        session.edit(result.definition, coalescingKey: key)
        setCurrentSession(session)
        issues = result.issues + extraIssues(for: result.definition)
        statusMessage = nil
    }

    /// Called as the user types in the JSON view.
    func setJSONText(_ text: String) {
        jsonText = text
        guard var session = currentSession else { return }
        let locked: ModeID? = session.isNew ? nil : session.original?.id
        let result = ModeJSON.parse(text, knownModes: knownIDs(adding: session.draft.id), lockedID: locked)
        issues = result.issues + (result.definition.map(extraIssues(for:)) ?? [])
        statusMessage = nil
        if let definition = result.definition {
            session.edit(definition, coalescingKey: "json")
            setCurrentSession(session)
            form = ModeForm(definition)
        }
    }

    func setTab(_ newTab: ModeEditorTab) {
        guard newTab != tab else { return }
        tab = newTab
        resync()
    }

    func undo() {
        guard var session = currentSession, session.canUndo else { return }
        session.undo()
        setCurrentSession(session)
        resync()
    }

    func redo() {
        guard var session = currentSession, session.canRedo else { return }
        session.redo()
        setCurrentSession(session)
        resync()
    }

    /// Goes back to the saved version (undoable).
    func discardChanges() {
        guard var session = currentSession else { return }
        session.discardChanges()
        setCurrentSession(session)
        resync()
    }

    // MARK: Saving

    func save() async {
        guard canSave, let session = currentSession, let selected = selection else { return }
        let definition = session.draft
        isBusy = true
        defer { isBusy = false }
        do {
            try await editing.save(definition)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        var saved = session
        saved.markSaved()
        switch selected {
        case .newMode:
            newSession = nil
            sessions[definition.id] = saved
            if selection == .newMode { selection = .mode(definition.id) }
        case .mode(let id):
            sessions[id] = saved
        }
        errorMessage = nil
        statusMessage = "Saved \(definition.name)."
        await reload()
    }

    /// Deletes the selected user-created mode.
    func deleteCurrent() async {
        guard case .mode(let id) = selection, currentProvenance == .user else { return }
        guard await run({ try await $0.delete(id) }) else { return }
        sessions[id] = nil
        select(catalog.modes.first.map { .mode($0.id) })
        statusMessage = "Deleted the mode."
    }

    /// Drops the user's override of the selected built-in mode.
    func restoreCurrentToFactory() async {
        guard case .mode(let id) = selection, currentProvenance == .userOverride else { return }
        guard await run({ try await $0.restoreFactory(id) }) else { return }
        sessions[id] = nil
        select(.mode(id))
        statusMessage = "Restored the built-in version."
    }

    /// Drops every override of a built-in mode; user-created modes stay.
    func restoreAllToFactory() async {
        let overridden = catalog.modes.filter { $0.provenance == .userOverride }.map(\.id)
        guard await run({ try await $0.restoreAllFactory() }) else { return }
        for id in overridden {
            sessions[id] = nil
        }
        select(selection)
        statusMessage = "Restored all built-in modes."
    }

    /// Runs a store operation and reloads the list. Returns `false` (and shows the
    /// error) if it failed.
    private func run(_ operation: (any ModeEditing) async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation(editing)
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
        await reload()
        return true
    }

    // MARK: Helpers

    /// Rebuilds the form, JSON text and issues from the current draft.
    private func resync() {
        guard let session = currentSession else {
            form = nil
            jsonText = ""
            issues = []
            return
        }
        let draft = session.draft
        form = ModeForm(draft)
        jsonText = ModeJSON.text(for: draft)
        issues = ModeValidator().issues(in: draft, knownModes: knownIDs(adding: draft.id)) + extraIssues(for: draft)
    }

    private func knownIDs(adding id: ModeID) -> Set<ModeID> {
        Set(catalog.ids).union([id])
    }

    /// Problems only this screen can see: a new mode must not take over an existing id.
    private func extraIssues(for draft: ModeDefinition) -> [ModeValidationIssue] {
        guard currentSession?.isNew == true, catalog.contains(draft.id) else { return [] }
        return [ModeValidationIssue(path: "id", message: "a mode with the id '\(draft.id)' already exists")]
    }

    private func uniqueID(basedOn id: ModeID) -> ModeID {
        var candidate = ModeID(rawValue: "\(id.rawValue)-copy")
        var counter = 2
        while catalog.contains(candidate) {
            candidate = ModeID(rawValue: "\(id.rawValue)-copy-\(counter)")
            counter += 1
        }
        return candidate
    }

    private static func describe(_ error: Error) -> String {
        (error as? CustomStringConvertible)?.description ?? error.localizedDescription
    }
}
