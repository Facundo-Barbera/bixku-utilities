import BixkuCore
import BixkuDock
import Foundation

/// Outcome of one agent run.
public struct AgentRunResult: Sendable, Equatable {
    /// The agent's final answer for the user.
    public var message: String
    /// Proposals made during the run (applied, pending or failed).
    public var proposals: [ModeChangeProposal]
    /// Model replies consumed.
    public var steps: Int
    /// Whether the run read untrusted data (its proposals were never auto-approved).
    public var readUntrustedData: Bool
    public var transcript: [AgentMessage]
}

/// The mode agent: a tool-calling loop over an ``AgentLLM``.
///
/// Each ``run(_:)`` starts a fresh conversation (versioned system prompt + the
/// user's request) and lets the model call the typed ``AgentTool``s until it
/// finishes. Mutating tools go through the ``ProposalCoordinator``, so the
/// model can propose but only the policy or the user can approve.
///
/// Prompt-injection defenses:
/// - untrusted text is sanitized and fenced (``UntrustedText``) and the system
///   prompt declares fenced text to be data;
/// - once a run has read untrusted data, its proposals are never auto-approved;
/// - every argument is decoded into a typed struct and re-validated, unknown
///   tools are rejected, and the loop is bounded.
public actor ModeAgent {
    public nonisolated let coordinator: ProposalCoordinator
    private let llm: any AgentLLM
    private let clock: any BixkuClock
    public let maxSteps: Int
    public let maxMalformedReplies: Int
    public let activityLimit: Int

    public init(
        llm: any AgentLLM,
        coordinator: ProposalCoordinator,
        clock: any BixkuClock = SystemClock(),
        maxSteps: Int = 12,
        maxMalformedReplies: Int = 2,
        activityLimit: Int = 200
    ) {
        self.llm = llm
        self.coordinator = coordinator
        self.clock = clock
        self.maxSteps = max(1, maxSteps)
        self.maxMalformedReplies = max(0, maxMalformedReplies)
        self.activityLimit = max(1, activityLimit)
    }

    public func run(_ request: String) async throws -> AgentRunResult {
        var transcript = [
            AgentMessage(role: .system, content: ModeAgentPrompt.system(now: clock.now())),
            AgentMessage(role: .user, content: request),
        ]
        var proposals: [ModeChangeProposal] = []
        var untrusted = false
        var malformed = 0

        for step in 1...maxSteps {
            try Task.checkCancellation()
            let text: String
            do {
                text = try await llm.complete(AgentLLMRequest(messages: transcript, responseSchema: ModeAgentPrompt.replySchema))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModeAgentError.unavailable(String(describing: error))
            }
            transcript.append(AgentMessage(role: .assistant, content: text))

            let reply: AgentReply
            do {
                reply = try AgentReply.parse(text)
                malformed = 0
            } catch {
                malformed += 1
                if malformed > maxMalformedReplies { throw error }
                transcript.append(AgentMessage(role: .tool, content: "Error: \(error). Reply with one JSON object as specified."))
                continue
            }

            switch reply {
            case .finish(let message):
                let final = try await refreshed(proposals)
                return AgentRunResult(message: message, proposals: final, steps: step, readUntrustedData: untrusted, transcript: transcript)
            case .callTool(let name, let arguments):
                let content: String
                do {
                    guard let tool = AgentTool(rawValue: name) else { throw ModeAgentError.unknownTool(name) }
                    let outcome = try await execute(tool, arguments: arguments, untrusted: untrusted)
                    if tool.returnsUntrustedData { untrusted = true }
                    if let proposal = outcome.proposal { proposals.append(proposal) }
                    content = "Result of \(name):\n\(outcome.json)"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    content = "Error from \(name): \(error)"
                }
                transcript.append(AgentMessage(role: .tool, content: content))
            }
        }
        throw ModeAgentError.tooManySteps(maxSteps)
    }

    // MARK: - Tools

    private struct Outcome {
        var json: String
        var proposal: ModeChangeProposal?
    }

    private func execute(_ tool: AgentTool, arguments: Data, untrusted: Bool) async throws -> Outcome {
        let store = coordinator.store
        let dock = coordinator.dock
        switch tool {
        case .listModes:
            _ = try decode(EmptyArguments.self, arguments, tool)
            let active = await dock?.activeMode()
            let listing = try await store.load().modes.map {
                ModeListing(id: $0.id, name: $0.name, symbol: $0.symbol, description: $0.summary, provenance: $0.provenance, active: $0.id == active)
            }
            return Outcome(json: try encode(listing))

        case .getMode:
            let args = try decode(IDArguments.self, arguments, tool)
            guard let definition = try await store.load().definition(ModeID(rawValue: args.id)) else {
                throw ModeAgentError.unknownMode(ModeID(rawValue: args.id))
            }
            return Outcome(json: String(decoding: try JSONModeStore.encode(definition), as: UTF8.self))

        case .proposeModeChange:
            let args = try decode(ModeArguments.self, try withSchemaVersion(arguments), tool)
            guard let before = try await store.load().definition(args.mode.id) else {
                throw ModeAgentError.unknownMode(args.mode.id)
            }
            return try await propose(.update(before: before, after: args.mode), args.justification, untrusted)

        case .createMode:
            let args = try decode(ModeArguments.self, try withSchemaVersion(arguments), tool)
            return try await propose(.create(args.mode), args.justification, untrusted)

        case .deleteMode:
            let args = try decode(IDArguments.self, arguments, tool)
            let id = ModeID(rawValue: args.id)
            guard let definition = try await store.load().definition(id) else { throw ModeAgentError.unknownMode(id) }
            return try await propose(.delete(definition), args.justification ?? "", untrusted)

        case .setActiveMode:
            let args = try decode(IDArguments.self, arguments, tool)
            guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
            let from = await dock.activeMode()
            return try await propose(.activate(from: from, to: ModeID(rawValue: args.id)), args.justification ?? "", untrusted)

        case .summarizeRecentActivity:
            let args = try decode(ActivityArguments.self, arguments, tool)
            guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
            let limit = min(max(args.limit ?? activityLimit, 1), activityLimit)
            let summary = Self.summarize(await dock.recentActivity(limit: limit), activeMode: await dock.activeMode())
            return Outcome(json: try encode(summary))

        case .listHeldNotifications:
            _ = try decode(EmptyArguments.self, arguments, tool)
            guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
            let listing = await dock.heldNotifications().prefix(50).map { held in
                HeldNotificationListing(
                    id: held.id,
                    app: UntrustedText.wrap(held.notification.displayAppName, maxLength: 60),
                    title: UntrustedText.wrap(held.notification.title),
                    body: held.notification.body.map { UntrustedText.wrap($0) },
                    category: held.category,
                    action: held.decision.action,
                    heldInMode: held.modeID,
                    receivedAt: held.notification.timestamp
                )
            }
            return Outcome(json: try encode(Array(listing)))

        case .releaseNotification:
            let args = try decode(IDArguments.self, arguments, tool)
            guard let dock else { throw ModeAgentError.unavailable("no dock is connected") }
            guard let uuid = UUID(uuidString: args.id) else {
                throw ModeAgentError.invalidArguments(tool: tool.rawValue, message: "'id' must be a notification UUID")
            }
            guard let held = await dock.heldNotifications().first(where: { $0.id == uuid }) else {
                throw ModeAgentError.unknownNotification(uuid)
            }
            let description = UntrustedText.sanitize("\(held.notification.displayAppName): \(held.notification.title)", maxLength: 80)
            return try await propose(.releaseNotification(id: uuid, description: description), args.justification ?? "", untrusted)
        }
    }

    private func propose(_ action: ProposedAction, _ justification: String, _ untrusted: Bool) async throws -> Outcome {
        let proposal = try await coordinator.submit(action, justification: justification, untrusted: untrusted)
        let note = proposal.status == .applied
            ? "Applied (low risk, auto-approved)."
            : "Waiting for the user's confirmation. Do not submit it again."
        let result = ProposalResult(proposalID: proposal.id, status: proposal.status, risk: proposal.risk, diff: proposal.renderedDiff, note: note)
        return Outcome(json: try encode(result), proposal: proposal)
    }

    /// Latest state of the run's proposals (an auto-approved one may have been applied).
    private func refreshed(_ proposals: [ModeChangeProposal]) async throws -> [ModeChangeProposal] {
        var result: [ModeChangeProposal] = []
        for proposal in proposals {
            result.append(await coordinator.proposal(proposal.id) ?? proposal)
        }
        return result
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ tool: AgentTool) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ModeAgentError.invalidArguments(tool: tool.rawValue, message: Self.describe(error))
        }
    }

    /// Fills in `mode.schemaVersion` when the model omits it.
    private func withSchemaVersion(_ arguments: Data) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any],
              var mode = object["mode"] as? [String: Any]
        else { return arguments }
        if mode["schemaVersion"] == nil { mode["schemaVersion"] = ModeDefinition.currentSchemaVersion }
        object["mode"] = mode
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing '\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))'"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return String(describing: error)
        }
    }

    /// Time per app, estimated from the gaps between samples (capped at 5 minutes).
    static func summarize(_ activity: [ClassifiedActivity], activeMode: ModeID?) -> ActivitySummary {
        struct Bucket {
            var name: String
            var bundleID: String?
            var category: ActivityCategory
            var samples = 0
            var seconds: TimeInterval = 0
            var titles: [String] = []
        }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        for (index, item) in activity.enumerated() {
            let key = item.sample.appBundleID ?? item.sample.appName ?? "unknown"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = Bucket(
                    name: item.sample.appName ?? item.sample.appBundleID ?? "Unknown app",
                    bundleID: item.sample.appBundleID,
                    category: item.verdict.category
                )
            }
            buckets[key]?.samples += 1
            buckets[key]?.category = item.verdict.category
            if index + 1 < activity.count {
                let gap = activity[index + 1].sample.timestamp.timeIntervalSince(item.sample.timestamp)
                buckets[key]?.seconds += min(max(gap, 0), 300)
            }
            if let title = item.sample.windowTitle, !title.isEmpty,
               let titles = buckets[key]?.titles, titles.count < 3,
               !titles.contains(UntrustedText.wrap(title, maxLength: 80))
            {
                buckets[key]?.titles.append(UntrustedText.wrap(title, maxLength: 80))
            }
        }
        let apps = order.compactMap { buckets[$0] }
            .sorted { $0.seconds > $1.seconds }
            .map {
                ActivitySummary.App(
                    app: UntrustedText.wrap($0.name, maxLength: 60),
                    bundleID: $0.bundleID.map { UntrustedText.sanitize($0, maxLength: 100) },
                    category: $0.category,
                    samples: $0.samples,
                    approximateMinutes: Int(($0.seconds / 60).rounded()),
                    recentTitles: $0.titles
                )
            }
        return ActivitySummary(activeMode: activeMode, samples: activity.count, apps: apps)
    }
}
