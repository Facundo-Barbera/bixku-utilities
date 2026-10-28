import SwiftUI

/// The Dock's "Agent" tab: tell the agent what to change, review its proposals
/// as diffs, approve / reject / undo them, and configure the LLM provider.
struct AgentTabView: View {
    @StateObject private var model: AgentViewModel
    @State private var pane = Pane.proposals

    private enum Pane: String, CaseIterable, Identifiable {
        case proposals = "Proposals"
        case provider = "Provider"

        var id: String { rawValue }
    }

    init(model: @autoclosure @escaping () -> AgentViewModel) {
        _model = StateObject(wrappedValue: model())
    }

    /// The tab wired to the placeholder agent and the Keychain, until the real agent adapter is plugged in.
    static func makeDefault() -> AgentTabView {
        AgentTabView(model: AgentViewModel(agent: PlaceholderAgent(), secrets: KeychainSecretStore()))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch pane {
            case .proposals:
                ProposalsPane(model: model)
            case .provider:
                ProviderSettingsPane(model: model)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Proposals

private struct ProposalsPane: View {
    @ObservedObject var model: AgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.proposals.isEmpty {
                        Text("Ask the agent to adjust a mode or add a new one. Its proposals appear here for you to review.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.pending) { proposal in
                        ProposalCard(proposal: proposal, model: model)
                    }
                    if !model.history.isEmpty {
                        Text("History")
                            .font(.headline)
                            .padding(.top, 4)
                        ForEach(model.history) { proposal in
                            ProposalCard(proposal: proposal, model: model)
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("e.g. \"In Writing mode, hold all notifications except calls\"", text: $model.instruction, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.send() }
                    Button("Send") { model.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canSend)
                }
            }
            .padding(12)
        }
    }
}

private struct ProposalCard: View {
    let proposal: AgentProposal
    @ObservedObject var model: AgentViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(proposal.instruction)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(proposal.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                ProposalDiffView(lines: proposal.diffLines)

                HStack {
                    StatusLabel(status: proposal.status)
                    Spacer()
                    actions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch proposal.status {
        case .pending:
            Button("Reject") { model.reject(proposal) }
            Button("Approve") { model.approve(proposal) }
                .buttonStyle(.borderedProminent)
        case .approved:
            Button("Undo") { model.revert(proposal) }
        case .rejected, .reverted, .failed:
            EmptyView()
        }
    }
}

private struct StatusLabel: View {
    let status: ProposalStatus

    var body: some View {
        switch status {
        case .pending:
            Label("Needs your decision", systemImage: "hourglass")
                .foregroundStyle(.orange)
        case .approved:
            Label("Applied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .reverted:
            Label("Undone", systemImage: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label("Failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// A monospaced, colored diff: green for additions, red for removals.
struct ProposalDiffView: View {
    let lines: [DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.rendered)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(foreground(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(background(for: line.kind))
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
    }

    private func foreground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .primary
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Provider settings

private struct ProviderSettingsPane: View {
    @ObservedObject var model: AgentViewModel

    var body: some View {
        Form {
            Picker("Provider", selection: Binding(
                get: { model.config.provider },
                set: { model.selectProvider($0) }
            )) {
                ForEach(AgentProvider.allCases) { Text($0.displayName).tag($0) }
            }

            TextField("Model", text: $model.config.model)

            TextField("Environment variable", text: $model.config.environmentVariable)
            Text("If this variable is set when the app starts, its value is used as the API key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("API key", text: $model.apiKeyDraft, prompt: Text(model.hasStoredKey ? "Stored in Keychain" : "Paste a key"))
            Text("Stored in the macOS Keychain only. Never written to files or logs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save") { model.saveSettings() }
                Button("Remove stored key") { model.removeStoredKey() }
                    .disabled(!model.hasStoredKey)
                if let status = model.settingsStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
