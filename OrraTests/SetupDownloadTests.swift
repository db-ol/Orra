import Foundation
import Synchronization
import Testing
@testable import Orra

/// The welcome window's cleanup proposal, its one download of both models, the button that
/// follows the cleanup switch, and the step its guide talks about.
@MainActor
struct SetupDownloadTests {
    private let folder = URL(fileURLWithPath: "/nonexistent/Models/qwen3")
    private let speechTotal = ModelManifest.qwen3.totalBytes
    private let cleanupTotal = ModelManifest.qwen35Cleanup.totalBytes

    // MARK: The proposal

    @Test func cleanupIsProposedToANewUserWithSixteenGigabytesOrMore() {
        for gigabytes: UInt64 in [16, 18, 24, 36, 48, 64, 128] {
            #expect(CleanupDefault.proposes(savedChoice: nil, speechModelInstalled: false, physicalMemory: gigabytes << 30))
        }
        for gigabytes: UInt64 in [4, 8, 12] {
            #expect(!CleanupDefault.proposes(savedChoice: nil, speechModelInstalled: false, physicalMemory: gigabytes << 30))
        }
        #expect(!CleanupDefault.proposes(savedChoice: nil, speechModelInstalled: false, physicalMemory: (16 << 30) - 1))
    }

    /// A saved choice is never flipped, and a user who has the speech model already is not
    /// new.
    @Test func anExistingUserKeepsTheirChoice() {
        for saved in [true, false] {
            #expect(!CleanupDefault.proposes(savedChoice: saved, speechModelInstalled: false, physicalMemory: 48 << 30))
        }
        #expect(!CleanupDefault.proposes(savedChoice: nil, speechModelInstalled: true, physicalMemory: 48 << 30))
    }

    @Test func memoryIsShownInWholeGigabytes() {
        #expect(CleanupDefault.gigabytes(8 << 30) == 8)
        #expect(CleanupDefault.gigabytes(16 << 30) == 16)
        #expect(CleanupDefault.gigabytes((24 << 30) - 4096) == 24)
    }

    @Test func thePreferenceTellsANeverMadeChoiceApart() throws {
        let suite = "io.github.db-ol.OrraTests.cleanup-saved-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CleanupPreference.saved(from: defaults) == nil)
        CleanupPreference.save(false, to: defaults)
        #expect(CleanupPreference.saved(from: defaults) == false)
        CleanupPreference.save(true, to: defaults)
        #expect(CleanupPreference.saved(from: defaults) == true)
    }

    // MARK: The order

    @Test func theSpeechModelComesFirst() {
        let missing = ModelInstaller.State.missing(bytesPresent: 0)
        let installed = ModelInstaller.State.installed(folder)
        #expect(SetupDownload.next(speech: missing, wantsCleanup: true, cleanup: missing) == .speech)
        #expect(SetupDownload.next(speech: .failed(.offline), wantsCleanup: true, cleanup: missing) == .speech)
        // Nothing new while the speech model downloads, is checked, or is looked for.
        for busy in [ModelInstaller.State.downloading(bytes: 5, source: nil), .verifying, .checking] {
            #expect(SetupDownload.next(speech: busy, wantsCleanup: true, cleanup: missing) == nil)
            #expect(SetupDownload.active(speech: busy, wantsCleanup: true, cleanup: missing) == .speech)
        }
        #expect(SetupDownload.next(speech: installed, wantsCleanup: true, cleanup: missing) == .cleanup)
        #expect(SetupDownload.next(speech: installed, wantsCleanup: true, cleanup: .failed(.unreachable)) == .cleanup)
        #expect(SetupDownload.next(speech: installed, wantsCleanup: false, cleanup: missing) == nil)
        #expect(SetupDownload.next(speech: installed, wantsCleanup: true, cleanup: installed) == nil)
        #expect(SetupDownload.active(speech: installed, wantsCleanup: true, cleanup: .downloading(bytes: 1, source: nil)) == .cleanup)
        #expect(SetupDownload.active(speech: installed, wantsCleanup: false, cleanup: missing) == nil)
        #expect(SetupDownload.active(speech: installed, wantsCleanup: true, cleanup: installed) == nil)
    }

    // MARK: The bar

    @Test func theBarCountsTheBytesOfBothModels() {
        let half = speechTotal / 2
        var progress = CombinedProgress(speech: .downloading(bytes: half, source: nil), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 0), cleanupTotal: cleanupTotal)
        #expect(progress.completed == half)
        #expect(progress.total == speechTotal + cleanupTotal)
        #expect(progress.percent == half * 100 / (speechTotal + cleanupTotal))
        // The speech model in place counts in full, and the cleanup model's bytes add to it.
        progress = CombinedProgress(speech: .installed(folder), speechTotal: speechTotal, cleanup: .downloading(bytes: 1_000, source: .modelScope), cleanupTotal: cleanupTotal)
        #expect(progress.completed == speechTotal + 1_000)
        // Bytes kept from an earlier download count too.
        progress = CombinedProgress(speech: .missing(bytesPresent: 10), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 20), cleanupTotal: cleanupTotal)
        #expect(progress.completed == 30)
        // Both in place, or both checked.
        progress = CombinedProgress(speech: .installed(folder), speechTotal: speechTotal, cleanup: .verifying, cleanupTotal: cleanupTotal)
        #expect(progress.completed == progress.total)
        #expect(progress.percent == 100)
        #expect(progress.fraction == 1)
    }

    @Test func aModelLeftOutOfTheBarDoesNotCount() {
        var progress = CombinedProgress(speech: .downloading(bytes: 100, source: nil), speechTotal: speechTotal, cleanup: nil, cleanupTotal: cleanupTotal)
        #expect(progress.total == speechTotal)
        #expect(progress.completed == 100)
        progress = CombinedProgress(speech: nil, speechTotal: speechTotal, cleanup: .downloading(bytes: cleanupTotal / 4, source: nil), cleanupTotal: cleanupTotal)
        #expect(progress.total == cleanupTotal)
        // Rounded down, as in the menu.
        #expect(progress.percent == 24)
        progress = CombinedProgress(speech: nil, speechTotal: speechTotal, cleanup: nil, cleanupTotal: cleanupTotal)
        #expect(progress.total == 0)
        #expect(progress.fraction == 0)
        #expect(progress.percent == 0)
    }

    @Test func bytesAreKeptWithinTheModel() {
        #expect(CombinedProgress.bytes(.downloading(bytes: 50, source: nil), total: 40) == 40)
        #expect(CombinedProgress.bytes(.downloading(bytes: -1, source: nil), total: 40) == 0)
        #expect(CombinedProgress.bytes(.failed(.offline), total: 40) == 0)
        #expect(CombinedProgress.bytes(.checking, total: 40) == 0)
    }

    // MARK: The step's text

    @Test func theButtonFollowsTheCleanupSwitch() {
        let missing = ModelInstaller.State.missing(bytesPresent: 0)
        var summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.active == .speech)
        #expect(summary.button == "Download Models (5.52 GB)")
        #expect(summary.lines == ModelInstaller.State.missing(bytesPresent: 0).menuLines(total: speechTotal, locale: Locale(identifier: "en")))
        #expect(!summary.cancels)
        #expect(summary.progress == nil)
        // Without cleanup, the button says the cleanup model is left out.
        summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Download Speech Model Only (2.47 GB)")
        // Bytes on disk from before: what is left of both.
        summary = DownloadSummary(speech: .missing(bytesPresent: 470_000_000), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 50_000_000), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Resume Download (5 GB left)")
        // Without cleanup, what is left of the speech model alone.
        summary = DownloadSummary(speech: .missing(bytesPresent: 470_000_000), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 50_000_000), cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Resume Download (2 GB left)")
        // A failed download is tried again either way.
        summary = DownloadSummary(speech: .failed(.offline), speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Try Again")
    }

    @Test func whileTheSpeechModelDownloadsTheBarCoversBoth() {
        let summary = DownloadSummary(speech: .downloading(bytes: speechTotal, source: .huggingFace), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 0), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.progress?.total == speechTotal + cleanupTotal)
        #expect(summary.lines == ["Downloading the speech model, then the cleanup model: 44% of 5.52 GB", "From huggingface.co"])
        #expect(summary.button == "Cancel Download")
        #expect(summary.cancels)
        // Started from the menu while cleanup was only proposed: the speech model alone.
        let fromMenu = DownloadSummary(speech: .downloading(bytes: 0, source: nil), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 0), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(fromMenu.progress?.total == speechTotal)
        #expect(!fromMenu.lines.contains { $0.contains("cleanup model") })
    }

    @Test func dictationIsReadyWhileTheCleanupModelDownloads() {
        let summary = DownloadSummary(speech: .installed(folder), speechTotal: speechTotal, cleanup: .downloading(bytes: 0, source: nil), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.active == .cleanup)
        #expect(summary.lines.first == "The speech model is ready, so you can dictate while the cleanup model downloads.")
        #expect(summary.progress?.completed == speechTotal)
        #expect(summary.cancels)
        // Turned on later, with the speech model in place at launch: the cleanup model alone.
        let later = DownloadSummary(speech: .installed(folder), speechTotal: speechTotal, cleanup: .downloading(bytes: 0, source: nil), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: false, locale: Locale(identifier: "en"))
        #expect(later.progress?.total == cleanupTotal)
        #expect(later.lines.contains("Downloading the cleanup model: 0% of 3.05 GB"))
    }

    @Test func nothingIsLeftOnceTheWantedModelsAreInPlace() {
        let summary = DownloadSummary(speech: .installed(folder), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 0), cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true)
        #expect(summary.active == nil)
        #expect(summary.lines.isEmpty)
        #expect(summary.button == nil)
        #expect(summary.progress == nil)
    }

    @Test func theStepFollowsThePickedLanguage() {
        let chinese = Locale(identifier: "zh-Hans")
        let missing = ModelInstaller.State.missing(bytesPresent: 0)
        let summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: chinese)
        #expect(summary.button == "下载模型（5.52 GB）")
        let speechOnly = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, locale: chinese)
        #expect(speechOnly.button == "仅下载语音模型（2.47 GB）")
        #expect(GuideStep.download.line(locale: chinese) == "你好，我是 Orra。先下载我需要的模型，只需一次。")
        #expect(GuideStep.ready.line(locale: Locale(identifier: "en")) == "All set! Hold the talk key and say hello.")
    }

    // MARK: The guide

    private func checklist(model: ModelInstaller.State = .missing(bytesPresent: 0), modelState: PushToTalkController.ModelState = .notLoaded, microphone: MicrophoneAccess = .notDetermined, hotkeyActive: Bool = false) -> SetupChecklist {
        SetupChecklist(installer: model, modelState: modelState, microphone: microphone, hotkeyActive: hotkeyActive)
    }

    @Test func theGuideTalksAboutTheFirstStepLeft() {
        #expect(GuideStep.current(checklist: checklist(), talkKeyChosen: false, downloadingCleanup: false) == .download)
        // While the speech model downloads, the guide moves on to the permissions.
        let downloading = checklist(model: .downloading(bytes: 1, source: nil))
        #expect(GuideStep.current(checklist: downloading, talkKeyChosen: false, downloadingCleanup: false) == .microphone)
        let heard = checklist(model: .downloading(bytes: 1, source: nil), microphone: .authorized)
        #expect(GuideStep.current(checklist: heard, talkKeyChosen: false, downloadingCleanup: false) == .accessibility)
        let allowed = checklist(model: .downloading(bytes: 1, source: nil), microphone: .authorized, hotkeyActive: true)
        #expect(GuideStep.current(checklist: allowed, talkKeyChosen: false, downloadingCleanup: false) == .talkKey)
        #expect(GuideStep.current(checklist: allowed, talkKeyChosen: true, downloadingCleanup: false) == .downloading)
        let ready = checklist(model: .installed(folder), modelState: .ready, microphone: .authorized, hotkeyActive: true)
        #expect(GuideStep.current(checklist: ready, talkKeyChosen: true, downloadingCleanup: true) == .downloading)
        #expect(GuideStep.current(checklist: ready, talkKeyChosen: true, downloadingCleanup: false) == .ready)
    }

    @Test func everyStepHasALine() {
        let english = Locale(identifier: "en")
        let lines = GuideStep.allCases.map { $0.line(locale: english) }
        #expect(Set(lines).count == GuideStep.allCases.count)
        #expect(lines.allSatisfy { !$0.isEmpty })
    }

    // MARK: Driving the installers

    /// Counts the requests of one installer.
    nonisolated final class Calls: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func makeSetup(memory: UInt64 = 48 << 30, saved: Bool? = nil, savedNow: @escaping (Bool) -> Void = { _ in }) -> (setup: SetupDownload, speechCalls: Calls, cleanupCalls: Calls) {
        let temporary = TemporaryModelFolders()
        let cleanupFolders = TemporaryModelFolders()
        let speechCalls = Calls()
        let cleanupCalls = Calls()
        func environment(_ calls: Calls) -> ModelDownload.Environment {
            ModelDownload.Environment(
                fetch: FileFetch { _, _, _, _, _, _ in
                    calls.add()
                    throw URLError(.notConnectedToInternet)
                },
                freeSpace: { _ in 100_000_000_000 },
                sleep: { _ in }
            )
        }
        let speech = ModelInstaller(manifest: temporary.manifest, folders: temporary.folders, environment: environment(speechCalls))
        let cleanup = TextCleanup(
            isOn: saved ?? false,
            save: savedNow,
            models: ModelInstaller(manifest: cleanupFolders.manifest, folders: cleanupFolders.folders, environment: environment(cleanupCalls)),
            engine: CleanupEngine(load: { _ in }, unload: {}, complete: { $0 })
        )
        return (SetupDownload(speech: speech, cleanup: cleanup, physicalMemory: memory, savedChoice: { saved }), speechCalls, cleanupCalls)
    }

    @Test func aNewUserSeesCleanupOnAndNothingIsSavedOrDownloadedYet() async {
        var saves: [Bool] = []
        let (setup, speechCalls, cleanupCalls) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        #expect(setup.proposesCleanup)
        #expect(setup.wantsCleanup)
        #expect(!setup.cleanup.isOn)
        #expect(saves.isEmpty)
        #expect(speechCalls.value == 0)
        #expect(cleanupCalls.value == 0)
    }

    @Test func aSmallMacOrASavedChoiceGetsNoProposal() async {
        let (small, _, _) = makeSetup(memory: 8 << 30)
        await small.speech.prepare()
        small.lookAtLaunch()
        #expect(!small.wantsCleanup)
        #expect(!small.hasEnoughMemory)
        let (declined, _, _) = makeSetup(saved: false)
        await declined.speech.prepare()
        declined.lookAtLaunch()
        #expect(!declined.wantsCleanup)
        // Off from before, not turned off in the window: no line on what is lost.
        #expect(!declined.turnedCleanupOff)
    }

    /// Turning the switch on again ends the line on what is lost.
    @Test func turningTheSwitchBackOnEndsTheWarning() async {
        let (setup, _, _) = makeSetup()
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        setup.setCleanup(false)
        #expect(setup.turnedCleanupOff)
        setup.setCleanup(true)
        #expect(!setup.turnedCleanupOff)
        #expect(setup.wantsCleanup)
    }

    @Test func turningTheProposalOffIsSavedAndStaysOff() async {
        var saves: [Bool] = []
        let (setup, _, cleanupCalls) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        #expect(!setup.turnedCleanupOff)
        setup.setCleanup(false)
        #expect(saves == [false])
        #expect(!setup.wantsCleanup)
        // The window says what is lost, until the switch is on again.
        #expect(setup.turnedCleanupOff)
        setup.start()
        await setup.speech.waitForDownload()
        #expect(!setup.cleanup.isOn)
        setup.speechInstalled()
        #expect(cleanupCalls.value == 0)
    }

    /// Download turns cleanup on and fetches the speech model only. The cleanup model
    /// follows once the speech model is in place.
    @Test func theCleanupModelWaitsForTheSpeechModel() async {
        var saves: [Bool] = []
        let (setup, speechCalls, cleanupCalls) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        setup.start()
        #expect(saves == [true])
        #expect(setup.cleanup.isOn)
        #expect(setup.queuesCleanup)
        await setup.speech.waitForDownload()
        #expect(speechCalls.value > 0)
        #expect(cleanupCalls.value == 0)
        setup.speechInstalled()
        #expect(!setup.queuesCleanup)
        await setup.cleanup.models.waitForDownload()
        #expect(cleanupCalls.value > 0)
    }

    /// Cancel during the speech model keeps cleanup on, and nothing follows on its own.
    @Test func cancelDuringTheSpeechModelDropsTheQueue() async {
        let (setup, _, cleanupCalls) = makeSetup()
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        setup.start()
        setup.cancel()
        await setup.speech.waitForDownload()
        #expect(setup.cleanup.isOn)
        #expect(!setup.queuesCleanup)
        setup.speechInstalled()
        #expect(cleanupCalls.value == 0)
    }

    /// A speech model that came from the menu ends a proposal the user never answered.
    @Test func aProposalEndsWhenTheSpeechModelComesFromTheMenu() async {
        var saves: [Bool] = []
        let (setup, _, cleanupCalls) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        setup.lookAtLaunch()
        setup.speechInstalled()
        #expect(!setup.wantsCleanup)
        #expect(saves.isEmpty)
        #expect(cleanupCalls.value == 0)
    }
}
