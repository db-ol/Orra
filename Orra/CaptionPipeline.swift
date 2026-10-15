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
    /// The speech model's text for 16 kHz mono samples.
    var transcribe: (_ samples: [Float]) async throws -> String
    /// Whether the cleanup model can translate now, without waiting for a load.
    var canTranslate: () -> Bool
    /// Which way to translate, the user's translation setting.
    var direction: () -> TranslationDirection
    /// The model's answer for a sentence and a target, see RewriteEngine.translate.
    var translate: (_ text: String, _ target: TranslationTarget) async throws -> String
}

extension CaptionEngines {
    /// The app's models, shared with dictation through `turns`. The transcript gets the
    /// language check dictation has, see Transcription.checkingLanguage, but no vocabulary,
    /// since a transcript of only vocabulary terms costs extra passes.
    static func live(transcription: Transcription, isSpeechReady: @escaping () -> Bool, cleanup: TextCleanup, turns: EngineTurns) -> CaptionEngines {
        shared(
            transcription: transcription,
            isSpeechReady: isSpeechReady,
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
        canTranslate: @escaping () -> Bool,
        direction: @escaping () -> TranslationDirection,
        complete: @escaping @Sendable (String, TranslationTarget) async throws -> String,
        turns: EngineTurns
    ) -> CaptionEngines {
        CaptionEngines(
            isSpeechReady: isSpeechReady,
            transcribe: { samples in
                try await turns.captionTurn {
                    let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
                    return try await transcription.transcribe(samples, vocabulary: [], audioSeconds: seconds, takingDigits: false)
                }
            },
            canTranslate: canTranslate,
            direction: direction,
            translate: { text, target in
                try await turns.captionTranslationTurn { try await complete(text, target) }
            }
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
final class CaptionPipeline {
    /// The sentences waiting, beyond which translation is skipped.
    static let defaultBacklogLimit = 3
    /// The sentences kept waiting, such as during a long hands free dictation. Older ones
    /// are dropped past this, since each holds up to 12 s of audio and a caption that
    /// comes minutes late is worth nothing.
    static let waitingLimit = 20

    /// The measurement on audio files, which feeds faster than real time, passes no limit.
    let backlogLimit: Int

    private var segmenter: CaptionSegmenter
    private let engines: CaptionEngines
    private let report: (CaptionSentence) -> Void
    /// Called when a sentence is dropped because the speech model is not loaded.
    private let speechNotReady: () -> Void
    private let segments: AsyncStream<CaptionSegment>
    private let input: AsyncStream<CaptionSegment>.Continuation
    private var worker: Task<Void, Never>?
    private var waiting = 0
    private var nextID = 0
    private var isStopped = false

    init(
        engines: CaptionEngines,
        settings: CaptionSegmenter.Settings = .init(),
        backlogLimit: Int = CaptionPipeline.defaultBacklogLimit,
        speechNotReady: @escaping () -> Void = {},
        report: @escaping (CaptionSentence) -> Void
    ) {
        segmenter = CaptionSegmenter(settings: settings)
        self.engines = engines
        self.backlogLimit = backlogLimit
        self.report = report
        self.speechNotReady = speechNotReady
        (segments, input) = AsyncStream.makeStream(of: CaptionSegment.self, bufferingPolicy: .bufferingNewest(Self.waitingLimit))
        worker = Task { [weak self, segments] in
            for await segment in segments {
                guard let self, !Task.isCancelled else { return }
                await self.process(segment)
            }
        }
    }

    /// Takes the next samples of the stream.
    func feed(_ samples: [Float]) {
        guard !isStopped else { return }
        for segment in segmenter.append(samples) {
            enqueue(segment)
        }
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
        if case .dropped = input.yield(segment) {
            waiting -= 1
            Logger.captions.notice("A waiting caption sentence was dropped, more than \(Self.waitingLimit, privacy: .public) were waiting")
        }
    }

    private func process(_ segment: CaptionSegment) async {
        defer { waiting -= 1 }
        guard engines.isSpeechReady() else {
            speechNotReady()
            return
        }
        let recognitionStarted = ContinuousClock.now
        let raw: String
        do {
            raw = try await engines.transcribe(segment.samples)
        } catch {
            if !(error is CancellationError) {
                Logger.captions.error("Transcribing a caption failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
            return
        }
        guard !isStopped, !Task.isCancelled else { return }
        let recognitionSeconds = Self.seconds(recognitionStarted.duration(to: .now))
        let text = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: segment.duration))
        guard !text.isEmpty else { return }
        let target = engines.direction().target(for: text)
        let translates = target != nil && TranslationStep.isWorthTranslating(text) && waiting <= backlogLimit && engines.canTranslate()
        nextID += 1
        var sentence = CaptionSentence(
            id: nextID,
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
        guard let parsed = TranslationPrompt.parse(answer) else {
            Logger.captions.notice("A caption translation was not readable")
            return nil
        }
        if let failure = TranslationGuard.check(source: text, output: parsed.translation, target: target) {
            Logger.captions.notice("A caption translation was held back by the \(failure.logName, privacy: .public) check")
            return nil
        }
        return parsed.translation == text ? nil : parsed.translation
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
