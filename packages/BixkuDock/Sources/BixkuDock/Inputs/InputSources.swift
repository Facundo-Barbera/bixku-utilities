import BixkuCore
import Foundation

/// Produces ``ActivitySample``s. The macOS app implements it with `NSWorkspace`
/// (frontmost app), the Accessibility API (focused window title, browser URL) and
/// `CGEventSource` (idle time).
///
/// Contract:
/// - ``start()`` begins observing and returns the stream of samples. It may throw if a
///   required permission is missing (report it; the engine keeps running without it).
/// - Emit a sample whenever the frontmost app, focused window or document changes,
///   and periodically while nothing changes (every few seconds) so durations and
///   idle time stay current. The engine deduplicates identical samples cheaply.
/// - Apply privacy filtering you can do locally (e.g. never read titles of password
///   managers); the engine additionally redacts configured apps.
/// - ``stop()`` finishes the stream. `start()` may be called again after `stop()`.
public protocol ActivitySource: AnyObject, Sendable {
    func start() async throws -> AsyncStream<ActivitySample>
    func stop() async
}

/// Produces ``IncomingNotification``s as they are delivered. Same contract as
/// ``ActivitySource``. On macOS the app observes delivered notifications (e.g. via
/// the Accessibility API on the Notification Center UI) and maps them; set
/// ``IncomingNotification/category`` when the source can tell, else leave it `nil`.
public protocol NotificationSource: AnyObject, Sendable {
    func start() async throws -> AsyncStream<IncomingNotification>
    func stop() async
}

/// A source fed by hand: call ``send(_:)``. For tests, previews and debugging UIs.
///
/// Elements sent while not started are dropped.
public final class ManualSource<Element: Sendable>: @unchecked Sendable {
    private let continuation = Locked<AsyncStream<Element>.Continuation?>(nil)

    public init() {}

    public func start() async throws -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let previous = self.continuation.withLock { current -> AsyncStream<Element>.Continuation? in
            defer { current = continuation }
            return current
        }
        previous?.finish()
        return stream
    }

    public func stop() async {
        finish()
    }

    /// Delivers `element`. Returns `false` if the source is not started.
    @discardableResult
    public func send(_ element: Element) -> Bool {
        guard let continuation = continuation.withLock({ $0 }) else { return false }
        if case .terminated = continuation.yield(element) { return false }
        return true
    }

    /// Ends the current stream.
    public func finish() {
        continuation.withLock { current in
            current?.finish()
            current = nil
        }
    }

    public var isStarted: Bool {
        continuation.withLock { $0 != nil }
    }
}

/// A source that plays a fixed script on a ``BixkuClock`` (each step waits `delay`
/// after the previous one). Finishes after the last step unless `keepOpen` is set.
public final class ScriptedSource<Element: Sendable>: @unchecked Sendable {
    public struct Step: Sendable {
        public var delay: Duration
        public var element: Element

        public init(after delay: Duration, _ element: Element) {
            self.delay = delay
            self.element = element
        }
    }

    public let steps: [Step]
    private let clock: any BixkuClock
    private let keepOpen: Bool
    private let task = Locked<Task<Void, Never>?>(nil)

    public init(steps: [Step], clock: any BixkuClock, keepOpen: Bool = false) {
        self.steps = steps
        self.clock = clock
        self.keepOpen = keepOpen
    }

    public func start() async throws -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let steps = steps
        let clock = clock
        let keepOpen = keepOpen
        let newTask = Task {
            for step in steps {
                do {
                    try await clock.sleep(for: step.delay)
                } catch {
                    break
                }
                continuation.yield(step.element)
            }
            if !keepOpen || Task.isCancelled { continuation.finish() }
        }
        continuation.onTermination = { _ in newTask.cancel() }
        task.withLock { current in
            current?.cancel()
            current = newTask
        }
        return stream
    }

    public func stop() async {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

extension ManualSource: ActivitySource where Element == ActivitySample {}
extension ManualSource: NotificationSource where Element == IncomingNotification {}
extension ScriptedSource: ActivitySource where Element == ActivitySample {}
extension ScriptedSource: NotificationSource where Element == IncomingNotification {}

public typealias ManualActivitySource = ManualSource<ActivitySample>
public typealias ManualNotificationSource = ManualSource<IncomingNotification>
public typealias ScriptedActivitySource = ScriptedSource<ActivitySample>
public typealias ScriptedNotificationSource = ScriptedSource<IncomingNotification>
