import Foundation

/// Outcome of ``ModuleRegistry/startAll()``.
public struct StartReport: Sendable, Equatable {
    /// Modules running after the call, in start order (includes ones already running).
    public var running: [ModuleID] = []
    /// Modules that failed to start (directly or because a dependency is down).
    public var failures: [ModuleID: String] = [:]

    public var isSuccess: Bool {
        failures.isEmpty
    }
}

/// Owns the registered modules and drives their lifecycle.
///
/// - Validates ids and rejects duplicates on ``register(_:)``.
/// - Computes a deterministic start order from declared dependencies
///   (``startupOrder()``), rejecting missing dependencies and cycles.
/// - Starts modules in dependency order and stops them in reverse order.
/// - Tracks each module's ``ModuleState`` and publishes every transition as a
///   ``ModuleStateChanged`` event on the environment's bus.
///
/// Lifecycle operations (`start*`, `stop*`, `unregister`) are serialized: a call
/// waits for the previous one to finish, so concurrent callers never interleave
/// half-started modules.
public actor ModuleRegistry {
    private struct Entry {
        let module: any BixkuModule
        var state: ModuleState
    }

    public nonisolated let environment: ModuleEnvironment

    private var registrationOrder: [ModuleID] = []
    private var entries: [ModuleID: Entry] = [:]
    private var lifecycleTail: Task<Void, Never>?

    public init(environment: ModuleEnvironment = ModuleEnvironment()) {
        self.environment = environment
    }

    // MARK: Registration

    /// Adds a module in the `registered` state. Dependencies may be registered later;
    /// they are resolved when starting.
    public func register(_ module: any BixkuModule) throws {
        let manifest = module.manifest
        guard manifest.id.isValid else { throw ModuleError.invalidModuleID(manifest.id.rawValue) }
        for dependency in manifest.dependencies where !dependency.isValid {
            throw ModuleError.invalidModuleID(dependency.rawValue)
        }
        guard entries[manifest.id] == nil else { throw ModuleError.duplicateModule(manifest.id) }
        entries[manifest.id] = Entry(module: module, state: .registered)
        registrationOrder.append(manifest.id)
        publishState(.registered, for: manifest.id)
    }

    /// Stops (if needed) and removes a module. Fails if another registered module
    /// depends on it.
    public func unregister(_ id: ModuleID) async throws {
        try await serialized { registry in
            try await registry.unregisterNow(id)
        }
    }

    private func unregisterNow(_ id: ModuleID) async throws {
        guard let entry = entries[id] else { throw ModuleError.unknownModule(id) }
        let dependents = registrationOrder.filter { entries[$0]?.module.manifest.dependencies.contains(id) == true }
        guard dependents.isEmpty else { throw ModuleError.hasDependents(module: id, dependents: dependents) }
        if entry.state.isActive {
            await stopNow(id)
        }
        entries[id] = nil
        registrationOrder.removeAll { $0 == id }
    }

    // MARK: Queries

    /// Registered ids, in registration order.
    public var moduleIDs: [ModuleID] {
        registrationOrder
    }

    /// Manifests of registered modules, in registration order.
    public var manifests: [ModuleManifest] {
        registrationOrder.compactMap { entries[$0]?.module.manifest }
    }

    public func module(_ id: ModuleID) -> (any BixkuModule)? {
        entries[id]?.module
    }

    public func module<Module: BixkuModule>(_ id: ModuleID, as type: Module.Type) -> Module? {
        entries[id]?.module as? Module
    }

    public func state(of id: ModuleID) -> ModuleState? {
        entries[id]?.state
    }

    public var states: [ModuleID: ModuleState] {
        entries.mapValues(\.state)
    }

    /// Every lifecycle transition from now on (all modules).
    public nonisolated func stateChanges(
        buffering: StreamBuffering = .unbounded
    ) -> AsyncStream<EventEnvelope<ModuleStateChanged>> {
        environment.eventBus.subscribe(to: ModuleStateChanged.self, buffering: buffering)
    }

    // MARK: Dependency graph

    /// Topological order of all registered modules: dependencies first; ties broken
    /// by registration order so the result is deterministic.
    ///
    /// - Throws: ``ModuleError/missingDependency(module:dependency:)`` or
    ///   ``ModuleError/dependencyCycle(_:)``.
    public func startupOrder() throws -> [ModuleID] {
        try Self.topologicalOrder(of: registrationOrder) { self.dependencies(of: $0) }
    }

    /// Throws if the dependency graph is not startable.
    public func validate() throws {
        _ = try startupOrder()
    }

    private func dependencies(of id: ModuleID) -> [ModuleID] {
        var seen = Set<ModuleID>()
        return (entries[id]?.module.manifest.dependencies ?? []).filter { seen.insert($0).inserted }
    }

    static func topologicalOrder(
        of nodes: [ModuleID],
        dependencies: (ModuleID) -> [ModuleID]
    ) throws -> [ModuleID] {
        let known = Set(nodes)
        for node in nodes {
            for dependency in dependencies(node) where !known.contains(dependency) {
                throw ModuleError.missingDependency(module: node, dependency: dependency)
            }
        }
        var placed = Set<ModuleID>()
        var order: [ModuleID] = []
        order.reserveCapacity(nodes.count)
        while order.count < nodes.count {
            guard let next = nodes.first(where: { node in
                !placed.contains(node) && dependencies(node).allSatisfy { placed.contains($0) }
            }) else {
                let remaining = nodes.filter { !placed.contains($0) }
                throw ModuleError.dependencyCycle(findCycle(in: remaining, dependencies: dependencies))
            }
            placed.insert(next)
            order.append(next)
        }
        return order
    }

    /// Returns one cycle among `nodes` as `[a, b, …, a]`. Every node in `nodes` is
    /// on a cycle or depends on one, so a depth-first walk always finds one.
    private static func findCycle(in nodes: [ModuleID], dependencies: (ModuleID) -> [ModuleID]) -> [ModuleID] {
        let candidates = Set(nodes)
        var finished = Set<ModuleID>()

        func visit(_ node: ModuleID, path: inout [ModuleID]) -> [ModuleID]? {
            if let index = path.firstIndex(of: node) {
                return Array(path[index...]) + [node]
            }
            guard !finished.contains(node) else { return nil }
            path.append(node)
            for dependency in dependencies(node) where candidates.contains(dependency) {
                if let cycle = visit(dependency, path: &path) { return cycle }
            }
            path.removeLast()
            finished.insert(node)
            return nil
        }

        for node in nodes {
            var path: [ModuleID] = []
            if let cycle = visit(node, path: &path) { return cycle }
        }
        return nodes
    }

    /// `id` plus everything it (transitively) depends on, in start order.
    private func dependencyClosure(of id: ModuleID) throws -> [ModuleID] {
        var needed = Set<ModuleID>()
        var stack = [id]
        while let next = stack.popLast() {
            guard needed.insert(next).inserted else { continue }
            guard entries[next] != nil else {
                throw ModuleError.missingDependency(module: id, dependency: next)
            }
            stack.append(contentsOf: dependencies(of: next))
        }
        return try Self.topologicalOrder(of: registrationOrder.filter(needed.contains)) { self.dependencies(of: $0) }
    }

    /// Everything that (transitively) depends on `id`, excluding `id`.
    private func dependents(of id: ModuleID) -> Set<ModuleID> {
        var result = Set<ModuleID>()
        var frontier = [id]
        while let current = frontier.popLast() {
            for candidate in registrationOrder where !result.contains(candidate) {
                if dependencies(of: candidate).contains(current) {
                    result.insert(candidate)
                    frontier.append(candidate)
                }
            }
        }
        result.remove(id)
        return result
    }

    // MARK: Lifecycle

    /// Starts every registered module in dependency order.
    ///
    /// A module whose start throws is marked `failed`; modules depending on it are
    /// marked `failed` without being started. Other modules still start.
    ///
    /// - Throws: only graph errors (missing dependency, cycle), before starting anything.
    @discardableResult
    public func startAll() async throws -> StartReport {
        try await serialized { registry in
            try await registry.startAllNow()
        }
    }

    private func startAllNow() async throws -> StartReport {
        let order = try startupOrder()
        var report = StartReport()
        for id in order {
            if let down = dependencies(of: id).first(where: { entries[$0]?.state.isRunning != true }) {
                let reason = ModuleError.dependencyNotRunning(module: id, dependency: down).description
                setState(.failed(reason: reason), for: id)
                report.failures[id] = reason
                continue
            }
            do {
                try await startNow(id)
                report.running.append(id)
            } catch {
                report.failures[id] = Self.reason(for: error)
            }
        }
        return report
    }

    /// Stops every running module, dependents before their dependencies.
    public func stopAll() async {
        await serialized { registry in
            await registry.stopAllNow()
        }
    }

    private func stopAllNow() async {
        let order = (try? startupOrder()) ?? registrationOrder
        for id in order.reversed() where entries[id]?.state.isActive == true {
            await stopNow(id)
        }
    }

    /// Starts `id`, first starting whatever it depends on.
    public func start(_ id: ModuleID) async throws {
        try await serialized { registry in
            try await registry.startWithDependencies(id)
        }
    }

    private func startWithDependencies(_ id: ModuleID) async throws {
        guard entries[id] != nil else { throw ModuleError.unknownModule(id) }
        for module in try dependencyClosure(of: id) {
            try await startNow(module)
        }
    }

    /// Stops `id`, first stopping every running module that depends on it.
    public func stop(_ id: ModuleID) async throws {
        try await serialized { registry in
            try await registry.stopWithDependents(id)
        }
    }

    private func stopWithDependents(_ id: ModuleID) async throws {
        guard entries[id] != nil else { throw ModuleError.unknownModule(id) }
        let dependents = dependents(of: id)
        let order = (try? startupOrder()) ?? registrationOrder
        for module in order.reversed() where dependents.contains(module) && entries[module]?.state.isActive == true {
            await stopNow(module)
        }
        await stopNow(id)
    }

    /// Starts a single module whose dependencies are already running. No-op if running.
    private func startNow(_ id: ModuleID) async throws {
        guard let entry = entries[id] else { throw ModuleError.unknownModule(id) }
        if entry.state.isRunning { return }
        let manifest = entry.module.manifest
        for dependency in dependencies(of: id) where entries[dependency]?.state.isRunning != true {
            let error = ModuleError.dependencyNotRunning(module: id, dependency: dependency)
            setState(.failed(reason: error.description), for: id)
            throw error
        }
        setState(.starting, for: id)
        do {
            let context = try environment.makeContext(for: manifest)
            try await entry.module.start(context: context)
            setState(.running, for: id)
        } catch {
            let reason = Self.reason(for: error)
            setState(.failed(reason: reason), for: id)
            throw ModuleError.startFailed(module: id, reason: reason)
        }
    }

    /// Stops a single module if it is active. Never throws: `stop()` is best-effort.
    private func stopNow(_ id: ModuleID) async {
        guard let entry = entries[id], entry.state.isActive else { return }
        setState(.stopping, for: id)
        await entry.module.stop()
        setState(.stopped, for: id)
    }

    // MARK: Helpers

    private func setState(_ state: ModuleState, for id: ModuleID) {
        guard entries[id] != nil else { return }
        entries[id]?.state = state
        publishState(state, for: id)
    }

    private func publishState(_ state: ModuleState, for id: ModuleID) {
        environment.eventBus.publish(ModuleStateChanged(moduleID: id, state: state), source: nil)
    }

    private static func reason(for error: Error) -> String {
        if case ModuleError.startFailed(_, let reason) = error { return reason }
        return String(describing: error)
    }

    /// Runs `operation` after every previously enqueued lifecycle operation.
    private func serialized<Result: Sendable>(
        _ operation: @escaping @Sendable (isolated ModuleRegistry) async throws -> Result
    ) async throws -> Result {
        let previous = lifecycleTail
        let task = Task<Result, Error> {
            await previous?.value
            return try await operation(self)
        }
        lifecycleTail = Task {
            _ = await task.result
        }
        return try await task.value
    }

    private func serialized(_ operation: @escaping @Sendable (isolated ModuleRegistry) async -> Void) async {
        let previous = lifecycleTail
        let task = Task<Void, Never> {
            await previous?.value
            await operation(self)
        }
        lifecycleTail = task
        await task.value
    }
}
