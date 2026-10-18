import Foundation
import Synchronization
import Testing
@testable import Orra

/// Use names on screen in the controller, with a fake reading of the screen, so no app is
/// read.
@MainActor
struct ScreenNamesControllerTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let workspace = FakeWorkspace()

    /// A reading of the screen that records the apps it read and the presses it got, and
    /// waits for `release` while `holds` is set.
    final class FakeScreen: Sendable {
        private let state = Mutex<(reads: [pid_t], presses: [ContinuousClock.Instant], holds: Bool, waiting: [CheckedContinuation<Void, Never>])>(([], [], false, []))
        let names: [String]

        init(names: [String], holds: Bool = false) {
            self.names = names
            state.withLock { $0.holds = holds }
        }

        var reads: [pid_t] {
            state.withLock { $0.reads }
        }

        var presses: [ContinuousClock.Instant] {
            state.withLock { $0.presses }
        }

        func read(_ app: pid_t, pressed: ContinuousClock.Instant) async -> [String] {
            await withCheckedContinuation { continuation in
                let waits = state.withLock { state in
                    state.reads.append(app)
                    state.presses.append(pressed)
                    if state.holds { state.waiting.append(continuation) }
                    return state.holds
                }
                if !waits { continuation.resume() }
            }
            return names
        }

        func release() {
            let waiting = state.withLock { state in
                state.holds = false
                defer { state.waiting = [] }
                return state.waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    private func controller(screen: FakeScreen, on: Bool, vocabulary: [String] = ["Orra"], saved: @escaping (Bool) -> Void = { _ in }) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            frontmostApp: { [workspace] in workspace.frontmost },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            vocabulary: vocabularyWords(vocabulary),
            usesScreenNames: on,
            saveUsesScreenNames: saved,
            readScreenNames: { await screen.read($0, pressed: $1) }
        )
        await controller.loadModel()
        return controller
    }

    /// A dictation whose reading of the screen has ended before the release, unless the
    /// reading holds.
    private func dictate(_ controller: PushToTalkController, screen: FakeScreen, beforeRelease: () -> Void = {}) async throws {
        let reads = screen.reads.count
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.pressed(isRepeat: false))
        try await waitUntil { mic.calls.filter { $0 == "start" }.count > starts }
        if controller.usesScreenNames {
            try await waitUntil { screen.reads.count > reads }
        }
        // The fake answers in the same step it is asked, unless it holds.
        await Task.yield()
        beforeRelease()
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
    }

    @Test func offNothingIsReadAndTheModelGetsTheVocabularyAsBefore() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield"])
        let controller = await controller(screen: screen, on: false)
        #expect(!controller.usesScreenNames)
        try await dictate(controller, screen: screen)
        speech.reply = "Orra。"
        speech.replyWithoutContext = "Aura."
        try await dictate(controller, screen: screen)
        #expect(screen.reads.isEmpty)
        // As without the switch: the vocabulary, and the pass of the echo check.
        #expect(speech.receivedContexts == ["Orra", "Orra", nil])
        #expect(inserter.inserted == ["你好", "Orra。"])
    }

    @Test func onTheNamesComeFirstThenTheVocabulary() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield", "Quorvia", "orra"])
        let controller = await controller(screen: screen, on: true, vocabulary: ["Orra", "通义千问"])
        speech.reply = "我们周五和 Dana 一起发布 Quorvia。"
        try await dictate(controller, screen: screen)
        #expect(screen.reads == [100])
        // A name the vocabulary holds comes once, in the vocabulary's spelling.
        #expect(speech.receivedContexts == ["Dana Whitfield\nQuorvia\nOrra\n通义千问"])
        #expect(inserter.inserted == ["我们周五和 Dana 一起发布 Quorvia。"])
    }

    @Test func aReadingThatHasNotEndedIsNotWaitedFor() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield"], holds: true)
        let controller = await controller(screen: screen, on: true)
        try await dictate(controller, screen: screen)
        #expect(screen.reads == [100])
        #expect(speech.receivedContexts == ["Orra"])
        #expect(inserter.inserted == ["你好"])
        screen.release()
    }

    @Test func namesFromAnotherAppThanThePasteAreNotUsed() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield"])
        let controller = await controller(screen: screen, on: true)
        try await dictate(controller, screen: screen) {
            workspace.frontmost = 200
        }
        #expect(screen.reads == [100])
        #expect(speech.receivedContexts == ["Orra"])
    }

    @Test func aListOfNamesIsNeverPastedOverSpeech() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield", "Quorvia"])
        let controller = await controller(screen: screen, on: true, vocabulary: [])
        speech.reply = "Dana Whitfield, Quorvia."
        speech.replyWithoutContext = "Let's go over the launch plan tomorrow."
        try await dictate(controller, screen: screen)
        #expect(speech.receivedContexts == ["Dana Whitfield\nQuorvia", nil])
        #expect(inserter.inserted == ["Let's go over the launch plan tomorrow."])
    }

    @Test func turningItOffStopsTheReadingAndIsSaved() async throws {
        var saved: [Bool] = []
        let screen = FakeScreen(names: ["Dana Whitfield"])
        let controller = await controller(screen: screen, on: false) { saved.append($0) }
        controller.setUsesScreenNames(true)
        controller.setUsesScreenNames(true)
        try await dictate(controller, screen: screen)
        controller.setUsesScreenNames(false)
        try await dictate(controller, screen: screen)
        #expect(saved == [true, false])
        #expect(screen.reads == [100])
        #expect(speech.receivedContexts == ["Dana Whitfield\nOrra", "Orra"])
    }

    @Test func aShortcutReadsNothingAndAnEarlyCaptureReadsOnceItCounts() async throws {
        let screen = FakeScreen(names: ["Dana Whitfield"])
        let controller = await controller(screen: screen, on: true)
        // A press that may still be a shortcut starts the microphone silently, and the
        // shortcut drops it.
        controller.handle(.armed)
        try await waitUntil { mic.calls == ["start"] }
        controller.handle(.cancelled)
        try await waitUntil { mic.calls.contains("cancel") }
        await Task.yield()
        #expect(screen.reads.isEmpty)
        controller.handle(.armed)
        try await waitUntil { mic.calls.filter { $0 == "start" }.count == 2 }
        #expect(screen.reads.isEmpty)
        let counted = ContinuousClock.now
        controller.handle(.pressed(isRepeat: false))
        let answered = ContinuousClock.now
        try await waitUntil { screen.reads.count == 1 }
        // The time limit of the reading counts from the press that counted, not from when
        // the reading got to run.
        let pressed = try #require(screen.presses.first)
        #expect(counted <= pressed && pressed <= answered)
        await Task.yield()
        controller.handle(.released)
        try await waitUntil { controller.state == .idle }
        #expect(speech.receivedContexts == ["Dana Whitfield\nOrra"])
    }
}
