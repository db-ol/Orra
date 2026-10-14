import AudioCommon
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
    /// The same vocabulary speech-swift reads, for PrefixedDecoder. Nil when the folder
    /// has no vocab.json, and then no hypotheses are made.
    private var tokenizer: Qwen3Tokenizer?
    /// The latest hypothesis of the dictation in progress, see `hypothesize`.
    private var hypothesis: Hypothesis?

    private struct Hypothesis {
        var context: String?
        var sampleCount: Int
        var tokens: [Int32]
    }
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
        let vocabulary = folder.appendingPathComponent("vocab.json")
        if FileManager.default.fileExists(atPath: vocabulary.path) {
            let loadedTokenizer = Qwen3Tokenizer()
            try loadedTokenizer.load(from: vocabulary)
            tokenizer = loadedTokenizer
        }
        model = loaded
    }

    /// - Parameters:
    ///   - context: Words the speech is likely to contain, one per line, which
    ///     speech-swift puts in the prompt's system turn. The app passes the user's
    ///     vocabulary. ContextEvaluationTests measures what a vocabulary does.
    ///   - language: The language the model must write, or nil to let it choose.
    ///
    /// When `hypothesize` left a hypothesis of the first part of these samples with the
    /// same context, and no language is asked for, the hypothesis without its last tokens
    /// (HypothesisPrefix) starts the answer, so only the rest is generated. The hypothesis
    /// is used once.
    func transcribe(_ samples: [Float], context: String? = nil, language: SpeechLanguage? = nil) throws -> String {
        guard let model else { throw TranscriptionError.modelMissing }
        guard !samples.isEmpty else { throw TranscriptionError.noAudio }
        if language == nil, let tokenizer, let earlier = hypothesis, earlier.context == context, earlier.sampleCount <= samples.count {
            hypothesis = nil
            let prefix = HypothesisPrefix.cut(earlier.tokens)
            if !prefix.isEmpty {
                let tokens = try PrefixedDecoder.decode(model: model, tokenizer: tokenizer, samples: samples, context: context, language: nil, prefix: prefix)
                return PrefixedDecoder.text(of: tokens, tokenizer: tokenizer)
            }
        }
        return run(model, on: samples, context: context, language: language)
    }

    /// Transcribes the audio recorded so far while the key is still held, when the GPU is
    /// otherwise idle, and keeps the tokens for the final pass in `transcribe`. A hypothesis
    /// with the same context from earlier in the hold starts this one the same way. Returns
    /// nothing, and the text is never logged. Throws CancellationError between tokens when
    /// the task is cancelled, and the earlier hypothesis then stays.
    func hypothesize(_ samples: [Float], context: String?) throws {
        guard let model, let tokenizer, !samples.isEmpty else { return }
        var prefix: [Int32] = []
        if let earlier = hypothesis, earlier.context == context, earlier.sampleCount <= samples.count {
            prefix = HypothesisPrefix.cut(earlier.tokens)
        }
        let tokens = try PrefixedDecoder.decode(model: model, tokenizer: tokenizer, samples: samples, context: context, language: nil, prefix: prefix)
        hypothesis = Hypothesis(context: context, sampleCount: samples.count, tokens: tokens)
    }

    /// Drops the hypothesis, at the start of each hold, so none outlives its dictation.
    func forgetHypothesis() {
        hypothesis = nil
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
            transcribe: { samples, context, language in try await engine.transcribe(samples, context: context, language: language) },
            hypothesize: { samples, context in try await engine.hypothesize(samples, context: context) },
            forgetHypothesis: { await engine.forgetHypothesis() }
        )
    }
}
