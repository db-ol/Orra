import Foundation
import Synchronization
import Testing
@testable import Orra

/// The Polish switch and its style in TextCleanup: off until the user turns it on, the
/// download it asks for first, the model it keeps loaded and the prompt it reads ahead,
/// with temporary folders, stand in servers and a stand in model.
@MainActor
struct PolishSwitchTests {
    let temporary = TemporaryModelFolders()

    /// A stand in for the model that counts its loads and the polish prompts read ahead.
    @MainActor
    final class FakeEngine {
        private(set) var isLoaded = false
        private(set) var loads = 0
        /// The styles whose polish prompts were read ahead, in order.
        private(set) var prepared: [PolishStyle] = []

        var engine: CleanupEngine {
            CleanupEngine(
                load: { [self] _ in await load() },
                unload: { [self] in await unload() },
                complete: { _ in #"{"cleaned": ""}"# },
                polish: { _, _ in #"{"polished": ""}"# },
                preparePolish: { [self] style in await prepare(style) }
            )
        }

        private func load() {
            loads += 1
            isLoaded = true
        }

        private func unload() {
            isLoaded = false
        }

        private func prepare(_ style: PolishStyle) {
            prepared.append(style)
        }
    }

    /// A stand in whose polish prompt is read only when the test says so.
    @MainActor
    final class SlowPromptEngine {
        private(set) var prepared: [PolishStyle] = []
        private(set) var isPreparing = false
        private var finishing: CheckedContinuation<Void, Never>?

        var engine: CleanupEngine {
            CleanupEngine(
                load: { _ in },
                unload: {},
                complete: { _ in #"{"cleaned": ""}"# },
                polish: { _, _ in #"{"polished": ""}"# },
                preparePolish: { [self] style in await prepare(style) }
            )
        }

        private func prepare(_ style: PolishStyle) async {
            isPreparing = true
            await withCheckedContinuation { finishing = $0 }
            prepared.append(style)
            isPreparing = false
        }

        func finishPreparing() {
            finishing?.resume()
            finishing = nil
        }
    }

    private func makeCleanup(
        isOn: Bool = false,
        polishIsOn: Bool = false,
        polishStyle: PolishStyle = .clear,
        fetch: FileFetch,
        saved: @escaping (Bool) -> Void = { _ in },
        savedPolish: @escaping (Bool) -> Void = { _ in },
        savedStyle: @escaping (PolishStyle) -> Void = { _ in },
        engine: CleanupEngine = .live(),
        loadWait: Duration = TextCleanup.defaultLoadWait
    ) -> TextCleanup {
        TextCleanup(
            isOn: isOn,
            save: saved,
            polishIsOn: polishIsOn,
            savePolish: savedPolish,
            polishStyle: polishStyle,
            savePolishStyle: savedStyle,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: fetch, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: engine,
            loadWait: loadWait
        )
    }

    /// Turning Polish on without the model asks first, and nothing goes online until the
    /// user agrees. Cleanup stays as it was.
    @Test func turningPolishOnAsksBeforeTheDownload() async {
        defer { temporary.remove() }
        let calls = Mutex(0)
        var saved: [Bool] = []
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, savedPolish: { saved.append($0) })
        await cleanup.start()
        cleanup.turnOnPolish()
        #expect(cleanup.isConfirmingPolishDownload)
        #expect(!cleanup.isConfirmingDownload)
        #expect(!cleanup.polishIsOn)
        #expect(!cleanup.isOn)
        #expect(saved.isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(cleanup.model.polishStyle() == nil)
        #expect(await cleanup.model.waitUntilLoadedForPolish() == false)
    }

    /// Agreeing to the download for Polish turns Polish on and leaves cleanup off. Cleanup
    /// then turns on without asking again, and Cancel Download turns both off.
    @Test func confirmingTheDownloadForPolishAndCancelling() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        var saved: [Bool] = []
        var savedPolish: [Bool] = []
        let cleanup = makeCleanup(fetch: servers.fetch, saved: { saved.append($0) }, savedPolish: { savedPolish.append($0) })
        await cleanup.start()
        cleanup.turnOnPolish()
        cleanup.confirmPolishDownload()
        #expect(cleanup.polishIsOn)
        #expect(!cleanup.isOn)
        #expect(!cleanup.isConfirmingPolishDownload)
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
        #expect(!cleanup.polishIsOn)
        #expect(saved == [true, false])
        #expect(savedPolish == [true, false])
    }

    /// While cleanup is on, the user agreed to the download already, so Polish turns on
    /// without asking, and so does translation while Polish is on.
    @Test func polishSharesTheDownloadOfCleanup() async {
        defer { temporary.remove() }
        let servers = StubServers(behaviors: [.huggingFace: StubBehavior(chunkDelay: .milliseconds(50))])
        defer { servers.close() }
        let cleanup = makeCleanup(fetch: servers.fetch)
        await cleanup.start()
        cleanup.turnOn()
        cleanup.confirmDownload()
        cleanup.turnOnPolish()
        #expect(cleanup.polishIsOn)
        #expect(!cleanup.isConfirmingPolishDownload)
        cleanup.turnOff()
        // With Polish on alone, Projects needs no question either, and its page offers no
        // Cancel Download, which would stop the download Polish waits for.
        #expect(!cleanup.isOn)
        #expect(!cleanup.translationIsOn)
        #expect(cleanup.turnOnProjects())
        #expect(!cleanup.isConfirmingProjectsDownload)
        #expect(!cleanup.canCancelProjectsDownload)
        cleanup.turnOnTranslation()
        #expect(cleanup.translationIsOn)
        #expect(!cleanup.isConfirmingTranslationDownload)
        cleanup.cancelDownload()
        await cleanup.models.waitForDownload()
    }

    /// Polish alone loads the model at launch and reads the prompt of its style ahead.
    /// The cleanup closure stays off, and the polish closure has the style.
    @Test func polishAloneLoadsTheModelAndReadsItsPromptAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(polishIsOn: true, polishStyle: .concise, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
        #expect(fake.prepared == [.concise])
        #expect(cleanup.model.polishStyle() == .concise)
        #expect(await cleanup.model.waitUntilLoadedForPolish())
        #expect(await cleanup.model.waitUntilLoaded() == false)
        #expect(cleanup.model.isOn() == false)
    }

    /// A dictation that waits for the load goes on only once the polish prompt is read, so
    /// the first polish after a load, at launch or at the press of a key after an idle
    /// unload, does not spend its time limit reading the prompt. The wait stays bounded by
    /// `loadWait`, which this test sets long.
    @Test func aDictationWaitingForTheLoadGoesOnOnceThePolishPromptIsRead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = SlowPromptEngine()
        let cleanup = makeCleanup(polishIsOn: true, polishStyle: .concise, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine, loadWait: .seconds(3_600))
        await cleanup.start()
        #expect(cleanup.engineState == .loading)
        let loaded = Mutex<Bool?>(nil)
        let dictation = Task {
            let ready = await cleanup.model.waitUntilLoadedForPolish()
            loaded.withLock { $0 = ready }
        }
        try await waitUntil({ fake.isPreparing })
        // Time for a dictation resumed too early to go on.
        try await Task.sleep(for: .milliseconds(200))
        #expect(loaded.withLock { $0 } == nil)
        #expect(cleanup.engineState == .loading)
        fake.finishPreparing()
        await dictation.value
        #expect(loaded.withLock { $0 } == true)
        #expect(fake.prepared == [.concise])
        await cleanup.waitForLoad()
        #expect(cleanup.engineState == .ready)
        #expect(fake.prepared == [.concise])
    }

    /// A style picked while the model loads is read once the load is over, so the first
    /// polish in it does not read it either.
    @Test func aStylePickedWhileTheModelLoadsIsReadAfterTheLoad() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = SlowPromptEngine()
        let cleanup = makeCleanup(polishIsOn: true, polishStyle: .clear, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine, loadWait: .seconds(3_600))
        await cleanup.start()
        try await waitUntil({ fake.isPreparing })
        cleanup.setPolishStyle(.concise)
        fake.finishPreparing()
        try await waitUntil({ fake.prepared == [.clear] && fake.isPreparing })
        fake.finishPreparing()
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.clear, .concise])
        #expect(cleanup.engineState == .ready)
    }

    /// With the model loaded for cleanup, turning Polish on reads its prompt ahead at
    /// once, and a change of style reads the new one. The style is saved also while Polish
    /// is off, and reads nothing ahead then. Turning Polish off leaves the model to cleanup,
    /// and the last switch off unloads it.
    @Test func turningPolishOnWithTheModelLoadedReadsThePromptAhead() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        var styles: [PolishStyle] = []
        let cleanup = makeCleanup(isOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, savedStyle: { styles.append($0) }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        #expect(fake.prepared.isEmpty)
        cleanup.setPolishStyle(.concise)
        #expect(styles == [.concise])
        await cleanup.waitForLoad()
        #expect(fake.prepared.isEmpty)
        #expect(cleanup.model.polishStyle() == nil)
        cleanup.turnOnPolish()
        #expect(cleanup.polishIsOn)
        #expect(!cleanup.isConfirmingPolishDownload)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.concise])
        #expect(cleanup.model.polishStyle() == .concise)
        cleanup.setPolishStyle(.clear)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.concise, .clear])
        #expect(styles == [.concise, .clear])
        // The same style again changes nothing.
        cleanup.setPolishStyle(.clear)
        await cleanup.waitForLoad()
        #expect(styles == [.concise, .clear])
        cleanup.turnOffPolish()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.model.polishStyle() == nil)
        #expect(await cleanup.model.waitUntilLoaded())
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
    }

    /// Cleanup off while Polish is on keeps the model loaded, as for translation.
    @Test func cleanupOffKeepsTheModelForPolish() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let fake = FakeEngine()
        let cleanup = makeCleanup(isOn: true, polishIsOn: true, fetch: FileFetch { _, _, _, _, _, _ in }, engine: fake.engine)
        await cleanup.start()
        await cleanup.waitForLoad()
        cleanup.turnOff()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState == .ready)
        #expect(await cleanup.model.waitUntilLoadedForPolish())
        #expect(await cleanup.model.waitUntilLoaded() == false)
    }

    /// With the model in place, turning Polish on loads it, and turning it off unloads it
    /// when nothing else needs it.
    @Test func withTheModelInPlaceTurningPolishOnLoadsAtOnce() async throws {
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let calls = Mutex(0)
        let fake = FakeEngine()
        let cleanup = makeCleanup(fetch: FileFetch { _, _, _, _, _, _ in calls.withLock { $0 += 1 } }, engine: fake.engine)
        await cleanup.start()
        #expect(cleanup.engineState == .unloaded)
        cleanup.turnOnPolish()
        #expect(cleanup.polishIsOn)
        #expect(cleanup.engineState == .loading)
        await cleanup.waitForLoad()
        #expect(fake.loads == 1)
        #expect(fake.prepared == [.clear])
        cleanup.turnOffPolish()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(cleanup.engineState == .unloaded)
        #expect(calls.withLock { $0 } == 0)
    }
}
