import Foundation
import Observation
import os

/// The user's settings a file is transcribed with, those of dictation, read once when the
/// file starts.
nonisolated struct FileTranscriptionSettings: Equatable, Sendable {
    /// The language the user dictates in besides English, see DictationLanguage.
    var language: DictationLanguage = .chinese
    /// The vocabulary terms the speech model gets, the same up to 200 a dictation gets,
    /// see Vocabulary.forModel(_:).
    var terms: [String] = []
    /// Fillers and numbers, as the switches in Settings say, see FillerRules and
    /// NumberRules.
    var removesFillers = true
    var writesDigits = true
}

/// What the speech model wrote for one segment, and how long the model worked on it.
nonisolated struct FileSegmentRecognition: Equatable, Sendable {
    var text: String
    /// Seconds of model work, without the wait for a dictation, for the time left.
    var modelSeconds: Double
}

/// What Transcribe File needs from the app. Closures, so tests pass fakes. The app's go
/// through EngineTurns, so dictation goes first, see `live`.
struct FileTranscriptionEngines {
    /// Opens a file, see FileAudioSource.open(_:).
    var open: (URL) async throws -> OpenedFile
    /// Whether the speech model is loaded.
    var isSpeechReady: () -> Bool
    /// The settings now, read when a file starts.
    var settings: () -> FileTranscriptionSettings
    /// The speech model's text for the samples of one segment, after its turn, see
    /// EngineTurns.
    var transcribe: (_ samples: [Float], _ settings: FileTranscriptionSettings) async throws -> FileSegmentRecognition
    /// Whether a dictation has held up the file for a moment, which the window then says,
    /// see EngineTurns.dictationNoteDue. A tap of the talk key holds it up too briefly.
    var dictationNoteDue: () -> Bool
    /// Whether Live Captions run, during which the file waits.
    var captionsRun: () -> Bool
    /// Waits, while captions run. Tests pass a shorter one.
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

extension FileTranscriptionEngines {
    /// The app's speech model and the user's settings of dictation.
    static func live(transcription: Transcription, turns: EngineTurns, pushToTalk: PushToTalkController, captions: MeetingCaptions) -> FileTranscriptionEngines {
        shared(
            transcription: transcription,
            turns: turns,
            isSpeechReady: { pushToTalk.modelState == .ready },
            settings: {
                FileTranscriptionSettings(
                    language: pushToTalk.dictationLanguage,
                    terms: Vocabulary.forModel(pushToTalk.vocabulary),
                    removesFillers: pushToTalk.removesFillerWords,
                    writesDigits: pushToTalk.writesNumbersAsDigits
                )
            },
            captionsRun: { captions.isOn }
        )
    }

    /// The speech model behind `turns`, from its parts. The end to end test passes a model
    /// it loaded itself, so it runs the path the window runs. Each segment is transcribed
    /// as a dictation is, with the vocabulary, its echo check, the number pass and the
    /// language check, see Transcription.transcribe(_:vocabulary:holdsScreenNames:audioSeconds:takingDigits:language:),
    /// but without names from the screen. A dictation that cancels a segment's call runs
    /// it again after the dictation, however often that happens.
    static func shared(
        transcription: Transcription,
        turns: EngineTurns,
        open: @escaping (URL) async throws -> OpenedFile = FileAudioSource.open,
        isSpeechReady: @escaping () -> Bool,
        settings: @escaping () -> FileTranscriptionSettings,
        captionsRun: @escaping () -> Bool
    ) -> FileTranscriptionEngines {
        FileTranscriptionEngines(
            open: open,
            isSpeechReady: isSpeechReady,
            settings: settings,
            transcribe: { samples, settings in
                try await turns.turn(for: .file, retries: .max) {
                    let started = ContinuousClock.now
                    let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
                    let text = try await transcription.transcribe(
                        samples,
                        vocabulary: settings.terms,
                        audioSeconds: seconds,
                        takingDigits: settings.writesDigits && settings.language.takesDigitsFromPassWithoutVocabulary,
                        language: settings.language
                    )
                    let took = started.duration(to: .now)
                    return FileSegmentRecognition(text: text, modelSeconds: Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
                }
            },
            dictationNoteDue: { turns.dictationNoteDue },
            captionsRun: captionsRun
        )
    }
}

/// Transcribe File: one audio or video file at a time, turned into text segment by
/// segment with the speech model of dictation, the user's dictation language, vocabulary,
/// filler rule and number rule, and no cleanup model. The window shows it, see
/// TranscribeFileWindow.
///
/// Dictation goes first: each segment's call takes its turn through EngineTurns, so a
/// press of the talk key or the translation key gets the speech model before the next
/// segment, and the file goes on after the dictation is pasted or cancelled. While Live
/// Captions run, the file waits before its next segment, so captions keep up with the
/// meeting, and goes on once they are off.
///
/// The text stays in memory, in this object, until the window closes or another file
/// starts. It is written only to a file the user saves, and never logged, nor is the
/// file's name. The log gets durations, counts, timings and error codes.
@Observable
final class FileTranscription {
    nonisolated enum Phase: Equatable, Sendable {
        /// No file yet.
        case idle
        /// The file is being opened.
        case opening
        case transcribing
        /// Every segment is done.
        case finished
        /// The user stopped it. What was done stays.
        case stopped
        /// The file could not be read, at its start or partway, or the speech model went
        /// away. What was done before stays.
        case failed(Failure)
    }

    nonisolated enum Failure: Error, Equatable, Sendable {
        case file(FileAudioProblem)
        /// The speech model is not loaded.
        case speechModel
    }

    /// The file being transcribed, or the last one.
    nonisolated struct File: Equatable, Sendable {
        /// The name the window shows and the save panel starts from. Never logged.
        var name: String
        /// The folder it is in, where the save panel starts. Nothing in it is read.
        var folder: URL
        /// Its length in seconds, 0 until it is open.
        var duration: Double
    }

    /// Why starting another file waits for the user, see `pendingDiscard`.
    nonisolated enum Discard: Equatable, Sendable {
        /// The user dropped or picked this file.
        case startFile(URL)
        /// The user closes the window.
        case closeWindow
    }

    /// The segments the time left waits for, so a slow first segment, which can include
    /// the first load of a program on the GPU, does not decide it alone.
    static let segmentsBeforeEstimate = 3
    /// How often a file waiting for Live Captions looks again.
    static let captionsCheckInterval: Duration = .milliseconds(250)

    private(set) var file: File?
    private(set) var phase: Phase = .idle
    /// The segments with text so far, in order.
    private(set) var segments: [FileTranscriptSegment] = []
    /// Seconds of the file done so far, for the progress bar.
    private(set) var doneSeconds = 0.0
    /// The estimated seconds of work left, nil until `segmentsBeforeEstimate` segments are
    /// done.
    private(set) var secondsLeft: Double?
    /// True while the file waits for Live Captions to stop.
    private(set) var waitsForCaptions = false
    /// Segments the speech model failed on, which are left out.
    private(set) var failedSegments = 0
    /// True once the text was saved to a file since it last changed.
    private(set) var isSaved = false
    /// What waits for the user to discard the text that is not saved, see `choose(_:)`.
    var pendingDiscard: Discard?
    /// True after a drop of several files, which the window says, until a file is chosen.
    private(set) var refusedSeveralFiles = false

    @ObservationIgnored private let engines: FileTranscriptionEngines
    @ObservationIgnored private var job: Task<Void, Never>?
    /// Counts the files started, so a job that was stopped or replaced changes nothing.
    @ObservationIgnored private var jobNumber = 0
    /// Keeps the Mac from sleeping on its own and Orra from App Nap while a file runs.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init(engines: FileTranscriptionEngines) {
        self.engines = engines
    }

    /// Whether the speech model can take a file now.
    var isSpeechReady: Bool {
        engines.isSpeechReady()
    }

    /// Whether a dictation has held up the file for a moment, which the window says.
    var waitsForDictation: Bool {
        phase == .transcribing && engines.dictationNoteDue()
    }

    /// True from the start of a file until it is done, stopped or failed.
    var isRunning: Bool {
        phase == .opening || phase == .transcribing
    }

    /// Whether closing the window or starting another file loses text the user has not
    /// saved, or a file still under way.
    var hasUnsavedText: Bool {
        isRunning || (!segments.isEmpty && !isSaved)
    }

    /// The text without times, for Copy.
    var text: String {
        FileTranscript.text(of: segments)
    }

    /// A drop on the window: one file goes to `choose(_:)`. Several files are refused,
    /// which the window then says, and so is a drop of anything that is no file or while
    /// the speech model is not loaded. Returns whether the drop was taken.
    func drop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard isSpeechReady, !files.isEmpty else { return false }
        guard files.count == 1, let url = files.first else {
            refusedSeveralFiles = true
            return false
        }
        choose(url)
        return true
    }

    /// The user dropped or picked a file: it starts, or when that would lose text that is
    /// not saved, the window asks first, see `pendingDiscard`.
    func choose(_ url: URL) {
        refusedSeveralFiles = false
        guard hasUnsavedText else {
            start(url)
            return
        }
        pendingDiscard = .startFile(url)
    }

    /// The user agreed to discard the text: the file they chose starts. Returns whether
    /// the window may close, for a close that waited.
    @discardableResult
    func discard() -> Bool {
        let pending = pendingDiscard
        pendingDiscard = nil
        switch pending {
        case .startFile(let url):
            start(url)
            return false
        case .closeWindow:
            close()
            return true
        case nil:
            return false
        }
    }

    /// The user kept the text, so nothing changes.
    func keep() {
        pendingDiscard = nil
    }

    /// Starts `url` at once, after stopping a file under way, with the user's settings of
    /// this moment.
    func start(_ url: URL) {
        stopJob()
        jobNumber += 1
        let number = jobNumber
        file = File(name: url.lastPathComponent, folder: url.deletingLastPathComponent(), duration: 0)
        segments = []
        doneSeconds = 0
        secondsLeft = nil
        failedSegments = 0
        waitsForCaptions = false
        isSaved = false
        guard engines.isSpeechReady() else {
            phase = .failed(.speechModel)
            Logger.fileTranscription.notice("A file was not started, the speech model is not loaded")
            return
        }
        phase = .opening
        let settings = engines.settings()
        job = Task { [weak self] in
            await self?.run(url, settings: settings, number: number)
        }
    }

    /// Stops the file under way. The segments done stay, and the one under way is
    /// dropped.
    func stop() {
        guard isRunning else { return }
        phase = .stopped
        waitsForCaptions = false
        secondsLeft = nil
        stopJob()
        Logger.fileTranscription.notice("Stopped by the user at \(Int(self.doneSeconds), privacy: .public) s of \(Int(self.file?.duration ?? 0), privacy: .public) s, \(self.segments.count, privacy: .public) segments")
    }

    /// The window closes: the file under way stops and the text goes from memory.
    func close() {
        if isRunning {
            stop()
        }
        stopJob()
        pendingDiscard = nil
        file = nil
        segments = []
        doneSeconds = 0
        secondsLeft = nil
        failedSegments = 0
        isSaved = false
        phase = .idle
    }

    /// The window asks before it closes while text is not saved. Returns whether it may
    /// close at once.
    func windowShouldClose() -> Bool {
        guard hasUnsavedText else {
            close()
            return true
        }
        pendingDiscard = .closeWindow
        return false
    }

    /// The contents of a file of `kind`, for Save as Text… and Save as Subtitles….
    func contents(as kind: FileTranscript.Kind) -> String {
        FileTranscript.contents(of: segments, as: kind)
    }

    /// The name the save panel offers for `kind`.
    func suggestedName(as kind: FileTranscript.Kind) -> String {
        FileTranscript.suggestedName(for: file?.name ?? "", as: kind)
    }

    /// Writes the text as `kind` to the file the user chose in the save panel, the only
    /// file Transcribe File writes. Throws when it cannot be written.
    func save(as kind: FileTranscript.Kind, to url: URL) throws {
        let data = Data(contents(as: kind).utf8)
        try data.write(to: url, options: .atomic)
        isSaved = true
        Logger.fileTranscription.notice("Saved \(self.segments.count, privacy: .public) segments as \(kind.pathExtension, privacy: .public)")
    }

    private func stopJob() {
        job?.cancel()
        job = nil
        endActivity()
    }

    /// Whether job `number` still owns the window's state.
    private func owns(_ number: Int) -> Bool {
        number == jobNumber && isRunning && !Task.isCancelled
    }

    private func run(_ url: URL, settings: FileTranscriptionSettings, number: Int) async {
        let started = ContinuousClock.now
        let opened: OpenedFile
        do {
            opened = try await engines.open(url)
        } catch {
            guard owns(number) else { return }
            let problem = error as? FileAudioProblem ?? .unreadable
            phase = .failed(.file(problem))
            Logger.fileTranscription.notice("A file could not be opened: \(problem.logName, privacy: .public)")
            return
        }
        guard owns(number) else {
            await opened.cancel()
            return
        }
        file?.duration = opened.duration
        phase = .transcribing
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transcribing a file")
        Logger.fileTranscription.notice("Transcribing a file of \(Int(opened.duration), privacy: .public) s, \(settings.terms.count, privacy: .public) vocabulary terms, language \(settings.language.rawValue, privacy: .public)")
        var modelSeconds = 0.0
        var processed = 0
        var outcome = "finished"
        do {
            while let segment = try await opened.next() {
                try await waitWhileCaptionsRun(number)
                guard owns(number) else { throw CancellationError() }
                let seconds = Double(segment.samples.count) / Double(RecordingLimits.sampleRate)
                do {
                    let recognition = try await engines.transcribe(segment.samples, settings)
                    modelSeconds += recognition.modelSeconds
                    let text = await Self.text(recognition.text, seconds: seconds, settings: settings)
                    guard owns(number) else { throw CancellationError() }
                    if !text.isEmpty {
                        segments.append(FileTranscriptSegment(id: segments.count + 1, start: segment.start, end: segment.end, text: text))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch TranscriptionError.modelMissing {
                    throw Failure.speechModel
                } catch {
                    guard owns(number) else { throw CancellationError() }
                    failedSegments += 1
                    Logger.fileTranscription.error("A segment of \(String(format: "%.1f", seconds), privacy: .public) s failed: \(String(reflecting: type(of: error)), privacy: .public)")
                }
                processed += 1
                let duration = max(opened.duration, segment.end)
                doneSeconds = max(doneSeconds, min(segment.end, duration))
                secondsLeft = Self.secondsLeft(done: doneSeconds, of: duration, modelSeconds: modelSeconds, segments: processed)
            }
            guard owns(number) else { throw CancellationError() }
            doneSeconds = max(doneSeconds, opened.duration)
            secondsLeft = nil
            phase = .finished
        } catch is CancellationError {
            outcome = "stopped"
        } catch let failure as Failure {
            outcome = "failed"
            if owns(number) {
                phase = .failed(failure)
                secondsLeft = nil
            }
        } catch {
            outcome = "failed"
            if owns(number) {
                phase = .failed(.file(error as? FileAudioProblem ?? .readFailed))
                secondsLeft = nil
            }
        }
        await opened.cancel()
        if number == jobNumber {
            endActivity()
        }
        let took = started.duration(to: .now)
        let perMinute = doneSeconds > 0 ? Double(took.components.seconds) / (doneSeconds / 60) : 0
        Logger.fileTranscription.notice("A file \(outcome, privacy: .public) after \(took, privacy: .public): \(processed, privacy: .public) segments, \(self.failedSegments, privacy: .public) failed, model \(String(format: "%.1f", modelSeconds), privacy: .public) s, \(String(format: "%.1f", perMinute), privacy: .public) s per minute of audio")
    }

    /// Waits before the next segment while Live Captions run.
    private func waitWhileCaptionsRun(_ number: Int) async throws {
        guard engines.captionsRun() else { return }
        waitsForCaptions = true
        Logger.fileTranscription.notice("A file waits while Live Captions run")
        while engines.captionsRun() {
            do {
                try await engines.sleep(Self.captionsCheckInterval)
            } catch {
                if number == jobNumber {
                    waitsForCaptions = false
                }
                throw CancellationError()
            }
            guard owns(number) else { throw CancellationError() }
        }
        waitsForCaptions = false
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    /// The seconds of work left: what remains of the file at the pace of the model so far.
    /// Nil before `segmentsBeforeEstimate` segments, and once nothing remains.
    static func secondsLeft(done: Double, of duration: Double, modelSeconds: Double, segments: Int) -> Double? {
        guard segments >= segmentsBeforeEstimate, done > 0, duration > done else { return nil }
        return (duration - done) * modelSeconds / done
    }

    /// A segment's text as a dictation's before the paste: through TranscriptGuard, into
    /// simplified characters for Chinese, without fillers and with numbers as digits when
    /// the switches say so, which Japanese and Spanish skip, as in a dictation. Off the main
    /// actor, since the language check may run NLLanguageRecognizer.
    ///
    /// Unlike a dictation, a segment of nothing but fillers, such as “Um.” or “嗯。” between
    /// two pauses, is left out while fillers are removed, see FillerRules.isOnlyFillers(_:).
    @concurrent
    nonisolated static func text(_ raw: String, seconds: Double, settings: FileTranscriptionSettings) async -> String {
        let guarded = TranscriptGuard.clean(raw, audioSeconds: seconds)
        var text = settings.language.simplifiesCharacters ? ChineseText.simplified(guarded) : guarded
        let takesSteps = settings.language == .chinese || LanguageGuard.takesChineseAndEnglishSteps(text, for: settings.language)
        if settings.removesFillers, takesSteps {
            if FillerRules.isOnlyFillers(text) {
                return ""
            }
            text = FillerRules.removingFillers(from: text)
        }
        if settings.writesDigits, takesSteps {
            text = NumberRules.writingNumbersAsDigits(in: text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
