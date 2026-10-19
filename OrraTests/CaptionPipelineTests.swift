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
    /// The dictation language each transcription was given.
    private(set) var languages: [DictationLanguage] = []
    /// The dictation language the engines report, as the user's setting.
    var language = DictationLanguage.chinese
    /// The text and the route of each translation.
    private(set) var translated: [(text: String, route: TranslationRoute)] = []
    private(set) var running = 0
    private(set) var mostRunning = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    static let translations = [
        "Hello everyone.": "大家好。",
        "我们开始吧。": "Let's get started.",
        "Next slide please.": "请看下一张幻灯片。",
        "Let's look at the numbers.": "我们来看看这些数字。",
        "That sounds good.": "听起来不错。",
        "Good morning, everyone.": "Buenos días a todos.",
        "Gracias a todos.": "Thanks, everyone.",
        "ありがとうございます": "Thank you very much.",
    ]

    init(_ transcripts: [String]) {
        self.transcripts = transcripts
    }

    func engines(turns: EngineTurns? = nil) -> CaptionEngines {
        CaptionEngines(
            isSpeechReady: { [self] in speechReady },
            transcribe: { [self] samples, language in
                if let turns {
                    return try await turns.captionTurn { try await self.transcribe(samples, language) }
                }
                return try await transcribe(samples, language)
            },
            canTranslate: { [self] in translationReady },
            direction: { [self] in direction },
            translate: { [self] text, route in
                if let turns {
                    return try await turns.captionTranslationTurn { try await self.translate(text, route) }
                }
                return try await translate(text, route)
            },
            language: { [self] in language }
        )
    }

    private func transcribe(_ samples: [Float], _ language: DictationLanguage) async throws -> String {
        let turn = transcribed
        transcribed += 1
        languages.append(language)
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        if turn < recognitionDelays.count {
            try await Task.sleep(for: recognitionDelays[turn])
        }
        return turn < transcripts.count ? transcripts[turn] : ""
    }

    private func translate(_ text: String, _ route: TranslationRoute) async throws -> String {
        translated.append((text, route))
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
        #expect(models.translated.map(\.route.target) == [.english, .english])
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

    /// Original only shows what was said, so nothing is translated, also with the model
    /// ready. A switch to a mode that translates counts from the next sentence, and so
    /// does a switch back.
    @Test func originalOnlyNeverTranslates() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please.", "That sounds good.", "Let's look at the numbers."])
        var wantsTranslation = false
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(), wantsTranslation: { wantsTranslation }) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        try await eventually { reports.count == 2 }
        #expect(reports.map(\.original) == ["Hello everyone.", "Next slide please."])
        #expect(reports.allSatisfy { $0.translation == .none })
        #expect(models.translated.isEmpty)
        wantsTranslation = true
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        try await eventually { reports.last?.translation == .done("听起来不错。") }
        #expect(models.translated.map(\.text) == ["That sounds good."])
        wantsTranslation = false
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await pipeline.finish()
        #expect(models.translated.map(\.text) == ["That sounds good."])
        #expect(reports.last?.original == "Let's look at the numbers.")
        #expect(reports.last?.translation == CaptionSentence.Translation.none)
    }

    /// A switch to Original while the language of a sentence is read leaves that sentence
    /// without translation.
    @Test func aSwitchToOriginalDuringTheLanguageReadIsHeeded() async throws {
        let models = FakeCaptionModels(["Hello everyone."])
        var wantsTranslation = true
        var reports: [CaptionSentence] = []
        var engines = models.engines()
        let direction = engines.direction
        // The pipeline asks for the direction after its first check and reads the language
        // with it, so the switch lands between the two checks.
        engines.direction = {
            wantsTranslation = false
            return direction()
        }
        let pipeline = CaptionPipeline(engines: engines, wantsTranslation: { wantsTranslation }) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await pipeline.finish()
        #expect(!wantsTranslation)
        #expect(reports.map(\.translation) == [.none])
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

    /// Each sentence is checked with the dictation language chosen when it is transcribed,
    /// and keeps its Han characters as written for Japanese.
    @Test func eachSentenceTakesTheDictationLanguageOfItsMoment() async throws {
        let models = FakeCaptionModels([LanguageGuardTests.japaneseInHan, LanguageGuardTests.japaneseInHan])
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        try await eventually { models.transcribed == 1 }
        models.language = .japanese
        pipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await pipeline.finish()
        #expect(models.languages == [.chinese, .japanese])
        #expect(Set(reports.filter { $0.id == 1 }.map(\.original)) == [ChineseText.simplified(LanguageGuardTests.japaneseInHan)])
        #expect(Set(reports.filter { $0.id == 2 }.map(\.original)) == [LanguageGuardTests.japaneseInHan])
    }

    /// A user who dictates in Spanish reads an English meeting in Spanish and a Spanish one
    /// in English, also with a direction saved for Chinese, which acts as Automatic. One
    /// who dictates in Japanese reads kana only Japanese in English.
    @Test func captionsTranslateBetweenTheDictationLanguageAndEnglish() async throws {
        let models = FakeCaptionModels(["Good morning, everyone.", "Gracias a todos."])
        models.language = .spanish
        models.direction = .chinese
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(models.translated.map(\.route) == [TranslationRoute(.spanish, into: .spanish), TranslationRoute(.spanish, into: .english)])
        #expect(reports.compactMap(\.translatedText) == ["Buenos días a todos.", "Thanks, everyone."])

        let japanese = FakeCaptionModels(["ありがとうございます"])
        japanese.language = .japanese
        var japaneseReports: [CaptionSentence] = []
        let japanesePipeline = CaptionPipeline(engines: japanese.engines()) { japaneseReports.append($0) }
        japanesePipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await japanesePipeline.finish()
        #expect(japanese.translated.map(\.route) == [TranslationRoute(.japanese, into: .english)])
        #expect(japaneseReports.last?.translation == .done("Thank you very much."))
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
        #expect(models.translated.map(\.text) == ["Sentence 6.", "Sentence 7.", "Sentence 8."])
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

    /// The captions check the language of each sentence with the dictation language they
    /// are given, as dictation does.
    @Test func captionsCheckTheLanguageWithTheDictationLanguage() async throws {
        let speech = FakeSpeech()
        speech.reply = LanguageGuardTests.spanish
        let engines = CaptionEngines.shared(
            transcription: speech.transcription,
            isSpeechReady: { true },
            language: { .spanish },
            canTranslate: { false },
            direction: { .automatic },
            complete: { _, _ in "" },
            turns: EngineTurns()
        )
        #expect(engines.language() == .spanish)
        #expect(try await engines.transcribe([0.1], .chinese) == LanguageGuardTests.spanish)
        #expect(speech.receivedLanguages == [nil, .chinese, .english])
        let interim = try #require(engines.transcribeInterim)
        #expect(try await interim([0.1], .spanish) == LanguageGuardTests.spanish)
        #expect(try await engines.transcribe([0.1], .spanish) == LanguageGuardTests.spanish)
        #expect(speech.receivedLanguages == [nil, .chinese, .english, nil, nil])
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

    @Test func aLongDictationKeepsOnlyTheLatestWaitingSentences() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let models = FakeCaptionModels((1...25).map { "Sentence \($0)." })
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(turns: turns)) { reports.append($0) }
        turns.dictationStarted()
        // The pipeline is ready for its first sentence.
        try await Task.sleep(for: .milliseconds(20))
        pipeline.feed(FakeCaptionModels.audio(sentences: 25))
        try await Task.sleep(for: .milliseconds(30))
        turns.dictationEnded()
        await pipeline.finish()
        // The first sentence was taken up at once and the latest 20 waited. Sentences 2
        // to 5 were dropped.
        #expect(models.transcribed == 1 + CaptionPipeline.waitingLimit)
        let starts = reports.map(\.start)
        #expect(starts.first ?? 99 < 1)
        #expect(!starts.contains { $0 > 2 && $0 < 10 })
        #expect(starts.last ?? 0 > 48)
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
