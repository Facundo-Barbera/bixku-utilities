import Foundation

/// An ``AgentControlling`` that calls no LLM. It answers every instruction with
/// a canned "create mode" proposal and tracks approval state in memory, so the
/// Agent tab is usable end to end until the real agent is plugged in.
final class PlaceholderAgent: AgentControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AgentProposal] = []
    private var subscribers: [UUID: AsyncStream<[AgentProposal]>.Continuation] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    var proposals: AsyncStream<[AgentProposal]> {
        AsyncStream { continuation in
            let token = UUID()
            lock.lock()
            subscribers[token] = continuation
            continuation.yield(items)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[token] = nil
                self.lock.unlock()
            }
        }
    }

    func instruct(_ instruction: String) async throws {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentError.emptyInstruction }

        let modeID = Self.slug(from: text)
        let proposal = AgentProposal(
            instruction: text,
            summary: "Add a mode named \"\(modeID)\" (placeholder agent, no LLM involved)",
            changes: [
                AgentChange(kind: .create, targetID: modeID, fields: [
                    AgentFieldChange(name: "name", before: nil, after: modeID.capitalized),
                    AgentFieldChange(name: "summary", before: nil, after: text),
                ]),
            ],
            createdAt: now()
        )
        mutate { $0.append(proposal) }
    }

    func approve(_ id: AgentProposal.ID) async throws {
        try transition(id, action: "approve", from: .pending, to: .approved)
    }

    func reject(_ id: AgentProposal.ID) async throws {
        try transition(id, action: "reject", from: .pending, to: .rejected)
    }

    func revert(_ id: AgentProposal.ID) async throws {
        try transition(id, action: "revert", from: .approved, to: .reverted)
    }

    private func transition(_ id: AgentProposal.ID, action: String, from: ProposalStatus, to: ProposalStatus) throws {
        let decidedAt = now()
        try mutate { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw AgentError.unknownProposal(id)
            }
            guard items[index].status == from else {
                throw AgentError.invalidTransition(action: action, status: items[index].status)
            }
            items[index].status = to
            items[index].decidedAt = decidedAt
        }
    }

    /// Applies `change` and publishes the new list. Nothing is published if it throws.
    /// Publishing happens under the lock (`yield` never blocks) so subscribers see updates in order.
    private func mutate(_ change: (inout [AgentProposal]) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        var updated = items
        try change(&updated)
        items = updated
        for subscriber in subscribers.values {
            subscriber.yield(updated)
        }
    }

    /// A lowercase, hyphenated identifier made from the first words of `text`.
    static func slug(from text: String) -> String {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(3)
            .map(String.init)
        return words.isEmpty ? "new-mode" : words.joined(separator: "-")
    }
}
