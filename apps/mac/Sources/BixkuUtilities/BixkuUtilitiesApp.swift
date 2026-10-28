import SwiftUI
import BixkuCore

@main
struct BixkuUtilitiesApp: App {
    var body: some Scene {
        MenuBarExtra("Bixku Utilities", systemImage: "square.grid.2x2") {
            Text("Bixku Utilities \(BixkuCore.version)")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("Bixku Utilities", id: "main") {
            Text("Bixku Utilities")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
