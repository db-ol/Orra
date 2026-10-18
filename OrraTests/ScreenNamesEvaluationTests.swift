import Foundation
import Testing
@testable import Orra

/// Runs clips of the context experiment of 2026-10-15 through Orra's own path with the
/// real Qwen3-ASR model: without names, with the names Use names on screen takes from the
/// text before the cursor, and with the names of the page as well, which the experiment
/// had and Orra does not read, see ScreenReader. Only when asked for:
///
///     TEST_RUNNER_ORRA_SCREEN_NAMES_CLIPS=<clips.jsonl of the experiment> \
///     TEST_RUNNER_ORRA_SCREEN_NAMES_OUT=<file.jsonl outside the repository> \
///     xcodebuild test -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' \
///         -derivedDataPath <folder> -maximum-test-execution-time-allowance 600 \
///         -only-testing:OrraTests/ScreenNamesEvaluationTests
///
/// Each line of the clips file is a JSON object with the id, the audio file relative to the
/// clips file, the reference text, the target names, whether the voice is synthetic, and
/// the context: the text before the cursor and the names on the page. The model is
/// TEST_RUNNER_ORRA_SCREEN_NAMES_MODEL_DIR, or the one Orra installed. A name counts as
/// written right as often as both the reference and the transcript hold it, ignoring case
/// and the spaces of Chinese text. The output file gets one line per clip and condition with
/// the pasted text, and a summary of counts, never text, goes next to it with the extension
/// summary.txt. Point it at the experiment's own clips only, and outside the repository.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_SCREEN_NAMES_CLIPS"] != nil))
@MainActor
struct ScreenNamesEvaluationTests {
    private struct Clip: Decodable {
        struct Context: Decodable {
            var before: String
            var pageNames: [String]
        }

        var id: String
        var audio: String
        var reference: String
        var targets: [String]
        var synthetic: Bool
        var context: Context
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// How often `name` is in `text`, ignoring case and the spaces of Chinese text.
    private static func count(_ name: String, in text: String) -> Int {
        func key(_ text: String) -> String {
            let lower = text.lowercased()
            return lower.contains(where: \.isHan) ? lower.filter { $0 != " " } : lower
        }
        let needle = key(name)
        guard !needle.isEmpty else { return 0 }
        return key(text).components(separatedBy: needle).count - 1
    }

    @Test func namesWrittenRightWithAndWithoutTheScreen() async throws {
        let clipsFile = URL(fileURLWithPath: try #require(Self.environment["ORRA_SCREEN_NAMES_CLIPS"]))
        let folder = Self.environment["ORRA_SCREEN_NAMES_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RealModel.folder
        let modelFolder = try #require(folder, "No speech model: set TEST_RUNNER_ORRA_SCREEN_NAMES_MODEL_DIR")
        let engine = Qwen3Engine(folder: { modelFolder })
        try await engine.load()
        var passes = 0
        let transcription = Transcription(
            load: { try await engine.load() },
            transcribe: { samples, context, language in
                passes += 1
                return try await engine.transcribe(samples, context: context, language: language)
            }
        )
        let common = CommonWords.load(from: modelFolder.appendingPathComponent("vocab.json"))
        try #require(!common.latin.isEmpty)
        let lines = try String(contentsOf: clipsFile, encoding: .utf8).split(separator: "\n")
        let clips = try lines.map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }

        // One untimed pass without and one with a context, so Metal compiles its programs first.
        if let first = clips.first {
            let samples = try CaptionPipelineMeasurementTests.samples(of: clipsFile.deletingLastPathComponent().appendingPathComponent(first.audio))
            _ = try await engine.transcribe(samples)
            _ = try await engine.transcribe(samples, context: "Orra\nQwen3")
        }

        let conditions = ["none", "field", "page"]
        var right: [String: (all: Int, real: Int)] = [:]
        var passCount: [String: Int] = [:]
        var termCounts: [Int] = []
        var targets = (all: 0, real: 0)
        var output: [String] = []
        for clip in clips {
            let samples = try CaptionPipelineMeasurementTests.samples(of: clipsFile.deletingLastPathComponent().appendingPathComponent(clip.audio))
            let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
            let field = ScreenNames.terms(in: ScreenText(beforeCursor: clip.context.before), common: common)
            termCounts.append(field.count)
            let page = Vocabulary.terms(from: clip.context.pageNames + field)
            for target in clip.targets {
                let expected = Self.count(target, in: clip.reference)
                targets.all += expected
                if !clip.synthetic { targets.real += expected }
            }
            for condition in conditions {
                let names = condition == "none" ? [] : condition == "field" ? field : page
                let before = passes
                let raw = try await transcription.transcribe(samples, vocabulary: names, holdsScreenNames: !names.isEmpty, audioSeconds: seconds)
                passCount[condition, default: 0] += passes - before
                var text = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: seconds))
                text = NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: text))
                var hits = 0
                for target in clip.targets {
                    hits += min(Self.count(target, in: clip.reference), Self.count(target, in: text))
                }
                right[condition, default: (0, 0)].all += hits
                if !clip.synthetic { right[condition, default: (0, 0)].real += hits }
                let row: [String: Any] = ["id": clip.id, "condition": condition, "text": text, "names": names.count, "right": hits]
                output.append(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }

        var summary = ["Names on screen, \(clips.count) clips, \(targets.all) target names, \(targets.real) of them in real speech"]
        summary.append("Names taken from the text before the cursor: median \(termCounts.sorted()[termCounts.count / 2]), most \(termCounts.max() ?? 0)")
        for condition in conditions {
            let counts = right[condition] ?? (0, 0)
            summary.append("\(condition): \(counts.all) of \(targets.all) right, \(counts.real) of \(targets.real) in real speech, \(passCount[condition] ?? 0) passes of the model")
        }
        let report = summary.joined(separator: "\n")
        Attachment.record(report, named: "screen-names.txt")
        if let out = Self.environment["ORRA_SCREEN_NAMES_OUT"] {
            let url = URL(fileURLWithPath: out)
            try (output.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try report.write(to: url.deletingPathExtension().appendingPathExtension("summary.txt"), atomically: true, encoding: .utf8)
        }
        #expect((right["field"]?.all ?? 0) >= (right["none"]?.all ?? 0))
    }
}
