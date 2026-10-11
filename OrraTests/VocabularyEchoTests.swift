import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Checks the guard against vocabulary echoes with the real Qwen3-ASR 1.7B model. With a
/// vocabulary as context, the model can answer a hold without speech with terms of the
/// list, see VocabularyEcho. Skipped like every RealModelTests suite when the model or the
/// evaluation data is not on this Mac.
///
/// The vocabularies are terms from the ContextASR sets, Chinese and English in turn, as
/// in the measurement that found the echo. The report holds numbers only, never text. It
/// goes to an attachment and to results/vocabulary-echo.txt in the evaluation folder.
extension RealModelTests {
    @MainActor
    @Suite
    struct VocabularyEchoTests {
        nonisolated private static let rate = RecordingLimits.sampleRate

        /// What the controller pastes: loops cut, traditional characters converted.
        private static func finalText(_ raw: String, seconds: Double) -> String {
            ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: seconds))
        }

        private static func hum(seconds: Double, dbfs: Double) -> [Float] {
            let amplitude = Float(pow(10, dbfs / 20)) * Float(2.0.squareRoot())
            return (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * Float.pi * 50 * Float($0) / Float(rate)) }
        }

        /// White noise from a fixed seed at an RMS level.
        private static func noise(seconds: Double, dbfs: Double, seed: UInt64) -> [Float] {
            var state = seed
            let amplitude = Float(pow(10, dbfs / 20)) * Float(3.0.squareRoot())
            return (0..<Int(seconds * Double(rate))).map { _ in
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
            }
        }

        /// The terms of the first clips of both ContextASR sets, in turn, each once.
        private static func contextTerms() throws -> [String] {
            var lists: [[String]] = []
            for set in ["contextasr_zh", "contextasr_en"] {
                let url = EvaluationData.root.appendingPathComponent("sets/\(set)/terms.tsv")
                var byClip: [String: [String]] = [:]
                for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    byClip[String(parts[0].dropLast(4))] = parts[1].split(separator: "|").map(String.init).filter { !$0.isEmpty }
                }
                lists.append(try EvaluationData.clips(in: set, count: 100).flatMap { byClip[$0.name] ?? [] })
            }
            var seen = Set<String>()
            var result: [String] = []
            for index in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where index < list.count {
                    let key = VocabularyEcho.normalized(list[index])
                    if !key.isEmpty, seen.insert(key).inserted { result.append(list[index]) }
                }
            }
            return result
        }

        /// The ContextASR sets: the terms of each clip and the list of clips.
        nonisolated private static func hasSets() -> Bool {
            ["contextasr_zh", "contextasr_en"].flatMap { ["sets/\($0)/terms.tsv", "sets/\($0)/refs.tsv"] }.allSatisfy {
                FileManager.default.fileExists(atPath: EvaluationData.root.appendingPathComponent($0).path)
            }
        }

        private static func save(_ report: [String], as name: String) throws {
            let text = report.joined(separator: "\n")
            Attachment.record(text, named: name)
            let results = EvaluationData.root.appendingPathComponent("results", isDirectory: true)
            try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            try text.write(to: results.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        @Test(.enabled(if: hasSets()))
        func holdsWithoutSpeechGiveNoTextWithALargeVocabulary() async throws {
            let engine = RealModel.engine()
            try await engine.load()
            let transcription = Transcription(
                load: { try await engine.load() },
                transcribe: { samples, context in try await engine.transcribe(samples, context: context) }
            )
            let terms = try Self.contextTerms()
            try #require(terms.count >= 100)

            var quiet: [(name: String, samples: [Float])] = [("silence", [Float](repeating: 0, count: 2 * Self.rate))]
            for dbfs in [-60.0, -50, -40] {
                quiet.append(("hum \(Int(dbfs)) dBFS", Self.hum(seconds: 2, dbfs: dbfs)))
                quiet.append(("noise \(Int(dbfs)) dBFS", Self.noise(seconds: 2, dbfs: dbfs, seed: 0x5EED + UInt64(-dbfs))))
            }

            var report = ["Vocabulary echo, holds without speech, numbers only"]
            var failures = 0
            for size in [50, 100] {
                let vocabulary = Array(terms.prefix(size))
                let context = Vocabulary.context(vocabulary)
                var echoes = 0, pasted = 0
                var parts: [String] = []
                for clip in quiet {
                    let seconds = Double(clip.samples.count) / Double(Self.rate)
                    // The first pass alone, as Orra worked before the guard.
                    let unguarded = Self.finalText(try await engine.transcribe(clip.samples, context: context), seconds: seconds)
                    let start = ContinuousClock.now
                    let guarded = Self.finalText(try await transcription.transcribe(clip.samples, vocabulary: vocabulary, audioSeconds: seconds), seconds: seconds)
                    let elapsed = start.duration(to: .now)
                    if !unguarded.isEmpty { echoes += 1 }
                    if !guarded.isEmpty { pasted += 1 }
                    let termCount = vocabulary.filter { VocabularyEcho.normalized(unguarded).contains(VocabularyEcho.normalized($0)) }.count
                    parts.append("\(clip.name): before \(unguarded.count) chars with \(termCount) terms, after \(guarded.count) chars, \(elapsed)")
                }
                failures += pasted
                report.append("\(size) terms: \(echoes) of \(quiet.count) gave text without the guard, \(pasted) with it")
                report += parts.map { "  " + $0 }
            }
            try Self.save(report, as: "vocabulary-echo.txt")
            #expect(failures == 0, "\(failures) holds without speech still gave text")
        }

        /// A term spoken by a system voice with `say`, as 16 kHz mono samples, between 0.3 s
        /// of faint noise as at the start and end of a hold. Nil when the voice is missing.
        private static func spoken(_ term: String, voice: String) throws -> [Float]? {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("orra-echo-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: file) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", file.path, "--data-format=LEF32@16000", term]
            say.standardError = FileHandle.nullDevice
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else { return nil }
            let audio = try AVAudioFile(forReading: file)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let speech = MicrophoneChannel.samples(from: buffer)
            guard !speech.isEmpty else { return nil }
            return noise(seconds: 0.3, dbfs: -60, seed: 1) + speech + noise(seconds: 0.3, dbfs: -60, seed: 2)
        }

        /// The first Chinese and the first English term of the list, the place the model
        /// echoes from, each spoken alone. The transcript is then only a term, so the guard
        /// transcribes again, and the term must survive that.
        @Test(.enabled(if: hasSets()))
        func aSpokenTermIsKept() async throws {
            let engine = RealModel.engine()
            try await engine.load()
            let transcription = Transcription(
                load: { try await engine.load() },
                transcribe: { samples, context in try await engine.transcribe(samples, context: context) }
            )
            let terms = try Self.contextTerms()
            try #require(terms.count >= 100)
            var report = ["Vocabulary echo, a spoken term, numbers only"]
            var spokenCount = 0
            var exercised = 0
            for (index, voice) in [(0, "Tingting"), (1, "Samantha")] {
                guard let speech = try Self.spoken(terms[index], voice: voice) else {
                    report.append("term \(index): voice \(voice) missing, skipped")
                    continue
                }
                spokenCount += 1
                let seconds = Double(speech.count) / Double(Self.rate)
                let key = VocabularyEcho.normalized(terms[index])
                for size in [50, 100] {
                    let vocabulary = Array(terms.prefix(size))
                    let unguarded = Self.finalText(try await engine.transcribe(speech, context: Vocabulary.context(vocabulary)), seconds: seconds)
                    let onlyTerms = VocabularyEcho.isOnlyTerms(unguarded, of: vocabulary)
                    let start = ContinuousClock.now
                    let text = Self.finalText(try await transcription.transcribe(speech, vocabulary: vocabulary, audioSeconds: seconds), seconds: seconds)
                    let elapsed = start.duration(to: .now)
                    let kept = VocabularyEcho.normalized(text).contains(key)
                    report.append("term \(index) with \(size) terms: only terms \(onlyTerms), term kept \(kept), \(text.count) chars, \(elapsed)")
                    if onlyTerms { exercised += 1 }
                    #expect(kept, "term \(index) with \(size) terms: the spoken term was dropped")
                }
            }
            try Self.save(report, as: "vocabulary-echo-spoken.txt")
            try #require(spokenCount > 0, "no system voice could speak the terms")
            #expect(exercised > 0, "every transcript held more than terms, so the guard was never exercised")
        }
    }
}
