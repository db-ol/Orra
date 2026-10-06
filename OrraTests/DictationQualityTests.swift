import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Checks the real Qwen3-ASR 1.7B model the way dictation uses it: holds without speech,
/// pauses around speech, audio at a microphone's sample rate through the whole controller,
/// and a long dictation. Skipped when the model or the evaluation data is not on this Mac.
///
/// Two heavier checks run only when asked for, through environment variables that
/// xcodebuild passes on when they carry the TEST_RUNNER_ prefix:
/// TEST_RUNNER_ORRA_FULL_EVAL=1 runs all 600 evaluation clips, and TEST_RUNNER_ORRA_SOAK=1
/// runs 200 dictations in a row to watch memory.
///
/// Attachments hold numbers only, never transcript text.
extension RealModelTests {
    @MainActor
    @Suite
    struct DictationQualityTests {
        nonisolated private static let rate = RecordingLimits.sampleRate

        /// The processing PushToTalkController applies before pasting.
        private static func finalText(_ raw: String, samples: [Float]) -> String {
            ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: Double(samples.count) / Double(rate)))
        }

        private static func silence(seconds: Double) -> [Float] {
            [Float](repeating: 0, count: Int(seconds * Double(rate)))
        }

        private static func hum(seconds: Double, dbfs: Double) -> [Float] {
            let amplitude = Float(pow(10, dbfs / 20)) * Float(2.0.squareRoot())
            return (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * Float.pi * 50 * Float($0) / Float(rate)) }
        }

        /// White noise from a fixed seed, so every run hears the same noise. The level is the
        /// RMS level, like the levels of the evaluation clips in docs/asr-baseline.md.
        private struct SeededNoise {
            private var state: UInt64

            init(seed: UInt64) {
                state = seed
            }

            mutating func samples(seconds: Double, dbfs: Double) -> [Float] {
                // Uniform noise between -a and a has an RMS of a divided by the root of 3.
                let amplitude = Float(pow(10, dbfs / 20)) * Float(3.0.squareRoot())
                return (0..<Int(seconds * Double(DictationQualityTests.rate))).map { _ in
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
                }
            }
        }

        /// Converts mono samples between sample rates, the way a microphone at 48 kHz would
        /// have delivered a 16 kHz clip.
        private static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
            let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false))
            let outputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false))
            let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)))
            input.frameLength = input.frameCapacity
            samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            let capacity = AVAudioFrameCount((Double(samples.count) * target / source).rounded(.up)) + 1_024
            let output = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity))
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            #expect(status != .error)
            return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }

        private static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        /// Waits until `condition` holds, for at most `timeout`.
        private static func waitUntil(timeout: Duration = .seconds(60), _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        @Test func holdsWithoutSpeechGiveNoText() async throws {
            let engine = Qwen3Engine()
            try await engine.load()
            var noise = SeededNoise(seed: 0x5EED)
            let inputs: [(String, [Float])] = [
                ("silence 0.4 s", Self.silence(seconds: 0.4)),
                ("silence 3 s", Self.silence(seconds: 3)),
                ("silence 10 s", Self.silence(seconds: 10)),
                ("noise -60 dBFS RMS 2 s", noise.samples(seconds: 2, dbfs: -60)),
                ("noise -45 dBFS RMS 6 s", noise.samples(seconds: 6, dbfs: -45)),
                ("noise -35 dBFS RMS 2 s", noise.samples(seconds: 2, dbfs: -35)),
                ("hum 50 Hz -30 dBFS RMS 2 s", Self.hum(seconds: 2, dbfs: -30)),
            ]
            for (label, samples) in inputs {
                let text = Self.finalText(try await engine.transcribe(samples), samples: samples)
                #expect(text.isEmpty, "\(label) gave \(text.count) characters")
            }
        }

        @Test func pausesAroundSpeechChangeNothing() async throws {
            let engine = Qwen3Engine()
            try await engine.load()
            var noise = SeededNoise(seed: 0xA11CE)
            for (set, dropFillers) in [("fleurs_zh", false), ("ascend_mixed", true)] {
                for clip in try EvaluationData.clips(in: set, count: 2) {
                    let speech = try EvaluationData.samples(set: set, name: clip.name)
                    let alone = Self.finalText(try await engine.transcribe(speech), samples: speech)
                    let base = TranscriptScoring.counts(references: [clip.reference], hypotheses: [alone], dropFillers: dropFillers)
                    let variants = [
                        ("silence before", Self.silence(seconds: 3) + speech),
                        ("silence after", speech + Self.silence(seconds: 3)),
                        ("noise before", noise.samples(seconds: 3, dbfs: -45) + speech),
                        ("noise after", speech + noise.samples(seconds: 3, dbfs: -45)),
                    ]
                    for (label, samples) in variants {
                        let text = Self.finalText(try await engine.transcribe(samples), samples: samples)
                        let errors = TranscriptScoring.counts(references: [clip.reference], hypotheses: [text], dropFillers: dropFillers).errors
                        #expect(errors <= base.errors + 1, "\(set) \(clip.name) \(label): \(errors) errors, \(base.errors) without the pause")
                        // Also against the speech alone, so a clip the model already gets wrong
                        // still checks something.
                        let change = TranscriptScoring.editDistance(TranscriptScoring.tokens(text, dropFillers: dropFillers), TranscriptScoring.tokens(alone, dropFillers: dropFillers))
                        #expect(change <= 1, "\(set) \(clip.name) \(label): \(change) tokens differ from the speech alone")
                    }
                }
            }
        }

        @Test func dictationAtMicrophoneRateMatchesTheClip() async throws {
            // One engine serves both the controller and the direct comparison.
            let engine = Qwen3Engine()
            let mic = FakeMicrophone()
            let inserter = FakeInserter()
            let controller = PushToTalkController(
                capture: mic.capture,
                transcription: Transcription(load: { try await engine.load() }, transcribe: { try await engine.transcribe($0) }),
                insert: inserter.insert,
                frontmostApp: { 100 },
                minimumHold: .zero,
                releaseTail: .zero
            )
            await controller.loadModel()
            #expect(controller.modelState == .ready)

            var report: [String] = []
            for (set, dropFillers) in [("fleurs_zh", false), ("fleurs_en", false), ("ascend_mixed", true)] {
                for clip in try EvaluationData.clips(in: set, count: 2) {
                    let speech = try EvaluationData.samples(set: set, name: clip.name)
                    let direct = Self.finalText(try await engine.transcribe(speech), samples: speech)

                    // The microphone delivers 48 kHz, and the controller resamples to 16 kHz.
                    mic.recording = AudioRecording(samples: try Self.resample(speech, from: 16_000, to: 48_000), sampleRate: 48_000)
                    let before = inserter.inserted.count
                    controller.handle(.pressed(isRepeat: false))
                    try await Self.waitUntil { mic.calls.last == "start" }
                    let released = ContinuousClock.now
                    controller.handle(.released)
                    try await Self.waitUntil { controller.state == .idle }
                    let latency = released.duration(to: .now)
                    #expect(controller.state == .idle)
                    #expect(controller.problem == nil)
                    let pasted = inserter.inserted.count > before ? inserter.inserted[before] : ""
                    #expect(!pasted.isEmpty || direct.isEmpty, "\(set) \(clip.name): nothing was pasted")
                    let change = TranscriptScoring.editDistance(TranscriptScoring.tokens(pasted, dropFillers: dropFillers), TranscriptScoring.tokens(direct, dropFillers: dropFillers))
                    #expect(change <= 1, "\(set) \(clip.name): \(change) tokens differ from the direct result")

                    let viaController = TranscriptScoring.counts(references: [clip.reference], hypotheses: [pasted], dropFillers: dropFillers)
                    let viaEngine = TranscriptScoring.counts(references: [clip.reference], hypotheses: [direct], dropFillers: dropFillers)
                    #expect(viaController.errors <= viaEngine.errors + 1, "\(set) \(clip.name): \(viaController.errors) errors through the controller, \(viaEngine.errors) direct")
                    let seconds = Double(speech.count) / Double(Self.rate)
                    report.append("\(set) \(clip.name): \(String(format: "%.1f", seconds)) s, release to paste \(latency), errors \(viaController.errors) of \(viaController.tokens), direct \(viaEngine.errors)")
                }
            }
            Attachment.record(report.joined(separator: "\n"), named: "dictation-48khz.txt")
        }

        @Test func longDictationStaysAccurate() async throws {
            let engine = Qwen3Engine()
            try await engine.load()
            var report: [String] = []
            for (set, dropFillers, target) in [("fleurs_zh", false, 58.0), ("ascend_mixed", true, 30.0)] {
                // Clips joined with short pauses, up to the target length, never past 60 s.
                var samples: [Float] = []
                var references: [String] = []
                var single = (errors: 0, tokens: 0)
                for clip in try EvaluationData.clips(in: set, count: 40) {
                    let speech = try EvaluationData.samples(set: set, name: clip.name)
                    let next = samples.count + speech.count + Self.rate / 2
                    guard Double(next) / Double(Self.rate) <= target else { continue }
                    let alone = Self.finalText(try await engine.transcribe(speech), samples: speech)
                    let counts = TranscriptScoring.counts(references: [clip.reference], hypotheses: [alone], dropFillers: dropFillers)
                    single = (single.errors + counts.errors, single.tokens + counts.tokens)
                    samples += speech + Self.silence(seconds: 0.5)
                    references.append(clip.reference)
                }
                let seconds = Double(samples.count) / Double(Self.rate)
                let start = ContinuousClock.now
                let text = Self.finalText(try await engine.transcribe(samples), samples: samples)
                let latency = start.duration(to: .now)
                let joined = TranscriptScoring.counts(references: [references.joined(separator: " ")], hypotheses: [text], dropFillers: dropFillers)
                let joinedRate = 100 * Double(joined.errors) / Double(max(joined.tokens, 1))
                let singleRate = 100 * Double(single.errors) / Double(max(single.tokens, 1))
                report.append("\(set): \(references.count) clips, \(String(format: "%.1f", seconds)) s, \(latency), error \(String(format: "%.1f", joinedRate))% joined, \(String(format: "%.1f", singleRate))% one by one")
                #expect(seconds <= RecordingLimits.maximumSeconds)
                #expect(joinedRate <= singleRate + 3, "\(set): \(joinedRate)% joined against \(singleRate)% one by one")
            }
            Attachment.record(report.joined(separator: "\n"), named: "long-dictation.txt")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_FULL_EVAL"] != nil))
        func fullEvaluation() async throws {
            let engine = Qwen3Engine()
            try await engine.load()
            var report: [String] = []
            for (set, dropFillers) in [("fleurs_zh", false), ("fleurs_en", false), ("ascend_mixed", true)] {
                let clips = try EvaluationData.clips(in: set, count: 1_000)
                let baseline = try EvaluationData.baseline(engine: "q17_auto", set: set)
                let theirTexts = try clips.map { try #require(baseline[$0.name], "no baseline for \($0.name)") }
                var hypotheses: [String] = []
                var latencies: [Double] = []
                for clip in clips {
                    let speech = try EvaluationData.samples(set: set, name: clip.name)
                    let start = ContinuousClock.now
                    let raw = try await engine.transcribe(speech)
                    latencies.append(Self.seconds(start.duration(to: .now)))
                    hypotheses.append(Self.finalText(raw, samples: speech))
                }
                let references = clips.map(\.reference)
                let ours = TranscriptScoring.errorRate(references: references, hypotheses: hypotheses, dropFillers: dropFillers)
                let theirs = TranscriptScoring.errorRate(references: references, hypotheses: theirTexts, dropFillers: dropFillers)
                let sorted = latencies.sorted()
                report.append("\(set): \(clips.count) clips, error \(String(format: "%.2f", ours))% against baseline \(String(format: "%.2f", theirs))%, latency median \(String(format: "%.3f", sorted[sorted.count / 2])) s, p95 \(String(format: "%.3f", sorted[sorted.count * 95 / 100])) s, worst \(String(format: "%.3f", sorted.last!)) s")
                #expect(ours <= theirs + 1, "\(set): \(ours)% against baseline \(theirs)%")
            }
            Attachment.record(report.joined(separator: "\n"), named: "full-evaluation.txt")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_SOAK"] != nil))
        func memoryStaysBoundedOverManyDictations() async throws {
            let engine = Qwen3Engine()
            try await engine.load()
            let afterLoad = MemoryFootprint.current()
            let clips = try EvaluationData.clips(in: "fleurs_zh", count: 50)
            var report: [String] = []
            var latencies: [Double] = []
            var series: [String] = []
            var footprints: [UInt64] = []
            var first: UInt64 = 0
            for round in 0..<200 {
                let clip = clips[round % clips.count]
                let speech = try EvaluationData.samples(set: "fleurs_zh", name: clip.name)
                let start = ContinuousClock.now
                _ = try await engine.transcribe(speech)
                latencies.append(Self.seconds(start.duration(to: .now)))
                let footprint = MemoryFootprint.current()
                footprints.append(footprint)
                if round == 0 {
                    first = footprint
                }
                series.append("\(round + 1) \(Int(latencies.last! * 1000)) ms \(footprint / 1_000_000) MB")
                if (round + 1) % 25 == 0 {
                    report.append("after \(round + 1): \(footprint / 1_000_000) MB")
                }
            }
            let last = MemoryFootprint.current()
            let sorted = latencies.sorted()
            let median = sorted[sorted.count / 2]
            report.append("after 1: \(first / 1_000_000) MB, latency median \(String(format: "%.3f", median)) s, p95 \(String(format: "%.3f", sorted[sorted.count * 95 / 100])) s, worst \(String(format: "%.3f", sorted.last!)) s, over twice the median: \(latencies.filter { $0 > 2 * median }.count)")
            Attachment.record(report.joined(separator: "\n"), named: "memory-soak.txt")
            Attachment.record(series.joined(separator: "\n"), named: "memory-soak-series.txt")
            // Single readings swing by more than 1 GB with the clip, so compare medians of an
            // early and a late window of 50 dictations.
            let early = footprints[25..<75].sorted()[25]
            let late = footprints[150..<200].sorted()[25]
            #expect(late <= early + 500_000_000, "median \(late / 1_000_000) MB late against \(early / 1_000_000) MB early, \(last / 1_000_000) MB after 200")
            // Memory that settles higher at once, see the same check in Qwen3EngineTests.
            #expect(late <= afterLoad + 2_500_000_000, "median \(late / 1_000_000) MB late, \(afterLoad / 1_000_000) MB after load")
        }
    }
}
