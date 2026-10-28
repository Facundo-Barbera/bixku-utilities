import Foundation

/// A deterministic ``LLMClient`` for tests: replays queued steps in order and records
/// every request it receives.
public final class ScriptedLLM: LLMClient, @unchecked Sendable {
    public enum Step: Sendable {
        case respond(LLMResponse)
        case fail(any Error)
    }

    public typealias Handler = @Sendable (LLMRequest) async throws -> LLMResponse

    private struct State {
        var steps: [Step]
        var requests: [LLMRequest] = []
    }

    private let state: LockedBox<State>
    private let handler: Handler?
    private let delay: TimeInterval

    /// - Parameter delay: seconds to wait before answering (cancellable); useful for
    ///   testing cancellation and timeouts.
    public init(_ steps: [Step] = [], delay: TimeInterval = 0) {
        self.state = LockedBox(State(steps: steps))
        self.handler = nil
        self.delay = delay
    }

    public convenience init(responses: [LLMResponse], delay: TimeInterval = 0) {
        self.init(responses.map { .respond($0) }, delay: delay)
    }

    /// Answers every request through `handler` instead of a queue.
    public init(handler: @escaping Handler) {
        self.state = LockedBox(State(steps: []))
        self.handler = handler
        self.delay = 0
    }

    /// Queues one more step.
    public func enqueue(_ step: Step) {
        state.withLock { $0.steps.append(step) }
    }

    public func enqueue(_ response: LLMResponse) {
        enqueue(.respond(response))
    }

    /// Every request received so far, oldest first.
    public var requests: [LLMRequest] { state.withLock { $0.requests } }
    public var callCount: Int { state.withLock { $0.requests.count } }
    /// Scripted steps not consumed yet.
    public var remaining: Int { state.withLock { $0.steps.count } }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        state.withLock { $0.requests.append(request) }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
        if let handler {
            return try await handler(request)
        }
        let step: Step? = state.withLock { $0.steps.isEmpty ? nil : $0.steps.removeFirst() }
        switch step {
        case .respond(let response): return response
        case .fail(let error): throw error
        case nil: throw LLMError.scriptExhausted
        }
    }
}
