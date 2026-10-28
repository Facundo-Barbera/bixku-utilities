import Foundation

/// The contract every Bixku utility implements.
///
/// A module is a long-lived object owned by the ``ModuleRegistry``. It describes
/// itself through its ``manifest`` and is driven through ``start(context:)`` and
/// ``stop()``; its lifecycle ``ModuleState`` is tracked and published by the registry.
///
/// Rules:
/// - Never reach for globals (`UserDefaults.standard`, fixed paths, singletons):
///   everything a module needs comes from the ``ModuleContext`` passed to `start`.
/// - `start` should return once the module is operational and move long-running
///   work into tasks it owns; `stop` must cancel them.
/// - If `start` throws, the module must have released whatever it acquired: the
///   registry marks it `failed` and does not call `stop`.
/// - `start` may be called again after `stop` (restart).
///
/// Implementations are typically actors or `final class`es with internal locking.
public protocol BixkuModule: AnyObject, Sendable {
    /// Static description of the module. Must not change while registered.
    var manifest: ModuleManifest { get }

    /// Brings the module up. Dependencies declared in the manifest are running.
    func start(context: ModuleContext) async throws

    /// Tears the module down. Must be idempotent and must not throw.
    func stop() async
}

extension BixkuModule {
    public var id: ModuleID {
        manifest.id
    }

    public var displayName: String {
        manifest.displayName
    }

    public var summary: String {
        manifest.summary
    }
}
