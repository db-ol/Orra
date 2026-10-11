import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

extension Logger {
    /// Loading and running the cleanup model. Timings, token counts and guard outcomes only,
    /// never text.
    nonisolated static let rewrite = Logger(subsystem: "io.github.db-ol.Orra", category: "rewrite")
}

nonisolated extension ModelManifest {
    /// Qwen3 4B Instruct 2507 in the 4 bit MLX build, for cleaning up dictations. Apache-2.0.
    /// Hugging Face main as of 2026-10-10, where only tokenizer_config.json changed after the
    /// upload. ModelScope's mirror in the mlx-community organization lists the same sizes and
    /// SHA-256 values at its commit, and hf-mirror.com serves the Hugging Face commit.
    /// tokenizer.json is what CleanupTokenizer reads. chat_template.jinja and the index are
    /// left out, since Orra builds the prompt itself and the weights are in one file.
    static let qwen3Cleanup = ModelManifest(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        huggingFaceRevision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        modelScopeRevision: "ec7ca96008a45bebdd03ad3d09d86f6e61a3e4af",
        files: [
            ModelFile(name: "config.json", size: 938, sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
            ModelFile(name: "generation_config.json", size: 238, sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
            ModelFile(name: "tokenizer_config.json", size: 5_440, sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
            ModelFile(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ModelFile(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "tokenizer.json", size: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "model.safetensors", size: 2_263_022_417, sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f", resumable: true),
        ]
    )
}

nonisolated extension ModelFolders {
    /// Where the cleanup model goes: its own folder next to the speech model's, in
    /// ~/Library/Application Support/io.github.db-ol.Orra/Models. No older copy to reuse.
    static var liveCleanup: ModelFolders {
        ModelFolders(models: live.models, oldCopies: [])
    }
}

/// Owns the cleanup model. An actor, so loading and generating run off the main actor and
/// one cleanup runs at a time. Loaded while cleanup is on, unloaded when it is turned off.
///
/// Written against mlx-swift-lm 3.31.4.
actor RewriteEngine {
    /// What one cleanup produced, for the caller to parse and check.
    struct Completion: Sendable {
        /// The prefill and what the model wrote after it.
        let answer: String
        let promptTokens: Int
        let generatedTokens: Int
    }

    private var context: ModelContext?

    var isLoaded: Bool {
        context != nil
    }

    /// Loads the model from an installed folder and runs one short cleanup, so the first
    /// dictation does not pay for compiling GPU programs. Reads local files only.
    func load(from folder: URL) async throws {
        guard context == nil else { return }
        let started = ContinuousClock.now
        let loaded = try await LLMModelFactory.shared.load(from: folder, using: CleanupTokenizerLoader())
        context = loaded
        do {
            _ = try generate("好的。", maximumTokens: 4)
        } catch {
            unload()
            throw error
        }
        Logger.rewrite.notice("Cleanup model loaded and warmed up in \(started.duration(to: .now), privacy: .public)")
    }

    /// Drops the model and the GPU buffers MLX keeps for reuse.
    func unload() {
        guard context != nil else { return }
        context = nil
        Memory.clearCache()
        Logger.rewrite.notice("Cleanup model unloaded")
    }

    /// Runs the cleanup prompt on a transcript. Greedy, so the same text always gets the
    /// same answer. Stops early when the task is cancelled, see CleanupStep.
    func cleanUp(_ text: String) throws -> Completion {
        guard let context else { throw RewriteError.notLoaded }
        let inputTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count
        return try generate(text, maximumTokens: RewritePrompt.maximumTokens(inputTokens: inputTokens))
    }

    private func generate(_ text: String, maximumTokens: Int) throws -> Completion {
        guard let context else { throw RewriteError.notLoaded }
        let started = ContinuousClock.now
        let prompt = context.tokenizer.encode(text: RewritePrompt.text(for: text), addSpecialTokens: false)
        // The end of turn tokens from generation_config.json and the tokenizer.
        var stop = context.configuration.eosTokenIds
        if let end = context.tokenizer.eosTokenId {
            stop.insert(end)
        }
        let parameters = GenerateParameters(maxTokens: maximumTokens, temperature: 0)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(prompt)), model: context.model, parameters: parameters)
        let prefilled = ContinuousClock.now
        var generated: [Int] = []
        var reason = "the token limit"
        while let token = iterator.next() {
            if stop.contains(token) {
                reason = "the end of the answer"
                break
            }
            generated.append(token)
            if Task.isCancelled {
                reason = "cancellation"
                break
            }
        }
        // The iterator evaluates ahead. Let that finish before the next use of MLX.
        Stream().synchronize()
        let answer = RewritePrompt.prefill + context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
        Logger.rewrite.notice("Cleanup ran in \(started.duration(to: .now), privacy: .public): \(prompt.count, privacy: .public) prompt tokens in \(started.duration(to: prefilled), privacy: .public), \(generated.count, privacy: .public) of at most \(maximumTokens, privacy: .public) tokens written, stopped by \(reason, privacy: .public)")
        return Completion(answer: answer, promptTokens: prompt.count, generatedTokens: generated.count)
    }
}

nonisolated enum RewriteError: Error, Equatable {
    case notLoaded
}

/// What PushToTalkController needs from the cleanup model. Closures, so tests pass fakes.
struct CleanupModel {
    /// Whether cleanup is on and the model is loaded, so a cleanup can start at once.
    var isReady: () -> Bool
    /// The model's answer for a transcript, see RewriteEngine.cleanUp.
    var complete: @Sendable (String) async throws -> String

    /// No cleanup, for tests and previews.
    static let off = CleanupModel(isReady: { false }, complete: { _ in throw RewriteError.notLoaded })
}

/// The cleanup step after the rule steps: runs the model, reads its answer and checks it.
/// Anything other than a cleanup that passes every check gives back the text it was given,
/// so the model can only ever remove fillers and apply corrections, never lose a dictation.
nonisolated enum CleanupStep {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The model's cleanup passed the checks and differs from the text.
        case cleaned
        /// The model gave the text back as it was.
        case unchanged
        /// The answer was not the JSON object the prompt asks for.
        case unreadable
        case heldBack(RewriteGuard.Failure)
        case timedOut
        case failed

        /// For the log, without any text.
        var logName: String {
            switch self {
            case .cleaned: "cleaned"
            case .unchanged: "unchanged"
            case .unreadable: "answer not readable"
            case .heldBack(let failure): "held back by the \(failure.logName) check"
            case .timedOut: "timed out"
            case .failed: "failed"
            }
        }
    }

    /// The longest Orra waits for a cleanup of this text before it pastes the text without
    /// it. The model writes the whole text again, so the time grows with its length. On an
    /// M5 Pro, CleanupModelEvaluationTests measured 0.7 s for 46 Chinese characters, 3.9 s
    /// for 400 and 4.5 s for 905 English ones, about 60 written tokens a second. This
    /// allows about twice that, so a slower Mac still gets most cleanups.
    static func timeout(for text: String) -> Duration {
        .seconds(2) + .milliseconds(15) * text.count
    }

    /// The longest text Orra cleans up, in characters. A longer one would keep the user
    /// waiting several seconds for the paste, so it is pasted without cleanup.
    static let maximumLength = 400

    /// Whether a text is worth a cleanup: at least three letters or digits, since a word or
    /// two has nothing to clean up, and no longer than `maximumLength`.
    static func isWorthCleaning(_ text: String) -> Bool {
        text.count <= maximumLength
            && text.unicodeScalars.lazy.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.prefix(3).count == 3
    }

    /// The text to paste and what happened. Logs the outcome and the time, never text.
    @concurrent
    static func run(_ text: String, timeout: Duration? = nil, complete: @escaping @Sendable (String) async throws -> String) async -> (text: String, outcome: Outcome) {
        let started = ContinuousClock.now
        let work = Task { try await complete(text) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout ?? Self.timeout(for: text))
            } catch {
                return false
            }
            work.cancel()
            return true
        }
        let result = await work.result
        timer.cancel()
        let timedOut = await timer.value
        let outcome: Outcome
        var cleaned = text
        if timedOut {
            outcome = .timedOut
        } else {
            switch result {
            case .success(let answer):
                if let parsed = RewritePrompt.parse(answer) {
                    if parsed.isEmpty {
                        // Never paste nothing because of the model.
                        outcome = .heldBack(.empty)
                    } else if let failure = RewriteGuard.check(source: text, output: parsed) {
                        outcome = .heldBack(failure)
                    } else if parsed == text {
                        outcome = .unchanged
                    } else {
                        outcome = .cleaned
                        cleaned = parsed
                    }
                } else {
                    outcome = .unreadable
                }
            case .failure(let error):
                outcome = .failed
                Logger.rewrite.error("Cleanup failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        Logger.rewrite.notice("Cleanup \(outcome.logName, privacy: .public) after \(started.duration(to: .now), privacy: .public)")
        return (cleaned, outcome)
    }
}

/// Whether the user turned cleanup on. Off until they do.
nonisolated enum CleanupPreference {
    static let defaultsKey = "cleansUpWithLocalModel"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}
