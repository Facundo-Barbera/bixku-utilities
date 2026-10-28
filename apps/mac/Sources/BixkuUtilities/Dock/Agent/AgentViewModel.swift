import Foundation
import SwiftUI

/// State of the Agent tab: the instruction field, the proposal history and the provider settings.
@MainActor
final class AgentViewModel: ObservableObject {
    @Published var instruction = ""
    @Published private(set) var proposals: [AgentProposal] = []
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?

    @Published var config: AgentProviderConfig
    /// What the user is typing in the API key field. Cleared as soon as it is stored.
    @Published var apiKeyDraft = ""
    @Published private(set) var hasStoredKey: Bool
    @Published private(set) var settingsStatus: String?

    private let agent: any AgentControlling
    private let credentials: AgentCredentials
    private let defaults: UserDefaults
    private var observation: Task<Void, Never>?

    init(agent: any AgentControlling, secrets: any SecretStore, defaults: UserDefaults = .standard) {
        let config = AgentProviderConfig.load(from: defaults)
        let credentials = AgentCredentials(secrets: secrets)
        self.agent = agent
        self.credentials = credentials
        self.defaults = defaults
        self.config = config
        self.hasStoredKey = credentials.hasStoredKey(for: config.provider)
    }

    /// Proposals waiting for a decision, newest first.
    var pending: [AgentProposal] {
        proposals.filter { $0.status.isPending }.reversed()
    }

    /// Everything else, newest first.
    var history: [AgentProposal] {
        proposals.filter { !$0.status.isPending }.reversed()
    }

    var canSend: Bool {
        !isSending && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starts following the agent's proposals. Safe to call more than once.
    func start() {
        guard observation == nil else { return }
        let stream = agent.proposals
        observation = Task { [weak self] in
            for await snapshot in stream {
                // Leaving the loop also ends the subscription once the view model is gone.
                guard let self else { return }
                self.proposals = snapshot
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func send() {
        let text = instruction
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await agent.instruct(text)
                instruction = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    func approve(_ proposal: AgentProposal) {
        perform { try await $0.approve(proposal.id) }
    }

    func reject(_ proposal: AgentProposal) {
        perform { try await $0.reject(proposal.id) }
    }

    func revert(_ proposal: AgentProposal) {
        perform { try await $0.revert(proposal.id) }
    }

    private func perform(_ action: @escaping (any AgentControlling) async throws -> Void) {
        errorMessage = nil
        Task {
            do {
                try await action(agent)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Provider settings

    /// Switches provider and resets model and environment variable to its defaults.
    func selectProvider(_ provider: AgentProvider) {
        guard provider != config.provider else { return }
        config = AgentProviderConfig(provider: provider)
        hasStoredKey = credentials.hasStoredKey(for: provider)
        apiKeyDraft = ""
        settingsStatus = nil
    }

    func saveSettings() {
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.environmentVariable = config.environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
        config.save(to: defaults)

        let draft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !draft.isEmpty {
                try credentials.store(draft, for: config.provider)
            }
            apiKeyDraft = ""
            hasStoredKey = credentials.hasStoredKey(for: config.provider)
            settingsStatus = "Saved"
        } catch {
            settingsStatus = "Could not save the key: \(error.localizedDescription)"
        }
    }

    func removeStoredKey() {
        do {
            try credentials.removeKey(for: config.provider)
            hasStoredKey = false
            settingsStatus = "Key removed"
        } catch {
            settingsStatus = "Could not remove the key: \(error.localizedDescription)"
        }
    }
}
