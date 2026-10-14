import Foundation
import Testing
@testable import Orra

@MainActor
struct DictationTimingsTests {
    @Test func eachLapIsTheTimeSinceTheOneBefore() {
        let released = ContinuousClock.now
        var timings = DictationTimings(releasedAt: released)
        timings.lap(.start, at: released + .milliseconds(2))
        timings.lap(.releaseTail, at: released + .milliseconds(152))
        timings.lap(.recognition, at: released + .milliseconds(452))
        #expect(timings.durations == [.start: .milliseconds(2), .releaseTail: .milliseconds(150), .recognition: .milliseconds(300)])
        #expect(timings.total == .milliseconds(452))
        #expect(timings.summary == "start 2 ms, releaseTail 150 ms, recognition 300 ms")
    }

    @Test func aStepTimedTwiceAddsUp() {
        let released = ContinuousClock.now
        var timings = DictationTimings(releasedAt: released)
        timings.lap(.cleanup, at: released + .milliseconds(10))
        timings.lap(.cleanup, at: released + .milliseconds(25))
        #expect(timings.durations == [.cleanup: .milliseconds(25)])
    }

    @Test func aPastedDictationReportsEveryStepInOrder() async throws {
        let mic = FakeMicrophone()
        let speech = FakeSpeech()
        speech.delay = .milliseconds(30)
        let inserter = FakeInserter()
        let cleanup = CleanupModel(waitUntilLoaded: { true }, complete: { _ in #"{"cleaned":"你好，今天下午开会。"}"# })
        speech.reply = "你好，今天下午开会"
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .milliseconds(20)
        )
        var reported: [DictationTimings] = []
        controller.onTimings = { reported.append($0) }
        await controller.loadModel()
        controller.handle(.pressed(isRepeat: false))
        for _ in 0..<1_000 where !mic.calls.contains("start") {
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.handle(.released)
        for _ in 0..<1_000 where controller.state != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(inserter.inserted.count == 1)
        let timings = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(Set(timings.durations.keys) == Set(DictationTimings.Step.allCases))
        #expect(timings.durations[.releaseTail]! >= .milliseconds(20))
        #expect(timings.durations[.recognition]! >= .milliseconds(30))
        let sum = timings.durations.values.reduce(Duration.zero, +)
        #expect(sum == timings.total)
    }

    @Test func aDictationThatPastesNothingReportsNothing() async throws {
        let mic = FakeMicrophone()
        let speech = FakeSpeech()
        speech.reply = ""
        let inserter = FakeInserter()
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero
        )
        var reported = 0
        controller.onTimings = { _ in reported += 1 }
        await controller.loadModel()
        controller.handle(.pressed(isRepeat: false))
        for _ in 0..<1_000 where !mic.calls.contains("start") {
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.handle(.released)
        for _ in 0..<1_000 where controller.state != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(inserter.inserted.isEmpty)
        #expect(reported == 0)
    }
}
