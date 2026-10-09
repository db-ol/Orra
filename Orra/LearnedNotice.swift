import AppKit
import Observation
import SwiftUI

/// The word Orra just learned on its own, shown for a few seconds with Undo.
@Observable
final class LearnedNotice {
    static let duration: Duration = .seconds(8)

    private(set) var learned: CorrectionLearning.Learned?

    @ObservationIgnored var onChange: ((CorrectionLearning.Learned?) -> Void)?
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var hide: Task<Void, Never>?

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Shows the word, in place of one shown before, and hides it after `duration`.
    func show(_ learned: CorrectionLearning.Learned) {
        hide?.cancel()
        self.learned = learned
        onChange?(learned)
        hide = Task { [weak self, sleep] in
            do {
                try await sleep(Self.duration)
            } catch {
                return
            }
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
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
                    if learned.addedToVocabulary {
                        Text("Added “\(learned.correction.corrected)” to Vocabulary")
                    } else {
                        // Already in the vocabulary, or the vocabulary is full.
                        Text("Orra now writes “\(learned.correction.corrected)”")
                    }
                    Text("Heard as “\(learned.correction.heard)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Button("Undo") {
                    undo(learned)
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
