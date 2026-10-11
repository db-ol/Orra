import Foundation
import MLXLMCommon

/// The byte level BPE tokenizer of Qwen3, read from vocab.json, merges.txt and
/// tokenizer_config.json, for the cleanup model.
///
/// mlx-swift-lm leaves tokenizers to the app. Its own adapter needs the Tokenizers product
/// of swift-transformers, which Orra does not link, so this is a small port of what
/// tokenizer.json of Qwen3 describes: NFC, then the split pattern below, then byte level
/// BPE without a prefix space. Added tokens such as <|im_start|> are matched first and
/// never split. RewriteTokenizerTests compares it with the Hugging Face tokenizer.
nonisolated final class QwenTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    /// The split pattern of Qwen2 and Qwen3, from tokenizer.json.
    static let pattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    /// Read only after init, so sharing between threads is safe.
    private let vocabulary: [String: Int]
    private let tokens: [Int: String]
    /// Rank and merged token for a pair of tokens, keyed by both IDs.
    private let merges: [UInt64: (rank: Int, merged: Int)]
    /// The token for each byte.
    private let byteTokens: [Int]
    /// Added tokens by content, longest first for matching, with whether each is special.
    private let added: [(content: String, id: Int, special: Bool)]
    private let addedIDs: [Int: (content: String, special: Bool)]
    private let splitter: NSRegularExpression

    let eosToken: String? = "<|im_end|>"
    let bosToken: String? = nil
    let unknownToken: String? = nil

    enum LoadError: Error {
        case unreadable(String)
    }

    init(folder: URL) throws {
        let vocabData = try Data(contentsOf: folder.appendingPathComponent("vocab.json"))
        guard let vocabulary = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw LoadError.unreadable("vocab.json")
        }
        var tokens: [Int: String] = [:]
        tokens.reserveCapacity(vocabulary.count)
        for (token, id) in vocabulary {
            tokens[id] = token
        }

        let configData = try Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json"))
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let decoder = config["added_tokens_decoder"] as? [String: [String: Any]] else {
            throw LoadError.unreadable("tokenizer_config.json")
        }
        var added: [(content: String, id: Int, special: Bool)] = []
        for (key, entry) in decoder {
            guard let id = Int(key), let content = entry["content"] as? String else { continue }
            added.append((content, id, entry["special"] as? Bool ?? false))
        }
        added.sort { $0.content.utf16.count > $1.content.utf16.count }

        let byteToCharacter = Self.byteToCharacter
        let byteTokens = try (0..<256).map { byte in
            guard let id = vocabulary[String(byteToCharacter[byte])] else { throw LoadError.unreadable("vocab.json") }
            return id
        }

        let mergesText = try String(contentsOf: folder.appendingPathComponent("merges.txt"), encoding: .utf8)
        var merges: [UInt64: (rank: Int, merged: Int)] = [:]
        merges.reserveCapacity(160_000)
        var rank = 0
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#version") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let left = vocabulary[String(parts[0])],
                  let right = vocabulary[String(parts[1])],
                  let merged = vocabulary[String(parts[0]) + String(parts[1])] else {
                throw LoadError.unreadable("merges.txt")
            }
            let key = UInt64(UInt32(left)) << 32 | UInt64(UInt32(right))
            if merges[key] == nil {
                merges[key] = (rank, merged)
            }
            rank += 1
        }

        self.vocabulary = vocabulary
        self.tokens = tokens
        self.merges = merges
        self.byteTokens = byteTokens
        self.added = added
        self.addedIDs = Dictionary(added.map { ($0.id, ($0.content, $0.special)) }, uniquingKeysWith: { first, _ in first })
        self.splitter = try NSRegularExpression(pattern: Self.pattern)
    }

    /// GPT-2's map from bytes to printable characters, which the vocabulary is written in.
    static let byteToCharacter: [Character] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var mapped = printable
        var next = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            mapped.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, scalar) in zip(printable, mapped) {
            table[byte] = Character(Unicode.Scalar(UInt32(scalar))!)
        }
        return table
    }()

    static let characterToByte: [Unicode.Scalar: UInt8] = {
        var table: [Unicode.Scalar: UInt8] = [:]
        for (byte, character) in byteToCharacter.enumerated() {
            table[character.unicodeScalars.first!] = UInt8(byte)
        }
        return table
    }()

    // MARK: Encoding

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            // The nearest added token, longest first where two start at the same place.
            var nearest: (range: Range<Substring.Index>, id: Int)?
            for token in added {
                guard let range = rest.range(of: token.content, options: .literal) else { continue }
                if nearest == nil || range.lowerBound < nearest!.range.lowerBound {
                    nearest = (range, token.id)
                }
            }
            guard let nearest else {
                encodePlain(rest, into: &ids)
                break
            }
            encodePlain(rest[..<nearest.range.lowerBound], into: &ids)
            ids.append(nearest.id)
            rest = rest[nearest.range.upperBound...]
        }
        return ids
    }

    /// Text without added tokens: NFC, split, then BPE on the bytes of each piece.
    private func encodePlain(_ text: Substring, into ids: inout [Int]) {
        guard !text.isEmpty else { return }
        let normalized = String(text).precomposedStringWithCanonicalMapping as NSString
        let matches = splitter.matches(in: normalized as String, range: NSRange(location: 0, length: normalized.length))
        for match in matches {
            let piece = normalized.substring(with: match.range)
            ids.append(contentsOf: bpe(Array(piece.utf8)))
        }
    }

    private func bpe(_ bytes: [UInt8]) -> [Int] {
        var parts = bytes.map { byteTokens[Int($0)] }
        while parts.count > 1 {
            var best: (index: Int, rank: Int, merged: Int)?
            for index in 0..<(parts.count - 1) {
                let key = UInt64(UInt32(parts[index])) << 32 | UInt64(UInt32(parts[index + 1]))
                if let merge = merges[key], best == nil || merge.rank < best!.rank {
                    best = (index, merge.rank, merge.merged)
                }
            }
            guard let best else { break }
            // Merge every occurrence of the best pair, left to right.
            let left = parts[best.index]
            let right = parts[best.index + 1]
            var merged: [Int] = []
            merged.reserveCapacity(parts.count)
            var index = 0
            while index < parts.count {
                if index < parts.count - 1, parts[index] == left, parts[index + 1] == right {
                    merged.append(best.merged)
                    index += 2
                } else {
                    merged.append(parts[index])
                    index += 1
                }
            }
            parts = merged
        }
        return parts
    }

    // MARK: Decoding

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        var bytes: [UInt8] = []
        for id in tokenIds {
            if let token = addedIDs[id] {
                if !(skipSpecialTokens && token.special) {
                    bytes.append(contentsOf: token.content.utf8)
                }
                continue
            }
            guard let token = tokens[id] else { continue }
            for scalar in token.unicodeScalars {
                if let byte = Self.characterToByte[scalar] {
                    bytes.append(byte)
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func convertTokenToId(_ token: String) -> Int? {
        if let added = added.first(where: { $0.content == token }) {
            return added.id
        }
        return vocabulary[token]
    }

    func convertIdToToken(_ id: Int) -> String? {
        addedIDs[id]?.content ?? tokens[id]
    }

    /// Orra builds the chat prompt itself, see RewritePrompt.
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

/// Hands mlx-swift-lm the tokenizer above.
nonisolated struct QwenTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try QwenTokenizer(folder: directory)
    }
}
