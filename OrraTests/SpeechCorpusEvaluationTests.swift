import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Runs Orra's speech recognition on the 392 clips of the speech corpus in
/// Tools/speech-eval, the corpus Voxt checks its runtime on, and writes what it heard and
/// how long each clip took to a JSON file for Tools/speech-eval/score.py. Only when asked
/// for, with TEST_RUNNER_ORRA_SPEECH_EVAL=1, and in a Release build, since a Debug build
/// runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=<corpus> TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/SpeechCorpusEvaluationTests
///
/// It takes the path a dictation takes up to the transcript: the same resampling and
/// silence check, Qwen3Engine with Orra's decoding options and no vocabulary, then
/// TranscriptGuard and ChineseText.simplified. A clip of pure zeros is skipped, as a
/// dictation is. The filler and number rules, on by default, give ruled_text beside it.
/// The cleanup model is not run. Clips run whole, also the long ones over Orra's 60 s
/// recording limit.
///
/// Optional: TEST_RUNNER_ORRA_SPEECH_MODEL_DIR picks another model folder, and
/// TEST_RUNNER_ORRA_SPEECH_MODEL_ID the Hugging Face ID speech-swift reads its size and
/// bits from (SpeechModel.id by default). TEST_RUNNER_ORRA_SPEECH_EVAL_NAME names the
/// output file, orra-<model folder>.json by default.
///
/// The texts go only to that file, never to the log or the test result. The corpus is
/// public read and conversational speech, not anyone's dictation.
@Suite(.serialized, .enabled(if: SpeechCorpus.isRequested))
@MainActor
struct SpeechCorpusEvaluationTests {
    @Test func transcribeTheCorpus() async throws {
        let corpus = try #require(SpeechCorpus.folder, "set TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR to the folder build_corpus.py filled")
        let output = try #require(SpeechCorpus.environment["ORRA_SPEECH_EVAL_OUT"], "set TEST_RUNNER_ORRA_SPEECH_EVAL_OUT to a folder for the results")
        let modelFolder = try #require(SpeechCorpus.modelFolder, "no speech model on this Mac, or TEST_RUNNER_ORRA_SPEECH_MODEL_DIR is not a folder")
        let modelID = SpeechCorpus.environment["ORRA_SPEECH_MODEL_ID"] ?? SpeechModel.id
        let clips = try SpeechCorpus.manifest(in: corpus)
        #expect(clips.count == 392)

        let engine = Qwen3Engine(folder: { modelFolder }, modelID: modelID)
        let transcription = Transcription(
            load: { try await engine.load() },
            transcribe: { samples, context, language in try await engine.transcribe(samples, context: context, language: language) }
        )
        let loadStarted = ContinuousClock.now
        try await transcription.load()
        let loadSeconds = SpeechCorpus.seconds(loadStarted.duration(to: .now))

        var results: [String: Any] = [:]
        var audioTotal = 0.0
        var decodeTotal = 0.0
        for clip in clips {
            let recording = try SpeechCorpus.recording(corpus.appendingPathComponent("clips/\(clip).wav"))
            let samples = AudioResampler.monoAt16kHz(recording)
            let audioSeconds = recording.duration
            var row: [String: Any] = ["audio_seconds": audioSeconds]
            if Silence.isSilent(samples) {
                row["text"] = ""
                row["ruled_text"] = ""
                row["decode_seconds"] = 0.0
                row["skipped_silent"] = true
            } else {
                let started = ContinuousClock.now
                let raw = try await transcription.transcribe(samples, vocabulary: [], audioSeconds: audioSeconds)
                let decodeSeconds = SpeechCorpus.seconds(started.duration(to: .now))
                let guarded = TranscriptGuard.clean(raw, audioSeconds: audioSeconds)
                let text = ChineseText.simplified(guarded)
                row["text"] = text
                row["ruled_text"] = NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: text))
                row["decode_seconds"] = decodeSeconds
                // Which post step changed the model's text, for reading the differences.
                row["guard_changed"] = raw.trimmingCharacters(in: .whitespacesAndNewlines) != guarded
                row["simplified_changed"] = guarded != text
                decodeTotal += decodeSeconds
                audioTotal += audioSeconds
            }
            results[clip] = row
        }

        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        let document: [String: Any] = [
            "model_folder": modelFolder.lastPathComponent,
            "model_id": modelID,
            "device": SpeechCorpus.chip(),
            "build": build,
            "load_seconds": loadSeconds,
            "clips": results,
        ]
        let name = SpeechCorpus.environment["ORRA_SPEECH_EVAL_NAME"] ?? "orra-\(modelFolder.lastPathComponent)"
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file)

        // Numbers only.
        let summary = "\(results.count) clips, \(String(format: "%.1f", audioTotal)) s of speech decoded in \(String(format: "%.1f", decodeTotal)) s, load \(String(format: "%.2f", loadSeconds)) s, \(build) build, written to \(file.path)"
        print(summary)
        Attachment.record(summary, named: "speech-corpus-evaluation.txt")
    }
}

enum SpeechCorpus {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isRequested: Bool {
        environment["ORRA_SPEECH_EVAL"] != nil
    }

    static var folder: URL? {
        guard let path = environment["ORRA_SPEECH_CORPUS_DIR"] else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.jsonl").path) ? url : nil
    }

    static var modelFolder: URL? {
        if let path = environment["ORRA_SPEECH_MODEL_DIR"] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
        }
        return RealModel.folder
    }

    /// The clip IDs of the manifest, in its order.
    static func manifest(in corpus: URL) throws -> [String] {
        let text = try String(contentsOf: corpus.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(object["id"] as? String)
        }
    }

    /// A clip as the microphone would deliver it: the first channel at the file's rate.
    static func recording(_ url: URL) throws -> AudioRecording {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return AudioRecording(samples: MicrophoneChannel.samples(from: buffer), sampleRate: file.processingFormat.sampleRate)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
