import BixkuDock
import BixkuDockSettings

/// Edits the modes of a running `DockModule` through the store the module itself
/// uses (module storage, or `modes_dir` when configured), so the engine sees every
/// save. Fails with `DockModuleError.notRunning` while the module is stopped.
struct DockModuleModeEditor: ModeEditing {
    let module: DockModule

    private func editor() throws -> ModeStoreEditor {
        guard let store = module.modeStore else { throw DockModuleError.notRunning }
        return ModeStoreEditor(store: store)
    }

    func loadCatalog() async throws -> ModeCatalog {
        try await editor().loadCatalog()
    }

    func save(_ definition: ModeDefinition) async throws {
        try await editor().save(definition)
    }

    func delete(_ id: ModeID) async throws {
        try await editor().delete(id)
    }

    func restoreFactory(_ id: ModeID) async throws {
        try await editor().restoreFactory(id)
    }

    func restoreAllFactory() async throws {
        try await editor().restoreAllFactory()
    }

    func catalogChanges() -> AsyncStream<ModeCatalog> {
        if let live = try? editor() {
            return live.catalogChanges()
        }
        // Not running: no live updates; the screen reloads when the app is activated.
        return AsyncStream { $0.finish() }
    }
}

extension DockSettingsView {
    /// Settings for the Dock module the app runs.
    init(module: DockModule) {
        self.init(editing: DockModuleModeEditor(module: module))
    }
}
