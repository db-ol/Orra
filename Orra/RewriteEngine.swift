import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

extension Logger {
    /// Loading and running the cleanup model. Timings, token counts and guard outcomes only,
    /// never text.
    nonisolated static let rewrite = Logger(subsystem: ProblemReport.subsystem, category: "rewrite")
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

/// Owns the cleanup model, which also translates and runs Projects jobs. An actor, so
/// loading and generating run off the main actor and one call runs at a time. Loaded while
/// cleanup or translation is on and the user dictates, while captions translate, and while
/// Projects holds it. Unloaded when none of them needs it or nobody dictated for a while,
/// see TextCleanup.
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

    /// The prefix caches of the translation prompts, one per route, each filled on the
    /// first translation on its route, see `translate`. At most
    /// TranslationPrefixSlots.limit, so a user who changes the dictation language never
    /// holds more than before, and TranslationPrefixSlots.captionsLimit while Live
    /// Captions run. Dropped with the model.
    private var translationPrefixes: [TranslationRoute: Prefix] = [:]
    /// Which routes have a prefix cache, in the order they were used.
    private var prefixSlots = TranslationPrefixSlots()

    /// The Projects jobs that have not ended, by their id, see `startJob`. Dropped with the
    /// model.
    private var jobs: [Int: Job] = [:]
    /// The id of the latest job.
    private var lastJobID = 0

    /// The bytes the cleanup prefix cache holds, 0 without one.
    var prefixCacheBytes: Int {
        Self.bytes(prefix)
    }

    /// The bytes the prefix cache of a translation target of Chinese holds, 0 before it is
    /// filled.
    func translationPrefixCacheBytes(_ target: TranslationTarget) -> Int {
        translationPrefixCacheBytes(.chinese(target))
    }

    /// The bytes the prefix cache of a route holds, 0 before it is filled.
    func translationPrefixCacheBytes(_ route: TranslationRoute) -> Int {
        Self.bytes(translationPrefixes[route])
    }

    /// The routes whose prefix cache is filled.
    var translationPrefixRoutes: Set<TranslationRoute> {
        Set(translationPrefixes.keys)
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
            _ = try generate(RewritePrompt.text(for: "好的。"), maximumTokens: 4, prefix: prefix, lookingUp: true, task: "Cleanup")
        } catch {
            unload()
            throw error
        }
        Logger.rewrite.notice("Cleanup model loaded and warmed up in \(started.duration(to: .now), privacy: .public)")
    }

    /// Drops the model, its prefix cache, the Projects jobs under way and the GPU buffers
    /// MLX keeps for reuse, and asks malloc to return the pages it holds free, so the memory
    /// goes back to the system. A later call on a dropped job throws
    /// RewriteError.jobDropped.
    func unload() {
        guard context != nil else { return }
        prefix = nil
        translationPrefixes = [:]
        prefixSlots = TranslationPrefixSlots()
        let droppedJobs = jobs.count
        jobs = [:]
        context = nil
        Memory.clearCache()
        let returned = malloc_zone_pressure_relief(nil, 0)
        if droppedJobs > 0 {
            Logger.rewrite.notice("Cleanup model unloaded with \(droppedJobs, privacy: .public) Projects jobs dropped, malloc returned \(returned, privacy: .public) bytes")
        } else {
            Logger.rewrite.notice("Cleanup model unloaded, malloc returned \(returned, privacy: .public) bytes")
        }
    }

    /// Gives the GPU buffers MLX keeps for reuse back, without unloading the model.
    func clearCache() {
        Memory.clearCache()
    }

    /// Runs the cleanup prompt on a transcript. Greedy, so the same text always gets the
    /// same answer. Stops early when the task is cancelled, see CleanupStep. Without the
    /// prefix cache it runs the model on the whole prompt, which the evaluation compares.
    /// A call whose task was cancelled before its turn, such as one TimedCall gave up on
    /// while it waited behind another call, throws CancellationError and never runs the
    /// model, so nobody waits for work whose answer is dropped.
    func cleanUp(_ text: String, usingPrefixCache: Bool = true) throws -> Completion {
        try Task.checkCancellation()
        guard let context else { throw RewriteError.notLoaded }
        let inputTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count
        return try generate(RewritePrompt.text(for: text), maximumTokens: RewritePrompt.maximumTokens(inputTokens: inputTokens), prefix: usingPrefixCache ? prefix : nil, lookingUp: true, task: "Cleanup")
    }

    /// Runs the translation prompt for a target on a transcript, see TranslationPrompt.
    /// Greedy and stops early when the task is cancelled, as `cleanUp` does. The first
    /// translation into a target fills its prefix cache, which takes about as long as
    /// reading the whole prompt once, so it costs that translation about what running
    /// without the cache costs and every later one runs with it. Filling both caches at
    /// load would make every load wait about 1.4 s longer and keep their memory for
    /// dictations that are never translated. `prepareTranslation` fills one ahead.
    func translate(_ text: String, into target: TranslationTarget, usingPrefixCache: Bool = true) throws -> Completion {
        try translate(text, into: .chinese(target), usingPrefixCache: usingPrefixCache)
    }

    /// Runs the translation prompt of a route on a transcript, the same way. A call
    /// cancelled before its turn throws before it fills a prefix cache too.
    func translate(_ text: String, into route: TranslationRoute, usingPrefixCache: Bool = true) throws -> Completion {
        try Task.checkCancellation()
        guard let context else { throw RewriteError.notLoaded }
        let inputTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count
        let prefix = usingPrefixCache ? try translationPrefix(route) : nil
        return try generate(TranslationPrompt.text(for: text, into: route), maximumTokens: TranslationPrompt.maximumTokens(inputTokens: inputTokens), prefix: prefix, task: "Translation into \(route.logName)")
    }

    /// Fills the prefix cache of a target of Chinese, if it is not filled yet, so the first
    /// translation into it does not wait for that.
    func prepareTranslation(into target: TranslationTarget) throws {
        try prepareTranslation(into: .chinese(target))
    }

    /// Fills the prefix cache of a route, if it is not filled yet.
    func prepareTranslation(into route: TranslationRoute) throws {
        _ = try translationPrefix(route)
    }

    /// Drops the prefix caches of every route outside `routes`, and drops those first when
    /// more caches than the limit would be filled. TextCleanup passes the routes of the
    /// user's dictation language, and while Live Captions run those of the caption target
    /// too, which raise the limit, see TranslationPrefixSlots. So a change of language or
    /// the end of captions gives the memory of the old ones back at once.
    func keepTranslationPrefixes(_ routes: Set<TranslationRoute>) {
        let dropped = prefixSlots.keep(routes)
        drop(dropped)
    }

    private func translationPrefix(_ route: TranslationRoute) throws -> Prefix? {
        guard let context else { throw RewriteError.notLoaded }
        if let cached = translationPrefixes[route] {
            _ = prefixSlots.use(route)
            return cached
        }
        // Drops a cache before filling one more, so no more than the limit are in memory.
        drop(prefixSlots.use(route))
        let tokens = PromptPrefix.translationPrompt(into: route) { context.tokenizer.encode(text: $0, addSpecialTokens: false) }
        do {
            let filled = try fillPrefixCache(tokens, for: "translation into \(route.logName)")
            translationPrefixes[route] = filled
            return filled
        } catch {
            prefixSlots.remove(route)
            throw error
        }
    }

    private func drop(_ routes: [TranslationRoute]) {
        guard !routes.isEmpty else { return }
        for route in routes {
            translationPrefixes[route] = nil
        }
        Memory.clearCache()
        Logger.rewrite.notice("Dropped \(routes.count, privacy: .public) translation prefix caches")
    }

    // MARK: Projects jobs

    /// The longest prompt a Projects job may have, in tokens. A sliced job of this length
    /// peaked 1.3 to 1.6 GB above the idle speech and cleanup models on an M5 Pro, which
    /// leaves room next to dictation on a Mac with 16 GB.
    nonisolated static let maximumJobPromptTokens = 8_192

    /// A Projects job that `startJob` began.
    nonisolated struct JobStart: Equatable, Sendable {
        let id: Int
        let promptTokens: Int
    }

    /// What one `readSlice` did.
    nonisolated struct SliceRun: Equatable, Sendable {
        /// The prompt tokens this slice read.
        let read: Int
        /// The prompt tokens left to read before the answer. The first burst reads the
        /// last token of the prompt, so this is 0 once only that one is left.
        let remaining: Int
        /// How long the slice ran on this actor, from its start until the GPU was done
        /// with it. Time spent waiting for the actor never counts.
        let ran: Duration
    }

    /// What one `writeBurst` did.
    nonisolated struct BurstRun: Equatable, Sendable {
        /// The answer tokens this burst wrote.
        let written: Int
        /// True once the answer is complete: the model ended it, or it reached the job's
        /// maximum.
        let finished: Bool
        /// How long the burst ran on this actor, measured as for a slice.
        let ran: Duration
    }

    /// A job between its calls: the prompt's tokens, how far the model read them, the
    /// model's cache, and the answer so far. Only this actor touches it.
    private nonisolated final class Job {
        let prompt: [Int]
        let maximumTokens: Int
        var cache: [any KVCache]
        /// How many prompt tokens the model has read.
        var read = 0
        /// Writes the answer, from the first burst on.
        var writer: TokenIterator?
        var answer: [Int] = []
        var isFinished = false

        init(prompt: [Int], maximumTokens: Int, cache: [any KVCache]) {
            self.prompt = prompt
            self.maximumTokens = maximumTokens
            self.cache = cache
        }
    }

    /// Begins a Projects job on a prompt, which ends with the caller's own prefill. The
    /// model reads the prompt in slices, see `readSlice`, and writes the answer in bursts,
    /// see `writeBurst`, each its own call, so a cleanup or a translation never waits for
    /// more than one of them. Greedy, without PromptLookup and without a prefix cache.
    /// Throws RewriteError.promptTooLong for a prompt over `maximumJobPromptTokens`.
    func startJob(_ prompt: String, maximumTokens: Int) throws -> JobStart {
        try Task.checkCancellation()
        guard let context else { throw RewriteError.notLoaded }
        let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
        guard tokens.count <= Self.maximumJobPromptTokens else { throw RewriteError.promptTooLong }
        lastJobID += 1
        jobs[lastJobID] = Job(prompt: tokens, maximumTokens: maximumTokens, cache: context.model.newCache(parameters: nil))
        return JobStart(id: lastJobID, promptTokens: tokens.count)
    }

    /// Reads up to `count` more tokens of a job's prompt into its cache, and leaves the
    /// last token for the first burst. Waits until the GPU is done and gives MLX's freed
    /// buffers back before it returns, so no work of the job is under way between calls.
    ///
    /// Each slice is one forward pass. Its size changes how bf16 values round, so where two
    /// words are close the greedy answer can take the other one: the same prompt read in
    /// other slices can get another answer. Slices that end where one call ends its windows
    /// of 512 tokens give exactly the answer of one call. Reading every slice in pieces of
    /// a fixed size would make the answer the same whatever the slices, but on an M5 Pro
    /// pieces of 64 tokens took 35 to 42% longer to the first token than one call, pieces
    /// of 128 took 13 to 15% longer, and slices of 256 in one pass 4 to 6%.
    func readSlice(_ id: Int, tokens count: Int) throws -> SliceRun {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        guard let job = jobs[id], let context else { throw RewriteError.jobDropped }
        // Where the slices stop: before the last token, or where they are once the answer
        // has begun.
        let last = job.writer == nil ? max(job.prompt.count - 1, job.read) : job.read
        let end = min(job.read + max(count, 1), last)
        if end > job.read {
            let slice = MLXArray(Array(job.prompt[job.read..<end]))[.newAxis]
            // Only the cache is evaluated, so the logits of the slice are never computed.
            _ = context.model(slice, cache: job.cache)
            eval(job.cache)
        }
        Stream().synchronize()
        let ran = started.duration(to: .now)
        Memory.clearCache()
        let read = end - job.read
        job.read = end
        return SliceRun(read: read, remaining: last - end, ran: ran)
    }

    /// Writes up to `count` more tokens of a job's answer, after reading what is left of
    /// its prompt on the first burst. The tokens stay here until `endJob` decodes them all
    /// at once, so a character made of several tokens is never cut. Stops early when the
    /// task is cancelled. Waits for the GPU and gives MLX's freed buffers back, as
    /// `readSlice` does.
    func writeBurst(_ id: Int, tokens count: Int) throws -> BurstRun {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        guard let job = jobs[id], let context else { throw RewriteError.jobDropped }
        if job.writer == nil, !job.isFinished {
            if job.read < job.prompt.count, job.maximumTokens > 0 {
                let rest = Array(job.prompt[job.read...])
                job.writer = try TokenIterator(input: LMInput(tokens: MLXArray(rest)), model: context.model, cache: job.cache, parameters: GenerateParameters(maxTokens: job.maximumTokens, temperature: 0))
                job.read = job.prompt.count
            } else {
                job.isFinished = true
            }
        }
        let stop = stopTokens(context)
        var written = 0
        while written < count, !job.isFinished {
            guard let token = job.writer?.next(), !stop.contains(token) else {
                job.isFinished = true
                break
            }
            job.answer.append(token)
            written += 1
            if job.answer.count >= job.maximumTokens {
                job.isFinished = true
            }
            if Task.isCancelled {
                break
            }
        }
        // The writer evaluates the next token ahead. Let it finish, so nothing runs on the
        // GPU for this job until its next call.
        Stream().synchronize()
        let ran = started.duration(to: .now)
        Memory.clearCache()
        return BurstRun(written: written, finished: job.isFinished, ran: ran)
    }

    /// Ends a job: decodes what the model wrote, without any prefill, drops the job and
    /// gives MLX's freed buffers back, its cache among them. Also for a job that has not
    /// finished, such as one whose caller was cancelled. Throws RewriteError.jobDropped
    /// when an unload dropped the job before.
    func endJob(_ id: Int) throws -> String {
        guard let job = jobs.removeValue(forKey: id) else { throw RewriteError.jobDropped }
        let answer = context?.tokenizer.decode(tokenIds: job.answer, skipSpecialTokens: true) ?? ""
        // Lets go of the job's arrays before the cache is cleared, so they go back too.
        job.writer = nil
        job.cache = []
        Memory.clearCache()
        return answer
    }

    /// The end of turn tokens from generation_config.json and the tokenizer.
    private func stopTokens(_ context: ModelContext) -> Set<Int> {
        var stop = context.configuration.eosTokenIds
        if let end = context.tokenizer.eosTokenId {
            stop.insert(end)
        }
        return stop
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
    private func generate(_ text: String, maximumTokens: Int, prefix: Prefix?, lookingUp looksUp: Bool = false, task: String) throws -> Completion {
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
        let stop = stopTokens(context)
        var generated: [Int] = []
        var reason = "the token limit"
        var lookup = PromptLookup.Counts()
        let prefilled: ContinuousClock.Instant
        if looksUp {
            let cache = cache ?? context.model.newCache(parameters: nil)
            var decoder = try PromptLookup(prompt: prompt, input: input, model: context.model, cache: cache)
            prefilled = ContinuousClock.now
            loop: while generated.count < maximumTokens {
                for token in decoder.next(limit: maximumTokens - generated.count) {
                    if stop.contains(token) {
                        reason = "the end of the answer"
                        break loop
                    }
                    generated.append(token)
                }
                if Task.isCancelled {
                    reason = "cancellation"
                    break
                }
            }
            lookup = decoder.counts
        } else {
            let parameters = GenerateParameters(maxTokens: maximumTokens, temperature: 0)
            var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(input)), model: context.model, cache: cache, parameters: parameters)
            // The iterator evaluates the first token ahead. Wait for it, so the time is the
            // time the model took to read the prompt.
            Stream().synchronize()
            prefilled = ContinuousClock.now
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
        }
        // The iterator evaluates ahead. Let that finish before the next use of MLX, and
        // return the freed buffers, as speech-swift does after each transcription, so the
        // buffer cache does not grow from run to run.
        Stream().synchronize()
        Memory.clearCache()
        let answer = RewritePrompt.prefill + context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
        let cached = prompt.count - input.count
        let prefillTime = started.duration(to: prefilled)
        Logger.rewrite.notice("\(task, privacy: .public) ran in \(started.duration(to: .now), privacy: .public): \(prompt.count, privacy: .public) prompt tokens, \(cached, privacy: .public) of them cached and \(input.count, privacy: .public) read in \(prefillTime, privacy: .public), \(generated.count, privacy: .public) of at most \(maximumTokens, privacy: .public) tokens written, stopped by \(reason, privacy: .public), \(lookup.verifications, privacy: .public) lookups verified \(lookup.drafted, privacy: .public) drafted tokens and kept \(lookup.accepted, privacy: .public)")
        return Completion(answer: answer, promptTokens: prompt.count, cachedPromptTokens: cached, prefillTime: prefillTime, generatedTokens: generated.count)
    }
}

nonisolated enum RewriteError: Error, Equatable {
    case notLoaded
    /// The model has a cache that PromptLookup can neither trim nor restore.
    case cacheCannotRollBack
    /// A Projects job's prompt is longer than RewriteEngine.maximumJobPromptTokens.
    case promptTooLong
    /// The model was unloaded since the Projects job began, which dropped the job.
    case jobDropped
}

/// What PushToTalkController needs from the cleanup model. Closures, so tests pass fakes.
struct CleanupModel {
    /// Whether the user turned cleanup on, without waiting for the model, see
    /// TextCleanup.isOn.
    var isOn: () -> Bool = { false }
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

/// A model call with a time limit, for the cleanup and translation steps.
///
/// At the limit it cancels the call and returns at once, so the paste never waits past
/// the limit. The call goes on until it ends by itself, and its result is dropped: one
/// that waits at the engine behind another call ends when that call is done, and one in
/// an MLX evaluation that does not look at cancellation ends with the evaluation. So the
/// call itself must hold whatever keeps other model work away until it really ends, and
/// the caller must never take the model as free when this returns. The cleanup model's
/// calls do: each holds its access to the model gate until the engine returns, see
/// CleanupEngine.gated, and the engine runs one call at a time, see RewriteEngine.
nonisolated enum TimedCall {
    /// What ended the wait first.
    private nonisolated enum Outcome<Value: Sendable>: Sendable {
        case answered(Result<Value, any Error>)
        case timedOut
    }

    /// What `call` gave back or threw, and whether `limit` passed first. Then the result is
    /// a CancellationError, and the call is cancelled and left to end on its own. A caller
    /// whose task is cancelled gets a CancellationError at once too, with `timedOut` false,
    /// and the call is cancelled the same way.
    @concurrent
    static func run<Value: Sendable>(
        within limit: Duration,
        _ call: @escaping @Sendable () async throws -> Value
    ) async -> (result: Result<Value, any Error>, timedOut: Bool) {
        guard !Task.isCancelled else { return (.failure(CancellationError()), false) }
        // The first outcome is kept, and the ones after it are dropped.
        let (outcomes, settle) = AsyncStream<Outcome<Value>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // Not awaited past the limit. A task of its own, which keeps the caller's
        // priority and task locals, as before.
        let work = Task {
            do {
                settle.yield(.answered(.success(try await call())))
            } catch {
                settle.yield(.answered(.failure(error)))
            }
        }
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            settle.yield(.timedOut)
        }
        // Nil when the caller's task is cancelled, which ends the stream.
        var iterator = outcomes.makeAsyncIterator()
        let outcome = await iterator.next()
        settle.finish()
        timer.cancel()
        switch outcome {
        case .answered(let result):
            return (result, false)
        case .timedOut:
            work.cancel()
            return (.failure(CancellationError()), true)
        case nil:
            work.cancel()
            return (.failure(CancellationError()), false)
        }
    }
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

    /// Why the model's cleanup of `text` is held back, nil when it may be pasted. An empty
    /// cleanup is held back, so the model never makes Orra paste nothing.
    static func check(_ cleaned: String, of text: String) -> RewriteGuard.Failure? {
        if cleaned.isEmpty {
            return .empty
        }
        return RewriteGuard.check(source: text, output: cleaned)
    }

    /// The text to paste and what happened. Logs the outcome and the time, never text.
    @concurrent
    static func run(_ text: String, timeout: Duration? = nil, complete: @escaping @Sendable (String) async throws -> String) async -> (text: String, outcome: Outcome) {
        let started = ContinuousClock.now
        let (result, timedOut) = await TimedCall.run(within: timeout ?? Self.timeout(for: text)) { try await complete(text) }
        let outcome: Outcome
        var cleaned = text
        if timedOut {
            outcome = .timedOut
        } else {
            switch result {
            case .success(let answer):
                if let parsed = RewritePrompt.parse(answer) {
                    if let failure = check(parsed, of: text) {
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

/// Whether the user turned cleanup on. Off until they do, in Settings, or until a new
/// user on a Mac with enough memory starts the welcome window's download, see
/// CleanupDefault.
nonisolated enum CleanupPreference {
    static let defaultsKey = "cleansUpWithLocalModel"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        saved(from: defaults) ?? false
    }

    /// The choice as saved, nil when the user never made one.
    static func saved(from defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: defaultsKey) as? Bool
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}
