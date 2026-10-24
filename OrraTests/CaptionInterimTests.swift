import Foundation
import Testing
@testable import Orra

/// The sentence the segmenter is still hearing, which interim captions transcribe.
struct CaptionSegmenterOpenSentenceTests {
    @Test func betweenSentencesNothingIsOpen() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.append(CaptionAudio.silence(1))
        #expect(segmenter.openSentence == nil)
        #expect(segmenter.openSeconds == 0)
        #expect(segmenter.openSilenceSeconds == 0)
    }

    @Test func tooLittleSpeechIsNoOpenSentenceYet() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.append(CaptionAudio.silence(1) + CaptionAudio.tone(0.2))
        #expect(segmenter.isInSpeech)
        #expect(segmenter.openSentence == nil)
    }

    @Test func theOpenSentenceGrowsAndStartsWhereItsFinalTextStarts() throws {
        var segmenter = CaptionSegmenter()
        _ = segmenter.append(CaptionAudio.silence(1) + CaptionAudio.tone(1))
        let early = try #require(segmenter.openSentence)
        // The preroll before the start at 1 s, as for the sentence once it ends.
        #expect(abs(early.start - 0.8) < 0.03)
        #expect(abs(segmenter.openSeconds - 1.2) < 0.03)
        #expect(segmenter.openSilenceSeconds == 0)
        _ = segmenter.append(CaptionAudio.tone(1))
        let later = try #require(segmenter.openSentence)
        #expect(later.start == early.start)
        #expect(later.duration > early.duration + 0.9)
        #expect(later.samples.count == Int((later.end - later.start) * CaptionAudio.rate))
        let final = segmenter.append(CaptionAudio.silence(1))
        try #require(final.count == 1)
        #expect(final[0].start == early.start)
        #expect(segmenter.openSentence == nil)
    }

    @Test func aPauseInsideTheSentenceCountsAndTheOpenSentenceStopsAtTheVoice() throws {
        var segmenter = CaptionSegmenter()
        _ = segmenter.append(CaptionAudio.silence(0.5) + CaptionAudio.tone(1) + CaptionAudio.silence(0.3))
        #expect(segmenter.isInSpeech)
        #expect(abs(segmenter.openSilenceSeconds - 0.3) < 0.03)
        let open = try #require(segmenter.openSentence)
        // Up to the last voiced frame and the 0.15 s tail, not the whole pause.
        #expect(abs(open.end - 1.65) < 0.03)
    }
}

/// Interim captions: text of a sentence while it is still heard, replaced by its final
/// text.
@MainActor
struct CaptionInterimTests {
    /// Feeds audio in 100 ms chunks like the capture, letting the pipeline run between.
    private func feedLive(_ pipeline: CaptionPipeline, _ audio: [Float]) async throws {
        let chunk = RecordingLimits.sampleRate / 10
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + chunk)
            pipeline.feed(Array(audio[index..<end]))
            index = end
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func interimTextShowsWhileTalkingAndTheFinalTextReplacesIt() async throws {
        let models = FakeCaptionModels(["Hello", "Hello everyone", "Hello everyone."])
        var reports: [CaptionSentence] = []
        var withdrawn: [Int] = []
        let pipeline = CaptionPipeline(engines: models.engines(), interimInterval: 1, withdraw: { withdrawn.append($0) }) { reports.append($0) }
        try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(2.5))
        let interims = reports.filter(\.isInterim)
        // At 1 s and 2 s of the sentence, with the preroll.
        #expect(interims.count == 2)
        #expect(interims.map(\.original) == ["Hello", "Hello everyone"])
        #expect(interims.allSatisfy { $0.id == 1 && $0.translation == .none })
        try await feedLive(pipeline, CaptionAudio.silence(1))
        await pipeline.finish()
        let finals = reports.filter { !$0.isInterim }
        #expect(finals.map(\.id) == [1, 1])
        #expect(finals.map(\.original) == ["Hello everyone.", "Hello everyone."])
        #expect(finals.map(\.translation) == [.pending, .done("大家好。")])
        // The final text starts where the interim text did, and only it was translated.
        #expect(finals[0].start == interims[0].start)
        #expect(models.translated.map(\.0) == ["Hello everyone."])
        #expect(withdrawn.isEmpty)
        #expect(models.mostRunning == 1)
    }

    @Test func theNextSentenceGetsItsOwnLine() async throws {
        let models = FakeCaptionModels(["Hello", "Hello everyone.", "Next", "Next slide please."])
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(), interimInterval: 1) { reports.append($0) }
        for round in 1...2 {
            try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(1.5) + CaptionAudio.silence(1))
            try await eventually { reports.filter { !$0.isInterim }.count == 2 * round }
        }
        await pipeline.finish()
        #expect(reports.filter(\.isInterim).map(\.id) == [1, 2])
        #expect(reports.filter { !$0.isInterim && $0.translation == .pending }.map(\.original) == ["Hello everyone.", "Next slide please."])
        #expect(reports.filter { !$0.isInterim }.map(\.id) == [1, 1, 2, 2])
    }

    @Test func anInterimLineWithoutFinalTextGoes() async throws {
        let models = FakeCaptionModels(["Hmm", ""])
        var reports: [CaptionSentence] = []
        var withdrawn: [Int] = []
        let pipeline = CaptionPipeline(engines: models.engines(), interimInterval: 1, withdraw: { withdrawn.append($0) }) { reports.append($0) }
        try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(1.5) + CaptionAudio.silence(1))
        await pipeline.finish()
        #expect(reports.map(\.isInterim) == [true])
        #expect(withdrawn == [1])
    }

    @Test func withoutAnIntervalThereIsNoInterimText() async throws {
        let models = FakeCaptionModels(["Hello everyone."])
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines()) { reports.append($0) }
        try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(3) + CaptionAudio.silence(1))
        await pipeline.finish()
        #expect(models.transcribed == 1)
        #expect(!reports.contains { $0.isInterim })
    }

    @Test func aDictationGetsTheModelAndNoInterimTextRuns() async throws {
        let models = FakeCaptionModels(["Hello everyone."])
        let turns = EngineTurns(pollInterval: .milliseconds(5))
        var engines = models.engines(turns: turns)
        engines.isFree = { !turns.isDictating }
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: engines, interimInterval: 1) { reports.append($0) }
        turns.dictationStarted()
        try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(3) + CaptionAudio.silence(1))
        #expect(models.transcribed == 0)
        turns.dictationEnded()
        await pipeline.finish()
        // Only the final text, after the dictation.
        #expect(models.transcribed == 1)
        #expect(reports.map(\.original) == ["Hello everyone.", "Hello everyone."])
        #expect(!reports.contains { $0.isInterim })
    }

    @Test func aWaitingSentenceGoesBeforeInterimText() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please."])
        // The first sentence's text takes until the next one is heard. A delay of 400 ms
        // stood for that, and on a busy test runner the feeding below took longer.
        models.holdsFirstTranscription = true
        var reports: [CaptionSentence] = []
        let pipeline = CaptionPipeline(engines: models.engines(), interimInterval: 1) { reports.append($0) }
        try await feedLive(pipeline, CaptionAudio.silence(0.5) + CaptionAudio.tone(0.6) + CaptionAudio.silence(0.7) + CaptionAudio.tone(1.2))
        // The second sentence passed 1 s while the first was transcribed, so it got no
        // interim text, and the first is not held up by one.
        try await eventually { models.isHolding }
        #expect(models.transcribed == 1)
        models.letGo()
        try await eventually { reports.count == 2 }
        try await feedLive(pipeline, CaptionAudio.silence(1))
        await pipeline.finish()
        #expect(reports.filter { !$0.isInterim }.map(\.original) == ["Hello everyone.", "Hello everyone.", "Next slide please.", "Next slide please."])
    }

    @Test func anInterimLineShowsTheOriginalSmallInEitherMode() {
        let sentence = CaptionSentence(id: 1, start: 0, end: 1, original: "Hello", translation: .none, isInterim: true)
        for mode in CaptionDisplayMode.allCases {
            #expect(mode.lines(for: sentence) == [.init(text: "Hello", style: .secondary)])
        }
    }

    @Test func theStoreRemovesALine() {
        let store = CaptionStore()
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello", translation: .none, isInterim: true))
        store.apply(CaptionSentence(id: 2, start: 1, end: 2, original: "Hi", translation: .none))
        store.remove(id: 1)
        #expect(store.sentences.map(\.id) == [2])
    }
}
