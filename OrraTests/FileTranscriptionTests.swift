import Foundation
import Testing
@testable import Orra

/// A file that gives made up segments, and can fail to open or stop partway.
@MainActor
final class FakeFileSource {
    var segments: [CaptionSegment]
    var duration: Double
    var openProblem: FileAudioProblem?
    /// Thrown after the segments, as by a file whose audio stops partway.
    var problemAfterSegments: FileAudioProblem?
    private(set) var opened = 0
    private(set) var taken = 0
    private(set) var cancelled = false

    init(_ segments: [CaptionSegment], duration: Double) {
        self.segments = segments
        self.duration = duration
    }

    /// Segments of `seconds` each, starting at `starts`, with one sample per segment that
    /// says which it is.
    convenience init(starts: [Double], seconds: Double = 3, duration: Double) {
        self.init(starts.enumerated().map { index, start in
            CaptionSegment(samples: [Float](repeating: Float(index + 1), count: Int(seconds * 16_000)), start: start, end: start + seconds)
        }, duration: duration)
    }

    func open(_ url: URL) throws -> OpenedFile {
        opened += 1
        if let openProblem {
            throw openProblem
        }
        return OpenedFile(duration: duration, next: { try await self.next() }, cancel: { await self.cancel() })
    }

    func next() throws -> CaptionSegment? {
        guard taken < segments.count else {
            if let problemAfterSegments {
                throw problemAfterSegments
            }
            return nil
        }
        taken += 1
        return segments[taken - 1]
    }

    func cancel() {
        cancelled = true
    }
}

/// The speech model of a file's tests: its text for each segment, which segment a call is
/// for, calls that wait until the test lets them go, and failures.
@MainActor
final class FakeFileSpeech {
    /// The text of each segment by its number, from 1, “Segment N.” when there is none.
    var texts: [Int: String] = [:]
    var errors: [Int: any Error] = [:]
    /// Segments whose call waits until `release`, or until it is cancelled.
    var held: Set<Int> = []
    var modelSeconds = 1.0
    /// The segment of each call, in order, cancelled calls included.
    private(set) var calls: [Int] = []
    private(set) var settings: [FileTranscriptionSettings] = []
    /// The calls that are waiting now.
    private(set) var waiting: Set<Int> = []

    func release(_ segment: Int) {
        held.remove(segment)
    }

    func transcribe(_ samples: [Float], _ settings: FileTranscriptionSettings) async throws -> FileSegmentRecognition {
        let segment = Int(samples.first ?? 0)
        calls.append(segment)
        self.settings.append(settings)
        if held.contains(segment) {
            waiting.insert(segment)
            defer { waiting.remove(segment) }
            while held.contains(segment) {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        if let error = errors[segment] {
            throw error
        }
        return FileSegmentRecognition(text: texts[segment] ?? "Segment \(segment).", modelSeconds: modelSeconds)
    }
}

@MainActor
struct FileTranscriptionTests {
    let url = URL(fileURLWithPath: "/Users/someone/Recordings/Interview.m4a")

    private func engines(
        _ source: FakeFileSource,
        _ speech: FakeFileSpeech,
        ready: Bool = true,
        settings: FileTranscriptionSettings = FileTranscriptionSettings(),
        captionsRun: @escaping () -> Bool = { false }
    ) -> FileTranscriptionEngines {
        FileTranscriptionEngines(
            open: { try source.open($0) },
            isSpeechReady: { ready },
            settings: { settings },
            transcribe: { try await speech.transcribe($0, $1) },
            dictationNoteDue: { false },
            captionsRun: captionsRun,
            sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
    }

    private func finished(_ transcription: FileTranscription) async throws {
        try await waitUntil { !transcription.isRunning }
    }

    @Test func segmentsComeInOrderWithTheirTimesAndTheFileIsLetGo() async throws {
        let source = FakeFileSource(starts: [0.2, 4.0, 9.5], duration: 14)
        let speech = FakeFileSpeech()
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        #expect(transcription.file?.name == "Interview.m4a")
        #expect(transcription.isRunning)
        try await finished(transcription)
        #expect(transcription.phase == .finished)
        #expect(transcription.file == FileTranscription.File(name: "Interview.m4a", folder: url.deletingLastPathComponent(), duration: 14))
        #expect(transcription.file?.folder.path == "/Users/someone/Recordings")
        #expect(transcription.segments == [
            FileTranscriptSegment(id: 1, start: 0.2, end: 3.2, text: "Segment 1."),
            FileTranscriptSegment(id: 2, start: 4.0, end: 7.0, text: "Segment 2."),
            FileTranscriptSegment(id: 3, start: 9.5, end: 12.5, text: "Segment 3."),
        ])
        #expect(transcription.doneSeconds == 14)
        #expect(transcription.text == "Segment 1.\nSegment 2.\nSegment 3.")
        #expect(source.cancelled)
        #expect(speech.calls == [1, 2, 3])
    }

    /// The text of each segment goes through the steps of a dictation before the paste,
    /// with the user's switches, and a segment without text is left out.
    @Test func eachSegmentGoesThroughTheRulesOfDictation() async throws {
        let raw = "呃，這個季度的增长是百分之五十。"
        let simplified = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: 3))
        let ruled = NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: simplified))
        #expect(ruled != simplified)
        for (fillers, digits, expected) in [(true, true, ruled), (false, false, simplified)] {
            let source = FakeFileSource(starts: [0, 4], duration: 8)
            let speech = FakeFileSpeech()
            speech.texts = [1: raw, 2: "  "]
            let settings = FileTranscriptionSettings(language: .chinese, terms: [], removesFillers: fillers, writesDigits: digits)
            let transcription = FileTranscription(engines: engines(source, speech, settings: settings))
            transcription.start(url)
            try await finished(transcription)
            #expect(transcription.segments.map(\.text) == [expected])
        }
        // Japanese text skips the Chinese and English rules, as in a dictation.
        let japanese = "えーと、三時に会いましょう。"
        let source = FakeFileSource(starts: [0], duration: 4)
        let speech = FakeFileSpeech()
        speech.texts = [1: japanese]
        let transcription = FileTranscription(engines: engines(source, speech, settings: FileTranscriptionSettings(language: .japanese)))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.segments.map(\.text) == [japanese])
    }

    /// A segment of nothing but fillers between two pauses, such as “Um.” or “嗯。”, is left
    /// out while fillers are removed, where a dictation of nothing else keeps it as it is.
    /// A hum that asks, a reply and a filler in a sentence are not left out.
    @Test func aSegmentOfNothingButFillersIsLeftOut() async {
        let settings = FileTranscriptionSettings()
        for filler in ["Um.", "Uh.", "嗯。", "呃。", "额。", "Um, uh.", "嗯嗯。", "Erm…"] {
            #expect(await FileTranscription.text(filler, seconds: 1, settings: settings) == "", "\(filler)")
        }
        #expect(FillerRules.removingFillers(from: "Um.") == "Um.")
        #expect(FillerRules.removingFillers(from: "嗯。") == "嗯。")
        for kept in ["嗯？", "Uh-huh.", "嗯哼。", "好的。", "UM."] {
            #expect(await FileTranscription.text(kept, seconds: 1, settings: settings) == kept, "\(kept)")
        }
        #expect(await FileTranscription.text("Um, we can ship it.", seconds: 2, settings: settings) == "We can ship it.")
        var keepingFillers = settings
        keepingFillers.removesFillers = false
        #expect(await FileTranscription.text("Um.", seconds: 1, settings: keepingFillers) == "Um.")
    }

    /// The vocabulary and the language of dictation reach the speech model through the
    /// path the window uses, read once when the file starts.
    @Test func theSpeechModelGetsTheVocabularyAndTheLanguageOfDictation() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let probe = Probe()
        let transcription = Transcription(load: {}, transcribe: { _, context, language in
            probe.contexts.append(context)
            probe.languages.append(language)
            return "Orra and Quorvia."
        })
        var settings = FileTranscriptionSettings(language: .chinese, terms: ["Orra", "Quorvia"], removesFillers: true, writesDigits: true)
        let engines = FileTranscriptionEngines.shared(
            transcription: transcription,
            turns: EngineTurns(pollInterval: .milliseconds(2)),
            open: { try source.open($0) },
            isSpeechReady: { true },
            settings: { settings },
            captionsRun: { false }
        )
        let file = FileTranscription(engines: engines)
        file.start(url)
        // A change after the start counts from the next file.
        settings.terms = []
        try await waitUntil { !file.isRunning }
        #expect(file.segments.map(\.text) == ["Orra and Quorvia.", "Orra and Quorvia."])
        #expect(probe.contexts == ["Orra\nQuorvia", "Orra\nQuorvia"])
        #expect(probe.languages == [nil, nil])
    }

    /// What a test's speech model saw, for the closures that stand in for it.
    @MainActor
    private final class Probe {
        var contexts: [String?] = []
        var languages: [SpeechLanguage?] = []
        var segments: [Int] = []
        var running = false
        var calls = 0
        /// When the test pressed the key.
        var pressed: ContinuousClock.Instant?

        /// A first call that only the press may end, however long a busy runner takes to
        /// get to the press. It gives up 5 s after a press that did not cancel it, so the
        /// test fails then instead of waiting for good.
        func runUntilThePress() async throws {
            while pressed.map({ $0.duration(to: .now) < .seconds(5) }) ?? true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test func progressFollowsTheSegmentsAndTheTimeLeftComesAfterAFew() async throws {
        let source = FakeFileSource(starts: [0, 10, 20, 30, 40], seconds: 5, duration: 60)
        let speech = FakeFileSpeech()
        speech.modelSeconds = 2
        speech.held = [3, 4]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await waitUntil { speech.waiting.contains(3) }
        // Two segments done, too few for an estimate.
        #expect(transcription.doneSeconds == 15)
        #expect(transcription.secondsLeft == nil)
        speech.release(3)
        try await waitUntil { speech.waiting.contains(4) }
        // 25 s of the file in 6 s of model work, so the 35 s left take 8.4 s.
        #expect(transcription.doneSeconds == 25)
        let left = try #require(transcription.secondsLeft)
        #expect(abs(left - 35 * 6 / 25) < 0.0001)
        speech.release(4)
        try await finished(transcription)
        #expect(transcription.secondsLeft == nil)
        #expect(transcription.doneSeconds == 60)
    }

    @Test func theTimeLeftIsTheRestOfTheFileAtThePaceSoFar() {
        #expect(FileTranscription.secondsLeft(done: 30, of: 90, modelSeconds: 3, segments: 2) == nil)
        #expect(FileTranscription.secondsLeft(done: 30, of: 90, modelSeconds: 3, segments: 3) == 6)
        #expect(FileTranscription.secondsLeft(done: 90, of: 90, modelSeconds: 9, segments: 9) == nil)
        #expect(FileTranscription.secondsLeft(done: 0, of: 90, modelSeconds: 0, segments: 3) == nil)
    }

    @Test func stopKeepsWhatIsDoneAndDropsTheSegmentUnderWay() async throws {
        let source = FakeFileSource(starts: [0, 4, 8, 12], duration: 16)
        let speech = FakeFileSpeech()
        speech.held = [3]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await waitUntil { speech.waiting.contains(3) }
        transcription.stop()
        #expect(transcription.phase == .stopped)
        #expect(!transcription.isRunning)
        try await waitUntil { source.cancelled }
        speech.release(3)
        try await Task.sleep(for: .milliseconds(30))
        #expect(transcription.segments.map(\.text) == ["Segment 1.", "Segment 2."])
        #expect(transcription.phase == .stopped)
        #expect(speech.calls == [1, 2, 3])
        #expect(transcription.hasUnsavedText)
    }

    @Test func aFileThatCannotBeReadSaysWhy() async throws {
        for problem in [FileAudioProblem.unreadable, .noAudio, .protected, .notOnThisMac] {
            let source = FakeFileSource(starts: [0], duration: 4)
            source.openProblem = problem
            let speech = FakeFileSpeech()
            let transcription = FileTranscription(engines: engines(source, speech))
            transcription.start(url)
            try await finished(transcription)
            #expect(transcription.phase == .failed(.file(problem)))
            #expect(transcription.segments.isEmpty)
            #expect(speech.calls.isEmpty)
            #expect(!transcription.hasUnsavedText)
        }
    }

    @Test func aFileThatStopsPartwayKeepsWhatWasDone() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 30)
        source.problemAfterSegments = .readFailed
        let speech = FakeFileSpeech()
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .failed(.file(.readFailed)))
        #expect(transcription.segments.count == 2)
        #expect(transcription.hasUnsavedText)
    }

    @Test func aSegmentTheModelFailsOnIsLeftOutAndCounted() async throws {
        let source = FakeFileSource(starts: [0, 4, 8], duration: 12)
        let speech = FakeFileSpeech()
        speech.errors = [2: URLError(.unknown)]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .finished)
        #expect(transcription.segments.map(\.text) == ["Segment 1.", "Segment 3."])
        #expect(transcription.failedSegments == 1)
        #expect(TranscribeFileView.endLine(segments: transcription.segments.count, failedSegments: transcription.failedSegments) == "Part of this file could not be transcribed.")
    }

    /// A file whose every segment the speech model fails on ends with no text, and the
    /// window says that it could not be transcribed, not that it holds no speech.
    @Test func aFileWhoseEverySegmentFailsSaysSo() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let speech = FakeFileSpeech()
        speech.errors = [1: URLError(.unknown), 2: URLError(.unknown)]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .finished)
        #expect(transcription.segments.isEmpty)
        #expect(transcription.failedSegments == 2)
        #expect(TranscribeFileView.endLine(segments: 0, failedSegments: 2) == "Orra could not transcribe this file.")
    }

    @Test func aSpeechModelThatGoesAwayEndsTheFile() async throws {
        let source = FakeFileSource(starts: [0, 4, 8], duration: 12)
        let speech = FakeFileSpeech()
        speech.errors = [2: TranscriptionError.modelMissing]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .failed(.speechModel))
        #expect(transcription.segments.map(\.text) == ["Segment 1."])
        #expect(speech.calls == [1, 2])
    }

    @Test func aFileStartsOnlyWithTheSpeechModelLoaded() async throws {
        let source = FakeFileSource(starts: [0], duration: 4)
        let transcription = FileTranscription(engines: engines(source, FakeFileSpeech(), ready: false))
        #expect(!transcription.isSpeechReady)
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .failed(.speechModel))
        #expect(source.opened == 0)
    }

    @Test func aFileWithoutSpeechEndsWithNoSegments() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let speech = FakeFileSpeech()
        speech.texts = [1: "", 2: " "]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.phase == .finished)
        #expect(transcription.segments.isEmpty)
        #expect(!transcription.hasUnsavedText)
    }

    // MARK: Turns

    /// A dictation under way when a segment comes up holds it until the dictation is over,
    /// as for captions. The window says that the file waits once the dictation has gone on
    /// for a moment, as the caption window does, so a tap of the talk key does not flash
    /// it: here once after 20 ms, and never for a tap, with turns whose note comes after an
    /// hour.
    @Test(arguments: [(Duration.seconds(3_600), false), (.milliseconds(20), true)])
    func aDictationGoesFirst(_ noteDelay: Duration, _ noteShows: Bool) async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2), noteDelay: noteDelay)
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let probe = Probe()
        let transcription = Transcription(load: {}, transcribe: { _, _, _ in
            probe.calls += 1
            return "Hello."
        })
        let file = FileTranscription(engines: .shared(transcription: transcription, turns: turns, open: { try source.open($0) }, isSpeechReady: { true }, settings: { FileTranscriptionSettings() }, captionsRun: { false }))
        turns.dictationStarted()
        file.start(url)
        try await waitUntil { file.phase == .transcribing }
        if noteShows {
            try await waitUntil { file.waitsForDictation }
        } else {
            try await Task.sleep(for: .milliseconds(40))
            #expect(!file.waitsForDictation)
        }
        #expect(probe.calls == 0)
        turns.dictationEnded()
        try await waitUntil { !file.isRunning }
        #expect(file.segments.map(\.text) == ["Hello.", "Hello."])
        #expect(!file.waitsForDictation)
    }

    /// A press while a segment's call runs cancels it, and the segment runs again once the
    /// dictation is over, so it is neither lost nor written twice.
    @Test func aPressCancelsTheSegmentUnderWayWhichRunsAgainAfterTheDictation() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let source = FakeFileSource(starts: [0, 4, 8], duration: 12)
        let probe = Probe()
        let transcription = Transcription(load: {}, transcribe: { samples, _, _ in
            let segment = Int(samples.first ?? 0)
            probe.segments.append(segment)
            if segment == 2, probe.segments.count(where: { $0 == 2 }) == 1 {
                probe.running = true
                defer { probe.running = false }
                try await probe.runUntilThePress()
            }
            return "Segment \(segment)."
        })
        let file = FileTranscription(engines: .shared(transcription: transcription, turns: turns, open: { try source.open($0) }, isSpeechReady: { true }, settings: { FileTranscriptionSettings() }, captionsRun: { false }))
        file.start(url)
        try await waitUntil { probe.running }
        probe.pressed = .now
        turns.dictationStarted()
        try await waitUntil { !probe.running }
        try await Task.sleep(for: .milliseconds(30))
        // Cancelled at once, and not yet run again.
        #expect(probe.segments == [1, 2])
        #expect(file.isRunning)
        turns.dictationEnded()
        try await waitUntil { !file.isRunning }
        #expect(probe.segments == [1, 2, 2, 3])
        #expect(file.segments.map(\.text) == ["Segment 1.", "Segment 2.", "Segment 3."])
    }

    /// While Live Captions run, the file waits before its next segment, and goes on once
    /// they are off.
    @Test func theFileWaitsWhileLiveCaptionsRun() async throws {
        let source = FakeFileSource(starts: [0, 4, 8], duration: 12)
        let speech = FakeFileSpeech()
        speech.held = [2]
        var captionsOn = false
        let transcription = FileTranscription(engines: engines(source, speech, captionsRun: { captionsOn }))
        transcription.start(url)
        try await waitUntil { speech.waiting.contains(2) }
        // Captions start while the second segment runs: it finishes, the third waits.
        captionsOn = true
        speech.release(2)
        try await waitUntil { transcription.waitsForCaptions }
        try await Task.sleep(for: .milliseconds(30))
        #expect(speech.calls == [1, 2])
        #expect(transcription.isRunning)
        captionsOn = false
        try await finished(transcription)
        #expect(!transcription.waitsForCaptions)
        #expect(speech.calls == [1, 2, 3])
        #expect(transcription.phase == .finished)
    }

    // MARK: Drops

    /// A drop of one file starts it. A drop of several files is refused, which the window
    /// says until a file is chosen, also while a file is in the window, and so is a drop of
    /// no file or while the speech model is not loaded.
    @Test func aDropTakesOneFileAtATime() async throws {
        let source = FakeFileSource(starts: [0], duration: 4)
        let transcription = FileTranscription(engines: engines(source, FakeFileSpeech()))
        let other = URL(fileURLWithPath: "/Users/someone/Movies/Talk.mp4")
        #expect(!transcription.drop([url, other]))
        #expect(transcription.refusedSeveralFiles)
        #expect(transcription.file == nil)
        let notAFile = try #require(URL(string: "orra-test:talk"))
        #expect(!transcription.drop([notAFile]))
        #expect(transcription.drop([url]))
        #expect(!transcription.refusedSeveralFiles)
        try await finished(transcription)
        #expect(transcription.file?.name == "Interview.m4a")
        #expect(!transcription.drop([url, other]))
        #expect(transcription.refusedSeveralFiles)
        #expect(transcription.file?.name == "Interview.m4a")
        #expect(source.opened == 1)
        transcription.choose(other)
        #expect(!transcription.refusedSeveralFiles)

        let notReady = FileTranscription(engines: engines(FakeFileSource(starts: [0], duration: 4), FakeFileSpeech(), ready: false))
        #expect(!notReady.drop([url]))
        #expect(notReady.file == nil)
    }

    // MARK: The text that is not saved

    @Test func anotherFileAsksFirstWhileTheTextIsNotSaved() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let speech = FakeFileSpeech()
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.choose(url)
        try await finished(transcription)
        #expect(transcription.hasUnsavedText)
        let next = URL(fileURLWithPath: "/Users/someone/Movies/Talk.mp4")
        transcription.choose(next)
        #expect(transcription.pendingDiscard == .startFile(next))
        #expect(transcription.file?.name == "Interview.m4a")
        transcription.keep()
        #expect(transcription.pendingDiscard == nil)
        #expect(transcription.segments.count == 2)
        transcription.choose(next)
        #expect(transcription.discard() == false)
        #expect(transcription.file?.name == "Talk.mp4")
        try await finished(transcription)
        #expect(source.opened == 2)

        // Once saved, the next file starts at once.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try transcription.save(as: .text, to: folder.appendingPathComponent("Talk.txt"))
        #expect(!transcription.hasUnsavedText)
        transcription.choose(url)
        #expect(transcription.pendingDiscard == nil)
        #expect(transcription.file?.name == "Interview.m4a")
        try await finished(transcription)
    }

    @Test func aFileUnderWayAsksFirstToo() async throws {
        let source = FakeFileSource(starts: [0, 4], duration: 8)
        let speech = FakeFileSpeech()
        speech.held = [1]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await waitUntil { speech.waiting.contains(1) }
        #expect(transcription.hasUnsavedText)
        #expect(!transcription.windowShouldClose())
        #expect(transcription.pendingDiscard == .closeWindow)
        #expect(transcription.discard())
        #expect(transcription.file == nil)
        #expect(transcription.phase == .idle)
        try await waitUntil { source.cancelled }
        speech.release(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(transcription.segments.isEmpty)
    }

    @Test func closingWithNothingToLoseClosesAtOnceAndForgetsTheText() async throws {
        let empty = FileTranscription(engines: engines(FakeFileSource(starts: [], duration: 0), FakeFileSpeech()))
        #expect(empty.windowShouldClose())
        let source = FakeFileSource(starts: [0], duration: 4)
        let transcription = FileTranscription(engines: engines(source, FakeFileSpeech()))
        transcription.start(url)
        try await finished(transcription)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try transcription.save(as: .subtitles, to: folder.appendingPathComponent("Interview.srt"))
        #expect(transcription.windowShouldClose())
        #expect(transcription.segments.isEmpty)
        #expect(transcription.file == nil)
    }

    @Test func savingWritesTheFileTheUserChoseInTheKindTheyChose() async throws {
        let source = FakeFileSource(starts: [1.5, 5], duration: 9)
        let speech = FakeFileSpeech()
        speech.texts = [1: "Hello everyone.", 2: "今天我们看一下预算。"]
        let transcription = FileTranscription(engines: engines(source, speech))
        transcription.start(url)
        try await finished(transcription)
        #expect(transcription.suggestedName(as: .text) == "Interview.txt")
        #expect(transcription.suggestedName(as: .subtitles) == "Interview.srt")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("Interview.txt")
        let subtitles = folder.appendingPathComponent("Interview.srt")
        try transcription.save(as: .text, to: text)
        try transcription.save(as: .subtitles, to: subtitles)
        #expect(try String(contentsOf: text, encoding: .utf8) == "Hello everyone.\n今天我们看一下预算。\n")
        #expect(try String(contentsOf: subtitles, encoding: .utf8) == "1\n00:00:01,500 --> 00:00:04,500\nHello everyone.\n\n2\n00:00:05,000 --> 00:00:08,000\n今天我们看一下预算。\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Interview.srt", "Interview.txt"])
        #expect(transcription.isSaved)
    }
}
