import BixkuDock
import BixkuNotify
import Foundation
import UserNotifications

/// Shows the end-of-mode digest as a system notification (UserNotifications).
///
/// The text comes from ``DigestNotificationContent``. The notification carries two actions,
/// "Review" (brings the app forward) and "Clear"; what they do is up to `onResponse`.
/// Notifications are only possible from a bundled app, so everything here is a no-op or
/// throws ``Failure/unavailable`` when running a bare `swift run` binary.
final class DigestNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Response: Equatable, Sendable {
        /// The notification or its "Review" button was clicked.
        case review
        /// The "Clear" button was pressed or the notification was dismissed.
        case clear
    }

    enum Failure: Error, Equatable {
        /// Not running as an `.app` bundle, so there is no notification center to talk to.
        case unavailable
        /// The user denied notifications for the app (System Settings > Notifications).
        case notAuthorized
    }

    static let categoryID = "online.bixku.dock.digest"
    static let reviewActionID = "online.bixku.dock.digest.review"
    static let clearActionID = "online.bixku.dock.digest.clear"

    private let onResponse: @Sendable (Response) -> Void

    init(onResponse: @escaping @Sendable (Response) -> Void) {
        self.onResponse = onResponse
        super.init()
    }

    /// `UNUserNotificationCenter.current()` raises an exception outside an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Becomes the center's delegate and registers the digest category next to any other
    /// registered category. Call once at launch, before delivering anything.
    func configure() async {
        guard let center else { return }
        center.delegate = self
        let review = UNNotificationAction(identifier: Self.reviewActionID, title: "Review", options: [.foreground])
        let clear = UNNotificationAction(identifier: Self.clearActionID, title: "Clear", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [review, clear],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        var categories = await center.notificationCategories()
        categories.update(with: category)
        center.setNotificationCategories(categories)
    }

    /// Asks for permission to show alerts. Returns whether it was granted.
    @discardableResult
    func requestAuthorization() async throws -> Bool {
        guard let center else { throw Failure.unavailable }
        return try await center.requestAuthorization(options: [.alert])
    }

    /// Delivers `digest` now. Asks for permission the first time. Does nothing for an empty digest.
    func deliver(_ digest: NotificationDigest) async throws {
        guard let center else { throw Failure.unavailable }
        guard let digestContent = DigestNotificationContent(digest: digest) else { return }

        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert]) else { throw Failure.notAuthorized }
        case .denied:
            throw Failure.notAuthorized
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = digestContent.title
        content.body = digestContent.body
        content.threadIdentifier = digestContent.threadIdentifier
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["modeID": digest.modeID.rawValue]
        try await center.add(UNNotificationRequest(identifier: digestContent.identifier, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the digest even when the app is frontmost.
        let isDigest = notification.request.content.categoryIdentifier == Self.categoryID
        completionHandler(isDigest ? [.banner, .list] : [])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.notification.request.content.categoryIdentifier == Self.categoryID else { return }
        switch response.actionIdentifier {
        case Self.clearActionID, UNNotificationDismissActionIdentifier:
            onResponse(.clear)
        default:
            onResponse(.review)
        }
    }
}
