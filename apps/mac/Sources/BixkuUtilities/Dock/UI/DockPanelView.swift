import BixkuDock
import SwiftUI

/// The Dock section of the menu-bar panel: active mode, mode picker, current
/// activity and the notifications held back.
struct DockPanelView: View {
    @ObservedObject var viewModel: DockViewModel

    private static let maxVisibleNotifications = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActiveModeHeader(
                mode: viewModel.activeMode,
                since: viewModel.snapshot.modeStartedAt,
                isManual: viewModel.snapshot.isManual,
                onResumeAutomatic: viewModel.resumeAutomatic
            )
            ModePicker(viewModel: viewModel)
            if let suggested = viewModel.snapshot.suggestedMode {
                SuggestionRow(mode: suggested) {
                    viewModel.select(suggested.id)
                }
            }
            Divider()
            ActivitySection(activity: viewModel.snapshot.activity)
            Divider()
            NotificationsSection(
                held: viewModel.snapshot.held,
                maxVisible: Self.maxVisibleNotifications,
                onRelease: viewModel.release,
                onDeliverDigest: viewModel.deliverDigest
            )
            Divider()
            Toggle("Floating dock", isOn: $viewModel.isFloatingDockEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show an always-on-top dock with the active mode's priority apps.")
        }
    }
}

// MARK: - Mode

private struct ActiveModeHeader: View {
    let mode: Mode?
    let since: Date?
    let isManual: Bool
    let onResumeAutomatic: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: mode?.symbol ?? "circle")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode?.name ?? "No mode")
                        .font(.headline)
                    if let since {
                        Text(since, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isManual {
                        Button("Auto", action: onResumeAutomatic)
                            .controlSize(.mini)
                            .help("Chosen manually. Resume automatic mode switching.")
                    }
                }
                if let summary = mode?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ModePicker: View {
    @ObservedObject var viewModel: DockViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(viewModel.modes.enumerated()), id: \.element.id) { index, mode in
                ModeButton(
                    mode: mode,
                    isActive: mode.id == viewModel.snapshot.activeModeID,
                    shortcut: viewModel.shortcutKey(forModeAt: index)
                ) {
                    viewModel.select(mode.id)
                }
            }
        }
    }
}

private struct ModeButton: View {
    let mode: Mode
    let isActive: Bool
    let shortcut: KeyEquivalent?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: mode.symbol)
                Text(mode.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.map { "\(mode.summary) (⌘\($0.character))" } ?? mode.summary)
        .accessibilityAddTraits(isActive ? .isSelected : [])

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }
}

private struct SuggestionRow: View {
    let mode: Mode
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
            Text("Looks like \(mode.name) time")
                .font(.caption)
            Spacer()
            Button("Switch", action: onSwitch)
                .controlSize(.small)
        }
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    let activity: DockActivity?

    private static func statusText(for activity: DockActivity) -> String {
        if activity.isIdle { return "Idle" }
        switch activity.attention {
        case .focus: return "On task"
        case .neutral: return "Neutral"
        case .distraction: return "Distraction"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity")
                .font(.subheadline.weight(.semibold))
            if let activity {
                HStack {
                    Text(activity.appName ?? "Unknown app")
                        .lineLimit(1)
                    Spacer()
                    Text(activity.category.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                if let title = activity.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    ProgressView(value: activity.confidence)
                        .controlSize(.small)
                    Text("\(Int((activity.confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Classifier confidence (\(activity.source.rawValue))")
                Text(Self.statusText(for: activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !activity.rationale.isEmpty {
                    Text(activity.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No activity observed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsSection: View {
    let held: [TriagedNotification]
    let maxVisible: Int
    let onRelease: (UUID) -> Void
    let onDeliverDigest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(held.isEmpty ? "Notifications" : "Held notifications (\(held.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !held.isEmpty {
                    Button("Deliver digest", action: onDeliverDigest)
                        .controlSize(.small)
                }
            }
            if held.isEmpty {
                Text("Nothing is being held back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(held.prefix(maxVisible)) { item in
                HeldNotificationRow(item: item) {
                    onRelease(item.id)
                }
            }
            if held.count > maxVisible {
                Text("+ \(held.count - maxVisible) more in the digest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeldNotificationRow: View {
    let item: TriagedNotification
    let onRelease: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.notification.displayAppName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(item.notification.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRelease) {
                Image(systemName: "tray.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Release now: \(item.decision.reason)")
            .accessibilityLabel("Release notification")
        }
    }
}

// MARK: - Previews

struct DockPanelView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = DockViewModel(preferences: PreviewPreferences())
        DockPanelView(viewModel: viewModel)
            .padding(12)
            .frame(width: 320)
            .task { viewModel.start(provider: PreviewDockState()) }
    }

    private final class PreviewPreferences: DockPreferences {
        var floatingDockEnabled = false
    }
}
