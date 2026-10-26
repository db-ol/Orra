import Foundation
import os
import Testing
@testable import Orra

@MainActor
struct MeetingCaptionsTests {
    /// Stands in for the capture. MeetingCaptions calls it off the main actor, so its
    /// state is behind a lock. With `holdsStart`, a start waits until `releaseStart`.
    private final class FakeSource: Sendable {
        private struct State {
            var fails: SystemAudioProblem?
            var holdsStart = false
            var deliver: (@Sendable ([Float]) -> Void)?
            var calls: [String] = []
            var startedOnMain = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let gate = DispatchSemaphore(value: 0)

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
            })
        }
    }

    private func makeCaptions(_ models: FakeCaptionModels, source: FakeSource, events: Box, displayMode: CaptionDisplayMode = .translationOnly, silenceHint: Double = 2) -> MeetingCaptions {
        let captions = MeetingCaptions(
            source: source.source,
            engines: models.engines(),
            started: { events.items.append("started") },
            stopped: { events.items.append("stopped") },
            displayMode: displayMode,
            silenceHint: silenceHint
        )
        captions.showWindow = { events.items.append("show") }
        captions.closeWindow = { events.items.append("close") }
        return captions
    }

    @MainActor
    private final class Box {
        var items: [String] = []
    }

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
        let captions = MeetingCaptions(source: FakeSource().source, engines: FakeCaptionModels([]).engines(), store: store, copyText: { copies.append($0) })
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
        #expect(!captions.hearsOnlySilence)
        captions.receive(CaptionAudio.silence(1))
        #expect(captions.hearsOnlySilence)
        captions.receive(CaptionAudio.tone(0.1))
        #expect(!captions.hearsOnlySilence)
        captions.receive(CaptionAudio.silence(5))
        #expect(!captions.hearsOnlySilence)
    }

    /// A capture that delivers nothing at all, as while nothing plays, suggests the
    /// permission after the same time as one that delivers only zeros. Zeros that come
    /// later keep the note, and the first sound takes it away.
    @Test func aCaptureThatDeliversNothingSuggestsThePermission() async throws {
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        try await eventually { captions.hearsOnlySilence }
        captions.receive(CaptionAudio.silence(0.1), run: captions.currentRun)
        #expect(captions.hearsOnlySilence)
        captions.receive(CaptionAudio.tone(0.1), run: captions.currentRun)
        #expect(!captions.hearsOnlySilence)
        captions.setOn(false)
    }

    /// A start that still waits, as for the permission prompt or for the first sound the
    /// Mac plays, suggests the permission after the same time.
    @Test func aStartThatStillWaitsSuggestsThePermission() async throws {
        let source = FakeSource()
        source.holdsStart = true
        defer { source.releaseStart() }
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box(), silenceHint: 0.2)
        captions.setOn(true)
        try await eventually { source.calls == ["start"] }
        try await eventually { captions.hearsOnlySilence }
        #expect(captions.capture == .starting)
        captions.setOn(false)
        #expect(!captions.hearsOnlySilence)
    }

    /// From the press of a key until the paste, captions start no model call, see
    /// EngineTurns. The window says that they wait and catch up after the dictation,
    /// but not for captions that cannot hear anything.
    @Test func captionsSayTheyWaitWhileADictationRuns() async throws {
        let turns = EngineTurns()
        let waits = "Captions wait while you dictate and catch up when you finish."
        let captions = makeCaptions(FakeCaptionModels([]), source: FakeSource(), events: Box())
        captions.setOn(true)
        try await eventually { captions.capture == .listening }
        #expect(!CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        turns.dictationStarted()
        #expect(CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        turns.dictationEnded()
        #expect(!CaptionNotes.lines(captions: captions, speechReady: true, turns: turns).contains(waits))
        captions.setOn(false)
        let source = FakeSource()
        source.fails = .failed(step: "start the device", status: -1)
        let failed = makeCaptions(FakeCaptionModels([]), source: source, events: Box())
        failed.setOn(true)
        try await eventually { failed.capture == .unavailable(.failed(step: "start the device", status: -1)) }
        turns.dictationStarted()
        #expect(!CaptionNotes.lines(captions: failed, speechReady: true, turns: turns).contains(waits))
        turns.dictationEnded()
        failed.setOn(false)
    }

    @Test func theDisplayModeIsSaved() {
        var saved: [CaptionDisplayMode] = []
        let captions = MeetingCaptions(source: FakeSource().source, engines: FakeCaptionModels([]).engines(), saveDisplayMode: { saved.append($0) })
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
