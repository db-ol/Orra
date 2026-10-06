import Foundation
import Testing
@testable import Orra

/// A stand in for the microphone. It records what the controller asked for and never
/// touches real audio or the permission prompt.
@MainActor
final class FakeMicrophone {
    var access: MicrophoneAccess = .authorized
    var accessAfterRequest: MicrophoneAccess = .authorized
    var recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000), sampleRate: 16_000)
    var startError: (any Error)?
    /// When true, only the next start fails.
    var failOnlyNextStart = false
    var startDelay: Duration = .zero
    private(set) var calls: [String] = []
    /// The microphone UID each start asked for, nil for the system default.
    private(set) var preferredInputs: [String?] = []

    /// A quiet tone, so a recording is never mistaken for a microphone without sound.
    static func tone(count: Int) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.1 }
    }

    var capture: AudioCapture {
        AudioCapture(
            access: { self.access },
            requestAccess: {
                self.calls.append("request")
                self.access = self.accessAfterRequest
                return self.access
            },
            start: { preferredInput in
                self.preferredInputs.append(preferredInput)
                if self.startDelay > .zero {
                    try? await Task.sleep(for: self.startDelay)
                }
                if let error = self.startError {
                    if self.failOnlyNextStart {
                        self.startError = nil
                    }
                    self.calls.append("start failed")
                    throw error
                }
                self.calls.append("start")
            },
            stop: {
                self.calls.append("stop")
                return self.recording
            },
            cancel: { self.calls.append("cancel") }
        )
    }
}

/// A stand in for the speech model.
@MainActor
final class FakeSpeech {
    var loadError: (any Error)?
    var reply = "你好"
    var transcribeError: (any Error)?
    var delay: Duration = .zero
    private(set) var loads = 0
    private(set) var receivedSampleCounts: [Int] = []

    var transcription: Transcription {
        Transcription(
            load: {
                self.loads += 1
                if let error = self.loadError { throw error }
            },
            transcribe: { samples in
                self.receivedSampleCounts.append(samples.count)
                if self.delay > .zero {
                    try await Task.sleep(for: self.delay)
                }
                if let error = self.transcribeError { throw error }
                return self.reply
            }
        )
    }
}

/// A stand in for pasting into the frontmost app.
@MainActor
final class FakeInserter {
    var result: InsertionResult = .pasted
    private(set) var inserted: [String] = []

    func insert(_ text: String) async -> InsertionResult {
        inserted.append(text)
        return result
    }
}

/// A stand in for the frontmost app.
@MainActor
final class FakeWorkspace {
    var frontmost: pid_t? = 100
}

struct TestError: Error {}

@MainActor
struct PushToTalkControllerTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let workspace = FakeWorkspace()

    private func makeController(
        limit: Duration = RecordingLimits.maximumDuration,
        minimumHold: Duration = .zero,
        loadModel: Bool = true
    ) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            maximumRecordingDuration: limit,
            minimumHold: minimumHold,
            releaseTail: .zero
        )
        if loadModel {
            await controller.loadModel()
        }
        return controller
    }

    /// Waits until `condition` holds, for at most a second.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dictate(_ controller: PushToTalkController) async throws {
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
    }

    @Test func startsIdleWithoutTheHotkey() async {
        let controller = await makeController(loadModel: false)
        #expect(controller.state == .idle)
        #expect(controller.isHotkeyActive == false)
        #expect(controller.modelState == .notLoaded)
    }

    @Test func talkKeysDefaultToRightControl() async {
        let controller = await makeController(loadModel: false)
        #expect(controller.talkKeys == [.rightControl])
    }

    @Test func talkKeysChangeAndAreSaved() {
        var saved: [Set<TalkKey>] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKeys: [.rightControl],
            saveTalkKeys: { saved.append($0) }
        )
        controller.setTalkKey(.fn, on: true)
        #expect(controller.talkKeys == [.rightControl, .fn])
        controller.setTalkKey(.rightControl, on: false)
        #expect(controller.talkKeys == [.fn])
        #expect(saved == [[.rightControl, .fn], [.fn]])
    }

    @Test func theLastTalkKeyStaysOn() {
        var saves = 0
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKeys: [.fn],
            saveTalkKeys: { _ in saves += 1 }
        )
        controller.setTalkKey(.fn, on: false)
        #expect(controller.talkKeys == [.fn])
        // Turning on a key that is already on changes nothing either.
        controller.setTalkKey(.fn, on: true)
        #expect(saves == 0)
    }

    @Test func anEmptySavedChoiceFallsBackToTheDefault() {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKeys: []
        )
        #expect(controller.talkKeys == TalkKey.defaultKeys)
    }

    @Test func theChosenMicrophoneIsSavedAndUsedForTheNextRecording() async throws {
        var saved: [MicrophoneChoice?] = []
        let brio = MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            saveMicrophone: { saved.append($0) }
        )
        await controller.loadModel()
        #expect(controller.microphone == nil)
        controller.setMicrophone(brio)
        // Choosing the same one again changes nothing.
        controller.setMicrophone(brio)
        #expect(saved == [brio])
        try await dictate(controller)
        controller.setMicrophone(nil)
        try await dictate(controller)
        #expect(mic.preferredInputs == ["brio-uid", nil])
        #expect(saved == [brio, nil])
    }

    @Test func silenceIsExplainedForTheMicrophoneThatRecorded() async throws {
        let webcam = AudioInput(id: 2, uid: "brio-uid", name: "Brio 500", isInternalMicrophone: false)
        mic.recording = AudioRecording(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, input: webcam)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            lidIsClosed: { true },
            minimumHold: .zero,
            releaseTail: .zero,
            microphone: MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        )
        await controller.loadModel()
        try await dictate(controller)
        // The lid is closed, but the webcam recorded, so the lid is not the reason.
        #expect(controller.problem == "No sound came from Brio 500")
        // The chosen microphone records whatever Sound settings says, so the way out is
        // Orra's own choice.
        #expect(controller.microphoneNotice == "Brio 500 is chosen under Microphone. Choose another microphone or System Default there.")
        #expect(controller.suggestsSoundSettings == false)
        #expect(controller.notice == nil)

        // The same for the internal microphone chosen in Orra with the lid closed.
        let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        mic.recording.input = builtIn
        controller.setMicrophone(MicrophoneChoice(uid: builtIn.uid, name: builtIn.name))
        try await dictate(controller)
        #expect(controller.problem == "The lid is closed, so the built in microphone is off")
        #expect(controller.microphoneNotice == "MacBook Pro Microphone is chosen under Microphone. Choose another microphone or System Default there.")
        #expect(controller.suggestsSoundSettings == false)
    }

    @Test func silenceFromTheDefaultInsteadOfAMissingChoiceOffersSoundSettings() async throws {
        let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        mic.recording = AudioRecording(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, input: builtIn)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            lidIsClosed: { true },
            minimumHold: .zero,
            releaseTail: .zero,
            microphone: MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        )
        await controller.loadModel()
        try await dictate(controller)
        #expect(controller.problem == "The lid is closed, so the built in microphone is off")
        #expect(controller.microphoneNotice == "Brio 500 is not connected, so MacBook Pro Microphone recorded.")
        // Sound settings picks the default, which is what recorded.
        #expect(controller.suggestsSoundSettings)
    }

    @Test func aMissingChosenMicrophoneIsNamedWhenTheDefaultRecords() async throws {
        let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        mic.recording.input = builtIn
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            lidIsClosed: { false },
            minimumHold: .zero,
            releaseTail: .zero,
            microphone: MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        )
        await controller.loadModel()
        try await dictate(controller)
        #expect(controller.microphoneNotice == "Brio 500 is not connected, so MacBook Pro Microphone recorded.")
        #expect(inserter.inserted == ["你好"])
        // A paste notice does not hide it.
        inserter.result = .leftOnPasteboardForSecureInput
        try await dictate(controller)
        #expect(controller.microphoneNotice == "Brio 500 is not connected, so MacBook Pro Microphone recorded.")
        #expect(controller.notice == "Secure input is on, so the text was not pasted. It is on the clipboard.")
        // The chosen microphone recorded, so there is nothing to say.
        inserter.result = .pasted
        mic.recording.input = AudioInput(id: 2, uid: "brio-uid", name: "Brio 500", isInternalMicrophone: false)
        try await dictate(controller)
        #expect(controller.microphoneNotice == nil)
        #expect(controller.notice == nil)
    }

    @Test func aChosenMicrophoneThatCannotStartIsNamed() async throws {
        mic.startError = AudioRecorderError.inputUnitFailed(step: "start the input unit", status: -10_875)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            microphone: MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        )
        await controller.loadModel()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle }
        #expect(controller.problem == "Brio 500 could not start")
        // System Default alone could land on the internal microphone behind a closed lid,
        // so the device is picked in Sound settings too.
        #expect(controller.microphoneNotice == "Choose System Default under Microphone, then pick Brio 500 in Sound settings.")
        #expect(controller.suggestsSoundSettings)
        // Without a chosen microphone, the default failed, which the menu says plainly.
        controller.setMicrophone(nil)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle }
        #expect(controller.problem == "The microphone could not start")
        #expect(controller.microphoneNotice == nil)
        #expect(controller.suggestsSoundSettings == false)
    }

    @Test func modelLoadsOnce() async {
        let controller = await makeController()
        await controller.loadModel()
        #expect(controller.modelState == .ready)
        #expect(speech.loads == 1)
    }

    @Test func missingModelFilesMakeTheModelUnavailable() async {
        speech.loadError = TranscriptionError.modelMissing
        let controller = await makeController()
        #expect(controller.modelState == .unavailable("The speech model is not on this Mac"))
    }

    @Test func holdBeforeTheModelIsReadyRecordsNothing() async throws {
        let controller = await makeController(loadModel: false)
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state == .idle)
        #expect(mic.calls.isEmpty)
    }

    @Test func holdRecordsAndReleaseTranscribesAndPastes() async throws {
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .listening)
        try await waitUntil { mic.calls == ["start"] }
        #expect(mic.calls == ["start"])
        controller.handle(.released)
        #expect(controller.state == .processing)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(speech.receivedSampleCounts == [16_000])
        #expect(inserter.inserted == ["你好"])
        #expect(controller.lastTranscript == "你好")
        #expect(controller.problem == nil)
    }

    @Test func releaseBeforeTheMicrophoneHasStartedStillStopsItAfterwards() async throws {
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    @Test func cancelBeforeTheMicrophoneHasStartedStillCancelsIt() async throws {
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls.count == 2 }
        #expect(mic.calls == ["start", "cancel"])
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func quickHoldAfterACancelledOneStillRecords() async throws {
        // fn+Delete, then fn held again before a slow microphone has started. The first
        // hold's cancel must land before the second start, or it would stop the second
        // recording.
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.count == 3 }
        #expect(mic.calls == ["start", "cancel", "start"])
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "cancel", "start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    @Test func lateStartFailureOfACancelledHoldLeavesTheNextHoldAlone() async throws {
        mic.startError = TestError()
        mic.failOnlyNextStart = true
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.count == 2 }
        #expect(mic.calls == ["start failed", "start"])
        #expect(controller.state == .listening)
        #expect(controller.problem == nil)
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(inserter.inserted == ["你好"])
    }

    @Test func holdWithoutMicrophoneAccessDoesNotTouchAnEarlierRecording() async throws {
        let controller = await makeController()
        try await dictate(controller)
        mic.access = .denied
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(mic.calls == ["start", "stop"])
    }

    @Test func dictationKeepsTheAppAwakeUntilTheTextIsPasted() async throws {
        speech.delay = .milliseconds(100)
        // Records the flag at the moment of the paste.
        final class PasteProbe {
            weak var controller: PushToTalkController?
            var awakeAtPaste: Bool?
        }
        let probe = PasteProbe()
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: { _ in
                probe.awakeAtPaste = probe.controller?.isKeepingDictationAwake
                return .pasted
            },
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero
        )
        probe.controller = controller
        await controller.loadModel()
        #expect(controller.isKeepingDictationAwake == false)
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.isKeepingDictationAwake)
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        // FakeSpeech counts the samples before its delay, so this is during transcription.
        try await waitUntil { !speech.receivedSampleCounts.isEmpty }
        #expect(controller.isKeepingDictationAwake)
        try await waitUntil { controller.state == .idle }
        #expect(probe.awakeAtPaste == true)
        #expect(controller.isKeepingDictationAwake == false)
    }

    @Test func cancelledOrRefusedHoldsDoNotKeepTheAppAwake() async throws {
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        #expect(controller.isKeepingDictationAwake == false)
        mic.access = .denied
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.isKeepingDictationAwake == false)
    }

    @Test func recordingIsResampledTo16kHzForTheModel() async throws {
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 48_000), sampleRate: 48_000)
        let controller = await makeController()
        try await dictate(controller)
        let count = try #require(speech.receivedSampleCounts.first)
        #expect(abs(count - 16_000) <= 2)
    }

    @Test func holdShorterThanTheMinimumIsNotTranscribed() async throws {
        let controller = await makeController(minimumHold: .milliseconds(300))
        try await dictate(controller)
        #expect(controller.state == .idle)
        // The microphone is still stopped, but nothing is transcribed.
        #expect(mic.calls == ["start", "stop"])
        #expect(speech.receivedSampleCounts.isEmpty)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func holdLongerThanTheMinimumIsTranscribed() async throws {
        let controller = await makeController(minimumHold: .milliseconds(50))
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(100))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(inserter.inserted == ["你好"])
    }

    @Test func recordingCutByADeviceChangeShowsAProblem() async throws {
        mic.recording.wasCut = true
        let controller = await makeController()
        try await dictate(controller)
        #expect(controller.problem != nil)
        #expect(speech.receivedSampleCounts.isEmpty)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func recordingWithoutSamplesShowsAProblem() async throws {
        mic.recording = AudioRecording(samples: [], sampleRate: 16_000)
        let controller = await makeController()
        try await dictate(controller)
        #expect(controller.problem != nil)
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func aRecordingWithoutAnySoundExplainsWhy() async throws {
        let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        mic.recording = AudioRecording(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, input: builtIn)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { 100 },
            lidIsClosed: { true },
            minimumHold: .zero,
            releaseTail: .zero
        )
        await controller.loadModel()
        try await dictate(controller)
        #expect(controller.problem == "The lid is closed, so the built in microphone is off")
        #expect(controller.suggestsSoundSettings)
        #expect(controller.microphoneNotice == nil)
        // Nothing reaches the model, and nothing is pasted.
        #expect(speech.receivedSampleCounts.isEmpty)
        #expect(inserter.inserted.isEmpty)
        // The next hold starts clean.
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.problem == nil)
        #expect(controller.suggestsSoundSettings == false)
    }

    @Test func emptyTextIsNotPasted() async throws {
        speech.reply = "  "
        let controller = await makeController()
        try await dictate(controller)
        #expect(inserter.inserted.isEmpty)
        #expect(controller.problem == nil)
    }

    @Test func aDecodingLoopIsCutBeforePasting() async throws {
        speech.reply = "三，" + String(repeating: "非常", count: 300)
        let controller = await makeController()
        try await dictate(controller)
        #expect(inserter.inserted == ["三，非常非常"])
    }

    @Test func traditionalCharactersArePastedAsSimplified() async throws {
        speech.reply = "這個 PR 先 merge 一下"
        let controller = await makeController()
        try await dictate(controller)
        #expect(inserter.inserted == ["这个 PR 先 merge 一下"])
    }

    @Test func switchingAppsBeforeThePasteKeepsTheTextForCopying() async throws {
        speech.delay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        workspace.frontmost = 200
        try await waitUntil { controller.state == .idle }
        #expect(inserter.inserted.isEmpty)
        #expect(controller.notice != nil)
        #expect(controller.lastTranscript == "你好")
    }

    @Test func failedTranscriptionShowsAProblemUntilTheNextHold() async throws {
        speech.transcribeError = TestError()
        let controller = await makeController()
        try await dictate(controller)
        #expect(controller.state == .idle)
        #expect(controller.problem != nil)
        #expect(inserter.inserted.isEmpty)
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.problem == nil)
    }

    @Test func secureInputLeavesANotice() async throws {
        inserter.result = .leftOnPasteboardForSecureInput
        let controller = await makeController()
        try await dictate(controller)
        #expect(controller.notice != nil)
        #expect(controller.problem == nil)
    }

    @Test func pressDuringProcessingIsIgnored() async throws {
        speech.delay = .milliseconds(200)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.released)
        #expect(controller.state == .processing)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    @Test func cancelDiscardsTheRecording() async throws {
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls.count == 2 }
        #expect(mic.calls == ["start", "cancel"])
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func firstHoldAsksForTheMicrophoneAndRecordsNothing() async throws {
        mic.access = .notDetermined
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls.contains("request") }
        #expect(mic.calls.contains("start") == false)
        #expect(controller.microphoneAccess == .authorized)
    }

    @Test func holdWithMicrophoneAccessOffRecordsNothing() async throws {
        mic.access = .denied
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state == .idle)
        #expect(mic.calls.isEmpty)
        #expect(controller.microphoneAccess == .denied)
    }

    @Test func buildWithoutAMicrophoneUsageDescriptionNeverAsks() async throws {
        mic.access = .notConfigured
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.requestMicrophoneAccess()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.state == .idle)
        #expect(mic.calls.isEmpty)
        #expect(controller.microphoneAccess == .notConfigured)
    }

    @Test func holdEndsWhenTheMicrophoneFailsToStart() async throws {
        mic.startError = TestError()
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle }
        #expect(controller.state == .idle)
        #expect(mic.calls == ["start failed"])
        #expect(controller.problem != nil)
    }

    @Test func releaseAfterAFailedStartFinishesWithTheProblem() async throws {
        mic.startError = TestError()
        mic.startDelay = .milliseconds(50)
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start failed"])
        #expect(controller.problem != nil)
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func longHoldIsProcessedAtTheTimeLimit() async throws {
        let controller = await makeController(limit: .milliseconds(50))
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(300))
        #expect(mic.calls == ["start", "stop"])
        #expect(controller.state == .idle)
        #expect(inserter.inserted == ["你好"])
        // The real release that follows later changes nothing.
        controller.handle(.released)
        #expect(mic.calls == ["start", "stop"])
    }

    @Test func releaseBeforeTheTimeLimitCancelsTheLimit() async throws {
        let controller = await makeController(limit: .milliseconds(100))
        let firstPress = ContinuousClock.now
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        // The second hold spans the first hold's deadline. If the first limit were still
        // running, it would end this hold at about 100 ms.
        try await Task.sleep(until: firstPress + .milliseconds(80), clock: .continuous)
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state == .listening)
        controller.handle(.cancelled)
        try await waitUntil { mic.calls.count == 4 }
        #expect(mic.calls == ["start", "stop", "start", "cancel"])
    }

    @Test func hostDetectionSeesTheTestEnvironment() {
        // AppDelegate skips the keyboard tap and the Accessibility prompt when
        // Xcode hosts tests or previews. This checks only that the environment
        // variable the guard relies on is set while tests run. It does not run
        // the guard itself.
        #expect(AppDelegate.isHostedByXcode)
    }
}
