import BixkuCore
import SwiftUI

/// SwiftUI views of the Hello module.
@MainActor
struct HelloModuleUI: ModuleUIProvider {
    let module: HelloModule

    var moduleID: ModuleID {
        HelloModule.id
    }

    func makeView(for descriptor: ModuleUIDescriptor, context: ModuleUIContext) -> AnyView? {
        switch descriptor.viewID {
        case HelloModule.panelViewID:
            return AnyView(HelloPanelView(module: module))
        case HelloModule.settingsViewID:
            guard let settings = context.settings else { return nil }
            return AnyView(HelloSettingsView(settings: settings))
        default:
            return nil
        }
    }
}

private struct HelloPanelView: View {
    let module: HelloModule

    @State private var message = "Say hello to try the module system."
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Say hello") {
                isWorking = true
                Task { @MainActor in
                    do {
                        message = try await module.greet()
                    } catch {
                        message = "Error: \(error)"
                    }
                    isWorking = false
                }
            }
            .disabled(isWorking)
        }
    }
}

private struct HelloSettingsView: View {
    let settings: any SettingsStore

    @State private var name = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name to greet", text: $name)
                .onSubmit(save)
            HStack {
                Button("Save", action: save)
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let stored = try? await settings.value(forKey: HelloModule.nameKey)
            name = stored?.stringValue ?? ""
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: ConfigValue? = trimmed.isEmpty ? nil : .string(trimmed)
        Task { @MainActor in
            do {
                try await settings.setValue(value, forKey: HelloModule.nameKey)
                status = "Saved"
            } catch {
                status = "Error: \(error)"
            }
        }
    }
}
