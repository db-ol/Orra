import AudioCommon
import Foundation
import MLX
import MLXCommon
import Qwen3ASR

/// Qwen3-ASR's prompt and greedy decoding, rebuilt from speech-swift's public pieces
/// (featureExtractor, audioEncoder, textDecoder and Qwen3Tokenizer), with one addition: a
/// forced start of the answer. Tokens from an earlier hypothesis go into the prompt after
/// the assistant turn begins, so the model reads them in the same parallel forward pass as
/// the audio, and only the rest of the text is generated one token at a time.
///
/// Written against speech-swift at commit 1f54e56. The prompt follows generateTextImpl in
/// Qwen3ASR.swift, the loop follows generateGreedyAsyncEval, including its cast of the
/// argmax to int32. With an empty prefix the tokens equal speech-swift's own greedy path,
/// which the speech corpus run in the pull request that added this checked on 200 clips.
/// When speech-swift changes its prompt, this file has to follow.
nonisolated enum PrefixedDecoder {
    /// Returns every token of the answer: the prefix, then the generated ones, without the
    /// end token. The answer starts with "language X<asr_text>" when no language is given.
    /// Throws CancellationError between tokens when the task is cancelled.
    static func decode(
        model: Qwen3ASRModel,
        tokenizer: Qwen3Tokenizer,
        samples: [Float],
        context: String?,
        language: SpeechLanguage?,
        prefix: [Int32]
    ) throws -> [Int32] {
        defer {
            // As speech-swift does after each transcription: wait for the speculative step,
            // then hand the scratch buffers back, so memory stays bounded.
            StreamOrDevice.default.stream.synchronize()
            Memory.clearCache()
        }
        guard let decoder = model.textDecoder else { throw TranscriptionError.modelMissing }
        let T = Qwen3ASRTokens.self
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        let maxTokens = max(448, Int(seconds * 12))
        let mel = model.featureExtractor.process(samples, sampleRate: RecordingLimits.sampleRate)
        let audio = model.audioEncoder(mel.expandedDimensions(axis: 0)).expandedDimensions(axis: 0)

        var ids: [Int32] = [T.imStartTokenId, T.systemTokenId, T.newlineTokenId].map { Int32($0) }
        if let context, !context.isEmpty {
            ids += tokenizer.encode(context).map { Int32($0) }
        }
        ids += [T.imEndTokenId, T.newlineTokenId, T.imStartTokenId, T.userTokenId, T.newlineTokenId, T.audioStartTokenId].map { Int32($0) }
        let audioStart = ids.count
        let audioCount = audio.dim(1)
        ids += [Int32](repeating: Int32(T.audioTokenId), count: audioCount)
        ids += [T.audioEndTokenId, T.imEndTokenId, T.newlineTokenId, T.imStartTokenId, T.assistantTokenId, T.newlineTokenId].map { Int32($0) }
        var forced = prefix
        if let language {
            forced = tokenizer.encode("language \(language.rawValue)").map { Int32($0) } + [Int32(T.asrTextTokenId)]
            if prefix.count > forced.count, Array(prefix.prefix(forced.count)) == forced {
                forced = prefix
            }
        }
        ids += forced

        try Task.checkCancellation()
        var embeds = decoder.embedTokens(MLXArray(ids).expandedDimensions(axis: 0))
        embeds = concatenated([
            embeds[0..., 0..<audioStart, 0...],
            audio.asType(embeds.dtype),
            embeds[0..., (audioStart + audioCount)..., 0...],
        ], axis: 1)
        let (hidden, prefilled) = decoder(inputsEmbeds: embeds, cache: nil)
        let length = hidden.dim(1)
        let logits = decoder.embedTokens.asLinear(hidden[0..., (length - 1)..<length, 0...])

        // Double buffered like generateGreedyAsyncEval: the GPU works on token N+1 while
        // the CPU reads token N.
        let budget = max(1, maxTokens - forced.count)
        let end = Int32(T.eosTokenId)
        var generated: [Int32] = []
        var next = argMax(logits, axis: -1).squeezed().asType(.int32)
        var cache = prefilled
        asyncEval(next, cache)
        for step in 0..<budget {
            try Task.checkCancellation()
            var following: (token: MLXArray, cache: [(MLXArray, MLXArray)])?
            if step + 1 < budget {
                let embedded = decoder.embedTokens(next.expandedDimensions(axis: 0).expandedDimensions(axis: 0))
                let (stepHidden, stepCache) = decoder(inputsEmbeds: embedded, cache: cache)
                let token = argMax(decoder.embedTokens.asLinear(stepHidden[0..., (-1)..., .ellipsis]), axis: -1).squeezed().asType(.int32)
                asyncEval(token, stepCache)
                following = (token, stepCache)
            }
            let token = next.item(Int32.self)
            if token == end { break }
            generated.append(token)
            guard let following else { break }
            next = following.token
            cache = following.cache
        }
        return forced + generated
    }

    /// The text of an answer, as speech-swift returns it: what follows <asr_text>.
    static func text(of tokens: [Int32], tokenizer: Qwen3Tokenizer) -> String {
        let raw = tokenizer.decode(tokens: tokens.map { Int($0) })
        if let range = raw.range(of: "<asr_text>") {
            return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }
}

/// Which part of a hypothesis made while the key was held the final pass may keep.
nonisolated enum HypothesisPrefix {
    /// Tokens dropped from the end of a hypothesis. Its last words were cut off by the end
    /// of the audio it saw, so they are often wrong.
    static let droppedTokens = 8

    /// The hypothesis without its last `droppedTokens` tokens, never cutting into the
    /// "language X<asr_text>" start. Empty when the hypothesis has no <asr_text>, so a
    /// strange answer is never forced on the final pass.
    static func cut(_ tokens: [Int32]) -> [Int32] {
        guard let marker = tokens.firstIndex(of: Int32(Qwen3ASRTokens.asrTextTokenId)) else { return [] }
        let end = max(marker + 1, tokens.count - droppedTokens)
        return Array(tokens[..<end])
    }
}
