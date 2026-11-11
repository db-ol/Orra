import Foundation
import Testing
@testable import Orra

/// Measures with the real speech model what the release relies on while the text shows as
/// the user speaks, see LiveDictation. Only when asked for, with
/// TEST_RUNNER_ORRA_LIVE_TEXT_EVAL=1, never in CI, and in a Release build, since a Debug
/// build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_LIVE_TEXT_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=<corpus> TEST_RUNNER_ORRA_LATENCY_CLIPS=<folder of WAV files> TEST_RUNNER_ORRA_LIVE_TEXT_REPORT=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/LiveTextMeasurementTests
///
/// `theStoppablePassWritesTheSameTextAndStopsSoon` transcribes each clip of the corpus with
/// the plain pass and with the pass that a cancel stops, and counts the clips where the two
/// differ. Then it cancels the stoppable pass 0, 10, 20, 50, 100 and 150 ms after it
/// started, on clips of about 12 s and 30 s, without context and with 200 made up terms,
/// and reports how long each pass went on after the cancel. MLX computes lazily, so the
/// encoder, the prompt and the first tokens run as one piece that a cancel cannot cut
/// short, and a long prompt makes that piece longer. A cancel at 0 ms mostly comes before
/// the pass begins and stops at its first check, so the most of the 20, 50 and 100 ms
/// cancels is what to judge by. Last, the plain pass runs again on the 12 s clips, which
/// must give the text it gave before the cancels.
///
/// `releaseToPasteWithTheTextOnAndOff` drives PushToTalkController with the app's gated
/// speech model, a vocabulary of 200 made up terms and 40 names on screen. A stand in
/// microphone plays each latency clip at its real speed, the key is released 0.3, 0.8 and
/// 1.5 s after the clip ends (TEST_RUNNER_ORRA_LIVE_TEXT_RELEASES sets others), with the text
/// off and on in turn, and cleanup off. Every run of a clip and release pastes from the same
/// samples, the clip and silence up to the release and the tail, so a text that differs
/// between on and off is not one of timing. TEST_RUNNER_ORRA_LATENCY_ROUNDS sets the rounds,
/// two by default. The report gives release to paste and liveTextStop at the median, p90,
/// p99 and most, how many releases waited more than 20 ms, release to paste with the text
/// on minus off beside the proposed bar, and how many pairs of the same round pasted the
/// same text.
///
/// The reports hold durations and counts only, never text.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_LIVE_TEXT_EVAL"] != nil))
@MainActor
struct LiveTextMeasurementTests {
    private static var reportFolder: URL? {
        ProcessInfo.processInfo.environment["ORRA_LIVE_TEXT_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Seconds after the speech at which `releaseToPasteWithTheTextOnAndOff` releases the
    /// key, from TEST_RUNNER_ORRA_LIVE_TEXT_RELEASES, such as 0.3,0.8,1.5, the default.
    private static var releaseOffsets: [Double] {
        ProcessInfo.processInfo.environment["ORRA_LIVE_TEXT_RELEASES"].map { $0.split(separator: ",").compactMap { Double($0) } } ?? [0.3, 0.8, 1.5]
    }

    /// 200 made up terms, half Latin and half Chinese, about as long as a vocabulary of
    /// names and product words.
    private static let terms: [String] = (0..<100).map { "Kestrel\($0) Nova" } + (0..<100).map { "甄若\($0)号" }

    private static func milliseconds(_ duration: Duration) -> Double {
        SpeechCorpus.seconds(duration) * 1_000
    }

    /// The value at `share` of the sorted values, such as 0.9 for p90.
    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * share).rounded()))]
    }

    @Test func theStoppablePassWritesTheSameTextAndStopsSoon() async throws {
        let corpus = try #require(SpeechCorpus.folder, "set TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR")
        let folder = try #require(Self.reportFolder, "set TEST_RUNNER_ORRA_LIVE_TEXT_REPORT to a new folder")
        let modelFolder = try #require(SpeechCorpus.modelFolder, "no speech model on this Mac")
        let engine = Qwen3Engine(folder: { modelFolder })
        try await engine.load()
        var lines: [String] = []
        var same = 0
        var different: [String] = []
        var twelve: [[Float]] = []
        var twelveTexts: [String] = []
        var thirty: [[Float]] = []
        var joined: [Float] = []
        for clip in try SpeechCorpus.clips(SpeechCorpus.manifest(in: corpus), listed: SpeechCorpus.listedClips()) {
            let samples = AudioResampler.monoAt16kHz(try SpeechCorpus.recording(corpus.appendingPathComponent("clips/\(clip.id).wav")))
            guard !Silence.isSilent(samples) else { continue }
            let plain = try await engine.transcribe(samples)
            let stoppable = try await engine.transcribe(samples, stopsWhenCancelled: true)
            if plain == stoppable {
                same += 1
            } else {
                different.append(clip.id)
            }
            let seconds = Double(samples.count) / 16_000
            if twelve.count < 4, (10...14).contains(seconds) {
                twelve.append(samples)
                twelveTexts.append(plain)
            }
            if thirty.count < 2 {
                joined += samples + [Float](repeating: 0, count: 4_800)
                if joined.count >= 30 * 16_000 {
                    thirty.append(Array(joined.prefix(30 * 16_000)))
                    joined = []
                }
            }
        }
        lines.append("Same text from the plain and the stoppable pass: \(same) clips, different: \(different.count) (\(different.joined(separator: ", ")))")

        let context = Vocabulary.context(Self.terms)
        for (name, clips) in [("12 s", twelve), ("30 s", thirty)] {
            for (label, terms) in [("no context", nil as String?), ("200 terms", context)] {
                // The cancels 20, 50 and 100 ms after the start, which land in the pass.
                var judged: [Double] = []
                for offset in [0, 10, 20, 50, 100, 150] {
                    var after: [Double] = []
                    var finished = 0
                    for samples in clips {
                        for _ in 0..<3 {
                            let pass = Task { try await engine.transcribe(samples, context: terms, stopsWhenCancelled: true) }
                            if offset > 0 {
                                try await Task.sleep(for: .milliseconds(offset))
                            }
                            let cancelled = ContinuousClock.now
                            pass.cancel()
                            if case .success = await pass.result {
                                finished += 1
                            }
                            after.append(Self.milliseconds(cancelled.duration(to: .now)))
                        }
                    }
                    if [20, 50, 100].contains(offset) {
                        judged += after
                    }
                    lines.append(String(format: "%@, %@, cancel %3d ms after the start: %d passes, ended after the cancel in median %.0f ms, p90 %.0f ms, most %.0f ms, %d ran to their end", name, label, offset, after.count, Self.percentile(after, 0.5), Self.percentile(after, 0.9), after.max() ?? 0, finished))
                }
                lines.append(String(format: "%@, %@, most of the cancels 20, 50 and 100 ms after the start: %.0f ms", name, label, judged.max() ?? 0))
            }
        }
        var again = 0
        for (samples, text) in zip(twelve, twelveTexts) {
            if try await engine.transcribe(samples) == text {
                again += 1
            }
        }
        lines.append("Same text from the plain pass after the cancels: \(again) of \(twelve.count) clips")
        let report = lines.joined(separator: "\n")
        print(report)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.write(to: folder.appendingPathComponent("stoppable-pass.txt"), atomically: true, encoding: .utf8)
        #expect(different.isEmpty)
        #expect(again == twelve.count)
    }

    @Test func releaseToPasteWithTheTextOnAndOff() async throws {
        let folder = try #require(Self.reportFolder, "set TEST_RUNNER_ORRA_LIVE_TEXT_REPORT to a new folder")
        let speechFolder = try #require(RealModel.folder, "no speech model on this Mac")
        let language = try DictationPair.chosen()
        let clips = try LatencyMeasurement.clips(for: language)
        try #require(!clips.isEmpty)
        let microphone = RealTimeMicrophone()
        let gate = ModelGate()
        let names = (0..<40).map { "Quorvia\($0)" }
        var pasted: [String] = []
        let controller = PushToTalkController(
            capture: microphone.capture,
            transcription: .qwen3(Qwen3Engine(folder: { speechFolder }), gate: gate),
            insert: { text in
                pasted.append(text)
                return .pasted
            },
            frontmostApp: { 100 },
            lidIsClosed: { false },
            isTrusted: { true },
            minimumHold: .zero,
            vocabulary: Self.terms.map { VocabularyWord($0, added: Date(timeIntervalSince1970: 0)) },
            usesScreenNames: true,
            readScreenNames: { _, _ in names },
            showsLiveText: false,
            liveTextAllowed: { true },
            dictationLanguage: language
        )
        var latest: DictationTimings?
        controller.onTimings = { latest = $0 }
        await controller.loadModel()
        try #require(controller.modelState == .ready)

        struct Run {
            let on: Bool
            let offset: Double
            let total: Double
            let stop: Double
        }
        var runs: [Run] = []
        // The pasted texts of each round, clip and release, with the text on and off.
        var texts: [String: [Bool: String]] = [:]
        func dictate(_ clip: LatencyMeasurement.Clip, on: Bool, offset: Double, round: Int) async throws {
            controller.setShowsLiveText(on)
            microphone.clip = clip.recording
            microphone.recordingLength = clip.recording.samples.count + Int((offset + SpeechCorpus.seconds(RecordingLimits.releaseTail)) * clip.recording.sampleRate)
            latest = nil
            pasted = []
            controller.handle(.pressed(isRepeat: false))
            try await Task.sleep(for: .seconds(clip.recording.duration + offset))
            controller.handle(.released)
            try await LatencyMeasurement.waitUntil { controller.state == .idle }
            guard let timings = latest, let text = pasted.last else {
                Issue.record("\(clip.name) pasted nothing, text \(on)")
                return
            }
            runs.append(Run(on: on, offset: offset, total: Self.milliseconds(timings.total), stop: Self.milliseconds(timings.durations[.liveTextStop] ?? .zero)))
            texts["\(round) \(clip.name) \(offset)", default: [:]][on] = text
        }
        // One of each first, so neither pays for a first run.
        try await dictate(clips[0], on: false, offset: 0.3, round: -1)
        try await dictate(clips[0], on: true, offset: 0.3, round: -1)
        runs = []
        texts = [:]
        for round in 0..<LatencyMeasurement.rounds {
            for clip in clips {
                for offset in Self.releaseOffsets {
                    for on in round % 2 == 0 ? [false, true] : [true, false] {
                        try await dictate(clip, on: on, offset: offset, round: round)
                    }
                }
            }
        }
        var lines: [String] = []
        for offset in Self.releaseOffsets {
            for on in [false, true] {
                let chosen = runs.filter { $0.on == on && $0.offset == offset }
                let totals = chosen.map(\.total)
                let stops = chosen.map(\.stop)
                lines.append(String(format: "Text %@, release %.1f s after the speech: %d runs, release to paste median %.0f ms, p90 %.0f ms, most %.0f ms, liveTextStop median %.1f ms, p90 %.1f ms, p99 %.1f ms, most %.1f ms, over 20 ms: %d", on ? "on " : "off", offset, chosen.count, Self.percentile(totals, 0.5), Self.percentile(totals, 0.9), totals.max() ?? 0, Self.percentile(stops, 0.5), Self.percentile(stops, 0.9), Self.percentile(stops, 0.99), stops.max() ?? 0, stops.count { $0 > 20 }))
            }
        }
        // The proposed bar: on within 10 ms or 5% of off, whichever is larger.
        for offset in Self.releaseOffsets {
            let off = runs.filter { !$0.on && $0.offset == offset }.map(\.total)
            let on = runs.filter { $0.on && $0.offset == offset }.map(\.total)
            let median = (on: Self.percentile(on, 0.5), off: Self.percentile(off, 0.5))
            let p90 = (on: Self.percentile(on, 0.9), off: Self.percentile(off, 0.9))
            lines.append(String(format: "Release %.1f s after the speech, on minus off: median %+.0f ms (bar %.0f ms), p90 %+.0f ms (bar %.0f ms)", offset, median.on - median.off, max(10, median.off * 0.05), p90.on - p90.off, max(10, p90.off * 0.05)))
        }
        let stops = runs.filter(\.on).map(\.stop)
        lines.append(String(format: "liveTextStop with the text on, all %d releases: p99 %.1f ms, most %.1f ms (bar 20 ms)", stops.count, Self.percentile(stops, 0.99), stops.max() ?? 0))
        let pairs = texts.values.filter { $0.count == 2 }
        lines.append("Pairs that pasted the same text with the text on and off: \(pairs.count { $0[true] == $0[false] }) of \(pairs.count)")
        let report = lines.joined(separator: "\n")
        print(report)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.write(to: folder.appendingPathComponent("release-to-paste.txt"), atomically: true, encoding: .utf8)
    }
}

/// A stand in microphone that plays a clip at its real speed from the start of the
/// recording, and silence after it until the stop, for LiveTextMeasurementTests.
@MainActor
final class RealTimeMicrophone {
    var clip = AudioRecording(samples: [], sampleRate: 48_000)
    /// How many samples the stop returns, the clip and silence after it, so two runs of a
    /// clip released at the same time paste from the same samples whatever the timing.
    /// Nil returns what was recorded by the stop.
    var recordingLength: Int?
    private var started: ContinuousClock.Instant?
    private var number = 0

    /// The samples recorded by `now`.
    private func count(at now: ContinuousClock.Instant) -> Int {
        guard let started else { return 0 }
        return Int(SpeechCorpus.seconds(started.duration(to: now)) * clip.sampleRate)
    }

    /// The samples recorded by now after the first `start`.
    private func samples(after start: Int) -> [Float] {
        let total = count(at: .now)
        guard start < total else { return [] }
        let fromClip = start < clip.samples.count ? Array(clip.samples[start..<min(total, clip.samples.count)]) : []
        return fromClip + [Float](repeating: 0, count: max(0, total - max(start, clip.samples.count)))
    }

    var capture: AudioCapture {
        AudioCapture(
            access: { .authorized },
            requestAccess: { .authorized },
            start: { _ in
                self.number += 1
                self.started = .now
            },
            stop: {
                defer { self.started = nil }
                let samples = self.recordingLength.map { length in
                    Array(self.clip.samples.prefix(length)) + [Float](repeating: 0, count: max(0, length - self.clip.samples.count))
                } ?? self.samples(after: 0)
                return AudioRecording(samples: samples, sampleRate: self.clip.sampleRate)
            },
            cancel: { self.started = nil },
            recorded: { count, recording in
                guard self.started != nil, recording == nil || recording == self.number else { return nil }
                return RecordedAudio(samples: self.samples(after: count), sampleRate: self.clip.sampleRate, recording: self.number)
            }
        )
    }
}
