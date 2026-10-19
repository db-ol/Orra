import Foundation
import Testing
@testable import Orra

/// The local model for meeting captions: loaded while captions run, kept through the idle
/// time, and given back when nothing else needs it, with a stand in model.
@MainActor
struct CaptionCleanupTests {
    let temporary = TemporaryModelFolders()
    let clock = TestClock()
    let fake = HoldingEngine()

    private func makeCleanup(isOn: Bool = false, installed: Bool = true, captionTarget: TranslationTarget? = nil) async throws -> TextCleanup {
        if installed {
            try temporary.writeAll(to: temporary.installed)
        }
        let cleanup = TextCleanup(
            isOn: isOn,
            save: { _ in },
            captionTarget: captionTarget,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in 100_000_000_000 }, sleep: { _ in })
            ),
            engine: fake.engine,
            idleUnloadDelay: .seconds(900),
            sleep: { [clock] in try await clock.sleep(for: $0) }
        )
        await cleanup.start()
        await cleanup.waitForLoad()
        return cleanup
    }

    @Test func captionsLoadTheModelAndGiveItBack() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(captionTarget: .chinese)
        #expect(!fake.isLoaded)
        cleanup.captionsStarted()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.isReadyForCaptions)
        // With translation off, only the prompt into the caption target is read ahead.
        #expect(fake.prepared == [.chinese])
        cleanup.captionsStopped()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(!cleanup.isReadyForCaptions)
        #expect(fake.events == ["load", "unload"])
    }

    /// A caption target picked while captions run has its prompt read ahead, so the next
    /// sentence does not wait for it. One picked while they are off waits for their start.
    @Test func aNewCaptionTargetIsReadAhead() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: true)
        #expect(fake.isLoaded)
        cleanup.setCaptionTarget(.chinese)
        await cleanup.waitForLoad()
        #expect(fake.prepared.isEmpty)
        cleanup.captionsStarted()
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.chinese])
        cleanup.setCaptionTarget(.english)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.chinese, .english])
        // The translation key's direction reads nothing for captions.
        cleanup.setTranslationDirection(.chinese)
        await cleanup.waitForLoad()
        #expect(fake.prepared == [.chinese, .english])
    }

    @Test func theModelStaysLoadedWhileCaptionsRun() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(isOn: true)
        #expect(fake.isLoaded)
        cleanup.captionsStarted()
        await cleanup.waitForLoad()
        cleanup.dictationStarted()
        cleanup.dictationEnded()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(2))
        }
        clock.advance(by: .seconds(3_600))
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.engineState != .unloadedWhileIdle)
        // Cleanup still needs it after captions stop, so it stays until the idle time.
        cleanup.captionsStopped()
        await cleanup.waitForLoad()
        #expect(fake.isLoaded)
        #expect(cleanup.isOn)
    }

    @Test func withoutTheModelNothingIsDownloadedUntilTheUserAgrees() async throws {
        defer { temporary.remove() }
        let cleanup = try await makeCleanup(installed: false)
        cleanup.captionsStarted()
        await cleanup.waitForLoad()
        #expect(!fake.isLoaded)
        #expect(!cleanup.isReadyForCaptions)
        guard case .missing = cleanup.models.state else {
            Issue.record("The model should be missing, not \(cleanup.models.state)")
            return
        }
        // Agreeing after captions stopped downloads nothing.
        cleanup.captionsStopped()
        cleanup.confirmCaptionDownload()
        guard case .missing = cleanup.models.state else {
            Issue.record("Nothing should download after captions stopped")
            return
        }
        #expect(!cleanup.isOn)
        #expect(!cleanup.translationIsOn)
    }
}
