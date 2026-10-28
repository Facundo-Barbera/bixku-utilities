import Foundation

/// Errors raised by the module system.
public enum ModuleError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidModuleID(String)
    case duplicateModule(ModuleID)
    case unknownModule(ModuleID)
    case missingDependency(module: ModuleID, dependency: ModuleID)
    /// The ids along the cycle, first id repeated at the end (`[a, b, a]`).
    case dependencyCycle([ModuleID])
    case hasDependents(module: ModuleID, dependents: [ModuleID])
    case dependencyNotRunning(module: ModuleID, dependency: ModuleID)
    case startFailed(module: ModuleID, reason: String)

    public var description: String {
        switch self {
        case .invalidModuleID(let id):
            return "Invalid module id '\(id)' (expected lowercase reverse-DNS or slug, e.g. 'online.bixku.dock')"
        case .duplicateModule(let id):
            return "A module with id '\(id)' is already registered"
        case .unknownModule(let id):
            return "No module registered with id '\(id)'"
        case .missingDependency(let module, let dependency):
            return "Module '\(module)' depends on '\(dependency)', which is not registered"
        case .dependencyCycle(let ids):
            return "Dependency cycle: " + ids.map(\.rawValue).joined(separator: " → ")
        case .hasDependents(let module, let dependents):
            return "Module '\(module)' is required by: " + dependents.map(\.rawValue).joined(separator: ", ")
        case .dependencyNotRunning(let module, let dependency):
            return "Module '\(module)' cannot start: dependency '\(dependency)' is not running"
        case .startFailed(let module, let reason):
            return "Module '\(module)' failed to start: \(reason)"
        }
    }
}
