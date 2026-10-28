import BixkuDock
import Foundation

/// Everything the Dock UI shows, captured at one instant. Immutable value so it can
/// cross actor boundaries and be diffed by SwiftUI.
struct DockSnapshot: Sendable, Equatable {
    /// Every available mode, in display order.
    var catalog: ModeCatalog
    var activeModeID: ModeID
    /// When the active mode started, if known.
    var modeStartedAt: Date?
    /// The latest classified foreground activity, if any was observed yet.
    var activity: ClassifiedActivity?
    /// A mode the classifier thinks fits the current activity. Advisory only.
    var suggestedModeID: ModeID?
    /// Notifications held back (or queued for the digest) while the mode is active.
    var held: [TriagedNotification]

    init(
        catalog: ModeCatalog = .factory,
        activeModeID: ModeID = .free,
        modeStartedAt: Date? = nil,
        activity: ClassifiedActivity? = nil,
        suggestedModeID: ModeID? = nil,
        held: [TriagedNotification] = []
    ) {
        self.catalog = catalog
        self.activeModeID = activeModeID
        self.modeStartedAt = modeStartedAt
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
/// The UI depends only on this protocol. The production implementation is an adapter
/// over the Dock engine of the `BixkuDock` package; `PreviewDockState` serves sample
/// data until the engine is wired in.
protocol DockStateProviding: Sendable {
    /// The state right now.
    func currentSnapshot() async -> DockSnapshot

    /// The current state followed by every later change. The stream ends when the
    /// consumer stops iterating.
    func snapshots() async -> AsyncStream<DockSnapshot>

    /// Switches the active mode manually.
    func selectMode(_ id: ModeID) async

    /// Delivers one held notification now.
    func releaseNotification(_ id: UUID) async

    /// Delivers everything held as a single digest.
    func deliverDigest() async
}
