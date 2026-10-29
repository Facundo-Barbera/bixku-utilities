import BixkuCore
import BixkuDock
import SwiftUI

/// SwiftUI side of the Dock module. It also owns the floating dock, so the panel
/// exists for as long as the module is registered (not only while the menu is open).
@MainActor
final class DockModuleUIProvider: ModuleUIProvider {
    /// `viewID` of the menu-bar panel in the Dock manifest.
    private static let panelViewID = "panel"
    /// `viewID` of the Agent window (see `DockHostModule.manifest`).
    static let agentViewID = "agent"

    private let viewModel: DockViewModel
    private let floatingDock: FloatingDockController
    private let agent: (any AgentControlling)?

    init(viewModel: DockViewModel, agent: (any AgentControlling)? = nil) {
        self.viewModel = viewModel
        self.agent = agent
        floatingDock = FloatingDockController(viewModel: viewModel)
    }

    var moduleID: ModuleID {
        DockModule.moduleID
    }

    func makeView(for descriptor: ModuleUIDescriptor, context: ModuleUIContext) -> AnyView? {
        switch descriptor.viewID {
        case Self.panelViewID:
            return AnyView(DockPanelView(viewModel: viewModel))
        case Self.agentViewID:
            return agent.map { AnyView(AgentTabView.make(agent: $0)) }
        default:
            return nil
        }
    }
}
