import BixkuCore
import Foundation

/// Thrown when an operation does not finish before its deadline.
public struct DeadlineExceeded: Error, Equatable, Sendable, CustomStringConvertible {
    public var timeout: Duration

    public var description: String {
        "timed out after \(DurationFormat.short(timeout.timeInterval))"
    }
}

/// Runs `operation` with a timeout measured on `clock`.
///
/// Unlike a task group, this returns as soon as the deadline passes even if the
/// operation ignores cancellation (it is cancelled and left to finish on its own),
/// so a misbehaving LLM provider cannot stall the engine.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    clock: any BixkuClock,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.install(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                do {
                    try await clock.sleep(for: timeout)
                    race.finish(.failure(DeadlineExceeded(timeout: timeout)))
                } catch {
                    // Cancelled: the operation finished first.
                }
            }
            race.track(work: work, timer: timer)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// First-result-wins bookkeeping for ``withDeadline(_:clock:operation:)``.
private final class Race<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var pending: Result<T, Error>?
        var done = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = Locked(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let pending = state.withLock { state -> Result<T, Error>? in
            state.continuation = continuation
            return state.pending
        }
        if let pending {
            state.withLock { $0.continuation = nil }
            continuation.resume(with: pending)
        }
    }

    func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let finished = state.withLock { state -> Bool in
            state.work = work
            state.timer = timer
            return state.done
        }
        if finished {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, work, timer) = state.withLock { state -> (CheckedContinuation<T, Error>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !state.done else { return (nil, nil, nil) }
            state.done = true
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil { state.pending = result }
            return (continuation, state.work, state.timer)
        }
        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
