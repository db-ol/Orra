import Foundation
import Testing
@testable import Orra

/// Runs the test sets of the release gate through a dictation and writes what would be
/// pasted, for Tools/release-gate/gate.py to score. Only when asked for, with
/// TEST_RUNNER_ORRA_GATE_SETS set to a folder of sets and TEST_RUNNER_ORRA_GATE_OUT to a
/// folder for the results, in a Release build:
///
///     TEST_RUNNER_ORRA_GATE_SETS=<sets> TEST_RUNNER_ORRA_GATE_OUT=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/GateSetEvaluationTests
///
/// Each set is a folder with clips/<id>.wav and manifest.jsonl, one JSON object per clip
/// with id, language, reference, context, expect_terms and forbid_terms, see
/// docs/release-gate.md. The sets hold synthetic speech made with macOS say from the
/// sentences in Tools/release-gate/sets.
///
/// It drives PushToTalkController as the app does, with the clip's context as the
/// vocabulary: the real speech model with the language guard and the echo check, the
/// transcript guard, the filler and number rules on, as by default, and the word
/// replacement step. Cleanup and translation are off. The microphone is a stand in that
/// returns the clip, and the text is collected instead of pasted.
@Suite(.serialized, .enabled(if: GateSets.folder != nil))
@MainActor
struct GateSetEvaluationTests {
    @Test func transcribeTheSets() async throws {
        let root = try #require(GateSets.folder)
        let speechFolder = try #require(RealModel.folder, "no speech model on this Mac")
        let sets = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/manifest.jsonl").path) }
            .sorted()
        try #require(!sets.isEmpty, "no set with a manifest.jsonl in \(root.path)")

        let speech = Qwen3Engine(folder: { speechFolder })
        let transcription = Transcription(
            load: { try await speech.load() },
            transcribe: { samples, context, language in try await speech.transcribe(samples, context: context, language: language) }
        )
        var pasted: String?
        let mic = FakeMicrophone()
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: transcription,
            insert: { text in
                pasted = text
                return .pasted
            },
            frontmostApp: { 100 },
            lidIsClosed: { false },
            isTrusted: { true },
            minimumHold: .zero,
            releaseTail: .zero
        )
        var latest: DictationTimings?
        controller.onTimings = { latest = $0 }
        let loadStarted = ContinuousClock.now
        await controller.loadModel()
        let loadSeconds = GateOutput.seconds(loadStarted.duration(to: .now))
        try #require(controller.modelState == .ready)

        var rows: [[String: Any]] = []
        for set in sets {
            let folder = root.appendingPathComponent(set, isDirectory: true)
            for clip in try GateSets.manifest(folder.appendingPathComponent("manifest.jsonl")) {
                let recording = try SpeechCorpus.recording(folder.appendingPathComponent("clips/\(clip.id).wav"))
                mic.recording = recording
                controller.setVocabulary(clip.context.map { VocabularyWord($0, added: .distantPast) })
                pasted = nil
                latest = nil
                let starts = mic.calls.count
                controller.handle(.pressed(isRepeat: false))
                try await LatencyMeasurement.waitUntil { mic.calls.count > starts }
                controller.handle(.released)
                try await LatencyMeasurement.waitUntil { controller.state == .idle }
                var row: [String: Any] = [
                    "set": set, "id": clip.id, "audio_seconds": recording.duration,
                    "text": pasted ?? "",
                ]
                if let latest {
                    row["recognition_ms"] = LatencyMeasurement.ms(latest.durations[.recognition] ?? .zero)
                    row["total_ms"] = LatencyMeasurement.ms(latest.total)
                }
                rows.append(row)
            }
        }
        try GateOutput.write(["suite": "sets", "load_seconds": loadSeconds, "sets": sets, "clips": rows], named: "sets-raw")
        // Numbers only.
        print("\(rows.count) clips in \(sets.count) sets")
    }
}

enum GateSets {
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_GATE_SETS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    struct Clip: Decodable {
        let id: String
        let context: [String]

        enum CodingKeys: String, CodingKey {
            case id, context
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            context = try container.decodeIfPresent([String].self, forKey: .context) ?? []
        }
    }

    static func manifest(_ url: URL) throws -> [Clip] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
    }
}
