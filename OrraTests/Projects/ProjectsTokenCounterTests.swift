import Foundation
import Testing
@testable import Orra

struct ProjectsTokenCounterTests {
    @Test func thereIsNoCounterWithoutTheWholeModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsTokenCounterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = ModelFolders(models: root, oldCopies: [])
        #expect(try await ProjectsTokenCounter.installed(in: folders) == nil)

        // The tokenizer files alone are not the model.
        let folder = folders.installed(.qwen35Cleanup)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        #expect(try await ProjectsTokenCounter.installed(in: folders) == nil)
    }

    /// Needs only the tokenizer files of the cleanup model, so it runs whenever the model is
    /// on this Mac, and never touches the GPU.
    @Test(.enabled(if: RewriteTestModel.folder != nil))
    func countsAsTheModelsTokenizerDoes() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let counter = try await ProjectsTokenCounter.reading(folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let texts = [
            "",
            "Hi Iris, the second proof is ready.",
            "白露你好，第二次打样已经好了，周三之前能寄到吗？",
            "<|im_start|>user\nExplain the email.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\nWarnings:\n",
        ]
        for text in texts {
            let expected = tokenizer.encode(text: text, addSpecialTokens: false).count
            #expect(counter.count(text) == expected)
            #expect(counter.countTokens(text) == expected)
        }
        // The chat template's markers are one token each, as the model reads them.
        #expect(counter.count("<|im_start|>") == 1)
    }

    @Test(.enabled(if: RewriteTestModel.folder != nil && ModelDisk.isComplete(ModelFolders.liveCleanup.installed(.qwen35Cleanup), .qwen35Cleanup)))
    func findsTheInstalledModel() async throws {
        let counter = try #require(try await ProjectsTokenCounter.installed())
        #expect(counter.count("Hi Iris") > 0)
    }
}
