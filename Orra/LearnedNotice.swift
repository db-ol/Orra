import AppKit
import Observation
import SwiftUI

/// The word Orra just learned on its own, shown for a while with Undo. Stays while the
/// pointer is over it.
@Observable
final class LearnedNotice {
    static let duration: Duration = .seconds(15)
    /// How long it stays after the pointer leaves it.
    static let afterHover: Duration = .seconds(4)

    private(set) var learned: CorrectionLearning.Learned?

    @ObservationIgnored var onChange: ((CorrectionLearning.Learned?) -> Void)?
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var hide: Task<Void, Never>?

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Shows the word, in place of one shown before, and hides it after `duration`.
    func show(_ learned: CorrectionLearning.Learned) {
        self.learned = learned
        onChange?(learned)
        hide(after: Self.duration)
    }

    /// Keeps the notice while the pointer is over it.
    func hold() {
        hide?.cancel()
        hide = nil
    }

    /// The pointer left: hides it a little later.
    func release() {
        guard learned != nil else { return }
        hide(after: Self.afterHover)
    }

    private func hide(after duration: Duration) {
        hide?.cancel()
        hide = Task { [weak self, sleep] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        hide?.cancel()
        hide = nil
        guard learned != nil else { return }
        learned = nil
        onChange?(nil)
    }
}

/// The floating panel with the notice, above the recording indicator. Like the indicator,
/// it never becomes key or main, so the app the user is in keeps the focus. It takes clicks,
/// for Undo and Close.
final class LearnedNoticePanel {
    let notice: LearnedNotice
    private let undo: (CorrectionLearning.Learned) -> Void
    private var panel: NSPanel?

    init(notice: LearnedNotice, undo: @escaping (CorrectionLearning.Learned) -> Void) {
        self.notice = notice
        self.undo = undo
        notice.onChange = { [weak self] learned in
            self?.present(learned)
        }
    }

    func show(_ learned: CorrectionLearning.Learned) {
        notice.show(learned)
    }

    private func present(_ learned: CorrectionLearning.Learned?) {
        guard learned != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        // A new view for each word, so the panel is sized to it right away.
        let undo = undo
        let content = FirstClickHostingView(rootView: LearnedNoticeView(notice: notice) { [notice] learned in
            undo(learned)
            notice.close()
        })
        content.onHover = { [notice] inside in
            if inside {
                notice.hold()
            } else {
                notice.release()
            }
        }
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        place(panel)
        panel.orderFrontRegardless()
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NSPanel {
        let panel = NonactivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    /// Bottom center of the screen with the pointer, above the recording indicator.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 76))
    }
}

/// Takes the first click, so a button in a panel that is never key works with one click.
/// Also tells when the pointer enters and leaves, also while another app is active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover(false)
    }
}

struct LearnedNoticeView: View {
    let notice: LearnedNotice
    let undo: (CorrectionLearning.Learned) -> Void

    var body: some View {
        if let learned = notice.learned {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    switch learned.outcome {
                    case .added:
                        Text("Added “\(learned.correction.corrected)” to Vocabulary")
                    case .vocabularyFull:
                        Text("Vocabulary is full, so “\(learned.correction.corrected)” was not added")
                    }
                    Text("Heard as “\(learned.correction.heard)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                if learned.outcome == .added {
                    Button("Undo") {
                        undo(learned)
                    }
                }
                Button {
                    notice.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            }
            .indicatorStyle()
            // Room for the shadow.
            .padding(12)
            .environment(\.colorScheme, .dark)
        }
    }
}
