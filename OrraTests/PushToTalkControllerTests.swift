import CoreGraphics
import Foundation
import Synchronization
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
    var level: Float = 0
    /// How long after the cue begins to wait for it the first sound arrives, nil for a
    /// microphone that delivers none.
    var soundDelay: Duration? = .zero
    /// While true the first sound has not arrived, until the test sets it to false or the
    /// cue's limit passes. Unlike `soundDelay`, it does not depend on how fast the Mac runs.
    var soundHeld = false
    /// What the timing log reads about the start.
    var onset = CaptureOnset(path: .unit, transport: 0x7573_6220)
    /// How often the controller read `onset`, once for each hold it logs.
    private(set) var onsetReads = 0
    /// Called when the controller reads `onset`.
    var whenOnsetRead: () -> Void = {}
    private(set) var calls: [String] = []
    /// The microphone UID each start asked for, nil for the system default.
    private(set) var preferredInputs: [String?] = []
    /// The microphone UID of each new choice the controller passed on, nil for the system
    /// default.
    private(set) var chosenInputs: [String?] = []

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
                    // A real start goes on when its task is cancelled, so the delay does too.
                    let delay = self.startDelay
                    await Task { try? await Task.sleep(for: delay) }.value
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
            cancel: { self.calls.append("cancel") },
            level: { self.level },
            waitForSound: { deadline in
                while self.soundHeld, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                guard let delay = self.soundDelay else {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    return
                }
                if delay > .zero {
                    try? await Task.sleep(until: min(.now + delay, deadline), clock: .continuous)
                }
            },
            onset: {
                self.onsetReads += 1
                self.whenOnsetRead()
                return self.onset
            },
            microphoneChosen: { preferredInput in
                self.chosenInputs.append(preferredInput)
            }
        )
    }
}

/// Collects the cues a controller sends to the recording indicator and the sounds.
@MainActor
final class CueRecorder {
    private(set) var list: [DictationCue] = []

    init(_ controller: PushToTalkController) {
        controller.onCue = { [weak self] cue in
            self?.list.append(cue)
        }
    }
}

/// A stand in for the speech model.
@MainActor
final class FakeSpeech {
    var loadError: (any Error)?
    var loadDelay: Duration = .zero
    var reply = "你好"
    /// The reply without a vocabulary, when it differs from `reply`.
    var replyWithoutContext: String?
    var transcribeError: (any Error)?
    /// An error only for a transcription without a vocabulary.
    var transcribeErrorWithoutContext: (any Error)?
    var delay: Duration = .zero
    private(set) var loads = 0
    private(set) var receivedSampleCounts: [Int] = []
    /// The reply when the model is told to write a language.
    var replyInLanguage: [SpeechLanguage: String] = [:]
    /// The context each transcription got.
    private(set) var receivedContexts: [String?] = []
    /// The language each transcription was told to write, nil when none.
    private(set) var receivedLanguages: [SpeechLanguage?] = []

    var transcription: Transcription {
        Transcription(
            load: {
                self.loads += 1
                if self.loadDelay > .zero {
                    try await Task.sleep(for: self.loadDelay)
                }
                if let error = self.loadError { throw error }
            },
            transcribe: { samples, context, language in
                self.receivedContexts.append(context)
                self.receivedLanguages.append(language)
                self.receivedSampleCounts.append(samples.count)
                if self.delay > .zero {
                    try await Task.sleep(for: self.delay)
                }
                if let error = self.transcribeError { throw error }
                if context == nil, let error = self.transcribeErrorWithoutContext { throw error }
                if let language, let hinted = self.replyInLanguage[language] { return hinted }
                if context == nil, let plain = self.replyWithoutContext { return plain }
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
    let tapSystem = FakeTapSystem()

    private func makeController(
        limit: Duration = RecordingLimits.maximumDuration,
        minimumHold: Duration = .zero,
        listeningCueDelay: Duration = .zero,
        soundWaitLimit: Duration = .seconds(1),
        loadModel: Bool = true
    ) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            maximumRecordingDuration: limit,
            minimumHold: minimumHold,
            releaseTail: .zero,
            listeningCueDelay: listeningCueDelay,
            soundWaitLimit: soundWaitLimit
        )
        if loadModel {
            await controller.loadModel()
        }
        return controller
    }

    /// A started controller whose keyboard tap is a fake, so no real tap is installed. The
    /// fake allows the tap, so the hotkey is active.
    private func startedController(translation: TranslationModel = .off) async throws -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            translation: translation,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            isTrusted: tapSystem.isTrusted,
            installTap: tapSystem.install,
            minimumHold: .zero,
            releaseTail: .zero,
            accessCheckDelay: .milliseconds(20)
        )
        controller.start()
        #expect(controller.isHotkeyActive)
        // In the app, ModelInstaller loads the model once its files are in place.
        await controller.loadModel()
        #expect(controller.modelState == .ready)
        return controller
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

    @Test func theTalkKeyDefaultsToRightControl() async {
        let controller = await makeController(loadModel: false)
        #expect(controller.talkKey == .rightControl)
    }

    @Test func theTalkKeyChangesAndIsSaved() {
        var saved: [Hotkey] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .rightControl,
            saveTalkKey: { saved.append($0) }
        )
        controller.chooseTalkKey(.fn)
        #expect(controller.talkKey == .fn)
        controller.chooseTalkKey(.leftOption)
        #expect(controller.talkKey == .leftOption)
        #expect(saved == [.fn, .leftOption])
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

    /// A new choice reaches the microphone at once, so the unit kept for the microphone
    /// chosen before lets go of its device then, not at the next press. The same choice
    /// again does not, and nothing records.
    @Test func aNewMicrophoneChoiceReachesTheMicrophoneAtOnce() async throws {
        let brio = MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        let airPods = MicrophoneChoice(uid: "airpods-uid", name: "AirPods")
        let controller = await makeController()
        controller.setMicrophone(brio)
        try await waitUntil { mic.chosenInputs.count == 1 }
        #expect(mic.chosenInputs == ["brio-uid"])
        controller.setMicrophone(brio)
        controller.setMicrophone(airPods)
        controller.setMicrophone(nil)
        try await waitUntil { mic.chosenInputs.count == 3 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(mic.chosenInputs == ["brio-uid", "airpods-uid", nil])
        #expect(mic.calls.isEmpty)
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
        inserter.result = .skippedPasswordField
        try await dictate(controller)
        #expect(controller.microphoneNotice == "Brio 500 is not connected, so MacBook Pro Microphone recorded.")
        #expect(controller.notice == "Orra does not paste into password fields. Use Copy Last Dictation.")
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

    @Test func aFailedLoadCanBeTriedAgain() async {
        speech.loadError = TranscriptionError.modelMissing
        let controller = await makeController()
        #expect(controller.modelState == .unavailable(.missing))
        // The user puts the model files in place and chooses Try Again.
        speech.loadError = nil
        await controller.loadModel()
        #expect(controller.modelState == .ready)
        #expect(speech.loads == 2)
        // Once it is loaded, it stays loaded.
        await controller.loadModel()
        #expect(speech.loads == 2)
    }

    /// Only ModelInstaller loads the model, once its files are in place. A load at start
    /// would fail before the installer is done and report the model as missing.
    @Test func startLeavesTheModelToTheInstaller() async throws {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            isTrusted: tapSystem.isTrusted,
            installTap: tapSystem.install,
            accessCheckDelay: .milliseconds(20)
        )
        controller.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(speech.loads == 0)
        #expect(controller.modelState == .notLoaded)
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
        #expect(controller.modelState == .unavailable(.missing))
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
        try await waitUntil { mic.preferredInputs.count == 1 }
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
        try await waitUntil { mic.preferredInputs.count == 1 }
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
        try await waitUntil { mic.preferredInputs.count == 1 }
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
        // Far longer than any hold in a test, so the hold is short on any machine. With
        // 300 ms, a slow CI runner took longer than that just to start the fake microphone,
        // and with 10 s a stalled runner still went past it.
        let controller = await makeController(minimumHold: .seconds(3600))
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

    @Test func aPasswordFieldLeavesANoticeAndTheTextForCopying() async throws {
        inserter.result = .skippedPasswordField
        let controller = await makeController()
        try await dictate(controller)
        #expect(controller.notice == "Orra does not paste into password fields. Use Copy Last Dictation.")
        #expect(controller.problem == nil)
        #expect(controller.lastTranscript == "你好")
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
        // Waits for the outcome rather than a fixed pause, because the limit's timer runs
        // late when many tests share the main actor.
        try await waitUntil { controller.state == .idle && !inserter.inserted.isEmpty }
        #expect(mic.calls == ["start", "stop"])
        #expect(controller.state == .idle)
        #expect(inserter.inserted == ["你好"])
        #expect(controller.notice == "Orra records up to 1 minute at a time, so the recording stopped there.")
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

    @Test func aTapTheSystemSwitchedOffShowsTheTalkKeyOffUntilANewTapIsInstalled() async throws {
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        // A dictation is in progress when the system switches the tap off.
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: HotkeyTapTests.rightControlDown)
        #expect(controller.state == .listening)
        _ = tap.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        // The hold ends, and the menu shows the talk key as off at once.
        #expect(controller.state == .idle)
        #expect(controller.isHotkeyActive == false)
        #expect(tapSystem.removals == 1)
        // Nothing switched the tap back on, and the controller did not check access right
        // away.
        #expect(tapSystem.installAttempts == 1)
        #expect(tapSystem.trustChecks == 1)
        // After the pause a new tap is installed, because access is still there.
        try await waitUntil { controller.isHotkeyActive }
        #expect(controller.isHotkeyActive)
        #expect(tapSystem.installAttempts == 2)
        #expect(tapSystem.trustChecks == 2)
    }

    @Test func aTapTheSystemSwitchedOffStaysOffWhenTheAccessCheckSaysNo() async throws {
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        // Access is gone, and the access check knows it.
        tapSystem.trusted = false
        tapSystem.allowsTap = false
        _ = tap.handle(type: .tapDisabledByUserInput, keyCode: 0, flags: [])
        #expect(controller.isHotkeyActive == false)
        try await waitUntil { tapSystem.trustChecks == 2 }
        #expect(tapSystem.trustChecks == 2)
        #expect(tapSystem.installAttempts == 1)
        #expect(controller.isHotkeyActive == false)
    }

    @Test func aStaleYesFromTheAccessCheckDoesNotBringTheTapBack() async throws {
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        // Access is gone. The access check still says yes, as AXIsProcessTrusted can from
        // its cache, but the system refuses a new tap.
        tapSystem.allowsTap = false
        _ = tap.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        #expect(controller.isHotkeyActive == false)
        try await waitUntil { tapSystem.installAttempts == 2 }
        #expect(tapSystem.installAttempts == 2)
        #expect(tapSystem.installed == nil)
        #expect(controller.isHotkeyActive == false)
        // Orra does not keep trying.
        try await Task.sleep(for: .milliseconds(100))
        #expect(tapSystem.installAttempts == 2)
    }

    @Test func aDictationSendsEveryCueInOrder() async throws {
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(cues.list == [.listening, .transcribing, .recordingStopped, .finished(message: nil)])
    }

    @Test func theIndicatorWaitsForTheHoldToLast() async throws {
        let controller = await makeController(listeningCueDelay: .seconds(1))
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        // Long enough for a cue sent without the delay to arrive.
        try await Task.sleep(for: .milliseconds(50))
        #expect(cues.list.isEmpty)
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.listening])
    }

    @Test func aShortcutWithTheTalkKeySendsNoCue() async throws {
        let controller = await makeController(listeningCueDelay: .seconds(1))
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        // The second key of the shortcut comes a moment later.
        try await Task.sleep(for: .milliseconds(50))
        controller.handle(.cancelled)
        // A hold that starts later, with the same delay, shows only after the first hold
        // would have.
        let probe = await makeController(listeningCueDelay: .seconds(1))
        let probeCues = CueRecorder(probe)
        probe.handle(.pressed(isRepeat: false))
        try await waitUntil { probeCues.list == [.listening] }
        #expect(probeCues.list == [.listening])
        #expect(cues.list.isEmpty)
    }

    @Test func aHoldBeforeTheModelIsReadyOnlySaysWhy() async throws {
        let controller = await makeController(loadModel: false)
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "The speech model is not ready. The Orra menu shows what is missing.")])
    }

    @Test func aHoldWhileTheModelLoadsSaysSo() async throws {
        speech.loadDelay = .seconds(1)
        let controller = await makeController(loadModel: false)
        let cues = CueRecorder(controller)
        Task { await controller.loadModel() }
        try await waitUntil { controller.modelState == .loading }
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "The speech model is still loading")])
    }

    @Test func aHoldWithAModelThatFailedToLoadGivesTheReason() async throws {
        speech.loadError = TranscriptionError.modelMissing
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "The speech model is not on this Mac")])
    }

    @Test func aHoldWithMicrophoneAccessOffSaysWhy() async throws {
        mic.access = .denied
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "Microphone access is off")])
    }

    @Test func aBuildWithoutAMicrophoneUsageDescriptionSaysSo() async throws {
        mic.access = .notConfigured
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "This build has no microphone usage description")])
    }

    @Test func theFirstHoldLeavesTheExplainingToTheSystemPrompt() async throws {
        mic.access = .notDetermined
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list.isEmpty)
    }

    @Test func aShortHoldClearsTheIndicatorAtTheRelease() async throws {
        // An hour, so a runner that stalls for seconds before the release still makes a
        // short hold. On main, with 10 s, a stall of the busy runner made it a long one.
        let controller = await makeController(minimumHold: .seconds(3600))
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.released)
        // At once, before the microphone has stopped.
        #expect(cues.list == [.listening, .finished(message: nil)])
        try await waitUntil { controller.state == .idle }
        #expect(cues.list == [.listening, .finished(message: nil)])
    }

    @Test func aCancelledHoldClearsTheIndicator() async throws {
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.cancelled)
        #expect(cues.list == [.listening, .finished(message: nil)])
    }

    @Test func aMicrophoneThatCannotStartEndsTheHoldWithTheProblem() async throws {
        mic.startError = TestError()
        mic.startDelay = .milliseconds(50)
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle }
        // No start sound for a microphone that never recorded.
        #expect(cues.list == [.finished(message: "The microphone could not start")])
    }

    @Test func theStartSoundWaitsForTheMicrophone() async throws {
        mic.startDelay = .milliseconds(300)
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(100))
        #expect(cues.list.isEmpty)
        try await waitUntil { mic.calls.contains("start") && !cues.list.isEmpty }
        #expect(cues.list == [.listening])
    }

    /// The start sound comes once the microphone delivers sound, not when it has started,
    /// since a microphone can deliver zeros for a while after its start.
    @Test func theStartSoundWaitsForSoundFromTheMicrophone() async throws {
        mic.soundHeld = true
        // A limit no run reaches, so only the sound can bring the cue.
        let controller = await makeController(soundWaitLimit: .seconds(60))
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        // Longer than the 150 ms delay, so only the missing sound holds the cue back.
        try await Task.sleep(for: .milliseconds(300))
        #expect(cues.list.isEmpty)
        mic.soundHeld = false
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.listening])
    }

    /// A microphone that sends no sound gets the cue after the limit, so nobody waits for
    /// it, and its hold ends with the message about the silence as before.
    @Test func aMicrophoneWithoutSoundGetsTheCueAfterTheLimit() async throws {
        mic.soundDelay = nil
        // A USB microphone, so the message does not depend on this Mac's lid.
        let brio = AudioInput(id: 2, uid: "brio-uid", name: "Brio 500", isInternalMicrophone: false)
        mic.recording = AudioRecording(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, input: brio)
        let controller = await makeController(soundWaitLimit: .milliseconds(300))
        let cues = CueRecorder(controller)
        let pressed = ContinuousClock.now
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.listening])
        // The cue came only after the limit. A slow run makes this longer, never shorter.
        #expect(pressed.duration(to: .now) >= .milliseconds(250))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(cues.list == [.listening, .transcribing, .recordingStopped, .finished(message: "No sound came from Brio 500")])
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func theHandsFreeCueWaitsForSoundToo() async throws {
        mic.soundHeld = true
        let controller = await makeController(soundWaitLimit: .seconds(60))
        let cues = CueRecorder(controller)
        controller.handle(.doublePressed)
        try await waitUntil { mic.calls.contains("start") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(cues.list.isEmpty)
        mic.soundHeld = false
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.handsFree(finishHint: "Press right Control to finish")])
    }

    // MARK: Early capture

    /// A key that waits starts the microphone at its key down without a cue. When the press
    /// counts, that recording becomes the dictation, so the microphone starts once.
    @Test func anEarlyCaptureStartsSilentlyAndBecomesTheDictation() async throws {
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        #expect(controller.state == .arming)
        try await waitUntil { mic.calls == ["start"] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(cues.list.isEmpty)
        #expect(controller.isKeepingDictationAwake == false)
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .listening)
        #expect(controller.isKeepingDictationAwake)
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.listening])
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
        #expect(cues.list == [.listening, .transcribing, .recordingStopped, .finished(message: nil)])
        #expect(mic.onsetReads == 1)
    }

    /// A press that captured early counts the minimum hold from the moment it counted, as
    /// before, so holding a key that waits alone a little longer than its wait is still too
    /// short to transcribe, although the recording started at the key down.
    @Test func anEarlyCaptureCountsTheMinimumHoldFromThePressCounting() async throws {
        let controller = await makeController(minimumHold: .milliseconds(200))
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        try await waitUntil { mic.calls == ["start"] }
        // The wait alone is longer than the minimum hold, and the release comes right
        // after the press counted.
        try await Task.sleep(for: .milliseconds(300))
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(speech.receivedSampleCounts.isEmpty)
        #expect(inserter.inserted.isEmpty)
        #expect(!cues.list.contains(.transcribing))
        // Held for the minimum after it counted, the next press is transcribed.
        controller.handle(.armed)
        try await waitUntil { mic.calls.count == 3 }
        controller.handle(.pressed(isRepeat: false))
        try await Task.sleep(for: .milliseconds(300))
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop", "start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    /// A shortcut drops the early capture without a cue, a sound or a message, and leaves
    /// the message of the hold before alone.
    @Test func aDroppedEarlyCaptureSaysNothing() async throws {
        mic.startError = TestError()
        mic.failOnlyNextStart = true
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle }
        #expect(controller.problem == "The microphone could not start")
        let before = cues.list
        controller.handle(.armed)
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls.contains("cancel") }
        #expect(mic.calls == ["start failed", "start", "cancel"])
        #expect(cues.list == before)
        #expect(controller.problem == "The microphone could not start")
        #expect(mic.onsetReads == 0)
    }

    /// While the model is not ready, the waiting press starts nothing and says nothing. The
    /// press says why once it counts.
    @Test func anEarlyCaptureWaitsSilentlyForTheModel() async throws {
        let controller = await makeController(loadModel: false)
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        #expect(controller.state == .idle)
        #expect(cues.list.isEmpty)
        controller.handle(.pressed(isRepeat: false))
        #expect(cues.list == [.finished(message: "The speech model is not ready. The Orra menu shows what is missing.")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(mic.calls.isEmpty)
    }

    /// A microphone that fails to start during the wait says nothing then. The press tries
    /// again once it counts, and says what went wrong.
    @Test func anEarlyCaptureThatCannotStartSaysNothingUntilThePressCounts() async throws {
        mic.startError = TestError()
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        try await waitUntil { mic.calls == ["start failed"] && controller.state == .idle }
        #expect(controller.state == .idle)
        #expect(controller.problem == nil)
        #expect(cues.list.isEmpty)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { controller.state == .idle && !cues.list.isEmpty }
        #expect(mic.calls == ["start failed", "start failed"])
        #expect(controller.problem == "The microphone could not start")
        #expect(cues.list == [.finished(message: "The microphone could not start")])
    }

    /// Shortcuts typed quickly while a slow microphone still starts for the first one: its
    /// cancel lands before the hold that follows starts, so it does not stop that hold, and
    /// the second shortcut, over before its turn came, never starts the microphone.
    @Test func quickShortcutsThenAHoldKeepTheMicrophoneInOrder() async throws {
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        controller.handle(.armed)
        try await waitUntil { mic.preferredInputs.count == 1 }
        controller.handle(.cancelled)
        controller.handle(.armed)
        controller.handle(.cancelled)
        controller.handle(.armed)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.count == 3 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(mic.calls == ["start", "cancel", "start"])
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "cancel", "start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    /// A press that is over before its start began, such as a shortcut typed at once, never
    /// starts the microphone, so there is nothing to cancel either.
    @Test func aPressOverBeforeItsStartBeganNeverStartsTheMicrophone() async throws {
        mic.startDelay = .milliseconds(50)
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        controller.handle(.cancelled)
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await Task.sleep(for: .milliseconds(150))
        #expect(mic.preferredInputs.isEmpty)
        #expect(mic.calls.isEmpty)
        #expect(mic.onsetReads == 0)
        #expect(cues.list.isEmpty)
        try await dictate(controller)
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    /// A shortcut drops the early capture while the microphone still starts, and the start
    /// fails afterwards: the press never counted, so nothing says so.
    @Test func aStartThatFailsAfterAShortcutDroppedItSaysNothing() async throws {
        mic.startError = TestError()
        mic.startDelay = .milliseconds(100)
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.armed)
        try await waitUntil { mic.preferredInputs.count == 1 }
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls == ["start failed"] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state == .idle)
        #expect(controller.problem == nil)
        #expect(controller.microphoneNotice == nil)
        #expect(controller.suggestsSoundSettings == false)
        #expect(cues.list.isEmpty)
    }

    /// The timing log reads how the microphone started after the paste, so the paste never
    /// waits for the microphone getting ready for the next hold.
    @Test func theTimingLogReadsTheStartAfterThePaste() async throws {
        let controller = await makeController()
        var pastedBeforeTheRead: [Bool] = []
        mic.whenOnsetRead = { [inserter] in pastedBeforeTheRead.append(inserter.inserted == ["你好"]) }
        try await dictate(controller)
        #expect(pastedBeforeTheRead == [true])
    }

    /// The timing log reads how the microphone started once for each hold, when its
    /// recording ends or is cancelled.
    @Test func theTimingLogReadsTheStartOnceAHoldEnds() async throws {
        let controller = await makeController()
        try await dictate(controller)
        #expect(mic.onsetReads == 1)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") && mic.calls.count == 3 }
        controller.handle(.cancelled)
        try await waitUntil { mic.calls.last == "cancel" && mic.onsetReads == 2 }
        #expect(mic.onsetReads == 2)
    }

    @Test func aSkippedPasswordFieldEndsTheDictationWithTheNotice() async throws {
        inserter.result = .skippedPasswordField
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(cues.list == [.listening, .transcribing, .recordingStopped, .finished(message: "Orra does not paste into password fields. Use Copy Last Dictation.")])
    }

    @Test func emptyTextEndsTheDictationSayingNothingWasRecognized() async throws {
        speech.reply = "  "
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(cues.list == [.listening, .transcribing, .recordingStopped, .finished(message: "No speech was recognized")])
        // The menu has no line for it.
        #expect(controller.problem == nil)
        #expect(controller.notice == nil)
    }

    @Test func theVocabularyReachesTheModelAndIsSaved() async throws {
        var saved: [[String]] = []
        let added = Date(timeIntervalSince1970: 1_000)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabularyWords("Orra", added: added),
            saveVocabulary: { saved.append($0.map(\.text)) }
        )
        await controller.loadModel()
        try await dictate(controller)
        #expect(controller.addToVocabulary("通义千问") == .added)
        try await dictate(controller)
        controller.setVocabulary([])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["Orra", "Orra\n通义千问", nil])
        #expect(saved == [["Orra", "通义千问"], []])
    }

    @Test func fillersAreRemovedOnlyWhileTheSettingIsOn() async throws {
        var saved: [Bool] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            saveRemovesFillerWords: { saved.append($0) }
        )
        #expect(controller.removesFillerWords)
        await controller.loadModel()
        speech.reply = "呃，我们明天 um 再说吧。"
        try await dictate(controller)
        controller.setRemovesFillerWords(false)
        try await dictate(controller)
        controller.setRemovesFillerWords(false)
        controller.setRemovesFillerWords(true)
        speech.reply = "嗯嗯"
        try await dictate(controller)
        #expect(inserter.inserted == ["我们明天再说吧。", "呃，我们明天 um 再说吧。", "嗯嗯"])
        #expect(controller.lastTranscript == "嗯嗯")
        #expect(saved == [false, true])
    }

    @Test func numbersAreWrittenAsDigitsOnlyWhileTheSettingIsOn() async throws {
        var saved: [Bool] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            saveWritesNumbersAsDigits: { saved.append($0) }
        )
        #expect(controller.writesNumbersAsDigits)
        await controller.loadModel()
        // The fillers go first, so 呃 between the numbers does not stop them.
        speech.reply = "呃，下午三点我们去看 Lexus RX 三五零。"
        try await dictate(controller)
        controller.setWritesNumbersAsDigits(false)
        try await dictate(controller)
        controller.setWritesNumbersAsDigits(false)
        controller.setWritesNumbersAsDigits(true)
        speech.reply = "我们一起去，三五成群。"
        try await dictate(controller)
        #expect(inserter.inserted == ["下午3点我们去看 Lexus RX 350。", "下午三点我们去看 Lexus RX 三五零。", "我们一起去，三五成群。"])
        #expect(saved == [false, true])
    }

    @Test func withAVocabularyNumbersComeFromASecondPassOnlyWhileTheSettingIsOn() async throws {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabularyWords("Orra", added: Date(timeIntervalSince1970: 1_000))
        )
        await controller.loadModel()
        speech.reply = "Orra 在二零二四年发布。"
        speech.replyWithoutContext = "Aura 在2024年发布。"
        try await dictate(controller)
        controller.setWritesNumbersAsDigits(false)
        try await dictate(controller)
        #expect(inserter.inserted == ["Orra 在2024年发布。", "Orra 在二零二四年发布。"])
        #expect(speech.receivedContexts == ["Orra", nil, "Orra"])
    }

    @Test func aPasteDatesTheVocabularyWordsItHolds() async throws {
        let added = Date(timeIntervalSince1970: 1_000)
        let pasteTime = Date(timeIntervalSince1970: 5_000)
        var saved: [[VocabularyWord]] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabularyWords("Orra", "通义千问", "Qwen", added: added),
            saveVocabulary: { saved.append($0) },
            now: { pasteTime }
        )
        await controller.loadModel()
        speech.reply = "我在用 orra 和通义千问。"
        try await dictate(controller)
        #expect(controller.vocabulary.map(\.lastUsed) == [pasteTime, pasteTime, nil])
        #expect(saved.last == controller.vocabulary)
        // A text that was not pasted dates nothing.
        let before = controller.vocabulary
        inserter.result = .skippedPasswordField
        speech.reply = "Qwen"
        try await dictate(controller)
        #expect(controller.vocabulary == before)
    }

    @Test func theModelGetsTheMostRecentWordsOfALongVocabulary() async throws {
        let words = (0..<300).map { VocabularyWord("term\($0)", added: Date(timeIntervalSince1970: Double($0))) }
        let controller = await controller(vocabulary: words)
        try await dictate(controller)
        let context = try #require(speech.receivedContexts.first ?? nil)
        #expect(context.split(separator: "\n").map(String.init) == (100..<300).map { "term\($0)" })
    }

    @Test func learningIsNeverRefusedBelowTheSanityCap() {
        let controller = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert)
        controller.setVocabulary((0..<1_000).map { VocabularyWord("term\($0)", added: .distantPast) })
        #expect(controller.addToVocabulary("Orra") == .added)
        #expect(controller.addToVocabulary("orra") == .alreadyThere)
        #expect(controller.vocabulary.count == 1_001)
        controller.setVocabulary((0..<(Vocabulary.maximumCount - 1)).map { VocabularyWord("term\($0)", added: .distantPast) })
        #expect(controller.addToVocabulary("Orra") == .added)
        #expect(controller.addToVocabulary("Qwen") == .full)
        #expect(controller.vocabulary.count == Vocabulary.maximumCount)
    }

    private func controller(vocabulary: [String]) async -> PushToTalkController {
        await controller(vocabulary: vocabularyWords(vocabulary))
    }

    private func controller(vocabulary: [VocabularyWord]) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabulary
        )
        await controller.loadModel()
        return controller
    }

    @Test func vocabularyTermsHeardOnlyWithTheVocabularyAreNotPasted() async throws {
        speech.reply = "极速借呗。鼎盛物流。I R S transcripts。"
        speech.replyWithoutContext = ""
        let controller = await controller(vocabulary: ["鼎盛物流", "极速借呗", "IRS transcripts", "Orra"])
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] && mic.calls.contains("start") }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(speech.receivedContexts == ["鼎盛物流\n极速借呗\nIRS transcripts\nOrra", nil])
        #expect(inserter.inserted.isEmpty)
        #expect(controller.lastTranscript == nil)
        #expect(cues.list.last == .finished(message: "No speech was recognized"))
        #expect(controller.problem == nil)
    }

    @Test func aSpokenVocabularyTermIsKeptAsWrittenWithTheVocabulary() async throws {
        speech.reply = "Orra。"
        speech.replyWithoutContext = "Aura."
        let controller = await controller(vocabulary: ["通义千问", "Orra"])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["通义千问\nOrra", nil])
        #expect(inserter.inserted == ["Orra。"])
    }

    @Test func onlyPunctuationWithoutTheVocabularyIsNoSpeech() async throws {
        speech.reply = "Orra。"
        speech.replyWithoutContext = "。"
        let controller = await controller(vocabulary: ["Orra"])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["Orra", nil])
        #expect(inserter.inserted.isEmpty)
        #expect(controller.problem == nil)
    }

    @Test func aFailedPassWithoutTheVocabularyKeepsTheText() async throws {
        speech.reply = "Orra。"
        speech.transcribeErrorWithoutContext = TestError()
        let controller = await controller(vocabulary: ["Orra"])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["Orra", nil])
        #expect(inserter.inserted == ["Orra。"])
        #expect(controller.problem == nil)
    }

    @Test func aTranscriptInAThirdLanguageIsTranscribedAgainInChineseWithTheVocabulary() async throws {
        speech.reply = "Pan om ol är en typ av enkelt och lätt måltid som är populär i sommar."
        speech.replyInLanguage = [.chinese: "Pa amb Oli 是一种在夏天流行的简单晚餐。"]
        let controller = await controller(vocabulary: ["Pa amb Oli"])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["Pa amb Oli", "Pa amb Oli"])
        #expect(speech.receivedLanguages == [nil, .chinese])
        #expect(inserter.inserted == ["Pa amb Oli 是一种在夏天流行的简单晚餐。"])
    }

    @Test func speechWithMoreThanTermsIsTranscribedOnce() async throws {
        speech.reply = "我们用 Orra 写字"
        speech.replyWithoutContext = ""
        let controller = await controller(vocabulary: ["Orra"])
        try await dictate(controller)
        #expect(speech.receivedContexts == ["Orra"])
        #expect(inserter.inserted == ["我们用 Orra 写字"])
    }

    @Test func thePasteIsReported() async throws {
        let controller = await makeController()
        var reported: [(String, pid_t)] = []
        controller.onPasted = { text, app, beforeCleanup, replacements in
            reported.append((text, app))
            #expect(beforeCleanup == nil)
            #expect(replacements.isEmpty)
        }
        try await dictate(controller)
        #expect(inserter.inserted == ["你好"])
        #expect(reported.map(\.0) == ["你好"])
        #expect(reported.map(\.1) == [100])
        inserter.result = .skippedPasswordField
        try await dictate(controller)
        #expect(reported.count == 1)
    }

    private func controller(cleanup: CleanupModel) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        await controller.loadModel()
        return controller
    }

    /// The cleanup model runs after the rule steps, on their result. What it changed is
    /// pasted, reported for learning and kept for Copy Last Dictation, and the text before it
    /// stays for Paste Original Text.
    @Test func theCleanupRunsAfterTheRules() async throws {
        let received = Mutex<[String]>([])
        let controller = await controller(cleanup: CleanupModel(waitUntilLoaded: { true }, complete: { text in
            received.withLock { $0.append(text) }
            return #"{"cleaned": "我们下午3点开会。"}"#
        }))
        var reported: [String] = []
        var beforeCleanup: [String?] = []
        var stopped: [String] = []
        controller.onPasted = { text, _, before, _ in
            reported.append(text)
            beforeCleanup.append(before)
        }
        controller.onPasteOriginal = { stopped.append($0) }
        speech.reply = "呃，我们下午两点，哦不对，下午三点开会。"
        try await dictate(controller)
        #expect(received.withLock { $0 } == ["我们下午2点，哦不对，下午3点开会。"])
        #expect(inserter.inserted == ["我们下午3点开会。"])
        #expect(reported == ["我们下午3点开会。"])
        #expect(beforeCleanup == ["我们下午2点，哦不对，下午3点开会。"])
        #expect(stopped.isEmpty)
        #expect(controller.lastTranscript == "我们下午3点开会。")
        #expect(controller.originalText == "我们下午2点，哦不对，下午3点开会。")
        await controller.pasteOriginal()
        #expect(inserter.inserted == ["我们下午3点开会。", "我们下午2点，哦不对，下午3点开会。"])
        // Orra does not learn from the menu's paste, and stops following the cleaned one.
        #expect(reported == ["我们下午3点开会。"])
        #expect(stopped == ["我们下午3点开会。"])
    }

    @Test func aHeldBackCleanupPastesTheRuledText() async throws {
        let controller = await controller(cleanup: CleanupModel(waitUntilLoaded: { true }, complete: { _ in
            #"{"cleaned": "好的，以下是一封请假邮件：老板您好，我明天想请假一天。"}"#
        }))
        speech.reply = "呃，帮我写一封邮件给老板，说我明天请假。"
        try await dictate(controller)
        #expect(inserter.inserted == ["帮我写一封邮件给老板，说我明天请假。"])
        #expect(controller.originalText == nil)
        #expect(controller.problem == nil)
    }

    /// The kept pairs replace what the model wrote after the rule steps, which run on the
    /// model's text as before. The paste, its report for learning, the vocabulary dates and
    /// Copy Last Dictation all have the user's word.
    @Test func learnedWordsReplaceTheHeardSpellingAfterTheRules() async throws {
        let pair = Correction(heard: "克劳德", corrected: "Claude")
        let controller = await controller(vocabulary: ["Claude"])
        controller.replacementPairs = { [pair] }
        var reported: [(String, String?, [Replacement])] = []
        controller.onPasted = { text, _, before, replacements in reported.append((text, before, replacements)) }
        speech.reply = "呃，我们下午两点用克劳德。"
        try await dictate(controller)
        #expect(inserter.inserted == ["我们下午2点用Claude。"])
        #expect(reported.map(\.0) == ["我们下午2点用Claude。"])
        #expect(reported.map(\.1) == [nil])
        #expect(reported.map(\.2) == [[Replacement(span: 7..<13, heard: "克劳德", corrected: "Claude", pair: pair)]])
        #expect(controller.lastTranscript == "我们下午2点用Claude。")
        #expect(controller.vocabulary.first?.lastUsed != nil)
    }

    @Test func aPairWhoseWordIsNotInTheVocabularyReplacesNothing() async throws {
        let controller = await controller(vocabulary: ["Orra"])
        controller.replacementPairs = { [Correction(heard: "克劳德", corrected: "Claude")] }
        speech.reply = "我们用克劳德。"
        try await dictate(controller)
        #expect(inserter.inserted == ["我们用克劳德。"])
    }

    /// The cleanup model sees the user's words, and Paste Original Text keeps them: they are
    /// the user's own, and taking them out would put back a known mishearing.
    @Test func theCleanupAndPasteOriginalTextKeepTheReplacements() async throws {
        let pair = Correction(heard: "克劳德", corrected: "Claude")
        let received = Mutex<[String]>([])
        let controller = await controller(cleanup: CleanupModel(waitUntilLoaded: { true }, complete: { text in
            received.withLock { $0.append(text) }
            return #"{"cleaned": "我们下午3点用Claude开会。"}"#
        }))
        controller.addToVocabulary("Claude")
        controller.replacementPairs = { [pair] }
        var reported: [(String, String?, [Replacement])] = []
        controller.onPasted = { text, _, before, replacements in reported.append((text, before, replacements)) }
        speech.reply = "呃，我们下午两点，哦不对，下午三点用克劳德开会。"
        try await dictate(controller)
        let ruled = "我们下午2点，哦不对，下午3点用Claude开会。"
        #expect(received.withLock { $0 } == [ruled])
        #expect(inserter.inserted == ["我们下午3点用Claude开会。"])
        #expect(controller.originalText == ruled)
        // Placed in the text before the cleanup.
        #expect(reported.map(\.1) == [ruled])
        #expect(reported.map(\.2) == [[Replacement(span: 16..<22, heard: "克劳德", corrected: "Claude", pair: pair)]])
        await controller.pasteOriginal()
        #expect(inserter.inserted.last == ruled)
    }

    @Test func aFailingCleanupPastesTheRuledText() async throws {
        let controller = await controller(cleanup: CleanupModel(waitUntilLoaded: { true }, complete: { _ in throw TestError() }))
        speech.reply = "呃，我们明天再说吧。"
        try await dictate(controller)
        #expect(inserter.inserted == ["我们明天再说吧。"])
        #expect(controller.originalText == nil)
        #expect(controller.problem == nil)
    }

    @Test func noCleanupWhileTheModelIsNotReadyOrTheTextIsShort() async throws {
        let calls = Mutex(0)
        var ready = false
        let controller = await controller(cleanup: CleanupModel(waitUntilLoaded: { ready }, complete: { text in
            calls.withLock { $0 += 1 }
            return #"{"cleaned": "x"}"#
        }))
        speech.reply = "我们明天再说吧。"
        try await dictate(controller)
        ready = true
        speech.reply = "好的。"
        try await dictate(controller)
        #expect(calls.withLock { $0 } == 0)
        #expect(inserter.inserted == ["我们明天再说吧。", "好的。"])
        await controller.pasteOriginal()
        #expect(inserter.inserted.count == 2)
    }

    // MARK: Translation

    private static let spoken = "呃，我们下周一，哦不是，下周二开会。"
    private static let goodTranslation = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"#

    /// A stand in for the model's translations, which records what it was asked.
    @MainActor
    final class FakeTranslation {
        /// What the model closure reads and writes off the main actor.
        final class Shared: Sendable {
            let answer: Mutex<String>
            let received = Mutex<[String]>([])
            let fails = Mutex(false)

            init(answer: String) {
                self.answer = Mutex(answer)
            }
        }

        var ready = true
        var direction = TranslationDirection.automatic
        let shared: Shared

        init(answer: String = PushToTalkControllerTests.goodTranslation) {
            shared = Shared(answer: answer)
        }

        var model: TranslationModel {
            TranslationModel(
                isReady: { self.ready },
                direction: { self.direction },
                complete: { [shared] text, target in
                    shared.received.withLock { $0.append("\(target.rawValue) \(text)") }
                    if shared.fails.withLock({ $0 }) { throw TestError() }
                    return shared.answer.withLock { $0 }
                }
            )
        }

        var received: [String] {
            shared.received.withLock { $0 }
        }

        var calls: Int {
            received.count
        }
    }

    private func controller(translation: FakeTranslation, cleanup: CleanupModel = .off) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup,
            translation: translation.model,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        controller.setTranslationKeyOn(true)
        await controller.loadModel()
        return controller
    }

    /// A hold of `key` that records and is released.
    private func dictate(_ controller: PushToTalkController, with key: TalkKey) async throws {
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.pressed(isRepeat: false), key: .key(key))
        try await waitUntil { mic.calls.filter { $0 == "start" }.count > starts }
        controller.handle(.released, key: .key(key))
        try await waitUntil { controller.state == .idle }
    }

    /// The translation key pastes the translation of the text the rules left. Copy Last
    /// Dictation copies the translation, Paste Original Text pastes the text before it,
    /// and Orra never learns from the translated paste.
    @Test func theTranslationKeyPastesTheTranslation() async throws {
        let translation = FakeTranslation()
        let controller = await controller(translation: translation)
        var reported: [String] = []
        var stopped: [String] = []
        controller.onPasted = { text, _, _, _ in reported.append(text) }
        controller.onPasteOriginal = { stopped.append($0) }
        speech.reply = Self.spoken
        try await dictate(controller, with: .rightOption)
        let asked = try #require(translation.received.first)
        #expect(asked.hasPrefix("en "))
        let ruled = String(asked.dropFirst(3))
        #expect(!ruled.contains("呃"))
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        #expect(controller.lastTranscript == "We have a meeting next Tuesday.")
        // Cleanup is off, so the text before translation is the text the rules left.
        #expect(controller.originalText == ruled)
        #expect(controller.notice == nil)
        #expect(reported.isEmpty)
        await controller.pasteOriginal()
        #expect(inserter.inserted == ["We have a meeting next Tuesday.", ruled])
        #expect(reported.isEmpty)
        #expect(stopped == ["We have a meeting next Tuesday."])
    }

    /// With cleanup on, the translation step does the cleanup, so the cleanup step does
    /// not run, and Paste Original Text pastes the cleaned text.
    @Test func withCleanupOnTheTextBeforeTranslationIsCleanedUp() async throws {
        let translation = FakeTranslation()
        let cleanups = Mutex(0)
        let controller = await controller(translation: translation, cleanup: CleanupModel(waitUntilLoaded: { true }, complete: { _ in
            cleanups.withLock { $0 += 1 }
            return #"{"cleaned": "x"}"#
        }))
        speech.reply = Self.spoken
        try await dictate(controller, with: .rightOption)
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        #expect(controller.originalText == "我们下周二开会。")
        #expect(cleanups.withLock { $0 } == 0)
    }

    /// The talk key never translates, also while translation is on.
    @Test func theTalkKeyDoesNotTranslate() async throws {
        let translation = FakeTranslation()
        let controller = await controller(translation: translation)
        var reported: [String] = []
        controller.onPasted = { text, _, _, _ in reported.append(text) }
        try await dictate(controller, with: .rightControl)
        try await dictate(controller)
        #expect(translation.calls == 0)
        #expect(inserter.inserted == ["你好", "你好"])
        #expect(reported == ["你好", "你好"])
    }

    /// A translation that fails a check, or a model that fails, pastes the text without
    /// translation and says so. That paste is the dictation itself, so Orra may learn
    /// from it.
    @Test func aTranslationThatCannotBeUsedPastesTheTextWithoutIt() async throws {
        let translation = FakeTranslation(answer: #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday at 3."}"#)
        let controller = await controller(translation: translation)
        var reported: [String] = []
        controller.onPasted = { text, _, _, _ in reported.append(text) }
        speech.reply = Self.spoken
        try await dictate(controller, with: .rightOption)
        let ruled = try #require(inserter.inserted.first)
        #expect(ruled.contains("下周二"))
        #expect(controller.notice == "This dictation was pasted without translation.")
        #expect(controller.originalText == nil)
        #expect(reported == [ruled])
        translation.shared.fails.withLock { $0 = true }
        try await dictate(controller, with: .rightOption)
        #expect(inserter.inserted == [ruled, ruled])
        #expect(controller.notice == "This dictation was pasted without translation.")
        // An unreadable answer too.
        translation.shared.fails.withLock { $0 = false }
        translation.shared.answer.withLock { $0 = "We have a meeting next Tuesday." }
        try await dictate(controller, with: .rightOption)
        #expect(inserter.inserted == [ruled, ruled, ruled])
    }

    @Test func aLongDictationIsPastedWithoutTranslation() async throws {
        let translation = FakeTranslation()
        let controller = await controller(translation: translation)
        let long = String(repeating: "我们明天下午开会讨论一下。", count: 25)
        #expect(long.count > TranslationStep.maximumLength)
        speech.reply = long
        // Long enough to have said it, so the length cap of TranscriptGuard keeps it all.
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000 * 50), sampleRate: 16_000)
        try await dictate(controller, with: .rightOption)
        #expect(translation.calls == 0)
        #expect(inserter.inserted.count == 1)
        #expect(inserter.inserted.first?.count == long.count)
        #expect(controller.notice == "Dictations over 300 characters are pasted without translation.")
    }

    @Test func withoutTheModelTheTextIsPastedWithoutTranslation() async throws {
        let translation = FakeTranslation()
        translation.ready = false
        let controller = await controller(translation: translation)
        try await dictate(controller, with: .rightOption)
        #expect(translation.calls == 0)
        #expect(inserter.inserted == ["你好"])
        #expect(controller.notice == "The local model is not ready, so the text was pasted without translation.")
    }

    /// Text with nothing to translate, such as digits, is pasted as it is without a
    /// notice, and so is text already in a fixed target language.
    @Test func textWithNothingToTranslateIsPastedQuietly() async throws {
        let translation = FakeTranslation(answer: #"{"cleaned": "我们下周二开会。", "translation": "我们下周二开会。"}"#)
        translation.direction = .chinese
        let controller = await controller(translation: translation)
        speech.reply = "123"
        try await dictate(controller, with: .rightOption)
        #expect(translation.calls == 0)
        #expect(inserter.inserted == ["123"])
        #expect(controller.notice == nil)
        speech.reply = "我们下周二开会。"
        try await dictate(controller, with: .rightOption)
        #expect(translation.received == ["zh 我们下周二开会。"])
        #expect(inserter.inserted == ["123", "我们下周二开会。"])
        #expect(controller.notice == nil)
    }

    /// The indicator learns that the dictation will be translated, and which way, for
    /// holds of the translation key only.
    @Test func theCuesOfATranslationSayWhichWay() async throws {
        let translation = FakeTranslation()
        translation.direction = .english
        let controller = await controller(translation: translation)
        let cues = CueRecorder(controller)
        try await dictate(controller, with: .rightOption)
        #expect(cues.list == [.listening(translation: .english), .transcribing, .recordingStopped, .finished(message: nil)])
        try await dictate(controller, with: .rightControl)
        #expect(cues.list.suffix(4) == [.listening, .transcribing, .recordingStopped, .finished(message: nil)])
        // A key of no dictation, such as the translation key while translation is off,
        // never translates.
        controller.setTranslationKeyOn(false)
        try await dictate(controller, with: .rightOption)
        #expect(cues.list.suffix(4).first == .listening)
        #expect(translation.calls == 1)
    }

    /// A double press of the translation key, through the tap, records hands free and
    /// pastes the translation at the next press, after the key's wait, as for the talk key.
    @Test func aDoublePressOfTheTranslationKeyTranslatesHandsFree() async throws {
        let translation = FakeTranslation()
        speech.reply = Self.spoken
        let controller = try await startedController(translation: translation.model)
        controller.setTranslationKeyOn(true)
        let cues = CueRecorder(controller)
        let tap = try #require(tapSystem.installed)
        let key = TalkKey.rightOption
        let down = key.downFlag.union(.maskAlternate)
        var now = ContinuousClock.now
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: now)
        now = now.advanced(by: .milliseconds(80))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        // The tap of a key that waits keeps nothing. Its early capture is dropped.
        #expect(controller.state == .idle)
        now = now.advanced(by: .milliseconds(100))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: now)
        now = now.advanced(by: .milliseconds(80))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        #expect(controller.state == .handsFree)
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.handsFree(finishHint: "Press right Option to finish", translation: .automatic)])
        now = now.advanced(by: .seconds(2))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: now)
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        try await waitUntil { controller.state == .idle && !inserter.inserted.isEmpty }
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        // The tap was over before its start began, so it never started the microphone, and
        // the second press's early capture became the dictation.
        #expect(mic.calls == ["start", "stop"])
    }

    /// An Option shortcut during the translation key's wait drops the capture that the key
    /// down started, silently, and a hold through the wait keeps its capture from the key
    /// down.
    @Test func anOptionShortcutDuringTheWaitIsDroppedSilently() async throws {
        let translation = FakeTranslation()
        let controller = try await startedController(translation: translation.model)
        controller.setTranslationKeyOn(true)
        let cues = CueRecorder(controller)
        let tap = try #require(tapSystem.installed)
        let key = TalkKey.rightOption
        let down = key.downFlag.union(.maskAlternate)
        #expect(tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down) == false)
        #expect(controller.state == .arming)
        // The microphone starts at once, before a person types the next key.
        try await waitUntil { mic.calls == ["start"] }
        // Option E types an accent and passes through.
        #expect(tap.handle(type: .keyDown, keyCode: 14, flags: down) == false)
        tap.fireTimer()
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [])
        #expect(controller.state == .idle)
        try await waitUntil { mic.calls == ["start", "cancel"] }
        #expect(mic.calls == ["start", "cancel"])
        // No cue, no sound, no message, and the cleanup model was not asked to load.
        #expect(cues.list.isEmpty)
        #expect(controller.problem == nil)
        #expect(controller.notice == nil)
        #expect(controller.isKeepingDictationAwake == false)
        // Nothing to log: the press never counted.
        #expect(mic.onsetReads == 0)
        // Held through the wait: the timer fires and the capture of the key down goes on.
        // The times are given, so the release counts as the end of a hold, not as a tap.
        let pressed = ContinuousClock.now
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: pressed)
        #expect(controller.state == .arming)
        try await waitUntil { mic.calls.count == 3 }
        #expect(cues.list.isEmpty)
        tap.fireTimer()
        #expect(controller.state == .listening)
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.listening(translation: .automatic)])
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: pressed.advanced(by: .seconds(2)))
        try await waitUntil { controller.state == .idle && !inserter.inserted.isEmpty }
        #expect(translation.calls == 1)
        #expect(mic.calls == ["start", "cancel", "start", "stop"])
        #expect(mic.onsetReads == 1)
    }

    @Test func theLevelComesFromTheMicrophone() async {
        mic.level = 0.25
        let controller = await makeController()
        #expect(controller.inputLevel() == 0.25)
    }

    @Test func microphoneAccessCanBeReadAgain() async {
        mic.access = .denied
        let controller = await makeController()
        controller.refreshMicrophoneAccess()
        #expect(controller.microphoneAccess == .denied)
        mic.access = .authorized
        controller.refreshMicrophoneAccess()
        #expect(controller.microphoneAccess == .authorized)
        // Reading never asks.
        #expect(mic.calls.isEmpty)
    }

    @Test func hostDetectionSeesTheTestEnvironment() {
        // AppDelegate skips the keyboard tap and the welcome window when Xcode
        // hosts tests or previews. This checks only that the environment
        // variable the guard relies on is set while tests run. It does not run
        // the guard itself.
        #expect(AppDelegate.isHostedByXcode)
    }

    // MARK: Hands free

    @Test func aDoublePressRecordsHandsFreeUntilTheNextPress() async throws {
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] }
        controller.handle(.tapped)
        #expect(controller.state == .waitingForSecondPress)
        // The second press, then its quick release.
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .listening)
        controller.handle(.doublePressed)
        #expect(controller.state == .handsFree)
        try await waitUntil { cues.list.count == 2 }
        // The same recording goes on: the microphone started once.
        #expect(cues.list == [.listening, .handsFree(finishHint: "Press right Control to finish")])
        #expect(mic.calls == ["start"])
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
        #expect(cues.list.last == .finished(message: nil))
    }

    @Test func aTapThenAHoldPastesAtTheRelease() async throws {
        let controller = await makeController()
        let cues = CueRecorder(controller)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { cues.list == [.listening] }
        controller.handle(.tapped)
        // The second press is held, so it is an ordinary hold on the same recording.
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .listening)
        try await waitUntil { cues.list == [.listening, .listening] }
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(mic.calls == ["start", "stop"])
        #expect(inserter.inserted == ["你好"])
    }

    @Test func aDoublePressFromIdleStartsTheMicrophoneAndShowsTheHintAtOnce() async throws {
        let controller = await makeController(listeningCueDelay: .seconds(10))
        let cues = CueRecorder(controller)
        controller.handle(.doublePressed)
        try await waitUntil { !cues.list.isEmpty }
        #expect(cues.list == [.handsFree(finishHint: "Press right Control to finish")])
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(inserter.inserted == ["你好"])
    }

    @Test func aTapWithoutASecondPressIsDiscarded() async throws {
        let controller = await makeController()
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.tapped)
        // The window ends without a second press.
        controller.handle(.cancelled)
        try await waitUntil { mic.calls.contains("cancel") }
        #expect(controller.state == .idle)
        #expect(mic.calls == ["start", "cancel"])
        #expect(inserter.inserted.isEmpty)
    }

    @Test func cancellingHandsFreePastesNothing() async throws {
        let controller = await makeController()
        controller.handle(.doublePressed)
        try await waitUntil { mic.calls.contains("start") }
        // Escape, or a change of keys.
        controller.handle(.cancelled)
        try await waitUntil { mic.calls.contains("cancel") }
        #expect(controller.state == .idle)
        #expect(inserter.inserted.isEmpty)
        #expect(speech.receivedSampleCounts.isEmpty)
    }

    @Test func handsFreeStopsAtTheTimeLimitAndSaysWhy() async throws {
        let controller = await makeController(limit: .milliseconds(50))
        let cues = CueRecorder(controller)
        controller.handle(.doublePressed)
        try await waitUntil { controller.state == .idle && !inserter.inserted.isEmpty }
        #expect(inserter.inserted == ["你好"])
        #expect(cues.list.last == .finished(message: "Orra records up to 1 minute at a time, so the recording stopped there."))
    }

    @Test func aDoublePressWithoutTheModelSaysWhy() async throws {
        let controller = await makeController(loadModel: false)
        let cues = CueRecorder(controller)
        controller.handle(.doublePressed)
        #expect(controller.state == .idle)
        #expect(mic.calls.isEmpty)
        #expect(cues.list.count == 1)
    }

    @Test func handsFreeThroughTheTapEndsWithEscape() async throws {
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        let key = TalkKey.rightControl
        let down = HotkeyTapTests.rightControlDown
        var now = ContinuousClock.now
        #expect(tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: now) == false)
        now = now.advanced(by: .milliseconds(80))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        #expect(controller.state == .waitingForSecondPress)
        now = now.advanced(by: .milliseconds(100))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: down, at: now)
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        #expect(controller.state == .handsFree)
        #expect(tap.activeKey == .rightControl)
        // Escape is swallowed and cancels.
        #expect(tap.handle(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: [], at: now))
        #expect(controller.state == .idle)
        #expect(tap.handle(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: [], at: now) == false)
        try await waitUntil { mic.calls.contains("cancel") }
        #expect(inserter.inserted.isEmpty)
    }

    @Test func aDoublePressDuringProcessingLeavesEscapeAlone() async throws {
        speech.delay = .milliseconds(300)
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.contains("start") }
        controller.handle(.released)
        #expect(controller.state == .processing)
        let key = TalkKey.fn
        controller.chooseTalkKey(.key(key))
        var now = ContinuousClock.now
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: .maskSecondaryFn, at: now)
        now = now.advanced(by: .milliseconds(50))
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: .maskSecondaryFn, at: now)
        _ = tap.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [], at: now)
        // The state model ignored the double press, so the tap holds no dictation.
        #expect(controller.state == .processing)
        #expect(tap.handle(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: [], at: now) == false)
        try await waitUntil { controller.state == .idle }
    }

    @Test func handsFreeIsSaved() {
        var saved: [Bool] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            handsFree: true,
            saveHandsFree: { saved.append($0) }
        )
        controller.setHandsFreeOn(false)
        controller.setHandsFreeOn(false)
        #expect(controller.handsFreeOn == false)
        #expect(saved == [false])
    }

    // MARK: Choosing the talk key by pressing it

    @Test func pressingAKeyMakesItTheTalkKey() {
        var saved: [Hotkey] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .rightOption,
            saveTalkKey: { saved.append($0) }
        )
        #expect(controller.hasChosenTalkKey == false)
        controller.startChoosingTalkKey()
        #expect(controller.isChoosingTalkKey)
        controller.keyChoice(type: .flagsChanged, keyCode: 0x38, flags: .maskShift)
        #expect(controller.keyChoiceNote == "Shift can't be the talk key. On its own, it switches input methods between Chinese and English.")
        controller.keyChoice(type: .flagsChanged, keyCode: 0x38, flags: [])
        controller.keyChoice(type: .keyDown, keyCode: 0x24, flags: [])
        #expect(controller.keyChoiceNote == "The Return key can't be the talk key. Holding it would type or do something in the app in front.")
        controller.keyChoice(type: .flagsChanged, keyCode: 0x39, flags: .maskAlphaShift)
        #expect(controller.keyChoiceNote == "Caps Lock can't be the talk key. It turns capitals or the input method on and off.")
        // fn with an arrow is a key of its own, such as Page Up, not fn. Up Arrow has the
        // same name on every keyboard layout, unlike a letter.
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        controller.keyChoice(type: .keyDown, keyCode: 0x7E, flags: .maskSecondaryFn)
        #expect(controller.keyChoiceNote == "fn Up Arrow is a key combination and can't be the talk key.")
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: [])
        #expect(controller.isChoosingTalkKey)
        #expect(controller.talkKey == .rightOption)
        // Left Option pressed and released on its own.
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.leftOption.keyCode, flags: [.maskAlternate, TalkKey.leftOption.downFlag])
        #expect(controller.isChoosingTalkKey)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.leftOption.keyCode, flags: [])
        #expect(controller.isChoosingTalkKey == false)
        #expect(controller.keyChoiceNote == nil)
        #expect(controller.talkKey == .leftOption)
        #expect(saved == [.leftOption])
        #expect(controller.hasChosenTalkKey)
        // A press after the choice changes nothing.
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: [])
        #expect(controller.talkKey == .leftOption)
    }

    @Test func aTalkKeyGoingDownClearsTheNoteAboutAnEarlierPress() {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .rightControl
        )
        controller.startChoosingTalkKey()
        controller.keyChoice(type: .keyDown, keyCode: 0x24, flags: [])
        #expect(controller.keyChoiceNote == "The Return key can't be the talk key. Holding it would type or do something in the app in front.")
        // A key up or other event that decides nothing keeps the note.
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: [])
        #expect(controller.keyChoiceNote != nil)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: [.maskAlternate, TalkKey.rightOption.downFlag])
        #expect(controller.keyChoiceNote == nil)
        #expect(controller.isChoosingTalkKey)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: [])
        #expect(controller.talkKey == .rightOption)
    }

    @Test func escapeStopsChoosingWithoutAChange() {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .fn
        )
        controller.startChoosingTalkKey()
        controller.keyChoice(type: .keyDown, keyCode: 0x00, flags: [])
        #expect(controller.keyChoiceNote != nil)
        controller.keyChoice(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: [])
        #expect(controller.isChoosingTalkKey == false)
        #expect(controller.keyChoiceNote == nil)
        #expect(controller.talkKey == .fn)
    }

    @Test func stoppingTheRecordingClearsTheNoteAndAHalfPress() {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .fn
        )
        controller.startChoosingTalkKey()
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [.maskControl, TalkKey.rightControl.downFlag])
        controller.stopChoosingKey()
        // A new recording starts afresh, so the earlier press's release chooses nothing.
        controller.startChoosingTalkKey()
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [])
        #expect(controller.isChoosingTalkKey)
        #expect(controller.talkKey == .fn)
        controller.stopChoosingKey()
    }

    // MARK: The translation key

    @Test func theTranslationKeyDefaultsToTheKeyBesideTheTalkKey() {
        let controller = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert)
        #expect(controller.translationKey == .rightOption)
        let optionTalker = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkKey: .rightOption)
        #expect(optionTalker.translationKey == .rightCommand)
        let saved = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkKey: .fn, translationKey: .leftOption)
        #expect(saved.translationKey == .leftOption)
        // Never the talk key.
        let clash = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, talkKey: .fn, translationKey: .fn)
        #expect(clash.translationKey == .rightOption)
    }

    @Test func pickingTheTranslationKeyAsTheTalkKeySwapsThem() {
        var savedTalk: [Hotkey] = []
        var savedTranslation: [Hotkey] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .rightControl,
            saveTalkKey: { savedTalk.append($0) },
            saveTranslationKey: { savedTranslation.append($0) }
        )
        controller.chooseTalkKey(.rightOption)
        #expect(controller.talkKey == .rightOption)
        #expect(controller.translationKey == .rightControl)
        #expect(savedTalk == [.rightOption])
        #expect(savedTranslation == [.rightControl])
        #expect(controller.keySwap == KeySwap(talkKey: .rightOption, translationKey: .rightControl))
        #expect(controller.keySwap?.message() == "The two keys swapped. The talk key is now right Option and the translation key right Control.")
        // A key without a clash leaves the translation key, and the note goes.
        controller.chooseTalkKey(.fn)
        #expect(controller.translationKey == .rightControl)
        #expect(controller.keySwap == nil)
        #expect(savedTranslation == [.rightControl])
    }

    @Test func pickingTheTalkKeyAsTheTranslationKeySwapsThem() {
        var savedTalk: [Hotkey] = []
        var savedTranslation: [Hotkey] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .fn,
            saveTalkKey: { savedTalk.append($0) },
            translationKey: .rightOption,
            saveTranslationKey: { savedTranslation.append($0) }
        )
        controller.startChoosingKey(for: .translation)
        #expect(controller.choosingKeySlot == .translation)
        #expect(controller.isChoosingTalkKey == false)
        controller.keyChoice(type: .keyDown, keyCode: 0x24, flags: [])
        #expect(controller.keyChoiceNote == "The Return key can't be the translation key. Holding it would type or do something in the app in front.")
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: [])
        #expect(controller.choosingKeySlot == nil)
        #expect(controller.translationKey == .fn)
        #expect(controller.talkKey == .rightOption)
        #expect(savedTranslation == [.fn])
        #expect(savedTalk == [.rightOption])
        #expect(controller.hasChosenTalkKey)
        #expect(controller.keySwap == KeySwap(talkKey: .rightOption, translationKey: .fn))
        // Recording again clears the note, and Escape changes nothing.
        controller.startChoosingKey(for: .translation)
        #expect(controller.keySwap == nil)
        controller.keyChoice(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: [])
        #expect(controller.translationKey == .fn)
        #expect(savedTranslation == [.fn])
    }

    @Test func recordingOneKeyStopsTheOther() {
        let controller = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert)
        controller.startChoosingTalkKey()
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: [.maskCommand, TalkKey.leftCommand.downFlag])
        controller.startChoosingKey(for: .translation)
        // The half press belonged to the talk key's recording, so its release picks nothing.
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: [])
        #expect(controller.choosingKeySlot == .translation)
        #expect(controller.translationKey == .rightOption)
        #expect(controller.talkKey == .rightControl)
        controller.stopChoosingKey()
        #expect(controller.choosingKeySlot == nil)
    }

    /// The tap watches the translation key only while translation is on. That key waits
    /// before it counts, recording silently meanwhile, while the talk key counts at once.
    @Test func theTapWatchesTheTranslationKeyOnlyWhileTranslationIsOn() async throws {
        let controller = try await startedController()
        let tap = try #require(tapSystem.installed)
        let optionDown = TalkKey.rightOption.downFlag.union(.maskAlternate)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: optionDown)
        #expect(tap.activeKey == nil)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: [])
        controller.setTranslationKeyOn(true)
        #expect(controller.translationKeyIsOn)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: optionDown)
        #expect(tap.activeKey == .rightOption)
        // It records silently while it waits.
        #expect(controller.state == .arming)
        tap.fireTimer()
        #expect(controller.state == .listening)
        controller.setTranslationKeyOn(false)
        // Turning translation off ends the translation key's dictation.
        #expect(controller.state == .idle)
        #expect(tap.activeKey == nil)
        try await waitUntil { mic.calls.contains("cancel") }
    }

    @Test func keepingTheDefaultKeySavesIt() {
        var saved: [Hotkey] = []
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            talkKey: .rightControl,
            saveTalkKey: { saved.append($0) }
        )
        #expect(controller.hasChosenTalkKey == false)
        controller.chooseTalkKey(.rightControl)
        #expect(controller.hasChosenTalkKey)
        #expect(saved == [.rightControl])
    }

    /// Press to start and stop: the first press records on after its release, and the
    /// next press pastes. The mode is saved.
    @Test func theTalkKeyCanStartAndStopWithAPress() async throws {
        let controller = try await startedController()
        var savedModes: [TriggerMode] = []
        let saving = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, saveTriggerMode: { mode, _ in savedModes.append(mode) })
        saving.setTriggerMode(.toggle, for: .talk)
        saving.setTriggerMode(.toggle, for: .talk)
        #expect(savedModes == [.toggle])
        #expect(saving.talkHint() == "Press right Control to talk, and again to finish")
        controller.setTriggerMode(.toggle, for: .talk)
        let tap = try #require(tapSystem.installed)
        let controlDown = TalkKey.rightControl.downFlag.union(.maskControl)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(controller.state == .listening)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [])
        #expect(controller.state == .handsFree)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(controller.state == .handsFree)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [])
        #expect(controller.state != .handsFree)
        try await waitUntil { mic.calls.contains("stop") }
    }

    /// A translation key of Control and Option: right Control, the talk key, waits so the
    /// combination can take over, and the dictation is the translation key's.
    @Test func aCombinationTranslationKeyTakesOverFromTheTalkKey() async throws {
        let controller = try await startedController()
        controller.setTranslationKeyOn(true)
        let combination = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
        controller.chooseTranslationKey(combination)
        #expect(controller.translateHint() == "Hold ⌃ ⌥ to translate")
        let tap = try #require(tapSystem.installed)
        let controlDown = TalkKey.rightControl.downFlag.union(.maskControl)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(tap.activeKey == .rightControl)
        #expect(controller.state == .arming)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: controlDown.union(TalkKey.rightOption.downFlag).union(.maskAlternate))
        #expect(tap.activeKey == combination)
        // The combination waits without an early capture, so right Control's is dropped.
        #expect(controller.state == .idle)
        tap.fireTimer()
        #expect(controller.state == .listening)
        // Picking the combination for the talk key swaps the keys.
        controller.chooseTalkKey(combination)
        #expect(controller.talkKey == combination)
        #expect(controller.translationKey == .rightControl)
    }

    @Test func aRecordedShortcutBecomesTheKey() {
        var saved: [Hotkey] = []
        let controller = PushToTalkController(capture: mic.capture, transcription: speech.transcription, insert: inserter.insert, saveTalkKey: { saved.append($0) })
        controller.startChoosingTalkKey()
        let flags = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 0x08)).union(.maskShift)
        controller.keyChoice(type: .flagsChanged, keyCode: 0x38, flags: .maskShift)
        #expect(controller.keyChoiceRejection == .shift)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: flags)
        // The combination under way replaces the note about Shift.
        #expect(controller.keyChoiceRejection == nil)
        controller.keyChoice(type: .keyDown, keyCode: 0x02, flags: flags)
        #expect(controller.choosingKeySlot == nil)
        #expect(controller.talkKey == .combination(KeyCombination(modifiers: [.shift, .command], keyCode: 0x02)))
        #expect(controller.talkKey.combination?.character != nil)
        #expect(saved == [controller.talkKey])
    }
}
