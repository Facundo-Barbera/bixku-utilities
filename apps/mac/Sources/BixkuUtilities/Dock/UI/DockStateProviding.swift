import BixkuDock
import Foundation

/// What the user is doing right now, as shown by the Dock UI.
struct DockActivity: Sendable, Equatable {
    var appName: String?
    var windowTitle: String?
    var category: ActivityCategory
    /// How sure the classifier is, from 0 to 1.
    var confidence: Double
    var rationale: String
    var source: VerdictSource
    /// Whether the activity serves the active mode.
    var attention: AttentionLevel
    var isIdle: Bool

    init(
        appName: String?,
        windowTitle: String? = nil,
        category: ActivityCategory,
        confidence: Double,
        rationale: String = "",
        source: VerdictSource = .rules,
        attention: AttentionLevel = .neutral,
        isIdle: Bool = false
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.category = category
        self.confidence = min(1, max(0, confidence))
        self.rationale = rationale
        self.source = source
        self.attention = attention
        self.isIdle = isIdle
    }
}

/// Everything the Dock UI shows, captured at one instant. Immutable value so it can
/// cross actor boundaries and be diffed by SwiftUI.
struct DockSnapshot: Sendable, Equatable {
    /// Every available mode, in display order.
    var catalog: ModeCatalog
    var activeModeID: ModeID
    /// When the active mode started, if known.
    var modeStartedAt: Date?
    /// The user picked the active mode, so automatic transitions are suspended.
    var isManual: Bool
    /// The latest classified foreground activity, if any was observed yet.
    var activity: DockActivity?
    /// A mode the classifier thinks fits the current activity. Advisory only.
    var suggestedModeID: ModeID?
    /// Notifications held back (or queued for the digest) while the mode is active.
    var held: [TriagedNotification]

    init(
        catalog: ModeCatalog = .factory,
        activeModeID: ModeID = .free,
        modeStartedAt: Date? = nil,
        isManual: Bool = false,
        activity: DockActivity? = nil,
        suggestedModeID: ModeID? = nil,
        held: [TriagedNotification] = []
    ) {
        self.catalog = catalog
        self.activeModeID = activeModeID
        self.modeStartedAt = modeStartedAt
        self.isManual = isManual
        self.activity = activity
        self.suggestedModeID = suggestedModeID
        self.held = held
    }

    static let empty = DockSnapshot()

    var activeMode: Mode? {
        catalog.mode(activeModeID)
    }

    /// The suggested mode, only when it exists and differs from the active one.
    var suggestedMode: Mode? {
        guard let id = suggestedModeID, id != activeModeID else { return nil }
        return catalog.mode(id)
    }
}

/// Source of Dock state and sink of the user's actions.
///
/// The UI depends only on this protocol. The production implementation is
/// `DockEngineState`, an adapter over the `BixkuDock` engine; `PreviewDockState`
/// serves sample data for previews.
protocol DockStateProviding: Sendable {
    /// The state right now.
    func currentSnapshot() async -> DockSnapshot

    /// The current state followed by every later change. The stream ends when the
    /// consumer stops iterating.
    func snapshots() async -> AsyncStream<DockSnapshot>

    /// Switches the active mode manually.
    func selectMode(_ id: ModeID) async

    /// Hands control back to the automatic mode rules after a manual choice.
    func resumeAutomatic() async

    /// Delivers one held notification now.
    func releaseNotification(_ id: UUID) async

    /// Delivers everything held as a single digest.
    func deliverDigest() async
}
