import Foundation
import Synchronization
import Testing
@testable import Orra

/// The setting, its download and its loading, with temporary folders and stand in servers.
@MainActor
struct TextCleanupTests {
    let temporary = TemporaryModelFolders()

    private func makeCleanup(isOn: Bool = false, fetch: FileFetch, saved: @escaping (Bool) -> Void = { _ in }) -> TextCleanup {
        TextCleanup(
            isOn: isOn,
            save: saved,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: fetch, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            )
        )
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
}
