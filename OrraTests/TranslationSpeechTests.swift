import Foundation
import Synchronization
import Testing
@testable import Orra

/// A stand in for the voice model. It records what it was asked to speak and, unless a
/// test says otherwise, streams two short pieces of silence for each text.
final class FakeSynthesizer: SpeechSynthesizer {
    let spoken = Mutex<[String]>([])
    let voices = Mutex<[Double?]>([])
    let transcripts = Mutex<[String?]>([])
    let loads = Mutex(0)
    let unloads = Mutex(0)
    let forgets = Mutex(0)
    let failsLoad = Mutex(false)
    let failsSpeaking = Mutex(false)
    /// Whether it streams, as Qwen3-TTS without a voice sample does.
    let streamsPieces = Mutex(true)
    /// What it makes of a text on its nth try (from 0), in place of the two short pieces.
    let makes = Mutex<(@Sendable (String, Int) -> [SpokenAudio])?>(nil)
    private let tries = Mutex<[String: Int]>([:])

    func streams(voice: VoiceSample?) -> Bool {
        streamsPieces.withLock { $0 }
    }

    func load(model: URL, codec: URL) async throws {
        loads.withLock { $0 += 1 }
        if failsLoad.withLock({ $0 }) { throw TestError() }
    }

    func unload() async {
        unloads.withLock { $0 += 1 }
    }

    func forgetVoice() async {
        forgets.withLock { $0 += 1 }
    }

    func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error> {
        spoken.withLock { $0.append("\(language.rawValue) \(text)") }
        voices.withLock { $0.append(voice?.seconds) }
        transcripts.withLock { $0.append(voice?.transcript) }
        let fails = failsSpeaking.withLock { $0 }
        let attempt = tries.withLock { tries in
            defer { tries[text, default: 0] += 1 }
            return tries[text, default: 0]
        }
        let made = makes.withLock { $0 }.map { $0(text, attempt) }
        return AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: TestError())
                return
            }
            if let made {
                for audio in made {
                    continuation.yield(audio)
                }
                continuation.finish()
                return
            }
            continuation.yield(SpokenAudio(samples: [Float](repeating: 0, count: 240), sampleRate: 24_000))
            continuation.yield(SpokenAudio(samples: [Float](repeating: 0, count: 480), sampleRate: 24_000))
            continuation.finish()
        }
    }
}

/// A stand in for the output device, which records what it was asked to do.
@MainActor
final class FakePlayback: SpeechPlayback {
    private(set) var calls: [String] = []
    var refuses = false

    func start(on device: AudioOutput) throws {
        if refuses { throw SpeechPlayerError.engineFailed }
        calls.append("start \(device.name)")
    }

    func play(_ audio: SpokenAudio) {
        calls.append("play \(audio.samples.count)")
    }

    func finish() async {
        calls.append("finish")
    }

    func stop() {
        calls.append("stop")
    }
}

@MainActor
struct TranslationSpeechTests {
    let synthesizer = FakeSynthesizer()
    let playback = FakePlayback()
    static let speakers = AudioOutput(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    static let orraMicrophone = AudioOutput(id: 2, uid: "io.github.db-ol.Orra.Microphone", name: "Orra Microphone")
    static let folders = VoiceModelFolders(model: URL(fileURLWithPath: "/tmp/model"), codec: URL(fileURLWithPath: "/tmp/codec"))

    private func makeSpeech(
        on: Bool = true,
        outputs: [AudioOutput] = [speakers, orraMicrophone],
        folders: VoiceModelFolders? = folders,
        output: SpeechOutputChoice? = nil,
        withModel: Bool = true,
        transcribeVoice: @escaping (VoiceSample) async throws -> String = { _ in "We met at noon." }
    ) -> TranslationSpeech {
        let speech = TranslationSpeech(
            engines: withModel ? .only(synthesizer) : .none,
            playback: playback,
            outputs: { outputs },
            folders: { folders },
            settings: TranslationSpeech.Settings(isOn: on, alsoPastes: true, output: output),
            dictationPoll: .milliseconds(1)
        )
        speech.transcribeVoice = transcribeVoice
        return speech
    }

    private var spoken: [String] {
        synthesizer.spoken.withLock { $0 }
    }

    /// Each sentence is synthesized and played in order into Orra Microphone, and the device is
    /// let go once everything played. The model loads once.
    @Test func sentencesAreSpokenInOrderIntoOrraMicrophone() async {
        let speech = makeSpeech()
        speech.speak("We have a meeting next Tuesday. Could you send the numbers before then?", in: .english)
        speech.speak("好的，没问题。", in: .chinese)
        await speech.waitUntilDone()
        #expect(spoken == ["en We have a meeting next Tuesday.", "en Could you send the numbers before then?", "zh 好的，没问题。"])
        #expect(playback.calls == [
            "start Orra Microphone", "play 240", "play 480", "play 240", "play 480", "finish", "stop",
            "start Orra Microphone", "play 240", "play 480", "finish", "stop",
        ])
        #expect(synthesizer.loads.withLock { $0 } == 1)
        #expect(speech.state == .idle)
        #expect(speech.problem == nil)
        #expect(speech.isLoaded)
    }

    /// Without Orra Microphone and without a choice, nothing plays: never the speakers by
    /// surprise. A chosen device that is gone is named.
    @Test func withoutADeviceNothingIsSpoken() async {
        let speech = makeSpeech(outputs: [Self.speakers])
        speech.speak("Hello there, everyone.", in: .english)
        await speech.waitUntilDone()
        #expect(spoken.isEmpty)
        #expect(playback.calls.isEmpty)
        #expect(speech.problem == "Choose where Orra speaks the translation in Settings.")

        speech.setOutput(SpeechOutputChoice(uid: "loopback-uid", name: "Loopback Audio"))
        #expect(speech.problem == nil)
        speech.speak("Hello there, everyone.", in: .english)
        await speech.waitUntilDone()
        #expect(spoken.isEmpty)
        #expect(speech.problem == "Loopback Audio is not connected, so the translation was not spoken.")
    }

    @Test func aChosenDeviceIsUsed() async {
        let speech = makeSpeech(output: SpeechOutputChoice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"))
        speech.speak("Hello there, everyone.", in: .english)
        await speech.waitUntilDone()
        #expect(playback.calls.first == "start MacBook Pro Speakers")
    }

    /// Off, or in a build without a voice model, nothing is spoken.
    @Test func offOrWithoutAModelNothingIsSpoken() async {
        let off = makeSpeech(on: false)
        #expect(!off.speaks)
        off.speak("Hello there, everyone.", in: .english)
        await off.waitUntilDone()
        let noModel = makeSpeech(withModel: false)
        #expect(!noModel.canSpeak)
        #expect(!noModel.speaks)
        noModel.speak("Hello there, everyone.", in: .english)
        await noModel.waitUntilDone()
        #expect(spoken.isEmpty)
        #expect(playback.calls.isEmpty)
        #expect(!off.voiceForDictation.speaks())
        let on = makeSpeech()
        #expect(on.voiceForDictation.speaks())
    }

    /// With Also Paste off, the translation is still pasted while it could not be spoken:
    /// no voice model on this Mac, or no device to speak into.
    @Test func aTranslationThatCannotBeSpokenIsStillPasted() {
        let ready = makeSpeech()
        ready.setAlsoPastes(false)
        #expect(!ready.voiceForDictation.alsoPastes())
        let noModel = makeSpeech(folders: nil)
        noModel.setAlsoPastes(false)
        #expect(noModel.voiceForDictation.alsoPastes())
        let noDevice = makeSpeech(outputs: [Self.speakers])
        noDevice.setAlsoPastes(false)
        #expect(noDevice.voiceForDictation.alsoPastes())
        #expect(makeSpeech().voiceForDictation.alsoPastes())
    }

    /// Dictation first: nothing is synthesized while the user dictates.
    @Test func theVoiceWaitsWhileTheUserDictates() async throws {
        let speech = makeSpeech()
        var dictating = true
        speech.isDictating = { dictating }
        speech.speak("We have a meeting next Tuesday.", in: .english)
        try await Task.sleep(for: .milliseconds(50))
        #expect(spoken.isEmpty)
        #expect(synthesizer.loads.withLock { $0 } == 0)
        dictating = false
        await speech.waitUntilDone()
        #expect(spoken == ["en We have a meeting next Tuesday."])
    }

    /// Stop drops what is queued.
    @Test func stopDropsWhatIsQueued() async throws {
        let speech = makeSpeech()
        var dictating = true
        speech.isDictating = { dictating }
        speech.speak("We have a meeting next Tuesday.", in: .english)
        speech.speak("Could you send the numbers before then?", in: .english)
        try await Task.sleep(for: .milliseconds(20))
        speech.stop()
        dictating = false
        await speech.waitUntilDone()
        #expect(spoken.isEmpty)
        #expect(playback.calls == ["stop"])
        // Later translations are spoken again.
        speech.speak("Thanks a lot, everyone.", in: .english)
        await speech.waitUntilDone()
        #expect(spoken == ["en Thanks a lot, everyone."])
    }

    static let threeSeconds = VoiceSample(samples: [Float](repeating: 0.1, count: 48_000), sampleRate: 16_000)

    /// The voice sample goes to the model with every piece, together with what the speech
    /// model heard in it, and once removed, the model's own voice speaks and the model
    /// forgets what it derived from the sample.
    @Test func theVoiceSampleIsUsedUntilRemoved() async throws {
        var heard: [VoiceSample] = []
        let speech = makeSpeech(transcribeVoice: { sample in
            heard.append(sample)
            return "  We met at noon.\n"
        })
        #expect(speech.voiceSeconds == nil)
        await speech.useVoice(Self.threeSeconds)
        #expect(heard == [Self.threeSeconds])
        #expect(speech.voiceSeconds == 3)
        #expect(!speech.isListeningToVoice)
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        speech.forgetVoice()
        #expect(speech.voiceSeconds == nil)
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        #expect(synthesizer.voices.withLock { $0 } == [3, nil])
        #expect(synthesizer.transcripts.withLock { $0 } == ["We met at noon.", nil])
        for _ in 0..<100 where synthesizer.forgets.withLock({ $0 }) < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(synthesizer.forgets.withLock { $0 } == 2)
    }

    /// A sample in which the speech model hears nothing, or one it cannot take, is not
    /// used, the voice before it stays, and Settings says why.
    @Test func aSampleWithoutWordsIsNotUsed() async {
        var answer: Result<String, any Error> = .success("We met at noon.")
        let speech = makeSpeech(transcribeVoice: { _ in try answer.get() })
        await speech.useVoice(Self.threeSeconds)
        #expect(speech.voiceSeconds == 3)

        answer = .success(" … ")
        await speech.useVoice(VoiceSample(samples: [Float](repeating: 0, count: 80_000), sampleRate: 16_000))
        #expect(speech.problem == "Orra heard no speech in the voice sample.")
        #expect(speech.voiceSeconds == 3)

        answer = .failure(TranscriptionError.modelMissing)
        await speech.useVoice(VoiceSample(samples: [Float](repeating: 0.1, count: 80_000), sampleRate: 16_000))
        #expect(speech.problem == "Orra could not listen to the voice sample. Choose it again once the speech model is ready.")
        #expect(speech.voiceSeconds == 3)
        #expect(!speech.isListeningToVoice)

        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        #expect(synthesizer.transcripts.withLock { $0 } == ["We met at noon."])
    }

    /// Remove while the speech model still listens to a sample drops that sample when the
    /// words arrive.
    @Test func removeWhileListeningDropsTheSample() async {
        let gate = AsyncStream<Void>.makeStream()
        let speech = makeSpeech(transcribeVoice: { _ in
            for await _ in gate.stream { break }
            return "We met at noon."
        })
        let listening = Task { await speech.useVoice(Self.threeSeconds) }
        for _ in 0..<100 where !speech.isListeningToVoice {
            await Task.yield()
        }
        #expect(speech.isListeningToVoice)
        speech.forgetVoice()
        #expect(!speech.isListeningToVoice)
        gate.continuation.yield()
        await listening.value
        #expect(speech.voiceSeconds == nil)
        #expect(speech.problem == nil)
    }

    @Test func problemsWithTheModelOrTheDeviceAreShown() async {
        let missing = makeSpeech(folders: nil)
        missing.speak("Hello there, everyone.", in: .english)
        await missing.waitUntilDone()
        #expect(missing.problem == "The voice model is not on this Mac yet.")

        synthesizer.failsLoad.withLock { $0 = true }
        let failing = makeSpeech()
        failing.speak("Hello there, everyone.", in: .english)
        await failing.waitUntilDone()
        #expect(failing.problem == "The voice model could not be loaded.")
        #expect(!failing.isLoaded)
        synthesizer.failsLoad.withLock { $0 = false }

        playback.refuses = true
        failing.speak("Hello there, everyone.", in: .english)
        await failing.waitUntilDone()
        #expect(failing.problem == "Orra could not play into Orra Microphone.")
        playback.refuses = false

        synthesizer.failsSpeaking.withLock { $0 = true }
        failing.speak("Hello there, everyone.", in: .english)
        await failing.waitUntilDone()
        #expect(failing.problem == "The voice model could not speak this translation.")
        #expect(playback.calls.suffix(2) == ["finish", "stop"])
        #expect(failing.state == .idle)
        #expect(spoken.isEmpty == false)
    }

    /// About the length a voice model gives `text`, as a tone loud enough to count as
    /// speech.
    nonisolated static func reading(_ text: String) -> SpokenAudio {
        SpeechCheckTests.tone(seconds: SpeechCheck.expectedSeconds(for: text))
    }

    /// A piece that comes whole is checked before it plays. One that fails is made once
    /// more, and the second try plays.
    @Test func aFailedPieceIsMadeAgain() async {
        synthesizer.streamsPieces.withLock { $0 = false }
        synthesizer.makes.withLock {
            $0 = { text, attempt in
                // Cut off on the first try of the second sentence.
                text.hasPrefix("Could") && attempt == 0 ? [SpeechCheckTests.tone(seconds: 0.3)] : [Self.reading(text)]
            }
        }
        let speech = makeSpeech()
        speech.speak("We have a meeting next Tuesday. Could you send the numbers before then?", in: .english)
        await speech.waitUntilDone()
        #expect(spoken == ["en We have a meeting next Tuesday.", "en Could you send the numbers before then?", "en Could you send the numbers before then?"])
        let first = Self.reading("We have a meeting next Tuesday.").samples.count
        let second = Self.reading("Could you send the numbers before then?").samples.count
        #expect(playback.calls == ["start Orra Microphone", "play \(first)", "play \(second)", "finish", "stop"])
        #expect(speech.problem == nil)
    }

    /// A piece that fails twice is skipped, the rest of the translation is spoken, and the
    /// menu says so. The paste does not depend on it: with Also Paste on, the translation
    /// was pasted whole when the key was released.
    @Test func aPieceThatFailsTwiceIsSkipped() async {
        synthesizer.streamsPieces.withLock { $0 = false }
        synthesizer.makes.withLock {
            $0 = { text, _ in
                // A loop: 7.1 s for a short sentence, as CosyVoice3 once made.
                text.hasPrefix("好的") ? [SpeechCheckTests.tone(seconds: 7.1)] : [Self.reading(text)]
            }
        }
        let speech = makeSpeech()
        #expect(speech.voiceForDictation.alsoPastes())
        speech.speak("好的，我们开始吧。今天先看一下上周的进度。", in: .chinese)
        await speech.waitUntilDone()
        #expect(spoken == ["zh 好的，我们开始吧。", "zh 好的，我们开始吧。", "zh 今天先看一下上周的进度。"])
        let played = Self.reading("今天先看一下上周的进度。").samples.count
        #expect(playback.calls == ["start Orra Microphone", "play \(played)", "finish", "stop"])
        #expect(speech.problem == "The voice model failed twice on a sentence, so Orra skipped it.")
        #expect(speech.state == .idle)
        #expect(speech.voiceForDictation.alsoPastes())
    }

    /// Near silence is not played either.
    @Test func silenceIsNotPlayed() async {
        synthesizer.streamsPieces.withLock { $0 = false }
        synthesizer.makes.withLock {
            $0 = { _, _ in [SpokenAudio(samples: [Float](repeating: 0.001, count: 24_000 * 3), sampleRate: 24_000)] }
        }
        let speech = makeSpeech()
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        #expect(spoken.count == 2)
        #expect(playback.calls == ["start Orra Microphone", "finish", "stop"])
        #expect(speech.problem == "The voice model failed twice on a sentence, so Orra skipped it.")
    }

    /// A streamed piece plays as it comes, so it is not checked for silence, and it is not
    /// made again. Only its length is held: it is cut at the longest its text may run.
    @Test func aStreamedPieceIsCutAtItsLongest() async {
        let text = "Thank you all, see you next week."
        let longest = SpeechCheck.longestSeconds(for: text)
        // Parts of one second, without end.
        synthesizer.makes.withLock {
            $0 = { _, _ in Array(repeating: SpeechCheckTests.tone(seconds: 1), count: 30) }
        }
        let speech = makeSpeech()
        speech.speak(text, in: .english)
        await speech.waitUntilDone()
        #expect(spoken == ["en \(text)"])
        let whole = Int(longest)
        let rest = Int((longest - Double(whole)) * 24_000)
        var expected = ["start Orra Microphone"] + Array(repeating: "play 24000", count: whole)
        if rest > 0 {
            expected.append("play \(rest)")
        }
        #expect(playback.calls == expected + ["finish", "stop"])
        #expect(speech.problem == nil)
    }

    /// A streamed piece of near silence plays as it is.
    @Test func aStreamedPieceIsNotCheckedForSilence() async {
        synthesizer.makes.withLock {
            $0 = { _, _ in [SpokenAudio(samples: [Float](repeating: 0, count: 2_400), sampleRate: 24_000)] }
        }
        let speech = makeSpeech()
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        #expect(spoken.count == 1)
        #expect(playback.calls == ["start Orra Microphone", "play 2400", "finish", "stop"])
    }

    /// Turning it on loads the model ahead of the first translation when the model is in
    /// place, turning it off unloads it, and both are saved.
    @Test func theSwitchLoadsAndUnloadsAndIsSaved() async {
        var saved: [TranslationSpeech.Settings] = []
        let speech = TranslationSpeech(
            engines: .only(synthesizer),
            playback: playback,
            outputs: { [Self.orraMicrophone] },
            folders: { Self.folders },
            save: { saved.append($0) },
            dictationPoll: .milliseconds(1)
        )
        speech.setOn(true)
        await speech.waitUntilDone()
        #expect(synthesizer.loads.withLock { $0 } == 1)
        #expect(speech.isLoaded)
        speech.setOn(false)
        await speech.waitUntilDone()
        #expect(synthesizer.unloads.withLock { $0 } == 1)
        #expect(!speech.isLoaded)
        speech.setAlsoPastes(false)
        speech.setOutput(SpeechOutputChoice(uid: "io.github.db-ol.Orra.Microphone", name: "Orra Microphone"))
        #expect(saved.map(\.isOn) == [true, false, false, false])
        #expect(saved.last == TranslationSpeech.Settings(isOn: false, alsoPastes: false, output: SpeechOutputChoice(uid: "io.github.db-ol.Orra.Microphone", name: "Orra Microphone")))
    }

    /// Without the model's files, turning it on does not report a problem yet.
    @Test func turningOnWithoutTheModelIsQuiet() async {
        let speech = makeSpeech(on: false, folders: nil)
        speech.setOn(true)
        await speech.waitUntilDone()
        #expect(speech.problem == nil)
        #expect(synthesizer.loads.withLock { $0 } == 0)
    }

    @Test func settingsAreSavedWithoutTheVoice() throws {
        let name = "AudioOutputTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // The defaults: off, and the text is pasted too.
        #expect(TranslationSpeech.Settings.load(from: defaults) == TranslationSpeech.Settings(isOn: false, alsoPastes: true, output: nil))
        let chosen = TranslationSpeech.Settings(isOn: true, alsoPastes: false, output: SpeechOutputChoice(uid: "loopback-uid", name: "Loopback Audio"))
        chosen.save(to: defaults)
        #expect(TranslationSpeech.Settings.load(from: defaults) == chosen)
        TranslationSpeech.Settings(isOn: true, alsoPastes: true, output: nil).save(to: defaults)
        #expect(TranslationSpeech.Settings.load(from: defaults).output == nil)
        #expect(defaults.string(forKey: SpeechPreference.outputNameKey) == nil)
        // Only these five keys, so no sample or text can be in the settings.
        let keys = Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
        #expect(keys.isSubset(of: [SpeechPreference.isOnKey, SpeechPreference.alsoPastesKey, SpeechPreference.outputUIDKey, SpeechPreference.outputNameKey, SpeechPreference.voiceModelKey]))
    }
}
