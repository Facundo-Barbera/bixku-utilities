import BixkuCore
import Foundation

extension EventName {
    /// A request for the Dock to do something (published by other modules).
    public static let dockCommand: EventName = "dock.command"
    /// The outcome of a ``DockCommand``.
    public static let dockCommandResult: EventName = "dock.command-result"
}

/// A request to the Dock, sent over the event bus so other modules (the mode agent)
/// never call into the Dock directly. The running ``DockModule`` executes it and
/// answers with a ``DockCommandResult`` carrying the same `id`.
public struct DockCommand: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .dockCommand

    public enum Action: Codable, Sendable, Equatable {
        /// Switch to a mode without pinning it (refused while the user's manual
        /// choice is in effect). See ``DockEngine/activateMode(_:reason:)``.
        case activateMode(ModeID, reason: String)
        /// Create or replace a user mode (validated; overrides a factory mode with the same id).
        case saveMode(ModeDefinition)
        /// Delete a user mode or override.
        case deleteMode(ModeID)
    }

    public var id: UUID
    public var action: Action

    public init(id: UUID = UUID(), _ action: Action) {
        self.id = id
        self.action = action
    }
}

/// Outcome of a ``DockCommand``.
public struct DockCommandResult: BixkuEventPayload, Equatable {
    public static let eventName: EventName = .dockCommandResult

    public var commandID: UUID
    public var succeeded: Bool
    /// Error description when the command failed (validation issues included).
    public var message: String?

    public init(commandID: UUID, succeeded: Bool, message: String? = nil) {
        self.commandID = commandID
        self.succeeded = succeeded
        self.message = message
    }
}
