import BixkuCore
import BixkuDock
import Foundation

/// Errors raised while turning tool calls into proposals or applying them.
public enum ModeAgentError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownMode(ModeID)
    case modeAlreadyExists(ModeID)
    case invalidMode(ModeValidationError)
    case cannotDeleteBuiltInMode(ModeID)
    case noChanges(ModeID)
    case unknownProposal(UUID)
    /// The proposal is not in a state that allows the action.
    case proposalNotPending(UUID, ProposalStatus)
    /// The mode changed since the proposal (or history entry) was computed.
    case stale(ModeID)
    case unknownHistoryVersion(Int)
    case unknownNotification(UUID)
    case unknownTool(String)
    case invalidArguments(tool: String, message: String)
    case malformedReply(String)
    case tooManySteps(Int)
    case unavailable(String)

    public var description: String {
        switch self {
        case .unknownMode(let id): return "No mode with id '\(id)'"
        case .modeAlreadyExists(let id): return "A mode with id '\(id)' already exists; use propose_mode_change"
        case .invalidMode(let error): return error.description
        case .cannotDeleteBuiltInMode(let id): return "'\(id)' is a built-in mode and cannot be deleted"
        case .noChanges(let id): return "The proposed definition of '\(id)' is identical to the current one"
        case .unknownProposal(let id): return "No proposal with id \(id)"
        case .proposalNotPending(let id, let status): return "Proposal \(id) is \(status.rawValue); that action is not possible"
        case .stale(let id): return "Mode '\(id)' changed since this was computed; ask the agent again"
        case .unknownHistoryVersion(let version): return "No history version \(version)"
        case .unknownNotification(let id): return "No held notification with id \(id)"
        case .unknownTool(let name): return "Unknown tool '\(name)'"
        case .invalidArguments(let tool, let message): return "Invalid arguments for \(tool): \(message)"
        case .malformedReply(let message): return "Malformed reply: \(message)"
        case .tooManySteps(let steps): return "The agent did not finish within \(steps) steps"
        case .unavailable(let message): return "The language model is unavailable: \(message)"
        }
    }
}

extension ModeAgentError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Turns agent actions into proposals, gates them through the ``ApprovalPolicy``,
/// applies approved ones to the ``ModeStore`` / dock, and keeps the versioned
/// ``ModeHistory`` (with revert).
///
/// Nothing the language model says is trusted here: every action is re-validated
/// against the live catalog both when proposed and when applied.
public actor ProposalCoordinator {
    public nonisolated let store: any ModeStore
    public nonisolated let dock: (any ModeAgentDockAccess)?
    public nonisolated let history: ModeHistory
    private var policy: ApprovalPolicy
    private let validator = ModeValidator()
    private let clock: any BixkuClock
    private let eventBus: EventBus?
    private let source: ModuleID?
    private var proposals: [UUID: ModeChangeProposal] = [:]
    private var order: [UUID] = []

    public init(
        store: any ModeStore,
        dock: (any ModeAgentDockAccess)? = nil,
        history: ModeHistory = ModeHistory(),
        policy: ApprovalPolicy = .default,
        clock: any BixkuClock = SystemClock(),
        eventBus: EventBus? = nil,
        source: ModuleID? = nil
    ) {
        self.store = store
        self.dock = dock
        self.history = history
        self.policy = policy
        self.clock = clock
        self.eventBus = eventBus
        self.source = source
    }

    public var approvalPolicy: ApprovalPolicy { policy }

    public func setApprovalPolicy(_ policy: ApprovalPolicy) {
        self.policy = policy
    }

    /// Every proposal of this session, oldest first.
    public var allProposals: [ModeChangeProposal] {
        order.compactMap { proposals[$0] }
    }

    public var pendingProposals: [ModeChangeProposal] {
        allProposals.filter { $0.status == .pending }
    }

    public func proposal(_ id: UUID) -> ModeChangeProposal? {
        proposals[id]
    }

    // MARK: - Proposing

    /// Validates `action`, records a proposal, and applies it right away if the
    /// policy allows. Throws (without recording anything) if the action is invalid.
    @discardableResult
    public func submit(_ action: ProposedAction, justification: String, untrusted: Bool) async throws -> ModeChangeProposal {
        let catalog = try await store.load()
        try check(action, against: catalog)
        let (risk, reasons) = policy.assess(action)
        var proposal = ModeChangeProposal(
            action: action,
            justification: String(justification.prefix(1_000)),
            changes: changes(of: action),
            risk: risk,
            riskReasons: reasons,
            influencedByUntrustedData: untrusted,
            createdAt: clock.now()
        )
        let decision = policy.decide(proposal)
        proposals[proposal.id] = proposal
        order.append(proposal.id)
        eventBus?.publish(AgentProposalEvent(proposal: proposal, requiresConfirmation: decision == .requireConfirmation), source: source)
        if decision == .autoApprove {
            proposal = try await apply(proposal.id, autoApproved: true)
        }
        return proposal
    }

    /// The user approved a pending proposal.
    @discardableResult
    public func approve(_ id: UUID) async throws -> ModeChangeProposal {
        try await apply(id, autoApproved: false)
    }

    /// The user rejected a pending proposal.
    @discardableResult
    public func reject(_ id: UUID) throws -> ModeChangeProposal {
        guard var proposal = proposals[id] else { throw ModeAgentError.unknownProposal(id) }
        guard proposal.status == .pending else { throw ModeAgentError.proposalNotPending(id, proposal.status) }
        proposal.status = .rejected
        proposals[id] = proposal
        return proposal
    }

    // MARK: - Applying

    private func apply(_ id: UUID, autoApproved: Bool) async throws -> ModeChangeProposal {
        guard var proposal = proposals[id] else { throw ModeAgentError.unknownProposal(id) }
        guard proposal.status == .pending else { throw ModeAgentError.proposalNotPending(id, proposal.status) }
        do {
            let catalog = try await store.load()
            try check(proposal.action, against: catalog)
            var version: Int?
            switch proposal.action {
            case .create(let definition):
                try await store.save(definition)
                version = try await record(modeID: definition.id, before: nil, after: definition, catalog: catalog, proposal: proposal)
            case .update(let before, let after):
                guard catalog.definition(after.id) == before else { throw ModeAgentError.stale(after.id) }
                try await store.save(after)
                version = try await record(modeID: after.id, before: before, after: after, catalog: catalog, proposal: proposal)
            case .delete(let definition):
                guard catalog.definition(definition.id) == definition else { throw ModeAgentError.stale(definition.id) }
                try await store.delete(definition.id)
                let restored = try await store.load().definition(definition.id)
                version = try await record(modeID: definition.id, before: definition, after: restored, catalog: catalog, proposal: proposal)
            case .activate(_, let to):
                guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
                try await dock.setActiveMode(to, reason: "agent: \(proposal.justification)")
            case .releaseNotification(let notificationID, _):
                guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
                try await dock.releaseNotification(notificationID)
            }
            proposal.status = .applied
            proposals[id] = proposal
            eventBus?.publish(
                AgentAppliedEvent(proposal: proposal, historyVersion: version, autoApproved: autoApproved, summary: proposal.title),
                source: source
            )
            return proposal
        } catch {
            proposal.status = .failed
            proposals[id] = proposal
            throw error
        }
    }

    private func record(
        modeID: ModeID,
        before: ModeDefinition?,
        after: ModeDefinition?,
        catalog: ModeCatalog,
        proposal: ModeChangeProposal
    ) async throws -> Int {
        try await history.record(
            modeID: modeID,
            before: before,
            beforeProvenance: catalog.mode(modeID)?.provenance,
            after: after,
            proposalID: proposal.id,
            summary: proposal.title,
            at: clock.now()
        ).version
    }

    /// Restores the mode touched by history entry `version` to its state before
    /// that entry. Reverts are themselves recorded (and can be reverted). The user
    /// asks for reverts directly, so they skip the approval policy.
    @discardableResult
    public func revert(_ version: Int) async throws -> ModeHistoryEntry {
        guard let entry = try await history.entry(version) else { throw ModeAgentError.unknownHistoryVersion(version) }
        let catalog = try await store.load()
        let current = catalog.mode(entry.modeID)
        guard current?.definition == entry.after else { throw ModeAgentError.stale(entry.modeID) }

        switch (entry.before, entry.beforeProvenance) {
        case (nil, _), (_, .factory?):
            // Did not exist, or was the built-in version: drop the user document.
            if current?.provenance != .factory { try await store.delete(entry.modeID) }
        case (let before?, _):
            try await store.save(before)
        }
        let restored = try await store.load().mode(entry.modeID)
        let reverted = try await history.record(
            modeID: entry.modeID,
            before: current?.definition,
            beforeProvenance: current?.provenance,
            after: restored?.definition,
            proposalID: nil,
            revertsVersion: version,
            summary: "Revert v\(version): \(entry.summary)",
            at: clock.now()
        )
        eventBus?.publish(
            AgentAppliedEvent(proposal: nil, historyVersion: reverted.version, autoApproved: false, summary: reverted.summary),
            source: source
        )
        return reverted
    }

    /// Undoes an applied catalog proposal (reverts its history entry) and marks it
    /// ``ProposalStatus/reverted``.
    @discardableResult
    public func revertProposal(_ id: UUID) async throws -> ModeChangeProposal {
        guard var proposal = proposals[id] else { throw ModeAgentError.unknownProposal(id) }
        guard proposal.status == .applied, proposal.action.changesCatalog else {
            throw ModeAgentError.proposalNotPending(id, proposal.status)
        }
        guard let entry = try await history.all().last(where: { $0.proposalID == id }) else {
            throw ModeAgentError.unknownProposal(id)
        }
        try await revert(entry.version)
        proposal.status = .reverted
        proposals[id] = proposal
        return proposal
    }

    // MARK: - Checks

    private func check(_ action: ProposedAction, against catalog: ModeCatalog) throws {
        switch action {
        case .create(let definition):
            guard !catalog.contains(definition.id) else { throw ModeAgentError.modeAlreadyExists(definition.id) }
            try validate(definition, known: Set(catalog.ids).union([definition.id]))
        case .update(let before, let after):
            guard before.id == after.id, catalog.contains(after.id) else { throw ModeAgentError.unknownMode(after.id) }
            guard before != after else { throw ModeAgentError.noChanges(after.id) }
            try validate(after, known: Set(catalog.ids))
        case .delete(let definition):
            guard let mode = catalog.mode(definition.id) else { throw ModeAgentError.unknownMode(definition.id) }
            guard mode.provenance != .factory else { throw ModeAgentError.cannotDeleteBuiltInMode(definition.id) }
        case .activate(_, let to):
            guard catalog.contains(to) else { throw ModeAgentError.unknownMode(to) }
        case .releaseNotification:
            break
        }
    }

    private func validate(_ definition: ModeDefinition, known: Set<ModeID>) throws {
        do {
            try validator.validate(definition, knownModes: known)
        } catch let error as ModeValidationError {
            throw ModeAgentError.invalidMode(error)
        }
    }

    private func changes(of action: ProposedAction) -> [ModeFieldChange] {
        switch action {
        case .create(let definition): return ModeDiff.changes(from: nil, to: definition)
        case .update(let before, let after): return ModeDiff.changes(from: before, to: after)
        case .delete(let definition): return ModeDiff.changes(from: definition, to: nil)
        case .activate(let from, let to):
            return [ModeFieldChange(path: "activeMode", before: from.map { "\"\($0)\"" }, after: "\"\(to)\"")]
        case .releaseNotification: return []
        }
    }
}
