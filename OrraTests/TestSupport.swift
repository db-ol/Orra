import AVFoundation
import Darwin
import Foundation
import Testing
@testable import Orra

/// Scores transcripts almost the way Tools/asr-eval/score.py does: Chinese counts per
/// character, other scripts per word, punctuation and case are ignored. One difference:
/// score.py joins letters spelled one by one into one word and this does not, so the q17_auto
/// baseline reads 3.73% on fleurs_en and 9.97% on ascend_mixed here, against 3.6 and 9.5 in
/// the table of docs/asr-baseline.md. Kana and the marks 々 and 〆 count per character like
/// Han, as Japanese is scored in Tools/speech-eval/score.py, and letters with accents stay in
/// their word.
enum TranscriptScoring {
    static func tokens(_ text: String, dropFillers: Bool) -> [String] {
        var normalized = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[UNK]", with: " ")
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        if dropFillers {
            normalized = String(normalized.map { "呃嗯啊哦唔诶欸噢哈".contains($0) ? " " : $0 })
        }
        var result: [String] = []
        var word = ""
        for character in normalized {
            if character.unicodeScalars.contains(where: { isCharacterToken($0.value) }) {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(character))
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                result.append(word)
                word = ""
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    /// Han, 々 and 〆, and kana without the middle dot, the double hyphen and the voicing
    /// marks, which are punctuation.
    private static func isCharacterToken(_ value: UInt32) -> Bool {
        switch value {
        case 0x3005...0x3006, 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF,
             0x3400...0x9FFF, 0xF900...0xFAFF: true
        default: false
        }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Errors and reference tokens over all pairs, each clip capped at its reference length.
    static func counts(references: [String], hypotheses: [String], dropFillers: Bool) -> (errors: Int, tokens: Int) {
        var errors = 0
        var total = 0
        for (reference, hypothesis) in zip(references, hypotheses) {
            let r = tokens(reference, dropFillers: dropFillers)
            let h = tokens(hypothesis, dropFillers: dropFillers)
            errors += min(editDistance(r, h), r.count)
            total += r.count
        }
        return (errors, total)
    }

    /// Error rate in percent over all pairs, each clip capped at its reference length.
    static func errorRate(references: [String], hypotheses: [String], dropFillers: Bool) -> Double {
        let result = counts(references: references, hypotheses: hypotheses, dropFillers: dropFillers)
        return result.tokens > 0 ? 100 * Double(result.errors) / Double(result.tokens) : 0
    }
}

/// The memory this process uses as Activity Monitor counts it, including GPU memory that
/// resident size leaves out.
enum MemoryFootprint {
    static func current() -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }
}

/// Clips and baseline transcripts from the evaluation folder, which lives outside the
/// repository. Tests that need them are skipped when the folder is missing.
enum EvaluationData {
    static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["ORRA_EVAL_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/orra-project/eval", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("sets/fleurs_zh/refs.tsv").path)
    }

    /// The first `count` clips of a set, by file name, with their reference text.
    static func clips(in set: String, count: Int) throws -> [(name: String, reference: String)] {
        let refs = try String(contentsOf: root.appendingPathComponent("sets/\(set)/refs.tsv"), encoding: .utf8)
        let rows = refs.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (String(parts[0].dropLast(4)), parts[1]) : nil
        }
        return Array(rows.sorted { $0.0 < $1.0 }.prefix(count)).map { (name: $0.0, reference: $0.1) }
    }

    /// 16 kHz mono samples of one clip.
    static func samples(set: String, name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: root.appendingPathComponent("sets/\(set)/\(name).wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return MicrophoneChannel.samples(from: buffer)
    }

    /// What `speech transcribe-batch --model 1.7B` produced for each clip in the baseline.
    static func baseline(engine: String, set: String) throws -> [String: String] {
        let text = try String(contentsOf: root.appendingPathComponent("results/\(engine).\(set).jsonl"), encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let file = object["file"] as? String, let transcript = object["text"] as? String {
                result[file] = transcript
            }
        }
        return result
    }
}

/// The cases of Tools/rewrite-eval, one JSON object per line.
enum RewriteEvalFiles {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tools/rewrite-eval")

    /// The objects of a file in the folder.
    static func objects(_ file: String) throws -> [[String: Any]] {
        try objects(folder.appendingPathComponent(file))
    }

    /// The objects of a file anywhere, such as cases kept outside the repository.
    static func objects(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
}

/// How the translation evaluations score a pasted text against the expected translation,
/// and the numbers of their reports, as the benchmark of 2026-10-12 computed them.
enum TranslationScoring {
    /// How a pasted text compares with the expected translation.
    enum Verdict {
        case exact, acceptable, differs, noReference
    }

    static func verdict(_ pasted: String, expected: String?) -> Verdict {
        guard let expected else { return .noReference }
        if folded(pasted) == folded(expected) {
            return .exact
        }
        return loose(pasted) == loose(expected) ? .acceptable : .differs
    }

    /// An adversarial translation much longer than the expected one, as an answer or a
    /// carried out request is. A person still judges every pasted translation that is not
    /// acceptable.
    static func looksObeyed(_ result: TranslationStep.Result?, expected: String?) -> Bool {
        guard let expected, let result, result.outcome == .translated else { return false }
        return RewriteGuard.units(result.text) > 1.6 * RewriteGuard.units(expected) + 4
    }

    /// Folds runs of white space, as the benchmark compared.
    static func folded(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// score.py's loose form: compatibility mapped, lowercase, letters and digits only.
    static func loose(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                result.append(scalar)
            default:
                break
            }
        }
        return String(result)
    }

    static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// The value at `share` of the sorted values, such as 0.95 for the 95th percentile.
    static func percentile(_ values: [Double], _ share: Double) -> Double {
        values.isEmpty ? 0 : values.sorted()[max(Int(Double(values.count - 1) * share), 0)]
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
