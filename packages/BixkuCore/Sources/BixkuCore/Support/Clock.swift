import Foundation

/// Source of time for modules. Inject it instead of calling `Date()` / `Task.sleep`
/// directly so time-dependent logic can be tested with ``ManualClock``.
///
/// Named `BixkuClock` to avoid clashing with the standard library's `Clock` protocol.
public protocol BixkuClock: Sendable {
    /// The current wall-clock time.
    func now() -> Date
    /// Suspends for `duration`. Throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock.
public struct SystemClock: BixkuClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A clock that only moves when ``advance(by:)`` is called. Intended for tests.
public final class ManualClock: BixkuClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Date
        var sleepers: [UUID: Sleeper] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state: Locked<State>

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        state = Locked(State(now: now))
    }

    public func now() -> Date {
        state.withLock { $0.now }
    }

    /// Number of tasks currently suspended in ``sleep(for:)``.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    public func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Action { case resume, cancel, wait }
                let action = state.withLock { state -> Action in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    let deadline = state.now.addingTimeInterval(duration.timeInterval)
                    if deadline <= state.now { return .resume }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.addingTimeInterval(duration.timeInterval)
            let now = state.now
            let dueIDs = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

extension Duration {
    /// The duration in (fractional) seconds.
    public var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
