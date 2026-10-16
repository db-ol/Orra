import Foundation
import Synchronization
import Testing
@testable import Orra

/// The welcome window's one download, which includes the cleanup model for a new user on a
/// Mac with enough memory, its bar and text, and the step its guide talks about.
@MainActor
struct SetupDownloadTests {
    private let folder = URL(fileURLWithPath: "/nonexistent/Models/qwen3")
    private let speechTotal = ModelManifest.qwen3.totalBytes
    private let cleanupTotal = ModelManifest.qwen35Cleanup.totalBytes

    // MARK: Who gets the cleanup model

    @Test func aNewUserWithSixteenGigabytesOrMoreGetsTheCleanupModel() {
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

    @Test func aNewUsersButtonNamesBothModels() {
        let missing = ModelInstaller.State.missing(bytesPresent: 0)
        var summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.active == .speech)
        #expect(summary.button == "Download Models (5.52 GB)")
        #expect(summary.lines == ["The speech model, and a second model that tidies up what you say, such as fillers and corrections you make while speaking."])
        #expect(!summary.cancels)
        #expect(summary.progress == nil)
        // Bytes on disk from before: what is left of both.
        summary = DownloadSummary(speech: .missing(bytesPresent: 470_000_000), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 50_000_000), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Resume Download (5 GB left)")
        // A failed download is tried again.
        summary = DownloadSummary(speech: .failed(.offline), speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Try Again")
        // A speech model download from the menu failed: a start here also queues the
        // cleanup model, so the button names both.
        summary = DownloadSummary(speech: .failed(.offline), speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Download Models (5.52 GB)")
        #expect(summary.lines == ["This Mac is offline. Connect to the internet, then try again."])
    }

    /// With the cleanup model already in place, only the speech model is left to download,
    /// so the step names it alone and its size.
    @Test func withTheCleanupModelInPlaceOnlyTheSpeechModelIsNamed() {
        let installed = ModelInstaller.State.installed(folder)
        var summary = DownloadSummary(speech: .missing(bytesPresent: 0), speechTotal: speechTotal, cleanup: installed, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.active == .speech)
        #expect(summary.button == "Download Speech Model (2.47 GB)")
        #expect(summary.lines == ["Orra needs its speech model to transcribe."])
        summary = DownloadSummary(speech: .failed(.offline), speechTotal: speechTotal, cleanup: installed, cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Try Again")
    }

    /// Under 16 GB with no saved choice, the step says why cleanup stays off. With cleanup
    /// off by a saved choice, it says nothing about memory.
    @Test func withoutCleanupOnlyTheSpeechModelIsNamed() {
        let missing = ModelInstaller.State.missing(bytesPresent: 0)
        var summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, memoryKeepsCleanupOff: 8, locale: Locale(identifier: "en"))
        #expect(summary.button == "Download Speech Model (2.47 GB)")
        #expect(summary.lines == ["Cleanup stays off on this Mac because it has 8 GB of memory. You can turn it on later in Settings, General."])
        summary = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.button == "Download Speech Model (2.47 GB)")
        #expect(summary.lines == ["Orra needs its speech model to transcribe."])
        // What is left of the speech model alone.
        summary = DownloadSummary(speech: .missing(bytesPresent: 470_000_000), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 50_000_000), cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, memoryKeepsCleanupOff: 8, locale: Locale(identifier: "en"))
        #expect(summary.button == "Resume Download (2 GB left)")
        summary = DownloadSummary(speech: .failed(.offline), speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, memoryKeepsCleanupOff: 8, locale: Locale(identifier: "en"))
        #expect(summary.button == "Try Again")
        #expect(summary.lines == ["This Mac is offline. Connect to the internet, then try again."])
    }

    @Test func whileTheSpeechModelDownloadsTheBarCoversBoth() {
        let summary = DownloadSummary(speech: .downloading(bytes: speechTotal, source: .huggingFace), speechTotal: speechTotal, cleanup: .missing(bytesPresent: 0), cleanupTotal: cleanupTotal, wantsCleanup: true, queuesCleanup: true, includesSpeech: true, locale: Locale(identifier: "en"))
        #expect(summary.progress?.total == speechTotal + cleanupTotal)
        #expect(summary.lines == ["Downloading the speech model, then the cleanup model: 44% of 5.52 GB", "From huggingface.co"])
        #expect(summary.button == "Cancel Download")
        #expect(summary.cancels)
        // Started from the menu before the window's download: the speech model alone.
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
        // Turned on in Settings, with the speech model in place at launch: the cleanup model
        // alone.
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
        #expect(summary.lines == ["包括语音模型，以及整理文字的第二个模型，它会去掉语气词，并按你说出口的更正改好内容。"])
        let speechOnly = DownloadSummary(speech: missing, speechTotal: speechTotal, cleanup: missing, cleanupTotal: cleanupTotal, wantsCleanup: false, queuesCleanup: false, includesSpeech: true, memoryKeepsCleanupOff: 8, locale: chinese)
        #expect(speechOnly.button == "下载语音模型（2.47 GB）")
        #expect(speechOnly.lines == ["这台 Mac 只有 8 GB 内存，所以整理功能先关着。之后可以在“设置 → 通用”里打开。"])
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

    @Test func aNewUserGetsBothModelsAndNothingIsSavedOrDownloadedYet() async {
        var saves: [Bool] = []
        let (setup, speechCalls, cleanupCalls) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        #expect(setup.proposesCleanup)
        #expect(setup.wantsCleanup)
        #expect(setup.memoryKeepsCleanupOff == nil)
        #expect(!setup.cleanup.isOn)
        #expect(setup.summary(locale: Locale(identifier: "en")).button?.hasPrefix("Download Models (") == true)
        #expect(saves.isEmpty)
        #expect(speechCalls.value == 0)
        #expect(cleanupCalls.value == 0)
    }

    /// Under 16 GB the download is the speech model alone, nothing is saved, and the step
    /// says why. Turning cleanup on in Settings ends the line.
    @Test func aSmallMacGetsTheSpeechModelAlone() async {
        var saves: [Bool] = []
        let (small, _, cleanupCalls) = makeSetup(memory: 8 << 30, savedNow: { saves.append($0) })
        await small.speech.prepare()
        await small.cleanup.start()
        small.lookAtLaunch()
        #expect(!small.wantsCleanup)
        #expect(small.memoryKeepsCleanupOff == 8)
        #expect(small.summary(locale: Locale(identifier: "en")).lines.first?.contains("8 GB") == true)
        small.start()
        await small.speech.waitForDownload()
        small.speechInstalled()
        #expect(saves.isEmpty)
        #expect(!small.cleanup.isOn)
        #expect(cleanupCalls.value == 0)
        // Turned on in Settings.
        small.cleanup.confirmDownload()
        #expect(small.memoryKeepsCleanupOff == nil)
        await small.cleanup.models.waitForDownload()
    }

    /// A saved choice is never flipped. Off: the speech model alone, with no line on memory.
    @Test func aSavedChoiceOffKeepsCleanupOff() async {
        var saves: [Bool] = []
        for memory: UInt64 in [8 << 30, 48 << 30] {
            let (declined, _, cleanupCalls) = makeSetup(memory: memory, saved: false, savedNow: { saves.append($0) })
            await declined.speech.prepare()
            await declined.cleanup.start()
            declined.lookAtLaunch()
            #expect(!declined.wantsCleanup)
            #expect(declined.memoryKeepsCleanupOff == nil)
            let summary = declined.summary(locale: Locale(identifier: "en"))
            #expect(summary.button?.hasPrefix("Download Speech Model (") == true)
            #expect(!summary.lines.contains { $0.contains("memory") })
            declined.start()
            await declined.speech.waitForDownload()
            declined.speechInstalled()
            #expect(!declined.cleanup.isOn)
            #expect(cleanupCalls.value == 0)
        }
        #expect(saves.isEmpty)
    }

    /// Saved on, also on a small Mac: both models.
    @Test func aSavedChoiceOnGetsBothModels() async {
        let (setup, _, _) = makeSetup(memory: 8 << 30, saved: true)
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        #expect(!setup.proposesCleanup)
        #expect(setup.wantsCleanup)
        #expect(setup.memoryKeepsCleanupOff == nil)
        #expect(setup.summary(locale: Locale(identifier: "en")).button?.hasPrefix("Download Models (") == true)
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

    /// During a speech model download started from the menu, the step names the speech
    /// model alone, since the cleanup model would not follow, and nothing is saved.
    @Test func aMenuDownloadLeavesTheCleanupModelOut() async {
        var saves: [Bool] = []
        let (setup, _, _) = makeSetup(savedNow: { saves.append($0) })
        await setup.speech.prepare()
        await setup.cleanup.start()
        setup.lookAtLaunch()
        #expect(setup.wantsCleanup)
        setup.speech.download()
        #expect(setup.speech.state.isBusy)
        #expect(!setup.wantsCleanup)
        #expect(!setup.queuesCleanup)
        await setup.speech.waitForDownload()
        #expect(saves.isEmpty)
    }

    /// A speech model that came from the menu ends a new user's download that was never
    /// started, and cleanup stays off.
    @Test func aNewUsersDownloadEndsWhenTheSpeechModelComesFromTheMenu() async {
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
