import AppKit
import Combine
import SwiftUI

/// Geometry of the floating dock. Sizes are fixed per item so the panel can be sized
/// without asking SwiftUI for its fitting size.
enum FloatingDockLayout {
    static let itemSize: CGFloat = 44
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12
    /// Gap between the dock and the bottom edge of the visible screen area.
    static let bottomMargin: CGFloat = 12

    /// Panel size for `appCount` app items plus the leading mode glyph.
    static func size(appCount: Int) -> CGSize {
        let items = CGFloat(appCount + 1)
        let width = padding * 2 + items * itemSize + (items - 1) * spacing
        return CGSize(width: width, height: padding * 2 + itemSize)
    }
}

/// An always-on-top panel that never takes focus, so clicking it does not pull the
/// user out of the app they are working in.
private final class FloatingDockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
    }
}

/// Shows the floating dock while the Dock module is running and the user has turned
/// the dock on (off by default). Its contents follow the active mode's priority apps.
@MainActor
final class FloatingDockController {
    private let viewModel: DockViewModel
    private var panel: FloatingDockPanel?
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: DockViewModel) {
        self.viewModel = viewModel

        Publishers.CombineLatest(viewModel.$isRunning, viewModel.$isFloatingDockEnabled)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                if visible {
                    self?.show()
                } else {
                    self?.hide()
                }
            }
            .store(in: &cancellables)

        viewModel.$priorityApps
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.resize(appCount: count)
            }
            .store(in: &cancellables)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(appCount: viewModel.priorityApps.count)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingDockPanel {
        let size = FloatingDockLayout.size(appCount: viewModel.priorityApps.count)
        let panel = FloatingDockPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: FloatingDockView(viewModel: viewModel))
        position(panel, size: size)
        return panel
    }

    /// Resizes the panel around its horizontal center, keeping it where the user left it.
    private func resize(appCount: Int) {
        guard let panel else { return }
        let size = FloatingDockLayout.size(appCount: appCount)
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Centers the panel at the bottom of the main screen's visible area.
    private func position(_ panel: NSPanel, size: CGSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + FloatingDockLayout.bottomMargin
        )
        panel.setFrameOrigin(origin)
    }
}

/// The contents of the floating dock: the active mode's glyph followed by its
/// priority apps. Clicking an app launches or activates it.
private struct FloatingDockView: View {
    @ObservedObject var viewModel: DockViewModel

    var body: some View {
        HStack(spacing: FloatingDockLayout.spacing) {
            Image(systemName: viewModel.activeMode?.symbol ?? "circle")
                .font(.title2)
                .frame(width: FloatingDockLayout.itemSize, height: FloatingDockLayout.itemSize)
                .help(viewModel.activeMode?.name ?? "Dock")
            ForEach(viewModel.priorityApps) { app in
                Button {
                    viewModel.open(app)
                } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: FloatingDockLayout.itemSize, height: FloatingDockLayout.itemSize)
                }
                .buttonStyle(.plain)
                .help(app.name)
            }
        }
        .padding(FloatingDockLayout.padding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}
