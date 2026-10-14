import AppKit
import AVFoundation
import Foundation
import MLX
import Qwen3ASR
import Synchronization
import Testing
@testable import Orra

/// Measures where the time goes from the release of the talk key to the paste, step by
/// step, with the real speech model and the real cleanup model on this Mac. Only when
/// asked for, with TEST_RUNNER_ORRA_LATENCY=1, never in CI, and in a Release build, since
/// a Debug build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_LATENCY=1 TEST_RUNNER_ORRA_LATENCY_CLIPS=<folder of WAV files> TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=<corpus> TEST_RUNNER_ORRA_LATENCY_REPORT=<file> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/LatencyMeasurementTests
///
/// The clips folder holds synthetic dictations made with macOS say, see
/// docs/manual-testing.md. From the speech corpus of Tools/speech-eval it takes the first
/// three clips of each short and mid stratum in Chinese, English and mixed speech. Each
/// clip is upsampled to 48 kHz first, the rate most Mac microphones record at, so the
/// resampling step does real work.
///
/// `dictations` drives PushToTalkController as the app does: a press, the release, the
/// default release tail, the real speech model with the language guard, the filler and
/// number rules, the cleanup model through CleanupStep, and a real TextInserter. Each clip
/// runs with cleanup off and on. What it cannot do on a Mac someone works on, it leaves
/// out: the microphone is a stand in that returns the clip at once, the inserter writes to
/// a private pasteboard instead of the general one and builds the Command V events without
/// posting them, and no vocabulary or word pairs are set.
///
/// `speechModelParts` splits one pass of the speech model into the mel features, the audio
/// encoder and the text decoder, to see what could run while the key is held.
///
/// The report holds durations and counts only, never text.
@Suite(.serialized, .enabled(if: LatencyMeasurement.isRequested))
@MainActor
struct LatencyMeasurementTests {
    @Test func dictations() async throws {
        let speechFolder = try #require(RealModel.folder, "no speech model on this Mac")
        let cleanupFolder = try #require(RewriteTestModel.folder, "no cleanup model on this Mac")
        let clips = try LatencyMeasurement.clips()
        try #require(clips.count >= 12)

        let speech = Qwen3Engine(folder: { speechFolder })
        let passes = PassLog()
        let transcription = Transcription(
            load: { try await speech.load() },
            transcribe: { samples, context, language in
                let started = ContinuousClock.now
                let text = try await speech.transcribe(samples, context: context, language: language)
                passes.add(started.duration(to: .now))
                return text
            }
        )
        let rewrite = RewriteEngine()
        try await rewrite.load(from: cleanupFolder)
        let completions = CompletionLog()
        let cleanupSwitch = Switch()
        let cleanup = CleanupModel(
            waitUntilLoaded: { cleanupSwitch.isOn },
            complete: { text in
                let started = ContinuousClock.now
                let completion = try await rewrite.cleanUp(text)
                completions.add(completion, took: started.duration(to: .now))
                return completion.answer
            }
        )
        let paste = PasteLog()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.db-ol.Orra.latency-\(UUID().uuidString)"))
        // Something to read and put back, as on a pasteboard someone uses.
        pasteboard.clearContents()
        pasteboard.setString("clipboard", forType: .string)
        let inserter = TextInserter(
            pasteboard: pasteboard,
            postCommandShortcut: { keyCode in
                // Builds the events the app posts, without posting them.
                let source = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
            },
            secureInputHolder: { nil },
            frontmostApp: { nil },
            focusedField: { _ in .plainText },
            readSnapshot: { name in
                let started = ContinuousClock.now
                let snapshot = await PasteboardSnapshot.read(pasteboardNamed: name)
                paste.read(started.duration(to: .now))
                return snapshot
            },
            keyCodeForV: { KeyboardLayout.keyCode(for: "v", withCommand: true) ?? 9 }
        )
        let mic = FakeMicrophone()
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: transcription,
            cleanup: cleanup,
            insert: { await inserter.insert($0) },
            frontmostApp: { 100 },
            lidIsClosed: { false },
            isTrusted: { true },
            minimumHold: .zero
        )
        var latest: DictationTimings?
        controller.onTimings = { latest = $0 }
        let loadStarted = ContinuousClock.now
        await controller.loadModel()
        let speechLoad = loadStarted.duration(to: .now)
        try #require(controller.modelState == .ready)

        func dictate(_ clip: LatencyMeasurement.Clip, cleanupOn: Bool) async throws -> Run? {
            mic.recording = clip.recording
            cleanupSwitch.isOn = cleanupOn
            passes.reset()
            completions.reset()
            paste.reset()
            latest = nil
            let starts = mic.calls.count
            controller.handle(.pressed(isRepeat: false))
            try await LatencyMeasurement.waitUntil { mic.calls.count > starts }
            controller.handle(.released)
            try await LatencyMeasurement.waitUntil { controller.state == .idle }
            // Past the inserter's restore of the pasteboard, so every paste reads it.
            try await Task.sleep(for: .milliseconds(700))
            guard let timings = latest else { return nil }
            return Run(clip: clip, cleanupOn: cleanupOn, timings: timings, passes: passes.durations, completion: completions.latest, snapshotReads: paste.reads)
        }

        // One dictation of each kind first, so neither model pays for a first run.
        _ = try await dictate(clips[0], cleanupOn: false)
        _ = try await dictate(clips[0], cleanupOn: true)
        var runs: [Run] = []
        for round in 0..<LatencyMeasurement.rounds {
            for clip in clips {
                // Alternates which mode goes first, so neither always follows the other.
                for cleanupOn in round % 2 == 0 ? [false, true] : [true, false] {
                    if let run = try await dictate(clip, cleanupOn: cleanupOn) {
                        runs.append(run)
                    } else {
                        Issue.record("\(clip.name) pasted nothing, cleanup \(cleanupOn)")
                    }
                }
            }
        }
        await rewrite.unload()

        let report = LatencyReport(runs: runs, speechLoad: speechLoad, clips: clips).text
        print(report)
        Attachment.record(report, named: "latency.txt")
        if let path = LatencyMeasurement.environment["ORRA_LATENCY_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// One pass of the speech model in three parts: the mel features, the audio encoder,
    /// and the rest, the text decoder, as the whole pass minus the first two. The model
    /// options are Orra's, see Qwen3Engine.
    @Test func speechModelParts() async throws {
        let folder = try #require(RealModel.folder, "no speech model on this Mac")
        let clips = try LatencyMeasurement.clips()
        let model = try await Qwen3ASRModel.fromPretrained(modelId: SpeechModel.id, cacheDir: folder, offlineMode: true)
        func options(_ seconds: Double) -> Qwen3DecodingOptions {
            Qwen3DecodingOptions(maxTokens: max(448, Int(seconds * 12)), longInputThresholdSeconds: .infinity)
        }
        _ = model.transcribe(audio: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, options: options(1))
        var rows: [(name: String, seconds: Double, mel: Double, encoder: Double, decoder: Double, characters: Int)] = []
        for clip in clips {
            let samples = AudioResampler.monoAt16kHz(clip.recording)
            let seconds = Double(samples.count) / 16_000
            // Twice, the first run of each clip length warms up.
            var measured: (Double, Double, Double, Int) = (0, 0, 0, 0)
            for _ in 0..<2 {
                let started = ContinuousClock.now
                let mel = model.featureExtractor.process(samples, sampleRate: 16_000)
                eval(mel)
                let melDone = ContinuousClock.now
                let embeddings = model.audioEncoder(mel.expandedDimensions(axis: 0))
                eval(embeddings)
                let encoderDone = ContinuousClock.now
                let wholeStarted = ContinuousClock.now
                let text = model.transcribe(audio: samples, sampleRate: 16_000, options: options(seconds))
                let whole = LatencyMeasurement.ms(wholeStarted.duration(to: .now))
                let melTime = LatencyMeasurement.ms(started.duration(to: melDone))
                let encoderTime = LatencyMeasurement.ms(melDone.duration(to: encoderDone))
                measured = (melTime, encoderTime, whole - melTime - encoderTime, text.count)
                Memory.clearCache()
            }
            rows.append((clip.name, seconds, measured.0, measured.1, measured.2, measured.3))
        }
        var report = "Speech model parts, ms, second run of each clip (mel, encoder, decoder = whole pass minus both), chip \(SpeechCorpus.chip())\n"
        report += "| clip | audio s | mel | encoder | decoder | characters |\n|---|---|---|---|---|---|\n"
        for row in rows {
            report += "| \(row.name) | \(LatencyMeasurement.f(row.seconds, 1)) | \(LatencyMeasurement.f(row.mel, 1)) | \(LatencyMeasurement.f(row.encoder, 1)) | \(LatencyMeasurement.f(row.decoder, 1)) | \(row.characters) |\n"
        }
        let total = rows.reduce(0) { $0 + $1.mel + $1.encoder + $1.decoder }
        report += "Shares over all clips: mel \(LatencyMeasurement.f(100 * rows.reduce(0) { $0 + $1.mel } / total, 1)) %, encoder \(LatencyMeasurement.f(100 * rows.reduce(0) { $0 + $1.encoder } / total, 1)) %, decoder \(LatencyMeasurement.f(100 * rows.reduce(0) { $0 + $1.decoder } / total, 1)) %\n"
        print(report)
        Attachment.record(report, named: "speech-parts.txt")
        if let path = LatencyMeasurement.environment["ORRA_LATENCY_REPORT"] {
            try report.write(toFile: path + ".speech", atomically: true, encoding: .utf8)
        }
    }

    struct Run {
        let clip: LatencyMeasurement.Clip
        let cleanupOn: Bool
        let timings: DictationTimings
        let passes: [Duration]
        let completion: (completion: RewriteEngine.Completion, took: Duration)?
        let snapshotReads: Duration
    }
}

/// The time of each pass of the speech model in one dictation.
nonisolated final class PassLog: Sendable {
    private let state = Mutex<[Duration]>([])
    func add(_ duration: Duration) { state.withLock { $0.append(duration) } }
    func reset() { state.withLock { $0 = [] } }
    var durations: [Duration] { state.withLock { $0 } }
}

/// The cleanup model's latest completion and how long it took.
nonisolated final class CompletionLog: Sendable {
    private let state = Mutex<(RewriteEngine.Completion, Duration)?>(nil)
    func add(_ completion: RewriteEngine.Completion, took: Duration) { state.withLock { $0 = (completion, took) } }
    func reset() { state.withLock { $0 = nil } }
    var latest: (completion: RewriteEngine.Completion, took: Duration)? { state.withLock { $0.map { (completion: $0.0, took: $0.1) } } }
}

/// How long the inserter's pasteboard reads took in one dictation.
@MainActor
final class PasteLog {
    private(set) var reads: Duration = .zero

    func reset() {
        reads = .zero
    }

    func read(_ duration: Duration) {
        reads += duration
    }
}

@MainActor
final class Switch {
    var isOn = false
}

enum LatencyMeasurement {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isRequested: Bool {
        environment["ORRA_LATENCY"] != nil
    }

    static var rounds: Int {
        Int(environment["ORRA_LATENCY_ROUNDS"] ?? "") ?? 2
    }

    struct Clip {
        let name: String
        /// short, mid or long.
        let length: String
        /// zh, en or mixed.
        let language: String
        let source: String
        let recording: AudioRecording
    }

    /// The synthetic clips, then three clips of each short and mid stratum of the corpus.
    static func clips() throws -> [Clip] {
        var clips: [Clip] = []
        if let path = environment["ORRA_LATENCY_CLIPS"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }.sorted()
            for name in names {
                let parts = name.split(separator: "_")
                let recording = try SpeechCorpus.recording(folder.appendingPathComponent(name))
                clips.append(Clip(name: "say " + name.replacingOccurrences(of: ".wav", with: ""), length: String(parts[1]), language: String(parts[0]), source: "say", recording: at48kHz(recording)))
            }
        }
        if let corpus = SpeechCorpus.folder {
            let strata = ["zh_short", "en_short", "mixed", "zh_mid", "en_mid"]
            let text = try String(contentsOf: corpus.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
            var taken: [String: Int] = [:]
            for line in text.split(separator: "\n") {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let id = try #require(object["id"] as? String)
                let stratum = try #require(object["stratum"] as? String)
                guard strata.contains(stratum), taken[stratum, default: 0] < 3 else { continue }
                taken[stratum, default: 0] += 1
                let recording = try SpeechCorpus.recording(corpus.appendingPathComponent("clips/\(id).wav"))
                let language = stratum == "mixed" ? "mixed" : String(stratum.prefix(2))
                let length = stratum == "mixed" ? (recording.duration < 8 ? "short" : "mid") : String(stratum.dropFirst(3))
                clips.append(Clip(name: "corpus " + id, length: length, language: language, source: "corpus", recording: at48kHz(recording)))
            }
        }
        return clips
    }

    /// The clip as a 48 kHz microphone would deliver it.
    static func at48kHz(_ recording: AudioRecording) -> AudioRecording {
        let target = 48_000.0
        guard recording.sampleRate != target,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: recording.sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(recording.samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(recording.samples.count) * target / recording.sampleRate) + 4_096) else {
            return recording
        }
        input.frameLength = input.frameCapacity
        recording.samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        return AudioRecording(samples: samples, sampleRate: target)
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<120_000 where !condition() {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition())
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func f(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// The value at a fraction of the sorted values, nearest rank.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// The tables of the latency measurement. Numbers only.
@MainActor
struct LatencyReport {
    let runs: [LatencyMeasurementTests.Run]
    let speechLoad: Duration
    let clips: [LatencyMeasurement.Clip]

    private typealias M = LatencyMeasurement

    var text: String {
        var out = "Release to paste, Release build, chip \(SpeechCorpus.chip()), \(clips.count) clips (\(clips.filter { $0.source == "say" }.count) say, \(clips.filter { $0.source == "corpus" }.count) corpus), \(M.rounds) rounds, speech model load \(M.f(M.ms(speechLoad), 0)) ms\n"
        out += "Audio seconds per clip: median \(M.f(M.percentile(clips.map(\.recording.duration), 0.5), 1)), max \(M.f(clips.map(\.recording.duration).max() ?? 0, 1))\n\n"
        for cleanupOn in [false, true] {
            let selected = runs.filter { $0.cleanupOn == cleanupOn }
            out += "## Cleanup \(cleanupOn ? "on" : "off"), \(selected.count) dictations, ms\n\n"
            out += table(selected)
            out += "\n"
        }
        out += "## Total by length and language, ms, median (p90)\n\n| group | n | cleanup off | cleanup on |\n|---|---|---|---|\n"
        let groups = ["short", "mid", "long"].map { length in (length, { (run: LatencyMeasurementTests.Run) in run.clip.length == length }) }
            + ["zh", "en", "mixed"].map { language in (language, { (run: LatencyMeasurementTests.Run) in run.clip.language == language }) }
        for (name, belongs) in groups {
            let off = runs.filter { !$0.cleanupOn && belongs($0) }.map { M.ms($0.timings.total) }
            let on = runs.filter { $0.cleanupOn && belongs($0) }.map { M.ms($0.timings.total) }
            guard !off.isEmpty else { continue }
            out += "| \(name) | \(off.count) | \(M.f(M.percentile(off, 0.5), 0)) (\(M.f(M.percentile(off, 0.9), 0))) | \(M.f(M.percentile(on, 0.5), 0)) (\(M.f(M.percentile(on, 0.9), 0))) |\n"
        }
        let cleaned = runs.filter { $0.cleanupOn }.compactMap(\.completion)
        if !cleaned.isEmpty {
            let generated = cleaned.map { Double($0.completion.generatedTokens) }
            let prompt = cleaned.map { Double($0.completion.promptTokens - $0.completion.cachedPromptTokens) }
            let prefill = cleaned.map { M.ms($0.completion.prefillTime) }
            let generation = cleaned.map { M.ms($0.took) - M.ms($0.completion.prefillTime) }
            let rates = cleaned.map { Double($0.completion.generatedTokens) / max((M.ms($0.took) - M.ms($0.completion.prefillTime)) / 1_000, 0.001) }
            out += "\n## Cleanup model, \(cleaned.count) runs, median (p90)\n\n"
            out += "| measure | median | p90 | min | max |\n|---|---|---|---|---|\n"
            for (name, values) in [("prompt tokens read (not cached)", prompt), ("cached prompt tokens", cleaned.map { Double($0.completion.cachedPromptTokens) }), ("prefill ms", prefill), ("tokens generated", generated), ("generation ms", generation), ("tokens per second", rates)] {
                out += "| \(name) | \(M.f(M.percentile(values, 0.5), 1)) | \(M.f(M.percentile(values, 0.9), 1)) | \(M.f(values.min() ?? 0, 1)) | \(M.f(values.max() ?? 0, 1)) |\n"
            }
            let totalTokens = generated.reduce(0, +)
            let totalSeconds = generation.reduce(0, +) / 1_000
            out += "Overall \(M.f(totalTokens / totalSeconds, 1)) tokens per second over \(Int(totalTokens)) tokens. Runs skipped by isWorthCleaning: \(runs.filter { $0.cleanupOn && $0.completion == nil }.count)\n"
        }
        out += "\n## Per clip, median total ms\n\n| clip | audio s | passes | off | on | tokens |\n|---|---|---|---|---|---|\n"
        for clip in clips {
            let mine = runs.filter { $0.clip.name == clip.name }
            let off = mine.filter { !$0.cleanupOn }.map { M.ms($0.timings.total) }
            let on = mine.filter { $0.cleanupOn }.map { M.ms($0.timings.total) }
            let tokens = mine.compactMap { $0.completion?.completion.generatedTokens }.first.map(String.init) ?? "skipped"
            out += "| \(clip.name) | \(M.f(clip.recording.duration, 1)) | \(mine.first?.passes.count ?? 0) | \(M.f(M.percentile(off, 0.5), 0)) | \(M.f(M.percentile(on, 0.5), 0)) | \(tokens) |\n"
        }
        return out
    }

    private func table(_ runs: [LatencyMeasurementTests.Run]) -> String {
        var rows: [(String, [Double])] = []
        for step in DictationTimings.Step.allCases {
            let values = runs.map { M.ms($0.timings.durations[step] ?? .zero) }
            rows.append((step.rawValue, values))
            if step == .recognition {
                rows.append(("  of it speech model passes", runs.map { $0.passes.reduce(0) { $0 + M.ms($1) } }))
                rows.append(("  of it guards between passes", runs.map { M.ms($0.timings.durations[.recognition] ?? .zero) - $0.passes.reduce(0) { $0 + M.ms($1) } }))
            }
            if step == .cleanup {
                let withCleanup = runs.filter { $0.completion != nil }
                if !withCleanup.isEmpty {
                    rows.append(("  of it model prefill", withCleanup.map { M.ms($0.completion!.completion.prefillTime) }))
                    rows.append(("  of it model generation", withCleanup.map { M.ms($0.completion!.took) - M.ms($0.completion!.completion.prefillTime) }))
                    rows.append(("  of it parse and guards", withCleanup.map { M.ms($0.timings.durations[.cleanup] ?? .zero) - M.ms($0.completion!.took) }))
                }
            }
            if step == .paste {
                rows.append(("  of it pasteboard snapshot reads", runs.map { M.ms($0.snapshotReads) }))
            }
        }
        rows.append(("total", runs.map { M.ms($0.timings.total) }))
        var out = "| step | median | p90 | max |\n|---|---|---|---|\n"
        for (name, values) in rows {
            out += "| \(name) | \(M.f(M.percentile(values, 0.5), 2)) | \(M.f(M.percentile(values, 0.9), 2)) | \(M.f(values.max() ?? 0, 2)) |\n"
        }
        return out
    }
}
