import Foundation
import Testing
@testable import Orra

/// The translation prompts with the real tokenizer: the IDs transformers gave, the prefix
/// the benchmark cached, and every prompt of the translation evaluation starting with it,
/// so the cache is used for all of them. Needs only the tokenizer files, so it runs
/// whenever the model is on this Mac, and is skipped otherwise.
@Suite(.enabled(if: RewriteTestModel.folder != nil))
struct TranslationTokenizerTests {
    @Test func idsMatchTheHuggingFaceTokenizer() async throws {
        let tokenizer = try await CleanupTokenizer(folder: #require(RewriteTestModel.folder))
        #expect(tokenizer.encode(text: TranslationPromptCases.englishPrompt, addSpecialTokens: false) == TranslationPromptCases.englishIDs)
        #expect(tokenizer.encode(text: TranslationPromptCases.chinesePrompt, addSpecialTokens: false) == TranslationPromptCases.chineseIDs)
    }

    @Test func thePrefixIsTheOneTheBenchmarkCached() async throws {
        let tokenizer = try await CleanupTokenizer(folder: #require(RewriteTestModel.folder))
        let encode = { (text: String) in tokenizer.encode(text: text, addSpecialTokens: false) }
        #expect(PromptPrefix.translationPrompt(into: .english, encode: encode).count == TranslationPromptCases.englishPrefixCount)
        #expect(PromptPrefix.translationPrompt(into: .chinese, encode: encode).count == TranslationPromptCases.chinesePrefixCount)
    }

    @Test func everyEvaluationPromptStartsWithThePrefix() async throws {
        let tokenizer = try await CleanupTokenizer(folder: #require(RewriteTestModel.folder))
        let encode = { (text: String) in tokenizer.encode(text: text, addSpecialTokens: false) }
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/rewrite-eval")
        var count = 0
        for target in TranslationTarget.allCases {
            let prefix = PromptPrefix.translationPrompt(into: target, encode: encode)
            for file in ["cases.jsonl", "adversarial.jsonl", "translation-probes.jsonl"] {
                for line in try String(contentsOf: tools.appendingPathComponent(file), encoding: .utf8).split(separator: "\n") {
                    let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                    let input = try #require(object["input"] as? String)
                    let id = object["id"] as? String ?? ""
                    for text in [input, NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: input))] {
                        #expect(PromptPrefix.remainder(of: encode(TranslationPrompt.text(for: text, into: target)), after: prefix) != nil, "\(target) \(id)")
                        count += 1
                    }
                }
            }
        }
        #expect(count == 2 * 2 * (182 + 70 + 116))
    }
}
