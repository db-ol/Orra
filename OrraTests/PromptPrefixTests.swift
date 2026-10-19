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
        // The last X is the transcript, since the system text may hold an X of its own.
        let marked = RewritePrompt.text(for: "X")
        let position = try #require(marked.range(of: "X", options: .backwards))
        let start = String(marked[..<position.lowerBound])
        #expect(start.hasSuffix(#"{"transcript": ""#))
        #expect(prefix == encode(String(start.unicodeScalars.dropLast(2))))
        for transcript in ["呃，我们下周二开会。", "Hello", "\"quoted\"", "1", " space", "\n"] {
            let prompt = encode(RewritePrompt.text(for: transcript))
            let rest = try #require(PromptPrefix.remainder(of: prompt, after: prefix))
            #expect(prefix + rest == prompt)
        }
    }

    /// Each translation target has its own prefix, which ends inside `{"transcript": "` too.
    @Test func eachTranslationPromptHasItsOwnPrefix() throws {
        let encode = { (text: String) in text.unicodeScalars.map { Int($0.value) } }
        var prefixes: [[Int]] = []
        for target in DictationLanguage.chinese.translationTargets {
            let prefix = PromptPrefix.translationPrompt(into: target, encode: encode)
            let start = TranslationPrompt.text(for: "X", into: target).components(separatedBy: "X")[0]
            #expect(start.hasSuffix(#"{"transcript": ""#))
            #expect(prefix == encode(String(start.unicodeScalars.dropLast(2))))
            for transcript in ["呃，我们下周二开会。", "Hello", "\"quoted\"", "1", " space", "\n"] {
                let prompt = encode(TranslationPrompt.text(for: transcript, into: target))
                let rest = try #require(PromptPrefix.remainder(of: prompt, after: prefix))
                #expect(prefix + rest == prompt)
            }
            prefixes.append(prefix)
        }
        #expect(prefixes[0] != prefixes[1])
        // The cleanup prefix fits neither.
        let cleanup = PromptPrefix.cleanupPrompt(encode: encode)
        #expect(PromptPrefix.remainder(of: encode(TranslationPrompt.text(for: "Hello", into: .english)), after: cleanup) == nil)
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
        for file in ["cases.jsonl", "adversarial.jsonl", "meaning.jsonl"] {
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
        #expect(count == 2 * (182 + 70 + 20))
    }
}
