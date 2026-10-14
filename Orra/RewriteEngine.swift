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
    /// Qwen3.5 4B in the 4 bit MLX build, for cleaning up dictations. Apache-2.0. Hugging
    /// Face main as of 2026-10-11, last changed on 2026-03-02. ModelScope's mirror in the
    /// mlx-community organization lists the same sizes and SHA-256 values at its commit, and
    /// hf-mirror.com serves the Hugging Face commit. The weights hold the language model only,
    /// with no vision tower. tokenizer.json is what CleanupTokenizer reads, and it holds the
    /// vocabulary and the merges, so vocab.json is left out. chat_template.jinja, the index
    /// and the image and video processor files are left out too, since Orra builds the prompt
    /// itself, the weights are in one file and Orra sends only text.
    static let qwen35Cleanup = ModelManifest(
        id: "mlx-community/Qwen3.5-4B-4bit",
        huggingFaceRevision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
        modelScopeRevision: "ab9c7a42fd31095a40634b3362317779dee9e7fa",
        files: [
            ModelFile(name: "config.json", size: 3_366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
            ModelFile(name: "tokenizer_config.json", size: 1_139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
            ModelFile(name: "tokenizer.json", size: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            ModelFile(name: "model.safetensors", size: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db", resumable: true),
        ],
        // The cleanup model before 2026-10-11, which builds of the local-rewrite branch
        // downloaded. No release carried it.
        formerNames: ["Qwen3-4B-Instruct-2507-4bit"]
    )
}

nonisolated extension ModelFolders {
    /// Where the cleanup model goes: its own folder next to the speech model's, in
    /// ~/Library/Application Support/io.github.db-ol.Orra/Models. No older copy to reuse.
    static var liveCleanup: ModelFolders {
        ModelFolders(models: live.models, oldCopies: [])
    }
}

/// Owns the cleanup model, which also translates. An actor, so loading and generating run
/// off the main actor and one cleanup or translation runs at a time. Loaded while cleanup
/// or translation is on and the user dictates, unloaded when both are off or nobody
/// dictated for a while, see TextCleanup.
///
/// Written against mlx-swift-lm 3.31.4.
actor RewriteEngine {
    /// What one cleanup or translation produced, for the caller to parse and check.
    struct Completion: Sendable {
        /// The prefill and what the model wrote after it.
        let answer: String
        let promptTokens: Int
        /// How many of the prompt tokens came from the prefix cache, see PromptPrefix.
        let cachedPromptTokens: Int
        /// How long the model took to read the prompt tokens that were not cached.
        let prefillTime: Duration
        let generatedTokens: Int
    }

    private var context: ModelContext?

    /// The model's cache after the fixed start of a prompt, and the tokens of that start.
    /// A run uses a copy, so this one never changes.
    private typealias Prefix = (tokens: [Int], cache: [any KVCache])

    /// The prefix cache of the cleanup prompt, filled once after loading. Dropped with the
    /// model.
    private var prefix: Prefix?

    /// The prefix caches of the translation prompts, one per target, each filled on the
    /// first translation into its target, see `translate`. Dropped with the model.
    private var translationPrefixes: [TranslationTarget: Prefix] = [:]

    var isLoaded: Bool {
        context != nil
    }

    /// The bytes the cleanup prefix cache holds, 0 without one.
    var prefixCacheBytes: Int {
        Self.bytes(prefix)
    }

    /// The bytes the prefix cache of a translation target holds, 0 before it is filled.
    func translationPrefixCacheBytes(_ target: TranslationTarget) -> Int {
        Self.bytes(translationPrefixes[target])
    }

    private static func bytes(_ prefix: Prefix?) -> Int {
        prefix?.cache.reduce(0) { total, cache in
            total + cache.innerState().reduce(0) { $0 + $1.nbytes }
        } ?? 0
    }

    /// Loads the model from an installed folder, runs it on the fixed start of the prompt,
    /// and runs one short cleanup, so the first dictation does not pay for compiling GPU
    /// programs. Reads local files only.
    func load(from folder: URL) async throws {
        guard context == nil else { return }
        let started = ContinuousClock.now
        let loaded = try await LLMModelFactory.shared.load(from: folder, using: CleanupTokenizerLoader())
        context = loaded
        do {
            prefix = try fillPrefixCache(PromptPrefix.cleanupPrompt { loaded.tokenizer.encode(text: $0, addSpecialTokens: false) }, for: "cleanup")
            _ = try generate(RewritePrompt.text(for: "好的。"), maximumTokens: 4, prefix: prefix, task: "Cleanup")
        } catch {
            unload()
            throw error
        }
        Logger.rewrite.notice("Cleanup model loaded and warmed up in \(started.duration(to: .now), privacy: .public)")
    }

    /// Drops the model, its prefix cache and the GPU buffers MLX keeps for reuse, and asks
    /// malloc to return the pages it holds free, so the memory goes back to the system.
    func unload() {
        guard context != nil else { return }
        prefix = nil
        translationPrefixes = [:]
        context = nil
        Memory.clearCache()
        let returned = malloc_zone_pressure_relief(nil, 0)
        Logger.rewrite.notice("Cleanup model unloaded, malloc returned \(returned, privacy: .public) bytes")
    }

    /// Runs the cleanup prompt on a transcript. Greedy, so the same text always gets the
    /// same answer. Stops early when the task is cancelled, see CleanupStep. Without the
    /// prefix cache it runs the model on the whole prompt, which the evaluation compares.
    func cleanUp(_ text: String, usingPrefixCache: Bool = true) throws -> Completion {
        guard let context else { throw RewriteError.notLoaded }
        let inputTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count
        return try generate(RewritePrompt.text(for: text), maximumTokens: RewritePrompt.maximumTokens(inputTokens: inputTokens), prefix: usingPrefixCache ? prefix : nil, task: "Cleanup", closesAnswer: RewritePrompt.closesAnswer)
    }

    /// Runs the translation prompt for a target on a transcript, see TranslationPrompt.
    /// Greedy and stops early when the task is cancelled, as `cleanUp` does. The first
    /// translation into a target fills its prefix cache, which takes about as long as
    /// reading the whole prompt once, so it costs that translation about what running
    /// without the cache costs and every later one runs with it. Filling both caches at
    /// load would make every load wait about 1.4 s longer and keep their memory for
    /// dictations that are never translated. `prepareTranslation` fills one ahead.
    func translate(_ text: String, into target: TranslationTarget, usingPrefixCache: Bool = true) throws -> Completion {
        guard let context else { throw RewriteError.notLoaded }
        let inputTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count
        let prefix = usingPrefixCache ? try translationPrefix(target) : nil
        return try generate(TranslationPrompt.text(for: text, into: target), maximumTokens: TranslationPrompt.maximumTokens(inputTokens: inputTokens), prefix: prefix, task: "Translation into \(target.logName)")
    }

    /// Fills the prefix cache of a target, if it is not filled yet, so the first
    /// translation into it does not wait for that.
    func prepareTranslation(into target: TranslationTarget) throws {
        _ = try translationPrefix(target)
    }

    private func translationPrefix(_ target: TranslationTarget) throws -> Prefix? {
        guard let context else { throw RewriteError.notLoaded }
        if let cached = translationPrefixes[target] {
            return cached
        }
        let tokens = PromptPrefix.translationPrompt(into: target) { context.tokenizer.encode(text: $0, addSpecialTokens: false) }
        let filled = try fillPrefixCache(tokens, for: "translation into \(target.logName)")
        translationPrefixes[target] = filled
        return filled
    }

    /// Runs the model on the start of a prompt that every transcript shares and returns its
    /// cache. Without a shared start there is no cache and every run reads the whole
    /// prompt.
    private func fillPrefixCache(_ tokens: [Int], for task: String) throws -> Prefix? {
        guard let context else { throw RewriteError.notLoaded }
        let started = ContinuousClock.now
        guard !tokens.isEmpty else {
            Logger.rewrite.error("The \(task, privacy: .public) prompt has no shared start, so no prefix cache")
            return nil
        }
        let cache = context.model.newCache(parameters: nil)
        // Setting up the iterator runs the model on every token and fills the cache. The
        // token it picks after them is never read, so it never enters the cache.
        _ = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model, cache: cache, parameters: GenerateParameters(maxTokens: 1, temperature: 0))
        eval(cache)
        Stream().synchronize()
        // Reading the prefix leaves about 0.6 GB of freed buffers in MLX's buffer cache,
        // which has no limit unless the speech model set one.
        Memory.clearCache()
        let filled: Prefix = (tokens, cache)
        Logger.rewrite.notice("Prefix cache for \(task, privacy: .public) of \(tokens.count, privacy: .public) tokens and \(Self.bytes(filled), privacy: .public) bytes filled in \(started.duration(to: .now), privacy: .public)")
        return filled
    }

    /// Runs the model on a prompt, which ends with RewritePrompt.prefill, reading only what
    /// follows `prefix` when the prompt starts with it. `task` names the run in the log.
    private func generate(_ text: String, maximumTokens: Int, prefix: Prefix?, task: String, closesAnswer: ((String) -> Bool)? = nil) throws -> Completion {
        guard let context else { throw RewriteError.notLoaded }
        let started = ContinuousClock.now
        let prompt = context.tokenizer.encode(text: text, addSpecialTokens: false)
        // With the prefix cache, the model reads only the tokens after the prefix, on a copy
        // of the cache. A prompt that does not start with the prefix's tokens reads them all.
        var input = prompt
        var cache: [any KVCache]?
        if let prefix {
            if let remainder = PromptPrefix.remainder(of: prompt, after: prefix.tokens) {
                input = remainder
                cache = prefix.cache.map { $0.copy() }
            } else {
                Logger.rewrite.notice("\(task, privacy: .public) prompt does not start with the cached prefix, so all of it is read")
            }
        }
        // The end of turn tokens from generation_config.json and the tokenizer.
        var stop = context.configuration.eosTokenIds
        if let end = context.tokenizer.eosTokenId {
            stop.insert(end)
        }
        let parameters = GenerateParameters(maxTokens: maximumTokens, temperature: 0)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(input)), model: context.model, cache: cache, parameters: parameters)
        // The iterator evaluates the first token ahead. Wait for it, so the time is the
        // time the model took to read the prompt.
        Stream().synchronize()
        let prefilled = ContinuousClock.now
        var generated: [Int] = []
        var reason = "the token limit"
        while let token = iterator.next() {
            if stop.contains(token) {
                reason = "the end of the answer"
                break
            }
            generated.append(token)
            // A token that writes a closing brace may end the JSON object. Then the next
            // token would be the end of turn, so stop without running the model for it.
            if let closesAnswer, context.tokenizer.decode(tokenIds: [token], skipSpecialTokens: true).contains("}"),
               closesAnswer(context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)) {
                reason = "the end of the JSON object"
                break
            }
            if Task.isCancelled {
                reason = "cancellation"
                break
            }
        }
        // The iterator evaluates ahead. Let that finish before the next use of MLX, and
        // return the freed buffers, as speech-swift does after each transcription, so the
        // buffer cache does not grow from run to run.
        Stream().synchronize()
        Memory.clearCache()
        let answer = RewritePrompt.prefill + context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
        let cached = prompt.count - input.count
        let prefillTime = started.duration(to: prefilled)
        Logger.rewrite.notice("\(task, privacy: .public) ran in \(started.duration(to: .now), privacy: .public): \(prompt.count, privacy: .public) prompt tokens, \(cached, privacy: .public) of them cached and \(input.count, privacy: .public) read in \(prefillTime, privacy: .public), \(generated.count, privacy: .public) of at most \(maximumTokens, privacy: .public) tokens written, stopped by \(reason, privacy: .public)")
        return Completion(answer: answer, promptTokens: prompt.count, cachedPromptTokens: cached, prefillTime: prefillTime, generatedTokens: generated.count)
    }
}

nonisolated enum RewriteError: Error, Equatable {
    case notLoaded
}

/// What PushToTalkController needs from the cleanup model. Closures, so tests pass fakes.
struct CleanupModel {
    /// Whether the model can clean up a transcript now, after waiting a bounded time for a
    /// load under way, see TextCleanup.waitUntilLoaded.
    var waitUntilLoaded: () async -> Bool
    /// The talk key went down, see TextCleanup.dictationStarted.
    var dictationStarted: () -> Void = {}
    /// The dictation is over, see TextCleanup.dictationEnded.
    var dictationEnded: () -> Void = {}
    /// The model's answer for a transcript, see RewriteEngine.cleanUp.
    var complete: @Sendable (String) async throws -> String

    /// No cleanup, for tests and previews.
    static let off = CleanupModel(waitUntilLoaded: { false }, complete: { _ in throw RewriteError.notLoaded })
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
    /// M5 Pro, CleanupModelEvaluationTests measured 0.36 s for 46 Chinese characters, 3.4 s
    /// for 400 and 2.3 s for 905 English ones in a Release build with the prefix cache, and
    /// 1.1 s, 3.3 to 5.6 s and 2.5 s before it. This allows 2.7 s, 8 s and 15.6 s for them,
    /// so a slower Mac still gets most cleanups.
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
