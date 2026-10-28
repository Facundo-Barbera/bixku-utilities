import Foundation

/// Something a module does that the host may surface or gate (open set of strings).
public struct ModuleCapability: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Observes the frontmost app / window.
    public static let activityMonitoring: ModuleCapability = "activity-monitoring"
    /// Reads or reacts to user notifications.
    public static let notificationProcessing: ModuleCapability = "notification-processing"
    /// Calls a language model.
    public static let languageModel: ModuleCapability = "language-model"
    /// Performs network requests.
    public static let network: ModuleCapability = "network"
    /// Contributes UI to the menu bar.
    public static let menuBar: ModuleCapability = "menu-bar"
    /// Publishes events other modules may consume.
    public static let eventProducer: ModuleCapability = "event-producer"
}

/// An OS permission a module needs. The host requests/explains them; modules never
/// prompt on their own. The mapping to macOS APIs lives in `apps/mac`.
public struct ModulePermission: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// macOS Accessibility (AX) — read focused window titles, control other apps.
    public static let accessibility: ModulePermission = "accessibility"
    /// Post user notifications.
    public static let notifications: ModulePermission = "notifications"
    /// Screen Recording — needed to read window titles of other apps on recent macOS.
    public static let screenRecording: ModulePermission = "screen-recording"
    /// Apple Events automation of other apps.
    public static let automation: ModulePermission = "automation"
    /// Outgoing network connections (e.g. LLM provider).
    public static let network: ModulePermission = "network"
}

/// Static description of a module: identity, version, what it does and what it needs.
public struct ModuleManifest: Sendable, Codable, Equatable {
    public var id: ModuleID
    public var displayName: String
    public var summary: String
    public var version: SemanticVersion
    public var capabilities: Set<ModuleCapability>
    public var permissions: Set<ModulePermission>
    /// Modules that must be running before this one starts (and stopped after it).
    public var dependencies: [ModuleID]
    /// Views the module contributes; rendered by the host's UI providers.
    public var ui: [ModuleUIDescriptor]
    /// Table under `[modules.<configKey>]` in the config file. Defaults to the id's slug.
    public var configKey: String

    public init(
        id: ModuleID,
        displayName: String,
        summary: String,
        version: SemanticVersion,
        capabilities: Set<ModuleCapability> = [],
        permissions: Set<ModulePermission> = [],
        dependencies: [ModuleID] = [],
        ui: [ModuleUIDescriptor] = [],
        configKey: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.version = version
        self.capabilities = capabilities
        self.permissions = permissions
        self.dependencies = dependencies
        self.ui = ui
        self.configKey = configKey ?? id.slug
    }
}

/// Where a module view is shown by the host.
public enum ModuleUIKind: String, Sendable, Codable, CaseIterable {
    /// A section inside the menu-bar extra's panel.
    case menuBarPanel = "menu-bar-panel"
    /// A standalone window.
    case window
    /// A pane in the app's settings window.
    case settings
}

/// Platform-neutral description of a view a module contributes.
///
/// The core never references SwiftUI; the macOS app maps `viewID` to a concrete view
/// through the module's `ModuleUIProvider`.
public struct ModuleUIDescriptor: Hashable, Sendable, Codable {
    /// Identifier of the view, unique within the module (e.g. `"panel"`, `"settings"`).
    public var viewID: String
    public var title: String
    /// SF Symbol name (ignored on platforms without SF Symbols).
    public var systemImage: String
    public var kind: ModuleUIKind

    public init(viewID: String, title: String, systemImage: String, kind: ModuleUIKind) {
        self.viewID = viewID
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
    }
}
