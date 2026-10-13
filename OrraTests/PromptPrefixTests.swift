import Foundation
import Testing
@testable import Orra

/// The fixed start of the cleanup prompt, found with stand in token IDs, and the check that
/// decides whether a prompt can use the cache.
struct PromptPrefixTests {
    @Test func theSharedStartStopsTwoTokensBeforeTheFirstDifference() {
        #expect(PromptPrefix.shared([1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 9, 9]) == [1, 2])
        #expect(PromptPrefix.shared([1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6, 7]) == [1, 2, 3])
        #expect(PromptPrefix.shared([7, 1, 2], [8, 1, 2]) == [])
        #expect(PromptPrefix.shared([1, 2], [1, 2, 3]) == [])
        #expect(PromptPrefix.shared([], [1]) == [])
    }

    @Test func aPromptThatStartsWithThePrefixReadsOnlyTheRest() {
        #expect(PromptPrefix.remainder(of: [1, 2, 3, 4, 5], after: [1, 2, 3]) == [4, 5])
        #expect(PromptPrefix.remainder(of: [1, 2, 3, 4], after: [1, 2, 3]) == [4])
    }

    /// The tokenizer merged the end of the fixed text with the transcript, or the prompt
    /// changed: the cache does not fit, so the whole prompt is read.
    @Test func aPromptThatDiffersInThePrefixReadsEverything() {
        #expect(PromptPrefix.remainder(of: [1, 2, 9, 4, 5], after: [1, 2, 3]) == nil)
        #expect(PromptPrefix.remainder(of: [9, 2, 3, 4, 5], after: [1, 2, 3]) == nil)
        #expect(PromptPrefix.remainder(of: [1, 2], after: [1, 2, 3]) == nil)
    }

    /// The model needs at least one token to read, and an empty prefix caches nothing.
    @Test func nothingAfterThePrefixOrNoPrefixReadsEverything() {
        #expect(PromptPrefix.remainder(of: [1, 2, 3], after: [1, 2, 3]) == nil)
        #expect(PromptPrefix.remainder(of: [1, 2, 3], after: []) == nil)
    }

    /// With one stand in token per character, the prefix ends two characters before the
    /// transcript, inside `{"transcript": "`, and every prompt starts with it.
    @Test func theCleanupPromptPrefixEndsBeforeTheTranscript() throws {
        let encode = { (text: String) in text.unicodeScalars.map { Int($0.value) } }
        let prefix = PromptPrefix.cleanupPrompt(encode: encode)
        let start = RewritePrompt.text(for: "X").components(separatedBy: "X")[0]
        #expect(start.hasSuffix(#"{"transcript": ""#))
        #expect(prefix == encode(String(start.unicodeScalars.dropLast(2))))
        for transcript in ["呃，我们下周二开会。", "Hello", "\"quoted\"", "1", " space", "\n"] {
            let prompt = encode(RewritePrompt.text(for: transcript))
            let rest = try #require(PromptPrefix.remainder(of: prompt, after: prefix))
            #expect(prefix + rest == prompt)
        }
    }
}

/// The prefix with the real tokenizer: every prompt of the cleanup evaluation starts with
/// it, so the cache is used for all of them. Needs only the tokenizer files, so it runs
/// whenever the model is on this Mac, and is skipped otherwise.
@Suite(.enabled(if: RewriteTestModel.folder != nil))
struct PromptPrefixTokenizerTests {
    @Test func everyEvaluationPromptStartsWithThePrefix() async throws {
        let tokenizer = try await CleanupTokenizer(folder: #require(RewriteTestModel.folder))
        let encode = { (text: String) in tokenizer.encode(text: text, addSpecialTokens: false) }
        let prefix = PromptPrefix.cleanupPrompt(encode: encode)
        // Most of the prompt: its system text and examples.
        #expect(prefix.count > 800)
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/rewrite-eval")
        var count = 0
        for file in ["cases.jsonl", "adversarial.jsonl"] {
            for line in try String(contentsOf: tools.appendingPathComponent(file), encoding: .utf8).split(separator: "\n") {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let input = try #require(object["input"] as? String)
                let id = object["id"] as? String ?? ""
                for text in [input, NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: input))] {
                    #expect(PromptPrefix.remainder(of: encode(RewritePrompt.text(for: text)), after: prefix) != nil, "\(id)")
                    count += 1
                }
            }
        }
        #expect(count == 2 * (178 + 70))
    }
}
