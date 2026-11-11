import Foundation
import Testing
@testable import Orra

/// A recording in progress that a test fills as it likes, read the way the text shown while
/// the user speaks reads the microphone, by index. Never touches real audio.
@MainActor
final class ScriptedRecording {
    var samples: [Float] = []
    var sampleRate = Double(RecordingLimits.sampleRate)
    /// The recording's number, as the recorder counts them.
    var number = 1
    /// True once the recording stopped.
    var isOver = false
    /// How many reads came.
    private(set) var reads = 0

    func recorded(after count: Int, of recording: Int?) -> RecordedAudio? {
        reads += 1
        guard !isOver, recording == nil || recording == number else { return nil }
        let new = count < samples.count ? Array(samples[max(count, 0)...]) : []
        return RecordedAudio(samples: new, sampleRate: sampleRate, recording: number)
    }
}

/// A stand in for the speech model's pass that stops when its task is cancelled.
@MainActor
final class LivePasses {
    var delay: Duration = .zero
    /// What the next passes give, one each, before `reply`.
    var queued: [Result<String, any Error>] = []
    var reply = "你好"
    private(set) var sampleCounts: [Int] = []
    private(set) var running = 0
    private(set) var mostRunning = 0
    private(set) var cancelled = 0
    private(set) var finished = 0

    func pass(_ samples: [Float]) async throws -> String {
        sampleCounts.append(samples.count)
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                cancelled += 1
                throw error
            }
        }
        finished += 1
        if !queued.isEmpty {
            return try queued.removeFirst().get()
        }
        return reply
    }
}

@MainActor
struct LiveDictationTests {
    let recording = ScriptedRecording()
    let passes = LivePasses()

    /// The texts the dictation published, nil for a hide.
    final class Published {
        var texts: [LiveText?] = []
        var last: LiveText? {
            texts.last ?? nil
        }
    }

    /// What a task the test started saw when `ended()` returned, so the test can wait for
    /// it without awaiting a task that may never end.
    @MainActor
    final class AtTheEnd {
        /// The passes cancelled by then, nil until `ended()` returned.
        var cancelled: Int?
    }

    private func makeLive(
        _ published: Published,
        settings: LiveDictation.Settings = LiveDictationTests.settings,
        allowed: @escaping () -> Bool = { true },
        mayStartPass: @escaping () -> Bool = { true },
        piecePass: LiveDictation.PiecePass? = nil
    ) -> LiveDictation {
        let live = LiveDictation(
            read: { [recording] count, number in recording.recorded(after: count, of: number) },
            transcribe: { [passes] samples in try await passes.pass(samples) },
            language: .chinese,
            settings: settings,
            allowed: allowed,
            mayStartPass: mayStartPass,
            piecePass: piecePass,
            publish: { published.texts.append($0) }
        )
        live.start(after: Task { Optional(ContinuousClock.now) })
        return live
    }

    /// Reads every 5 ms and asks whether the text may show as often, so the tests do not
    /// wait for the 100 ms and 500 ms of the app.
    static var settings: LiveDictation.Settings {
        var settings = LiveDictation.Settings()
        settings.readInterval = .milliseconds(5)
        settings.rulesInterval = .milliseconds(5)
        return settings
    }

    @Test func theDefaultsAreThoseOfCaptions() {
        let settings = LiveDictation.Settings()
        #expect(settings.interimInterval == CaptionPipeline.defaultInterimInterval)
        #expect(settings.interimPauseLimit == CaptionPipeline.interimPauseLimit)
        #expect(settings.pieces == CaptionSegmenter.Settings())
        #expect(settings.readInterval == .milliseconds(100))
        #expect(settings.rulesInterval == .milliseconds(500))
    }

    @Test func theSentenceBeingHeardShowsAndItsPieceReplacesIt() async throws {
        let published = Published()
        passes.queued = [.success("你好"), .success("你好，世界。")]
        let live = makeLive(published)
        recording.samples = CaptionAudio.silence(0.3) + CaptionAudio.tone(1.5)
        try await waitUntil { published.last?.interim == "你好" }
        #expect(published.last == LiveText(finished: "", interim: "你好"))
        // A pause ends the sentence, and its piece's text takes the place of the interim text.
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { published.last?.finished == "你好，世界。" }
        #expect(published.last == LiveText(finished: "你好，世界。", interim: nil))
        #expect(passes.sampleCounts.count == 2)
        // The interim pass read the sentence with the time before it, the piece's pass too.
        #expect(passes.sampleCounts.allSatisfy { $0 > 16_000 && $0 <= 2 * 16_000 })
        live.release()
        #expect(await live.ended() == nil)
        #expect(live.counts.pieces == 1)
        #expect(live.counts.piecePasses == 1)
        #expect(live.counts.interimPasses == 1)
    }

    @Test func piecesAreTranscribedOneAtATimeInOrder() async throws {
        let published = Published()
        passes.delay = .milliseconds(30)
        passes.queued = [.success("一。"), .success("二。"), .success("三。")]
        var settings = Self.settings
        // Pieces only, so the order of the replies is the order of the pieces.
        settings.interimInterval = 1_000
        let live = makeLive(published, settings: settings)
        recording.samples = CaptionAudio.tone(1) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(1)
        try await waitUntil { published.last?.finished == "一。二。三。" }
        #expect(passes.mostRunning == 1)
        #expect(live.counts.interimPasses == 0)
        live.cancel()
        _ = await live.ended()
    }

    /// No interim pass while a piece waits for its pass, and none while the sentence pauses.
    @Test func anInterimPassWaitsForThePiecesAndForSpeech() async throws {
        let published = Published()
        passes.delay = .milliseconds(30)
        let live = makeLive(published)
        // Two sentences that ended, then silence: pieces only.
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1) + CaptionAudio.tone(1.5) + CaptionAudio.silence(2)
        try await waitUntil { live.counts.piecePasses == 2 }
        // Two more reads, so the dictation chose its next step after the pieces at least
        // once, however long the test process stalls.
        let reads = recording.reads
        try await waitUntil { recording.reads > reads + 1 }
        #expect(live.counts.interimPasses == 0)
        live.cancel()
        _ = await live.ended()
    }

    @Test func theReleaseCancelsThePassUnderWayAndNothingShowsAfterIt() async throws {
        let published = Published()
        // An hour, so only the cancel ends the pass, however long the test process stalls.
        passes.delay = .seconds(3_600)
        let live = makeLive(published)
        recording.samples = CaptionAudio.tone(1.5)
        try await waitUntil { passes.running == 1 }
        // The release and ended() in a task of their own, with nothing between them on the
        // main actor, so the pass the release cancelled has not ended yet when ended()
        // starts to wait. The task notes the cancelled passes once ended() returns. The test
        // waits for that note instead of awaiting the task, so a release that stops no pass
        // fails at the wait instead of waiting out the hour.
        let atTheEnd = AtTheEnd()
        let release = Task { [passes] in
            live.release()
            let joined = await live.ended()
            atTheEnd.cancelled = passes.cancelled
            return joined
        }
        try await waitUntil { atTheEnd.cancelled != nil }
        // The pass had stopped at the cancel when ended() returned, long before its hour.
        #expect(atTheEnd.cancelled == 1)
        #expect(await release.value == nil)
        #expect(published.texts.isEmpty)
        // Nothing reads or runs after it.
        let reads = recording.reads
        recording.samples += CaptionAudio.silence(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recording.reads == reads)
        #expect(passes.sampleCounts.count == 1)
    }

    /// A release that comes after a pass was chosen but before it reached the model starts
    /// no pass, since the gate lets a cancelled call in when it can enter at once.
    @Test func aReleaseBeforeThePassReachesTheModelStartsNone() async throws {
        let published = Published()
        var live: LiveDictation?
        var asked = 0
        live = makeLive(published, mayStartPass: {
            asked += 1
            live?.release()
            return true
        })
        // The piece ends at the first read, so the first question is for its pass.
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        #expect(await live?.ended() == nil)
        #expect(asked == 1)
        #expect(passes.sampleCounts.isEmpty)
        #expect(published.texts.isEmpty)
    }

    /// A pass that throws CancellationError while nothing cancelled it counts as failed, and
    /// its piece is not run again and again.
    @Test func aCancellationErrorWithoutACancelCountsAsAFailedPass() async throws {
        let published = Published()
        passes.queued = [.failure(CancellationError())]
        let live = makeLive(published)
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        try await waitUntil { live.counts.failedPasses == 1 }
        // Two more reads, so the dictation chose its next step after the failed pass.
        let reads = recording.reads
        try await waitUntil { recording.reads > reads + 1 }
        #expect(passes.sampleCounts.count == 1)
        #expect(published.texts.isEmpty)
        live.cancel()
        _ = await live.ended()
    }

    /// Whether the text may show is asked at the first read and then only every
    /// `rulesInterval`, since the app asks the window server on the main thread.
    @Test func whetherTheTextMayShowIsNotAskedAtEveryRead() async throws {
        let published = Published()
        var settings = Self.settings
        // An hour, so the reads come long before the next question even when the test
        // process stalls. With a minute, the busy CI runner took longer than that for them.
        settings.rulesInterval = .seconds(3_600)
        var asked = 0
        let live = makeLive(published, settings: settings, allowed: {
            asked += 1
            return true
        })
        try await waitUntil { recording.reads > 20 }
        #expect(asked == 1)
        live.cancel()
        _ = await live.ended()
    }

    @Test func aCancelStopsThePassAndShowsNothingMore() async throws {
        let published = Published()
        // An hour, so only the cancel ends the pass, however long the test process stalls.
        passes.delay = .seconds(3_600)
        let live = makeLive(published)
        recording.samples = CaptionAudio.tone(1.5)
        try await waitUntil { passes.running == 1 }
        live.cancel()
        try await waitUntil { passes.cancelled == 1 }
        _ = await live.ended()
        #expect(published.texts.isEmpty)
    }

    /// A text in a language the user does not dictate in is not shown, and the text of the
    /// next pass is.
    @Test func aTextInAThirdLanguageIsNotShown() async throws {
        let published = Published()
        passes.queued = [.success("안녕하세요 여러분 반갑습니다"), .success("大家好。")]
        let live = makeLive(published)
        recording.samples = CaptionAudio.tone(1.5)
        try await waitUntil { passes.finished == 1 }
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { published.last?.finished == "大家好。" }
        #expect(published.texts == [LiveText(finished: "大家好。", interim: nil)])
        live.cancel()
        _ = await live.ended()
    }

    /// A piece that gives no text takes the interim text of its sentence away, as a caption
    /// that ends without text does.
    @Test func aPieceWithoutTextTakesItsInterimTextAway() async throws {
        let published = Published()
        passes.queued = [.success("嗯"), .success("")]
        let live = makeLive(published)
        recording.samples = CaptionAudio.tone(1.5)
        try await waitUntil { published.last?.interim == "嗯" }
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { published.texts.count == 2 }
        #expect(published.last?.isEmpty == true)
        live.cancel()
        _ = await live.ended()
    }

    @Test func noPassStartsWhileTheCleanupModelPrepares() async throws {
        let published = Published()
        var preparing = true
        let live = makeLive(published, mayStartPass: { !preparing })
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        try await waitUntil { recording.reads > 5 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(passes.sampleCounts.isEmpty)
        // The piece waited, and runs once the load is done.
        preparing = false
        try await waitUntil { published.last?.finished == "你好" }
        live.cancel()
        _ = await live.ended()
    }

    @Test func theTextGoesOnceItIsNoLongerAllowed() async throws {
        let published = Published()
        var allowed = true
        let live = makeLive(published, allowed: { allowed })
        recording.samples = CaptionAudio.tone(1.5)
        try await waitUntil { published.last?.interim == "你好" }
        allowed = false
        try await waitUntil { published.texts.last == .some(nil) }
        let count = passes.sampleCounts.count
        recording.samples += CaptionAudio.silence(1)
        #expect(await live.ended() == nil)
        #expect(passes.sampleCounts.count == count)
    }

    /// After the model was busy with this hold for more than its share of the window, an
    /// interim pass waits, while pieces still get theirs.
    @Test func interimPassesWaitWhileTheModelWasBusy() async throws {
        let published = Published()
        var settings = Self.settings
        settings.busyShare = 0
        // An hour, so the first pass stays in the window even when the test process stalls.
        // With the app's 10 s, a longer stall would empty the window and let a second
        // interim pass start.
        settings.busyWindow = .seconds(3_600)
        let live = makeLive(published, settings: settings)
        passes.delay = .milliseconds(20)
        // A long sentence without a pause would get an interim pass every second.
        recording.samples = CaptionAudio.tone(1.2)
        try await waitUntil { live.counts.interimPasses == 1 }
        let reads = recording.reads
        recording.samples += CaptionAudio.tone(3)
        // Two more reads, so the dictation read the new speech and chose its next step.
        try await waitUntil { recording.reads > reads + 1 }
        #expect(live.counts.interimPasses == 1)
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { live.counts.piecePasses == 1 }
        live.cancel()
        _ = await live.ended()
    }

    /// A reader left from an earlier recording reads nothing of a newer one and stops.
    @Test func aReaderOfAnEarlierRecordingStops() async throws {
        let published = Published()
        let live = makeLive(published)
        try await waitUntil { recording.reads > 0 }
        recording.number = 2
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        #expect(await live.ended() == nil)
        #expect(passes.sampleCounts.isEmpty)
    }

    // MARK: Pieces joined for the paste, for measurements only

    @Test func theReleaseWaitsForAPieceUnderWayAndLeavesTheRestToTheLastPiece() async throws {
        let published = Published()
        let context = DictationContext(vocabulary: ["Orra"], holdsScreenNames: false, takingDigits: true, language: .chinese)
        var contexts = 0
        var piecesRun: [Int] = []
        var holdFirst = true
        let piecePass = LiveDictation.PiecePass(
            context: {
                contexts += 1
                return context
            },
            transcribe: { samples, given in
                #expect(given == context)
                piecesRun.append(samples.count)
                while holdFirst {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return "第一句。"
            }
        )
        var settings = Self.settings
        settings.interimInterval = 1_000
        let live = makeLive(published, settings: settings, piecePass: piecePass)
        recording.samples = CaptionAudio.tone(1) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(1)
        try await waitUntil { piecesRun.count == 1 }
        // Both pieces ended, the first one's pass runs.
        try await waitUntil { live.counts.pieces == 2 }
        live.release()
        holdFirst = false
        let joined = try #require(await live.ended())
        #expect(joined.pieces.map(\.text) == ["第一句。"])
        #expect(joined.context == context)
        #expect(contexts == 1)
        // The second piece was not run. Its audio goes into the last piece.
        #expect(piecesRun.count == 1)
        #expect(joined.cut == piecesRun[0])
        #expect(passes.sampleCounts.isEmpty)
    }

    @Test func aFailedPieceLetsThePasteGoOnAsWithoutPieces() async throws {
        let published = Published()
        let piecePass = LiveDictation.PiecePass(
            context: { DictationContext(vocabulary: [], holdsScreenNames: false, takingDigits: true, language: .chinese) },
            transcribe: { _, _ in throw TestError() }
        )
        var settings = Self.settings
        settings.interimInterval = 1_000
        let live = makeLive(published, settings: settings, piecePass: piecePass)
        recording.samples = CaptionAudio.tone(1) + CaptionAudio.silence(1)
        try await waitUntil { live.counts.failedPasses == 1 }
        live.release()
        #expect(await live.ended() == nil)
    }

    @Test func theTextKeepsItsLastCharacters() {
        let text = LiveText(finished: String(repeating: "一", count: 400), interim: "二三")
        let tail = text.tail(300)
        #expect(tail.interim == "二三")
        #expect(tail.finished.count == 298)
        #expect(LiveText(finished: "Hello.", interim: "How are").interimAfterFinished == " How are")
        #expect(LiveText(finished: "你好。", interim: "今天").interimAfterFinished == "今天")
        #expect(LiveText(finished: "", interim: "今天").interimAfterFinished == "今天")
        #expect(LiveText(finished: "你好", interim: nil).interimAfterFinished == "")
        #expect(LiveText().isEmpty)
        #expect(LiveText(finished: "", interim: "").isEmpty)
    }
}
