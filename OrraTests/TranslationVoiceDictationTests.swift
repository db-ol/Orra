import Foundation
import Synchronization
import Testing
@testable import Orra

/// The translation key with Speak Translation on.
@MainActor
struct TranslationVoiceDictationTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()

    /// A voice that records what it was handed.
    @MainActor
    final class Recorder {
        var spoken: [String] = []
        var speaks = true
        var alsoPastes = true

        var voice: TranslationVoice {
            TranslationVoice(
                speaks: { self.speaks },
                alsoPastes: { self.alsoPastes },
                speak: { text, language in self.spoken.append("\(language.rawValue) \(text)") }
            )
        }
    }

    private func controller(_ translation: PushToTalkControllerTests.FakeTranslation, voice: Recorder, language: DictationLanguage = .chinese) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            translation: translation.model,
            voice: voice.voice,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            dictationLanguage: language
        )
        controller.setTranslationKeyOn(true)
        await controller.loadModel()
        speech.reply = "呃，我们下周一，哦不是，下周二开会。"
        return controller
    }

    private func dictate(_ controller: PushToTalkController, with key: TalkKey) async throws {
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.pressed(isRepeat: false), key: .key(key))
        try await waitUntil { mic.calls.filter { $0 == "start" }.count > starts }
        controller.handle(.released, key: .key(key))
        try await waitUntil { controller.state == .idle }
    }

    /// A voice sample for Speak Translation is written down by the speech model at 16 kHz,
    /// without the vocabulary and without a paste, and only once the model is loaded. A
    /// silent sample gives no words.
    @Test func aVoiceSampleIsWrittenDownByTheSpeechModel() async throws {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        let sample = VoiceSample(samples: (0..<96_000).map { sin(Float($0) * 0.05) * 0.3 }, sampleRate: 48_000)
        await #expect(throws: TranscriptionError.modelMissing) {
            try await controller.transcribeVoiceSample(sample)
        }
        await controller.loadModel()
        speech.reply = " We met at noon. "
        #expect(try await controller.transcribeVoiceSample(sample) == "We met at noon.")
        #expect(speech.receivedContexts == [nil])
        #expect(speech.receivedLanguages == [nil])
        #expect(abs((speech.receivedSampleCounts.last ?? 0) - 32_000) < 100)

        let silent = VoiceSample(samples: [Float](repeating: 0, count: 48_000), sampleRate: 16_000)
        #expect(try await controller.transcribeVoiceSample(silent) == "")
        #expect(speech.receivedContexts.count == 1)
        #expect(inserter.inserted.isEmpty)
    }

    /// The translation is spoken and pasted, and Copy Last Dictation still has it.
    @Test func theTranslationIsSpokenAndPasted() async throws {
        let voice = Recorder()
        let controller = await controller(PushToTalkControllerTests.FakeTranslation(), voice: voice)
        try await dictate(controller, with: .rightOption)
        #expect(voice.spoken == ["en We have a meeting next Tuesday."])
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        #expect(controller.lastTranscript == "We have a meeting next Tuesday.")
    }

    /// With Also paste off, the translation is only spoken.
    @Test func theTranslationCanBeSpokenWithoutPasting() async throws {
        let voice = Recorder()
        voice.alsoPastes = false
        let controller = await controller(PushToTalkControllerTests.FakeTranslation(), voice: voice)
        try await dictate(controller, with: .rightOption)
        #expect(voice.spoken == ["en We have a meeting next Tuesday."])
        #expect(inserter.inserted.isEmpty)
        #expect(controller.lastTranscript == "We have a meeting next Tuesday.")
        #expect(controller.notice == nil)
    }

    /// Only a translation is spoken: not the talk key's dictation, not a translation that
    /// failed its checks, which is pasted as said, and nothing while the switch is off.
    @Test func onlyATranslationIsSpoken() async throws {
        let voice = Recorder()
        voice.alsoPastes = false
        let translation = PushToTalkControllerTests.FakeTranslation(answer: #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday at 3."}"#)
        let controller = await controller(translation, voice: voice)
        try await dictate(controller, with: .rightOption)
        #expect(voice.spoken.isEmpty)
        #expect(inserter.inserted.count == 1)
        #expect(controller.notice == "This dictation was pasted without translation.")
        try await dictate(controller, with: .rightControl)
        #expect(voice.spoken.isEmpty)
        #expect(inserter.inserted.count == 2)
        translation.shared.answer.withLock { $0 = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"# }
        voice.speaks = false
        try await dictate(controller, with: .rightOption)
        #expect(voice.spoken.isEmpty)
        #expect(inserter.inserted.last == "We have a meeting next Tuesday.")
    }

    /// The voice speaks a translation in its target language: Japanese and Spanish too.
    @Test func eachTranslationIsSpokenInItsLanguage() async throws {
        let voice = Recorder()
        let translation = PushToTalkControllerTests.FakeTranslation(answer: #"{"cleaned": "Can you send me the report today?", "translation": "¿Me puedes mandar el reporte hoy?"}"#)
        let spanish = await controller(translation, voice: voice, language: .spanish)
        speech.reply = "Can you send me the report today?"
        try await dictate(spanish, with: .rightOption)
        #expect(voice.spoken == ["es ¿Me puedes mandar el reporte hoy?"])
        translation.shared.answer.withLock { $0 = #"{"cleaned": "ありがとうございます", "translation": "Thank you very much."}"# }
        let japanese = await controller(translation, voice: voice, language: .japanese)
        speech.reply = "ありがとうございます"
        try await dictate(japanese, with: .rightOption)
        #expect(voice.spoken.last == "en Thank you very much.")
        translation.shared.answer.withLock { $0 = #"{"cleaned": "See you tomorrow.", "translation": "また明日。"}"# }
        speech.reply = "See you tomorrow."
        try await dictate(japanese, with: .rightOption)
        #expect(voice.spoken.last == "ja また明日。")
    }
}
