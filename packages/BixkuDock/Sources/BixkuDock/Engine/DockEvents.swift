import BixkuCore
import Foundation

// Events published by the Dock in addition to the shared `activity.changed`,
// `notification.received` and `mode.changed` (declared in BixkuCore).

extension EventName {
    /// A notification was triaged (allowed, held, summarized or silenced).
    public static let notificationTriaged: EventName = "notification.triaged"
    /// The smoothed activity category or its attention level changed.
    public static let dockActivityClassified: EventName = "dock.activity-classified"
    /// A mode ended with held notifications; the digest is ready to show.
    public static let dockDigestReady: EventName = "dock.digest-ready"
}

/// A notification and the decision taken for it.
///
/// The host acts on it: `allow` → leave it visible; `hold` / `summarize` → hide it
/// until the digest; `silence` → hide it.
public struct NotificationTriaged: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .notificationTriaged

    public var notificationID: UUID
    public var appBundleID: String?
    public var appName: String?
    public var title: String
    public var category: NotificationCategory
    public var action: NotificationAction
    public var reason: String
    public var isUrgent: Bool
    public var source: VerdictSource
    public var modeID: String

    public init(_ triaged: TriagedNotification) {
        notificationID = triaged.notification.id
        appBundleID = triaged.notification.appBundleID
        appName = triaged.notification.appName
        title = triaged.notification.title
        category = triaged.category
        action = triaged.decision.action
        reason = triaged.decision.reason
        isUrgent = triaged.decision.isUrgent
        source = triaged.decision.source
        modeID = triaged.modeID.rawValue
    }
}

/// The Dock's view of the current activity changed meaningfully: the smoothed
/// category or the attention level relative to the active mode.
public struct ActivityClassified: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .dockActivityClassified

    public var activity: CurrentActivity
    public var modeID: String

    public init(activity: CurrentActivity, modeID: ModeID) {
        self.activity = activity
        self.modeID = modeID.rawValue
    }
}

/// A digest of what was held back during a mode.
public struct DigestReady: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .dockDigestReady

    public var digest: NotificationDigest

    public init(digest: NotificationDigest) {
        self.digest = digest
    }
}
