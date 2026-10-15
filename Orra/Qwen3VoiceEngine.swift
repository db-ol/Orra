import Foundation

nonisolated extension ModelManifest {
    /// Qwen3-TTS 12Hz 0.6B Base in the 8 bit MLX build from speech-swift's author, the
    /// voice that speaks a translation. Apache-2.0. Hugging Face main as of 2026-10-14. The
    /// Base model clones a voice from a sample, and speaks Chinese and English. Only
    /// huggingface.co and hf-mirror.com carry it, see `VoiceModels.sources`, so the
    /// ModelScope revision is never used.
    static let qwen3Voice = ModelManifest(
        id: "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-8bit",
        huggingFaceRevision: "2a20f4adf0436810367cea5a51aa7eb1bc50b6d8",
        modelScopeRevision: "2a20f4adf0436810367cea5a51aa7eb1bc50b6d8",
        files: [
            ModelFile(name: "config.json", size: 431, sha256: "cf55a8f542f56123b253833c77cde387c8953a1b9454c11c735880edeb835e39"),
            ModelFile(name: "tokenizer_config.json", size: 7_344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
            ModelFile(name: "model.safetensors.index.json", size: 77_731, sha256: "7829f1cc24f5cbd7d7a3ba888bb08c7cf52d82ba79a4f0f3756d41f8bf5e52b4"),
            ModelFile(name: "merges.txt", size: 1_671_839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
            ModelFile(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "model.safetensors", size: 1_304_461_214, sha256: "9488e7005cc0cf44f8804eb543668d0763bb1c649ce6f1eddc663519524b3182", resumable: true),
        ]
    )

    /// The speech tokenizer of Qwen3-TTS, whose decoder turns the voice model's codes into
    /// sound. Apache-2.0. Hugging Face main as of 2026-10-14.
    static let qwen3VoiceCodec = ModelManifest(
        id: "Qwen/Qwen3-TTS-Tokenizer-12Hz",
        huggingFaceRevision: "7dd38ad4e9bad454aae9cd937d0cd577604fe229",
        modelScopeRevision: "7dd38ad4e9bad454aae9cd937d0cd577604fe229",
        files: [
            ModelFile(name: "configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            ModelFile(name: "preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
            ModelFile(name: "config.json", size: 2_336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            ModelFile(name: "model.safetensors", size: 682_293_092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258", resumable: true),
        ]
    )
}

#if canImport(Qwen3TTS)
import AudioCommon
import Qwen3TTS

/// Owns Qwen3-TTS from speech-swift. An actor, so loading and speaking run off the main
/// actor, and the model, which speech-swift says is not thread safe, speaks one piece at
/// a time.
///
/// Written against speech-swift at commit 1f54e56. A cloned voice uses the in context
/// call, synthesizeWithVoiceCloneICL, which reads the voice sample as codes of the speech
/// tokenizer together with what is said in it. A scratch benchmark on 2026-10-14 found
/// that the other clone call, synthesizeWithVoiceClone, which takes only a speaker vector,
/// does not reproduce the voice at that commit (similarity 0.27, about that of another
/// speaker), while the in context call reaches 0.67 to 0.70 in the sample's language. At
/// that commit a cloned voice is not streamed: the call returns a whole piece, so
/// TranslationSpeech cuts the text into sentences first. Without a voice sample the model
/// streams, and the first sound of a piece comes after a few frames.
///
/// The stream is made in a task of speech-swift's own, outside this actor, and ending the
/// stream early only asks that task to stop. So a piece is always streamed to its end, and
/// everything else that uses the model waits for that end first, see `settle`. A stop
/// drops what is left of the piece, like a cloned piece, which cannot stop midway either.
actor Qwen3VoiceEngine: SpeechSynthesizer {
    private var model: Qwen3TTSModel?
    /// The encoder half of the speech tokenizer, which turns the voice sample into codes for
    /// the in context clone call. Its weights sit in the same file as the decoder's.
    private var encoder: SpeechTokenizerEncoder?
    /// The stream of the piece being spoken without a voice sample, until it ended.
    private var streaming: Task<Void, Never>?

    nonisolated enum EngineError: Error {
        /// A voice sample without what is said in it, which the clone call needs.
        case noTranscript
    }

    func load(model folder: URL, codec: URL) async throws {
        await settle()
        guard model == nil else { return }
        // From local folders only, so loading never goes online. speech-swift's
        // fromPretrainedWithEncoder would do the same as these lines, but it resolves
        // its folders through a download cache. No change to MLX's wired memory limit,
        // which the speech model already raised.
        let loaded = try Qwen3TTSModel.fromLocal(modelDirectory: folder, tokenizerDirectory: codec, wiredMemoryPolicy: .none)
        let encoder = SpeechTokenizerEncoder(config: loaded.config.speechTokenizerDecoder)
        try TTSWeightLoader.loadSpeechTokenizerEncoderWeights(into: encoder, from: codec)
        model = loaded
        self.encoder = encoder
    }

    func unload() async {
        await settle()
        model?.unload()
        model = nil
        encoder = nil
    }

    func forgetVoice() async {
        await settle()
        model?.clearReferenceAudioCache()
    }

    /// Waits until no stream uses the model, also one that began while this waited.
    private func settle() async {
        while let current = streaming {
            await current.value
            if streaming == current {
                streaming = nil
            }
        }
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

    private func run(_ text: String, language: TranslationTarget, voice: VoiceSample?, continuation: AsyncThrowingStream<SpokenAudio, any Error>.Continuation) async throws {
        await settle()
        guard let model, let encoder else { throw TranscriptionError.modelMissing }
        let name = Self.languageName(language)
        // See VoiceCacheLimit.
        VoiceCacheLimit.begin()
        defer { VoiceCacheLimit.end() }
        if let voice {
            guard !voice.transcript.isEmpty else { throw EngineError.noTranscript }
            try Task.checkCancellation()
            let samples = model.synthesizeWithVoiceCloneICL(
                text: text,
                referenceAudio: voice.samples,
                referenceSampleRate: voice.sampleRate,
                referenceText: voice.transcript,
                language: name,
                codecEncoder: encoder
            )
            continuation.yield(SpokenAudio(samples: samples, sampleRate: model.sampleRate))
        } else {
            let stream = model.synthesizeStream(text: text, language: name, streaming: .lowLatency, languageExplicit: true)
            // Not a child task, so a stop does not end the stream before the model is done
            // with it. After a stop the continuation drops what comes.
            let reading = Task<Void, Never> {
                do {
                    for try await chunk in stream {
                        continuation.yield(SpokenAudio(samples: chunk.samples, sampleRate: chunk.sampleRate))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            streaming = reading
            await reading.value
        }
    }

    /// The language tags Qwen3-TTS takes.
    nonisolated static func languageName(_ language: TranslationTarget) -> String {
        switch language {
        case .english: "english"
        case .chinese: "chinese"
        }
    }
}
#endif
