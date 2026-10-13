import Foundation
import Qwen3ASR

/// Owns Qwen3-ASR from speech-swift. An actor, so loading and transcribing run off the
/// main actor, and the model, which speech-swift says is not thread safe, serves one
/// dictation at a time.
///
/// Written against speech-swift at commit 1f54e56. Not behind #if canImport(Qwen3ASR) on
/// purpose: without the package the build fails, instead of the engine and its test
/// silently dropping out of the build.
actor Qwen3Engine {
    private var model: Qwen3ASRModel?
    private let folder: @Sendable () -> URL?
    private let modelID: String

    /// - Parameters:
    ///   - folder: The folder to load the model from, or nil while it is not there. The app
    ///     passes the folder ModelInstaller fills. The real model tests pass the copy on
    ///     this Mac.
    ///   - modelID: The Hugging Face ID of the build in the folder. speech-swift reads the
    ///     model size and the quantization bits from it. The app uses SpeechModel.id. The
    ///     speech corpus evaluation passes another to try another build.
    init(folder: @escaping @Sendable () -> URL? = { SpeechModel.installedFolder() }, modelID: String = SpeechModel.id) {
        self.folder = folder
        self.modelID = modelID
    }

    func load() async throws {
        guard model == nil else { return }
        guard let folder = folder() else { throw TranscriptionError.modelMissing }
        // Offline mode keeps the load from touching the network, and with the folder given
        // speech-swift makes no cache folder of its own. Loading also caps MLX's buffer
        // cache (speech-swift pull request 498), so memory stays bounded across many
        // dictations. It also raises MLX's wired limit (MetalBudget.pinMemory in
        // speech-swift), so the model's MLX buffers stay wired in memory while Orra runs.
        // That last point is read from the source, not measured.
        let loaded = try await Qwen3ASRModel.fromPretrained(modelId: modelID, cacheDir: folder, offlineMode: true)
        // One second of silence before the first dictation. MLX reads the weights only when
        // they are first used. In a benchmark on 2026-10-05, the first launch of a program
        // with a freshly compiled MLX Metal library also took about 2 s for its first
        // transcription and later ones about 0.3 s, probably Metal compiling GPU programs.
        // Silence gives no text, so this only moves such one time costs from the user's first
        // dictation to the launch.
        _ = run(loaded, on: [Float](repeating: 0, count: RecordingLimits.sampleRate))
        model = loaded
    }

    /// - Parameters:
    ///   - context: Words the speech is likely to contain, one per line, which
    ///     speech-swift puts in the prompt's system turn. The app passes the user's
    ///     vocabulary. ContextEvaluationTests measures what a vocabulary does.
    ///   - language: The language the model must write, or nil to let it choose.
    func transcribe(_ samples: [Float], context: String? = nil, language: SpeechLanguage? = nil) throws -> String {
        guard let model else { throw TranscriptionError.modelMissing }
        guard !samples.isEmpty else { throw TranscriptionError.noAudio }
        return run(model, on: samples, context: context, language: language)
    }

    private func run(_ model: Qwen3ASRModel, on samples: [Float], context: String? = nil, language: SpeechLanguage? = nil) -> String {
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        // No language hint by default: docs/asr-baseline.md shows that a fixed hint hurts
        // mixed Chinese and English. LanguageGuard asks for one only when the model chose
        // a language other than these two. The token budget grows with the length of the audio.
        // Use the options overload on purpose. The shorter overload bans any repeated
        // three token sequence once audio passes 15 seconds, which changes repeated
        // numbers and words. Loops are cut by TranscriptGuard and the token budget instead.
        let options = Qwen3DecodingOptions(
            maxTokens: max(448, Int(seconds * 12)),
            language: language?.rawValue,
            context: context,
            longInputThresholdSeconds: .infinity
        )
        return model.transcribe(audio: samples, sampleRate: RecordingLimits.sampleRate, options: options)
    }
}

/// A language Qwen3-ASR can be told to write, by the name its prompt uses.
nonisolated enum SpeechLanguage: String, Sendable {
    case chinese = "Chinese"
    case english = "English"
}

extension Transcription {
    static func qwen3() -> Transcription {
        let engine = Qwen3Engine()
        return Transcription(
            load: { try await engine.load() },
            transcribe: { samples, context, language in try await engine.transcribe(samples, context: context, language: language) }
        )
    }
}
