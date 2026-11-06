import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// The Transcribe File window, which Transcribe File… in the menu bar menu opens. AppKit,
/// like the Projects window, since an accessory app cannot open a SwiftUI window from
/// AppKit code, and for the open and save panels and the question before it closes.
///
/// The window holds the text of one file, see FileTranscription. Closing it stops the file
/// under way and lets go of the text, after asking while the text is not saved, so the next
/// open starts empty. Orra shows in the Dock while it is open, as for Settings, see DockIcon.
final class TranscribeFileWindow: NSObject, NSWindowDelegate {
    /// The size the window first opens at.
    static let defaultSize = CGSize(width: 560, height: 540)
    /// The smallest size, at which the buttons at the bottom still fit in each language.
    static let minimumSize = CGSize(width: 500, height: 360)
    /// The name its frame is kept under between launches.
    private static let frameName = "TranscribeFileWindow"

    /// The app's speech model and settings, made anew for each window.
    private let engines: () -> FileTranscriptionEngines
    /// What the window says while the speech model cannot take a file, nil once it can.
    private let speechModelLine: () -> String?
    /// Called before the window shows, see DockIcon.willShowWindow().
    private let willShow: () -> Void
    private var window: NSWindow?
    /// The text of the open window, nil while it is closed.
    private var transcription: FileTranscription?

    init(engines: @escaping () -> FileTranscriptionEngines, speechModelLine: @escaping () -> String?, willShow: @escaping () -> Void) {
        self.engines = engines
        self.speechModelLine = speechModelLine
        self.willShow = willShow
    }

    /// Brings the window to the front, as it was when it is open.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        willShow()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let transcription = FileTranscription(engines: engines())
        self.transcription = transcription
        let view = TranscribeFileView(
            transcription: transcription,
            speechModelLine: speechModelLine,
            chooseFile: { [weak self] in self?.chooseFile() },
            save: { [weak self] kind in self?.save(as: kind) },
            closeWindow: { [weak self] in self?.window?.close() }
        )
        let window = Self.window(hosting: view)
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        window.delegate = self
        return window
    }

    /// The window with `content` in it, at its first size and with its minimum size.
    /// `makeWindow()` adds the frame it keeps between launches and the delegate, which
    /// tests leave out.
    static func window(hosting content: some View) -> NSWindow {
        let controller = NSHostingController(rootView: content.frame(minWidth: minimumSize.width, minHeight: minimumSize.height))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Transcribe File")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.contentMinSize = minimumSize
        return window
    }

    /// The close button asks first while text is not saved or a file runs, see
    /// FileTranscription.windowShouldClose().
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        transcription?.windowShouldClose() ?? true
    }

    /// The text goes from memory with the window, and the next open builds a new one. The
    /// window is kept until the close is done, since it may not go away inside its own
    /// notification.
    func windowWillClose(_ notification: Notification) {
        transcription?.close()
        transcription = nil
        let closing = window
        window = nil
        DispatchQueue.main.async {
            withExtendedLifetime(closing) {}
        }
    }

    /// Choose File…: the open panel, for one audio or video file. The file it gives is the
    /// only one Transcribe File reads.
    private func chooseFile() {
        guard let window, let transcription else { return }
        let panel = Self.openPanel()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            transcription.choose(url)
        }
    }

    /// The open panel of Choose File…, for one audio or video file. It hands over a file in
    /// iCloud Drive that is not on this Mac yet instead of having macOS download it, which
    /// it does by default, so FileAudioSource refuses it as for a drop, see
    /// FileAudioProblem.notOnThisMac.
    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canDownloadUbiquitousContents = false
        return panel
    }

    /// Save as Text… and Save as Subtitles…: the save panel, starting with the file's name
    /// and the extension of `kind`. The file it gives is the only one Transcribe File writes.
    private func save(as kind: FileTranscript.Kind) {
        guard let window, let transcription else { return }
        let panel = NSSavePanel()
        // A subtitle file is text that macOS has no type of its own for.
        let type = UTType(filenameExtension: kind.pathExtension, conformingTo: .plainText) ?? .plainText
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = transcription.suggestedName(as: kind)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try transcription.save(as: kind, to: url)
            } catch {
                Logger.fileTranscription.error("Saving the text failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

/// What the Transcribe File window shows: the place to drop a file before there is one,
/// then the file with its progress, the segments with their start times, and the buttons
/// that copy and save the text.
struct TranscribeFileView: View {
    let transcription: FileTranscription
    /// What the window says while the speech model cannot take a file, nil once it can.
    let speechModelLine: () -> String?
    let chooseFile: () -> Void
    let save: (FileTranscript.Kind) -> Void
    /// Closes the window after the user agreed to discard its text.
    let closeWindow: () -> Void
    @State private var isTargeted = false
    /// Where the list of segments is scrolled to.
    @State private var scroll = ScrollPosition(edge: .top)
    /// Whether the list shows the newest segment as it comes, which the user ends by
    /// scrolling up and starts again by scrolling back to the end.
    @State private var followsNewest = true
    /// True while the user scrolls the list, which it then never scrolls itself.
    @State private var userScrolls = false

    var body: some View {
        let modelLine = speechModelLine()
        VStack(spacing: 0) {
            if let file = transcription.file {
                header(file, modelLine: modelLine)
                Divider()
                segmentList(file)
                Divider()
                footer
            } else {
                dropArea(modelLine: modelLine)
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Nothing is taken while the speech model cannot take a file.
            modelLine == nil && transcription.drop(urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(get: { transcription.pendingDiscard != nil }, set: { shown in
                if !shown {
                    transcription.keep()
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if transcription.discard() {
                    closeWindow()
                }
            }
            Button("Cancel", role: .cancel) {
                transcription.keep()
            }
        } message: {
            if transcription.isRunning {
                Text("Orra is still transcribing it. What is done so far is not saved.")
            } else {
                Text("It is not saved. Save it as text or subtitles to keep it.")
            }
        }
    }

    // MARK: Before a file

    private func dropArea(modelLine: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop an audio or video file here")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("Orra transcribes it on this Mac, with your dictation language and vocabulary.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose File…") {
                chooseFile()
            }
            .controlSize(.large)
            .disabled(modelLine != nil)
            if let line = modelLine ?? dropNote {
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.tertiary)
                .padding(16)
        }
    }

    // MARK: With a file

    private func header(_ file: FileTranscription.File, modelLine: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.duration > 0 {
                        Text(verbatim: Self.clock(file.duration, showingHours: file.duration >= 3_600))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // Stop while a file runs, and the next file once it is over. A file can also
                // be dropped on the window at any time.
                if transcription.isRunning {
                    Button("Stop") {
                        transcription.stop()
                    }
                } else {
                    Button("Choose File…") {
                        chooseFile()
                    }
                    .disabled(modelLine != nil)
                }
            }
            if transcription.isRunning, file.duration > 0 {
                ProgressView(value: min(transcription.doneSeconds, file.duration), total: file.duration)
                    .progressViewStyle(.linear)
            } else if transcription.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if let status = status(modelLine: modelLine) {
                Text(verbatim: status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dropNote {
                Text(verbatim: dropNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func segmentList(_ file: FileTranscription.File) -> some View {
        ScrollView {
            if transcription.segments.isEmpty {
                if transcription.isRunning {
                    Text("The text appears here as Orra transcribes the file.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                let showsHours = file.duration >= 3_600
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcription.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: Self.clock(segment.start, showingHours: showsHours))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: showsHours ? 56 : 40, alignment: .trailing)
                            Text(verbatim: segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(16)
            }
        }
        .scrollPosition($scroll)
        .onScrollPhaseChange { _, phase in
            userScrolls = phase == .tracking || phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: ListGeometry.self) { geometry in
            ListGeometry(contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height, showsEnd: geometry.visibleRect.maxY >= geometry.contentSize.height - 8)
        } action: { old, new in
            if new.contentHeight == old.contentHeight, new.visibleHeight == old.visibleHeight {
                // The list scrolled, up to read or back down to the end.
                followsNewest = new.showsEnd
            } else if !userScrolls, followsNewest || new.showsEnd {
                // A new segment, or another size of the window.
                followsNewest = true
                scroll.scrollTo(edge: .bottom)
            }
        }
    }

    /// How tall the list of segments is, how much of it shows, and whether its end shows.
    private struct ListGeometry: Equatable {
        var contentHeight: CGFloat
        var visibleHeight: CGFloat
        var showsEnd: Bool
    }

    /// Said after a drop of several files, until the next file.
    private var dropNote: String? {
        transcription.refusedSeveralFiles ? String(localized: "Drop one file at a time.") : nil
    }

    private var footer: some View {
        let canExport = !transcription.segments.isEmpty && !transcription.isRunning
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Copy") {
                ConcealedClipboard.copy(transcription.text, to: .general)
            }
            .disabled(!canExport)
            Button("Save as Text…") {
                save(.text)
            }
            .disabled(!canExport)
            Button("Save as Subtitles…") {
                save(.subtitles)
            }
            .disabled(!canExport)
        }
        .padding(12)
    }

    // MARK: Text

    private var discardTitle: String {
        let name = transcription.file?.name ?? ""
        return String(localized: "Discard the transcript of “\(name)”?")
    }

    /// The line under the progress: what the file waits for, the time left, or how it
    /// ended.
    private func status(modelLine: String?) -> String? {
        switch transcription.phase {
        case .idle:
            return nil
        case .opening:
            return String(localized: "Opening the file…")
        case .transcribing:
            if transcription.waitsForCaptions {
                return String(localized: "Waiting while Live Captions run. The file goes on once they are off.")
            }
            if transcription.waitsForDictation {
                return String(localized: "Waiting for your dictation to finish…")
            }
            if let secondsLeft = transcription.secondsLeft {
                return Self.timeLeft(secondsLeft)
            }
            return String(localized: "Transcribing…")
        case .finished:
            return Self.endLine(segments: transcription.segments.count, failedSegments: transcription.failedSegments)
        case .stopped:
            return String(localized: "Stopped. The text so far stays.")
        case .failed(.speechModel):
            return modelLine ?? String(localized: "The speech model is not loaded. Try again once it is.")
        case .failed(.file(let problem)):
            return Self.message(for: problem)
        }
    }

    /// What the window says once every segment is done: whether any text came, and
    /// whether the speech model failed on part of the file or on all of it.
    static func endLine(segments: Int, failedSegments: Int) -> String {
        switch (segments, failedSegments) {
        case (0, 0): String(localized: "No speech was found in this file.")
        case (0, _): String(localized: "Orra could not transcribe this file.")
        case (_, 0): String(localized: "Done")
        default: String(localized: "Part of this file could not be transcribed.")
        }
    }

    /// What the window says about a file it cannot read.
    static func message(for problem: FileAudioProblem) -> String {
        switch problem {
        case .unreadable:
            String(localized: "Orra cannot read this file. Choose an audio or video file.")
        case .noAudio:
            String(localized: "This file has no audio.")
        case .protected:
            String(localized: "This file is protected, so Orra cannot read its audio.")
        case .notOnThisMac:
            String(localized: "This file is not on this Mac yet. Download it in Finder first.")
        case .readFailed:
            String(localized: "Orra could not read the rest of this file. The text so far stays.")
        }
    }

    /// The time left, in whole minutes, rounded up, in Orra's language.
    static func timeLeft(_ seconds: Double, locale: Locale = .interface) -> String {
        guard seconds >= 60 else {
            return String(localized: LocalizedStringResource("Less than a minute left", locale: locale))
        }
        let minutes = Int((seconds / 60).rounded(.up))
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .wide).locale(locale)
        let time = Duration.seconds(minutes * 60).formatted(style)
        return String(localized: LocalizedStringResource("About \(time) left", locale: locale))
    }

    /// A time in the file as a clock shows it: 0:05, 12:34, or 1:02:03 with hours.
    static func clock(_ seconds: Double, showingHours: Bool) -> String {
        let duration = Duration.seconds(Int(max(seconds, 0)))
        return duration.formatted(.time(pattern: showingHours ? .hourMinuteSecond : .minuteSecond))
    }
}

extension TranscribeFileView {
    /// What the window says while the speech model cannot take a file: the download until
    /// the model is in place, then the load. Nil once it is loaded.
    static func speechModelLine(installer: ModelInstaller.State, model: PushToTalkController.ModelState) -> String? {
        switch installer {
        case .installed:
            switch model {
            case .ready: nil
            case .notLoaded, .loading: String(localized: "Loading the speech model…")
            case .unavailable(let problem): problem.message()
            }
        case .checking:
            String(localized: "Loading the speech model…")
        case .downloading, .verifying, .missing, .failed:
            String(localized: "Orra needs its speech model first. Download it from Orra’s menu in the menu bar.")
        }
    }
}
