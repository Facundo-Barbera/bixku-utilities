import Foundation

/// Dotted name of an event type: `<namespace>.<event>` (e.g. `activity.changed`).
public struct EventName: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// The part before the first dot (`activity.changed` → `activity`).
    public var namespace: String {
        rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rawValue
    }

    public var description: String {
        rawValue
    }
}

/// A typed event payload. Each payload type maps to exactly one ``EventName``.
///
/// Payloads are `Codable` so they can be logged, persisted or sent to an LLM.
public protocol BixkuEventPayload: Sendable, Codable {
    static var eventName: EventName { get }
}

extension BixkuEventPayload {
    /// JSON encoding of this payload (also usable through `any BixkuEventPayload`).
    public func encodedJSON(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(self)
    }
}

/// A published event: metadata plus a type-erased payload.
public struct BixkuEvent: Sendable, Identifiable {
    public let id: UUID
    public let name: EventName
    /// Module that published the event (`nil` for the host / registry).
    public let source: ModuleID?
    public let timestamp: Date
    public let payload: any BixkuEventPayload

    public init(id: UUID = UUID(), source: ModuleID?, timestamp: Date, payload: any BixkuEventPayload) {
        self.id = id
        self.name = type(of: payload).eventName
        self.source = source
        self.timestamp = timestamp
        self.payload = payload
    }

    /// The payload as `Payload`, or `nil` if it is of another type.
    public func payload<Payload: BixkuEventPayload>(as type: Payload.Type) -> Payload? {
        payload as? Payload
    }

    /// JSON encoding of the payload.
    public func encodedPayload(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try payload.encodedJSON(using: encoder)
    }
}

/// A received event with a statically typed payload.
public struct EventEnvelope<Payload: BixkuEventPayload>: Sendable, Identifiable {
    public let id: UUID
    public let source: ModuleID?
    public let timestamp: Date
    public let payload: Payload

    public init?(_ event: BixkuEvent) {
        guard let payload = event.payload(as: Payload.self) else { return nil }
        self.id = event.id
        self.source = event.source
        self.timestamp = event.timestamp
        self.payload = payload
    }
}

/// Which events an untyped subscription receives.
public enum EventFilter: Sendable, Equatable {
    case all
    case names(Set<EventName>)
    /// Every event whose name starts with `"<namespace>."`.
    case namespace(String)

    public func matches(_ name: EventName) -> Bool {
        switch self {
        case .all: return true
        case .names(let names): return names.contains(name)
        case .namespace(let namespace): return name.namespace == namespace
        }
    }
}
