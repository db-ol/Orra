import AppKit
import SwiftUI

/// The floating panel at the bottom of the screen with the pointer. It never becomes key
/// or main and lets clicks through, so the app the user is in keeps the focus and gets
/// the paste. AppKit, because a SwiftUI window would take the focus.
final class RecordingIndicatorPanel {
    /// The feedback whose display the panel shows. RecordingFeedback.live sets it.
    weak var feedback: RecordingFeedback?
    private var panel: NSPanel?

    /// Builds the panel without showing it, at launch, so the first hold does not wait for
    /// a window to be made.
    func prepare() {
        if panel == nil {
            _ = makePanel()
        }
    }

    func present(_ display: RecordingFeedback.Display?) {
        guard display != nil else {
            panel?.orderOut(nil)
            return
        }
        guard let panel = panel ?? makePanel() else { return }
        place(panel)
        panel.orderFrontRegardless()
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
    let feedback: RecordingFeedback

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                // Room for the shadow.
                .padding(.bottom, 16)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch feedback.display {
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
        case nil:
            EmptyView()
        }
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
struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
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
