import BixkuCore

/// The Dock module as the host sees it: manifest and lifecycle. The engine lives in
/// the portable `BixkuDock` package and reaches the UI through `DockStateProviding`;
/// starting or stopping the module starts or stops the UI's observation of it.
actor DockModule: BixkuModule {
    static let id: ModuleID = "online.bixku.dock"
    static let panelViewID = "panel"

    private static let manifestValue = ModuleManifest(
        id: id,
        displayName: "Dock",
        summary: "Focus modes that follow what you are doing and hold back distracting notifications.",
        version: "0.1.0",
        capabilities: [.menuBar],
        ui: [
            ModuleUIDescriptor(viewID: panelViewID, title: "Dock", systemImage: "dock.rectangle", kind: .menuBarPanel),
        ]
    )

    nonisolated var manifest: ModuleManifest {
        Self.manifestValue
    }

    private let viewModel: DockViewModel

    init(viewModel: DockViewModel) {
        self.viewModel = viewModel
    }

    func start(context: ModuleContext) async throws {
        await viewModel.start()
        context.logger.info("Dock module started")
    }

    func stop() async {
        await viewModel.stop()
    }
}

extension DockModule {
    /// The Dock module with its UI, ready for `KnownModules`.
    ///
    /// The UI reads from `PreviewDockState` (sample data) until the Dock engine is
    /// connected: swap `provider` for the engine adapter, nothing else changes.
    @MainActor
    static func makeRegistration(provider: any DockStateProviding = PreviewDockState()) -> ModuleRegistration {
        let viewModel = DockViewModel(provider: provider)
        return ModuleRegistration(
            module: DockModule(viewModel: viewModel),
            ui: DockModuleUIProvider(viewModel: viewModel)
        )
    }
}
