import BixkuCore
import BixkuDock

/// The Dock as the app registers it: the portable `DockModule` (engine,
/// classifiers, triage) plus the link that points the UI at the engine each time it
/// starts. The engine is recreated on every start, so the UI is re-attached then.
actor DockHostModule: BixkuModule {
    private let dock: DockModule
    private let viewModel: DockViewModel

    nonisolated let manifest: ModuleManifest

    init(dock: DockModule, viewModel: DockViewModel) {
        self.dock = dock
        self.viewModel = viewModel
        manifest = dock.manifest
    }

    func start(context: ModuleContext) async throws {
        try await dock.start(context: context)
        guard let engine = dock.engine else { return }
        await viewModel.start(provider: DockEngineState(engine: engine))
    }

    func stop() async {
        await viewModel.stop()
        await dock.stop()
    }
}

extension DockHostModule {
    /// The Dock module with its UI, ready for `KnownModules`.
    ///
    /// Pass the platform activity and notification sources (and LLM providers) through
    /// `dock`; without them the engine runs but only reacts to manual mode changes.
    @MainActor
    static func makeRegistration(dock: DockModule = DockModule()) -> ModuleRegistration {
        let viewModel = DockViewModel()
        return ModuleRegistration(
            module: DockHostModule(dock: dock, viewModel: viewModel),
            ui: DockModuleUIProvider(viewModel: viewModel)
        )
    }
}
