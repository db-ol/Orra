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

    @Test func theModelLoadsOnlyFromACompleteInstalledFolder() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        #expect(SpeechModel.installedFolder(temporary.folders, temporary.manifest) == nil)
        // Weights without the tokenizer would paste token numbers, so they do not count.
        try temporary.write(["model.safetensors", "config.json", "model.safetensors.index.json"], to: temporary.installed)
        #expect(SpeechModel.installedFolder(temporary.folders, temporary.manifest) == nil)
        try temporary.writeAll(to: temporary.installed)
        #expect(SpeechModel.installedFolder(temporary.folders, temporary.manifest) == temporary.installed)
        // A copy in the old cache is not loaded from. Launch installs it first.
        let other = TemporaryModelFolders()
        defer { other.remove() }
        try other.writeAll(to: other.folders.oldCopies[0])
        #expect(SpeechModel.installedFolder(other.folders, other.manifest) == nil)
    }

    @Test func theEngineReportsAMissingModelWithoutLoading() async {
        let engine = Qwen3Engine(folder: { nil })
        await #expect(throws: TranscriptionError.modelMissing) {
            try await engine.load()
        }
    }

    @Test func modelIdIsTheChosenOne() {
        #expect(SpeechModel.id == "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
    }
}
