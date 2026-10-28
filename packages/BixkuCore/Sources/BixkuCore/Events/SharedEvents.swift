import Foundation

// Event vocabulary shared across modules. Payloads live in the core so producers and
// consumers do not depend on each other's packages. Module-private events should be
// declared in the module's own package with the module's namespace.

extension EventName {
    /// The frontmost app or its focused window changed. Producer: Dock (`DockEngine`).
    public static let activityChanged: EventName = "activity.changed"
    /// A user notification was observed. Producer: Dock (`DockEngine`).
    public static let notificationReceived: EventName = "notification.received"
    /// The active focus mode changed. Producer: Dock (`DockEngine`).
    public static let modeChanged: EventName = "mode.changed"
    /// A module's lifecycle state changed. Producer: ``ModuleRegistry``.
    public static let moduleStateChanged: EventName = "module.state-changed"
}

/// The user's foreground activity changed.
public struct ActivityChanged: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .activityChanged

    /// Bundle identifier of the frontmost app, if known.
    public var appBundleID: String?
    public var appName: String
    /// Title of the focused window. May be `nil` (no permission, or redacted by privacy rules).
    public var windowTitle: String?
    /// Optional extra context (e.g. a document path or URL host), already privacy-filtered.
    public var detail: String?
    /// Activity category as classified by the producer (`code`, `writing`, …), if any.
    public var category: String?
    /// Producer's confidence in `category`, from 0 to 1.
    public var confidence: Double?

    public init(
        appBundleID: String?,
        appName: String,
        windowTitle: String? = nil,
        detail: String? = nil,
        category: String? = nil,
        confidence: Double? = nil
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.detail = detail
        self.category = category
        self.confidence = confidence
    }
}

/// A user notification was delivered by some app.
public struct NotificationReceived: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .notificationReceived

    public var appBundleID: String?
    public var appName: String?
    public var title: String
    public var subtitle: String?
    public var body: String?

    public init(appBundleID: String?, appName: String? = nil, title: String, subtitle: String? = nil, body: String? = nil) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// The active mode changed (e.g. `writing` → `building`).
public struct ModeChanged: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .modeChanged

    public var previousModeID: String?
    public var modeID: String
    /// Why it changed (`user`, `schedule`, `agent: …`), for display and audit.
    public var reason: String?

    public init(previousModeID: String?, modeID: String, reason: String? = nil) {
        self.previousModeID = previousModeID
        self.modeID = modeID
        self.reason = reason
    }
}

/// A module's lifecycle state changed.
public struct ModuleStateChanged: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .moduleStateChanged

    public var moduleID: ModuleID
    public var state: ModuleState

    public init(moduleID: ModuleID, state: ModuleState) {
        self.moduleID = moduleID
        self.state = state
    }
}
