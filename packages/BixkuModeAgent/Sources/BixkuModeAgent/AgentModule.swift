import BixkuCore
import BixkuDock
import Foundation

/// The mode agent as a Bixku module.
///
/// It owns a ``ProposalCoordinator`` (history persisted in the module's storage,
/// events published on the bus as `agent.proposal` / `agent.applied`) and a
/// ``ModeAgent``. The mode store, dock access and language model are injected by
/// the host, which wires them to the Dock module and the shared LLM client.
///
/// Config (`[modules.mode-agent]`): `approval = "confirm-all" | "auto-approve-low-risk"`.
public final class AgentModule: BixkuModule, @unchecked Sendable {
    public static let moduleID: ModuleID = "online.bixku.mode-agent"

    public let manifest = ModuleManifest(
        id: AgentModule.moduleID,
        displayName: "Mode Agent",
        summary: "Adjusts Dock modes and creates new ones on request, with your approval.",
        version: SemanticVersion(0, 1, 0),
        capabilities: [.languageModel, .eventProducer],
        permissions: [.network]
    )

    private let store: any ModeStore
    private let dock: (any ModeAgentDockAccess)?
    private let llm: any AgentLLM
    private let policyOverride: ApprovalPolicy?
    private let lock = NSLock()
    private var running: ModeAgent?

    public init(store: any ModeStore, dock: (any ModeAgentDockAccess)?, llm: any AgentLLM, policy: ApprovalPolicy? = nil) {
        self.store = store
        self.dock = dock
        self.llm = llm
        self.policyOverride = policy
    }

    /// The running agent (`nil` while stopped).
    public var agent: ModeAgent? {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func start(context: ModuleContext) async throws {
        var policy = policyOverride ?? .default
        if policyOverride == nil, let value = context.moduleConfig.string("approval"),
           let mode = ApprovalPolicy.Mode(rawValue: value)
        {
            policy.mode = mode
        }
        let coordinator = ProposalCoordinator(
            store: store,
            dock: dock,
            history: ModeHistory(storage: context.storage),
            policy: policy,
            clock: context.clock,
            eventBus: context.eventBus,
            source: context.moduleID
        )
        let agent = ModeAgent(llm: llm, coordinator: coordinator, clock: context.clock)
        setRunning(agent)
    }

    public func stop() async {
        setRunning(nil)
    }

    private func setRunning(_ agent: ModeAgent?) {
        lock.lock()
        running = agent
        lock.unlock()
    }
}
