import AppKit
import BixkuDock
import CoreGraphics
import Foundation

/// Observes what the user is doing: frontmost app via `NSWorkspace`, focused window title via
/// Accessibility (when permitted) and idle time via `CGEventSource`. See ``ActivitySource``.
///
/// Everything runs on one private serial queue; the stream is thread-safe to yield into.
/// Window titles and idle time have no change notification, so a slow timer polls them; app
/// switches are picked up immediately through `NSWorkspace`. The Accessibility permission is
/// re-checked on every poll, so granting it takes effect without restarting the source.
final class NSWorkspaceActivitySource: ActivitySource, @unchecked Sendable {
    struct Configuration: Sendable {
        /// How often titles and idle time are polled.
        var pollInterval: TimeInterval = 1
        /// How long a change of focus must be stable before it is emitted.
        var debounce: TimeInterval = 0.5
        /// Re-emit interval while nothing changes.
        var heartbeat: TimeInterval = 5
        var privacy: ActivityPrivacyFilter = .default
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "online.bixku.utilities.dock.activity-monitor")

    // Guarded by `queue`.
    private var policy: ActivityEmissionPolicy
    private var continuation: AsyncStream<ActivitySample>.Continuation?
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var session: UInt64 = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.policy = ActivityEmissionPolicy(
            debounce: configuration.debounce,
            heartbeat: configuration.heartbeat
        )
    }

    /// Starts observing. Never throws for a missing Accessibility permission: the monitor
    /// degrades to app + idle only (check ``AccessibilityPermission/isTrusted``). Calling it
    /// again replaces the previous stream.
    func start() async throws -> AsyncStream<ActivitySample> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivitySample.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        queue.sync {
            teardown()
            session &+= 1
            let current = session
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                // A consumer that stops iterating ends the session, unless a newer one replaced it.
                self?.queue.async {
                    guard let self, self.session == current else { return }
                    self.teardown()
                }
            }
            policy.reset()
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.appDidActivate() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + configuration.pollInterval,
                repeating: configuration.pollInterval,
                leeway: .milliseconds(200)
            )
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            poll()
        }
        return stream
    }

    func stop() async {
        queue.sync { teardown() }
    }

    // MARK: - Queue-confined

    private func appDidActivate() {
        queue.async { [weak self] in
            self?.poll()
            // The change is only emitted once it has been stable for `debounce`.
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + self.configuration.debounce + 0.05) { [weak self] in
                self?.poll()
            }
        }
    }

    private func poll() {
        guard let continuation else { return }
        guard let sample = ActivitySampleMapper.sample(from: readSystem(), filter: configuration.privacy),
              policy.shouldEmit(sample)
        else { return }
        continuation.yield(sample)
    }

    private func readSystem() -> ActivityReading {
        let app = NSWorkspace.shared.frontmostApplication.map {
            FrontmostApp(
                bundleID: $0.bundleIdentifier,
                name: $0.localizedName,
                processID: $0.processIdentifier
            )
        }
        var title: String?
        if let app, AccessibilityPermission.isTrusted,
           configuration.privacy.allowsTitleRead(bundleID: app.bundleID) {
            title = AccessibilityWindowReader.focusedWindowTitle(processID: app.processID)
        }
        return ActivityReading(
            app: app,
            windowTitle: title,
            idleSeconds: Self.secondsSinceLastInput(),
            timestamp: Date()
        )
    }

    /// Seconds since the last keyboard / pointer event of any kind.
    private static func secondsSinceLastInput() -> TimeInterval {
        // ~0 is the "any event type" wildcard of CGEventSource.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// Idempotent. Must run on `queue`.
    private func teardown() {
        timer?.cancel()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        continuation?.finish()
        continuation = nil
    }
}
