import BixkuCore
import BixkuDock
import Foundation
import XCTest
import BixkuLLM
@testable import BixkuModeAgent

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

struct ScriptedLLMError: Error {}

/// A BixkuLLM ``ScriptedLLM`` answering with `replies` in order.
func scripted(_ replies: [String]) -> ScriptedLLM {
    ScriptedLLM(responses: replies.map { LLMResponse.text($0) })
}

/// In-memory dock with an active mode, activity and held notifications.
actor FakeDock: ModeAgentDockAccess {
    var active: ModeID? = .writing
    var activity: [ClassifiedActivity] = []
    var held: [TriagedNotification] = []
    private(set) var released: [UUID] = []
    private(set) var activations: [(ModeID, String)] = []

    func activeMode() -> ModeID? { active }

    func setActiveMode(_ id: ModeID, reason: String) {
        active = id
        activations.append((id, reason))
    }

    func recentActivity(limit: Int) -> [ClassifiedActivity] { Array(activity.suffix(limit)) }

    func heldNotifications() -> [TriagedNotification] { held }

    func releaseNotification(_ id: UUID) throws {
        guard held.contains(where: { $0.id == id }) else { throw ModeAgentError.unknownNotification(id) }
        held.removeAll { $0.id == id }
        released.append(id)
    }

    func setActivity(_ activity: [ClassifiedActivity]) { self.activity = activity }
    func setHeld(_ held: [TriagedNotification]) { self.held = held }
}

struct Harness {
    let store: JSONModeStore
    let dock: FakeDock
    let bus: EventBus
    let coordinator: ProposalCoordinator
    let clock: ManualClock

    init(policy: ApprovalPolicy = .default) {
        clock = ManualClock(now: t0)
        store = JSONModeStore(backend: InMemoryModeBackend())
        dock = FakeDock()
        bus = EventBus(clock: clock)
        coordinator = ProposalCoordinator(
            store: store,
            dock: dock,
            history: ModeHistory(storage: InMemoryModuleStorage()),
            policy: policy,
            clock: clock,
            eventBus: bus,
            source: AgentModule.moduleID
        )
    }

    func agent(_ llm: ScriptedLLM, maxSteps: Int = 12) -> ModeAgent {
        ModeAgent(llm: LLMClientAgentLLM(client: llm), coordinator: coordinator, clock: clock, maxSteps: maxSteps)
    }
}

/// A minimal valid user mode.
func makeMode(_ id: ModeID, defaultAction: NotificationAction = .allow) -> ModeDefinition {
    ModeDefinition(
        id: id,
        name: id.rawValue.capitalized,
        symbol: "circle",
        summary: "Test mode \(id)",
        notifications: NotificationPolicy(defaultAction: defaultAction)
    )
}

func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
}

func callTool(_ tool: String, _ arguments: String = "{}") -> String {
    #"{"action":"call_tool","tool":"\#(tool)","arguments":\#(arguments)}"#
}

func finish(_ message: String = "done") -> String {
    #"{"action":"finish","message":"\#(message)"}"#
}

func modeArguments(_ mode: ModeDefinition, _ justification: String = "because") -> String {
    #"{"mode":\#(json(mode)),"justification":"\#(justification)"}"#
}

func activity(_ bundleID: String, title: String?, category: ActivityCategory, at offset: TimeInterval) -> ClassifiedActivity {
    ClassifiedActivity(
        sample: ActivitySample(appBundleID: bundleID, appName: bundleID.split(separator: ".").last.map(String.init), windowTitle: title, timestamp: t0.addingTimeInterval(offset)),
        verdict: ActivityVerdict(category: category, confidence: 0.9, rationale: "test")
    )
}

func held(title: String, body: String? = nil, category: NotificationCategory = .chat) -> TriagedNotification {
    TriagedNotification(
        notification: IncomingNotification(appBundleID: "com.example.chat", appName: "Chat", title: title, body: body, timestamp: t0),
        category: category,
        decision: TriageDecision(action: .hold, reason: "held"),
        modeID: .writing,
        triagedAt: t0
    )
}
