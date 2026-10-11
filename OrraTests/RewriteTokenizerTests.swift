import Foundation
import MLXLMCommon
import Testing
@testable import Orra

/// The cleanup model on this Mac, for the tests that need its files: the folder named by
/// ORRA_REWRITE_MODEL_DIR (TEST_RUNNER_ORRA_REWRITE_MODEL_DIR through xcodebuild), or the
/// folder Orra installed. Found by file sizes and only read, never changed.
enum RewriteTestModel {
    static var folder: URL? {
        if let custom = ProcessInfo.processInfo.environment["ORRA_REWRITE_MODEL_DIR"] {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            return ModelDisk.isComplete(url, .qwen3Cleanup) ? url : nil
        }
        let installed = ModelFolders.liveCleanup.installed(.qwen3Cleanup)
        return ModelDisk.isComplete(installed, .qwen3Cleanup) ? installed : nil
    }
}

/// QwenTokenizer gives the IDs the Hugging Face tokenizer gives. Needs only the tokenizer
/// files, so it runs whenever the model is on this Mac, and is skipped otherwise.
@Suite(.enabled(if: RewriteTestModel.folder != nil))
struct RewriteTokenizerTests {
    private struct Case: Decodable {
        let text: String?
        let transcript: String?
        let ids: [Int]
    }

    private static let cases: [Case] = RewriteTokenizerCases.jsonl
        .split(separator: "\n")
        .map { try! JSONDecoder().decode(Case.self, from: Data($0.utf8)) }

    @Test func idsMatchTheHuggingFaceTokenizer() throws {
        let tokenizer = try QwenTokenizer(folder: #require(RewriteTestModel.folder))
        #expect(Self.cases.count == 24)
        for item in Self.cases {
            let text = item.text ?? RewritePrompt.text(for: item.transcript ?? "")
            #expect(tokenizer.encode(text: text, addSpecialTokens: false) == item.ids, "\(text.prefix(60))")
        }
    }

    @Test func decodingGivesTheTextBack() throws {
        let tokenizer = try QwenTokenizer(folder: #require(RewriteTestModel.folder))
        for text in ["我们下周二开会。", "Can you send me the PDF?", "emoji 😀👍🏽 ok", "  two  spaces\n"] {
            #expect(tokenizer.decode(tokenIds: tokenizer.encode(text: text, addSpecialTokens: false), skipSpecialTokens: true) == text)
        }
        let withEnd = tokenizer.encode(text: "好<|im_end|>", addSpecialTokens: false)
        #expect(tokenizer.decode(tokenIds: withEnd, skipSpecialTokens: true) == "好")
        #expect(tokenizer.decode(tokenIds: withEnd, skipSpecialTokens: false) == "好<|im_end|>")
        #expect(tokenizer.eosTokenId == 151_645)
        #expect(tokenizer.convertTokenToId("<|im_start|>") == 151_644)
    }
}
