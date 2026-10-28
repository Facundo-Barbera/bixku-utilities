import BixkuCore
import SwiftUI

/// What a UI provider gets when asked for a view.
@MainActor
struct ModuleUIContext {
    let host: ModuleHost
    let moduleID: ModuleID
    /// The module's settings store (shared with the running module).
    let settings: (any SettingsStore)?
}

/// SwiftUI side of a module: turns the module's platform-neutral
/// `ModuleUIDescriptor`s into concrete views. Lives in the app because the
/// portable packages cannot depend on SwiftUI.
@MainActor
protocol ModuleUIProvider {
    var moduleID: ModuleID { get }

    /// The view for `descriptor`, or `nil` if the provider does not know `descriptor.viewID`.
    func makeView(for descriptor: ModuleUIDescriptor, context: ModuleUIContext) -> AnyView?
}

/// Identifies one view of one module (e.g. the window to show in the module window).
struct ModuleViewReference: Hashable, Codable {
    let moduleID: ModuleID
    let viewID: String
}

/// A module view the host can render, with enough context to label it.
struct ModuleViewItem: Identifiable {
    let moduleID: ModuleID
    let descriptor: ModuleUIDescriptor

    var reference: ModuleViewReference {
        ModuleViewReference(moduleID: moduleID, viewID: descriptor.viewID)
    }

    var id: String {
        "\(moduleID.rawValue)/\(descriptor.viewID)"
    }
}

/// A module plus its optional UI, as listed in `KnownModules`.
struct ModuleRegistration {
    let module: any BixkuModule
    let ui: (any ModuleUIProvider)?
}
