import Foundation
import Testing
@testable import Orra

/// Stand in models for the caption pipeline. Each sentence of made up audio is a tone, and
/// the fake speech model writes the next of `transcripts` for it. The fake translation
/// answers like the cleanup model's translation prompt, with the translation from
/// `translations`, or the text itself, which is no translation.
@MainActor
final class FakeCaptionModels {
    var transcripts: [String]
    var speechReady = true
    var translationReady = true
    var direction = TranslationDirection.automatic
    /// How long each transcription takes, by its turn, so a later one can finish first if
    /// the pipeline ever ran two at once.
    var recognitionDelays: [Duration] = []
    var translationDelay: Duration = .zero
    /// Holds each translation until the test lets it go.
    var holdsTranslations = false
    private(set) var transcribed = 0
    private(set) var translated: [(String, TranslationTarget)] = []
    private(set) var running = 0
    private(set) var mostRunning = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    static let translations = [
        "Hello everyone.": "大家好。",
        "我们开始吧。": "Let's get started.",
        "Next slide please.": "请看下一张幻灯片。",
        "Let's look at the numbers.": "我们来看看这些数字。",
        "That sounds good.": "听起来不错。",
    ]

    init(_ transcripts: [String]) {
        self.transcripts = transcripts
    }

    func engines(turns: EngineTurns? = nil) -> CaptionEngines {
        CaptionEngines(
            isSpeechReady: { [self] in speechReady },
            transcribe: { [self] samples in
                if let turns {
                    return try await turns.captionTurn { try await self.transcribe(samples) }
                }
                return try await transcribe(samples)
            },
            canTranslate: { [self] in translationReady },
            direction: { [self] in direction },
            translate: { [self] text, target in
                if let turns {
                    return try await turns.captionTranslationTurn { try await self.translate(text, target) }
                }
                return try await translate(text, target)
            }
        )
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        let turn = transcribed
        transcribed += 1
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        if turn < recognitionDelays.count {
            try await Task.sleep(for: recognitionDelays[turn])
        }
        return turn < transcripts.count ? transcripts[turn] : ""
    }

    private func translate(_ text: String, _ target: TranslationTarget) async throws -> String {
        translated.append((text, target))
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        if holdsTranslations {
            await withCheckedContinuation { held.append($0) }
        }
        try? await Task.sleep(for: translationDelay)
        let translation = Self.translations[text] ?? text
        // Like RewriteEngine.generate, a cancelled call does not throw. It returns the
        // answer cut off where it stopped.
        if Task.isCancelled {
            return #"{"cleaned": "\#(text)", "translation": "\#(translation.prefix(1))"#
        }
        return #"{"cleaned": "\#(text)", "translation": "\#(translation)"}"#
    }

    var isHolding: Bool {
        !held.isEmpty
    }

    func letGo() {
        holdsTranslations = false
        let continuations = held
        held = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Made up audio with one sentence per transcript.
    static func audio(sentences: Int) -> [Float] {
        var audio = CaptionAudio.silence(0.5)
        for _ in 0..<sentences {
            audio += CaptionAudio.tone(1) + CaptionAudio.silence(1)
        }
        return audio
    }
}

/// Waits until the condition holds, for at most a few seconds.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 where !condition() {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
}

@MainActor
struct CaptionPipelineTests {
    @Test func sentencesComeInOrderEachTranscriptBeforeItsTranslation() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "我们开始吧。", "Next slide please."])
        // The first takes longest, so running them at once would swap the order.
        models.recognitionDelays = [.milliseconds(60), .milliseconds(5), .milliseconds(1)]
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 3))
        await pipeline.finish()
        #expect(models.mostRunning == 1)
        #expect(reports.map(\.id) == [1, 1, 2, 2, 3, 3])
        #expect(reports.map(\.original) == ["Hello everyone.", "Hello everyone.", "我们开始吧。", "我们开始吧。", "Next slide please.", "Next slide please."])
        #expect(reports.map(\.translation) == [
            .pending, .done("大家好。"),
            .pending, .done("Let's get started."),
            .pending, .done("请看下一张幻灯片。"),
        ])
        // The times are where each sentence was in the audio.
        let starts = reports.map(\.start)
        #expect(starts == starts.sorted())
        #expect(abs(starts[0] - 0.3) < 0.03)
        #expect(abs(starts[2] - 2.3) < 0.03)
    }

    @Test func theTranslationFollowsTheSetDirection() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "我们开始吧。"])
        models.direction = .english
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        // English into English gives the text back, which is no translation.
        #expect(models.translated.map(\.1) == [.english, .english])
        #expect(reports[1].translation == CaptionSentence.Translation.none)
        #expect(reports.last?.translation == .done("Let's get started."))
    }

    @Test func withoutTheLocalModelSentencesComeWithoutTranslation() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Thanks."])
        models.translationReady = false
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(reports.map(\.original) == ["Hello everyone.", "Thanks."])
        #expect(reports.allSatisfy { $0.translation == .none })
        #expect(models.translated.isEmpty)
    }

    @Test func withoutTheSpeechModelSentencesAreDroppedAndSaidSo() async throws {
        let models = FakeCaptionModels(["Hello everyone."])
        models.speechReady = false
        var reports: [CaptionSentence] = []
        var missing = 0
        let pipeline = CaptionPipeline(engines: models.engines(), speechNotReady: { missing += 1 }) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(reports.isEmpty)
        #expect(missing == 2)
        #expect(models.transcribed == 0)
    }

    @Test func silenceAndEmptyTranscriptsGiveNoSentence() async throws {
        let models = FakeCaptionModels(["", "  ", "Okay."])
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(CaptionAudio.silence(3))
        pipeline.feed(FakeCaptionModels.audio(sentences: 3))
        await pipeline.finish()
        #expect(reports.map(\.id) == [1, 1])
        #expect(reports.first?.original == "Okay.")
    }

    @Test func aTranslationThatFailsItsCheckIsNotShown() async throws {
        let models = FakeCaptionModels(["请把这份报告发给我。"])
        var reports: [CaptionSentence] = []
        let engines = models.engines()
        let failing = CaptionEngines(
            isSpeechReady: engines.isSpeechReady,
            transcribe: engines.transcribe,
            canTranslate: engines.canTranslate,
            direction: engines.direction,
            // Chinese where English was asked for.
            translate: { _, _ in #"{"cleaned": "请把这份报告发给我。", "translation": "请把这份报告发给我吧。"}"# }
        )
        let pipeline = CaptionPipeline(engines: failing) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await pipeline.finish()
        #expect(reports.map(\.translation) == [.pending, .none])
    }

    @Test func stoppingDropsWhatWaitsAndReportsNothingMore() async throws {
        let models = FakeCaptionModels(["One.", "Two.", "Three."])
        models.holdsTranslations = true
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 3))
        try await eventually { models.isHolding }
        #expect(reports.map(\.original) == ["One."])
        pipeline.stop()
        models.letGo()
        try await Task.sleep(for: .milliseconds(50))
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await pipeline.finish()
        #expect(reports.map(\.original) == ["One."])
        #expect(models.transcribed == 1)
    }

    @Test func farBehindSentencesSkipTheTranslationToCatchUp() async throws {
        let models = FakeCaptionModels((1...8).map { "Sentence \($0)." })
        models.holdsTranslations = true
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 8))
        try await eventually { models.isHolding }
        models.letGo()
        await pipeline.finish()
        let final = Dictionary(reports.map { ($0.id, $0.translation) }, uniquingKeysWith: { $1 })
        // Eight came at once. The first five had more than the backlog limit behind them
        // and went without translation, the last three were translated.
        #expect(final.count == 8)
        #expect((1...5).allSatisfy { final[$0] == CaptionSentence.Translation.none })
        #expect(models.translated.map(\.0) == ["Sentence 6.", "Sentence 7.", "Sentence 8."])
    }
}

/// Captions give way to dictation on the shared models, see EngineTurns.
@MainActor
struct EngineTurnsTests {
    @MainActor
    private final class Probe {
        var ran = false
        var attempts = 0
        var started = false
    }

    @Test func aCaptionCallWaitsWhileADictationRuns() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        turns.dictationStarted()
        let probe = Probe()
        let call = Task { try await turns.captionTurn { @MainActor in probe.ran = true } }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!probe.ran)
        turns.dictationEnded()
        try await call.value
        #expect(probe.ran)
    }

    @Test func aDictationCancelsTheCaptionCallAndItRunsAgainAfter() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let probe = Probe()
        let call = Task {
            try await turns.captionTranslationTurn { @MainActor () async throws -> Int in
                probe.attempts += 1
                probe.started = true
                // A translation, which stops when its task is cancelled and returns what
                // it has so far, without throwing.
                try? await Task.sleep(for: probe.attempts == 1 ? .seconds(30) : .milliseconds(1))
                return probe.attempts
            }
        }
        try await eventually { probe.started }
        turns.dictationStarted()
        try await Task.sleep(for: .milliseconds(30))
        // Stopped at once, and not yet run again.
        #expect(probe.attempts == 1)
        turns.dictationEnded()
        #expect(try await call.value == 2)
    }

    @Test func aTranslationCutOffByADictationIsNotShownAndRunsAgain() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let models = FakeCaptionModels(["Hello everyone."])
        models.holdsTranslations = true
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(turns: turns)) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        try await eventually { models.isHolding }
        turns.dictationStarted()
        // The translation stops early and returns a cut off answer, as the model does.
        models.letGo()
        try await Task.sleep(for: .milliseconds(30))
        #expect(models.translated.count == 1)
        #expect(reports.allSatisfy { $0.translation == .pending })
        turns.dictationEnded()
        await pipeline.finish()
        #expect(models.translated.count == 2)
        #expect(reports.last?.translation == .done("大家好。"))
    }

    @Test func turningCaptionsOffCancelsAWaitingCall() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        turns.dictationStarted()
        let call = Task { try await turns.captionTurn { 1 } }
        try await Task.sleep(for: .milliseconds(10))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test func theDictationsCleanupModelTellsTheTurns() {
        let turns = EngineTurns()
        var events: [String] = []
        let model = CleanupModel(waitUntilLoaded: { false }, dictationStarted: { events.append("started") }, dictationEnded: { events.append("ended") }, complete: { _ in "" })
            .sharing(turns)
        model.dictationStarted()
        #expect(turns.isDictating)
        model.dictationEnded()
        #expect(!turns.isDictating)
        #expect(events == ["started", "ended"])
    }

    @Test func captionsWaitForADictationAndCatchUpInOrder() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let models = FakeCaptionModels(["Let's look at the numbers.", "That sounds good."])
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(turns: turns)) { reports.append($0) }
        turns.dictationStarted()
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(models.transcribed == 0)
        turns.dictationEnded()
        await pipeline.finish()
        #expect(reports.map(\.original) == ["Let's look at the numbers.", "Let's look at the numbers.", "That sounds good.", "That sounds good."])
        #expect(reports.last?.translation == .done("听起来不错。"))
    }
}
