import AppKit
import SwiftUI

/// The floating panel at the bottom of the screen with the pointer. It never becomes key
/// or main and lets clicks through, so the app the user is in keeps the focus and gets
/// the paste. AppKit, because a SwiftUI window would take the focus.
///
/// While it shows the idle bar, it watches where the pointer moves, since a panel that
/// lets clicks through gets no mouse events, and tells the feedback when the pointer is
/// over the bar. Moving the pointer is all it watches, never a click or a key.
final class RecordingIndicatorPanel {
    /// The feedback whose display the panel shows. RecordingFeedback.live sets it.
    weak var feedback: RecordingFeedback?
    private var panel: NSPanel?
    private var pointerMonitors: [Any] = []
    private var screenObserver: (any NSObjectProtocol)?

    /// Builds the panel without showing it, at launch, so the first hold does not wait for
    /// a window to be made.
    func prepare() {
        if panel == nil {
            _ = makePanel()
        }
    }

    func present(_ display: RecordingFeedback.Display?) {
        guard display != nil else {
            watchPointer(false)
            panel?.orderOut(nil)
            return
        }
        guard let panel = panel ?? makePanel() else { return }
        // The idle bar sits just below the Dock, so a Dock that hides and shows covers it,
        // while the indicator stays above everything.
        panel.level = display == .idle ? Self.idleLevel : .statusBar
        place(panel)
        panel.orderFrontRegardless()
        watchPointer(display == .idle)
    }

    /// Just below the Dock, and above every app window, also in full screen.
    static let idleLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    /// Where the pointer counts as over the idle bar, in screen coordinates: the bar with
    /// a margin, so it is easy to find.
    static func idleBarArea(inPanelAt frame: NSRect) -> NSRect {
        let bar = RecordingIndicatorView.idleBarSize
        return NSRect(
            x: frame.midX - bar.width / 2 - 12,
            y: frame.minY + RecordingIndicatorView.bottomPadding - 10,
            width: bar.width + 24,
            height: bar.height + 20
        )
    }

    private func watchPointer(_ on: Bool) {
        guard on else {
            for monitor in pointerMonitors {
                NSEvent.removeMonitor(monitor)
            }
            pointerMonitors = []
            if feedback?.pointerIsOverIdleBar == true {
                feedback?.pointerIsOverIdleBar = false
            }
            return
        }
        let moved: () -> Void = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let pointer = NSEvent.mouseLocation
            // The bar follows the pointer to another display.
            if !NSMouseInRect(pointer, panel.screen?.frame ?? .zero, false),
               NSScreen.screens.contains(where: { NSMouseInRect(pointer, $0.frame, false) }) {
                self.place(panel)
            }
            let over = Self.idleBarArea(inPanelAt: panel.frame).contains(pointer)
            if self.feedback?.pointerIsOverIdleBar != over {
                self.feedback?.pointerIsOverIdleBar = over
            }
        }
        // The pointer may rest on the bar already, as after a dictation.
        moved()
        guard pointerMonitors.isEmpty else { return }
        // Another app's windows get the moves, and Orra's own windows, such as Settings.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in moved() }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            moved()
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NSPanel? {
        guard let feedback else { return nil }
        let panel = NonactivatingPanel(
            contentRect: NSRect(origin: .zero, size: RecordingIndicatorView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // On every Space, over full screen apps too, and never in the window cycle.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView(feedback: feedback))
        self.panel = panel
        // A display added or removed, or the Dock moved: the bar stays at the bottom.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.place(panel)
            }
        }
        return panel
    }

    /// Bottom center of the screen with the pointer, above the Dock.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 8))
    }
}

/// A panel that never becomes key or main, so showing it leaves the focus where it is.
final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The indicator, drawn at the bottom of a clear panel: a level meter while Orra listens,
/// a spinner while it transcribes, or a message.
struct RecordingIndicatorView: View {
    static let panelSize = CGSize(width: 520, height: 150)
    static let idleBarSize = CGSize(width: 40, height: 6)
    /// Room for the shadow below the indicator, and where the idle bar sits.
    static let bottomPadding: CGFloat = 16
    let feedback: RecordingFeedback

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .padding(.bottom, Self.bottomPadding)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch feedback.presented {
        case .listening:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                LevelMeterBars(level: feedback.level)
            }
            .indicatorStyle()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Listening")
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
            }
            .indicatorStyle()
        case .message(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                // Already in the user's language, so shown as it is.
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 440)
            .indicatorStyle()
        case .idle:
            VStack(spacing: 10) {
                if feedback.pointerIsOverIdleBar {
                    // Already in the user's language.
                    Text(verbatim: feedback.holdHint())
                        .indicatorStyle()
                        .transition(.opacity)
                }
                IdleBar()
            }
            .animation(.easeOut(duration: 0.15), value: feedback.pointerIsOverIdleBar)
        case nil:
            EmptyView()
        }
    }
}

/// The small bar that shows Orra is ready: dark with a light edge, so it shows on light
/// and dark backgrounds alike.
private struct IdleBar: View {
    var body: some View {
        Capsule()
            .fill(.black.opacity(0.45))
            .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
            .frame(width: RecordingIndicatorView.idleBarSize.width, height: RecordingIndicatorView.idleBarSize.height)
            .accessibilityElement()
            .accessibilityLabel("Orra is ready")
    }
}

/// Five bars that grow with the level, highest in the middle.
private struct LevelMeterBars: View {
    let level: Double
    private static let weights = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 4, height: 6 + 14 * level * Self.weights[index])
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// The dark, blurred background of a heads up display, as NSVisualEffectView draws it.
private struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private extension View {
    func indicatorStyle() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                HUDBackground()
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            )
    }
}
