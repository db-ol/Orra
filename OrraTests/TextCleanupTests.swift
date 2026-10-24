import Foundation
import Synchronization
import Testing
@testable import Orra

/// The setting, its download and its loading, with temporary folders and stand in servers.
@MainActor
struct TextCleanupTests {
    let temporary = TemporaryModelFolders()

    private func makeCleanup(
        isOn: Bool = false,
        translationIsOn: Bool = false,
        fetch: FileFetch,
        saved: @escaping (Bool) -> Void = { _ in },
        savedTranslation: @escaping (Bool) -> Void = { _ in },
        savedDirection: @escaping (TranslationDirection) -> Void = { _ in },
        engine: CleanupEngine = .live()
    ) -> TextCleanup {
        TextCleanup(
            isOn: isOn,
            save: saved,
            translationIsOn: translationIsOn,
            saveTranslation: savedTranslation,
            saveDirection: savedDirection,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: fetch, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: engine
        )
    }

    /// A stand in for the model that holds each load until it is let go, and counts loads
    /// running at once.
    @MainActor
    final class FakeEngine {
        var holdsLoads = false
        var failsNextLoad = false
        private(set) var loads = 0
        private(set) var running = 0
        private(set) var mostRunning = 0
        private(set) var isLoaded = false
        /// The targets whose translation prompts were read ahead, in order.
        var prepared: [TranslationTarget] {
            preparedRoutes.map(\.target)
        }
        /// The routes whose translation prompts were read ahead, in order.
        private(set) var preparedRoutes: [TranslationRoute] = []
        /// The routes each call to keep the translation prompts named, in order.
        private(set) var kept: [Set<TranslationRoute>] = []
        private var held: [CheckedContinuation<Void, Never>] = []

        var engine: CleanupEngine {
            CleanupEngine(
                load: { [self] _ in try await load() },
                unload: { [self] in await unload() },
                complete: { _ in #"{"cleaned": ""}"# },
                translate: { _, _ in #"{"cleaned": "", "translation": ""}"# },
                prepareTranslation: { [self] route in await prepare(route) },
                keepTranslationPrefixes: { [self] routes in await keep(routes) }
            )
        }

        private func prepare(_ route: TranslationRoute) {
            preparedRoutes.append(route)
        }

        private func keep(_ routes: Set<TranslationRoute>) {
            kept.append(routes)
        }

        private func load() async throws {
            loads += 1
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

        private func unload() {
            isLoaded = false
        }

        func letGo() {
            holdsLoads = false
            for continuation in held {
                continuation.resume()
            }
            held = []
        }

        func waitForLoads(_ count: Int) async {
            for _ in 0..<10_000 where loads < count {
                await Task.yield()
            }
        }
    }

    @Test func thePreferenceIsOffUntilSaved() throws {
        try withTestDefaults("cleanup") { defaults in
            #expect(CleanupPreference.load(from: defaults) == false)
            CleanupPreference.save(true, to: defaults)
            #expect(CleanupPreference.load(from: defaults))
            CleanupPreference.save(false, to: defaults)
            #expect(CleanupPreference.load(from: defaults) == false)
        }
    }

    /// Turning cleanup on without the model asks first, and nothing goes online until the
    /// user agrees.
    @Test func turningOnAsksBeforeTheDownload() async {
        defer { temporary.remove() }
        let calls = Mutex(0)
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, saved: { saved.append($0) })
        await cleanup.start()
        cleanup.turnOn()
        #expect(cleanup.isConfirmingDownload)
        #expect(!cleanup.isOn)
        #expect(saved.isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(await cleanup.model.waitUntilLoaded() == false)
    }

    @Test func confirmingDownloadsAndCancellingTurnsItOff() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: servers.fetch, saved: { saved.append($0) })
        await cleanup.start()
        cleanup.turnOn()
        cleanup.confirmDownload()
        #expect(cleanup.isOn)
        #expect(!cleanup.isConfirmingDownload)
        guard case .downloading = cleanup.models.state else {
            Issue.record("Expected a download, got \(cleanup.models.state)")
            return
        }
        cleanup.cancelDownload()
        await cleanup.models.waitForDownload()
        #expect(!cleanup.isOn)
        #expect(saved == [true, false])
        guard case .missing = cleanup.models.state else {
            Issue.record("Expected the model to be missing, got \(cleanup.models.state)")
            return
        }
    }

    /// The stand in files are not a model, so loading fails, and cleanup is never ready.
    @Test func aModelThatCannotLoadIsNeverUsed() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in })
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .failed)
        #expect(await cleanup.model.waitUntilLoaded() == false)
    }

    /// With the model in place, turning on needs no download, and turning off unloads.
    @Test func withTheModelInPlaceTurningOnLoadsAtOnce() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let calls = Mutex(0)
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } })
        await cleanup.start()
        #expect(cleanup.engineState == .unloaded)
        cleanup.turnOn()
        #expect(cleanup.isOn)
        #expect(!cleanup.isConfirmingDownload)
        #expect(cleanup.engineState == .loading)
        await cleanup.waitForLoad()
        cleanup.turnOff()
        #expect(cleanup.engineState == .unloaded)
        #expect(calls.withLock { $0 } == 0)
    }

    /// Off and on again while the model loads: one load at a time, the unload between them,
    /// and the model loaded at the end.
    @Test func offAndOnDuringALoadEndsLoaded() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        fake.holdsLoads = true
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        cleanup.turnOn()
        await fake.waitForLoads(1)
        #expect(fake.loads == 1)
        cleanup.turnOff()
        cleanup.turnOn()
        #expect(cleanup.engineState == .loading)
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(fake.mostRunning == 1)
        #expect(fake.loads == 2)
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
        #expect(await cleanup.model.waitUntilLoaded())
    }

    /// Turned off during a load: the model is unloaded once the load is over.
    @Test func offDuringALoadEndsUnloaded() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        fake.holdsLoads = true
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await fake.waitForLoads(1)
        cleanup.turnOff()
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
        #expect(await cleanup.model.waitUntilLoaded() == false)
    }

    @Test func tryAgainLoadsAfterAFailedLoad() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        fake.failsNextLoad = true
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .failed)
        await cleanup.retryLoading()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        #expect(fake.loads == 2)
    }

    /// Try Again on a line that stayed after the model loaded or began to load, such as Try
    /// Loading Again in the Projects window after a load from Settings, leaves the model as
    /// it is. Nothing looks at the files again and nothing loads twice, so cleanup never
    /// goes without the model meanwhile.
    @Test(arguments: [false, true])
    func tryAgainLeavesAModelThatIsLoadedOrLoadingAlone(whileLoading: Bool) async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        fake.holdsLoads = whileLoading
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        if whileLoading {
            await fake.waitForLoads(1)
        } else {
            await cleanup.waitForLoad()
        }
        let state = cleanup.engineState
        #expect(state == (whileLoading ? .loading : .ready))
        await cleanup.retryLoading()
        #expect(cleanup.engineState == state)
        #expect(cleanup.models.state == .installed(temporary.installed))
        fake.letGo()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        #expect(fake.loads == 1)
        #expect(await cleanup.model.waitUntilLoaded())
    }

    /// A finished download loads the model.
    @Test func aFinishedDownloadLoadsTheModel() async {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: servers.fetch, engine: fake.engine)
        await cleanup.start()
        cleanup.turnOn()
        cleanup.confirmDownload()
        await cleanup.models.waitForDownload()
        await cleanup.waitForLoad()
        #expect(cleanup.models.state == .installed(temporary.installed))
        #expect(cleanup.engineState == .ready)
        #expect(fake.isLoaded)
    }

    /// Before Orra has looked for the model on disk, turning on does nothing, since it
    /// cannot tell yet whether a download is needed.
    @Test func turningOnBeforeTheCheckDoesNotAskToDownload() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        #expect(!cleanup.canTurnOn)
        cleanup.turnOn()
        #expect(!cleanup.isConfirmingDownload)
        #expect(!cleanup.isOn)
        await cleanup.start()
        #expect(cleanup.canTurnOn)
        cleanup.turnOn()
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
    }

    // MARK: Projects

    /// Turning Projects on without the model asks first, and nothing goes online until the
    /// user agrees. Cleanup stays off.
    @Test func turningProjectsOnAsksBeforeTheDownload() async {
        defer { temporary.remove() }
        let calls = Mutex(0)
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, saved: { saved.append($0) })
        await cleanup.start()
        #expect(cleanup.turnOnProjects() == false)
        #expect(cleanup.isConfirmingProjectsDownload)
        #expect(!cleanup.isConfirmingDownload)
        #expect(!cleanup.projectsAgreedToDownload)
        // The window opening and closing downloads nothing either.
        cleanup.projectsStarted()
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
        #expect(calls.withLock { $0 } == 0)
        guard case .missing = cleanup.models.state else {
            Issue.record("Nothing should download before the user agrees, the state is \(cleanup.models.state)")
            return
        }
        // Turning Projects off clears the question.
        cleanup.projectsTurnedOff()
        #expect(!cleanup.isConfirmingProjectsDownload)
        #expect(!cleanup.isOn)
        #expect(saved.isEmpty)
    }

    /// Before Orra has looked for the model on disk, turning Projects on neither asks nor
    /// goes on, as for cleanup.
    @Test func turningProjectsOnBeforeTheCheckDoesNotAsk() async {
        defer { temporary.remove() }
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in })
        #expect(cleanup.turnOnProjects() == false)
        #expect(!cleanup.isConfirmingProjectsDownload)
    }

    /// With the model in place Projects turns on at once, downloads nothing and loads
    /// nothing until its window or a request holds the model.
    @Test func withTheModelInPlaceProjectsTurnOnWithoutAsking() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let calls = Mutex(0)
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, engine: fake.engine)
        await cleanup.start()
        #expect(cleanup.turnOnProjects())
        #expect(!cleanup.isConfirmingProjectsDownload)
        await cleanup.waitForLoad()
        #expect(fake.loads == 0)
        #expect(calls.withLock { $0 } == 0)
    }

    /// A download agreed to for Projects goes on while the window opens and closes and
    /// captions start and stop, since Projects stays on. Once in place, the model stays
    /// unloaded while nothing holds it. Cleanup and translation stay off.
    @Test func aDownloadForProjectsGoesOnWithTheWindowClosed() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(10))])
        defer { servers.close() }
        var saved: [Bool] = []
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: servers.fetch, saved: { saved.append($0) }, engine: fake.engine)
        await cleanup.start()
        #expect(cleanup.turnOnProjects() == false)
        cleanup.confirmProjectsDownload()
        #expect(!cleanup.isConfirmingProjectsDownload)
        #expect(cleanup.projectsAgreedToDownload)
        #expect(!cleanup.isOn)
        #expect(!cleanup.translationIsOn)
        guard case .downloading = cleanup.models.state else {
            Issue.record("Expected a download, got \(cleanup.models.state)")
            return
        }
        // Turning Projects on again asks nothing.
        #expect(cleanup.turnOnProjects())
        #expect(!cleanup.isConfirmingProjectsDownload)
        cleanup.projectsStarted()
        cleanup.projectsStopped()
        cleanup.captionsStarted()
        cleanup.captionsStopped()
        await cleanup.models.waitForDownload()
        await cleanup.waitForLoad()
        #expect(cleanup.models.state == .installed(temporary.installed))
        #expect(fake.loads == 0)
        #expect(saved.isEmpty)
    }

    /// Turning Projects off stops a download only Projects agreed to.
    @Test func turningProjectsOffStopsItsDownload() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(10))])
        defer { servers.close() }
        let cleanup = makeCleanup(fetch: servers.fetch)
        await cleanup.start()
        cleanup.confirmProjectsDownload()
        cleanup.projectsTurnedOff()
        #expect(!cleanup.projectsAgreedToDownload)
        await cleanup.models.waitForDownload()
        guard case .missing = cleanup.models.state else {
            Issue.record("Expected the download to stop, got \(cleanup.models.state)")
            return
        }
        // Without an agreement, nothing stops at the next turn off.
        cleanup.projectsTurnedOff()
        #expect(!cleanup.isConfirmingProjectsDownload)
    }

    /// A download agreed to for cleanup counts for Projects, and goes on when Projects
    /// turns off. Cancel Download on the Projects page stops it as under the switch of
    /// cleanup, and Projects asks again next time.
    @Test func projectsShareTheDownloadOfCleanup() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        let cleanup = makeCleanup(fetch: servers.fetch)
        await cleanup.start()
        cleanup.turnOn()
        cleanup.confirmDownload()
        #expect(cleanup.turnOnProjects())
        #expect(!cleanup.isConfirmingProjectsDownload)
        #expect(!cleanup.projectsAgreedToDownload)
        cleanup.projectsTurnedOff()
        guard case .downloading = cleanup.models.state else {
            Issue.record("The download for cleanup should go on, the state is \(cleanup.models.state)")
            return
        }
        #expect(cleanup.turnOnProjects())
        cleanup.confirmProjectsDownload()
        #expect(cleanup.projectsAgreedToDownload)
        cleanup.cancelDownload()
        await cleanup.models.waitForDownload()
        #expect(!cleanup.projectsAgreedToDownload)
        #expect(!cleanup.isOn)
        #expect(cleanup.turnOnProjects() == false)
        #expect(cleanup.isConfirmingProjectsDownload)
    }

    /// Cancel Download on the Projects page stops only a download nothing else waits for,
    /// and never turns cleanup or translation off. Under their switches it still does.
    @Test func theProjectsPageCancelsOnlyItsOwnDownload() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: servers.fetch, saved: { saved.append($0) })
        await cleanup.start()
        cleanup.turnOn()
        cleanup.confirmDownload()
        cleanup.confirmProjectsDownload()
        #expect(!cleanup.canCancelProjectsDownload)
        cleanup.cancelProjectsDownload()
        #expect(cleanup.isOn)
        #expect(cleanup.projectsAgreedToDownload)
        guard case .downloading = cleanup.models.state else {
            Issue.record("The download for cleanup should go on, the state is \(cleanup.models.state)")
            return
        }
        // Cleanup turns off, and the download goes on for Projects alone, which may now
        // cancel it. Cleanup stays off.
        cleanup.turnOff()
        #expect(cleanup.canCancelProjectsDownload)
        guard case .downloading = cleanup.models.state else {
            Issue.record("The download for Projects should go on, the state is \(cleanup.models.state)")
            return
        }
        cleanup.cancelProjectsDownload()
        await cleanup.models.waitForDownload()
        #expect(!cleanup.projectsAgreedToDownload)
        #expect(!cleanup.isOn)
        #expect(saved == [true, false])
        guard case .missing = cleanup.models.state else {
            Issue.record("Expected the download to stop, got \(cleanup.models.state)")
            return
        }
    }

    /// While captions run, the Projects page leaves the cancel to the caption window.
    @Test func whileCaptionsRunTheProjectsPageCannotCancel() async {
        defer { temporary.remove() }
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in })
        await cleanup.start()
        #expect(cleanup.canCancelProjectsDownload)
        cleanup.captionsStarted()
        #expect(!cleanup.canCancelProjectsDownload)
        cleanup.captionsStopped()
        #expect(cleanup.canCancelProjectsDownload)
    }

    /// A download that only captions agreed to stops when they do, so turning Projects on
    /// meanwhile asks too. Once the user agrees, it goes on after captions stop.
    @Test func turningProjectsOnDuringADownloadForCaptionsAsks() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        let cleanup = makeCleanup(fetch: servers.fetch)
        await cleanup.start()
        cleanup.captionsStarted()
        cleanup.confirmCaptionDownload()
        guard case .downloading = cleanup.models.state else {
            Issue.record("Expected a download for captions, got \(cleanup.models.state)")
            return
        }
        #expect(cleanup.turnOnProjects() == false)
        #expect(cleanup.isConfirmingProjectsDownload)
        cleanup.confirmProjectsDownload()
        cleanup.captionsStopped()
        guard case .downloading = cleanup.models.state else {
            Issue.record("The download for Projects should go on, the state is \(cleanup.models.state)")
            return
        }
        cleanup.projectsTurnedOff()
        await cleanup.models.waitForDownload()
        guard case .missing = cleanup.models.state else {
            Issue.record("Expected the download to stop, got \(cleanup.models.state)")
            return
        }
    }

    /// Once the download for Projects is in place, the model loads only for a holder.
    @Test func aFinishedDownloadForProjectsLoadsOnlyForAHolder() async {
        defer { temporary.remove() }
        let servers = StubServers()
        defer { servers.close() }
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: servers.fetch, engine: fake.engine)
        await cleanup.start()
        cleanup.confirmProjectsDownload()
        await cleanup.models.waitForDownload()
        await cleanup.waitForLoad()
        #expect(cleanup.models.state == .installed(temporary.installed))
        #expect(fake.loads == 0)
        cleanup.projectsStarted()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        cleanup.projectsStopped()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
    }

    // MARK: Translation

    @Test func translationIsOffUntilSavedAndTheDirectionIsAutomatic() throws {
        try withTestDefaults("translation") { defaults in
            #expect(TranslationPreference.load(from: defaults) == false)
            TranslationPreference.save(true, to: defaults)
            #expect(TranslationPreference.load(from: defaults))
            #expect(TranslationDirection.load(from: defaults) == .automatic)
            TranslationDirection.chinese.save(to: defaults)
            #expect(TranslationDirection.load(from: defaults) == .chinese)
        }
    }

    /// Turning translation on without the model asks as cleanup does, and nothing goes
    /// online until the user agrees.
    @Test func turningTranslationOnAsksBeforeTheDownload() async {
        defer { temporary.remove() }
        let calls = Mutex(0)
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, savedTranslation: { saved.append($0) })
        await cleanup.start()
        cleanup.turnOnTranslation()
        #expect(cleanup.isConfirmingTranslationDownload)
        #expect(!cleanup.isConfirmingDownload)
        #expect(!cleanup.translationIsOn)
        #expect(saved.isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(cleanup.translation.isReady() == false)
    }

    /// Agreeing to the download for translation turns translation on and leaves cleanup
    /// off. Cleanup then turns on without asking again, and Cancel Download turns both off.
    @Test func confirmingTheDownloadForTranslationAndCancelling() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        var saved: [Bool] = []
        var savedTranslation: [Bool] = []
        let cleanup = makeCleanup(fetch: servers.fetch, saved: { saved.append($0) }, savedTranslation: { savedTranslation.append($0) })
        await cleanup.start()
        cleanup.turnOnTranslation()
        cleanup.confirmTranslationDownload()
        #expect(cleanup.translationIsOn)
        #expect(!cleanup.isOn)
        #expect(!cleanup.isConfirmingTranslationDownload)
        guard case .downloading = cleanup.models.state else {
            Issue.record("Expected a download, got \(cleanup.models.state)")
            return
        }
        cleanup.turnOn()
        #expect(cleanup.isOn)
        #expect(!cleanup.isConfirmingDownload)
        cleanup.cancelDownload()
        await cleanup.models.waitForDownload()
        #expect(!cleanup.isOn)
        #expect(!cleanup.translationIsOn)
        #expect(saved == [true, false])
        #expect(savedTranslation == [true, false])
    }

    /// Translation on and cleanup off still loads the model, and the translation prompts
    /// are read ahead for both targets, since the automatic direction picks one per
    /// dictation. The cleanup closure stays off.
    @Test func translationAloneLoadsTheModelAndReadsBothPromptsAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(translationIsOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
        #expect(fake.prepared == [.english, .chinese])
        #expect(cleanup.translation.isReady())
        #expect(await cleanup.model.waitUntilLoaded() == false)
    }

    /// With the model loaded for cleanup, turning translation on reads the prompts ahead
    /// at once, a fixed direction only its own, and a change of direction the new one.
    /// Turning translation off leaves the model to cleanup.
    @Test func turningTranslationOnWithTheModelLoadedReadsThePromptAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        var directions: [TranslationDirection] = []
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, savedDirection: { directions.append($0) }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.prepared.isEmpty)
        cleanup.setTranslationDirection(.chinese)
        #expect(directions == [.chinese])
        await cleanup.waitForLoad()
        // Translation is off, so nothing is read ahead yet.
        #expect(fake.prepared.isEmpty)
        cleanup.turnOnTranslation()
        #expect(cleanup.translationIsOn)
        #expect(!cleanup.isConfirmingTranslationDownload)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.chinese])
        #expect(cleanup.translation.direction() == .chinese)
        cleanup.setTranslationDirection(.english)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.chinese, .english])
        cleanup.turnOffTranslation()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(await cleanup.model.waitUntilLoaded())
        #expect(cleanup.translation.isReady() == false)
        // The last switch off unloads.
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
    }

    /// Cleanup off while translation is on keeps the model loaded.
    @Test func cleanupOffKeepsTheModelForTranslation() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(isOn: true, translationIsOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
        #expect(cleanup.translation.isReady())
        #expect(await cleanup.model.waitUntilLoaded() == false)
        #expect(TextCleanup.preparedTargets(.automatic) == [.english, .chinese])
        #expect(TextCleanup.preparedTargets(.english) == [.english])
    }

    /// The prompts read ahead are those of the dictation language: both of its routes for
    /// Automatic, and the route of a fixed direction as it acts for that language. For
    /// Chinese they are the targets they always were.
    @Test func thePromptsReadAheadAreThoseOfTheDictationLanguage() {
        let japanese = [TranslationRoute(.japanese, into: .english), TranslationRoute(.japanese, into: .japanese)]
        #expect(TextCleanup.preparedRoutes(.automatic, .japanese) == japanese)
        #expect(TextCleanup.preparedRoutes(.japanese, .japanese) == [TranslationRoute(.japanese, into: .japanese)])
        #expect(TextCleanup.preparedRoutes(.spanish, .spanish) == [TranslationRoute(.spanish, into: .spanish)])
        #expect(TextCleanup.preparedRoutes(.english, .spanish) == [TranslationRoute(.spanish, into: .english)])
        // A choice saved for Chinese acts as Automatic for Japanese, and the other way round.
        #expect(TextCleanup.preparedRoutes(.chinese, .japanese) == japanese)
        #expect(TextCleanup.preparedRoutes(.japanese, .chinese) == TextCleanup.preparedRoutes(.automatic, .chinese))
        for direction in TranslationDirection.choices(for: .chinese) {
            #expect(TextCleanup.preparedRoutes(direction, .chinese).map(\.target) == TextCleanup.preparedTargets(direction))
        }
        for language in DictationLanguage.allCases {
            for direction in TranslationDirection.allCases {
                #expect((1...TranslationPrefixSlots.limit).contains(TextCleanup.preparedRoutes(direction, language).count))
            }
        }
    }

    /// While captions run, the prompt into the caption target is read ahead first, as it
    /// acts for the dictation language, then those of the translation key while translation
    /// is on, each once. All stay within the two routes of the dictation language.
    @Test func captionRoutesAreReadAhead() {
        #expect(TextCleanup.preparedRoutes(direction: nil, captionTarget: .chinese, .chinese) == [.chinese(.chinese)])
        #expect(TextCleanup.preparedRoutes(direction: nil, captionTarget: .english, .japanese) == [TranslationRoute(.japanese, into: .english)])
        // A target saved for Chinese acts as Spanish for Spanish dictation.
        #expect(TextCleanup.preparedRoutes(direction: nil, captionTarget: .chinese, .spanish) == [TranslationRoute(.spanish, into: .spanish)])
        #expect(TextCleanup.preparedRoutes(direction: .automatic, captionTarget: .chinese, .chinese) == [.chinese(.chinese), .chinese(.english)])
        #expect(TextCleanup.preparedRoutes(direction: .english, captionTarget: .english, .chinese) == [.chinese(.english)])
        #expect(TextCleanup.preparedRoutes(direction: .automatic, captionTarget: nil, .japanese) == TextCleanup.preparedRoutes(.automatic, .japanese))
        #expect(TextCleanup.preparedRoutes(direction: nil, captionTarget: nil, .chinese).isEmpty)
        for language in DictationLanguage.allCases {
            for direction in TranslationDirection.allCases {
                for target in TranslationTarget.allCases {
                    let routes = TextCleanup.preparedRoutes(direction: direction, captionTarget: target, language)
                    #expect(Set(routes).count == routes.count)
                    #expect(Set(routes).isSubset(of: language.translationRoutes))
                }
            }
        }
    }

    /// Captions running with translation off read the prompt of their target, not those of
    /// the translation key's direction, and a change of dictation language reads it for the
    /// new language.
    @Test func captionsReadTheirOwnPromptAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = TextCleanup(
            isOn: true,
            save: { _ in },
            translationDirection: .english,
            captionTarget: .chinese,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: fake.engine
        )
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.isEmpty)
        cleanup.captionsStarted()
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes == [.chinese(.chinese)])
        cleanup.setDictationLanguage(.japanese)
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.last == TranslationRoute(.japanese, into: .japanese))
        #expect(fake.kept.last == Set(DictationLanguage.japanese.translationRoutes))
    }

    /// A change of dictation language keeps only the prompts of the new language and reads
    /// them ahead, while translation is on and the model is loaded. Otherwise the next
    /// load reads them.
    @Test func aChangeOfLanguageReadsItsPromptsAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(translationIsOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        let chinese = DictationLanguage.chinese.translationTargets.map(TranslationRoute.chinese)
        #expect(fake.preparedRoutes == chinese)
        #expect(fake.kept == [Set(chinese)])
        cleanup.setDictationLanguage(.spanish)
        #expect(cleanup.dictationLanguage == .spanish)
        await cleanup.waitForLoad()
        let spanish = [TranslationRoute(.spanish, into: .english), TranslationRoute(.spanish, into: .spanish)]
        #expect(fake.kept.last == Set(spanish))
        #expect(Array(fake.preparedRoutes.dropFirst(2)) == spanish)
        // The same language reads nothing more.
        cleanup.setDictationLanguage(.spanish)
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.count == 4)
        // A fixed direction reads its route only.
        cleanup.setTranslationDirection(.spanish)
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.last == TranslationRoute(.spanish, into: .spanish))
        // With translation off, nothing is read until translation is on again.
        cleanup.turnOffTranslation()
        await cleanup.waitForLoad()
        let count = fake.preparedRoutes.count
        cleanup.setDictationLanguage(.japanese)
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.count == count)
    }

    /// A direction saved for Chinese reads the prompts of Automatic for Spanish, and its own
    /// again when the user goes back to Chinese.
    @Test func aChoiceOfAnotherLanguageReadsTheAutomaticPrompts() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(translationIsOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        cleanup.setTranslationDirection(.chinese)
        cleanup.setDictationLanguage(.spanish)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes == [TranslationRoute(.spanish, into: .english), TranslationRoute(.spanish, into: .spanish)])
        #expect(cleanup.translationDirection == .chinese)
        cleanup.setDictationLanguage(.chinese)
        await cleanup.waitForLoad()
        #expect(fake.preparedRoutes.last == .chinese(.chinese))
    }
}
