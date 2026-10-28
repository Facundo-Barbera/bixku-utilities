import BixkuCore
import BixkuDock
import SwiftUI

/// SwiftUI side of the Dock module. It also owns the floating dock, so the panel
/// exists for as long as the module is registered (not only while the menu is open).
@MainActor
final class DockModuleUIProvider: ModuleUIProvider {
    /// `viewID` of the menu-bar panel in the Dock manifest.
    private static let panelViewID = "panel"

    private let viewModel: DockViewModel
    private let floatingDock: FloatingDockController

    init(viewModel: DockViewModel) {
        self.viewModel = viewModel
        floatingDock = FloatingDockController(viewModel: viewModel)
    }

    var moduleID: ModuleID {
        DockModule.moduleID
    }

    func makeView(for descriptor: ModuleUIDescriptor, context: ModuleUIContext) -> AnyView? {
        switch descriptor.viewID {
        case Self.panelViewID:
            return AnyView(DockPanelView(viewModel: viewModel))
        default:
            return nil
        }
    }
}
