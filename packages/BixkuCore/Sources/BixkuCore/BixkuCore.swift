import Foundation

/// Core namespace for Bixku Utilities.
///
/// BixkuCore defines the module system shared by every utility: the ``BixkuModule``
/// contract, the ``ModuleRegistry`` that orders and drives module lifecycles, the
/// typed ``EventBus`` modules use to talk to each other, and per-module storage,
/// settings, configuration, logging and clock abstractions. It depends only on
/// Foundation and the Swift standard library so it builds and tests on Linux.
public enum BixkuCore {
    public static let version = "0.2.0"
}
