import Foundation
import Testing
@testable import Orra

/// Measures a vocabulary given to Qwen3-ASR as context. Runs only when asked for, with
/// TEST_RUNNER_ORRA_CONTEXT_EVAL=1, and only on sets that are on this Mac.
///
/// - contextasr_zh and contextasr_en come from ContextASR-Bench through
///   Tools/asr-eval/prep_contextasr.py. Each clip lists the terms it contains. Every clip is
///   transcribed twice: without context, and with its own terms mixed with ten terms from
///   other clips that it does not contain, as a real vocabulary would be.
/// - ascend_mixed checks that a vocabulary unrelated to the speech does no harm.
/// - Silence, hum and noise check that a vocabulary does not make the model say its words
///   when nobody speaks.
///
/// The report holds numbers only, never transcript text. It goes to an attachment and to
/// results/context-evaluation.txt in the evaluation folder.
extension RealModelTests {
    @MainActor
    @Suite
    struct ContextEvaluationTests {
        nonisolated private static let rate = RecordingLimits.sampleRate
        private static let distractorsPerClip = 10

        /// What the controller pastes: loops cut, traditional characters converted.
        private static func finalText(_ raw: String, samples: [Float]) -> String {
            ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: Double(samples.count) / Double(rate)))
        }

        /// Lowercase letters and digits only, so "N P C 行为树" matches "NPC行为树".
        static func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(ChineseText.simplified(text).lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }))
        }

        /// The terms file of a set: clip name to its terms.
        private static func terms(in set: String) throws -> [String: [String]] {
            let url = EvaluationData.root.appendingPathComponent("sets/\(set)/terms.tsv")
            var result: [String: [String]] = [:]
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                result[String(parts[0].dropLast(4))] = parts[1].split(separator: "|").map(String.init)
            }
            return result
        }

        private static func hasSet(_ set: String) -> Bool {
            FileManager.default.fileExists(atPath: EvaluationData.root.appendingPathComponent("sets/\(set)/terms.tsv").path)
        }

        private static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        private static func percent(_ part: Int, _ whole: Int) -> String {
            String(format: "%.1f%%", 100 * Double(part) / Double(max(whole, 1)))
        }

        private static func latencyLine(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "no clips" }
            return String(format: "median %.2f s, p95 %.2f s", sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
        }

        /// One pass over the clips of a set, without or with context.
        private struct Pass {
            var hypotheses: [String] = []
            var termsFound = 0
            var distractorsInserted = 0
            var latencies: [Double] = []
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_CONTEXT_EVAL"] != nil))
        func vocabularyAsContext() async throws {
            let engine = RealModel.engine()
            try await engine.load()
            let count = Int(ProcessInfo.processInfo.environment["ORRA_CONTEXT_COUNT"] ?? "") ?? 100
            var report: [String] = ["Context evaluation, \(count) clips per set at most"]
            var unrelatedTerms: [String] = []

            for set in ["contextasr_zh", "contextasr_en"] where Self.hasSet(set) {
                let clips = try EvaluationData.clips(in: set, count: count)
                let termsByClip = try Self.terms(in: set)
                let allTerms = clips.flatMap { termsByClip[$0.name] ?? [] }
                unrelatedTerms += allTerms.prefix(15)
                var plain = Pass()
                var biased = Pass()
                var termCount = 0
                var distractorCount = 0
                for (index, clip) in clips.enumerated() {
                    let own = termsByClip[clip.name] ?? []
                    let reference = Self.normalized(clip.reference)
                    // Terms of the following clips that this clip does not contain.
                    let distractors = (1...clips.count).lazy
                        .flatMap { termsByClip[clips[(index + $0) % clips.count].name] ?? [] }
                        .filter { !reference.contains(Self.normalized($0)) }
                        .prefix(Self.distractorsPerClip)
                    let offered = Array(distractors)
                    // Interleaved, so the clip's own terms are not always first.
                    var vocabulary: [String] = []
                    for position in 0..<max(own.count, offered.count) {
                        if position < offered.count { vocabulary.append(offered[position]) }
                        if position < own.count { vocabulary.append(own[position]) }
                    }
                    let context = vocabulary.joined(separator: "\n")
                    let speech = try EvaluationData.samples(set: set, name: clip.name)
                    let counted = own.filter { reference.contains(Self.normalized($0)) }
                    termCount += counted.count
                    distractorCount += offered.count
                    for withContext in [false, true] {
                        let start = ContinuousClock.now
                        let raw = try await engine.transcribe(speech, context: withContext ? context : nil)
                        let elapsed = Self.seconds(start.duration(to: .now))
                        let text = Self.finalText(raw, samples: speech)
                        let heard = Self.normalized(text)
                        let found = counted.filter { heard.contains(Self.normalized($0)) }.count
                        let inserted = offered.filter { heard.contains(Self.normalized($0)) }.count
                        if withContext {
                            biased.hypotheses.append(text); biased.termsFound += found; biased.distractorsInserted += inserted; biased.latencies.append(elapsed)
                        } else {
                            plain.hypotheses.append(text); plain.termsFound += found; plain.distractorsInserted += inserted; plain.latencies.append(elapsed)
                        }
                    }
                }
                let references = clips.map(\.reference)
                let plainRate = TranscriptScoring.errorRate(references: references, hypotheses: plain.hypotheses, dropFillers: false)
                let biasedRate = TranscriptScoring.errorRate(references: references, hypotheses: biased.hypotheses, dropFillers: false)
                report.append("""
                \(set): \(clips.count) clips, \(termCount) term occurrences, \(distractorCount) distractors offered
                  terms recognized: \(Self.percent(plain.termsFound, termCount)) without context, \(Self.percent(biased.termsFound, termCount)) with
                  distractors inserted: \(Self.percent(plain.distractorsInserted, distractorCount)) without, \(Self.percent(biased.distractorsInserted, distractorCount)) with
                  error rate: \(String(format: "%.2f", plainRate))% without, \(String(format: "%.2f", biasedRate))% with
                  latency: \(Self.latencyLine(plain.latencies)) without, \(Self.latencyLine(biased.latencies)) with
                """)
            }

            // A vocabulary that has nothing to do with the speech.
            let vocabulary = (unrelatedTerms.isEmpty ? ["Orra", "Qwen3-ASR", "speech-swift"] : unrelatedTerms).joined(separator: "\n")
            let unrelated = vocabulary.split(separator: "\n").map(String.init)
            if FileManager.default.fileExists(atPath: EvaluationData.root.appendingPathComponent("sets/ascend_mixed/refs.tsv").path) {
                let clips = try EvaluationData.clips(in: "ascend_mixed", count: 200)
                var plain: [String] = []
                var biased: [String] = []
                var inserted = 0
                for clip in clips {
                    let speech = try EvaluationData.samples(set: "ascend_mixed", name: clip.name)
                    plain.append(Self.finalText(try await engine.transcribe(speech), samples: speech))
                    let text = Self.finalText(try await engine.transcribe(speech, context: vocabulary), samples: speech)
                    biased.append(text)
                    let heard = Self.normalized(text)
                    let reference = Self.normalized(clip.reference)
                    inserted += unrelated.filter { heard.contains(Self.normalized($0)) && !reference.contains(Self.normalized($0)) }.count
                }
                let references = clips.map(\.reference)
                let plainRate = TranscriptScoring.errorRate(references: references, hypotheses: plain, dropFillers: true)
                let biasedRate = TranscriptScoring.errorRate(references: references, hypotheses: biased, dropFillers: true)
                report.append("ascend_mixed with \(unrelated.count) unrelated terms: error \(String(format: "%.2f", plainRate))% without, \(String(format: "%.2f", biasedRate))% with, \(inserted) terms inserted in \(clips.count) clips")
            }

            // Nobody speaks.
            var spoken = 0
            let quiet: [(String, [Float])] = [
                ("silence", [Float](repeating: 0, count: 3 * Self.rate)),
                ("hum", (0..<(3 * Self.rate)).map { 0.014 * sin(2 * Float.pi * 50 * Float($0) / Float(Self.rate)) }),
                ("noise", (0..<(3 * Self.rate)).map { Float(($0 &* 1_103_515_245 &+ 12_345) % 65_536) / 65_536 * 0.006 - 0.003 }),
            ]
            for (_, samples) in quiet {
                let text = Self.finalText(try await engine.transcribe(samples, context: vocabulary), samples: samples)
                if !text.isEmpty { spoken += 1 }
            }
            report.append("no speech with \(unrelated.count) terms as context: \(spoken) of \(quiet.count) gave text")

            let text = report.joined(separator: "\n")
            Attachment.record(text, named: "context-evaluation.txt")
            let results = EvaluationData.root.appendingPathComponent("results", isDirectory: true)
            try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            try text.write(to: results.appendingPathComponent("context-evaluation.txt"), atomically: true, encoding: .utf8)
        }
    }
}
