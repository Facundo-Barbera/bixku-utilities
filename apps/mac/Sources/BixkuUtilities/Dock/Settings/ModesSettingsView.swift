import AppKit
import BixkuDock
import BixkuDockSettings
import SwiftUI

/// The "Modes" tab: the mode list on the left, the editor on the right.
struct ModesSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var confirmRestoreAll = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await viewModel.start() }
        // Pick up edits made elsewhere (the agent, a hand-edited file) on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.reload() }
        }
        .confirmationDialog(
            "Restore all built-in modes?",
            isPresented: $confirmRestoreAll,
            titleVisibility: .visible
        ) {
            Button("Restore built-in modes", role: .destructive) {
                Task { await viewModel.restoreAllToFactory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes to built-in modes are discarded. Modes you created are kept.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { viewModel.selection }, set: { viewModel.select($0) })) {
                Section("Modes") {
                    ForEach(viewModel.catalog.modes) { mode in
                        ModeRow(
                            name: mode.name,
                            symbol: mode.symbol,
                            provenance: mode.provenance,
                            isDirty: viewModel.isDirty(.mode(mode.id))
                        )
                        .tag(ModeSelection.mode(mode.id))
                    }
                    if viewModel.isDirty(.newMode) {
                        ModeRow(name: "New mode", symbol: "plus.circle", provenance: .user, isDirty: true)
                            .tag(ModeSelection.newMode)
                    }
                }
                if !viewModel.catalog.issues.isEmpty {
                    Section("Skipped documents") {
                        ForEach(Array(viewModel.catalog.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.description)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    viewModel.createMode()
                } label: {
                    Label("New mode", systemImage: "plus")
                }
                Spacer()
                Menu {
                    Button("Duplicate mode") { viewModel.duplicateCurrent() }
                        .disabled(viewModel.selection == nil)
                    Divider()
                    Button("Restore all built-in modes…", role: .destructive) { confirmRestoreAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(8)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if viewModel.form != nil {
            ModeEditorView(viewModel: viewModel)
        } else {
            Text(viewModel.catalog.modes.isEmpty ? "Loading modes…" : "Select a mode.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ModeRow: View {
    let name: String
    let symbol: String
    let provenance: ModeProvenance
    let isDirty: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            if isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .help("Unsaved changes")
            }
            switch provenance {
            case .factory:
                EmptyView()
            case .userOverride:
                Text("Edited").font(.caption2).foregroundStyle(.secondary)
            case .user:
                Text("Custom").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Toolbar, Form/JSON editor and footer for the selected mode.
struct ModeEditorView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
            Divider()
            if let form = viewModel.form {
                switch viewModel.tab {
                case .form:
                    ModeFormView(viewModel: viewModel, form: form)
                case .json:
                    ModeJSONView(viewModel: viewModel)
                }
            }
            Divider()
            footer
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A fresh editor (and fresh text boxes) for each mode.
        .id(viewModel.selection)
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: Binding(get: { viewModel.tab }, set: { viewModel.setTab($0) })) {
                Text("Form").tag(ModeEditorTab.form)
                Text("JSON").tag(ModeEditorTab.json)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)

            Button(action: viewModel.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            Button(action: viewModel.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)

            Spacer()

            switch viewModel.currentProvenance {
            case .userOverride:
                Button("Restore built-in") { Task { await viewModel.restoreCurrentToFactory() } }
            case .user:
                Button("Delete", role: .destructive) { Task { await viewModel.deleteCurrent() } }
            case .factory, nil:
                EmptyView()
            }
            if viewModel.isNewMode {
                Button("Discard", role: .destructive) { viewModel.discardNewMode() }
            } else {
                Button("Revert") { viewModel.discardChanges() }
                    .disabled(!viewModel.isDirty)
            }
            Button("Save") { Task { await viewModel.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if viewModel.tab == .form {
                IssueListView(issues: viewModel.issues, validMessage: "Valid mode.")
            }
            let changes = viewModel.changeSummary
            if !changes.isEmpty {
                DisclosureGroup("Unsaved changes (\(changes.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}
