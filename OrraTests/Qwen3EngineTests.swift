import Foundation
import Testing
@testable import Orra

/// Runs the real Qwen3-ASR 1.7B model on 10 clips of the public evaluation sets and
/// compares the result with the baseline in docs/asr-baseline.md, then measures load time,
/// latency and memory over 20 dictations. The numbers are attached to the test result as
/// qwen3-measurements.txt. Skipped when the model or the evaluation data is not on this
/// Mac, which on the maintainer's Mac means something is wrong.
extension RealModelTests {
    @Suite
    struct Qwen3EngineTests {
        @Test func matchesTheBaselineAndKeepsMemoryBounded() async throws {
            let engine = RealModel.engine()
            let loadStart = ContinuousClock.now
            try await engine.load()
            let loadTime = loadStart.duration(to: .now)
            // Memory with the model loaded and idle, as it sits between dictations.
            let footprintAfterLoad = MemoryFootprint.current()
            // The warm up in Qwen3Engine.load reads the weights, about 2.5 GB. Without it this
            // reading is about 0.1 GB.
            #expect(footprintAfterLoad > 1_500_000_000, "\(footprintAfterLoad / 1_000_000) MB after load, the warm up did not touch the weights")

            // Numbers only, never transcript text. Kept as an attachment of the test result.
            var report = ["load \(loadTime), footprint after load \(footprintAfterLoad / 1_000_000) MB"]
            var latencies: [Duration] = []
            var footprints: [UInt64] = []
            // One pooled rate over both sets. Five short mixed clips hold only about 34 tokens,
            // so a per set rate would move by about 3 points for a single token.
            var ours = (errors: 0, tokens: 0)
            var baselines = (errors: 0, tokens: 0)
            for (set, dropFillers) in [("fleurs_zh", false), ("ascend_mixed", true)] {
                let clips = try EvaluationData.clips(in: set, count: 5)
                let baseline = try EvaluationData.baseline(engine: "q17_auto", set: set)
                var transcripts: [String] = []
                for clip in clips {
                    let samples = try EvaluationData.samples(set: set, name: clip.name)
                    let start = ContinuousClock.now
                    let transcript = try await engine.transcribe(samples)
                    let latency = start.duration(to: .now)
                    transcripts.append(transcript)
                    latencies.append(latency)
                    footprints.append(MemoryFootprint.current())
                    let mine = TranscriptScoring.counts(references: [clip.reference], hypotheses: [transcript], dropFillers: dropFillers)
                    let theirText = try #require(baseline[clip.name], "no baseline for \(clip.name)")
                    let theirs = TranscriptScoring.counts(references: [clip.reference], hypotheses: [theirText], dropFillers: dropFillers)
                    let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
                    report.append("\(set) \(clip.name): \(String(format: "%.1f", seconds)) s audio, \(latency), errors \(mine.errors) of \(mine.tokens), baseline \(theirs.errors)")
                }
                let references = clips.map(\.reference)
                let our = TranscriptScoring.counts(references: references, hypotheses: transcripts, dropFillers: dropFillers)
                let theirTexts = try clips.map { try #require(baseline[$0.name], "no baseline for \($0.name)") }
                let theirs = TranscriptScoring.counts(references: references, hypotheses: theirTexts, dropFillers: dropFillers)
                ours = (ours.errors + our.errors, ours.tokens + our.tokens)
                baselines = (baselines.errors + theirs.errors, baselines.tokens + theirs.tokens)
                report.append("\(set): \(our.errors) errors in \(our.tokens) tokens, baseline \(theirs.errors)")
            }
            let ourError = 100 * Double(ours.errors) / Double(max(ours.tokens, 1))
            let baselineError = 100 * Double(baselines.errors) / Double(max(baselines.tokens, 1))
            report.append("pooled error \(ourError) against baseline \(baselineError)")
            // A regression gate on Orra's own measurement: 14 errors in 214 tokens in five
            // identical runs on 2026-10-05, and 4 more tokens (about 2 points) are allowed. The
            // command line baseline is reported but is not the bar. It scored 25, and 12 of
            // those come from one fleurs_zh clip where it wrote the five numbers as Chinese
            // numerals while the reference uses digits. Without that clip the two differ by one.
            #expect(ours.tokens == 214, "the bar of 18 errors was set for 214 tokens")
            #expect(ours.errors <= 18, "\(ours.errors) errors in \(ours.tokens) tokens, 14 measured on 2026-10-05")

            // Ten more dictations, then check that memory did not keep growing.
            let clips = try EvaluationData.clips(in: "fleurs_zh", count: 10)
            for clip in clips {
                let samples = try EvaluationData.samples(set: "fleurs_zh", name: clip.name)
                let start = ContinuousClock.now
                _ = try await engine.transcribe(samples)
                let latency = start.duration(to: .now)
                latencies.append(latency)
                footprints.append(MemoryFootprint.current())
                report.append("again fleurs_zh \(clip.name): \(latency)")
            }
            // A single reading depends on which clip ran last, by up to about 1.3 GB, so
            // compare medians over the same five fleurs_zh clips, dictations 1 to 5 against
            // 11 to 15. That catches slow growth. The ceiling against the reading after load
            // catches memory that settles higher at once, for example if speech-swift stopped
            // clearing its buffer cache after each transcription. Healthy runs sit about 1.2
            // to 1.35 GB above it.
            let early = footprints[0..<5].sorted()[2]
            let late = footprints[10..<15].sorted()[2]
            let sorted = latencies.sorted()
            report.append("latency median \(sorted[sorted.count / 2]) worst \(sorted.last!), footprint after first \(footprints[0] / 1_000_000) MB, median of 1 to 5 \(early / 1_000_000) MB, of 11 to 15 \(late / 1_000_000) MB, after 20 \(footprints[19] / 1_000_000) MB")
            Attachment.record(report.joined(separator: "\n"), named: "qwen3-measurements.txt")
            #expect(late <= early + 1_000_000_000, "\(late / 1_000_000) MB against \(early / 1_000_000) MB")
            #expect(late <= footprintAfterLoad + 2_500_000_000, "\(late / 1_000_000) MB late, \(footprintAfterLoad / 1_000_000) MB after load")
        }
    }
}
