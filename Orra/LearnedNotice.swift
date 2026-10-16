import AppKit
import Observation
import SwiftUI

/// The word Orra just learned on its own, shown for a while with Undo and a countdown to when
/// it goes, or a word it offers to add after a fix of one Chinese character, in a field the
/// user may edit. Stays while the pointer is over it, or while the user edits the word. An
/// offered word that is closed or runs out is declined. A notice that comes while a word is
/// offered, or an offer that comes while any notice is shown, waits and shows once the one
/// shown closes, so an offer is never lost unseen. A learned word replaces a learned word
/// shown or waiting, so only the latest Undo is kept.
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

    /// The most notices that wait. A further one pushes out the oldest.
    static let maximumWaiting = 5

    private(set) var content: Content?
    private(set) var countdown: Countdown?
    /// The notices waiting for the one shown to close, oldest first.
    private(set) var waiting: [Content] = []
    /// The offered word as the user edits it.
    var draft = ""

    var learned: CorrectionLearning.Learned? {
        if case .learned(let learned) = content { learned } else { nil }
    }

    var suggestion: WordSuggestion? {
        if case .suggestion(let suggestion) = content { suggestion } else { nil }
    }

    @ObservationIgnored var onChange: ((Content?) -> Void)?
    /// Called when the user undoes a word learned on its own, after the notice closed.
    @ObservationIgnored var onUndo: ((CorrectionLearning.Learned) -> Void)?
    /// Called when the user adds an offered word, maybe edited, after the notice closed.
    @ObservationIgnored var onAdd: ((WordSuggestion, String) -> Void)?
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

    /// Shows the word, in place of a learned word shown before, and hides it after
    /// `duration`. Waits while a word is offered.
    func show(_ learned: CorrectionLearning.Learned) {
        let content = Content.learned(learned)
        if suggestion != nil {
            waiting.removeAll { if case .learned = $0 { true } else { false } }
            enqueue(content)
        } else {
            present(content)
        }
    }

    /// Offers the word, with the guess in the field. Waits while another notice is shown.
    func suggest(_ suggestion: WordSuggestion) {
        let content = Content.suggestion(suggestion)
        guard content != self.content, !waiting.contains(content) else { return }
        if self.content != nil {
            enqueue(content)
        } else {
            present(content)
        }
    }

    private func enqueue(_ content: Content) {
        waiting.append(content)
        if waiting.count > Self.maximumWaiting {
            waiting.removeFirst()
        }
    }

    private func present(_ content: Content) {
        if case .suggestion(let suggestion) = content {
            draft = suggestion.guess
        }
        self.content = content
        pointerInside = false
        editing = false
        onChange?(content)
        switch content {
        case .learned: hide(after: Self.duration)
        case .suggestion: hide(after: Self.suggestionDuration)
        }
    }

    /// Shows the next waiting notice, when none is shown.
    private func showNext() {
        guard content == nil, !waiting.isEmpty else { return }
        present(waiting.removeFirst())
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
        clear()
        if let declined {
            onDecline?(declined)
        }
        showNext()
    }

    /// Undoes the word shown. The notice closes first, so a notice that undoing shows stays.
    func undo() {
        guard let learned else { return }
        clear()
        onUndo?(learned)
        showNext()
    }

    /// Adds the offered word as the user left it in the field. The notice closes first, so
    /// a notice that adding shows, such as a full vocabulary, stays.
    func add() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suggestion, !word.isEmpty else { return }
        clear()
        onAdd?(suggestion, word)
        showNext()
    }

    /// Closes the notice after the user answered it, with Undo or Add, and shows the next
    /// one waiting.
    func finish() {
        clear()
        showNext()
    }

    private func clear() {
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
/// into the offered word's field. The user edits the word while the panel is key. Then the
/// focus goes back to the app the user was in once the notice closes or changes.
final class LearnedNoticePanel {
    let notice: LearnedNotice
    private var panel: NoticePanel?
    private var keyObservers: [NSObjectProtocol] = []
    /// The app in front when the notice appeared, given the focus back after typing.
    private var previousApp: NSRunningApplication?

    init(
        notice: LearnedNotice,
        undo: @escaping (CorrectionLearning.Learned) -> Void,
        add: @escaping (WordSuggestion, String) -> Void = { _, _ in },
        decline: @escaping (WordSuggestion) -> Void = { _ in }
    ) {
        self.notice = notice
        notice.onChange = { [weak self] content in
            self?.present(content)
        }
        notice.onUndo = undo
        notice.onAdd = add
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
        if wasKey {
            // The new notice has no field with the focus. Ordering the panel out is what
            // gives up key status, and it comes back in front below without taking it.
            panel.acceptsKeyboard = false
            panel.orderOut(nil)
            giveFocusBack()
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        if case .suggestion = content {
            panel.acceptsKeyboard = true
        }
        // A new view for each word, so the panel is sized to it right away.
        let view = FirstClickHostingView(rootView: LearnedNoticeView(notice: notice))
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
        // The panel is key only while the user edits the offered word in its field, so its
        // key status holds the countdown. A click back into another app ends it, also when
        // the field keeps its focus inside the panel.
        let center = NotificationCenter.default
        keyObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: nil) { [notice] _ in
                MainActor.assumeIsolated { notice.setEditing(true) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [notice] _ in
                MainActor.assumeIsolated { notice.setEditing(false) }
            },
        ]
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
                    notice.undo()
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
                .onSubmit { notice.add() }
                .onExitCommand { notice.close() }
            Button("Add") {
                notice.add()
            }
                .disabled(notice.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            CountdownRing(countdown: notice.countdown)
            closeButton
        }
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
                .accessibilityLabel(Text("Paused"))
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
