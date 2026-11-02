import AppKit
import SwiftUI

/// The floating caption window: always on top, on every Space and over full screen apps,
/// translucent, and moved by dragging anywhere on it. Closing it turns captions off.
/// macOS remembers where it was and its size.
final class CaptionWindow: NSObject, NSWindowDelegate {
    static let defaultSize = CGSize(width: 520, height: 260)
    static let minimumSize = CGSize(width: 300, height: 140)

    private let captions: MeetingCaptions
    private let pushToTalk: PushToTalkController
    private let cleanup: TextCleanup
    private let turns: EngineTurns
    private var panel: NSPanel?

    init(captions: MeetingCaptions, pushToTalk: PushToTalkController, cleanup: TextCleanup, turns: EngineTurns) {
        self.captions = captions
        self.pushToTalk = pushToTalk
        self.cleanup = cleanup
        self.turns = turns
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Without taking the focus from the call.
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = String(localized: "Live Captions")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // On every Space, over full screen apps too.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = Self.minimumSize
        panel.delegate = self
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        let content = NSHostingView(rootView: CaptionView(captions: captions, pushToTalk: pushToTalk, cleanup: cleanup, turns: turns))
        content.translatesAutoresizingMaskIntoConstraints = false
        // Only the minimum size. With the default, the scroll view's growing content sets
        // the window's height, and the user could not make it shorter.
        content.sizingOptions = [.minSize]
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        if !panel.setFrameUsingName(Self.frameName) {
            place(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static let frameName = "MeetingCaptions"

    /// The first time: bottom center of the main screen, above where the recording
    /// indicator shows.
    private func place(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.defaultSize.width / 2, y: visible.minY + 140))
    }

    func windowWillClose(_ notification: Notification) {
        captions.setOn(false)
    }
}

/// The captions, newest at the bottom, with what is in the way above them, and what
/// captions listen to, the display mode, the caption target and Copy at the top. While
/// captions listen to the microphone, a line under the top row says so.
struct CaptionView: View {
    @Bindable var captions: MeetingCaptions
    let pushToTalk: PushToTalkController
    @Bindable var cleanup: TextCleanup
    /// Whether a dictation holds the captions, see EngineTurns.
    let turns: EngineTurns

    /// What onScrollGeometryChange reports to CaptionFollow.
    private struct ScrollGeometry: Equatable {
        let offset: Double
        let contentHeight: Double
        let viewportHeight: Double
    }

    /// Where the list is scrolled to, so the follow logic can move it to the bottom.
    @State private var position = ScrollPosition(edge: .bottom)
    /// True while the scroll view reports the user scrolling.
    @State private var userScrolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // What captions listen to by name and three segments while they fit. In a
            // narrower window the source shows as its icon, then the modes as a menu, and
            // last the caption target as its icon.
            ViewThatFits(in: .horizontal) {
                topRow(sourceTitle: true, segmented: true, targetTitle: true)
                topRow(sourceTitle: false, segmented: true, targetTitle: true)
                topRow(sourceTitle: false, segmented: false, targetTitle: true)
                topRow(sourceTitle: false, segmented: false, targetTitle: false)
            }
            // Also while a dictation pauses the captions, since the microphone stays on.
            if let input = captions.microphoneInUse {
                MicrophoneSign(input: input)
            }
            CaptionNotes(captions: captions, pushToTalk: pushToTalk, cleanup: cleanup, turns: turns)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Says where captions come from, since a test with one's own voice
                    // gives none of what the Mac plays. The note that nothing plays says
                    // the same, so the placeholder hides while that note shows.
                    if captions.store.sentences.isEmpty, captions.silence != .noAudio {
                        Group {
                            if captions.source == .microphone {
                                Text("Captions of what you say into the microphone appear here.")
                            } else {
                                Text("Captions of what the Mac plays, such as a call or a video, appear here. To caption what you say, choose Microphone in the menu at the top left of the window.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    ForEach(captions.store.shown) { sentence in
                        CaptionSentenceView(lines: captions.displayMode.lines(for: sentence))
                            .id(sentence.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                userScrolls = phase == .interacting || phase == .decelerating
            }
            // Every change of the content or the window comes through here, after layout,
            // so the move down sees the new height. Moving down from onChange of the
            // sentences ran before layout and stopped at the old bottom.
            .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                ScrollGeometry(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height)
            } action: { _, geometry in
                if captions.follow.update(offset: geometry.offset, contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight, userScrolls: userScrolls) {
                    position.scrollTo(edge: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !captions.follow.isFollowing, !captions.store.sentences.isEmpty {
                    Button("Jump to Latest") {
                        captions.follow.jumpToLatest()
                        position.scrollTo(edge: .bottom)
                    }
                    .controlSize(.small)
                    .padding(6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(minWidth: CaptionWindow.minimumSize.width, minHeight: CaptionWindow.minimumSize.height)
        .alert("Download the model for translation?", isPresented: $cleanup.isConfirmingCaptionDownload) {
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: cleanup.models.manifest.totalBytes)) {
                cleanup.confirmCaptionDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }

    /// The top row: what captions listen to and what they show at the left, the caption
    /// target and Copy at the right.
    private func topRow(sourceTitle: Bool, segmented: Bool, targetTitle: Bool) -> some View {
        HStack(spacing: 8) {
            CaptionSourceMenu(captions: captions, showsTitle: sourceTitle)
            if segmented {
                CaptionModePicker(captions: captions)
                    .pickerStyle(.segmented)
            } else {
                CaptionModePicker(captions: captions)
                    .pickerStyle(.menu)
            }
            Spacer(minLength: 0)
            CaptionTargetMenu(captions: captions, cleanup: cleanup, showsTitle: targetTitle)
            CaptionCopyButton(captions: captions)
        }
    }
}

/// What captions listen to: what the Mac plays or the microphone, as in Settings. The
/// choice's name shows beside its icon where the row has room, and the icon alone
/// otherwise.
private struct CaptionSourceMenu: View {
    let captions: MeetingCaptions
    let showsTitle: Bool

    var body: some View {
        Menu {
            Picker("Captions listen to", selection: Binding(get: { captions.source }, set: { captions.setSource($0) })) {
                ForEach(CaptionSource.allCases, id: \.self) { source in
                    Label(source.title, systemImage: source.systemImage)
                        .tag(source)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            let label = Label {
                Text(verbatim: captions.source.title)
            } icon: {
                Image(systemName: captions.source.systemImage)
            }
            if showsTitle {
                label.labelStyle(.titleAndIcon)
            } else {
                label.labelStyle(.iconOnly)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help(Text("Captions listen to"))
        .accessibilityLabel(Text("Captions listen to"))
        .accessibilityValue(Text(verbatim: captions.source.title))
    }
}

/// The sign that captions listen to the microphone, with its name, under the top row. Plain
/// text, so VoiceOver reads it, next to the orange dot macOS shows in the menu bar.
private struct MicrophoneSign: View {
    let input: AudioInput

    var body: some View {
        Label {
            Text("Microphone on: \(input.name)")
        } icon: {
            Image(systemName: "mic.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// What the window shows of each sentence: Original, Translated or Both, as in Settings.
private struct CaptionModePicker: View {
    let captions: MeetingCaptions

    var body: some View {
        Picker("Show", selection: Binding(get: { captions.displayMode }, set: { captions.setDisplayMode($0) })) {
            ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                CaptionModeChoice(mode: mode)
                    .tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The language captions translate into, as on the Meeting Interpretation page, with the
/// choice checked. Off in Original, which does not translate. Its name shows beside its
/// icon unless the window is narrow.
private struct CaptionTargetMenu: View {
    let captions: MeetingCaptions
    let cleanup: TextCleanup
    let showsTitle: Bool

    var body: some View {
        // A target saved for another dictation language shows as the one it acts as.
        let target = cleanup.effectiveCaptionTarget
        Menu {
            Picker("Translate captions into", selection: Binding(get: { target }, set: { cleanup.pickCaptionTarget($0) })) {
                ForEach(CaptionTarget.choices(for: cleanup.dictationLanguage), id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            let label = Label {
                Text(target.title)
            } icon: {
                Image(systemName: "translate")
            }
            if showsTitle {
                label.labelStyle(.titleAndIcon)
            } else {
                label.labelStyle(.iconOnly)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help(Text("Translate captions into"))
        .accessibilityLabel(Text("Translate captions into"))
        .accessibilityValue(Text(target.title))
        .disabled(!captions.displayMode.translates)
    }
}

/// Copy at the top right. A click copies every final sentence the way the window shows
/// it, and the arrow opens a menu for the originals, the translations or both. After a
/// copy the icon shows a checkmark for a moment and VoiceOver hears "Copied".
private struct CaptionCopyButton: View {
    let captions: MeetingCaptions

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Menu {
            Button("Copy Original Text") {
                copy(.original)
            }
            Button("Copy Translation") {
                copy(.translation)
            }
            .disabled(!captions.store.hasTranslation)
            Button("Copy Original and Translation") {
                copy(.originalAndTranslation)
            }
            if captions.store.droppedOldest {
                Divider()
                Text("Orra keeps the last \(captions.store.limit) sentences.")
            }
        } label: {
            Label("Copy All Captions", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
        } primaryAction: {
            copy(nil)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Copy All Captions")
        .disabled(!captions.store.hasFinalSentences)
    }

    /// Nil copies the way the window shows the sentences.
    private func copy(_ content: CaptionTranscript.Content?) {
        guard captions.copy(captions.store.transcript, as: content) else { return }
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

/// One sentence: the main line large, the original small above it.
private struct CaptionSentenceView: View {
    let lines: [CaptionDisplayMode.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line.style {
                case .main:
                    Text(verbatim: line.text)
                        .font(.title3)
                case .secondary:
                    Text(verbatim: line.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Why captions are not complete yet: the capture, the speech model, a dictation, the
/// local model. Internal for tests.
struct CaptionNotes: View {
    let captions: MeetingCaptions
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup
    let turns: EngineTurns

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.lines(captions: captions, speechReady: pushToTalk.modelState == .ready, turns: turns), id: \.self) { line in
                plainNote(line)
            }
            // The prompt while access is not decided, and the microphone pane of System
            // Settings while it is off, as in the welcome window.
            if case .microphoneUnavailable(.access(let access)) = captions.capture {
                switch access {
                case .notDetermined:
                    Button("Allow Microphone Access…") {
                        pushToTalk.requestMicrophoneAccess()
                    }
                    .controlSize(.small)
                case .denied:
                    Button("Open Microphone Settings…") {
                        pushToTalk.requestMicrophoneAccess()
                    }
                    .controlSize(.small)
                case .authorized, .notConfigured:
                    EmptyView()
                }
            }
            // No translation notes or download until the capture runs. While it starts,
            // captions do not need the model yet, and a download agreed to then would be
            // ignored. None in Original only, which does not translate.
            if captions.capture == .listening, captions.displayMode.translates {
                translationNote
            }
        }
    }

    /// The notes above those of the local model, in order: the capture, the speech model,
    /// and a dictation that holds the captions.
    static func lines(captions: MeetingCaptions, speechReady: Bool, turns: EngineTurns) -> [String] {
        var lines: [String] = []
        switch captions.capture {
        case .unavailable(.notConfigured):
            lines.append(String(localized: "This build of Orra cannot capture the sound the Mac plays yet."))
        case .unavailable(.failed):
            lines.append(String(localized: "Orra could not capture the sound the Mac plays. Turn Live Captions off and on again to try again."))
        case .microphoneUnavailable(.access(.notDetermined)):
            lines.append(String(localized: "The microphone needs permission"))
        case .microphoneUnavailable(.access(.denied)):
            lines.append(String(localized: "Microphone access is off. Turn on Orra under Microphone in System Settings."))
        case .microphoneUnavailable(.access(.notConfigured)):
            lines.append(String(localized: "This build has no microphone usage description"))
        case .microphoneUnavailable(.noInput):
            lines.append(String(localized: "No microphone is connected. Captions start once you connect one."))
        case .microphoneUnavailable(.access(.authorized)), .microphoneUnavailable(.failed):
            lines.append(String(localized: "Orra could not start the microphone. Turn Live Captions off and on again to try again."))
        case .off, .starting, .listening:
            switch captions.silence {
            case .noAudio:
                lines.append(String(localized: "Nothing is playing on the Mac. Captions show what the Mac plays, such as a call or a video. To caption what you say, choose Microphone in the menu at the top left of the window."))
            case .noSound:
                lines.append(String(localized: "No sound from the Mac yet. If something is playing, allow Orra under Screen & System Audio Recording in Privacy & Security settings."))
            case .microphoneSilent(let situation):
                lines.append(Silence.advice(for: situation))
            case nil:
                break
            }
        }
        if !speechReady || captions.speechModelMissing {
            lines.append(String(localized: "The speech model is not ready. Captions start once it is loaded."))
        }
        // From the press of a key until the paste, captions start no model call, see
        // EngineTurns. Said once the dictation has gone on for a moment, so a tap of the
        // talk key does not flash it. Not for a capture that failed, which has nothing to
        // catch up on. What the Mac plays waits and catches up, and what the microphone
        // hears meanwhile is left out, see MeetingCaptions.MicrophonePause.
        if turns.dictationNoteDue, captions.capture == .starting || captions.capture == .listening {
            if captions.source == .microphone {
                lines.append(String(localized: "Captions pause while you dictate and go on when you finish."))
            } else {
                lines.append(String(localized: "Captions wait while you dictate and catch up when you finish."))
            }
        }
        return lines
    }

    @ViewBuilder
    private var translationNote: some View {
        let total = cleanup.models.manifest.totalBytes
        switch cleanup.models.state {
        case .installed:
            switch cleanup.engineState {
            case .loading:
                plainNote(CleanupLabels.loading(.translation))
            case .failed:
                plainNote(CleanupLabels.failedToLoad(.translation))
            case .unloaded, .ready, .unloadedWhileIdle:
                EmptyView()
            }
        case .missing:
            plainNote(String(localized: "The local model is not on this Mac yet. Until it is, captions show what was said without translation."))
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: total)) {
                cleanup.isConfirmingCaptionDownload = true
            }
            .controlSize(.small)
        case .downloading(let bytes, _):
            plainNote(CleanupLabels.progress(bytes: bytes, total: total, use: .translation))
        case .failed:
            ForEach(cleanup.models.state.menuLines(total: total), id: \.self) { line in
                plainNote(line)
            }
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: total)) {
                cleanup.confirmCaptionDownload()
            }
            .controlSize(.small)
        case .checking, .verifying:
            EmptyView()
        }
    }

    private func plainNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension CaptionSource {
    /// The name of the choice, the same in the window and in Settings, where the row's
    /// label "Captions listen to" supplies the verb.
    var title: String {
        switch self {
        case .systemAudio: String(localized: "What the Mac Plays")
        case .microphone: String(localized: "Microphone")
        }
    }

    var systemImage: String {
        switch self {
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic.fill"
        }
    }
}

extension CaptionDisplayMode {
    /// The name in the picker, the same in the window and in Settings, where the row's
    /// label "Captions show" supplies the verb.
    var title: LocalizedStringKey {
        switch self {
        case .originalOnly: "Original"
        case .translationOnly: "Translated"
        case .originalAndTranslation: "Both"
        }
    }

    /// The help of the choice. Original only says that it does not translate.
    var help: LocalizedStringKey? {
        switch self {
        case .originalOnly: "Shows what was said, without translating it."
        case .translationOnly, .originalAndTranslation: nil
        }
    }
}

/// One choice of a display mode picker, with its help when it has one. In the window and
/// in Settings.
struct CaptionModeChoice: View {
    let mode: CaptionDisplayMode

    var body: some View {
        if let help = mode.help {
            Text(mode.title)
                .help(Text(help))
        } else {
            Text(mode.title)
        }
    }
}
