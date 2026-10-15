import Foundation
import Synchronization
import Testing
@testable import Orra

extension VoiceEngines {
    /// A build with one voice model, `synthesizer`.
    static func only(_ synthesizer: any SpeechSynthesizer, as kind: VoiceEngineKind = .qwen3) -> VoiceEngines {
        VoiceEngines(available: [kind]) { $0 == kind ? synthesizer : nil }
    }
}

/// Which voice model speaks: the one product the build links, or the user's pick when it
/// links both, Qwen3-TTS until then.
@MainActor
struct VoiceEngineChoiceTests {
    @Test func noProductNoModel() {
        #expect(VoiceEngineChoice.resolve(saved: nil, available: []) == nil)
        #expect(VoiceEngineChoice.resolve(saved: .cosyVoice, available: []) == nil)
        #expect(!VoiceEngines.none.offersChoice)
    }

    /// One product is used whatever was saved, for example by a build with the other.
    @Test func oneProductIsUsed() {
        #expect(VoiceEngineChoice.resolve(saved: nil, available: [.qwen3]) == .qwen3)
        #expect(VoiceEngineChoice.resolve(saved: .cosyVoice, available: [.qwen3]) == .qwen3)
        #expect(VoiceEngineChoice.resolve(saved: nil, available: [.cosyVoice]) == .cosyVoice)
        #expect(VoiceEngineChoice.resolve(saved: .qwen3, available: [.cosyVoice]) == .cosyVoice)
    }

    @Test func bothProductsStartWithQwenAndKeepThePick() {
        let both: [VoiceEngineKind] = [.qwen3, .cosyVoice]
        #expect(VoiceEngineChoice.resolve(saved: nil, available: both) == .qwen3)
        #expect(VoiceEngineChoice.resolve(saved: .qwen3, available: both) == .qwen3)
        #expect(VoiceEngineChoice.resolve(saved: .cosyVoice, available: both) == .cosyVoice)
    }

    @Test func eachModelHasItsOwnDownloads() {
        #expect(VoiceEngineKind.qwen3.manifests.model == .qwen3Voice)
        #expect(VoiceEngineKind.qwen3.manifests.codec == .qwen3VoiceCodec)
        #expect(VoiceEngineKind.cosyVoice.manifests.model == .cosyVoice)
        #expect(VoiceEngineKind.cosyVoice.manifests.codec == .cosyVoiceSpeaker)
        #expect(VoiceEngineKind.allCases.map(\.name) == ["Qwen3-TTS", "CosyVoice3"])
    }

    /// CosyVoice3's files are pinned with their hashes, weights last and resumable, and the
    /// speaker encoder's files keep their folders.
    @Test func theCosyVoiceManifestsArePinned() {
        for manifest in [ModelManifest.cosyVoice, .cosyVoiceSpeaker] {
            #expect(manifest.huggingFaceRevision.count == 40)
            #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
            #expect(Set(manifest.files.map(\.name)).count == manifest.files.count)
            #expect(manifest.files.allSatisfy { !$0.name.hasPrefix("/") && !$0.name.contains("..") })
            #expect(manifest.files.last?.resumable == true)
            let large = manifest.files.filter { $0.size > 10_000_000 }
            #expect(large.allSatisfy { $0.resumable })
        }
        #expect(ModelManifest.cosyVoice.files.map(\.name).contains("speech_tokenizer.safetensors"))
        #expect(ModelManifest.cosyVoice.files.map(\.name).contains("flow_noise.bin"))
        #expect(ModelManifest.cosyVoiceSpeaker.files.allSatisfy { $0.name.hasPrefix("CamPlusPlus.mlmodelc/") })
        #expect(ModelManifest.cosyVoice.folderName != ModelManifest.qwen3Voice.folderName)
    }

    @Test func thePickIsSaved() throws {
        let name = "VoiceEngineChoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SpeechPreference.voiceModel(in: defaults) == nil)
        SpeechPreference.saveVoiceModel(.cosyVoice, to: defaults)
        #expect(SpeechPreference.voiceModel(in: defaults) == .cosyVoice)
        #expect(defaults.string(forKey: SpeechPreference.voiceModelKey) == "cosyvoice3")
        defaults.set("some-other-model", forKey: SpeechPreference.voiceModelKey)
        #expect(SpeechPreference.voiceModel(in: defaults) == nil)
        SpeechPreference.saveVoiceModel(nil, to: defaults)
        #expect(defaults.object(forKey: SpeechPreference.voiceModelKey) == nil)
        let settings = TranslationSpeech.Settings(isOn: true, alsoPastes: true, output: nil, voiceModel: .qwen3)
        settings.save(to: defaults)
        #expect(TranslationSpeech.Settings.load(from: defaults) == settings)
    }
}

/// Voice model in Settings, with two stand in models.
@MainActor
struct VoiceEngineSwitchTests {
    let qwen = FakeSynthesizer()
    let cosy = FakeSynthesizer()
    let playback = FakePlayback()

    private var both: VoiceEngines {
        VoiceEngines(available: [.qwen3, .cosyVoice]) { [qwen, cosy] kind in
            kind == .qwen3 ? qwen : cosy
        }
    }

    private func makeSpeech(engines: VoiceEngines? = nil, saved: VoiceEngineKind? = nil, save: @escaping (TranslationSpeech.Settings) -> Void = { _ in }) -> TranslationSpeech {
        let speech = TranslationSpeech(
            engines: engines ?? both,
            playback: playback,
            outputs: { [TranslationSpeechTests.orraMicrophone] },
            folders: { TranslationSpeechTests.folders },
            settings: TranslationSpeech.Settings(isOn: true, alsoPastes: true, output: nil, voiceModel: saved),
            save: save,
            dictationPoll: .milliseconds(1)
        )
        speech.transcribeVoice = { _ in "We met at noon." }
        return speech
    }

    @Test func bothLinkedOffersAChoiceAndStartsWithQwen() async {
        let speech = makeSpeech()
        #expect(speech.engine == .qwen3)
        #expect(speech.engineChoices == [.qwen3, .cosyVoice])
        speech.speak("Hello there.", in: .english)
        await speech.waitUntilDone()
        #expect(qwen.spoken.withLock { $0 } == ["en Hello there."])
        #expect(cosy.spoken.withLock { $0 }.isEmpty)
    }

    @Test func theSavedPickSpeaks() async {
        let speech = makeSpeech(saved: .cosyVoice)
        #expect(speech.engine == .cosyVoice)
        speech.speak("Hello there.", in: .english)
        await speech.waitUntilDone()
        #expect(cosy.spoken.withLock { $0 } == ["en Hello there."])
        #expect(qwen.loads.withLock { $0 } == 0)
    }

    /// With one product there is nothing to pick, and Settings shows no picker.
    @Test func oneLinkedOffersNoChoice() {
        let speech = makeSpeech(engines: .only(cosy, as: .cosyVoice), saved: .qwen3)
        #expect(speech.engine == .cosyVoice)
        #expect(speech.engineChoices.isEmpty)
        #expect(speech.canSpeak)
        let none = makeSpeech(engines: VoiceEngines.none)
        #expect(none.engine == nil)
        #expect(!none.canSpeak)
    }

    /// Picking the other model unloads the old one, loads the new one, keeps the voice
    /// sample and its transcript for the new one, saves the pick and swaps the downloads.
    @Test func pickingTheOtherModelSwitches() async {
        var saved: [TranslationSpeech.Settings] = []
        var changes: [VoiceEngineKind] = []
        let speech = makeSpeech(save: { saved.append($0) })
        speech.onEngineChange = { changes.append($0) }
        await speech.useVoice(VoiceSample(samples: [Float](repeating: 0.1, count: 48_000), sampleRate: 16_000))
        speech.speak("Hello there.", in: .english)
        await speech.waitUntilDone()
        #expect(speech.isLoaded)

        speech.setEngine(.cosyVoice)
        #expect(speech.engine == .cosyVoice)
        #expect(changes == [.cosyVoice])
        #expect(saved.last?.voiceModel == .cosyVoice)
        speech.speak("你好。", in: .chinese)
        await speech.waitUntilDone()
        #expect(qwen.unloads.withLock { $0 } == 1)
        #expect(cosy.loads.withLock { $0 } == 1)
        #expect(cosy.spoken.withLock { $0 } == ["zh 你好。"])
        #expect(cosy.transcripts.withLock { $0 } == ["We met at noon."])
        #expect(speech.isLoaded)

        // The same pick again, or a model the build lacks, changes nothing.
        speech.setEngine(.cosyVoice)
        #expect(changes == [.cosyVoice])
        let single = makeSpeech(engines: .only(qwen))
        single.setEngine(.cosyVoice)
        #expect(single.engine == .qwen3)
    }

    /// A pick while a translation is queued stops it, so the old model does not speak it
    /// after the pick.
    @Test func aPickStopsWhatIsQueued() async {
        let speech = makeSpeech()
        var dictating = true
        speech.isDictating = { dictating }
        speech.speak("Hello there.", in: .english)
        speech.setEngine(.cosyVoice)
        dictating = false
        await speech.waitUntilDone()
        #expect(qwen.spoken.withLock { $0 }.isEmpty)
        #expect(cosy.spoken.withLock { $0 }.isEmpty)
    }
}

/// The downloads follow the voice model.
@MainActor
struct VoiceModelsSelectTests {
    @Test func selectSwapsTheDownloads() {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let models = VoiceModels(kind: .qwen3) { manifest in
            ModelInstaller(manifest: manifest, folders: temporary.folders, environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in nil }, sleep: { _ in }))
        }
        #expect(models.model.manifest == .qwen3Voice)
        #expect(models.codec.manifest == .qwen3VoiceCodec)
        let before = models.model
        models.select(.qwen3)
        #expect(models.model === before)
        models.select(.cosyVoice)
        #expect(models.kind == .cosyVoice)
        #expect(models.model.manifest == .cosyVoice)
        #expect(models.codec.manifest == .cosyVoiceSpeaker)
        #expect(models.folders == nil)
        #expect(models.totalBytes == ModelManifest.cosyVoice.totalBytes + ModelManifest.cosyVoiceSpeaker.totalBytes)
    }
}
