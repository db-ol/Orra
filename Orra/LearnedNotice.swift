import AppKit
import Observation
import SwiftUI

/// The word Orra just learned on its own, shown for a while with Undo and a countdown to when
/// it goes, or a word it offers to add after a fix of one Chinese character, in a field the
/// user may edit. Stays while the pointer is over it, or while the user edits the word. An
/// offered word that is closed or runs out is declined.
@Observable
final class LearnedNotice {
    static let duration: Duration = .seconds(10)
    /// An offered word asks the user to read and decide, so it stays longer.
    static let suggestionDuration: Duration = .seconds(15)
    /// How long it stays after the pointer leaves it, or after the user stops editing.
    static let afterHover: Duration = .seconds(4)

    enum Content: Equatable {
        case learned(CorrectionLearning.Learned)
        case suggestion(WordSuggestion)
    }

    /// When the notice goes and how long that countdown is in all, for the ring. Nil while
    /// the pointer or the user's editing holds it.
    struct Countdown: Equatable {
        let hidesAt: Date
        let seconds: TimeInterval
    }

    private(set) var content: Content?
    private(set) var countdown: Countdown?
    /// The offered word as the user edits it.
    var draft = ""

    var learned: CorrectionLearning.Learned? {
        if case .learned(let learned) = content { learned } else { nil }
    }

    var suggestion: WordSuggestion? {
        if case .suggestion(let suggestion) = content { suggestion } else { nil }
    }

    @ObservationIgnored var onChange: ((Content?) -> Void)?
    /// Called when an offered word is closed or runs out without being added.
    @ObservationIgnored var onDecline: ((WordSuggestion) -> Void)?
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var hide: Task<Void, Never>?
    @ObservationIgnored private var pointerInside = false
    @ObservationIgnored private var editing = false

    init(
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.sleep = sleep
        self.now = now
    }

    /// Shows the word, in place of one shown before, and hides it after `duration`.
    func show(_ learned: CorrectionLearning.Learned) {
        present(.learned(learned), for: Self.duration)
    }

    /// Offers the word, in place of a notice shown before, with the guess in the field.
    func suggest(_ suggestion: WordSuggestion) {
        draft = suggestion.guess
        present(.suggestion(suggestion), for: Self.suggestionDuration)
    }

    private func present(_ content: Content, for duration: Duration) {
        self.content = content
        pointerInside = false
        editing = false
        onChange?(content)
        hide(after: duration)
    }

    /// Keeps the notice while the pointer is over it.
    func hold() {
        pointerInside = true
        pause()
    }

    /// The pointer left: hides it a little later, unless the user is editing the word.
    func release() {
        pointerInside = false
        resume()
    }

    /// The user started or stopped editing the offered word. Keeps it while editing.
    func setEditing(_ isEditing: Bool) {
        editing = isEditing
        if isEditing {
            pause()
        } else {
            resume()
        }
    }

    private func pause() {
        hide?.cancel()
        hide = nil
        countdown = nil
    }

    private func resume() {
        guard content != nil, !pointerInside, !editing else { return }
        hide(after: Self.afterHover)
    }

    private func hide(after duration: Duration) {
        hide?.cancel()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        countdown = Countdown(hidesAt: now().addingTimeInterval(seconds), seconds: seconds)
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

    /// Closes the notice. An offered word that was not added is declined.
    func close() {
        let declined = suggestion
        finish()
        if let declined {
            onDecline?(declined)
        }
    }

    /// Closes the notice after the user answered it, with Undo or Add.
    func finish() {
        hide?.cancel()
        hide = nil
        countdown = nil
        pointerInside = false
        editing = false
        guard content != nil else { return }
        content = nil
        onChange?(nil)
    }
}

/// A panel that never becomes main, and becomes key only while it offers a word and only
/// when the user clicks into its field, so the app the user is in keeps the focus otherwise.
final class NoticePanel: NSPanel {
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// The floating panel with the notice, above the recording indicator. Showing it never takes
/// the focus. It takes clicks, for Undo, Add and Close, and the keyboard only after a click
/// into the offered word's field. Then the focus goes back to the app the user was in once
/// the notice closes.
final class LearnedNoticePanel {
    let notice: LearnedNotice
    private let undo: (CorrectionLearning.Learned) -> Void
    private let add: (WordSuggestion, String) -> Void
    private var panel: NoticePanel?
    /// The app in front when the notice appeared, given the focus back after typing.
    private var previousApp: NSRunningApplication?

    init(
        notice: LearnedNotice,
        undo: @escaping (CorrectionLearning.Learned) -> Void,
        add: @escaping (WordSuggestion, String) -> Void = { _, _ in },
        decline: @escaping (WordSuggestion) -> Void = { _ in }
    ) {
        self.notice = notice
        self.undo = undo
        self.add = add
        notice.onChange = { [weak self] content in
            self?.present(content)
        }
        notice.onDecline = decline
    }

    func show(_ learned: CorrectionLearning.Learned) {
        notice.show(learned)
    }

    func suggest(_ suggestion: WordSuggestion) {
        notice.suggest(suggestion)
    }

    private func present(_ content: LearnedNotice.Content?) {
        let wasKey = panel?.isKeyWindow ?? false
        guard let content else {
            panel?.acceptsKeyboard = false
            panel?.orderOut(nil)
            if wasKey { giveFocusBack() }
            return
        }
        let panel = panel ?? makePanel()
        if !wasKey {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        if case .suggestion = content {
            panel.acceptsKeyboard = true
        } else {
            panel.acceptsKeyboard = false
            if wasKey {
                panel.resignKey()
                giveFocusBack()
            }
        }
        // A new view for each word, so the panel is sized to it right away.
        let undo = undo
        let add = add
        let view = FirstClickHostingView(rootView: LearnedNoticeView(
            notice: notice,
            undo: { [notice] learned in
                undo(learned)
                notice.finish()
            },
            add: { [notice] suggestion, text in
                add(suggestion, text)
                notice.finish()
            }
        ))
        view.onHover = { [notice] inside in
            if inside {
                notice.hold()
            } else {
                notice.release()
            }
        }
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        place(panel)
        panel.orderFrontRegardless()
    }

    /// Orra never activates itself for the notice, so the app the user was in normally
    /// still has the focus. Should Orra have become active, it hands activation back.
    private func giveFocusBack() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate()
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NoticePanel {
        let panel = NoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // A click on a button leaves the focus alone. Only a click into the field makes
        // the panel key.
        panel.becomesKeyOnlyIfNeeded = true
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
    @Bindable var notice: LearnedNotice
    let undo: (CorrectionLearning.Learned) -> Void
    let add: (WordSuggestion, String) -> Void
    @FocusState private var editing: Bool

    var body: some View {
        if let content = notice.content {
            Group {
                switch content {
                case .learned(let learned):
                    learnedView(learned)
                case .suggestion(let suggestion):
                    suggestionView(suggestion)
                }
            }
            .indicatorStyle()
            // Room for the shadow.
            .padding(12)
            .environment(\.colorScheme, .dark)
        }
    }

    private func learnedView(_ learned: CorrectionLearning.Learned) -> some View {
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
            CountdownRing(countdown: notice.countdown)
            closeButton
        }
    }

    private func suggestionView(_ suggestion: WordSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a word to your vocabulary?")
                Text("Changed “\(suggestion.change.heard)” to “\(suggestion.change.corrected)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            TextField("Word", text: $notice.draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .focused($editing)
                .onSubmit(addDraft)
                .onExitCommand { notice.close() }
                .onChange(of: editing) { _, isEditing in
                    notice.setEditing(isEditing)
                }
            Button("Add", action: addDraft)
                .disabled(notice.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            CountdownRing(countdown: notice.countdown)
            closeButton
        }
    }

    private func addDraft() {
        guard let suggestion = notice.suggestion,
              !notice.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(suggestion, notice.draft)
    }

    private var closeButton: some View {
        Button {
            notice.close()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Close")
    }
}

/// The seconds until the notice goes, in a ring that empties, or a pause sign while the
/// pointer or the user's editing holds the notice.
private struct CountdownRing: View {
    let countdown: LearnedNotice.Countdown?

    var body: some View {
        Group {
            if let countdown {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let left = max(0, countdown.hidesAt.timeIntervalSince(context.date))
                    ring(fraction: countdown.seconds > 0 ? left / countdown.seconds : 0) {
                        Text(verbatim: "\(Int(left.rounded(.up)))")
                            .font(.caption2.monospacedDigit())
                    }
                    .accessibilityLabel(Text("Closes in \(Int(left.rounded(.up))) seconds"))
                }
            } else {
                ring(fraction: 1) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 7))
                }
                .accessibilityLabel(Text("Stays while the pointer is over it"))
            }
        }
        .frame(width: 20, height: 20)
    }

    private func ring(fraction: Double, @ViewBuilder label: () -> some View) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label()
                .foregroundStyle(.secondary)
        }
    }
}
