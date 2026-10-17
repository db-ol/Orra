import Foundation
import Synchronization
import Testing
@testable import Orra

/// Measures the idle unload with the real cleanup model: the memory footprint before the
/// load, after it and after the unload, the time from the press of the talk key to a
/// loaded model, and the wait a dictation after an unload adds. Only when asked for, with
/// TEST_RUNNER_ORRA_CLEANUP_IDLE_MEASURE=1, and only when the model is on this Mac, see
/// RewriteTestModel. It loads 3 GB several times, so run it on its own in a Release build:
///
///     TEST_RUNNER_ORRA_CLEANUP_IDLE_MEASURE=1 xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/CleanupIdleUnloadMeasurementTests
///
/// The speech model is a stand in that answers at once, so the measured wait is the most
/// a dictation of that hold can wait. The real speech model takes a moment more, which the
/// load overlaps too.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_CLEANUP_IDLE_MEASURE"] != nil && RewriteTestModel.folder != nil))
@MainActor
struct CleanupIdleUnloadMeasurementTests {
    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1e9)
    }

    /// The footprint right after an unload and over the next 3 s, since the system takes the
    /// freed GPU buffers back a moment later.
    private static func release() async throws -> String {
        let started = ContinuousClock.now
        var readings: [String] = []
        for offset in [0, 250, 500, 1_000, 2_000, 3_000] {
            try await Task.sleep(until: started + .milliseconds(offset))
            readings.append("\(offset) ms \(gigabytes(MemoryFootprint.current()))")
        }
        return readings.joined(separator: ", ")
    }

    /// Waits until the condition holds, and fails the test after 30 s.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Gave up waiting after 30 s")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func memoryAndWaits() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let clock = TestClock()
        let idle: Duration = .seconds(900)
        let cleanup = TextCleanup(
            isOn: true,
            save: { _ in },
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            idleUnloadDelay: idle,
            sleep: { [clock] in try await clock.sleep(for: $0) }
        )
        var report = ""

        func unload() async throws {
            for _ in 0..<1_000 where clock.sleeping == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            clock.advance(by: idle)
            try await waitUntil { cleanup.isUnloadedWhileIdle }
            await cleanup.waitForLoad()
        }

        // As at launch, the installer hands over the folder of the real model.
        let before = MemoryFootprint.current()
        let loadStarted = ContinuousClock.now
        cleanup.models.onInstalled(folder)
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        let loadTime = loadStarted.duration(to: .now)
        let loaded = MemoryFootprint.current()
        let first = await CleanupStep.run("呃，我们下午两点，哦不对，下午三点开会。", complete: cleanup.model.complete)
        let afterCleanup = MemoryFootprint.current()
        try await unload()
        report += "Footprint before load \(Self.gigabytes(before)), after load \(Self.gigabytes(loaded)) (load \(Self.seconds(loadTime))), after one cleanup (\(first.outcome.logName)) \(Self.gigabytes(afterCleanup))\n"
        report += "After the idle unload: \(try await Self.release())\n"

        // From the press of the talk key to a loaded model.
        for round in 1...3 {
            let pressed = ContinuousClock.now
            cleanup.dictationStarted()
            let ready = await cleanup.waitUntilLoaded()
            let toReady = pressed.duration(to: .now)
            let footprint = MemoryFootprint.current()
            cleanup.dictationEnded()
            report += "Round \(round): key down to model ready \(Self.seconds(toReady)), loaded \(ready), footprint \(Self.gigabytes(footprint))\n"
            try await unload()
            report += "  after the unload: \(try await Self.release())\n"
        }

        // Dictations through the controller, with a stand in microphone and speech model.
        let mic = FakeMicrophone()
        let speech = FakeSpeech()
        speech.reply = "呃，我们下午两点，哦不对，下午三点开会。"
        var pastedAt: [ContinuousClock.Instant] = []
        var pasted: [String] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup.model,
            insert: { text in
                pastedAt.append(.now)
                pasted.append(text)
                return .pasted
            },
            frontmostApp: { 100 },
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        await controller.loadModel()

        func dictate(hold: Duration) async throws -> Duration {
            let count = pasted.count
            controller.handle(.pressed(isRepeat: false))
            try await Task.sleep(for: hold)
            let released = ContinuousClock.now
            controller.handle(.released)
            try await waitUntil { pasted.count > count && controller.state == .idle }
            return released.duration(to: pastedAt[count])
        }

        for hold in [Duration.milliseconds(400), .milliseconds(800), .milliseconds(1_200), .milliseconds(2_000)] {
            let cold = try await dictate(hold: hold)
            let coldText = pasted.last
            let warm = try await dictate(hold: hold)
            report += "Hold \(Self.seconds(hold)): release to paste \(Self.seconds(cold)) after the idle unload, \(Self.seconds(warm)) right after, cleaned both times \(coldText == "我们下午3点开会。" && pasted.last == "我们下午3点开会。")\n"
            try await unload()
        }
        cleanup.turnOff()
        await cleanup.waitForLoad()
        report += "After turning off: \(try await Self.release())\n"

        print(report)
        Attachment.record(report, named: "cleanup-idle-unload.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_CLEANUP_IDLE_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Short dictations with the real speech model, which transcribes while the cleanup model
    /// still loads: the start of a clip as the recording, so the speech model reads 3 s of
    /// audio after a hold of 0.5 s.
    @Test(.enabled(if: RealModel.folder != nil && EvaluationData.isAvailable))
    func withTheSpeechModel() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let clock = TestClock()
        let idle: Duration = .seconds(900)
        let cleanup = TextCleanup(
            isOn: true,
            save: { _ in },
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            idleUnloadDelay: idle,
            sleep: { [clock] in try await clock.sleep(for: $0) }
        )
        cleanup.models.onInstalled(folder)
        await cleanup.waitForLoad()
        let speechEngine = RealModel.engine()
        let mic = FakeMicrophone()
        var pastedAt: [ContinuousClock.Instant] = []
        var pasted: [String] = []
        let runs = Mutex(0)
        var model = cleanup.model
        let complete = model.complete
        model.complete = { text in
            runs.withLock { $0 += 1 }
            return try await complete(text)
        }
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: Transcription(
                load: { try await speechEngine.load() },
                transcribe: { samples, context, language in try await speechEngine.transcribe(samples, context: context, language: language) }
            ),
            cleanup: model,
            insert: { text in
                pastedAt.append(.now)
                pasted.append(text)
                return .pasted
            },
            frontmostApp: { 100 },
            listeningCueDelay: .zero
        )
        await controller.loadModel()
        var report = ""
        for clip in try EvaluationData.clips(in: "fleurs_zh", count: 3) {
            // The idle unload, then a dictation right away and one after it.
            for _ in 0..<1_000 where clock.sleeping == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            clock.advance(by: idle)
            try await waitUntil { cleanup.isUnloadedWhileIdle }
            await cleanup.waitForLoad()
            let samples = try EvaluationData.samples(set: "fleurs_zh", name: clip.name)
            mic.recording = AudioRecording(samples: Array(samples.prefix(48_000)), sampleRate: 16_000)
            var times: [Duration] = []
            var texts: [String] = []
            var cleanups: [Int] = []
            for _ in 0..<2 {
                let count = pasted.count
                let before = runs.withLock { $0 }
                controller.handle(.pressed(isRepeat: false))
                try await Task.sleep(for: .milliseconds(500))
                let released = ContinuousClock.now
                controller.handle(.released)
                try await waitUntil { pasted.count > count && controller.state == .idle }
                times.append(released.duration(to: pastedAt[count]))
                texts.append(pasted[count])
                cleanups.append(runs.withLock { $0 } - before)
            }
            report += "Hold 0.5 s, 3 s of audio: release to paste \(Self.seconds(times[0])) after the idle unload, \(Self.seconds(times[1])) right after, model runs \(cleanups), same text \(texts[0] == texts[1])\n"
        }
        cleanup.turnOff()
        await cleanup.waitForLoad()
        print(report)
        Attachment.record(report, named: "cleanup-idle-unload-speech.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_CLEANUP_IDLE_REPORT"] {
            try report.write(toFile: path + ".speech", atomically: true, encoding: .utf8)
        }
    }
}
