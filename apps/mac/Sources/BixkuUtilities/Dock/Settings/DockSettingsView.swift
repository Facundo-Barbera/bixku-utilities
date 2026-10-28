import BixkuDock
import BixkuDockSettings
import SwiftUI

/// Settings of the Dock module: the mode editor and the permissions the Dock needs.
///
/// Hand it the same `ModeEditing` the running Dock reads its modes from, so edits
/// made here are picked up by the engine: `init(module:)` for the app's `DockModule`,
/// or `ModeStoreEditor(store:)` for any `ModeStore`.
@MainActor
struct DockSettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @StateObject private var permissions = PermissionsModel()

    init(editing: any ModeEditing) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(editing: editing))
    }

    var body: some View {
        TabView {
            ModesSettingsView(viewModel: viewModel)
                .tabItem { Label("Modes", systemImage: "square.stack") }
            PermissionsView(model: permissions)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

extension DockSettingsView {
    /// Standalone settings (previews, or a Dock configured with `modes_dir` set to
    /// this folder) backed by mode documents in the app's Application Support folder,
    /// derived at runtime (see `ModeLocations`).
    init(dataDirectory: URL? = nil) {
        let directory = ModeLocations.modesDirectory(dataDirectory: dataDirectory)
        self.init(editing: ModeStoreEditor(store: JSONModeStore(directory: directory)))
    }
}
