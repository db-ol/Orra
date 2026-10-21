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
    /// The caption target, the user's setting. Chinese, as for most users of Orra.
    var target = TranslationTarget.chinese
    /// How long each transcription takes, by its turn, so a later one can finish first if
    /// the pipeline ever ran two at once.
    var recognitionDelays: [Duration] = []
    var translationDelay: Duration = .zero
    /// Holds each translation until the test lets it go.
    var holdsTranslations = false
    /// Holds the first transcription until the test lets it go, like a slow one, however
    /// long the test takes to feed the audio after it.
    var holdsFirstTranscription = false
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
        "今日はありがとうございました。": "Thank you for today.",
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
            target: { [self] in target },
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
        if turn == 0, holdsFirstTranscription {
            await withCheckedContinuation { held.append($0) }
        }
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

/// Waits until the condition holds, for at most a minute, and fails the test at the caller's
/// line when it does not. The limit is time, not a count of turns, since 2,000 turns of
/// 2 ms ran out on the busy CI runner before the work a test waited for was done.
@MainActor
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor
struct CaptionPipelineTests {
    @Test func sentencesComeInOrderEachTranscriptBeforeItsTranslation() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Let's look at the numbers.", "Next slide please."])
        // The first takes longest, so running them at once would swap the order.
        models.recognitionDelays = [.milliseconds(60), .milliseconds(5), .milliseconds(1)]
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 3))
        await pipeline.finish()
        #expect(models.mostRunning == 1)
        #expect(reports.map(\.id) == [1, 1, 2, 2, 3, 3])
        #expect(reports.map(\.original) == ["Hello everyone.", "Hello everyone.", "Let's look at the numbers.", "Let's look at the numbers.", "Next slide please.", "Next slide please."])
        #expect(reports.map(\.translation) == [
            .pending, .done("大家好。"),
            .pending, .done("我们来看看这些数字。"),
            .pending, .done("请看下一张幻灯片。"),
        ])
        // The times are where each sentence was in the audio.
        let starts = reports.map(\.start)
        #expect(starts == starts.sorted())
        #expect(abs(starts[0] - 0.3) < 0.03)
        #expect(abs(starts[2] - 2.3) < 0.03)
    }

    /// Captions translate into the caption target. A sentence in it already is shown as it
    /// was said, without running the model, on the Chinese routes too, and a change of
    /// the target counts from the next sentence.
    @Test func theTranslationFollowsTheCaptionTarget() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "我们开始吧。", "Next slide please.", "我们开始吧。"])
        models.target = .english
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        try await eventually { reports.last?.translation == .done("Let's get started.") }
        #expect(models.translated.map(\.route) == [.chinese(.english)])
        // One report, with no translation to wait for.
        #expect(reports.filter { $0.id == 1 }.map(\.translation) == [.none])
        models.target = .chinese
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(models.translated.map(\.route) == [.chinese(.english), .chinese(.chinese)])
        #expect(reports.filter { $0.id == 3 }.last?.translation == .done("请看下一张幻灯片。"))
        #expect(reports.filter { $0.id == 4 }.map(\.translation) == [.none])
    }

    /// The captions ask for the caption target, never for the translation key's direction,
    /// so changing Translate into leaves them alone and the other way round.
    @Test func theTranslationKeysDirectionLeavesCaptionsAlone() async throws {
        let cleanup = launchCleanup(direction: .english)
        cleanup.setCaptionTarget(.chinese)
        let engines = CaptionEngines.live(transcription: FakeSpeech().transcription, isSpeechReady: { true }, language: { .chinese }, cleanup: cleanup, turns: EngineTurns())
        #expect(engines.target() == .chinese)
        cleanup.setTranslationDirection(.chinese)
        cleanup.setTranslationDirection(.automatic)
        #expect(engines.target() == .chinese)
        cleanup.setCaptionTarget(.english)
        #expect(engines.target() == .english)
        #expect(cleanup.translationDirection == .automatic)
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
        let target = engines.target
        // The pipeline asks for the target after its first check and reads the language
        // with it, so the switch lands between the two checks.
        engines.target = {
            wantsTranslation = false
            return target()
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

    /// A user who dictates in Spanish and reads Spanish sees an English meeting in Spanish
    /// and a Spanish one as it was said, also with a target saved for Chinese, which acts
    /// as Spanish. With English as the target, the Spanish meeting goes into English. One
    /// who dictates in Japanese and reads English sees kana only Japanese in English.
    @Test func captionsTranslateBetweenTheDictationLanguageAndEnglish() async throws {
        let models = FakeCaptionModels(["Good morning, everyone.", "Gracias a todos."])
        models.language = .spanish
        models.target = .chinese
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(models.translated.map(\.route) == [TranslationRoute(.spanish, into: .spanish)])
        #expect(reports.compactMap(\.translatedText) == ["Buenos días a todos."])
        #expect(reports.filter { $0.id == 2 }.map(\.translation) == [.none])

        let english = FakeCaptionModels(["Good morning, everyone.", "Gracias a todos."])
        english.language = .spanish
        english.target = .english
        var englishReports: [CaptionSentence] = []
        let englishPipeline = CaptionPipeline(engines: english.engines()) { englishReports.append($0) }
        englishPipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await englishPipeline.finish()
        #expect(english.translated.map(\.route) == [TranslationRoute(.spanish, into: .english)])
        #expect(englishReports.compactMap(\.translatedText) == ["Thanks, everyone."])

        let japanese = FakeCaptionModels(["ありがとうございます"])
        japanese.language = .japanese
        japanese.target = .english
        var japaneseReports: [CaptionSentence] = []
        let japanesePipeline = CaptionPipeline(engines: japanese.engines()) { japaneseReports.append($0) }
        japanesePipeline.feed(FakeCaptionModels.audio(sentences: 1))
        await japanesePipeline.finish()
        #expect(japanese.translated.map(\.route) == [TranslationRoute(.japanese, into: .english)])
        #expect(japaneseReports.last?.translation == .done("Thank you very much."))
    }

    /// The rule of the dictation language takes Japanese with kanji for Chinese, and Chinese
    /// for Japanese. Captions tell them apart by their kana, so a Chinese reader sees a
    /// Japanese meeting in English, and a Japanese reader a Chinese one, as before captions
    /// had their own target, instead of as it was said.
    @Test func aMeetingTheRuleTakesForTheDictationLanguageGoesIntoEnglish() async throws {
        let chinese = FakeCaptionModels(["今日はありがとうございました。", "我们开始吧。"])
        chinese.target = .chinese
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: chinese.engines()) { reports.append($0) }
        pipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await pipeline.finish()
        #expect(chinese.translated.map(\.route) == [.chinese(.english)])
        #expect(reports.compactMap(\.translatedText) == ["Thank you for today."])
        // Chinese is in the target already.
        #expect(reports.filter { $0.id == 2 }.map(\.translation) == [.none])

        let japanese = FakeCaptionModels(["我们开始吧。", "今日はありがとうございました。"])
        japanese.language = .japanese
        japanese.target = .japanese
        var japaneseReports: [CaptionSentence] = []
        let japanesePipeline = CaptionPipeline(engines: japanese.engines()) { japaneseReports.append($0) }
        japanesePipeline.feed(FakeCaptionModels.audio(sentences: 2))
        await japanesePipeline.finish()
        #expect(japanese.translated.map(\.route) == [TranslationRoute(.japanese, into: .english)])
        #expect(japaneseReports.compactMap(\.translatedText) == ["Let's get started."])
        #expect(japaneseReports.filter { $0.id == 2 }.map(\.translation) == [.none])
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
        models.target = .english
        var reports: [CaptionSentence] = []
        let engines = models.engines()
        let failing = CaptionEngines(
            isSpeechReady: engines.isSpeechReady,
            transcribe: engines.transcribe,
            canTranslate: engines.canTranslate,
            target: engines.target,
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
        var languages: [SpeechLanguage?] = []
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
            target: { .chinese },
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

    /// A key that goes down while a caption's first pass runs keeps the passes in the
    /// dictation language and English from starting until the dictation is over. The
    /// sentence then runs again from its first pass.
    @Test func aDictationDuringTheFirstPassStartsNoLanguagePass() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let probe = Probe()
        let transcription = Transcription(load: {}, transcribe: { _, _, language in
            probe.languages.append(language)
            if probe.languages.count == 1 {
                // The key goes down while the first pass runs.
                turns.dictationStarted()
            }
            return LanguageGuardTests.swedish
        })
        let engines = CaptionEngines.shared(
            transcription: transcription,
            isSpeechReady: { true },
            canTranslate: { false },
            target: { .chinese },
            complete: { _, _ in "" },
            turns: turns
        )
        let call = Task { try await engines.transcribe([0.1], .chinese) }
        defer { call.cancel() }
        // The key must be down before it goes up, or the caption would wait for good.
        try await waitUntil { turns.isDictating }
        try #require(turns.isDictating)
        // Time for a language pass that must wait for the dictation.
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.languages == [nil])
        turns.dictationEnded()
        #expect(try await call.value == LanguageGuardTests.swedish)
        #expect(probe.languages == [nil, nil, .chinese, .english])
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
        // Other model work hears of the key down too, with the dictation under way.
        turns.whenDictationStarts { events.append("handler, dictating: \(turns.isDictating)") }
        model.dictationStarted()
        #expect(turns.isDictating)
        model.dictationEnded()
        #expect(!turns.isDictating)
        #expect(events == ["handler, dictating: true", "started", "ended"])
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
