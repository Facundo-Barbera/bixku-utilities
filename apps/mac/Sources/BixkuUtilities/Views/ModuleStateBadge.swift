import BixkuCore
import SwiftUI

/// Colored dot plus label for a module's lifecycle state.
struct ModuleStateBadge: View {
    let state: ModuleState

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .help(state.description)
    }

    private var title: String {
        switch state {
        case .registered: return "Not started"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .failed: return .red
        case .registered, .stopped: return .gray
        }
    }
}
