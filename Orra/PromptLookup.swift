import MLX
import MLXLMCommon

/// Greedy decoding with drafts copied from the prompt. The cleaned text mostly repeats the
/// transcript, so after the last tokens written the transcript usually goes on with the
/// tokens the model is about to write. Each round looks up the last few tokens written in
/// the transcript, drafts the tokens that follow them there, and runs the model once on
/// the drafts. The model's own greedy pick at each position decides how many drafts are
/// kept: every draft up to the first one the model would not have written, plus the
/// model's pick at that position. So the tokens are the ones plain greedy decoding writes,
/// only several of them come from one pass.
///
/// Qwen3.5 has attention layers, whose cache can drop its last positions, and gated delta
/// layers, whose cache holds a running state that cannot. So a round keeps the gated delta
/// states from before it, and when it keeps fewer drafts than it ran, it puts those states
/// back, drops the round's positions from the attention caches, and runs the kept tokens
/// again at the start of the next round, in the same pass as its drafts. MLX arrays are
/// never changed in place, so keeping a state is keeping a reference.
///
/// Written against mlx-swift-lm 3.31.4.
nonisolated struct PromptLookup {
    /// For the log: how many rounds ran the model on drafts, how many drafts they ran and
    /// how many the model kept.
    struct Counts {
        var verifications = 0
        var drafted = 0
        var accepted = 0
    }

    /// The most drafts in one round. More cost little while the model reads its weights
    /// once per pass, and a wrong draft ends the round's drafts anyway.
    static let maximumDraft = 12

    /// The longest run of tokens looked up, then shorter ones down to one token.
    static let longestMatch = 3

    private let model: any LanguageModel
    private let cache: [any KVCache]
    /// The tokens drafts are copied from.
    private let source: [Int]
    /// Every token written so far.
    private var written: [Int] = []
    /// Tokens written but not yet in the cache, run at the start of the next pass.
    private var pending: [Int] = []
    /// The first token, picked while reading the prompt, which `next` hands out first.
    private var first: Int?
    /// Where in `source` the last kept draft ended, where the next lookup looks first.
    private var cursor = 0
    private(set) var counts = Counts()

    /// Reads the prompt tokens in `input` into `cache`, as TokenIterator does, and picks
    /// the first token. Drafts come from the last `input.count` tokens of `prompt`, the
    /// part after the prefix cache, which holds the transcript.
    init(prompt: [Int], input: [Int], model: any LanguageModel, cache: [any KVCache]) throws {
        guard cache.allSatisfy({ $0.isTrimmable || $0 is ArraysCache }) else {
            throw RewriteError.cacheCannotRollBack
        }
        self.model = model
        self.cache = cache
        self.source = Array(prompt.suffix(input.count))
        let logits: MLXArray
        switch try model.prepare(LMInput(tokens: MLXArray(input)), cache: cache, windowSize: 512) {
        case .tokens(let rest):
            logits = withPreparedCache(cache, lengths: rest.sequenceLengths) {
                model(rest.tokens[.newAxis], cache: cache)
            }
        case .logits(let result):
            logits = result.logits
        }
        let token = argMax(logits[0, -1], axis: -1).item(Int.self)
        first = token
        pending = [token]
        written = [token]
    }

    /// The next tokens greedy decoding writes, at least one and at most `limit`.
    mutating func next(limit: Int) -> [Int] {
        if let first {
            self.first = nil
            return [first]
        }
        // Rejected drafts leave the kept tokens pending, and each round runs them again. Once
        // as many are pending as one round may draft, a round without drafts puts them all in
        // the cache, so a run of rejections costs a bounded amount per token.
        let draft = pending.count > Self.maximumDraft ? [] : lookUp(count: min(Self.maximumDraft, limit - 1))
        let input = pending + draft
        let states = cache.map { ($0 as? ArraysCache).map { (state: $0.state, offset: $0.offset) } }
        let logits = model(MLXArray(input)[.newAxis], cache: cache)
        // The model's pick after the last pending token and after each draft.
        let picks = argMax(logits[0, (pending.count - 1)...], axis: -1).asType(.int32).asArray(Int32.self).map(Int.init)
        var kept = 0
        while kept < draft.count, draft[kept] == picks[kept] {
            kept += 1
        }
        let tokens = Array(draft.prefix(kept)) + [picks[kept]]
        if kept == draft.count {
            pending = [picks[kept]]
        } else {
            for (layer, saved) in zip(cache, states) {
                if let saved, let layer = layer as? ArraysCache {
                    layer.state = saved.state
                    layer.offset = saved.offset
                } else {
                    layer.trim(input.count)
                }
            }
            pending += tokens
        }
        if !draft.isEmpty {
            counts.verifications += 1
            counts.drafted += draft.count
            counts.accepted += kept
        }
        written += tokens
        return tokens
    }

    /// The tokens that follow the last tokens written where they appear in `source`,
    /// looking first at or after the end of the last kept draft, then anywhere, for the
    /// longest run that appears. None when no run does.
    private mutating func lookUp(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        for length in stride(from: min(Self.longestMatch, written.count), through: 1, by: -1) {
            let tail = written.suffix(length)
            let starts = Array(stride(from: cursor, to: source.count - length, by: 1)) + Array(stride(from: 0, to: min(cursor, source.count - length), by: 1))
            for start in starts where source[start ..< start + length].elementsEqual(tail) {
                let from = start + length
                let draft = Array(source[from ..< min(from + count, source.count)])
                if !draft.isEmpty {
                    cursor = from
                    return draft
                }
            }
        }
        return []
    }
}
