import Foundation
import Synchronization
import Testing
@testable import Orra

/// The setting, its download and its loading, with temporary folders and stand in servers.
@MainActor
struct TextCleanupTests {
    let temporary = TemporaryModelFolders()

    private func makeCleanup(isOn: Bool = false, fetch: FileFetch, saved: @escaping (Bool) -> Void = { _ in }, engine: CleanupEngine = .live()) -> TextCleanup {
        TextCleanup(
            isOn: isOn,
            save: saved,
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
        private var held: [CheckedContinuation<Void, Never>] = []

        var engine: CleanupEngine {
            CleanupEngine(
                load: { [self] _ in try await load() },
                unload: { [self] in await unload() },
                complete: { _ in #"{"cleaned": ""}"# }
            )
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
        let suite = "io.github.db-ol.OrraTests.cleanup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CleanupPreference.load(from: defaults) == false)
        CleanupPreference.save(true, to: defaults)
        #expect(CleanupPreference.load(from: defaults))
        CleanupPreference.save(false, to: defaults)
        #expect(CleanupPreference.load(from: defaults) == false)
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
        #expect(cleanup.model.isReady() == false)
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
        #expect(cleanup.model.isReady() == false)
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
        #expect(cleanup.model.isReady())
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
        #expect(cleanup.model.isReady() == false)
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
}
