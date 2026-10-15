import Foundation

nonisolated extension ModelManifest {
    /// CosyVoice3 0.5B in the bf16 MLX build from speech-swift's author, the second voice
    /// model, which clones a voice sample more closely than Qwen3-TTS. Apache-2.0. Hugging
    /// Face main as of 2026-10-15, unchanged since 2026-07-06. The folder holds the speech
    /// tokenizer that turns a voice sample into codes, too. Only huggingface.co and
    /// hf-mirror.com carry it, see `VoiceModels.sources`, so the ModelScope revision is
    /// never used.
    static let cosyVoice = ModelManifest(
        id: "aufklarer/CosyVoice3-0.5B-MLX-bf16",
        huggingFaceRevision: "9b210b2381280b3af1c631d474a250e3e46d7017",
        modelScopeRevision: "9b210b2381280b3af1c631d474a250e3e46d7017",
        files: [
            ModelFile(name: "config.json", size: 1_780, sha256: "b6409141dd25b32d45f1c9aedb8d1b8cebe63cf65ea9193d5358ebf4978f9607"),
            ModelFile(name: "tokenizer_config.json", size: 1_287, sha256: "482bd979881423375ca5414e4e0d94cd7c5349dbb17fffd46b4d36d71e62a1bc"),
            ModelFile(name: "merges.txt", size: 1_402_109, sha256: "ac8ff86a72bee70828fbc1119bc4398c6f3a9a6e490d7b0dbe917be025478bd0"),
            ModelFile(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "flow_noise.bin", size: 4_800_000, sha256: "3ebc526a5163d79f14b760e978e05e86dc83d9685f24a537a494cb1a5cf06c6f"),
            ModelFile(name: "hifigan.safetensors", size: 83_086_548, sha256: "840350956a8403245c738504a0da2a0c2047d5e705173930030013f28d4e3a1e", resumable: true),
            ModelFile(name: "speech_tokenizer.safetensors", size: 484_039_728, sha256: "a3b9b816756469673efe84af9190f6cac4a8946cd7a113b76a35375daaea0e26", resumable: true),
            ModelFile(name: "flow.safetensors", size: 664_553_192, sha256: "f1685d7e476295b104a675aa7e25a2572d5858879a4be0dfdd25253215b8e3d4", resumable: true),
            ModelFile(name: "llm.safetensors", size: 1_012_327_296, sha256: "7d40340e3feda51dfe10137bf12690a512a1092d2eccf3b9605357a895c9ba2b", resumable: true),
        ]
    )

    /// CAM++, the speaker encoder CosyVoice3 reads a voice sample with, as a compiled Core
    /// ML model. Apache-2.0. Hugging Face main as of 2026-10-15, unchanged since
    /// 2026-05-28. Only the files of the model, not the README or config.json.
    static let cosyVoiceSpeaker = ModelManifest(
        id: "aufklarer/CamPlusPlus-Speaker-CoreML",
        huggingFaceRevision: "c3cbd83f0c1028cf753b3e3e67639854218206a1",
        modelScopeRevision: "c3cbd83f0c1028cf753b3e3e67639854218206a1",
        files: [
            ModelFile(name: "CamPlusPlus.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "078a62ad867e7b005f4a8a4b4326291b3b6cc88956550a219914d48209998592"),
            ModelFile(name: "CamPlusPlus.mlmodelc/coremldata.bin", size: 381, sha256: "8a92c38810ab12796c1c9c6ff49a47fc3c539dc73fd55f79ae6084c995695b1b"),
            ModelFile(name: "CamPlusPlus.mlmodelc/metadata.json", size: 2_015, sha256: "fab69ba7f236533e3cbb1163f071d8655ef994a6c52ea0e15a17d622e79543a3"),
            ModelFile(name: "CamPlusPlus.mlmodelc/model.mil", size: 755_748, sha256: "bae40fe39195bf878cc28e65eca8924d1a558aa892914fa14a3530b194ed228d"),
            ModelFile(name: "CamPlusPlus.mlmodelc/weights/weight.bin", size: 13_932_672, sha256: "c877516a45280e1f2d8834a905a65a9a45c4007ee3a7b2983b4ebe4586fa2ab2", resumable: true),
        ]
    )
}

#if canImport(CosyVoiceTTS)
import CosyVoiceTTS

/// Owns CosyVoice3 from speech-swift. An actor, so loading and speaking run off the main
/// actor, and the model, which speech-swift says is not thread safe, speaks one piece at
/// a time.
///
/// Written against speech-swift at commit 1f54e56. A cloned voice uses a voice profile,
/// which extractVoiceProfile makes from the voice sample and what is said in it: speech
/// tokenizer codes, a mel spectrogram and a CAM++ speaker vector. The profile is made once
/// per sample, in about 0.04 to 0.3 s, and kept with the sample it came from. A scratch
/// benchmark on 2026-10-14 found a similarity to the sample of 0.82 in the sample's
/// language and 0.76 across languages, against 0.67 and 0.55 for Qwen3-TTS's in context
/// call.
///
/// At that commit nothing streams: synthesizeStream yields one chunk at the end, so every
/// piece, cloned or not, comes back whole. TranslationSpeech cuts the text into sentences
/// first. The call runs on this actor without a pause, so a piece always runs to its end,
/// and everything else that uses the model waits for that end. A stop drops what the
/// piece made.
actor CosyVoiceEngine: SpeechSynthesizer {
    private var model: CosyVoiceTTSModel?
    /// Turns the voice sample into speech codes for the profile.
    private var tokenizer: SpeechTokenizerModel?
    /// Turns the voice sample into a speaker vector for the profile.
    private var speaker: CamPlusPlusSpeaker?
    /// The profile of the voice sample it was made from. Compared with the sample of each
    /// piece, so a piece never speaks in the voice of an older sample.
    private var profile: (sample: VoiceSample, profile: CosyVoiceVoiceProfile)?

    nonisolated enum EngineError: Error {
        /// A voice sample without what is said in it, which the profile needs.
        case noTranscript
    }

    /// `codec` is the folder of the CAM++ speaker encoder, the second download.
    func load(model folder: URL, codec speakerFolder: URL) async throws {
        guard model == nil else { return }
        // From local folders only, with offlineMode, so loading never goes online: every
        // file fromPretrained looks for is in the pinned manifests. It warms the model up,
        // which compiles its Metal shaders, and raises MLX's wired limit to the value the
        // speech model already set (MetalBudget.pinMemory).
        let loaded = try await CosyVoiceTTSModel.fromPretrained(modelId: ModelManifest.cosyVoice.id, cacheDir: folder, offlineMode: true)
        let tokenizer = try SpeechTokenizerModel.fromSafetensors(at: folder.appendingPathComponent("speech_tokenizer.safetensors"))
        let speaker = try await CamPlusPlusSpeaker.fromPretrained(modelId: ModelManifest.cosyVoiceSpeaker.id, cacheDir: speakerFolder, offlineMode: true)
        model = loaded
        self.tokenizer = tokenizer
        self.speaker = speaker
    }

    func unload() async {
        model?.unload()
        model = nil
        tokenizer = nil
        speaker = nil
        profile = nil
    }

    func forgetVoice() async {
        profile = nil
    }

    nonisolated func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(text, language: language, voice: voice, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ text: String, language: TranslationTarget, voice: VoiceSample?, continuation: AsyncThrowingStream<SpokenAudio, any Error>.Continuation) throws {
        guard let model, let tokenizer, let speaker else { throw TranscriptionError.modelMissing }
        try Task.checkCancellation()
        // See VoiceCacheLimit.
        VoiceCacheLimit.begin()
        defer { VoiceCacheLimit.end() }
        // CosyVoice3 reads the language from the text. The tag only keeps the call the same
        // as Qwen3-TTS's.
        let name = Self.languageName(language)
        let samples: [Float]
        if let voice {
            guard !voice.transcript.isEmpty else { throw EngineError.noTranscript }
            let profile = try profile(for: voice, model: model, tokenizer: tokenizer, speaker: speaker)
            samples = model.synthesize(text: text, voiceProfile: profile, language: name)
        } else {
            samples = model.synthesize(text: text, language: name)
        }
        continuation.yield(SpokenAudio(samples: samples, sampleRate: model.config.sampleRate))
    }

    /// The profile of `voice`, made the first time it speaks.
    private func profile(for voice: VoiceSample, model: CosyVoiceTTSModel, tokenizer: SpeechTokenizerModel, speaker: CamPlusPlusSpeaker) throws -> CosyVoiceVoiceProfile {
        if let profile, profile.sample == voice {
            return profile.profile
        }
        let made = try model.extractVoiceProfile(
            audio: voice.samples,
            sampleRate: voice.sampleRate,
            speechTokenizer: tokenizer,
            camppSpeaker: speaker,
            referenceTranscript: voice.transcript
        )
        profile = (voice, made)
        return made
    }

    nonisolated static func languageName(_ language: TranslationTarget) -> String {
        switch language {
        case .english: "english"
        case .chinese: "chinese"
        }
    }
}
#endif
