import Foundation
import os
import Testing
@testable import Orra

@MainActor
struct MeetingCaptionsTests {
    /// Stands in for the capture. MeetingCaptions calls it off the main actor, so its
    /// state is behind a lock. With `holdsStart`, a start waits until `releaseStart`, and
    /// with `holdsPlayChecks`, a check whether something plays waits until
    /// `releasePlayChecks`.
    private final class FakeSource: Sendable {
        private struct State {
            var fails: SystemAudioProblem?
            var holdsStart = false
            var deliver: (@Sendable ([Float]) -> Void)?
            var calls: [String] = []
            var startedOnMain = false
            var plays: [Bool?] = [false]
            var holdsPlayChecks = false
            var answers: [Bool?] = []
            var checkedOnMain = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let gate = DispatchSemaphore(value: 0)
        private let checkGate = DispatchSemaphore(value: 0)

        /// What the checks whether something plays answer, one after the other, and the
        /// last one for every check after it. Nothing plays unless a test says otherwise.
        var plays: [Bool?] {
            get { state.withLock { $0.plays } }
            set { state.withLock { $0.plays = newValue } }
        }

        var holdsPlayChecks: Bool {
            get { state.withLock { $0.holdsPlayChecks } }
            set { state.withLock { $0.holdsPlayChecks = newValue } }
        }

        /// What the checks answered, in order.
        var answers: [Bool?] {
            state.withLock { $0.answers }
        }

        var checkedOnMain: Bool {
            state.withLock { $0.checkedOnMain }
        }

        func releasePlayChecks() {
            checkGate.signal()
        }

        var fails: SystemAudioProblem? {
            get { state.withLock { $0.fails } }
            set { state.withLock { $0.fails = newValue } }
        }

        var holdsStart: Bool {
            get { state.withLock { $0.holdsStart } }
            set { state.withLock { $0.holdsStart = newValue } }
        }

        /// "start", "started", "failed" and "stop", in the order they happened.
        var calls: [String] {
            state.withLock { $0.calls }
        }

        var starts: Int {
            calls.filter { $0 == "start" }.count
        }

        var stops: Int {
            calls.filter { $0 == "stop" }.count
        }

        var isCapturing: Bool {
            state.withLock { $0.deliver != nil }
        }

        var startedOnMain: Bool {
            state.withLock { $0.startedOnMain }
        }

        func releaseStart() {
            gate.signal()
        }

        var source: SystemAudioSource {
            SystemAudioSource(start: { [self] deliver in
                let (holds, fails) = state.withLock {
                    $0.calls.append("start")
                    if Thread.isMainThread {
                        $0.startedOnMain = true
                    }
                    return ($0.holdsStart, $0.fails)
                }
                if holds {
                    // Like the permission prompt. Bounded, so a broken test cannot hang,
                    // but long, since a busy runner can keep the main actor away from a
                    // test for many seconds.
                    _ = gate.wait(timeout: .now() + 120)
                }
                if let fails {
                    state.withLock { $0.calls.append("failed") }
                    throw fails
                }
                state.withLock {
                    $0.calls.append("started")
                    $0.deliver = deliver
                }
            }, stop: { [self] in
                state.withLock {
                    $0.calls.append("stop")
                    $0.deliver = nil
                }
            }, somethingPlays: { [self] in
                let (holds, answer) = state.withLock {
                    if Thread.isMainThread {
                        $0.checkedOnMain = true
                    }
                    let answer = $0.plays.count > 1 ? $0.plays.removeFirst() : $0.plays.first ?? nil
                    return ($0.holdsPlayChecks, answer)
                }
                if holds {
                    // Like an audio server that does not answer. Bounded, as a start that
                    // waits.
                    _ = checkGate.wait(timeout: .now() + 120)
                }
                state.withLock { $0.answers.append(answer) }
                return answer
            })
        }
    }

    /// Stands in for the caption microphone, named apart from PushToTalkControllerTests'
    /// FakeMicrophone. MeetingCaptions starts and stops it off the main actor, so its state
    /// is behind a lock. With `holdsStart`, a start waits until `releaseStart`, like a
    /// Bluetooth microphone that takes seconds, and with `holdsStop`, a stop waits until
    /// `releaseStop`. `move` tells the captions that the device moved, and `inputs` stands in
    /// for the watch of the devices.
    private final class FakeCaptionMicrophone: Sendable {
        private struct State {
            var access = MicrophoneAccess.authorized
            var fails: MicrophoneCaptionProblem?
            var holdsStart = false
            var holdsStop = false
            var stopWaits = false
            var lidClosed = false
            var input = AudioInput(id: 7, uid: "usb-1", name: "USB Microphone", isInternalMicrophone: false)
            var deliver: (@Sendable ([Float]) -> Void)?
            var moved: (@Sendable () -> Void)?
            var calls: [String] = []
            var startedUIDs: [String?] = []
            var startedOnMain = false
            var accessReads = 0
        }

        /// The watch of the devices, which captions start while no microphone is
        /// connected.
        @MainActor
        final class Inputs {
            var onChange: (@MainActor () -> Void)?
            var watches = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let gate = DispatchSemaphore(value: 0)
        private let stopGate = DispatchSemaphore(value: 0)
        let inputs = MainActor.assumeIsolated { Inputs() }

        var access: MicrophoneAccess {
            get { state.withLock { $0.access } }
            set { state.withLock { $0.access = newValue } }
        }

        var fails: MicrophoneCaptionProblem? {
            get { state.withLock { $0.fails } }
            set { state.withLock { $0.fails = newValue } }
        }

        var holdsStart: Bool {
            get { state.withLock { $0.holdsStart } }
            set { state.withLock { $0.holdsStart = newValue } }
        }

        var holdsStop: Bool {
            get { state.withLock { $0.holdsStop } }
            set { state.withLock { $0.holdsStop = newValue } }
        }

        /// True while a stop waits for `releaseStop`.
        var stopWaits: Bool {
            state.withLock { $0.stopWaits }
        }

        var lidClosed: Bool {
            get { state.withLock { $0.lidClosed } }
            set { state.withLock { $0.lidClosed = newValue } }
        }

        var input: AudioInput {
            get { state.withLock { $0.input } }
            set { state.withLock { $0.input = newValue } }
        }

        /// "start", "started", "failed" and "stop", in the order they happened.
        var calls: [String] {
            state.withLock { $0.calls }
        }

        var starts: Int {
            calls.filter { $0 == "start" }.count
        }

        var stops: Int {
            calls.filter { $0 == "stop" }.count
        }

        /// The UID each start was given, nil for the system default.
        var startedUIDs: [String?] {
            state.withLock { $0.startedUIDs }
        }

        var startedOnMain: Bool {
            state.withLock { $0.startedOnMain }
        }

        var accessReads: Int {
            state.withLock { $0.accessReads }
        }

        var isCapturing: Bool {
            state.withLock { $0.deliver != nil }
        }

        func releaseStart() {
            gate.signal()
        }

        func releaseStop() {
            stopGate.signal()
        }

        /// The device went away or changed, as the capture reports it, on a background
        /// queue.
        func move() {
            let moved = state.withLock { $0.moved }
            DispatchQueue.global().async {
                moved?()
            }
        }

        var source: MicrophoneCaptionSource {
            MicrophoneCaptionSource(access: { [self] in
                state.withLock {
                    $0.accessReads += 1
                    return $0.access
                }
            }, start: { [self] uid, deliver, moved in
                let (holds, fails, input) = state.withLock {
                    $0.calls.append("start")
                    $0.startedUIDs.append(uid)
                    if Thread.isMainThread {
                        $0.startedOnMain = true
                    }
                    return ($0.holdsStart, $0.fails, $0.input)
                }
                if holds {
                    // Bounded, so a broken test cannot hang, but long, since a busy runner
                    // can keep the main actor away from a test for many seconds.
                    _ = gate.wait(timeout: .now() + 120)
                }
                if let fails {
                    state.withLock { $0.calls.append("failed") }
                    throw fails
                }
                state.withLock {
                    $0.calls.append("started")
                    $0.deliver = deliver
                    $0.moved = moved
                }
                return input
            }, stop: { [self] in
                let holds = state.withLock {
                    $0.stopWaits = $0.holdsStop
                    return $0.holdsStop
                }
                if holds {
                    // Like a Bluetooth microphone that takes a moment to let go. Bounded, as a
                    // start that waits.
                    _ = stopGate.wait(timeout: .now() + 120)
                }
                state.withLock {
                    $0.stopWaits = false
                    $0.calls.append("stop")
                    $0.deliver = nil
                    $0.moved = nil
                }
            }, lidClosed: { [self] in
                state.withLock { $0.lidClosed }
            }, watchInputs: { [inputs] onChange in
                MainActor.assumeIsolated {
                    inputs.onChange = onChange
                    inputs.watches += 1
                }
                return inputs
            })
        }
    }

    /// The checks whether something plays come quickly in the tests, and their answers
    /// may take long, since a busy runner can keep the queue they run on waiting. The
    /// microphone's hold after a pause is off unless a test sets it, and its starts again
    /// and looks at access come quickly. The limit of starts again counts over ten minutes,
    /// since a busy runner can spread a test's moves over more than the app's 20 s.
    private func makeCaptions(
        _ models: FakeCaptionModels,
        source: FakeSource,
        events: Box,
        microphone: FakeCaptionMicrophone? = nil,
        displayMode: CaptionDisplayMode = .translationOnly,
        silenceHint: Double = 2,
        playCheckLimit: Double = 60,
        microphoneHold: Double = 0,
        microphoneQuietLimit: Double = 60,
        restartDelay: Double = 0.01
    ) -> MeetingCaptions {
        let captions = MeetingCaptions(
            systemAudio: source.source,
            microphone: microphone?.source ?? .unavailable,
            engines: models.engines(),
            started: { events.items.append("started") },
            stopped: { events.items.append("stopped") },
            displayMode: displayMode,
            pausesMicrophone: { events.pause },
            askForMicrophoneAccess: { events.asks += 1 },
            silenceHint: silenceHint,
            playCheckInterval: 0.05,
            playCheckLimit: playCheckLimit,
            microphoneHold: microphoneHold,
            microphoneQuietLimit: microphoneQuietLimit,
            restartDelay: restartDelay,
            restartWindow: 600,
            accessCheckInterval: 0.01
        )
        captions.showWindow = { events.items.append("show") }
        captions.closeWindow = { events.items.append("close") }
        return captions
    }

    @MainActor
    private final class Box {
        var items: [String] = []
        /// What holds microphone captions back, as AppDelegate reads it from a dictation.
        var pause = MeetingCaptions.MicrophonePause.notPaused
        /// How often the captions asked for microphone access.
        var asks = 0
    }

    /// Captions that listen to the microphone, on and listening, and the run of that start.
    private func listeningToTheMicrophone(_ captions: MeetingCaptions) async throws -> Int {
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        return captions.currentRun
    }

    private static let nothingPlays = "Nothing is playing on the Mac. Captions show what the Mac plays, such as a call or a video. To caption what you say, choose Microphone in the menu at the top left of the window."
    private static let permission = "No sound from the Mac yet. If something is playing, allow Orra under Screen & System Audio Recording in Privacy & Security settings."
    private static let captureFailed = "Orra could not capture the sound the Mac plays. Turn Live Captions off and on again to try again."

    @Test func turningOnStartsTheCaptureAndShowsTheWindow() async throws {
        let source = FakeSource()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: source, events: events)
        captions.setOn(true)
        #expect(captions.isOn)
        #expect(captions.capture == .starting)
        try await eventually { captions.capture == .listening }
        #expect(source.starts == 1)
        #expect(!source.startedOnMain)
        #expect(events.items == ["show", "started"])
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
    }

    @Test func turningOffKeepsTheCaptionsAndClosesTheWindow() async throws {
        let source = FakeSource()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello.", "Again."]), source: source, events: events)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        let run = captions.currentRun
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await eventually { captions.store.sentences.count == 1 }
        captions.setOn(false)
        // Kept until Orra quits, so the meeting can still be copied.
        #expect(captions.store.sentences.map(\.original) == ["Hello."])
        #expect(captions.store.hasFinalSentences)
        #expect(captions.capture == .off)
        try await eventually { source.stops == 1 }
        #expect(!source.isCapturing)
        #expect(events.items == ["show", "started", "stopped", "close"])
        // Samples still on their way from the capture are ignored.
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.map(\.original) == ["Hello."])
    }

    @Test func aStartMovesTheLastMeetingToThePreviousTranscript() async throws {
        let source = FakeSource()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone.", "Next slide please."]), source: source, events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(FakeCaptionModels.audio(sentences: 2), run: captions.currentRun)
        try await eventually { captions.store.sentences.compactMap(\.translatedText) == ["大家好。", "请看下一张幻灯片。"] }
        captions.setOn(false)
        // The window starts empty, and the meeting is kept unseen.
        captions.setOn(true)
        #expect(captions.store.sentences.isEmpty)
        #expect(!captions.store.hasFinalSentences)
        #expect(captions.store.previous.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        // A start with nothing said leaves the previous transcript alone.
        captions.setOn(false)
        captions.setOn(true)
        #expect(captions.store.previous.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        captions.setOn(false)
    }

    @Test func aShortStrayStartKeepsThePreviousMeeting() async throws {
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone.", "Hmm"]), source: FakeSource(), events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
        captions.setOn(false)
        // A stray start hears the start of a sentence, and stops before it ends.
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        let audio = CaptionAudio.silence(0.5) + CaptionAudio.tone(1.5)
        let chunk = RecordingLimits.sampleRate / 10
        for start in stride(from: 0, to: audio.count, by: chunk) {
            captions.receive(Array(audio[start..<min(audio.count, start + chunk)]), run: captions.currentRun)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await eventually { captions.store.sentences.first?.isInterim == true }
        captions.setOn(false)
        // The heard line can still be copied until the next start.
        #expect(captions.store.transcript.sentences.map(\.original) == ["Hmm"])
        captions.setOn(true)
        #expect(captions.store.previous.sentences.map(\.original) == ["Hello everyone."])
        captions.setOn(false)
    }

    @Test func aStopEndsAPendingTranslationWithoutOne() async throws {
        let models = FakeCaptionModels(["Hello everyone."])
        models.holdsTranslations = true
        let captions = makeCaptions(models, source: FakeSource(), events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { models.isHolding }
        #expect(captions.store.sentences.first?.translation == .pending)
        captions.setOn(false)
        #expect(captions.store.sentences.map(\.translation) == [.none])
        // The translation that comes after the stop changes nothing.
        models.letGo()
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.map(\.translation) == [.none])
        #expect(captions.store.transcript.text(.translation) == "Hello everyone.")
    }

    @Test func aStopKeepsTheLineStillBeingHeardAsAFinalSentence() async throws {
        let captions = makeCaptions(FakeCaptionModels(["Hello", "Hello everyone."]), source: FakeSource(), events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        // Like the capture, in 100 ms pieces, until the sentence shows as interim text.
        let audio = CaptionAudio.silence(0.5) + CaptionAudio.tone(1.5)
        let chunk = RecordingLimits.sampleRate / 10
        for start in stride(from: 0, to: audio.count, by: chunk) {
            captions.receive(Array(audio[start..<min(audio.count, start + chunk)]), run: captions.currentRun)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await eventually { captions.store.sentences.first?.isInterim == true }
        #expect(!captions.store.hasFinalSentences)
        captions.setOn(false)
        #expect(captions.store.sentences.map(\.original) == ["Hello"])
        #expect(captions.store.sentences.map(\.isInterim) == [false])
        #expect(captions.store.sentences.map(\.translation) == [.none])
        #expect(captions.store.hasFinalSentences)
    }

    @Test func copyingUsesTheDisplayModeUnlessAContentIsChosen() {
        var copies: [String] = []
        let store = CaptionStore()
        let captions = MeetingCaptions(systemAudio: FakeSource().source, engines: FakeCaptionModels([]).engines(), store: store, copyText: { copies.append($0) })
        #expect(!captions.copy(store.transcript))
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello everyone.", translation: .done("大家好。")))
        store.apply(CaptionSentence(id: 2, start: 1, end: 2, original: "Next slide", translation: .none, isInterim: true))
        #expect(captions.copy(store.transcript))
        captions.setDisplayMode(.originalAndTranslation)
        captions.copy(store.transcript)
        captions.copy(store.transcript, as: .original)
        #expect(copies == ["大家好。", "Hello everyone.\n大家好。", "Hello everyone."])
    }

    /// Original only does not load the local model, nor offer its download. A switch to a
    /// mode that translates asks for it once, and a switch back keeps it until the stop.
    @Test func originalOnlyAsksForTheModelOnlyAfterASwitchToTranslating() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please."])
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, displayMode: .originalOnly)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        #expect(events.items == ["show"])
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.count == 1 }
        #expect(captions.store.sentences.map(\.translation) == [.none])
        #expect(models.translated.isEmpty)
        captions.setDisplayMode(.originalAndTranslation)
        #expect(events.items == ["show", "started"])
        captions.setDisplayMode(.originalOnly)
        captions.setDisplayMode(.translationOnly)
        #expect(events.items == ["show", "started"])
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.last?.translatedText == "请看下一张幻灯片。" }
        // The sentence heard in Original only keeps its original.
        #expect(captions.store.sentences.first?.translation == CaptionSentence.Translation.none)
        captions.setOn(false)
        #expect(events.items == ["show", "started", "stopped", "close"])
        // The next start in Original only asks again only after a switch.
        captions.setDisplayMode(.originalOnly)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        #expect(events.items == ["show", "started", "stopped", "close", "show"])
        captions.setOn(false)
    }

    /// A switch while captions are off, or still starting, waits for the capture to run.
    @Test func aSwitchBeforeTheCaptureRunsAsksForTheModelOnceItDoes() async throws {
        let source = FakeSource()
        source.holdsStart = true
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events, displayMode: .originalOnly)
        captions.setDisplayMode(.originalAndTranslation)
        captions.setDisplayMode(.originalOnly)
        #expect(events.items.isEmpty)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        captions.setDisplayMode(.translationOnly)
        #expect(events.items == ["show"])
        source.releaseStart()
        try await eventually { captions.capture == .listening }
        #expect(events.items == ["show", "started"])
        captions.setOn(false)
    }

    @Test func aRefusedCaptureSaysSoInTheWindow() async throws {
        let source = FakeSource()
        source.fails = .notConfigured
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events)
        captions.setOn(true)
        #expect(captions.isOn)
        try await eventually { captions.capture == .unavailable(.notConfigured) }
        // The local model is not loaded for captions that cannot hear anything.
        #expect(events.items == ["show"])
    }

    @Test func aStartThatWaitsDoesNotHoldTheMainActor() async throws {
        let source = FakeSource()
        source.holdsStart = true
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events)
        captions.setOn(true)
        // setOn returned while the start still waits, as for the permission prompt.
        try await eventually { source.calls == ["start"] }
        #expect(captions.capture == .starting)
        #expect(events.items == ["show"])
        source.releaseStart()
        try await eventually { captions.capture == .listening }
        #expect(events.items == ["show", "started"])
        #expect(source.calls == ["start", "started"])
    }

    @Test func aStopDuringTheStartTearsDownWhatTheStartMade() async throws {
        let source = FakeSource()
        source.holdsStart = true
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        captions.setOn(false)
        #expect(!captions.isOn)
        #expect(captions.capture == .off)
        // The stop waits for the start, then removes what it made.
        #expect(source.calls == ["start"])
        source.releaseStart()
        try await eventually { source.calls == ["start", "started", "stop"] }
        #expect(!source.isCapturing)
        // The late outcome of the start changes nothing, and the local model is not
        // loaded for captions that are off.
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.capture == .off)
        #expect(events.items == ["show", "stopped", "close"])
    }

    @Test func aStopDuringAFailedStartLeavesCaptionsOff() async throws {
        let source = FakeSource()
        source.holdsStart = true
        source.fails = .failed(step: "start the device", status: -1)
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box())
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        captions.setOn(false)
        source.releaseStart()
        try await eventually { source.calls == ["start", "failed", "stop"] }
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.capture == .off)
    }

    @Test func offAndOnAgainDuringTheStartEndsListeningToTheLatestStart() async throws {
        let source = FakeSource()
        source.holdsStart = true
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello."]), source: source, events: events)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        captions.setOn(false)
        captions.setOn(true)
        #expect(captions.capture == .starting)
        source.holdsStart = false
        source.releaseStart()
        try await eventually { captions.capture == .listening }
        #expect(source.calls == ["start", "started", "stop", "start", "started"])
        #expect(source.isCapturing)
        #expect(events.items == ["show", "stopped", "close", "show", "started"])
        // Samples of the first start are ignored, those of the latest are captioned.
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun - 2)
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.count == 1)
    }

    @Test func onlyZerosSuggestThePermission() {
        let source = FakeSource()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box())
        captions.setOn(true)
        captions.receive(CaptionAudio.silence(1.5))
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(1))
        #expect(captions.silence == .noSound)
        captions.receive(CaptionAudio.tone(0.1))
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(5))
        #expect(captions.silence == nil)
    }

    /// A capture that delivers nothing at all, as while nothing plays, says so after the
    /// same time as one that delivers only zeros suggests the permission. Audio that comes
    /// later takes the note away, zeros that add up to the hint suggest the permission,
    /// and the first sound takes that away too.
    @Test func aCaptureThatDeliversNothingSaysNothingPlays() async throws {
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        try await eventually { captions.silence != nil }
        #expect(captions.silence == .noAudio)
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.silence == .noSound)
        captions.receive(CaptionAudio.tone(0.1), run: captions.currentRun)
        #expect(captions.silence == nil)
        captions.setOn(false)
    }

    /// Zeros that come before the hint, fewer than it, keep the note that nothing plays
    /// away, and suggest the permission once they add up to it.
    @Test func zerosBeforeTheHintNeverSayNothingPlays() async throws {
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        // Captions turned on later with the same hint say that nothing plays only after
        // these would have.
        let probe = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        probe.setOn(true)
        try await eventually { probe.silence == .noAudio }
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.silence == .noSound)
        probe.setOn(false)
        captions.setOn(false)
    }

    /// A start that still waits, as for the permission prompt or with tap auto start for
    /// the first sound the Mac plays, says that nothing plays after the same time.
    @Test func aStartThatStillWaitsSaysNothingPlays() async throws {
        let source = FakeSource()
        source.holdsStart = true
        defer { source.releaseStart() }
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        try await eventually { captions.silence == .noAudio }
        #expect(captions.capture == .starting)
        captions.setOn(false)
        #expect(captions.silence == nil)
    }

    /// The window tells the two apart. No audio at all says that nothing plays and what
    /// captions show, and samples of only zeros suggest the permission.
    @Test func theWindowTellsNothingPlayingFromOnlyZeros() async throws {
        let turns = EngineTurns()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).isEmpty)
        try await eventually { captions.silence == .noAudio }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [Self.nothingPlays])
        captions.receive(CaptionAudio.silence(0.2), run: captions.currentRun)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [Self.permission])
        captions.receive(CaptionAudio.tone(0.1), run: captions.currentRun)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).isEmpty)
        captions.setOn(false)
    }

    /// Something plays while the capture delivers no samples at all, as a refused
    /// permission may give, so the window suggests the permission after the hint, as for
    /// samples of only zeros. Core Audio is asked off the main thread, once. Zeros that
    /// come later keep the note, and the first sound takes it away.
    @Test func somethingPlayingWithNoAudioSuggestsThePermission() async throws {
        let source = FakeSource()
        source.holdsStart = true
        source.plays = [true]
        defer { source.releaseStart() }
        let turns = EngineTurns()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.silence != nil }
        #expect(captions.silence == .noSound)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [Self.permission])
        #expect(source.answers == [true])
        #expect(!source.checkedOnMain)
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.silence == .noSound)
        captions.receive(CaptionAudio.tone(0.1), run: captions.currentRun)
        #expect(captions.silence == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.answers == [true])
        captions.setOn(false)
    }

    /// When Core Audio cannot tell whether something plays, the window suggests the
    /// permission after the hint, as it did before Orra asked.
    @Test func noAnswerWhetherSomethingPlaysSuggestsThePermission() async throws {
        let source = FakeSource()
        source.plays = [nil]
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.silence != nil }
        #expect(captions.silence == .noSound)
        #expect(source.answers == [nil])
        captions.setOn(false)
    }

    /// A check that gets no answer within its limit counts as one that cannot tell, so
    /// an audio server that hangs does not leave the window without a note.
    @Test func aCheckWithoutAnAnswerInTimeSuggestsThePermission() async throws {
        let source = FakeSource()
        source.holdsPlayChecks = true
        defer { source.releasePlayChecks() }
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2, playCheckLimit: 0.2)
        captions.setOn(true)
        try await eventually { captions.silence != nil }
        #expect(captions.silence == .noSound)
        #expect(source.answers.isEmpty)
        captions.setOn(false)
    }

    /// While the window says that nothing plays, Orra asks again. Something that starts to
    /// play while still no samples come suggests the permission once two checks in a row
    /// find it playing, and no check follows.
    @Test func somethingThatStartsToPlayWithNoAudioSuggestsThePermission() async throws {
        let source = FakeSource()
        source.plays = [false, false, true, true]
        let turns = EngineTurns()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.silence == .noAudio }
        try await eventually { captions.silence == .noSound }
        #expect(source.answers == [false, false, true, true])
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [Self.permission])
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.answers.count == 4)
        captions.setOn(false)
    }

    /// Something that plays for one check only keeps the note that nothing plays, and the
    /// checks go on.
    @Test func somethingThatPlaysForOneCheckKeepsTheNote() async throws {
        let source = FakeSource()
        source.plays = [false, true, false]
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { source.answers.count >= 5 }
        #expect(captions.silence == .noAudio)
        #expect(Array(source.answers.prefix(5)) == [false, true, false, false, false])
        captions.setOn(false)
    }

    /// The first audio ends the checks, and so does turning captions off. A check under
    /// way may still answer.
    @Test func audioOrAStopEndsTheChecks() async throws {
        let source = FakeSource()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { source.answers.count >= 2 }
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.silence == nil)
        var checks = source.answers.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.answers.count <= checks + 1)
        captions.setOn(false)
        captions.setOn(true)
        try await eventually { source.answers.count >= checks + 3 }
        captions.setOn(false)
        checks = source.answers.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.answers.count <= checks + 1)
    }

    /// A start that fails once the window said that nothing plays leaves only the note
    /// that the capture failed, and the checks end.
    @Test func aStartThatFailsAfterTheNoteLeavesOnlyTheFailure() async throws {
        let source = FakeSource()
        source.holdsStart = true
        source.fails = .failed(step: "start the device", status: -1)
        let turns = EngineTurns()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.silence == .noAudio }
        source.releaseStart()
        try await eventually { captions.capture == .unavailable(.failed(step: "start the device", status: -1)) }
        #expect(captions.silence == nil)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [Self.captureFailed])
        let checks = source.answers.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.answers.count <= checks + 1)
        captions.setOn(false)
    }

    /// A start that failed has its own note, and no note about silence follows it, neither
    /// in the window nor in the log.
    @Test func aFailedStartGetsNoSilenceNote() async throws {
        let source = FakeSource()
        source.fails = .failed(step: "start the device", status: -1)
        let failed = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        failed.setOn(true)
        try await eventually { failed.capture == .unavailable(.failed(step: "start the device", status: -1)) }
        // Captions that start, turned on later with the same hint, say that nothing plays
        // only after the failed ones would have.
        let probe = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        probe.setOn(true)
        try await eventually { probe.silence == .noAudio }
        #expect(failed.silence == nil)
        probe.setOn(false)
        failed.setOn(false)
    }

    /// A sound before the hint keeps both notes away, also once the hint has passed with
    /// no sound since.
    @Test func aSoundBeforeTheHintGetsNoSilenceNote() async throws {
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        captions.receive(CaptionAudio.tone(0.1), run: captions.currentRun)
        // Captions turned on later with the same hint say that nothing plays only after
        // these would have.
        let probe = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        probe.setOn(true)
        try await eventually { probe.silence == .noAudio }
        #expect(captions.silence == nil)
        probe.setOn(false)
        captions.setOn(false)
    }

    /// Off and on again starts the hint over. The stop ends the check of the first run at
    /// once, and that check says nothing in the second run.
    @Test func offAndOnAgainStartsTheSilenceHintOver() async throws {
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 60)
        captions.setOn(true)
        captions.setOn(false)
        captions.setOn(true)
        // Captions turned on later with a short hint say that nothing plays only after the
        // ended check has run.
        let probe = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.1)
        probe.setOn(true)
        try await eventually { probe.silence == .noAudio }
        #expect(captions.silence == nil)
        probe.setOn(false)
        captions.setOn(false)
    }

    /// From the press of a key until the paste, captions start no model call, see
    /// EngineTurns. Once the dictation has gone on for a moment, the window says that
    /// they wait and catch up after it, but not for captions that cannot hear anything.
    @Test func captionsSayTheyWaitWhileADictationRuns() async throws {
        let turns = EngineTurns(noteDelay: .milliseconds(100))
        let waits = "Captions wait while you dictate and catch up when you finish."
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        #expect(!CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        turns.dictationStarted()
        // Not at once, since a tap of the talk key holds the captions for a moment too.
        #expect(!CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        try await eventually { CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits) }
        turns.dictationEnded()
        #expect(!CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        captions.setOn(false)
        let source = FakeSource()
        source.fails = .failed(step: "start the device", status: -1)
        let failed = makeCaptions(FakeCaptionModels([]), source: source, events: Box())
        failed.setOn(true)
        try await eventually { failed.capture == .unavailable(.failed(step: "start the device", status: -1)) }
        turns.dictationStarted()
        try await eventually { turns.dictationNoteDue }
        #expect(!CaptionNotes.lines(captions: failed, speechReady: true, turns: turns).contains(waits))
        turns.dictationEnded()
        failed.setOn(false)
    }

    @Test func theDisplayModeIsSaved() {
        var saved: [CaptionDisplayMode] = []
        let captions = MeetingCaptions(systemAudio: FakeSource().source, engines: FakeCaptionModels([]).engines(), saveDisplayMode: { saved.append($0) })
        #expect(captions.displayMode == .translationOnly)
        captions.setDisplayMode(.originalAndTranslation)
        captions.setDisplayMode(.originalAndTranslation)
        #expect(saved == [.originalAndTranslation])
    }

    @Test func theDisplayModeIsReadBack() throws {
        try withTestDefaults("caption") { defaults in
            #expect(CaptionDisplayMode.load(from: defaults) == .translationOnly)
            CaptionDisplayMode.originalAndTranslation.save(to: defaults)
            #expect(CaptionDisplayMode.load(from: defaults) == .originalAndTranslation)
            CaptionDisplayMode.originalOnly.save(to: defaults)
            #expect(CaptionDisplayMode.load(from: defaults) == .originalOnly)
            // The values saved before Original only came stay as they were.
            #expect(CaptionDisplayMode.translationOnly.rawValue == "translationOnly")
            #expect(CaptionDisplayMode.originalAndTranslation.rawValue == "originalAndTranslation")
            defaults.set("somethingNewer", forKey: CaptionDisplayMode.defaultsKey)
            #expect(CaptionDisplayMode.load(from: defaults) == .translationOnly)
        }
    }

    // MARK: The microphone

    /// Every new MeetingCaptions listens to what the Mac plays, and nothing of the
    /// microphone is used or asked until the user chooses it.
    @Test func captionsListenToWhatTheMacPlaysAtFirst() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), microphone: microphone)
        #expect(captions.source == .systemAudio)
        #expect(CaptionSource.allCases == [.systemAudio, .microphone])
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        #expect(source.starts == 1)
        #expect(captions.microphoneInUse == nil)
        captions.setOn(false)
        try await eventually { source.stops == 1 }
        #expect(microphone.calls.isEmpty)
        #expect(microphone.accessReads == 0)
    }

    /// The prompt follows the user's own choice of the microphone, only while access is not
    /// decided. Turning captions on never asks.
    @Test(arguments: [MicrophoneAccess.notDetermined, .denied, .authorized, .notConfigured])
    func choosingTheMicrophoneAsksForAccessOnlyWhenNotDecided(access: MicrophoneAccess) async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.access = access
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone)
        captions.setOn(true)
        captions.setOn(false)
        #expect(events.asks == 0)
        captions.setSource(.microphone)
        #expect(events.asks == (access == .notDetermined ? 1 : 0))
        captions.setSource(.microphone)
        captions.setOn(true)
        captions.setOn(false)
        #expect(events.asks == (access == .notDetermined ? 1 : 0))
    }

    @Test func turningOnWithTheMicrophoneListensToItOffTheMainActor() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events, microphone: microphone)
        captions.microphoneChosen("usb-1")
        captions.setSource(.microphone)
        #expect(microphone.calls.isEmpty)
        captions.setOn(true)
        #expect(captions.capture == .starting)
        try await eventually { captions.capture == .listening }
        #expect(microphone.startedUIDs == ["usb-1"])
        #expect(!microphone.startedOnMain)
        #expect(captions.microphoneInUse == microphone.input)
        #expect(source.calls.isEmpty)
        #expect(events.items == ["show", "started"])
        captions.setOn(false)
    }

    /// A switch while captions are on changes only the capture: the meeting, its window and
    /// its sentences go on, and the model is not asked for again.
    @Test func aSwitchWhileOnKeepsTheMeetingAndTheWindow() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone.", "Next slide please."]), source: source, events: events, microphone: microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
        let previous = captions.store.previous
        captions.setSource(.microphone)
        try await eventually { captions.capture == .listening && microphone.calls == ["start", "started"] }
        try await eventually { source.stops == 1 }
        #expect(events.items == ["show", "started"])
        #expect(captions.store.previous == previous)
        #expect(captions.store.sentences.map(\.original) == ["Hello everyone."])
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.last?.translatedText == "请看下一张幻灯片。" }
        #expect(captions.store.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        captions.setOn(false)
        #expect(events.items == ["show", "started", "stopped", "close"])
    }

    @Test func turningOffOrChoosingTheMacLetsGoOfTheMicrophoneAtOnce() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: source, events: Box(), microphone: microphone)
        var run = try await listeningToTheMicrophone(captions)
        captions.setOn(false)
        #expect(captions.microphoneInUse == nil)
        try await eventually { microphone.stops == 1 }
        #expect(!microphone.isCapturing)
        // Samples still on their way from the microphone are ignored.
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        run = captions.currentRun
        captions.setSource(.systemAudio)
        #expect(captions.microphoneInUse == nil)
        try await eventually { microphone.stops == 2 && source.starts == 1 }
        #expect(!microphone.isCapturing)
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.isEmpty)
        captions.setOn(false)
    }

    /// A switch never waits for a start of the other capture, such as one that waits for
    /// the permission prompt. That start's outcome is ignored, and its stop follows it.
    @Test func aSwitchDoesNotWaitForAStartOfTheOtherSource() async throws {
        let source = FakeSource()
        source.holdsStart = true
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events, microphone: microphone)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        captions.setSource(.microphone)
        try await eventually { captions.capture == .listening }
        #expect(microphone.calls == ["start", "started"])
        #expect(captions.microphoneInUse == microphone.input)
        source.releaseStart()
        try await eventually { source.calls == ["start", "started", "stop"] }
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.capture == .listening)
        #expect(captions.microphoneInUse == microphone.input)
        #expect(events.items == ["show", "started"])
        captions.setOn(false)
    }

    @Test(arguments: [MicrophoneAccess.denied, .notDetermined, .notConfigured])
    func withoutAccessTheWindowSaysSoAndNothingStarts(access: MicrophoneAccess) async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.access = access
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone, silenceHint: 0.1)
        captions.setSource(.microphone)
        captions.setOn(true)
        #expect(captions.capture == .microphoneUnavailable(.access(access)))
        let note = switch access {
        case .denied: "Microphone access is off. Turn on Orra under Microphone in System Settings."
        case .notDetermined: "The microphone needs permission"
        default: "This build has no microphone usage description"
        }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == [note])
        try await Task.sleep(for: .milliseconds(200))
        #expect(microphone.starts == 0)
        #expect(captions.silence == nil)
        #expect(captions.microphoneInUse == nil)
        // The local model is not loaded for captions that cannot hear anything.
        #expect(events.items == ["show"])
        captions.setOn(false)
    }

    /// Access given while captions wait for it starts the microphone, as after a click on
    /// Allow in the prompt or a switch in System Settings.
    @Test func theMicrophoneStartsOnceAccessIsGiven() async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.access = .denied
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        #expect(captions.capture == .microphoneUnavailable(.access(.denied)))
        microphone.access = .notDetermined
        try await eventually { captions.capture == .microphoneUnavailable(.access(.notDetermined)) }
        #expect(microphone.starts == 0)
        microphone.access = .authorized
        try await eventually { captions.capture == .listening }
        #expect(microphone.starts == 1)
        captions.setOn(false)
    }

    /// Access given after captions were turned off, or switched to what the Mac plays,
    /// never opens the microphone.
    @Test func accessGivenLaterOpensNothingForCaptionsThatMovedOn() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        microphone.access = .denied
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        captions.setOn(false)
        captions.setOn(true)
        captions.setSource(.systemAudio)
        try await eventually { captions.capture == .listening }
        microphone.access = .authorized
        try await Task.sleep(for: .milliseconds(200))
        #expect(microphone.starts == 0)
        #expect(source.starts == 1)
        captions.setOn(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(microphone.starts == 0)
    }

    /// The press of a key until the paste: what the microphone hears meanwhile never reaches
    /// the models, the sentence before the press ends, and captions go on after it.
    @Test func aDictationPausesMicrophoneCaptionsAndTheyGoOnAfterIt() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please."])
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, microphone: FakeCaptionMicrophone())
        let run = try await listeningToTheMicrophone(captions)
        // Speech with no pause after it yet.
        captions.receive(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.7), run: run)
        events.pause = .paused
        // The dictation, louder, so it shows if it ever reaches a model.
        captions.receive(CaptionAudio.tone(1, amplitude: 0.3), run: run)
        events.pause = .notPaused
        // Right after it: without the cut this would go on the sentence before the press.
        captions.receive(CaptionAudio.tone(0.7) + CaptionAudio.silence(1), run: run)
        try await eventually { captions.store.sentences.compactMap(\.translatedText).count == 2 }
        #expect(captions.store.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        #expect(models.transcribed == 2)
        #expect(models.heard.allSatisfy { samples in samples.allSatisfy { abs($0) <= 0.1 } })
        captions.setOn(false)
    }

    /// What arrives within the hold after a pause, such as the end of Orra's voice from the
    /// speakers, is left out too, and the captions go on once it has passed.
    @Test func whatArrivesRightAfterAPauseIsLeftOutToo() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please."])
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, microphone: FakeCaptionMicrophone(), microphoneHold: 0.3)
        let run = try await listeningToTheMicrophone(captions)
        captions.receive(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.7), run: run)
        events.pause = .paused
        captions.receive(CaptionAudio.tone(0.5, amplitude: 0.3), run: run)
        events.pause = .notPaused
        captions.receive(CaptionAudio.tone(0.5, amplitude: 0.3), run: run)
        try await Task.sleep(for: .milliseconds(350))
        captions.receive(CaptionAudio.tone(0.7) + CaptionAudio.silence(1), run: run)
        try await eventually { captions.store.sentences.compactMap(\.translatedText).count == 2 }
        #expect(captions.store.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        #expect(models.heard.allSatisfy { samples in samples.allSatisfy { abs($0) <= 0.1 } })
        captions.setOn(false)
    }

    /// A key that waits, such as right Option, records nothing for captions until its press
    /// counts. A press that turns out to be a shortcut leaves nothing out and cuts nothing.
    @Test func aKeyThatTurnsOutToBeAShortcutLeavesNothingOut() async throws {
        let models = FakeCaptionModels(["One sentence."])
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, microphone: FakeCaptionMicrophone())
        let run = try await listeningToTheMicrophone(captions)
        captions.receive(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.5), run: run)
        events.pause = .arming
        captions.receive(CaptionAudio.tone(0.3), run: run)
        try await Task.sleep(for: .milliseconds(30))
        #expect(models.transcribed == 0)
        events.pause = .notPaused
        captions.receive(CaptionAudio.silence(1), run: run)
        try await eventually { captions.store.sentences.first.map { !$0.isInterim && $0.translation != .pending } == true }
        #expect(models.transcribed == 1)
        // One sentence: the preroll, 0.8 s of speech and the tail.
        let heard = try #require(models.heard.first)
        #expect(abs(Double(heard.count) / CaptionAudio.rate - 1.15) < 0.03)
        captions.setOn(false)
    }

    /// A press that counts makes what its key heard part of the dictation, left out like the
    /// rest of it.
    @Test func aKeyWhosePressCountsLeavesOutWhatItHeard() async throws {
        let models = FakeCaptionModels(["Hello everyone.", "Next slide please."])
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, microphone: FakeCaptionMicrophone())
        let run = try await listeningToTheMicrophone(captions)
        captions.receive(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.7), run: run)
        events.pause = .arming
        captions.receive(CaptionAudio.tone(0.3, amplitude: 0.3), run: run)
        events.pause = .paused
        captions.receive(CaptionAudio.tone(0.5, amplitude: 0.3), run: run)
        events.pause = .notPaused
        captions.receive(CaptionAudio.tone(0.7) + CaptionAudio.silence(1), run: run)
        try await eventually { captions.store.sentences.compactMap(\.translatedText).count == 2 }
        #expect(captions.store.sentences.map(\.original) == ["Hello everyone.", "Next slide please."])
        #expect(models.heard.allSatisfy { samples in samples.allSatisfy { abs($0) <= 0.1 } })
        captions.setOn(false)
    }

    /// Turning captions off while a key that waits is down, as with the Live Captions
    /// shortcut or the window's close button, drops what the key held back, so no audio of
    /// the microphone stays in memory after a stop.
    @Test func aStopDropsWhatAKeyThatWaitsHeldBack() async throws {
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: FakeCaptionMicrophone())
        let run = try await listeningToTheMicrophone(captions)
        events.pause = .arming
        captions.receive(CaptionAudio.tone(0.3), run: run)
        #expect(abs(captions.heldMicrophoneSeconds - 0.3) < 0.01)
        captions.setOn(false)
        #expect(captions.heldMicrophoneSeconds == 0)
    }

    /// A dictation pauses captions of the microphone only. What the Mac plays waits and
    /// catches up, see EngineTurns, and nothing of it is left out.
    @Test func thePauseHoldsOnlyMicrophoneCaptions() async throws {
        let events = Box()
        events.pause = .paused
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: FakeSource(), events: events)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
        captions.setOn(false)
    }

    /// Captions never set up the microphone while a dictation holds it. The start waits
    /// until the dictation is over, and a stop meanwhile starts nothing.
    @Test func aStartOfTheMicrophoneWaitsForADictationToEnd() async throws {
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        events.pause = .paused
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        #expect(captions.capture == .starting)
        try await Task.sleep(for: .milliseconds(250))
        #expect(microphone.starts == 0)
        events.pause = .notPaused
        try await eventually { captions.capture == .listening }
        #expect(microphone.starts == 1)
        captions.setOn(false)
        events.pause = .paused
        captions.setOn(true)
        captions.setOn(false)
        events.pause = .notPaused
        try await Task.sleep(for: .milliseconds(250))
        #expect(microphone.starts == 1)
    }

    /// A start again that waits behind the stop of the unit before it looks at the pause
    /// once that stop is done, so a press that came meanwhile holds it too, and captions
    /// start no unit during the dictation.
    @Test func aStartBehindAStopWaitsForADictationThatBeganMeanwhile() async throws {
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone)
        _ = try await listeningToTheMicrophone(captions)
        microphone.holdsStop = true
        captions.microphoneChosen("usb-2")
        try await eventually { microphone.stopWaits }
        events.pause = .paused
        microphone.holdsStop = false
        microphone.releaseStop()
        try await eventually { microphone.stops == 1 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(microphone.starts == 1)
        #expect(captions.capture == .starting)
        events.pause = .notPaused
        try await eventually { microphone.starts == 2 && captions.capture == .listening }
        #expect(microphone.startedUIDs == [nil, "usb-2"])
        captions.setOn(false)
    }

    /// A start already under way at the press completes, since a unit cannot stop halfway
    /// through its start. The window shows that the microphone is on, and what it hears
    /// during the dictation is left out.
    @Test func aStartUnderWayAtThePressCompletesAndLeavesTheDictationOut() async throws {
        let models = FakeCaptionModels(["Next slide please."])
        let microphone = FakeCaptionMicrophone()
        microphone.holdsStart = true
        let events = Box()
        let captions = makeCaptions(models, source: FakeSource(), events: events, microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { microphone.calls == ["start"] }
        events.pause = .paused
        microphone.holdsStart = false
        microphone.releaseStart()
        try await eventually { captions.capture == .listening }
        #expect(captions.microphoneInUse == microphone.input)
        let run = captions.currentRun
        // The dictation, louder, so it shows if it ever reaches a model.
        captions.receive(CaptionAudio.tone(1, amplitude: 0.3), run: run)
        events.pause = .notPaused
        captions.receive(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.7) + CaptionAudio.silence(1), run: run)
        try await eventually { captions.store.sentences.compactMap(\.translatedText) == ["请看下一张幻灯片。"] }
        #expect(models.transcribed == 1)
        #expect(models.heard.allSatisfy { samples in samples.allSatisfy { abs($0) <= 0.1 } })
        captions.setOn(false)
    }

    /// A start that waits for a dictation, and a start again for a wake or a new choice
    /// that comes meanwhile, start the microphone once, not once and then again, which would
    /// switch a Bluetooth headset's profile twice.
    @Test func aStartAgainWhileAStartWaitsStartsTheMicrophoneOnce() async throws {
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        events.pause = .paused
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone, restartDelay: 0.3)
        captions.setSource(.microphone)
        captions.setOn(true)
        captions.macDidWake()
        events.pause = .notPaused
        try await eventually { captions.capture == .listening }
        try await Task.sleep(for: .milliseconds(500))
        #expect(microphone.starts == 1)
        #expect(captions.capture == .listening)
        captions.setOn(false)
    }

    @Test func microphoneCaptionsTranslateLikeTheMacs() async throws {
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: FakeSource(), events: events, microphone: FakeCaptionMicrophone())
        let run = try await listeningToTheMicrophone(captions)
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
        #expect(events.items == ["show", "started"])
        captions.setOn(false)
    }

    /// The microphone gets no note about what plays and never asks Core Audio. No sound
    /// since its start, or none for the quiet limit after some, names the device, and the
    /// first sound takes the note away.
    @Test func microphoneCaptionsAskNothingAboutWhatPlays() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), microphone: microphone, silenceHint: 0.2, microphoneQuietLimit: 0.5)
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .listening && captions.silence != nil }
        let silent = MeetingCaptions.SilenceKind.microphoneSilent(MicrophoneSituation(lidClosed: false, input: microphone.input))
        #expect(captions.silence == silent)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == ["No sound came from USB Microphone"])
        let run = captions.currentRun
        captions.receive(CaptionAudio.tone(0.1), run: run)
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(0.4), run: run)
        #expect(captions.silence == nil)
        captions.receive(CaptionAudio.silence(0.1), run: run)
        #expect(captions.silence == silent)
        captions.receive(CaptionAudio.tone(0.1), run: run)
        #expect(captions.silence == nil)
        #expect(source.answers.isEmpty)
        captions.setOn(false)
        // Quiet samples from the start, with the lid closed and the built in microphone.
        microphone.lidClosed = true
        microphone.input = AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.receive(CaptionAudio.silence(0.2), run: captions.currentRun)
        #expect(captions.silence == .microphoneSilent(MicrophoneSituation(lidClosed: true, input: microphone.input)))
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == ["The lid is closed, so the built in microphone is off"])
        #expect(source.answers.isEmpty)
        #expect(source.calls.isEmpty)
        captions.setOn(false)
    }

    /// A device that went away or changed starts the microphone again after the delay, in
    /// the same meeting. Samples of the earlier start are ignored, and while a dictation
    /// holds the microphone, the start waits for its end.
    @Test func aMicrophoneThatMovesStartsAgainInTheSameMeeting() async throws {
        let microphone = FakeCaptionMicrophone()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: FakeSource(), events: events, microphone: microphone, restartDelay: 0.05)
        let first = try await listeningToTheMicrophone(captions)
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: first)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
        microphone.move()
        try await eventually { microphone.calls == ["start", "started", "stop", "start", "started"] }
        try await eventually { captions.currentRun != first && captions.capture == .listening }
        #expect(events.items == ["show", "started"])
        #expect(captions.store.sentences.count == 1)
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: first)
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.count == 1)
        events.pause = .paused
        microphone.move()
        try await Task.sleep(for: .milliseconds(250))
        #expect(microphone.starts == 2)
        events.pause = .notPaused
        try await eventually { microphone.starts == 3 && captions.capture == .listening }
        captions.setOn(false)
    }

    /// A microphone that keeps moving, as a headset might that changes its profile at each
    /// start, starts again a few times only. Then captions let go of it and say that it
    /// could not start, until the user turns them off and on.
    @Test func aMicrophoneThatKeepsMovingIsLetGo() async throws {
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: microphone)
        _ = try await listeningToTheMicrophone(captions)
        let limit = MeetingCaptions.restartLimit
        for starts in 2...(limit + 1) {
            microphone.move()
            try await eventually { microphone.starts == starts && captions.capture == .listening }
        }
        microphone.move()
        try await eventually { captions.capture == .microphoneUnavailable(.failed(step: "follow the microphone", status: 0)) }
        try await eventually { microphone.stops == limit + 1 }
        #expect(!microphone.isCapturing)
        #expect(captions.microphoneInUse == nil)
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == ["Orra could not start the microphone. Turn Live Captions off and on again to try again."])
        // No change of the devices starts it again.
        #expect(microphone.inputs.watches == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(microphone.starts == limit + 1)
        // Turning captions off and on starts it, and counts the moves from nothing.
        captions.setOn(false)
        captions.setOn(true)
        try await eventually { captions.capture == .listening && microphone.starts == limit + 2 }
        for starts in (limit + 3)...(2 * limit + 2) {
            microphone.move()
            try await eventually { microphone.starts == starts && captions.capture == .listening }
        }
        captions.setOn(false)
    }

    @Test func aNewMicrophoneChoiceStartsTheMicrophoneAgain() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), microphone: microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.microphoneChosen("usb-2")
        try await Task.sleep(for: .milliseconds(50))
        #expect(microphone.calls.isEmpty)
        #expect(source.calls == ["start", "started"])
        captions.setSource(.microphone)
        try await eventually { microphone.startedUIDs == ["usb-2"] && captions.capture == .listening }
        captions.microphoneChosen("usb-3")
        try await eventually { microphone.startedUIDs == ["usb-2", "usb-3"] && captions.capture == .listening }
        captions.microphoneChosen("usb-3")
        captions.microphoneChosen(nil)
        try await eventually { microphone.startedUIDs == ["usb-2", "usb-3", nil] }
        captions.setOn(false)
    }

    @Test func wakeStartsTheMicrophoneAgainButNotTheMac() async throws {
        let source = FakeSource()
        let microphone = FakeCaptionMicrophone()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), microphone: microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        captions.macDidWake()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.calls == ["start", "started"])
        captions.setSource(.microphone)
        try await eventually { captions.capture == .listening && microphone.starts == 1 }
        captions.macDidWake()
        try await eventually { microphone.starts == 2 && captions.capture == .listening }
        #expect(microphone.calls == ["start", "started", "stop", "start", "started"])
        captions.setOn(false)
    }

    @Test func aMicrophoneThatFailsToStartSaysSo() async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.fails = .failed(step: "start the input unit", status: -1)
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: events, microphone: microphone, silenceHint: 0.1)
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .microphoneUnavailable(.failed(step: "start the input unit", status: -1)) }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == ["Orra could not start the microphone. Turn Live Captions off and on again to try again."])
        try await Task.sleep(for: .milliseconds(200))
        #expect(captions.silence == nil)
        #expect(captions.microphoneInUse == nil)
        #expect(events.items == ["show"])
        captions.setOn(false)
    }

    /// A start that failed, such as on AirPods whose input was not ready yet, is tried again
    /// at the next change of the devices.
    @Test func aMicrophoneThatFailedToStartTriesAgainWhenTheDevicesChange() async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.fails = .failed(step: "start the input unit", status: -1)
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .microphoneUnavailable(.failed(step: "start the input unit", status: -1)) }
        try #require(microphone.inputs.watches == 1)
        microphone.fails = nil
        microphone.inputs.onChange?()
        try await eventually { captions.capture == .listening }
        #expect(microphone.starts == 2)
        #expect(captions.microphoneInUse == microphone.input)
        captions.setOn(false)
    }

    /// No microphone at all says so, and one plugged in later is used.
    @Test func aMicrophonePluggedInLaterIsUsed() async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.fails = .noInput
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: microphone)
        captions.setSource(.microphone)
        captions.setOn(true)
        try await eventually { captions.capture == .microphoneUnavailable(.noInput) }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: EngineTurns()) == ["No microphone is connected. Captions start once you connect one."])
        #expect(microphone.inputs.watches == 1)
        microphone.fails = nil
        microphone.inputs.onChange?()
        try await eventually { captions.capture == .listening }
        #expect(captions.microphoneInUse == microphone.input)
        captions.setOn(false)
    }

    /// Once a dictation has gone on for a moment, the window says what becomes of the
    /// captions: those of the microphone pause, those of the Mac wait and catch up.
    @Test func theDictationNoteSaysCaptionsPauseForTheMicrophone() async throws {
        let turns = EngineTurns(noteDelay: .milliseconds(10))
        let pause = "Captions pause while you dictate and go on when you finish."
        let wait = "Captions wait while you dictate and catch up when you finish."
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: FakeCaptionMicrophone(), silenceHint: 60)
        _ = try await listeningToTheMicrophone(captions)
        turns.dictationStarted()
        try await eventually { turns.dictationNoteDue }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [pause])
        captions.setSource(.systemAudio)
        try await eventually { captions.capture == .listening }
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns) == [wait])
        turns.dictationEnded()
        captions.setOn(false)
    }

    /// The window's sign that the microphone is on shows only while captions listen to it.
    @Test func theMicrophoneSignShowsOnlyWhileItListens() async throws {
        let microphone = FakeCaptionMicrophone()
        microphone.holdsStart = true
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), microphone: microphone)
        captions.setSource(.microphone)
        #expect(captions.microphoneInUse == nil)
        captions.setOn(true)
        try await eventually { microphone.calls == ["start"] }
        #expect(captions.capture == .starting)
        #expect(captions.microphoneInUse == nil)
        microphone.holdsStart = false
        microphone.releaseStart()
        try await eventually { captions.capture == .listening }
        #expect(captions.microphoneInUse == microphone.input)
        captions.setSource(.systemAudio)
        #expect(captions.microphoneInUse == nil)
        captions.setSource(.microphone)
        try await eventually { captions.microphoneInUse == microphone.input }
        captions.setOn(false)
        #expect(captions.microphoneInUse == nil)
        microphone.access = .denied
        captions.setOn(true)
        #expect(captions.microphoneInUse == nil)
        captions.setOn(false)
    }

    /// The press of any key that starts a dictation pauses the microphone until the paste or
    /// the cancel, and so do a voice sample and Orra's voice. A key that waits holds the
    /// microphone's audio back until its press counts.
    @Test func theMicrophonePausesFromThePressUntilTheDictationIsOver() {
        typealias Pause = MeetingCaptions.MicrophonePause
        #expect(Pause(dictation: .idle, recordsVoiceSample: false, speaks: false) == .notPaused)
        #expect(Pause(dictation: .arming, recordsVoiceSample: false, speaks: false) == .arming)
        for state in [PushToTalkStateMachine.State.listening, .waitingForSecondPress, .handsFree, .processing] {
            #expect(Pause(dictation: state, recordsVoiceSample: false, speaks: false) == .paused)
        }
        #expect(Pause(dictation: .idle, recordsVoiceSample: true, speaks: false) == .paused)
        #expect(Pause(dictation: .idle, recordsVoiceSample: false, speaks: true) == .paused)
        #expect(Pause(dictation: .arming, recordsVoiceSample: false, speaks: true) == .paused)
    }
}

struct CaptionDisplayTests {
    private func sentence(_ translation: CaptionSentence.Translation) -> CaptionSentence {
        CaptionSentence(id: 1, start: 0, end: 1, original: "我们开始吧。", translation: translation)
    }

    @Test func translationOnlyShowsTheOriginalUntilTheTranslationReplacesIt() {
        let mode = CaptionDisplayMode.translationOnly
        #expect(mode.lines(for: sentence(.pending)) == [.init(text: "我们开始吧。", style: .secondary)])
        #expect(mode.lines(for: sentence(.done("Let's begin."))) == [.init(text: "Let's begin.", style: .main)])
        #expect(mode.lines(for: sentence(.none)) == [.init(text: "我们开始吧。", style: .main)])
    }

    @Test func originalOnlyShowsTheOriginalWhateverItsTranslation() {
        let mode = CaptionDisplayMode.originalOnly
        #expect(!mode.translates)
        #expect(CaptionDisplayMode.allCases.filter(\.translates) == [.translationOnly, .originalAndTranslation])
        #expect(CaptionDisplayMode.allCases.first == .originalOnly)
        for translation in [CaptionSentence.Translation.pending, .done("Let's begin."), .none] {
            #expect(mode.lines(for: sentence(translation)) == [.init(text: "我们开始吧。", style: .main)])
        }
    }

    @Test func bothShowTheOriginalAndTheTranslationJoinsIt() {
        let mode = CaptionDisplayMode.originalAndTranslation
        #expect(mode.lines(for: sentence(.pending)) == [.init(text: "我们开始吧。", style: .secondary)])
        #expect(mode.lines(for: sentence(.done("Let's begin."))) == [.init(text: "我们开始吧。", style: .secondary), .init(text: "Let's begin.", style: .main)])
        #expect(mode.lines(for: sentence(.none)) == [.init(text: "我们开始吧。", style: .main)])
    }

    @Test @MainActor func theStoreKeepsTheLatestSentencesOnly() {
        let store = CaptionStore(limit: 3)
        for id in 1...5 {
            store.apply(CaptionSentence(id: id, start: Double(id), end: Double(id) + 1, original: "\(id)", translation: .pending))
        }
        #expect(store.sentences.map(\.id) == [3, 4, 5])
        #expect(store.droppedOldest)
        #expect(!store.hasTranslation)
        store.apply(CaptionSentence(id: 4, start: 4, end: 5, original: "4", translation: .done("four")))
        #expect(store.sentences.map(\.id) == [3, 4, 5])
        #expect(store.sentences[1].translatedText == "four")
        #expect(store.hasTranslation)
        store.startOver()
        #expect(store.sentences.isEmpty)
        #expect(!store.droppedOldest)
        #expect(!store.hasTranslation)
    }

    @Test @MainActor func theWindowDrawsTheLast500WhileTheCopyHoldsMore() {
        let store = CaptionStore()
        #expect(CaptionStore.limit == 10_000)
        for id in 1...600 {
            store.apply(CaptionSentence(id: id, start: Double(id), end: Double(id) + 1, original: "\(id)", translation: .none))
        }
        #expect(store.shown.count == 500)
        #expect(store.shown.first?.id == 101)
        #expect(store.shown.last?.id == 600)
        #expect(store.transcript.sentences.count == 600)
        #expect(!store.droppedOldest)
    }

    @Test @MainActor func settlingKeepsTheHeardLineAndEndsPendingTranslations() {
        let store = CaptionStore()
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello everyone.", translation: .done("大家好。")))
        store.apply(CaptionSentence(id: 2, start: 1, end: 2, original: "Next slide please.", translation: .pending))
        store.apply(CaptionSentence(id: 3, start: 2, end: 3, original: "That sounds good.", translation: .none))
        store.apply(CaptionSentence(id: 4, start: 3, end: 4, original: "so the next", translation: .none, isInterim: true))
        store.settle()
        #expect(store.sentences.map(\.translation) == [.done("大家好。"), .none, .none, .none])
        #expect(store.sentences.map(\.isInterim) == [false, false, false, false])
        #expect(store.sentences.map(\.original) == ["Hello everyone.", "Next slide please.", "That sounds good.", "so the next"])
    }

    @Test @MainActor func startingOverKeepsOnlyAMeetingWithFinalSentences() {
        let store = CaptionStore()
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hello everyone.", translation: .done("大家好。")))
        store.apply(CaptionSentence(id: 2, start: 1, end: 2, original: "Next", translation: .none, isInterim: true))
        #expect(store.hasFinalSentences)
        store.startOver()
        #expect(store.sentences.isEmpty)
        #expect(!store.hasFinalSentences)
        // Only the final sentence, as a copy has it.
        #expect(store.previous.sentences.map(\.original) == ["Hello everyone."])
        // An interim line alone is nothing to keep, so the previous meeting stays. Also
        // when the stop made it final.
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hmm", translation: .none, isInterim: true))
        #expect(!store.hasFinalSentences)
        store.startOver()
        #expect(store.previous.sentences.map(\.original) == ["Hello everyone."])
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Hmm", translation: .none, isInterim: true))
        store.settle()
        #expect(store.hasFinalSentences)
        store.startOver()
        #expect(store.previous.sentences.map(\.original) == ["Hello everyone."])
        // A later meeting with final sentences replaces it.
        store.apply(CaptionSentence(id: 1, start: 0, end: 1, original: "Gracias a todos.", translation: .done("Thanks, everyone.")))
        store.startOver()
        #expect(store.previous.sentences.map(\.original) == ["Gracias a todos."])
    }
}

/// The window follows the newest sentence until the user scrolls up, and again once they
/// are back at the bottom.
struct CaptionFollowTests {
    @Test func newSentencesDoNotStopTheFollowing() {
        var follow = CaptionFollow()
        follow.update(offset: 0, contentHeight: 100, viewportHeight: 200)
        // Content grows below the view, the offset stays: not a scroll by the user.
        follow.update(offset: 0, contentHeight: 400, viewportHeight: 200)
        #expect(follow.isFollowing)
        // The window scrolls to the bottom.
        follow.update(offset: 200, contentHeight: 400, viewportHeight: 200)
        #expect(follow.isFollowing)
    }

    @Test func scrollingUpStopsItAndBackToTheBottomResumesIt() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 500, contentHeight: 1_000, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // New sentences while the user reads: the view stays where it is.
        follow.update(offset: 500, contentHeight: 1_300, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // Scrolling down, but not all the way.
        follow.update(offset: 1_000, contentHeight: 1_300, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // Close enough to the bottom.
        follow.update(offset: 1_090, contentHeight: 1_300, viewportHeight: 200)
        #expect(follow.isFollowing)
    }

    @Test func resizingTheWindowKeepsTheChoice() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 300)
        #expect(follow.isFollowing)
        follow.update(offset: 300, contentHeight: 1_000, viewportHeight: 300)
        #expect(!follow.isFollowing)
        follow.update(offset: 300, contentHeight: 1_000, viewportHeight: 250)
        #expect(!follow.isFollowing)
    }

    @Test func newOrLongerSentencesMoveTheViewDownWhileItFollows() {
        var follow = CaptionFollow()
        var moves = follow.update(offset: 0, contentHeight: 150, viewportHeight: 200)
        #expect(!moves)
        // A new sentence, or a translation longer than its original, pushes the bottom
        // out of view. The view should move down.
        moves = follow.update(offset: 0, contentHeight: 260, viewportHeight: 200)
        #expect(moves)
        // The move lands, in one step or several. None of them stops the following.
        moves = follow.update(offset: 30, contentHeight: 260, viewportHeight: 200)
        #expect(!moves)
        #expect(follow.isFollowing)
        moves = follow.update(offset: 60, contentHeight: 260, viewportHeight: 200)
        #expect(!moves)
        #expect(follow.isFollowing)
        // The next sentence moves it down again.
        moves = follow.update(offset: 60, contentHeight: 330, viewportHeight: 200)
        #expect(moves)
        #expect(follow.isFollowing)
    }

    @Test func aScrollTheViewReportsStopsTheFollowingEvenAsContentGrows() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        // A sentence comes in during the same frame as the user's scroll up.
        var moves = follow.update(offset: 600, contentHeight: 1_100, viewportHeight: 200, userScrolls: true)
        #expect(!moves)
        #expect(!follow.isFollowing)
        // More sentences while the user reads: no move down.
        moves = follow.update(offset: 600, contentHeight: 1_200, viewportHeight: 200)
        #expect(!moves)
        // The user scrolls back to the bottom and it follows again.
        moves = follow.update(offset: 990, contentHeight: 1_200, viewportHeight: 200, userScrolls: true)
        #expect(!moves)
        #expect(follow.isFollowing)
        moves = follow.update(offset: 990, contentHeight: 1_300, viewportHeight: 200)
        #expect(moves)
    }

    @Test func aSmallerWindowKeepsTheLatestInView() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        let moves = follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 120)
        #expect(moves)
        #expect(follow.isFollowing)
    }

    @Test func jumpingToTheLatestFollowsAgain() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 100, contentHeight: 1_000, viewportHeight: 200)
        #expect(!follow.isFollowing)
        follow.jumpToLatest()
        #expect(follow.isFollowing)
    }
}
