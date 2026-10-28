import Foundation

/// In-process publish/subscribe bus shared by all modules.
///
/// - Publishing is synchronous and never blocks (call it from any context).
/// - Each subscription is an `AsyncStream`; events published by one task arrive in
///   publish order. Slow subscribers drop the oldest undelivered events once their
///   buffer (``defaultBufferSize`` by default) is full.
/// - Cancelling the consuming task (or dropping the stream) unsubscribes.
/// - Only events published after `subscribe` returns are delivered (no replay).
public final class EventBus: Sendable {
    public static let defaultBufferSize = 256

    private let broadcaster = Broadcaster<BixkuEvent>()
    private let clock: any BixkuClock

    public init(clock: any BixkuClock = SystemClock()) {
        self.clock = clock
    }

    /// Publishes a typed payload.
    @discardableResult
    public func publish<Payload: BixkuEventPayload>(_ payload: Payload, source: ModuleID? = nil) -> BixkuEvent {
        let event = BixkuEvent(source: source, timestamp: clock.now(), payload: payload)
        publish(event)
        return event
    }

    /// Publishes a pre-built event (e.g. replayed from a log).
    public func publish(_ event: BixkuEvent) {
        broadcaster.broadcast(event)
    }

    /// Subscribes to every event whose payload is `Payload`.
    public func subscribe<Payload: BixkuEventPayload>(
        to type: Payload.Type,
        buffering: StreamBuffering = .newest(EventBus.defaultBufferSize)
    ) -> AsyncStream<EventEnvelope<Payload>> {
        broadcaster.subscribe(buffering: buffering) { event in
            event.name == Payload.eventName ? EventEnvelope<Payload>(event) : nil
        }
    }

    /// Subscribes to untyped events matching `filter`.
    public func subscribe(
        _ filter: EventFilter = .all,
        buffering: StreamBuffering = .newest(EventBus.defaultBufferSize)
    ) -> AsyncStream<BixkuEvent> {
        broadcaster.subscribe(buffering: buffering) { event in
            filter.matches(event.name) ? event : nil
        }
    }

    /// Number of live subscriptions.
    public var subscriberCount: Int {
        broadcaster.subscriberCount
    }

    /// Ends every subscription. Later subscriptions end immediately and publishing
    /// becomes a no-op. Call on app shutdown.
    public func shutdown() {
        broadcaster.finish()
    }
}
