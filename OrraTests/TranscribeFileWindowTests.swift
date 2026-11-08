import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Orra

/// What the Transcribe File window says: the time left, times in the file, what the
/// speech model needs and why a file cannot be read.
@MainActor
struct TranscribeFileWindowTests {
    @Test func theWindowSaysTheTimeLeftInWholeMinutes() {
        let english = Locale(identifier: "en")
        #expect(TranscribeFileView.timeLeft(30, locale: english) == "Less than a minute left")
        #expect(TranscribeFileView.timeLeft(61, locale: english) == "About 2 minutes left")
        #expect(TranscribeFileView.timeLeft(3_660, locale: english) == "About 1 hour, 1 minute left")
    }

    @Test func timesInTheFileShowAsAClock() {
        #expect(TranscribeFileView.clock(5.7, showingHours: false) == "0:05")
        #expect(TranscribeFileView.clock(754, showingHours: false) == "12:34")
        #expect(TranscribeFileView.clock(3_723, showingHours: true) == "1:02:03")
        #expect(TranscribeFileView.clock(65, showingHours: true) == "0:01:05")
    }

    @Test func theWindowSaysWhatTheSpeechModelNeeds() {
        let folder = URL(fileURLWithPath: "/tmp/model")
        let total: Int64 = 2_470_000_000
        let download = "Orra needs its speech model first. Download it from Orra’s menu in the menu bar."
        #expect(TranscribeFileView.speechModelLine(installer: .installed(folder), total: total, model: .ready) == nil)
        #expect(TranscribeFileView.speechModelLine(installer: .installed(folder), total: total, model: .loading) == "Loading the speech model…")
        #expect(TranscribeFileView.speechModelLine(installer: .checking, total: total, model: .notLoaded) == "Loading the speech model…")
        #expect(TranscribeFileView.speechModelLine(installer: .missing(bytesPresent: 0), total: total, model: .notLoaded) == download)
        #expect(TranscribeFileView.speechModelLine(installer: .failed(.offline), total: total, model: .notLoaded) == download)
        #expect(TranscribeFileView.speechModelLine(installer: .installed(folder), total: total, model: .unavailable(.failedToLoad)) == "The speech model could not be loaded")
        // A download under way, which the menu offers to cancel, is not sent to the menu
        // to start one. The window says how far it is, as the menu does.
        let downloading = ModelInstaller.State.downloading(bytes: total / 2, source: nil)
        #expect(TranscribeFileView.speechModelLine(installer: downloading, total: total, model: .notLoaded) == "Downloading the speech model: 50% of 2.47 GB")
        #expect(TranscribeFileView.speechModelLine(installer: downloading, total: total, model: .notLoaded) == downloading.menuLines(total: total).first)
        #expect(TranscribeFileView.speechModelLine(installer: .verifying, total: total, model: .notLoaded) == "Checking the downloaded files…")
    }

    /// What the window says once a file is done: no speech, text with or without parts
    /// the speech model failed on, or no text since it failed on every segment.
    @Test func theWindowSaysHowAFileEnded() {
        #expect(TranscribeFileView.endLine(segments: 0, failedSegments: 0) == "No speech was found in this file.")
        #expect(TranscribeFileView.endLine(segments: 0, failedSegments: 3) == "Orra could not transcribe this file.")
        #expect(TranscribeFileView.endLine(segments: 5, failedSegments: 0) == "Done")
        #expect(TranscribeFileView.endLine(segments: 5, failedSegments: 1) == "Part of this file could not be transcribed.")
    }

    /// Choose File… asks for one audio or video file, and hands over one in iCloud Drive
    /// that is not on this Mac yet, which FileAudioSource then refuses, instead of having
    /// macOS download it, as an open panel does unless told otherwise. The panel is made,
    /// never shown.
    @Test func theOpenPanelHasMacOSDownloadNothing() {
        let panel = TranscribeFileWindow.openPanel()
        #expect(!panel.canDownloadUbiquitousContents)
        #expect(!panel.allowsMultipleSelection)
        #expect(!panel.canChooseDirectories)
        #expect(panel.canChooseFiles)
        #expect(panel.allowedContentTypes == [.audiovisualContent])
    }

    /// The save panel offers the file's name with the extension of the kind and starts in
    /// the folder of the file, so the subtitles of a video land next to it. The panel is
    /// made, never shown.
    @Test func theSavePanelStartsNextToTheFile() throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let panel = TranscribeFileWindow.savePanel(as: .subtitles, name: "Lecture.srt", in: folder)
        #expect(panel.nameFieldStringValue == "Lecture.srt")
        #expect(panel.directoryURL?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(panel.allowedContentTypes.map(\.preferredFilenameExtension) == ["srt"])
        #expect(TranscribeFileWindow.savePanel(as: .text, name: "Lecture.txt", in: folder).allowedContentTypes == [.plainText])
    }

    @Test func eachProblemHasItsMessage() {
        let messages = [FileAudioProblem.unreadable, .noAudio, .protected, .notOnThisMac, .readFailed].map(TranscribeFileView.message(for:))
        #expect(Set(messages).count == 5)
        #expect(TranscribeFileView.message(for: .noAudio) == "This file has no audio.")
    }

    // MARK: The list of segments

    /// The list of segments shows the newest one as it comes, until the user scrolls up to
    /// read, and again once they scroll back to the end. The window is the app's, shown
    /// with orderFrontRegardless far off every screen, so the app is never activated and
    /// nothing shows on the screen. The user's scrolls are events of a mouse wheel given to
    /// the list's scroll view, never posted to the system. A scroll of its clip view in
    /// code would not do: SwiftUI puts its own scroll position back within 50 ms.
    @Test func theListFollowsTheNewestSegmentUntilTheUserScrollsUp() async throws {
        let count = 26
        let source = FakeFileSource(starts: (0..<count).map { Double($0) * 7.5 + 0.4 }, seconds: 6, duration: Double(count) * 7.5 + 5)
        let speech = FakeFileSpeech()
        speech.texts = Dictionary(uniqueKeysWithValues: (1...count).map { ($0, "Sentence \($0) of a made up meeting, long enough to take most of a line.") })
        speech.held = Set(1...count)
        let transcription = FileTranscription(engines: engines(source, speech))
        let window = TranscribeFileWindow.window(hosting: TranscribeFileView(transcription: transcription, speechModelLine: { nil }, chooseFile: {}, save: { _ in }, closeWindow: {}))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer {
            transcription.close()
            window.close()
        }
        transcription.start(URL(fileURLWithPath: "/Users/someone/Recordings/Long meeting.m4a"))
        func release(_ segments: ClosedRange<Int>) async throws {
            for segment in segments {
                try await waitUntil { speech.waiting.contains(segment) }
                speech.release(segment)
                try await waitUntil { transcription.segments.count >= segment }
            }
        }
        try await release(1...16)
        let content = try #require(window.contentView)
        let list = try #require(Self.scrollViews(in: content).max { $0.documentHeight < $1.documentHeight })
        // Taller than the window by a few segments, with the newest in view.
        try await waitUntil { list.documentHeight > list.contentView.bounds.height + 60 && list.showsEnd }

        // The user scrolls up to the first segments, and the list stays there.
        list.scrollByWheel(lines: 200)
        try await Task.sleep(for: .milliseconds(300))
        try await release(17...18)
        try await Task.sleep(for: .milliseconds(300))
        #expect(list.showsTop)
        #expect(!list.showsEnd)

        // Back at the end, it follows again.
        list.scrollByWheel(lines: -200)
        try await Task.sleep(for: .milliseconds(300))
        #expect(list.showsEnd)
        try await release(19...count)
        try await waitUntil { !transcription.isRunning && list.showsEnd }
    }

    /// The scroll views in a window, deepest last.
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { [$0].compactMap { $0 as? NSScrollView } + scrollViews(in: $0) }
    }

    // MARK: Pictures

    /// Renders the window in each of its states to a PNG, for a look at the layout in each
    /// language without running the app. Off unless ORRA_TRANSCRIBE_SNAPSHOTS names a
    /// folder to write to, which the test command passes as
    /// TEST_RUNNER_ORRA_TRANSCRIBE_SNAPSHOTS. CI never sets it. Run with -testLanguage
    /// zh-Hans, ja or es-419 for the other languages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSCRIBE_SNAPSHOTS"] != nil))
    func renderEveryState() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_TRANSCRIBE_SNAPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let texts = Self.sampleTexts[language] ?? Self.sampleTexts["en"]!
        let url = URL(fileURLWithPath: "/Users/someone/Recordings/" + (Self.fileNames[language] ?? "Team meeting.m4a"))
        let starts = (0..<texts.count).map { Double($0) * 7.5 + 0.4 }

        // Before a file, with the speech model loaded, and without it.
        try await render(FileTranscription(engines: engines(FakeFileSource(starts: [], duration: 0), FakeFileSpeech())), name: "\(language)-1-empty", to: folder)
        try await render(FileTranscription(engines: engines(FakeFileSource(starts: [], duration: 0), FakeFileSpeech())), modelLine: TranscribeFileView.speechModelLine(installer: .missing(bytesPresent: 0), total: 2_470_000_000, model: .notLoaded), name: "\(language)-2-no-model", to: folder)

        // Partway, with the time left after a few segments.
        let source = FakeFileSource(starts: starts, seconds: 6, duration: 1_834)
        let speech = FakeFileSpeech()
        speech.texts = Dictionary(uniqueKeysWithValues: texts.enumerated().map { ($0.offset + 1, $0.element) })
        speech.modelSeconds = 1.6
        speech.held = [6]
        let running = FileTranscription(engines: engines(source, speech))
        running.start(url)
        try await waitUntil { speech.waiting.contains(6) }
        try await render(running, name: "\(language)-3-transcribing", to: folder)
        running.stop()
        try await render(running, name: "\(language)-6-stopped", to: folder)

        // Waiting while Live Captions run.
        var captionsOn = false
        let waitingSource = FakeFileSource(starts: starts, seconds: 6, duration: 1_834)
        let waitingSpeech = FakeFileSpeech()
        waitingSpeech.texts = speech.texts
        waitingSpeech.held = [3]
        let waiting = FileTranscription(engines: engines(waitingSource, waitingSpeech, captionsRun: { captionsOn }))
        waiting.start(url)
        try await waitUntil { waitingSpeech.waiting.contains(3) }
        captionsOn = true
        waitingSpeech.release(3)
        try await waitUntil { waiting.waitsForCaptions }
        try await render(waiting, name: "\(language)-4-waiting-for-captions", to: folder)
        waiting.stop()

        // Done, in a file of over an hour, so the times show hours.
        let doneSource = FakeFileSource(starts: starts.map { $0 + 3_590 }, seconds: 6, duration: 3_700)
        let doneSpeech = FakeFileSpeech()
        doneSpeech.texts = speech.texts
        let done = FileTranscription(engines: engines(doneSource, doneSpeech))
        done.start(url)
        try await waitUntil { !done.isRunning }
        try await render(done, name: "\(language)-5-done", to: folder)

        // A movie without sound.
        let silentSource = FakeFileSource(starts: [], duration: 0)
        silentSource.openProblem = .noAudio
        let silent = FileTranscription(engines: engines(silentSource, FakeFileSpeech()))
        silent.start(URL(fileURLWithPath: "/Users/someone/Movies/Screen recording.mov"))
        try await waitUntil { !silent.isRunning }
        try await render(silent, name: "\(language)-7-no-audio", to: folder)

        // The smallest window, partway.
        try await render(running, name: "\(language)-8-smallest", to: folder, width: TranscribeFileWindow.minimumSize.width, height: TranscribeFileWindow.minimumSize.height)
    }

    private func engines(_ source: FakeFileSource, _ speech: FakeFileSpeech, captionsRun: @escaping () -> Bool = { false }) -> FileTranscriptionEngines {
        FileTranscriptionEngines(
            open: { try source.open($0) },
            isSpeechReady: { true },
            settings: { FileTranscriptionSettings() },
            transcribe: { try await speech.transcribe($0, $1) },
            dictationNoteDue: { false },
            captionsRun: captionsRun,
            sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
    }

    /// The window's content at its first size, or the size asked, drawn offscreen. The
    /// question before another file is a sheet, which an offscreen window does not draw.
    private func render(_ transcription: FileTranscription, modelLine: String? = nil, name: String, to folder: URL, width: CGFloat = TranscribeFileWindow.defaultSize.width, height: CGFloat = TranscribeFileWindow.defaultSize.height) async throws {
        let view = TranscribeFileView(transcription: transcription, speechModelLine: { modelLine }, chooseFile: {}, save: { _ in }, closeWindow: {})
        let size = NSSize(width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the view appears without showing.
        let offscreen = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        offscreen.close()
    }

    private static let fileNames = [
        "en": "Team meeting.m4a",
        "zh-Hans": "团队周会.m4a",
        "ja": "定例会議.m4a",
        "es-419": "Reunión del equipo.m4a",
    ]

    /// What the made up file says, in each language of the interface, with a line of
    /// English in each, as people mix them.
    private static let sampleTexts: [String: [String]] = [
        "en": [
            "Thanks everyone for joining. Let's start with the budget for next quarter.",
            "We spent a little less than planned on travel, so there is room for the conference in May.",
            "The hiring plan has two designers and one engineer.",
            "Can we move the design review to Thursday afternoon?",
            "Yes, Thursday works for me.",
            "Then let's look at the release schedule.",
            "The beta goes out on the twelfth, and the final build two weeks later.",
            "I'll send the notes after the meeting.",
        ],
        "zh-Hans": [
            "谢谢大家参加，我们先看一下下个季度的预算。",
            "差旅费比计划少花了一点，所以五月的会议还有余地。",
            "招聘计划里有两位设计师和一位工程师。",
            "设计评审能不能改到周四下午？",
            "可以，周四我没问题。",
            "那我们再看一下 release schedule。",
            "测试版 12 号发，正式版两周以后。",
            "会后我把纪要发给大家。",
        ],
        "ja": [
            "皆さん、お集まりいただきありがとうございます。まず来期の予算から始めましょう。",
            "出張費が予定より少し少なかったので、5月のカンファレンスに余裕があります。",
            "採用計画はデザイナー2名とエンジニア1名です。",
            "デザインレビューを木曜日の午後に移せますか？",
            "はい、木曜日なら大丈夫です。",
            "では release schedule を見ていきましょう。",
            "ベータ版は12日に、正式版はその2週間後に出します。",
            "会議の後で議事録を送ります。",
        ],
        "es-419": [
            "Gracias a todos por venir. Empecemos con el presupuesto del próximo trimestre.",
            "Gastamos un poco menos de lo previsto en viajes, así que hay margen para la conferencia de mayo.",
            "El plan de contratación incluye dos diseñadores y un ingeniero.",
            "¿Podemos pasar la revisión de diseño al jueves por la tarde?",
            "Sí, el jueves me funciona.",
            "Entonces veamos el release schedule.",
            "La beta sale el día doce y la versión final dos semanas después.",
            "Después de la reunión mando las notas.",
        ],
    ]
}

private extension NSScrollView {
    var documentHeight: CGFloat {
        documentView?.frame.height ?? 0
    }

    /// Whether the end of the document shows, within two points.
    var showsEnd: Bool {
        let visible = contentView.bounds
        return documentView?.isFlipped ?? true ? visible.maxY >= documentHeight - 2 : visible.minY <= 2
    }

    /// Whether the start of the document shows, within two points.
    var showsTop: Bool {
        let visible = contentView.bounds
        return documentView?.isFlipped ?? true ? visible.minY <= 2 : visible.maxY >= documentHeight - 2
    }

    /// Scrolls with the wheel of a mouse, as the user does, by `lines` lines, up when
    /// positive. The event goes to this view only, never to the system.
    func scrollByWheel(lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let wheel = NSEvent(cgEvent: event) else { return }
        scrollWheel(with: wheel)
    }
}
