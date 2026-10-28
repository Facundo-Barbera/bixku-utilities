import Foundation

/// How many undelivered elements a subscription keeps before dropping.
public enum StreamBuffering: Sendable, Equatable {
    /// Keep everything (use only for low-volume streams).
    case unbounded
    /// Keep the newest `n` elements, dropping older ones.
    case newest(Int)
    /// Keep the oldest `n` elements, dropping newer ones.
    case oldest(Int)

    func policy<T>(for _: T.Type) -> AsyncStream<T>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded: return .unbounded
        case .newest(let n): return .bufferingNewest(max(1, n))
        case .oldest(let n): return .bufferingOldest(max(1, n))
        }
    }
}

/// Fan-out of values to any number of `AsyncStream` subscribers.
///
/// Each subscriber has a `transform` that filters/maps the broadcast value; returning
/// `nil` skips delivery. Cancelling the consuming task (or dropping the stream)
/// removes the subscriber.
final class Broadcaster<Input: Sendable>: @unchecked Sendable {
    private struct Subscriber {
        let deliver: @Sendable (Input) -> Void
        let finish: @Sendable () -> Void
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        var isFinished = false
    }

    private let state = Locked(State())

    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    func subscribe<Output: Sendable>(
        buffering: StreamBuffering,
        transform: @escaping @Sendable (Input) -> Output?
    ) -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Output.self,
            bufferingPolicy: buffering.policy(for: Output.self)
        )
        let id = UUID()
        let subscriber = Subscriber(
            deliver: { input in
                if let output = transform(input) {
                    continuation.yield(output)
                }
            },
            finish: { continuation.finish() }
        )
        let accepted = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            state.subscribers[id] = subscriber
            return true
        }
        guard accepted else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func broadcast(_ input: Input) {
        // Deliver outside the lock: `onTermination` handlers re-enter `remove`.
        let targets = state.withLock { Array($0.subscribers.values) }
        for target in targets {
            target.deliver(input)
        }
    }

    /// Finishes every subscription; later subscriptions finish immediately.
    func finish() {
        let targets = state.withLock { state -> [Subscriber] in
            state.isFinished = true
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for target in targets {
            target.finish()
        }
    }

    private func remove(_ id: UUID) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
