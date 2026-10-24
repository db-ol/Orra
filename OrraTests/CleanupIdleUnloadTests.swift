import Foundation
import Synchronization
import Testing
@testable import Orra

/// A clock the test moves. Each sleep ends once the test has moved the clock past its end,
/// or throws when its task is cancelled.
final class TestClock: Sendable {
    private struct Sleeper {
        let end: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [Int: Sleeper] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    /// How many sleeps have not ended yet.
    var sleeping: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if Task.isCancelled {
                        return true
                    }
                    state.sleepers[id] = Sleeper(end: state.now + duration, continuation: continuation)
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock and ends every sleep that is over by then.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now += duration
            let due = state.sleepers.filter { $0.value.end <= state.now }
            for id in due.keys {
                state.sleepers.removeValue(forKey: id)
            }
            return due.values.map(\.continuation)
        }
        for continuation in due {
            continuation.resume()
        }
    }
}

/// A stand in for the cleanup model that can hold loads and unloads until the test lets
/// them go, and records them in order.
@MainActor
final class HoldingEngine {
    var holdsLoads = false
    var holdsUnloads = false
    var failsNextLoad = false
    var answer = #"{"cleaned": "我们下午3点开会。"}"#
    var translationAnswer = #"{"cleaned": "我们下周二开会。", "translation": "We have a meeting next Tuesday."}"#
    /// The targets whose translation prompts were read ahead, in order.
    private(set) var prepared: [TranslationTarget] = []
    /// How many translations ran on a loaded model.
    private(set) var translations = 0
    /// "load", "unload" and "clearCache" in the order they ran.
    private(set) var events: [String] = []
    private(set) var running = 0
    private(set) var mostRunning = 0
    private(set) var isLoaded = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var loads: Int {
        events.count { $0 == "load" }
    }

    var unloads: Int {
        events.count { $0 == "unload" }
    }

    var engine: CleanupEngine {
        CleanupEngine(
            load: { [self] _ in try await load() },
            unload: { [self] in await unload() },
            complete: { [self] _ in await answer },
            translate: { [self] _, _ in try await translate() },
            prepareTranslation: { [self] route in try await prepare(route.target) },
            clearCache: { [self] in await clearCache() }
        )
    }

    private func clearCache() {
        events.append("clearCache")
    }

    private func translate() throws -> String {
        guard isLoaded else { throw RewriteError.notLoaded }
        translations += 1
        return translationAnswer
    }

    private func prepare(_ target: TranslationTarget) throws {
        guard isLoaded else { throw RewriteError.notLoaded }
        prepared.append(target)
    }

    private func load() async throws {
        events.append("load")
        running += 1
        mostRunning = max(mostRunning, running)
        if holdsLoads {
            await withCheckedContinuation { held.append($0) }
        }
        running -= 1
        if failsNextLoad {
            failsNextLoad = false
            throw RewriteError.notLoaded
        }
        isLoaded = true
    }

    private func unload() async {
        events.append("unload")
        running += 1
        mostRunning = max(mostRunning, running)
        if holdsUnloads {
            await withCheckedContinuation { held.append($0) }
        }
        running -= 1
        isLoaded = false
    }

    /// Whether a load or unload is held now.
    var isHolding: Bool {
        !held.isEmpty
    }

    func letGo() {
        holdsLoads = false
        holdsUnloads = false
        let continuations = held
        held = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

/// Unloading the cleanup model after a while without a dictation, and loading it again
/// when the talk key goes down, with a stand in model and a clock the test moves.
@MainActor
struct CleanupIdleUnloadTests {
    let temporary = TemporaryModelFolders()
    let clock = TestClock()
    let fake = HoldingEngine()
    let idle: Duration = .seconds(900)
    let loadWait: Duration = .seconds(3)

    /// Cleanup that is on, or translation, with the stand in model files in place, started
    /// as at launch and loaded.
    private func makeCleanup(isOn: Bool = true, translationIsOn: Bool = false, idleUnloadDelay: Duration?? = .none) async throws -> TextCleanup {
        try temporary.writeAll(to: temporary.installed)
        let cleanup = TextCleanup(
            isOn: isOn,
            save: { _ in },
            translationIsOn: translationIsOn,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: fake.engine,
            idleUnloadDelay: idleUnloadDelay ?? idle,
            loadWait: loadWait,
            sleep: { [clock] in try await clock.sleep(for: $0) }
        )
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        #expect(fake.isLoaded)
        return cleanup
    }

    /// Lets the tasks the clock or a stand in woke run, for a moment.
    private func settle() async throws {
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Waits until the condition holds, and ends the test at the caller's line when it does
    /// not, see `waitUntil`.
    private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(condition, sourceLocation: sourceLocation)
    }

    /// Moves the clock once the idle timer or a wait is sleeping on it.
    private func advance(by duration: Duration, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await settle({ clock.sleeping > 0 }, sourceLocation: sourceLocation)
        clock.advance(by: duration)
        try await settle()
    }

    private func unloadWhileIdle(_ cleanup: TextCleanup, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await advance(by: idle, sourceLocation: sourceLocation)
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .unloadedWhileIdle)
        #expect(!fake.isLoaded)
    }

    // MARK: Idle unload

    @Test func theModelIsUnloadedAfterTheIdleTime() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await advance(by: idle - .seconds(1))
        #expect(fake.isLoaded)
        #expect(cleanup.engineState != .unloadedWhileIdle)
        try await advance(by: .seconds(1))
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload"])
        #expect(cleanup.engineState == .unloadedWhileIdle)
        // Settings still shows cleanup as working, since the next dictation loads it.
        #expect(CleanupLabels.status(cleanup.models.state, engine: cleanup.engineState, total: cleanup.models.manifest.totalBytes, use: .cleanup) == nil)
        #expect(cleanup.isOn)
    }

    @Test func eachDictationStartsTheIdleTimeAgain() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await advance(by: .seconds(600))
        cleanup.dictationStarted()
        // No unload while a dictation runs, however long it takes.
        try await settle()
        clock.advance(by: .seconds(600))
        try await settle()
        cleanup.dictationEnded()
        try await advance(by: .seconds(600))
        #expect(fake.isLoaded)
        cleanup.dictationStarted()
        cleanup.dictationEnded()
        try await advance(by: .seconds(899))
        #expect(fake.isLoaded)
        try await advance(by: .seconds(1))
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload"])
    }

    @Test func withoutAnIdleTimeTheModelStaysLoaded() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(idleUnloadDelay: .some(nil))
        try await settle()
        #expect(clock.sleeping == 0)
        cleanup.dictationStarted()
        cleanup.dictationEnded()
        try await settle()
        #expect(clock.sleeping == 0)
        #expect(fake.events == ["load"])
    }

    @Test func thePreferenceDefaultsToFifteenMinutes() throws {
        try withTestDefaults("idle") { defaults in
            #expect(CleanupIdlePreference.load(from: defaults) == .seconds(900))
            defaults.set(60, forKey: CleanupIdlePreference.defaultsKey)
            #expect(CleanupIdlePreference.load(from: defaults) == .seconds(60))
            defaults.set("120", forKey: CleanupIdlePreference.defaultsKey)
            #expect(CleanupIdlePreference.load(from: defaults) == .seconds(120))
            defaults.set(0, forKey: CleanupIdlePreference.defaultsKey)
            #expect(CleanupIdlePreference.load(from: defaults) == nil)
        }
    }

    // MARK: Loading again

    @Test func theTalkKeyLoadsTheModelAgain() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        cleanup.dictationStarted()
        #expect(cleanup.engineState == .loading)
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload", "load"])
        #expect(cleanup.engineState == .ready)
        #expect(await cleanup.waitUntilLoaded())
        // A second dictation right after loads nothing.
        cleanup.dictationEnded()
        cleanup.dictationStarted()
        #expect(cleanup.engineState == .ready)
        #expect(fake.loads == 2)
    }

    @Test func aLoadedModelIsNotLoadedAgain() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        cleanup.dictationStarted()
        #expect(cleanup.engineState == .ready)
        #expect(await cleanup.waitUntilLoaded())
        cleanup.dictationEnded()
        #expect(fake.events == ["load"])
    }

    @Test func aTranscriptWaitsForTheLoadUnderWay() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        cleanup.dictationStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoaded()
        }
        try await settle()
        #expect(result == nil)
        fake.letGo()
        await waiting.value
        #expect(result == true)
    }

    @Test func aLoadThatTakesTooLongIsNotWaitedFor() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        cleanup.dictationStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoaded()
        }
        try await settle { clock.sleeping > 0 }
        clock.advance(by: loadWait - .milliseconds(1))
        try await settle()
        #expect(result == nil)
        clock.advance(by: .milliseconds(1))
        await waiting.value
        #expect(result == false)
        // The load goes on, and the next dictation has the model.
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        #expect(await cleanup.waitUntilLoaded())
    }

    @Test func aFailedLoadIsNotUsed() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        fake.failsNextLoad = true
        cleanup.dictationStarted()
        #expect(await cleanup.waitUntilLoaded() == false)
        #expect(cleanup.engineState == .failed)
        // The next press does not try again. Try Again in Settings does.
        cleanup.dictationEnded()
        cleanup.dictationStarted()
        #expect(fake.loads == 2)
    }

    // MARK: Off and on

    @Test func offDuringALoadAgainStopsTheWaitAndEndsUnloaded() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        cleanup.dictationStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoaded()
        }
        try await settle()
        cleanup.turnOff()
        await waiting.value
        #expect(result == false)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload", "load", "unload"])
        #expect(fake.mostRunning == 1)
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
        // No idle timer for a model that is off.
        cleanup.dictationEnded()
        try await settle()
        #expect(clock.sleeping == 0)
    }

    @Test func offAndOnDuringAnIdleUnloadEndsLoaded() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        fake.holdsUnloads = true
        try await advance(by: idle)
        try await settle { fake.isHolding }
        cleanup.turnOff()
        cleanup.turnOn()
        #expect(cleanup.engineState == .loading)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload", "unload", "load"])
        #expect(fake.mostRunning == 1)
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
    }

    @Test func offWhileUnloadedThenOnLoadsAtOnce() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        cleanup.turnOff()
        #expect(cleanup.engineState != .unloadedWhileIdle)
        cleanup.turnOn()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
    }

    @Test func aDictationDuringTheUnloadLoadsAfterIt() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        fake.holdsUnloads = true
        try await advance(by: idle)
        try await settle { fake.isHolding }
        cleanup.dictationStarted()
        #expect(cleanup.engineState == .loading)
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoaded()
        }
        try await settle()
        #expect(result == nil)
        fake.letGo()
        await waiting.value
        #expect(result == true)
        #expect(fake.events == ["load", "unload", "load"])
        #expect(fake.mostRunning == 1)
        #expect(fake.isLoaded)
    }

    // MARK: With the controller

    private func controller(_ cleanup: TextCleanup, mic: FakeMicrophone, speech: FakeSpeech, inserter: FakeInserter) async -> PushToTalkController {
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            cleanup: cleanup.model,
            translation: cleanup.translation,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        controller.setTranslationKeyOn(cleanup.translationIsOn)
        await controller.loadModel()
        speech.reply = "呃，我们下午两点，哦不对，下午三点开会。"
        return controller
    }

    @Test func theKeyDownLoadsTheModelAndTheDictationIsCleanedUp() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        controller.handle(.pressed(isRepeat: false))
        // Loading starts at the press, before the release.
        try await settle { fake.isHolding }
        #expect(fake.loads == 2)
        try await settle { mic.calls.contains("start") }
        controller.handle(.released)
        try await settle { speech.receivedSampleCounts.count == 1 }
        try await settle()
        #expect(inserter.inserted.isEmpty)
        fake.letGo()
        try await settle { controller.state == .idle }
        #expect(inserter.inserted == ["我们下午3点开会。"])
        #expect(controller.originalText == "我们下午2点，哦不对，下午3点开会。")
        // The idle time starts again after the paste.
        try await advance(by: idle - .seconds(1))
        #expect(fake.isLoaded)
        // Paste Original Text needs no model.
        try await advance(by: .seconds(1))
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        await controller.pasteOriginal()
        #expect(inserter.inserted.last == "我们下午2点，哦不对，下午3点开会。")
        #expect(fake.loads == 2)
    }

    @Test func aLoadThatTakesTooLongPastesTheRuledText() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        controller.handle(.pressed(isRepeat: false))
        try await settle { mic.calls.contains("start") }
        controller.handle(.released)
        try await settle { clock.sleeping > 0 }
        clock.advance(by: loadWait)
        try await settle { controller.state == .idle }
        #expect(inserter.inserted == ["我们下午2点，哦不对，下午3点开会。"])
        #expect(controller.originalText == nil)
        #expect(controller.problem == nil)
        // The load finishes, and the next dictation is cleaned up without a wait.
        fake.letGo()
        await cleanup.waitForLoad()
        controller.handle(.pressed(isRepeat: false))
        try await settle { mic.calls.filter { $0 == "start" }.count == 2 }
        controller.handle(.released)
        try await settle { inserter.inserted.count == 2 }
        #expect(inserter.inserted.last == "我们下午3点开会。")
        #expect(fake.loads == 2)
    }

    @Test func handsFreeLoadsTheModelAndHoldsOffTheUnload() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        try await unloadWhileIdle(cleanup)
        // A double press from idle starts hands free at once.
        controller.handle(.doublePressed)
        #expect(controller.state == .handsFree)
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        // Hands free records until the next press. No unload meanwhile.
        try await settle { mic.calls.contains("start") }
        try await settle()
        #expect(clock.sleeping == 0)
        controller.handle(.released)
        try await settle { controller.state == .idle }
        #expect(inserter.inserted == ["我们下午3点开会。"])
        try await advance(by: idle)
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
    }

    @Test func aCancelledHoldStartsTheIdleTimeAgain() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        try await unloadWhileIdle(cleanup)
        // A shortcut with the talk key: the press loads the model, the cancel ends it.
        controller.handle(.pressed(isRepeat: false))
        controller.handle(.cancelled)
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        try await advance(by: idle)
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(fake.events == ["load", "unload", "load", "unload"])
        #expect(inserter.inserted.isEmpty)
    }

    // MARK: With translation

    /// The words the stand in translation fits, see HoldingEngine.translationAnswer.
    private static let spokenForTranslation = "呃，我们下周一，哦不是，下周二开会。"

    @Test func withTranslationAloneTheModelIsUnloadedAndReadsThePromptsAgain() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: false, translationIsOn: true)
        #expect(fake.prepared == [.english, .chinese])
        #expect(cleanup.translation.isReady())
        try await unloadWhileIdle(cleanup)
        #expect(fake.events == ["load", "unload"])
        // Ready in Settings, but no translation can start on a model out of memory.
        #expect(CleanupLabels.status(cleanup.models.state, engine: cleanup.engineState, total: cleanup.models.manifest.totalBytes, use: .translation) == nil)
        #expect(cleanup.translation.isReady() == false)
        #expect(await cleanup.translation.waitUntilLoaded() == false)
        cleanup.dictationStarted()
        #expect(cleanup.engineState == .loading)
        #expect(cleanup.translation.isReady() == false)
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload", "load"])
        #expect(fake.prepared == [.english, .chinese, .english, .chinese])
        #expect(cleanup.translation.isReady())
        #expect(await cleanup.translation.waitUntilLoaded())
        #expect(await cleanup.model.waitUntilLoaded() == false)
        // The idle time starts again after the dictation.
        cleanup.dictationEnded()
        try await unloadWhileIdle(cleanup)
        #expect(fake.events == ["load", "unload", "load", "unload"])
    }

    @Test func aTranslationWaitsForTheLoadUnderWay() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: false, translationIsOn: true)
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        cleanup.dictationStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.translation.waitUntilLoaded()
        }
        try await settle()
        #expect(result == nil)
        fake.letGo()
        await waiting.value
        #expect(result == true)
    }

    @Test func theTranslationKeyLoadsTheModelAndTheDictationIsTranslated() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: false, translationIsOn: true)
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        speech.reply = Self.spokenForTranslation
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        controller.handle(.pressed(isRepeat: false), key: controller.translationKey)
        // Loading starts at the press, before the release.
        try await settle { fake.isHolding }
        #expect(fake.loads == 2)
        try await settle { mic.calls.contains("start") }
        controller.handle(.released, key: controller.translationKey)
        try await settle { speech.receivedSampleCounts.count == 1 }
        try await settle()
        #expect(inserter.inserted.isEmpty)
        fake.letGo()
        try await settle { controller.state == .idle }
        #expect(inserter.inserted == ["We have a meeting next Tuesday."])
        #expect(controller.notice == nil)
        #expect(fake.translations == 1)
        // The prompts were read again after the load.
        #expect(fake.prepared == [.english, .chinese, .english, .chinese])
        // The idle time starts again after the paste.
        try await advance(by: idle)
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
    }

    @Test func aTranslationLoadThatTakesTooLongPastesUntranslatedAndWaitsOnce() async throws {
        defer { temporary.remove() }
        // With cleanup on too, the cleanup step does not wait a second time.
        let cleanup = try await makeCleanup(isOn: true, translationIsOn: true)
        let (mic, speech, inserter) = (FakeMicrophone(), FakeSpeech(), FakeInserter())
        let controller = await controller(cleanup, mic: mic, speech: speech, inserter: inserter)
        speech.reply = Self.spokenForTranslation
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        controller.handle(.pressed(isRepeat: false), key: controller.translationKey)
        try await settle { mic.calls.contains("start") }
        controller.handle(.released, key: controller.translationKey)
        try await settle { clock.sleeping > 0 }
        clock.advance(by: loadWait)
        try await settle { controller.state == .idle }
        // The text the rules left, neither translated nor cleaned up.
        let ruled = try #require(inserter.inserted.first)
        #expect(inserter.inserted.count == 1)
        #expect(ruled.contains("下周一") && !ruled.contains("呃"))
        #expect(controller.notice == String(localized: "The local model is not ready, so the text was pasted without translation."))
        #expect(fake.translations == 0)
        // The load goes on, and the next press of the translation key translates at once.
        fake.letGo()
        await cleanup.waitForLoad()
        controller.handle(.pressed(isRepeat: false), key: controller.translationKey)
        try await settle { mic.calls.filter { $0 == "start" }.count == 2 }
        controller.handle(.released, key: controller.translationKey)
        try await settle { inserter.inserted.count == 2 }
        #expect(inserter.inserted.last == "We have a meeting next Tuesday.")
        #expect(fake.loads == 2)
    }

    @Test func cleanupOffWhileTranslationIsOnKeepsTheModel() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: true, translationIsOn: true)
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load"])
        #expect(fake.isLoaded)
        #expect(cleanup.translation.isReady())
        // The idle time still runs for translation, and a press loads the model again.
        try await unloadWhileIdle(cleanup)
        fake.holdsLoads = true
        cleanup.dictationStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.translation.waitUntilLoaded()
        }
        try await settle()
        // Turning off the last one ends the wait and unloads.
        cleanup.turnOffTranslation()
        await waiting.value
        #expect(result == false)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload", "load", "unload"])
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
        cleanup.dictationEnded()
        try await settle()
        #expect(clock.sleeping == 0)
    }

    // MARK: Projects

    /// Cleanup and translation off unless asked, with or without the stand in model files,
    /// started as at launch unless asked.
    private func makeCleanupForProjects(isOn: Bool = false, installed: Bool = true, started: Bool = true) async throws -> TextCleanup {
        if installed {
            try temporary.writeAll(to: temporary.installed)
        }
        let cleanup = TextCleanup(
            isOn: isOn,
            save: { _ in },
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: fake.engine,
            idleUnloadDelay: idle,
            loadWait: loadWait,
            sleep: { [clock] in try await clock.sleep(for: $0) }
        )
        if started {
            await cleanup.start()
            await cleanup.waitForLoad()
        }
        return cleanup
    }

    @Test func noIdleUnloadWhileProjectsHoldTheModel() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        // The window opens and a request starts: two holders.
        cleanup.projectsStarted()
        cleanup.projectsStarted()
        #expect(cleanup.projectsNeedModel)
        try await settle()
        #expect(clock.sleeping == 0)
        // The end of a dictation does not start the idle time either.
        cleanup.dictationStarted()
        cleanup.dictationEnded()
        try await settle()
        #expect(clock.sleeping == 0)
        clock.advance(by: idle * 2)
        await cleanup.waitForLoad()
        #expect(fake.events == ["load"])
        #expect(await cleanup.waitUntilLoadedForProjects())
        // The request ends, and the window still holds the model.
        cleanup.projectsStopped()
        try await settle()
        #expect(clock.sleeping == 0)
        #expect(await cleanup.waitUntilLoadedForProjects())
        // The window closes. Cleanup is on, so the model stays until the idle time.
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "clearCache"])
        #expect(!cleanup.projectsNeedModel)
        #expect(await cleanup.waitUntilLoadedForProjects() == false)
        try await unloadWhileIdle(cleanup)
        #expect(fake.events == ["load", "clearCache", "unload"])
        // A stop without a holder changes nothing.
        cleanup.projectsStopped()
        #expect(!cleanup.projectsNeedModel)
    }

    @Test func theFirstHolderLoadsTheModelAndTheLastUnloadsItAtOnce() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        #expect(fake.events.isEmpty)
        // Without a holder Projects gets no model.
        #expect(await cleanup.waitUntilLoadedForProjects() == false)
        cleanup.projectsStarted()
        #expect(cleanup.engineState == .loading)
        #expect(await cleanup.waitUntilLoadedForProjects())
        #expect(fake.events == ["load"])
        try await settle()
        #expect(clock.sleeping == 0)
        // Turning cleanup on and off meanwhile keeps the model for Projects.
        cleanup.turnOn()
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        // Nothing else needs it, so the last holder unloads it at once.
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload"])
        #expect(cleanup.engineState == .unloaded)
        #expect(!fake.isLoaded)
        try await settle()
        #expect(clock.sleeping == 0)
    }

    @Test func theFirstHolderLoadsAModelUnloadedWhileIdle() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup()
        try await unloadWhileIdle(cleanup)
        cleanup.projectsStarted()
        #expect(cleanup.engineState == .loading)
        #expect(await cleanup.waitUntilLoadedForProjects())
        #expect(fake.events == ["load", "unload", "load"])
    }

    /// The Projects window opens during a dictation: the model loads only after the paste,
    /// so the load does not compete with the speech model.
    @Test func aHolderDuringADictationLoadsTheModelAfterThePaste() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        cleanup.dictationStarted()
        cleanup.projectsStarted()
        await cleanup.waitForLoad()
        #expect(fake.events.isEmpty)
        #expect(cleanup.engineState == .unloaded)
        cleanup.dictationEnded()
        #expect(cleanup.engineState == .loading)
        #expect(await cleanup.waitUntilLoadedForProjects())
        #expect(fake.events == ["load"])
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
    }

    @Test func aHolderThatLeavesDuringTheDictationLoadsNothing() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        cleanup.dictationStarted()
        cleanup.projectsStarted()
        #expect(cleanup.engineState == .unloaded)
        cleanup.projectsStopped()
        cleanup.dictationEnded()
        await cleanup.waitForLoad()
        #expect(fake.loads == 0)
        #expect(cleanup.engineState == .unloaded)
        // The next holder after the dictation loads it as usual.
        cleanup.projectsStarted()
        #expect(cleanup.engineState == .loading)
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
    }

    /// A Projects job that asks for the model during the dictation waits for the load
    /// after the paste, instead of failing for a model that is not there.
    @Test func aProjectsWaitDuringADictationEndsLoaded() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        cleanup.dictationStarted()
        cleanup.projectsStarted()
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoadedForProjects()
        }
        try await settle { clock.sleeping > 0 }
        #expect(result == nil)
        cleanup.dictationEnded()
        clock.advance(by: .milliseconds(100))
        await waiting.value
        #expect(result == true)
        #expect(fake.events == ["load"])
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
    }

    @Test func projectsWaitForALoadWithoutTheLimitOfADictation() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        fake.holdsLoads = true
        cleanup.projectsStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoadedForProjects()
        }
        try await settle()
        // No time limit runs for it.
        #expect(clock.sleeping == 0)
        #expect(result == nil)
        fake.letGo()
        await waiting.value
        #expect(result == true)
    }

    @Test func aCancelledProjectsWaitForALoadEndsAtOnce() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        fake.holdsLoads = true
        cleanup.projectsStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoadedForProjects()
        }
        try await settle()
        #expect(result == nil)
        waiting.cancel()
        await waiting.value
        #expect(result == false)
        // The load goes on for the holder.
        #expect(cleanup.engineState == .loading)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(await cleanup.waitUntilLoadedForProjects())
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
    }

    @Test func projectsWaitWhileOrraLooksForTheModelOnDisk() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects(started: false)
        #expect(cleanup.models.state == .checking)
        // The window opens at launch, before Orra has looked.
        cleanup.projectsStarted()
        #expect(cleanup.engineState == .unloaded)
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoadedForProjects()
        }
        try await settle { clock.sleeping > 0 }
        #expect(result == nil)
        // Orra finds the model, which loads for the holder.
        await cleanup.start()
        clock.advance(by: .milliseconds(100))
        await waiting.value
        #expect(result == true)
        #expect(fake.events == ["load"])
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
    }

    @Test func aLastHolderLeavingDuringALoadEndsTheWaitAndUnloads() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        fake.holdsLoads = true
        cleanup.projectsStarted()
        try await settle { fake.isHolding }
        var result: Bool?
        let waiting = Task {
            result = await cleanup.waitUntilLoadedForProjects()
        }
        try await settle()
        cleanup.projectsStopped()
        await waiting.value
        #expect(result == false)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload"])
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
    }

    @Test func withoutTheModelProjectsLoadAndDownloadNothing() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects(installed: false)
        cleanup.projectsStarted()
        await cleanup.waitForLoad()
        #expect(fake.events.isEmpty)
        #expect(await cleanup.waitUntilLoadedForProjects() == false)
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
        guard case .missing = cleanup.models.state else {
            Issue.record("Nothing should download for Projects, the state is \(cleanup.models.state)")
            return
        }
        #expect(!cleanup.isConfirmingDownload)
        #expect(!fake.isLoaded)
    }

    @Test func theProjectsEnvironmentWaitsForTheModelOfTheHolders() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanupForProjects()
        let environment = cleanup.projectsEnvironment(isDictating: { false }, captionsOn: { false }, memoryPressure: { .normal }, voiceLoaded: { false }, physicalMemory: 16 << 30)
        #expect(environment.physicalMemory == 16 << 30)
        #expect(await environment.waitUntilLoaded() == false)
        // A request of the user is a holder of its own.
        environment.holdModel()
        #expect(cleanup.projectsHolders == 1)
        #expect(await environment.waitUntilLoaded())
        // The stand in has no job calls.
        await #expect(throws: RewriteError.notLoaded) { try await environment.startJob("Hello", 8) }
        environment.releaseModel()
        #expect(cleanup.projectsHolders == 0)
        await cleanup.waitForLoad()
        #expect(fake.events == ["load", "unload"])
    }
}
