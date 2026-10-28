import BixkuCore
import SwiftUI

/// Settings window: list of modules on the left, details and module settings on the right.
struct SettingsView: View {
    @ObservedObject var host: ModuleHost
    @State private var selection: ModuleID?

    var body: some View {
        NavigationSplitView {
            List(host.modules, selection: $selection) { info in
                Label(info.manifest.displayName, systemImage: info.manifest.ui.first?.systemImage ?? "puzzlepiece.extension")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let info = host.modules.first(where: { $0.id == selection }) {
                ModuleDetailView(host: host, info: info)
            } else {
                Text(host.modules.isEmpty ? "No modules registered." : "Select a module.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            if selection == nil {
                selection = host.modules.first?.id
            }
        }
    }
}

/// Manifest, state, permissions, lifecycle controls and settings views of one module.
struct ModuleDetailView: View {
    @ObservedObject var host: ModuleHost
    let info: ModuleHost.ModuleInfo

    var body: some View {
        Form {
            Section {
                LabeledContent("Identifier", value: info.id.rawValue)
                LabeledContent("Version", value: info.manifest.version.description)
                LabeledContent("Status") {
                    ModuleStateBadge(state: info.state)
                }
                if case .failed(let reason) = info.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Start") {
                        Task { await host.start(info.id) }
                    }
                    .disabled(info.state.isActive)
                    Button("Stop") {
                        Task { await host.stop(info.id) }
                    }
                    .disabled(!info.state.isRunning)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.manifest.displayName)
                        .font(.title2)
                    Text(info.manifest.summary)
                        .foregroundStyle(.secondary)
                }
            }

            if !info.manifest.permissions.isEmpty {
                Section("Permissions") {
                    ForEach(info.manifest.permissions.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { permission in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(permission.title, systemImage: permission.systemImage)
                            Text(permission.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(host.settingsItems(for: info.id)) { item in
                Section(item.descriptor.title) {
                    host.view(for: item)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Content of the shared module window (`ModuleUIKind.window` views).
struct ModuleWindowView: View {
    @ObservedObject var host: ModuleHost

    var body: some View {
        Group {
            if let reference = host.presentedWindow, let item = host.item(for: reference) {
                host.view(for: item)
                    .navigationTitle(item.descriptor.title)
            } else {
                Text("No module window selected.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
