import BixkuDock
import BixkuNotify
import Foundation
import os

/// Feeds `bixku://notify` URLs to the Dock module as ``IncomingNotification``s.
///
/// macOS does not let an app read other apps' notifications, so this is the supported way to
/// get a notification in: a script, a CI hook, a shortcut or `bixku-notify` opens a URL.
/// The URL is untrusted input: ``NotifyURL`` validates and sanitizes it and a rate limiter
/// caps the flow. See docs/notifications.md.
final class URLSchemeNotificationSource: NotificationSource, @unchecked Sendable {
    /// What happened to a received URL.
    enum Outcome: Equatable {
        case delivered
        case rejected(NotifyURLError)
        case rateLimited
        /// The Dock module is not listening (stopped or never started); the URL is dropped.
        case notListening
    }

    /// The instance the app delegate forwards URLs to and the Dock module subscribes to.
    static let shared = URLSchemeNotificationSource()

    private let source = ManualNotificationSource()
    private let lock = NSLock()
    private var limiter: NotifyRateLimiter
    private let logger = Logger(subsystem: "online.bixku.utilities", category: "notify-url")

    init(limiter: NotifyRateLimiter = NotifyRateLimiter()) {
        self.limiter = limiter
    }

    func start() async throws -> AsyncStream<IncomingNotification> {
        try await source.start()
    }

    func stop() async {
        await source.stop()
    }

    /// Handles one opened URL. Only the outcome is logged, never the content.
    @discardableResult
    func receive(_ url: URL, now: Date = Date()) -> Outcome {
        guard url.scheme?.lowercased() == NotifyURL.scheme else { return .rejected(.wrongScheme) }
        lock.lock()
        let allowed = limiter.allow(at: now)
        lock.unlock()
        guard allowed else {
            logger.info("bixku://notify dropped: rate limit")
            return .rateLimited
        }
        switch NotifyURL.parse(url, now: now) {
        case .failure(let error):
            logger.info("bixku://notify rejected: \(error.description, privacy: .public)")
            return .rejected(error)
        case .success(let notification):
            guard source.send(notification) else {
                logger.info("bixku://notify dropped: Dock module is not listening")
                return .notListening
            }
            return .delivered
        }
    }
}
