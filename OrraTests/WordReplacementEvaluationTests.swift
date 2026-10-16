import Foundation
import Testing
@testable import Orra

/// WordReplacement on text that is correct, where every replacement is a false one. Text
/// only: no model is loaded.
struct WordReplacementEvaluationTests {
    /// Pairs as learning keeps them, the safe ones and the ones that must never replace.
    static let pairs = [
        Correction(heard: "克劳德", corrected: "Claude"),
        Correction(heard: "通一千问", corrected: "通义千问"),
        Correction(heard: "同意千万", corrected: "通义千问"),
        Correction(heard: "力热吧", corrected: "丽热巴"),
        Correction(heard: "林悦", corrected: "霖悦"),
        Correction(heard: "生根", corrected: "申根"),
        Correction(heard: "时候在", corrected: "是在"),
        Correction(heard: "Ora", corrected: "Orra"),
        Correction(heard: "Kwen", corrected: "Qwen"),
        Correction(heard: "kvlite", corrected: "KVLite"),
        Correction(heard: "Kubernetis", corrected: "Kubernetes"),
        Correction(heard: "cloud code", corrected: "Claude Code"),
        Correction(heard: "there", corrected: "their"),
        Correction(heard: "a pie", corrected: "API"),
        Correction(heard: "form", corrected: "from"),
    ]
    static let vocabulary = Array(Set(pairs.map(\.corrected))) + ["Orra", "Qwen3-ASR", "KVLite-Nova", "迪丽热巴"]

    /// Every text of the evaluation sets in Tools/rewrite-eval: dictations, their cleaned
    /// and translated forms, and the number cases.
    static let texts: [String] = {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/rewrite-eval")
        var texts: [String] = []
        for file in ["cases.jsonl", "adversarial.jsonl", "numbers.jsonl"] {
            guard let content = try? String(contentsOf: tools.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                texts += object.filter { $0.key != "id" && $0.key != "note" && $0.key != "notes" }.values.compactMap { $0 as? String }
            }
        }
        return texts
    }()

    @Test func theRewriteEvaluationTextsGetNoReplacement() {
        #expect(Self.texts.count > 2_000)
        for text in Self.texts {
            let result = WordReplacement.apply(to: text, pairs: Self.pairs, vocabulary: Self.vocabulary, ordinary: .system)
            #expect(result.replacements.isEmpty, "\(text)")
        }
    }

    /// Only the pairs that are no ordinary words are used. Ora is one in the system's list.
    @Test func onlyThePairsOfNamesAreUsed() {
        let usable = WordReplacement.usablePairs(Self.pairs, vocabulary: Self.vocabulary, ordinary: .system)
        #expect(Set(usable.map(\.heard)) == ["克劳德", "通一千问", "力热吧", "林悦", "Kwen", "kvlite", "Kubernetis"])
    }
}

/// Measures the replacements on the evaluation data, without a model. Runs only when asked
/// for, with TEST_RUNNER_ORRA_REPLACEMENT_EVAL=1, and only when the data is on this Mac:
/// the stored Qwen3-ASR 1.7B transcripts in results/ and the ContextASR texts in
/// contextasr/ of the evaluation folder.
///
/// The pairs are the ones learning would keep if the user fixed every stored transcript
/// to its reference. They are applied to correct text, the references and the ContextASR
/// texts, where every replacement is false, and to the transcripts, where a replacement is
/// a fix when the reference holds the word more often than the transcript did. The report
/// holds numbers only. It goes to an attachment and to results/word-replacement.txt.
struct WordReplacementDataEvaluationTests {
    private static var root: URL { EvaluationData.root }

    private static func lines(_ path: String) -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_REPLACEMENT_EVAL"] != nil))
    func learnedPairsOnStoredText() throws {
        var english: [String] = []
        var chinese: [String] = []
        for file in ["contextasr/ContextASR-Speech_English.jsonl", "contextasr/ContextASR-Speech_Mandarin.jsonl"] {
            for line in Self.lines(file) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let text = object["text"] as? String else { continue }
                if Self.hasHan(text) { chinese.append(text) } else { english.append(text) }
            }
        }
        // The stored transcripts, through the rule steps as the controller runs them.
        var clips: [(id: String, reference: String, transcript: String)] = []
        for file in ["q17_auto.fleurs_en", "q17_auto.fleurs_zh", "q17_auto.ascend_mixed"] {
            for line in Self.lines("results/\(file).scored.tsv") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { continue }
                let transcript = NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: ChineseText.simplified(parts[3])))
                clips.append((parts[1], parts[2], transcript))
                if Self.hasHan(parts[2]) { chinese.append(parts[2]) } else { english.append(parts[2]) }
            }
        }
        try #require(!clips.isEmpty && !english.isEmpty)
        var learnedFrom: [Correction: Set<String>] = [:]
        for clip in clips {
            for finding in CorrectionFinder.findings(pasted: clip.transcript, edited: clip.reference) {
                learnedFrom[finding.correction, default: []].insert(clip.id)
            }
        }
        let pairs = Array(learnedFrom.keys)
        let vocabulary = Array(Set(pairs.map(\.corrected)))
        let none = OrdinaryWords([])
        func falseCount(_ texts: [String], _ ordinary: OrdinaryWords) -> Int {
            texts.reduce(0) { $0 + WordReplacement.apply(to: $1, pairs: pairs, vocabulary: vocabulary, ordinary: ordinary).replacements.count }
        }
        var fixed = (same: 0, other: 0)
        var broken = (same: 0, other: 0)
        for clip in clips {
            for same in [true, false] {
                let chosen = pairs.filter { learnedFrom[$0]?.contains(clip.id) == same }
                for replacement in WordReplacement.apply(to: clip.transcript, pairs: chosen, vocabulary: vocabulary, ordinary: .system).replacements {
                    let inReference = clip.reference.components(separatedBy: replacement.corrected).count
                    let inTranscript = clip.transcript.components(separatedBy: replacement.corrected).count
                    switch (inReference > inTranscript, same) {
                    case (true, true): fixed.same += 1
                    case (true, false): fixed.other += 1
                    case (false, true): broken.same += 1
                    case (false, false): broken.other += 1
                    }
                }
            }
        }
        let usable = WordReplacement.usablePairs(pairs, vocabulary: vocabulary, ordinary: .system).count
        let report = """
        Word replacement, text only
        \(pairs.count) pairs learned from \(clips.count) transcripts, \(usable) used
        false replacements in \(english.count) English texts: \(falseCount(english, .system)), without the ordinary word check \(falseCount(english, none))
        false replacements in \(chinese.count) Chinese texts: \(falseCount(chinese, .system)), without the ordinary word check \(falseCount(chinese, none))
        same sentence again: \(fixed.same) fixed, \(broken.same) broken
        other transcripts: \(fixed.other) fixed, \(broken.other) broken
        """
        Attachment.record(report, named: "word-replacement.txt")
        let results = Self.root.appendingPathComponent("results", isDirectory: true)
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try report.write(to: results.appendingPathComponent("word-replacement.txt"), atomically: true, encoding: .utf8)
    }
}
