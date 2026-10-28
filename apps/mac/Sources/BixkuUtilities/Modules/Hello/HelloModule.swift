import BixkuCore
import Foundation

/// Emitted by the Hello module every time it greets.
struct HelloGreeted: BixkuEventPayload, Equatable {
    static let eventName: EventName = "hello.greeted"

    var message: String
    var count: Int
}

/// Minimal example module that exercises the module system end to end: manifest,
/// lifecycle, persisted storage, settings, events and UI. It exists only to
/// demonstrate the host and will be replaced by the Dock module.
///
/// Real modules keep their logic in a portable package under `packages/`; this one
/// lives in the app because it has no logic worth testing.
actor HelloModule: BixkuModule {
    static let id: ModuleID = "online.bixku.hello"
    static let panelViewID = "panel"
    static let settingsViewID = "settings"
    static let nameKey = "name"
    private static let countKey = "greeting-count"

    private static let manifestValue = ModuleManifest(
        id: id,
        displayName: "Hello",
        summary: "Example module that demonstrates the module system.",
        version: "0.1.0",
        capabilities: [.menuBar, .eventProducer],
        ui: [
            ModuleUIDescriptor(viewID: panelViewID, title: "Hello", systemImage: "hand.wave", kind: .menuBarPanel),
            ModuleUIDescriptor(viewID: settingsViewID, title: "Greeting", systemImage: "hand.wave", kind: .settings),
        ]
    )

    nonisolated var manifest: ModuleManifest {
        Self.manifestValue
    }

    private var context: ModuleContext?
    private var greetingCount = 0

    func start(context: ModuleContext) async throws {
        greetingCount = try await context.storage.value(Int.self, forKey: Self.countKey) ?? 0
        self.context = context
        context.logger.info("Hello module started (\(greetingCount) greetings so far)")
    }

    func stop() async {
        context?.logger.info("Hello module stopped")
        context = nil
    }

    /// Builds a greeting for the configured name, persists the counter and
    /// publishes a `hello.greeted` event.
    func greet() async throws -> String {
        guard let context else { throw HelloModuleError.notRunning }
        greetingCount += 1
        let count = greetingCount
        try await context.storage.setValue(count, forKey: Self.countKey)
        let stored = try await context.settings.value(forKey: Self.nameKey)
        let name = stored?.stringValue ?? "world"
        let message = "Hello, \(name)! (#\(count))"
        context.publish(HelloGreeted(message: message, count: count))
        return message
    }
}

enum HelloModuleError: Error, CustomStringConvertible {
    case notRunning

    var description: String {
        switch self {
        case .notRunning: return "The Hello module is not running."
        }
    }
}
