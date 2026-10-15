import Foundation
import Synchronization
import Testing
@testable import Orra

/// A stand in for the voice model. It records what it was asked to speak and gives back
/// two short pieces of silence for each text.
final class FakeSynthesizer: SpeechSynthesizer {
    let spoken = Mutex<[String]>([])
    let voices = Mutex<[Double?]>([])
    let loads = Mutex(0)
    let unloads = Mutex(0)
    let forgets = Mutex(0)
    let failsLoad = Mutex(false)
    let failsSpeaking = Mutex(false)

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
        let fails = failsSpeaking.withLock { $0 }
        return AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: TestError())
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
    static let orraVoice = AudioOutput(id: 2, uid: "OrraVoice_UID", name: "Orra Voice")
    static let folders = VoiceModelFolders(model: URL(fileURLWithPath: "/tmp/model"), codec: URL(fileURLWithPath: "/tmp/codec"))

    private func makeSpeech(
        on: Bool = true,
        outputs: [AudioOutput] = [speakers, orraVoice],
        folders: VoiceModelFolders? = folders,
        output: SpeechOutputChoice? = nil,
        withModel: Bool = true
    ) -> TranslationSpeech {
        TranslationSpeech(
            synthesizer: withModel ? synthesizer : nil,
            playback: playback,
            outputs: { outputs },
            folders: { folders },
            settings: TranslationSpeech.Settings(isOn: on, alsoPastes: true, output: output),
            dictationPoll: .milliseconds(1)
        )
    }

    private var spoken: [String] {
        synthesizer.spoken.withLock { $0 }
    }

    /// Each sentence is synthesized and played in order into Orra Voice, and the device is
    /// let go once everything played. The model loads once.
    @Test func sentencesAreSpokenInOrderIntoOrraVoice() async {
        let speech = makeSpeech()
        speech.speak("We have a meeting next Tuesday. Could you send the numbers before then?", in: .english)
        speech.speak("好的，没问题。", in: .chinese)
        await speech.waitUntilDone()
        #expect(spoken == ["en We have a meeting next Tuesday.", "en Could you send the numbers before then?", "zh 好的，没问题。"])
        #expect(playback.calls == [
            "start Orra Voice", "play 240", "play 480", "play 240", "play 480", "finish", "stop",
            "start Orra Voice", "play 240", "play 480", "finish", "stop",
        ])
        #expect(synthesizer.loads.withLock { $0 } == 1)
        #expect(speech.state == .idle)
        #expect(speech.problem == nil)
        #expect(speech.isLoaded)
    }

    /// Without Orra Voice and without a choice, nothing plays: never the speakers by
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

    /// The voice sample goes to the model with every piece, and once removed, the model's
    /// own voice speaks and the model forgets what it derived from the sample.
    @Test func theVoiceSampleIsUsedUntilRemoved() async throws {
        let speech = makeSpeech()
        #expect(speech.voiceSeconds == nil)
        speech.useVoice(VoiceSample(samples: [Float](repeating: 0.1, count: 48_000), sampleRate: 16_000))
        #expect(speech.voiceSeconds == 3)
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        speech.forgetVoice()
        #expect(speech.voiceSeconds == nil)
        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
        #expect(synthesizer.voices.withLock { $0 } == [3, nil])
        for _ in 0..<100 where synthesizer.forgets.withLock({ $0 }) < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(synthesizer.forgets.withLock { $0 } == 2)
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
        #expect(failing.problem == "Orra could not play into Orra Voice.")
        playback.refuses = false

        synthesizer.failsSpeaking.withLock { $0 = true }
        failing.speak("Hello there, everyone.", in: .english)
        await failing.waitUntilDone()
        #expect(failing.problem == "The voice model could not speak this translation.")
        #expect(playback.calls.suffix(2) == ["finish", "stop"])
        #expect(failing.state == .idle)
        #expect(spoken.isEmpty == false)
    }

    /// Turning it on loads the model ahead of the first translation when the model is in
    /// place, turning it off unloads it, and both are saved.
    @Test func theSwitchLoadsAndUnloadsAndIsSaved() async {
        var saved: [TranslationSpeech.Settings] = []
        let speech = TranslationSpeech(
            synthesizer: synthesizer,
            playback: playback,
            outputs: { [Self.orraVoice] },
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
        speech.setOutput(SpeechOutputChoice(uid: "OrraVoice_UID", name: "Orra Voice"))
        #expect(saved.map(\.isOn) == [true, false, false, false])
        #expect(saved.last == TranslationSpeech.Settings(isOn: false, alsoPastes: false, output: SpeechOutputChoice(uid: "OrraVoice_UID", name: "Orra Voice")))
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
        // Only these four keys, so no sample or text can be in the settings.
        let keys = Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
        #expect(keys.isSubset(of: [SpeechPreference.isOnKey, SpeechPreference.alsoPastesKey, SpeechPreference.outputUIDKey, SpeechPreference.outputNameKey]))
    }
}
