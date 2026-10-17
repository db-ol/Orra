#if canImport(Qwen3TTS)
import Foundation
import Synchronization
import Testing
@testable import Orra

/// The model gate with the three real models, in rounds that each start cold. The speech
/// and cleanup models come from the app's factories, and the voice model is behind the
/// app's wrapper, each round at a gate of its own. Only when asked for, with
/// TEST_RUNNER_ORRA_GATE_STRESS=1 and all three models on this Mac. It loads about 7 GB,
/// so run it on its own, in a Release build:
///
///     TEST_RUNNER_ORRA_GATE_STRESS=1 xcodebuild test -project Orra.xcodeproj -scheme Orra \
///         -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES \
///         -derivedDataPath build/DerivedData -only-testing:OrraTests/ModelGateStressTests
///
/// Each round makes a new speech model and a new voice model, so both load and warm up
/// again and the voice model's traces start cold. It unloads the cleanup model, so its load
/// fills the prefix caches again, and starts the three loads at once, as at launch, the
/// speech and cleanup loads with the gate reserved, as the app loads them. Then, for
/// TEST_RUNNER_ORRA_GATE_STRESS_SECONDS (60 by default), the speech model transcribes clips
/// of 1 to 12 s, every other one with the gate reserved, as a dictation's are. The cleanup
/// model cleans up and translates in a second loop. The voice model speaks streamed pieces
/// of 1 to 40 words, every other one stopped after its first part, and pieces in a voice
/// sample of about 10 s. TEST_RUNNER_ORRA_GATE_STRESS_ROUNDS sets the rounds, 30 by
/// default.
///
/// A round that makes no progress for 60 s ends the test process with _exit(1) and names
/// its phase, since hung MLX threads cannot be undone. With TEST_RUNNER_ORRA_GATE_BYPASS=1
/// the models run without the gate, as in Orra 0.4.0, and on mlx-swift 0.31.6 the run
/// should end that way. The clips and the voice sample come from the evaluation folder when
/// it is there (EvaluationData), and are made up tones otherwise.
///
/// The report holds durations and counts only: the 50th and 95th percentile and the
/// longest gate wait of dictation's transcriptions, and their time with and without a
/// piece being made. With the gate reserved no piece starts, so such a transcription waits
/// only for a piece in the gate when it asks, until that piece ends. The report goes to
/// the test's output, and to a file with TEST_RUNNER_ORRA_GATE_STRESS_REPORT.
@Suite(.serialized, .enabled(if: GateStress.isAskedFor && GateStress.folders != nil))
@MainActor
struct ModelGateStressTests {
    @Test func theModelsNeverHangTogether() async throws {
        let folders = try #require(GateStress.folders)
        let watchdog = GateStress.Watchdog()
        // Also when a round throws, so the watchdog does not report a hang 60 s later.
        defer { watchdog.stop() }
        let clips = GateStress.clips()
        let sample = GateStress.voiceSample()
        let rewrite = RewriteEngine()
        let tally = GateStress.Tally()
        for round in 1...GateStress.rounds {
            try await GateStress.round(round, folders: folders, rewrite: rewrite, clips: clips, sample: sample, watchdog: watchdog, tally: tally)
        }
        let report = tally.report(rounds: GateStress.rounds, bypass: GateStress.bypass)
        print(report)
        if let path = GateStress.environment["ORRA_GATE_STRESS_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

enum GateStress {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isAskedFor: Bool {
        environment["ORRA_GATE_STRESS"] != nil
    }

    static var bypass: Bool {
        environment["ORRA_GATE_BYPASS"] != nil
    }

    static var rounds: Int {
        Int(environment["ORRA_GATE_STRESS_ROUNDS"] ?? "") ?? 30
    }

    static var seconds: Double {
        Double(environment["ORRA_GATE_STRESS_SECONDS"] ?? "") ?? 60
    }

    struct Folders {
        let speech: URL
        let cleanup: URL
        let voice: VoiceModelFolders
    }

    static var folders: Folders? {
        let cleanup = ModelFolders.liveCleanup.installed(.qwen35Cleanup)
        let model = ModelFolders.liveCleanup.installed(.qwen3Voice)
        let codec = ModelFolders.liveCleanup.installed(.qwen3VoiceCodec)
        guard let speech = SpeechModel.installedFolder(),
              ModelDisk.isComplete(cleanup, .qwen35Cleanup),
              ModelDisk.isComplete(model, .qwen3Voice),
              ModelDisk.isComplete(codec, .qwen3VoiceCodec)
        else { return nil }
        return Folders(speech: speech, cleanup: cleanup, voice: VoiceModelFolders(model: model, codec: codec))
    }

    /// Clips of 1 to 12 s, from the evaluation folder or made up.
    static func clips() -> [[Float]] {
        let rate = RecordingLimits.sampleRate
        var clips: [[Float]] = []
        if EvaluationData.isAvailable {
            for set in ["fleurs_zh", "fleurs_en"] {
                for clip in (try? EvaluationData.clips(in: set, count: 10)) ?? [] {
                    if let samples = try? EvaluationData.samples(set: set, name: clip.name) {
                        clips.append(Array(samples.prefix(12 * rate)))
                    }
                }
            }
        }
        if clips.isEmpty {
            clips = (1...12).map { seconds in (0..<(seconds * rate)).map { Float(sin(Double($0) * 0.05)) * 0.1 } }
        }
        return clips
    }

    /// A voice sample of about 10 s with what is said in it, from the evaluation folder or
    /// made up.
    static func voiceSample() -> VoiceSample {
        let rate = RecordingLimits.sampleRate
        if EvaluationData.isAvailable {
            for clip in (try? EvaluationData.clips(in: "fleurs_en", count: 50)) ?? [] {
                if let samples = try? EvaluationData.samples(set: "fleurs_en", name: clip.name), (8 * rate...12 * rate).contains(samples.count) {
                    return VoiceSample(samples: samples, sampleRate: rate, transcript: clip.reference)
                }
            }
        }
        return VoiceSample(samples: (0..<(10 * rate)).map { Float(sin(Double($0) * 0.05)) * 0.1 }, sampleRate: rate, transcript: "We met at noon.")
    }

    static let words = "We will meet next Tuesday at three in the afternoon to review the budget and the plan for the new office, so please send the numbers before then and everyone can read them first.".split(separator: " ")
    static let cleanupTexts = ["呃，我们下午两点，哦不对，下午三点开会。", "Um, I think we should push the launch to next week."]

    /// Ends the test process when a round makes no progress for a minute.
    final class Watchdog: Sendable {
        private let state = Mutex<(phase: String, progress: ContinuousClock.Instant, stopped: Bool)>(("start", .now, false))

        init() {
            check()
        }

        func enter(_ phase: String) {
            state.withLock { $0 = (phase, .now, $0.stopped) }
        }

        func progress() {
            state.withLock { $0.progress = .now }
        }

        func stop() {
            state.withLock { $0.stopped = true }
        }

        private func check() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                let (phase, progress, stopped) = state.withLock { $0 }
                guard !stopped else { return }
                if progress.duration(to: .now) > .seconds(60) {
                    print("The model gate stress test hung in \(phase), gated: \(!GateStress.bypass)")
                    fflush(stdout)
                    // Not exit(), whose handlers could wait for the locks the hung threads hold.
                    _exit(1)
                }
                check()
            }
        }
    }

    /// The times of dictation's transcriptions.
    final class Tally: Sendable {
        private let state = Mutex<(waits: [Duration], alone: [Duration], withPiece: [Duration], calls: Int, pieces: Int)>(([], [], [], 0, 0))

        /// `wait` is nil without the gate.
        func dictation(wait: Duration?, total: Duration, duringPiece: Bool) {
            state.withLock { state in
                if let wait {
                    state.waits.append(wait)
                }
                if duringPiece {
                    state.withPiece.append(total)
                } else {
                    state.alone.append(total)
                }
            }
        }

        func call() {
            state.withLock { $0.calls += 1 }
        }

        func piece() {
            state.withLock { $0.pieces += 1 }
        }

        func report(rounds: Int, bypass: Bool) -> String {
            state.withLock { state in
                """
                Model gate stress: \(rounds) rounds of \(GateStress.seconds) s, gated: \(!bypass), \(state.calls) model calls, \(state.pieces) pieces
                Gate wait of dictation's transcriptions: \(Self.summary(state.waits))
                Dictation's transcriptions without a piece being made: \(Self.summary(state.alone))
                Dictation's transcriptions while a piece was made: \(Self.summary(state.withPiece))
                """
            }
        }

        private static func summary(_ durations: [Duration]) -> String {
            guard !durations.isEmpty else { return "none" }
            let sorted = durations.sorted()
            func percentile(_ share: Double) -> Duration {
                sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * share))]
            }
            return "\(sorted.count) calls, median \(percentile(0.5)), 95th percentile \(percentile(0.95)), longest \(sorted[sorted.count - 1])"
        }
    }

    /// Follows the voice model's work on pieces, from the call to the end of its stream.
    final class VoiceWork: SpeechSynthesizer {
        let inner: any SpeechSynthesizer
        /// The pieces under way, the pieces begun so far, and when the last one ended.
        private let busy = Mutex<(running: Int, begun: Int, lastEnded: ContinuousClock.Instant?)>((0, 0, nil))

        init(_ inner: any SpeechSynthesizer) {
            self.inner = inner
        }

        /// The pieces begun so far, whether one is under way, and when the last one ended.
        var now: (begun: Int, running: Bool, lastEnded: ContinuousClock.Instant?) {
            busy.withLock { ($0.begun, $0.running > 0, $0.lastEnded) }
        }

        func load(model: URL, codec: URL) async throws {
            try await inner.load(model: model, codec: codec)
        }

        func unload() async {
            await inner.unload()
        }

        func forgetVoice() async {
            await inner.forgetVoice()
        }

        func streams(voice: VoiceSample?) -> Bool {
            inner.streams(voice: voice)
        }

        func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error> {
            busy.withLock {
                $0.running += 1
                $0.begun += 1
            }
            let (stream, continuation) = AsyncThrowingStream<SpokenAudio, any Error>.makeStream()
            let parts = inner.speak(text, in: language, voice: voice)
            Task { [self] in
                var failure: (any Error)?
                do {
                    for try await part in parts {
                        continuation.yield(part)
                    }
                } catch {
                    failure = error
                }
                // Before the end of the stream, after which the wrapper lets go of the gate.
                busy.withLock {
                    $0.running -= 1
                    $0.lastEnded = .now
                }
                continuation.finish(throwing: failure)
            }
            return stream
        }
    }

    @MainActor
    static func round(_ round: Int, folders: Folders, rewrite: RewriteEngine, clips: [[Float]], sample: VoiceSample, watchdog: Watchdog, tally: Tally) async throws {
        let speechEngine = Qwen3Engine(folder: { folders.speech })
        let work = VoiceWork(Qwen3VoiceEngine())
        let speech: Transcription
        let cleanup: CleanupEngine
        let voice: any SpeechSynthesizer
        if bypass {
            // The same engines without the gate, as in Orra 0.4.0.
            speech = Transcription(
                load: { try await speechEngine.load() },
                transcribe: { samples, context, language in try await speechEngine.transcribe(samples, context: context, language: language) }
            )
            cleanup = CleanupEngine(
                load: { try await rewrite.load(from: $0) },
                unload: { await rewrite.unload() },
                complete: { try await rewrite.cleanUp($0).answer },
                translate: { try await rewrite.translate($0, into: $1).answer },
                prepareTranslation: { try await rewrite.prepareTranslation(into: $0) }
            )
            voice = work
        } else {
            let gate = ModelGate()
            speech = Transcription.qwen3(speechEngine, gate: gate)
            cleanup = CleanupEngine.live(rewrite, gate: gate)
            voice = ExclusiveSynthesizer(work, gate: gate)
        }

        watchdog.enter("round \(round), unloading the cleanup model")
        await cleanup.unload()

        watchdog.enter("round \(round), the three loads at once")
        let speechLoad = Task {
            let reservation = speech.gate?.reserve()
            defer { reservation?.end() }
            try await speech.load()
        }
        let cleanupLoad = Task {
            let reservation = cleanup.gate?.reserve()
            defer { reservation?.end() }
            try await cleanup.load(folders.cleanup)
            for target in TextCleanup.preparedTargets(.automatic) {
                try await cleanup.prepareTranslation(target)
            }
        }
        let voiceLoad = Task { try await voice.load(model: folders.voice.model, codec: folders.voice.codec) }
        try await speechLoad.value
        try await cleanupLoad.value
        try await voiceLoad.value
        watchdog.progress()

        watchdog.enter("round \(round), the three models at work")
        let end = ContinuousClock.now + .seconds(seconds)
        let transcribing = Task {
            var index = 0
            while ContinuousClock.now < end {
                let clip = clips[index % clips.count]
                if index % 2 == 0 {
                    let before = work.now
                    let asked = ContinuousClock.now
                    let reservation = speech.gate?.reserve()
                    defer { reservation?.end() }
                    // No piece starts while the gate is reserved, so the transcription waits
                    // only for a piece in the gate now, until that piece ends.
                    let voiceInside = speech.gate?.snapshot.exclusive
                    _ = try await speech.transcribe(clip, nil, nil)
                    let total = asked.duration(to: .now)
                    let after = work.now
                    let wait = voiceInside.map { inside in
                        inside ? max(.zero, asked.duration(to: after.lastEnded ?? asked)) : .zero
                    }
                    // A piece under way when it was asked for, or one that began meanwhile.
                    tally.dictation(wait: wait, total: total, duringPiece: before.running || after.begun > before.begun)
                } else {
                    _ = try await speech.transcribe(clip, nil, nil)
                }
                tally.call()
                watchdog.progress()
                index += 1
            }
        }
        let cleaning = Task {
            var index = 0
            while ContinuousClock.now < end {
                let text = cleanupTexts[index % cleanupTexts.count]
                if index % 2 == 0 {
                    _ = try await cleanup.complete(text)
                } else {
                    _ = try await cleanup.translate(text, index % 4 == 1 ? .english : .chinese)
                }
                tally.call()
                watchdog.progress()
                index += 1
            }
        }
        let speaking = Task {
            var index = 0
            while ContinuousClock.now < end {
                if index % 3 == 2 {
                    for try await _ in voice.speak("We will meet next Tuesday at three.", in: .english, voice: sample) {}
                } else {
                    let count = 1 + (index * 7) % 40
                    let text = words.prefix(count).joined(separator: " ") + "."
                    for try await _ in voice.speak(text, in: .english, voice: nil) {
                        if index % 2 == 1 {
                            break
                        }
                    }
                }
                tally.piece()
                watchdog.progress()
                index += 1
            }
        }
        try await transcribing.value
        try await cleaning.value
        try await speaking.value

        watchdog.enter("round \(round), unloading the voice model")
        await voice.unload()
        watchdog.progress()
    }
}
#endif
