import BixkuCore
import SwiftUI

/// SwiftUI side of the Dock module. It also owns the floating dock, so the panel
/// exists for as long as the module is registered (not only while the menu is open).
@MainActor
final class DockModuleUIProvider: ModuleUIProvider {
    private let viewModel: DockViewModel
    private let floatingDock: FloatingDockController

    init(viewModel: DockViewModel) {
        self.viewModel = viewModel
        floatingDock = FloatingDockController(viewModel: viewModel)
    }

    var moduleID: ModuleID {
        DockModule.id
    }

    func makeView(for descriptor: ModuleUIDescriptor, context: ModuleUIContext) -> AnyView? {
        switch descriptor.viewID {
        case DockModule.panelViewID:
            return AnyView(DockPanelView(viewModel: viewModel))
        default:
            return nil
        }
    }
}
