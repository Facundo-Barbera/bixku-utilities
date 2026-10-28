import AppKit
import BixkuCore
import SwiftUI

/// Content of the menu-bar extra: one section per running module panel, buttons
/// for module windows, and app actions.
struct MenuBarContentView: View {
    @ObservedObject var host: ModuleHost
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bixku Utilities")
                .font(.headline)

            let panels = host.items(of: .menuBarPanel)
            if panels.isEmpty {
                Text(host.modules.isEmpty ? "Loading modules…" : "No module panels are running.")
                    .foregroundStyle(.secondary)
            }
            ForEach(panels) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.descriptor.title, systemImage: item.descriptor.systemImage)
                        .font(.subheadline.weight(.semibold))
                    host.view(for: item)
                }
                Divider()
            }

            ForEach(host.items(of: .window)) { item in
                Button {
                    host.presentedWindow = item.reference
                    open(SceneID.moduleWindow)
                } label: {
                    Label("Open \(item.descriptor.title)…", systemImage: item.descriptor.systemImage)
                }
            }

            if let error = host.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Settings…") {
                    open(SceneID.settings)
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func open(_ sceneID: String) {
        openWindow(id: sceneID)
        // Menu-bar (LSUIElement) apps are not active by default; bring the window forward.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
