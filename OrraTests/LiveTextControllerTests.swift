import Foundation
import Testing
@testable import Orra

/// Show text while you speak in the controller: the text shows during the hold, the paste
/// stays the pass over the whole recording, and with the switch off nothing of it runs.
@MainActor
struct LiveTextControllerTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let recording = ScriptedRecording()
    let passes = LivePasses()

    /// What the controller told the indicator, nil for a hide.
    final class Shown {
        var texts: [LiveText?] = []
        var last: LiveText? {
            texts.last ?? nil
        }
    }

    /// A controller whose microphone also gives the recording in progress, and whose
    /// speech model has a stand in for the passes of the text.
    private func makeController(
        showsLiveText: Bool = true,
        allowed: @escaping () -> Bool = { true },
        transcribe: ((_ samples: [Float], _ context: String?, _ language: SpeechLanguage?) async throws -> String)? = nil
    ) async -> (PushToTalkController, Shown) {
        var capture = mic.capture
        capture.recorded = { [recording] count, number in recording.recorded(after: count, of: number) }
        var transcription = speech.transcription
        if let transcribe {
            transcription.transcribe = transcribe
        }
        transcription.stoppable = { [passes] samples in try await passes.pass(samples) }
        let controller = PushToTalkController(
            capture: capture,
            transcription: transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            showsLiveText: showsLiveText,
            liveTextAllowed: allowed
        )
        let shown = Shown()
        controller.onLiveText = { shown.texts.append($0) }
        await controller.loadModel()
        return (controller, shown)
    }

    private func press(_ controller: PushToTalkController) async throws {
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
    }

    private func release(_ controller: PushToTalkController) async throws {
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
    }

    /// With the switch off a dictation runs exactly as before: nothing reads the recording
    /// during the hold, the speech model runs once after the release, and the indicator is
    /// told nothing.
    @Test func withTheSwitchOffNothingRunsDuringTheHold() async throws {
        let (controller, shown) = await makeController(showsLiveText: false)
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        try await press(controller)
        try await Task.sleep(for: .milliseconds(300))
        #expect(recording.reads == 0)
        #expect(passes.sampleCounts.isEmpty)
        #expect(speech.receivedSampleCounts.isEmpty)
        try await release(controller)
        #expect(inserter.inserted == ["你好"])
        #expect(speech.receivedSampleCounts == [16_000])
        #expect(speech.receivedContexts == [nil])
        #expect(recording.reads == 0)
        #expect(passes.sampleCounts.isEmpty)
        #expect(shown.texts.isEmpty)
    }

    @Test func theTextShowsWhileSpeakingAndThePasteIsThePassOverTheWholeRecording() async throws {
        speech.reply = "整段录音的文字"
        passes.reply = "片段"
        let (controller, shown) = await makeController()
        recording.samples = CaptionAudio.tone(1.5)
        try await press(controller)
        try await waitUntil { shown.last?.interim == "片段" }
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { shown.last?.finished == "片段" }
        try await release(controller)
        // The text shown is never pasted, nor kept for Copy Last Dictation.
        #expect(inserter.inserted == ["整段录音的文字"])
        #expect(controller.lastTranscript == "整段录音的文字")
        #expect(controller.originalText == nil)
        // One pass over the whole recording after the release, as without the text.
        #expect(speech.receivedSampleCounts == [16_000])
        // The end of the dictation takes the text away.
        #expect(shown.texts.last == .some(nil))
    }

    /// The pass after the release starts only once the pass of the hold under way has
    /// stopped, which the release makes it do at once.
    @Test func theReleaseStopsThePassUnderWayAndTheTranscriptionFollowsIt() async throws {
        var runningAtTheFinalPass: [Int] = []
        var cancelledAtTheFinalPass: [Int] = []
        let (controller, _) = await makeController(transcribe: { [passes] _, _, _ in
            runningAtTheFinalPass.append(passes.running)
            cancelledAtTheFinalPass.append(passes.cancelled)
            return "整段"
        })
        // An hour, so only the release ends the pass, however long the test process stalls.
        // The wait for idle in release(_:) gives up long before, unless the release stops it.
        passes.delay = .seconds(3_600)
        var timings: [DictationTimings] = []
        controller.onTimings = { timings.append($0) }
        recording.samples = CaptionAudio.tone(1.5)
        try await press(controller)
        try await waitUntil { passes.running == 1 }
        try await release(controller)
        #expect(passes.cancelled == 1)
        // The pass had stopped at the cancel when the transcription started.
        #expect(runningAtTheFinalPass == [0])
        #expect(cancelledAtTheFinalPass == [1])
        #expect(inserter.inserted == ["整段"])
        let timing = try #require(timings.first)
        // The wait for the pass to stop did not last as long as the pass would have run.
        let stop = try #require(timing.durations[.liveTextStop])
        #expect(stop < passes.delay)
    }

    @Test func aCancelTakesTheTextAwayAndPastesNothing() async throws {
        passes.reply = "片段"
        let (controller, shown) = await makeController()
        recording.samples = CaptionAudio.tone(1.5)
        try await press(controller)
        try await waitUntil { shown.last?.interim == "片段" }
        // The sentence ends, and the pass of its piece runs until the cancel. An hour, so no
        // stall of the test process outlasts it. A piece gets its pass whatever the earlier
        // passes took, unlike a second interim pass, which needs new speech of twice the
        // time the first one took.
        passes.delay = .seconds(3_600)
        recording.samples += CaptionAudio.silence(1)
        try await waitUntil { passes.running == 1 }
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        #expect(shown.texts.last == .some(nil))
        try await waitUntil { passes.cancelled == 1 }
        #expect(inserter.inserted.isEmpty)
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    /// When the text may not show at the press, such as in Low Power Mode, nothing of it
    /// runs and the dictation is as without it.
    @Test func whenTheTextMayNotShowNothingOfItRuns() async throws {
        let (controller, shown) = await makeController(allowed: { false })
        recording.samples = CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        try await press(controller)
        try await Task.sleep(for: .milliseconds(300))
        try await release(controller)
        #expect(recording.reads == 0)
        #expect(passes.sampleCounts.isEmpty)
        #expect(shown.texts.isEmpty)
        #expect(inserter.inserted == ["你好"])
    }

    /// A press that may still be a shortcut starts nothing of the text, and a dropped one
    /// leaves nothing behind. Once the press counts, the text reads from the start.
    @Test func aPressThatMayBeAShortcutStartsNothing() async throws {
        let (controller, shown) = await makeController()
        recording.samples = CaptionAudio.tone(1.5)
        controller.handle(.armed)
        try await waitUntil { mic.calls.contains("start") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recording.reads == 0)
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recording.reads == 0)
        #expect(passes.sampleCounts.isEmpty)
        #expect(shown.texts.isEmpty)
        controller.handle(.armed)
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .listening)
        try await waitUntil { shown.last?.interim == "你好" }
        controller.handle(.cancelled)
    }

    /// For measurements only: the paste joins the pieces the hold transcribed with the rest
    /// of the recording after them.
    @Test func joinedPiecesPasteTheirTextsWithTheRest() async throws {
        let (controller, _) = await makeController()
        controller.joinsLivePieces = true
        speech.queued = [.success("第一句。"), .success("第二句。")]
        // The second sentence has not ended at the release.
        recording.samples = CaptionAudio.tone(1) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(0.3)
        mic.recording = AudioRecording(samples: recording.samples, sampleRate: 16_000)
        try await press(controller)
        try await waitUntil { speech.receivedSampleCounts.count == 1 }
        try await release(controller)
        #expect(inserter.inserted == ["第一句。第二句。"])
        let counts = speech.receivedSampleCounts
        try #require(counts.count == 2)
        #expect(counts[0] + counts[1] == recording.samples.count)
    }

    /// Joined pieces need the context the release gives. A vocabulary that changed during
    /// the hold makes the paste the pass over the whole recording.
    @Test func joinedPiecesWithAnotherContextGiveWayToTheWholeRecording() async throws {
        let (controller, _) = await makeController()
        controller.joinsLivePieces = true
        speech.queued = [.success("第一句。"), .success("整段。")]
        recording.samples = CaptionAudio.tone(1) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(0.3)
        mic.recording = AudioRecording(samples: recording.samples, sampleRate: 16_000)
        try await press(controller)
        try await waitUntil { speech.receivedSampleCounts.count == 1 }
        controller.addToVocabulary("Orra")
        try await release(controller)
        #expect(inserter.inserted == ["整段。"])
        #expect(speech.receivedSampleCounts.last == recording.samples.count)
    }

    @Test func theSwitchIsSavedAndOffUntilTurnedOn() throws {
        let suite = try TestDefaults("live-text")
        defer { suite.remove() }
        #expect(LiveTextPreference.load(from: suite.defaults) == false)
        var saved: [Bool] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            showsLiveText: LiveTextPreference.load(from: suite.defaults),
            saveShowsLiveText: {
                saved.append($0)
                LiveTextPreference.save($0, to: suite.defaults)
            }
        )
        #expect(controller.showsLiveText == false)
        controller.setShowsLiveText(true)
        controller.setShowsLiveText(true)
        #expect(saved == [true])
        #expect(LiveTextPreference.load(from: suite.defaults))
    }
}
