import Foundation

/// Lifecycle state of a registered module, owned and published by ``ModuleRegistry``.
///
/// ```
/// registered ─start→ starting ─→ running ─stop→ stopping ─→ stopped ─start→ starting …
///                       └──(start threw / dependency down)──→ failed ─start→ starting …
/// ```
public enum ModuleState: Sendable, Equatable, Codable, CustomStringConvertible {
    case registered
    case starting
    case running
    case stopping
    case stopped
    case failed(reason: String)

    public var isRunning: Bool {
        self == .running
    }

    /// `true` while the module is starting, running or stopping.
    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping: return true
        case .registered, .stopped, .failed: return false
        }
    }

    public var description: String {
        switch self {
        case .registered: return "registered"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
