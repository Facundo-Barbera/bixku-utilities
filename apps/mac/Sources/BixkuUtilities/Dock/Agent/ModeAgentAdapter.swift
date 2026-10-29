import BixkuDock
import BixkuLLM
import BixkuModeAgent
import Foundation

/// The real ``AgentControlling``: `BixkuModeAgent`'s ``ModeAgentController``
/// (agent loop, approval policy, history and revert) presented in the Agent
/// tab's vocabulary. Unqualified `ProposalStatus` here is the tab's type; the
/// agent package's one is `BixkuModeAgent.ProposalStatus`.
final class ModeAgentAdapter: AgentControlling, @unchecked Sendable {
    let controller: ModeAgentController

    init(controller: ModeAgentController) {
        self.controller = controller
    }

    var proposals: AsyncStream<[AgentProposal]> {
        let updates = controller.updates()
        return AsyncStream { continuation in
            let forwarding = Task {
                for await reviewed in updates {
                    continuation.yield(reviewed.map(AgentProposal.init))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }

    func instruct(_ instruction: String) async throws {
        try await translatingErrors { try await controller.instruct(instruction) }
    }

    func approve(_ id: AgentProposal.ID) async throws {
        try await translatingErrors { try await controller.approve(id) }
    }

    func reject(_ id: AgentProposal.ID) async throws {
        try await translatingErrors { try await controller.reject(id) }
    }

    func revert(_ id: AgentProposal.ID) async throws {
        try await translatingErrors { try await controller.revert(id) }
    }

    private func translatingErrors<T>(_ action: () async throws -> T) async throws {
        do {
            _ = try await action()
        } catch let error as ModeAgentControllerError {
            if let translated = AgentError(error) { throw translated }
            throw error
        }
    }
}

extension ModeAgentAdapter {
    /// The agent for the app's running Dock: it reads and edits modes through
    /// `module`'s engine and store, and asks for the provider settings and API key
    /// of the Agent tab on every instruction.
    static func make(
        module: DockModule,
        secrets: any SecretStore,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ModeAgentAdapter {
        let access = DockEngineAccess(module: module)
        let coordinator = ProposalCoordinator(store: access, dock: access)
        let settings = AgentSettingsSource(defaults: defaults, credentials: AgentCredentials(secrets: secrets), environment: environment)
        let controller = ModeAgentController(coordinator: coordinator, llm: { try settings.current().makeLLM() })
        return ModeAgentAdapter(controller: controller)
    }
}

/// Reads the Agent tab's provider settings when an instruction is sent.
struct AgentSettingsSource: @unchecked Sendable {
    let defaults: UserDefaults
    let credentials: AgentCredentials
    let environment: [String: String]

    func current() throws -> AgentProviderSettings {
        let config = AgentProviderConfig.load(from: defaults)
        let key: String?
        do {
            key = try credentials.apiKey(for: config, environment: environment)
        } catch {
            throw AgentError.providerNotConfigured("Could not read the \(config.provider.displayName) API key: \(error.localizedDescription)")
        }
        return AgentProviderSettings(
            provider: config.provider.llmProvider,
            displayName: config.provider.displayName,
            model: config.model,
            apiKey: key,
            environmentVariable: config.environmentVariable
        )
    }
}

extension AgentProvider {
    /// The BixkuLLM client family for this provider.
    var llmProvider: LLMProvider {
        switch self {
        case .anthropic: return .anthropic
        case .openai: return .openAICompatible
        }
    }
}

extension ProposalStatus {
    /// `approved` ↔ the agent's `applied`; `failed` keeps its message.
    init(_ status: ProposalReviewStatus) {
        switch status {
        case .pending: self = .pending
        case .approved: self = .approved
        case .rejected: self = .rejected
        case .reverted: self = .reverted
        case .failed(let message): self = .failed(message)
        }
    }
}

extension AgentError {
    /// The tab's equivalent of `error`, if it has one.
    init?(_ error: ModeAgentControllerError) {
        switch error {
        case .emptyInstruction: self = .emptyInstruction
        case .notConfigured(let message): self = .providerNotConfigured(message)
        case .unknownProposal(let id): self = .unknownProposal(id)
        case .invalidTransition(let action, let status): self = .invalidTransition(action: action, status: ProposalStatus(status))
        case .notRevertible: return nil
        }
    }
}

extension AgentProposal {
    /// The tab's view of a reviewed proposal: its title as summary, the agent's
    /// reason (and the untrusted-data warning) as detail, the field-level diff as one change.
    init(_ reviewed: ReviewedProposal) {
        let proposal = reviewed.proposal
        var notes: [String] = []
        let justification = proposal.justification.trimmingCharacters(in: .whitespacesAndNewlines)
        if !justification.isEmpty {
            notes.append("Agent's reason: \(justification)")
        }
        if proposal.influencedByUntrustedData {
            notes.append("Proposed after reading notifications or window titles; check it carefully.")
        }
        self.init(
            id: proposal.id,
            instruction: reviewed.instruction,
            summary: proposal.title,
            detail: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            changes: [AgentChange(proposal)],
            status: ProposalStatus(reviewed.status),
            createdAt: proposal.createdAt,
            decidedAt: reviewed.decidedAt
        )
    }
}

extension AgentChange {
    init(_ proposal: ModeChangeProposal) {
        let fields = proposal.changes.map { AgentFieldChange(name: $0.path, before: $0.before, after: $0.after) }
        switch proposal.action {
        case .create(let definition):
            self.init(kind: .create, targetID: definition.id.rawValue, fields: fields)
        case .update(_, let after):
            self.init(kind: .modify, targetID: after.id.rawValue, fields: fields)
        case .delete(let definition):
            self.init(kind: .remove, targetID: definition.id.rawValue, fields: fields)
        case .activate(_, let to):
            self.init(kind: .modify, targetID: to.rawValue, fields: fields)
        case .releaseNotification(_, let description):
            self.init(kind: .modify, targetID: "held notifications", fields: [
                AgentFieldChange(name: "deliver now", before: nil, after: description),
            ])
        }
    }
}
