import Foundation
import Testing
@testable import Orra

/// The speech detector with the bundled Silero VAD model. Runs in the test host, whose
/// bundle carries the model, and copies it into a temporary folder.
@Suite(.serialized)
struct SpeechDetectorTests {
    private static let rate = RecordingLimits.sampleRate

    private static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.vad-\(UUID().uuidString)", isDirectory: true)
    }

    /// White noise from a fixed seed at an RMS level in dBFS.
    private static func noise(seconds: Double, dbfs: Double) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let amplitude = Float(pow(10, dbfs / 20)) * Float(3.0.squareRoot())
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private static func hum(seconds: Double, dbfs: Double) -> [Float] {
        let amplitude = Float(pow(10, dbfs / 20)) * Float(2.0.squareRoot())
        return (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * Float.pi * 50 * Float($0) / Float(rate)) }
    }

    @Test func theBundledModelMatchesItsPinnedHashes() throws {
        for file in SpeechDetector.files {
            let name = file.bundled as NSString
            let url = try #require(Bundle.main.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension))
            #expect(try SpeechDetector.sha256(of: url) == file.sha256)
        }
    }

    @Test func theModelIsCopiedOnceAndADamagedCopyIsReplaced() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let detector = SpeechDetector(folder: folder)
        try await detector.prepareFolder()
        let weights = folder.appendingPathComponent("model.safetensors")
        #expect(try SpeechDetector.sha256(of: weights) == SpeechDetector.files[0].sha256)
        try Data("damaged".utf8).write(to: weights)
        try await detector.prepareFolder()
        #expect(try SpeechDetector.sha256(of: weights) == SpeechDetector.files[0].sha256)
    }

    @Test func silenceHumAndNoiseHoldNoSpeech() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let detector = SpeechDetector(folder: folder)
        for samples in [[Float](repeating: 0, count: 3 * Self.rate), Self.hum(seconds: 3, dbfs: -40), Self.noise(seconds: 3, dbfs: -50)] {
            #expect(await detector.hasSpeech(samples) == false)
        }
    }

    @Test(.enabled(if: EvaluationData.isAvailable))
    func speechHoldsSpeech() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let detector = SpeechDetector(folder: folder)
        for set in ["fleurs_zh", "fleurs_en", "ascend_mixed"] {
            for clip in try EvaluationData.clips(in: set, count: 3) {
                #expect(await detector.hasSpeech(try EvaluationData.samples(set: set, name: clip.name)) == true, "\(set) \(clip.name)")
            }
        }
    }

    @Test func aMissingModelLetsDictationGoOn() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let detector = SpeechDetector(folder: folder, bundle: Bundle(for: BundleMarker.self))
        #expect(await detector.hasSpeech([Float](repeating: 0, count: Self.rate)) == nil)
    }

    /// Every evaluation clip, which all hold speech, and how long the detector takes.
    /// Runs only with TEST_RUNNER_ORRA_VAD_EVAL=1. Numbers only.
    @Test(.enabled(if: EvaluationData.isAvailable && ProcessInfo.processInfo.environment["ORRA_VAD_EVAL"] != nil))
    func everyEvaluationClipHoldsSpeech() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let detector = SpeechDetector(folder: folder)
        #expect(await detector.load())
        var report: [String] = []
        for set in ["fleurs_zh", "fleurs_en", "ascend_mixed", "contextasr_zh", "contextasr_en"] {
            guard FileManager.default.fileExists(atPath: EvaluationData.root.appendingPathComponent("sets/\(set)/refs.tsv").path) else { continue }
            let clips = try EvaluationData.clips(in: set, count: 1_000)
            var missed: [String] = []
            var times: [Double] = []
            var audio = 0.0
            for clip in clips {
                let samples = try EvaluationData.samples(set: set, name: clip.name)
                audio += Double(samples.count) / Double(Self.rate)
                let start = ContinuousClock.now
                let speech = await detector.hasSpeech(samples)
                let elapsed = start.duration(to: .now)
                times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                if speech != true { missed.append("\(clip.name) \(String(format: "%.1f", Double(samples.count) / Double(Self.rate))) s") }
            }
            let sorted = times.sorted()
            report.append("\(set): \(clips.count) clips, \(missed.count) without speech found, detector median \(String(format: "%.3f", sorted[sorted.count / 2])) s, worst \(String(format: "%.3f", sorted.last ?? 0)) s, \(String(format: "%.0f", audio)) s of audio")
            report += missed.map { "  missed \($0)" }
        }
        let text = report.joined(separator: "\n")
        Attachment.record(text, named: "speech-detector.txt")
        try text.write(to: EvaluationData.root.appendingPathComponent("results/speech-detector.txt"), atomically: true, encoding: .utf8)
    }
}

/// A class in the test bundle, whose bundle holds no model.
private final class BundleMarker {}
