import Foundation
import MLXLMCommon
import Tokenizers

/// The cleanup model's tokenizer: Hugging Face's tokenizer from swift-transformers, read
/// from tokenizer.json and tokenizer_config.json in the installed folder, in the shape
/// mlx-swift-lm wants. The same bridge that the #adaptHuggingFaceTokenizer macro of
/// mlx-swift-lm writes, without the macro and its package.
nonisolated struct CleanupTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    /// Reads local files only. AutoTokenizer.from(modelFolder:) never downloads.
    init(folder: URL) async throws {
        upstream = try await AutoTokenizer.from(modelFolder: folder)
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    /// Orra writes the chat prompt itself, see RewritePrompt, and Orra does not download
    /// the chat template.
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

/// Hands mlx-swift-lm the tokenizer above.
nonisolated struct CleanupTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await CleanupTokenizer(folder: directory)
    }
}
