import Foundation
import os

/// One sentence of the meeting captions: what was said and, once the model wrote it, its
/// translation. Held in memory only, never logged or saved.
nonisolated struct CaptionSentence: Identifiable, Equatable, Sendable {
    nonisolated enum Translation: Equatable, Sendable {
        /// The model is translating it.
        case pending
        case done(String)
        /// No translation: the model is not ready, captions are behind, there was nothing
        /// to translate, or the translation failed a check or the model failed.
        case none
    }

    let id: Int
    /// Where the sentence starts and ends in the audio, in seconds from the start of the
    /// captions.
    let start: Double
    let end: Double
    let original: String
    var translation: Translation
    /// True for the text of a sentence still being heard, which the final text of the
    /// sentence replaces once it ends. Never translated.
    var isInterim = false
    /// How long the speech model and the cleanup model took for it, for the measurement.
    var recognitionSeconds: Double = 0
    var translationSeconds: Double = 0

    var translatedText: String? {
        if case .done(let text) = translation { text } else { nil }
    }
}

/// What the caption pipeline needs from the models. Closures, so tests pass fakes. The
/// app's go through EngineTurns, so dictation keeps priority, see `live`.
struct CaptionEngines {
    /// Whether the speech model is loaded.
    var isSpeechReady: () -> Bool
    /// The speech model's text for 16 kHz mono samples, with the language check for the
    /// dictation language.
    var transcribe: (_ samples: [Float], _ language: DictationLanguage) async throws -> String
    /// Whether the models are free for an interim caption, which is when no dictation
    /// is under way.
    var isFree: () -> Bool = { true }
    /// The speech model's text for a sentence still being heard. Unlike `transcribe`, it
    /// does not run again after a dictation that cancelled it, since the sentence has
    /// moved on by then. Nil uses `transcribe`.
    var transcribeInterim: ((_ samples: [Float], _ language: DictationLanguage) async throws -> String)?
    /// Whether the cleanup model can translate now, without waiting for a load.
    var canTranslate: () -> Bool
    /// Which way to translate, the user's translation setting.
    var direction: () -> TranslationDirection
    /// The model's answer for a sentence and a target, see RewriteEngine.translate.
    var translate: (_ text: String, _ target: TranslationTarget) async throws -> String
    /// The user's dictation language at this moment, see DictationLanguage. Each sentence
    /// is checked with the one chosen when it is transcribed.
    var language: () -> DictationLanguage = { .chinese }
}

extension CaptionEngines {
    /// The app's models, shared with dictation through `turns`. The transcript gets the
    /// language check dictation has, with the user's dictation language, see
    /// Transcription.checkingLanguage, but no vocabulary, since a transcript of only
    /// vocabulary terms costs extra passes.
    static func live(transcription: Transcription, isSpeechReady: @escaping () -> Bool, language: @escaping () -> DictationLanguage, cleanup: TextCleanup, turns: EngineTurns) -> CaptionEngines {
        shared(
            transcription: transcription,
            isSpeechReady: isSpeechReady,
            language: language,
            canTranslate: { cleanup.isReadyForCaptions },
            direction: { cleanup.translationDirection },
            complete: cleanup.translation.complete,
            turns: turns
        )
    }

    /// The models behind `turns`, from their parts. The measurement on audio files passes
    /// models it loaded itself, so it runs the path the app runs.
    static func shared(
        transcription: Transcription,
        isSpeechReady: @escaping () -> Bool,
        language: @escaping () -> DictationLanguage = { .chinese },
        canTranslate: @escaping () -> Bool,
        direction: @escaping () -> TranslationDirection,
        complete: @escaping @Sendable (String, TranslationTarget) async throws -> String,
        turns: EngineTurns
    ) -> CaptionEngines {
        let transcribe: @Sendable ([Float], DictationLanguage) async throws -> String = { samples, language in
            let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
            return try await transcription.transcribe(samples, vocabulary: [], audioSeconds: seconds, takingDigits: false, language: language)
        }
        return CaptionEngines(
            isSpeechReady: isSpeechReady,
            transcribe: { samples, language in
                try await turns.captionTurn { try await transcribe(samples, language) }
            },
            isFree: { !turns.isDictating },
            transcribeInterim: { samples, language in
                try await turns.captionTurn(retries: 0) { try await transcribe(samples, language) }
            },
            canTranslate: canTranslate,
            direction: direction,
            translate: { text, target in
                try await turns.captionTranslationTurn { try await complete(text, target) }
            },
            language: language
        )
    }
}

/// Turns a stream of 16 kHz mono audio into caption sentences: CaptionSegmenter cuts it at
/// pauses, the speech model transcribes each sentence, and the cleanup model translates
/// it. Live captions feed it the sound the Mac plays, and the measurement and the tests
/// feed it audio files or made up audio, so they all run the same path.
///
/// Sentences are transcribed and translated one at a time, in the order they were said.
/// Each is reported once when it is heard, with its translation pending when one follows,
/// and again when the translation is done. When more than `backlogLimit` sentences wait,
/// such as after a long dictation, sentences are shown without translation until captions
/// catch up, since a caption that comes late is worth little.
///
/// With `interimInterval`, the text of a sentence still being heard shows while the
/// person talks: every `interimInterval` of new audio the speech model transcribes the
/// sentence so far, and the line is reported as interim under the id its final text gets
/// later. Only when nothing else waits, the models are free and the sentence is not
/// pausing, since its end and its final text are near then. Interim text is not
/// translated, so the cleanup model runs once per sentence as before.
final class CaptionPipeline {
    /// The sentences waiting, beyond which translation is skipped.
    static let defaultBacklogLimit = 3
    /// How often the live captions transcribe a sentence still being heard, in seconds
    /// of its audio.
    static let defaultInterimInterval = 1.0
    /// A sentence silent this long at its end gets no interim text, since it is likely
    /// to end.
    static let interimPauseLimit = 0.1
    /// The sentences kept waiting, such as during a long hands free dictation. Older ones
    /// are dropped past this, since each holds up to 12 s of audio and a caption that
    /// comes minutes late is worth nothing.
    static let waitingLimit = 20

    /// The measurement on audio files, which feeds faster than real time, passes no limit.
    let backlogLimit: Int
    /// Seconds of new audio between interim texts of a sentence, nil for none.
    let interimInterval: Double?

    /// What the worker does next: a sentence that ended, with its number in the stream,
    /// or an interim text of the one being heard.
    private enum Job {
        case sentence(CaptionSegment, number: Int)
        case interim
    }

    private var segmenter: CaptionSegmenter
    private let engines: CaptionEngines
    private let report: (CaptionSentence) -> Void
    /// Called with the id of an interim line whose sentence got no final text, so it goes.
    private let withdraw: (Int) -> Void
    /// Called when a sentence is dropped because the speech model is not loaded.
    private let speechNotReady: () -> Void
    private let jobs: AsyncStream<Job>
    private let input: AsyncStream<Job>.Continuation
    private var worker: Task<Void, Never>?
    /// Sentences that ended and are not reported yet.
    private var waiting = 0
    private var nextID = 0
    private var isStopped = false
    /// Sentences the segmenter cut so far, which is the number of the one being heard.
    private var cutCount = 0
    /// True while an interim job waits for the worker.
    private var interimQueued = false
    /// The sentence the last interim text was for, and its audio then.
    private var lastInterim: (number: Int, seconds: Double)?
    /// The interim line on show and its sentence, which the final text replaces.
    private var interimLine: (number: Int, id: Int)?

    init(
        engines: CaptionEngines,
        settings: CaptionSegmenter.Settings = .init(),
        backlogLimit: Int = CaptionPipeline.defaultBacklogLimit,
        interimInterval: Double? = nil,
        speechNotReady: @escaping () -> Void = {},
        withdraw: @escaping (Int) -> Void = { _ in },
        report: @escaping (CaptionSentence) -> Void
    ) {
        segmenter = CaptionSegmenter(settings: settings)
        self.engines = engines
        self.backlogLimit = backlogLimit
        self.interimInterval = interimInterval
        self.report = report
        self.withdraw = withdraw
        self.speechNotReady = speechNotReady
        // An interim job is queued only while no sentence waits, so it takes no place of
        // one. A full queue drops it first, as the oldest job.
        (jobs, input) = AsyncStream.makeStream(of: Job.self, bufferingPolicy: .bufferingNewest(Self.waitingLimit))
        worker = Task { [weak self, jobs] in
            for await job in jobs {
                guard let self, !Task.isCancelled else { return }
                switch job {
                case .sentence(let segment, let number):
                    await self.process(segment, number: number)
                case .interim:
                    await self.interim()
                }
            }
        }
    }

    /// Sentences that ended and are not reported yet. For the measurement on audio
    /// files, which feeds faster than real time.
    var waitingSentences: Int {
        waiting
    }

    /// Takes the next samples of the stream.
    func feed(_ samples: [Float]) {
        guard !isStopped else { return }
        for segment in segmenter.append(samples) {
            enqueue(segment)
        }
        if isInterimDue {
            interimQueued = true
            yield(.interim)
        }
    }

    /// Whether the sentence being heard should get interim text now: it grew by
    /// `interimInterval` since its last one, or reached it, nothing else waits or runs,
    /// the models are free and it is not pausing.
    private var isInterimDue: Bool {
        guard let interimInterval, !interimQueued, waiting == 0, segmenter.isInSpeech,
              segmenter.openSilenceSeconds < Self.interimPauseLimit else { return false }
        let heard = lastInterim.flatMap { $0.number == cutCount ? $0.seconds : nil } ?? 0
        return segmenter.openSeconds >= heard + interimInterval && engines.isFree()
    }

    /// The end of the stream: the last sentence is cut, and this returns once every
    /// sentence is reported. For the measurement and tests.
    func finish() async {
        if !isStopped, let last = segmenter.finish() {
            enqueue(last)
        }
        input.finish()
        await worker?.value
    }

    /// Stops at once: the sentence being processed is cancelled and the waiting ones are
    /// dropped, and nothing is reported after this returns.
    func stop() {
        isStopped = true
        input.finish()
        worker?.cancel()
        worker = nil
    }

    private func enqueue(_ segment: CaptionSegment) {
        waiting += 1
        cutCount += 1
        yield(.sentence(segment, number: cutCount - 1))
    }

    private func yield(_ job: Job) {
        guard case .dropped(let dropped) = input.yield(job) else { return }
        switch dropped {
        case .sentence(_, let number):
            waiting -= 1
            if let line = interimLine, line.number == number {
                interimLine = nil
                withdraw(line.id)
            }
            Logger.captions.notice("A waiting caption sentence was dropped, more than \(Self.waitingLimit, privacy: .public) were waiting")
        case .interim:
            interimQueued = false
        }
    }

    /// Transcribes the sentence being heard and reports its text as interim, when it is
    /// still due and still being heard once the model is done.
    private func interim() async {
        interimQueued = false
        guard waiting == 0, engines.isSpeechReady(), engines.isFree(), let open = segmenter.openSentence else { return }
        let number = cutCount
        lastInterim = (number, segmenter.openSeconds)
        let language = engines.language()
        let recognitionStarted = ContinuousClock.now
        let raw: String
        do {
            raw = try await (engines.transcribeInterim ?? engines.transcribe)(open.samples, language)
        } catch {
            if !(error is CancellationError) {
                Logger.captions.error("Transcribing an interim caption failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
            return
        }
        // A sentence that ended meanwhile gets its final text next.
        guard !isStopped, !Task.isCancelled, cutCount == number else { return }
        let text = Self.text(raw, seconds: open.duration, language: language)
        guard !text.isEmpty else { return }
        let id: Int
        if let line = interimLine, line.number == number {
            id = line.id
        } else {
            nextID += 1
            id = nextID
            interimLine = (number, id)
        }
        report(CaptionSentence(
            id: id,
            start: open.start,
            end: open.end,
            original: text,
            translation: .none,
            isInterim: true,
            recognitionSeconds: Self.seconds(recognitionStarted.duration(to: .now))
        ))
    }

    private func process(_ segment: CaptionSegment, number: Int) async {
        defer { waiting -= 1 }
        // The interim line of this sentence, which the final text replaces, or which goes
        // when there is none.
        var interimID: Int?
        if let line = interimLine, line.number == number {
            interimID = line.id
            interimLine = nil
        }
        var reported = false
        defer {
            if !reported, let interimID, !isStopped {
                withdraw(interimID)
            }
        }
        guard engines.isSpeechReady() else {
            speechNotReady()
            return
        }
        let language = engines.language()
        let recognitionStarted = ContinuousClock.now
        let raw: String
        do {
            raw = try await engines.transcribe(segment.samples, language)
        } catch {
            if !(error is CancellationError) {
                Logger.captions.error("Transcribing a caption failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
            return
        }
        guard !isStopped, !Task.isCancelled else { return }
        let recognitionSeconds = Self.seconds(recognitionStarted.duration(to: .now))
        let text = Self.text(raw, seconds: segment.duration, language: language)
        guard !text.isEmpty else { return }
        let target = engines.direction().target(for: text)
        let translates = target != nil && TranslationStep.isWorthTranslating(text) && waiting <= backlogLimit && engines.canTranslate()
        let id: Int
        if let interimID {
            id = interimID
        } else {
            nextID += 1
            id = nextID
        }
        reported = true
        var sentence = CaptionSentence(
            id: id,
            start: segment.start,
            end: segment.end,
            original: text,
            translation: translates ? .pending : .none,
            recognitionSeconds: recognitionSeconds
        )
        report(sentence)
        guard translates, let target else { return }
        let translationStarted = ContinuousClock.now
        let translation = await translate(text, into: target)
        guard !isStopped, !Task.isCancelled else { return }
        sentence.translation = translation.map { .done($0) } ?? .none
        sentence.translationSeconds = Self.seconds(translationStarted.duration(to: .now))
        report(sentence)
    }

    /// The translation when it passes TranslationGuard, as for a dictation, nil otherwise.
    /// The cleanup part of the answer is not used, since captions show what was said.
    private func translate(_ text: String, into target: TranslationTarget) async -> String? {
        let answer: String
        do {
            answer = try await engines.translate(text, target)
        } catch {
            if !(error is CancellationError) {
                Logger.captions.error("Translating a caption failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
            return nil
        }
        let parsed = TranslationPrompt.parse(answer)
        switch TranslationStep.verdict(on: parsed, for: text, into: target) {
        case .translated:
            return parsed?.translation
        case .unreadable:
            Logger.captions.notice("A caption translation was not readable")
        case .heldBack(let failure):
            Logger.captions.notice("A caption translation was held back by the \(failure.logName, privacy: .public) check")
        case .unchanged, .timedOut, .failed:
            break
        }
        return nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// A caption's text as a dictation's: through TranscriptGuard, and into simplified
    /// characters for a user who dictates in Chinese, see DictationLanguage.
    private static func text(_ raw: String, seconds: Double, language: DictationLanguage) -> String {
        let guarded = TranscriptGuard.clean(raw, audioSeconds: seconds)
        return language.simplifiesCharacters ? ChineseText.simplified(guarded) : guarded
    }
}
