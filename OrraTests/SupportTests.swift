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

    @Test func scoringCountsKanaPerCharacterAndKeepsAccents() {
        #expect(TranscriptScoring.tokens("人々は「モササウルス・ゲーム」を見た。", dropFillers: false) == ["人", "々", "は", "モ", "サ", "サ", "ウ", "ル", "ス", "ゲ", "ー", "ム", "を", "見", "た"])
        #expect(TranscriptScoring.tokens("ｶﾞｰﾃﾞﾝ", dropFillers: false) == ["ガ", "ー", "デ", "ン"])
        #expect(TranscriptScoring.tokens("¿El año pasado?", dropFillers: false) == ["el", "año", "pasado"])
        #expect(TranscriptScoring.errorRate(references: ["東京へ行きます"], hypotheses: ["東京に行きます"], dropFillers: false) == 100.0 / 7)
    }

    /// Tools/speech-eval/token-cases.jsonl, which test_score.py checks against score.py: the
    /// same tokens for each text and the same errors for each reference and hypothesis, or
    /// the tokens a case lists under transcript_scoring where the two differ on purpose.
    @Test func scoringAgreesWithTheSpeechEvaluationScorer() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/speech-eval/token-cases.jsonl")
        let cases = try RewriteEvalFiles.objects(file)
        #expect(cases.count >= 30)
        for item in cases {
            if let text = item["text"] as? String {
                let expected = try #require((item["transcript_scoring"] ?? item["tokens"]) as? [String])
                #expect(TranscriptScoring.tokens(text, dropFillers: false) == expected, "\(text)")
            } else {
                let reference = try #require(item["reference"] as? String)
                let hypothesis = try #require(item["hypothesis"] as? String)
                let counts = TranscriptScoring.counts(references: [reference], hypotheses: [hypothesis], dropFillers: false)
                #expect(counts.errors == item["errors"] as? Int, "\(reference)")
                #expect(counts.tokens == item["reference_tokens"] as? Int, "\(reference)")
            }
        }
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
