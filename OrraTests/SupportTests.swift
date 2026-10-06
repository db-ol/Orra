import Foundation
import Testing
@testable import Orra

struct SupportTests {
    @Test func scoringCountsChineseCharactersAndEnglishWords() {
        #expect(TranscriptScoring.tokens("这个 PR，先 merge！", dropFillers: false) == ["这", "个", "pr", "先", "merge"])
        #expect(TranscriptScoring.tokens("呃what's the呃", dropFillers: true) == ["whats", "the"])
        #expect(TranscriptScoring.errorRate(references: ["你好 world"], hypotheses: ["你好 word"], dropFillers: false) == 100.0 / 3)
        // A runaway clip counts at most its reference length.
        #expect(TranscriptScoring.errorRate(references: ["好"], hypotheses: [String(repeating: "非常", count: 50)], dropFillers: false) == 100)
    }

    @Test func memoryFootprintIsReadable() {
        #expect(MemoryFootprint.current() > 0)
    }

    private func makeFiles(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
    }

    @Test func modelFilesAreFoundInBothCacheLayouts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orra-model-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SpeechModel.isOnThisMac(id: "owner/Model", base: base) == false)

        let current = base.appendingPathComponent("models/owner/Model", isDirectory: true)
        try makeFiles(["model.safetensors"], in: current)
        // Weights without the tokenizer would paste token numbers, so they do not count.
        #expect(SpeechModel.isOnThisMac(id: "owner/Model", base: base) == false)
        try makeFiles(SpeechModel.tokenizerFiles, in: current)
        #expect(SpeechModel.isOnThisMac(id: "owner/Model", base: base))

        let legacy = base.appendingPathComponent("owner_Legacy", isDirectory: true)
        try makeFiles(["model.safetensors"] + SpeechModel.tokenizerFiles, in: legacy)
        #expect(SpeechModel.isOnThisMac(id: "owner/Legacy", base: base))
    }

    @Test func modelIdIsTheChosenOne() {
        #expect(SpeechModel.id == "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
    }
}
