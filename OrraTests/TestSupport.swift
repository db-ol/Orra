import AVFoundation
import Darwin
import Foundation
@testable import Orra

/// Scores transcripts almost the way Tools/asr-eval/score.py does: Chinese counts per
/// character, other scripts per word, punctuation and case are ignored. One difference:
/// score.py joins letters spelled one by one into one word and this does not, so the q17_auto
/// baseline reads 3.73% on fleurs_en and 9.97% on ascend_mixed here, against 3.6 and 9.5 in
/// the table of docs/asr-baseline.md.
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
            if character.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }) {
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
