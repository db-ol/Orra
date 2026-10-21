import Foundation
import Observation
import os

/// Cleanup and translation with the local text model: the two settings, the model's
/// download and loading, and the closures PushToTalkController calls.
///
/// Both are off until the user turns them on. They share one model, which translates as
/// well as it cleans up. Turning either on asks first when the model still has to be
/// downloaded and no download was agreed to for the other, and nothing goes online before
/// the user confirms. While either is on the model is loaded at launch and stays loaded
/// while the user dictates. After `idleUnloadDelay` without a dictation it is unloaded, and
/// the next press of the talk key or the translation key loads it again while the user
/// speaks, see `dictationStarted()`. Turning the last one off unloads it and stops a
/// download. Translation works with cleanup off: the translation prompt cleans up and
/// translates in one answer, and the cleanup in it is used only while cleanup is on, see
/// TranslationStep. Meeting captions and Projects keep the model loaded while they need it,
/// see `captionsStarted()` and `projectsStarted()`. Turning Projects on asks before its
/// download too, see `turnOnProjects()`.
@Observable
final class TextCleanup {
    nonisolated enum EngineState: Equatable, Sendable {
        case unloaded
        case loading
        case ready
        /// Out of memory because nobody dictated for `idleUnloadDelay`. The next press of
        /// the talk key loads the model again, so Settings shows it as ready.
        case unloadedWhileIdle
        case failed
    }

    /// Whether the user turned cleanup on. Saved through `save` whenever it changes.
    private(set) var isOn: Bool
    /// Whether the user turned translation on, so the translation key pastes translated
    /// text. Saved through `saveTranslation` whenever it changes.
    private(set) var translationIsOn: Bool
    /// Which way dictations are translated. Saved through `saveDirection` whenever it
    /// changes.
    private(set) var translationDirection: TranslationDirection
    /// The user's dictation language, which translation goes between with English, see
    /// `setDictationLanguage(_:)`. AppDelegate keeps it in step with PushToTalkController.
    private(set) var dictationLanguage: DictationLanguage = .chinese
    /// The language Live Captions translate into as the user picked it, nil until they
    /// pick one, see CaptionTargetPreference. Saved through `saveCaptionTarget` whenever it
    /// changes.
    private(set) var pickedCaptionTarget: TranslationTarget?
    /// True while the Clean Up Text page asks whether to download the model.
    var isConfirmingDownload = false
    /// True while Settings asks whether to download the model for translation.
    var isConfirmingTranslationDownload = false
    /// Whether the model can run.
    private(set) var engineState: EngineState = .unloaded
    /// True while meeting captions run, which translate with the model. The model is then
    /// loaded when it is in place and stays loaded, see `captionsStarted()`.
    private(set) var captionsNeedModel = false
    /// How many holders Projects has on the model: one while the Projects window is open,
    /// and one for each request of the user while it runs, see `projectsStarted()`.
    private(set) var projectsHolders = 0
    /// True while the caption window asks whether to download the model.
    var isConfirmingCaptionDownload = false
    /// True while the Projects page asks whether to download the model, see
    /// `turnOnProjects()`.
    var isConfirmingProjectsDownload = false
    /// Whether the user agreed on the Projects page to download the model, until Projects
    /// turns off. Such a download goes on while nothing loads the model, such as with the
    /// Projects window closed, see `projectsTurnedOff()`.
    private(set) var projectsAgreedToDownload = false
    let models: ModelInstaller

    @ObservationIgnored private let engine: CleanupEngine
    @ObservationIgnored private let save: (Bool) -> Void
    @ObservationIgnored private let saveTranslation: (Bool) -> Void
    @ObservationIgnored private let saveDirection: (TranslationDirection) -> Void
    @ObservationIgnored private let saveCaptionTarget: (TranslationTarget) -> Void
    /// The caption target while none is picked, read each time, so it follows the user's
    /// own language, see CaptionTargetPreference.defaultTarget(ownLanguage:).
    @ObservationIgnored private let defaultCaptionTarget: () -> TranslationTarget
    /// The latest load or unload. Each waits for the one before it, so they never overlap
    /// and never swap order.
    @ObservationIgnored private var engineWork: Task<Void, Never>?
    /// Counts the loads asked for, so a load the user turned off and on again since leaves
    /// the state alone.
    @ObservationIgnored private var loadGeneration = 0
    /// The folder of the latest load, for loading again after an idle unload.
    @ObservationIgnored private var folder: URL?
    /// How long the model stays loaded without a dictation. Nil keeps it loaded.
    @ObservationIgnored private let idleUnloadDelay: Duration?
    /// The longest a finished transcript waits for a model that is still loading.
    @ObservationIgnored private let loadWait: Duration
    /// Waits for a time. Tests pass a clock they move themselves.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Unloads the model once `idleUnloadDelay` has passed without a dictation.
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    /// True from the press of the talk key or the translation key until the dictation is over. No idle unload
    /// happens in between.
    @ObservationIgnored private var isDictating = false
    /// True when the first holder of Projects came during a dictation, so its load waits
    /// until the dictation is over, see `projectsStarted()`.
    @ObservationIgnored private var projectsLoadWaitsForDictation = false
    /// Transcripts waiting for the load under way, resumed when it ends, when the last of
    /// cleanup and translation is turned off or when their wait is over.
    @ObservationIgnored private var loadWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiter = 0
    /// True once a wait of this dictation ran out, so it does not wait again.
    @ObservationIgnored private var loadWaitRanOut = false

    /// - Parameters:
    ///   - isOn: Whether cleanup is on, as saved.
    ///   - save: Saves the setting after the user changes it.
    ///   - translationIsOn: Whether translation is on, as saved.
    ///   - saveTranslation: Saves that setting after the user changes it.
    ///   - translationDirection: Which way to translate, as saved.
    ///   - saveDirection: Saves the direction after the user changes it.
    ///   - captionTarget: The language Live Captions translate into, as saved, nil for
    ///     none.
    ///   - saveCaptionTarget: Saves the caption target after the user picks one.
    ///   - defaultCaptionTarget: The caption target while none is picked.
    ///   - models: The installer for the cleanup model. Tests pass one with temporary
    ///     folders and a stand in network.
    ///   - engine: Loads and runs the model. Tests pass a stand in.
    ///   - idleUnloadDelay: How long the model stays loaded without a dictation, nil for
    ///     as long as cleanup or translation is on.
    ///   - loadWait: The longest a finished transcript waits for the model to load.
    ///   - sleep: Waits for a time. Tests pass a clock they move.
    init(
        isOn: Bool,
        save: @escaping (Bool) -> Void,
        translationIsOn: Bool = false,
        saveTranslation: @escaping (Bool) -> Void = { _ in },
        translationDirection: TranslationDirection = .automatic,
        saveDirection: @escaping (TranslationDirection) -> Void = { _ in },
        captionTarget: TranslationTarget? = nil,
        saveCaptionTarget: @escaping (TranslationTarget) -> Void = { _ in },
        defaultCaptionTarget: @escaping () -> TranslationTarget = { CaptionTargetPreference.defaultTarget(ownLanguage: nil) },
        models: ModelInstaller,
        engine: CleanupEngine = .live(),
        idleUnloadDelay: Duration? = CleanupIdlePreference.defaultDelay,
        loadWait: Duration = TextCleanup.defaultLoadWait,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.isOn = isOn
        self.save = save
        self.translationIsOn = translationIsOn
        self.saveTranslation = saveTranslation
        self.translationDirection = translationDirection
        self.saveDirection = saveDirection
        pickedCaptionTarget = captionTarget
        self.saveCaptionTarget = saveCaptionTarget
        self.defaultCaptionTarget = defaultCaptionTarget
        self.models = models
        self.engine = engine
        self.idleUnloadDelay = idleUnloadDelay
        self.loadWait = loadWait
        self.sleep = sleep
        // Set before anything can install the model, so every install loads it.
        models.onInstalled = { [weak self] folder in
            self?.load(from: folder)
        }
    }

    /// The app's cleanup. Creating it touches neither the disk nor the network.
    static func live() -> TextCleanup {
        TextCleanup(
            isOn: CleanupPreference.load(),
            save: { CleanupPreference.save($0) },
            translationIsOn: TranslationPreference.load(),
            saveTranslation: { TranslationPreference.save($0) },
            translationDirection: TranslationDirection.load(),
            saveDirection: { $0.save() },
            captionTarget: CaptionTargetPreference.saved(),
            saveCaptionTarget: { CaptionTargetPreference.save($0) },
            // Reads Orra's language as saved, so one picked in the welcome window counts
            // at once.
            defaultCaptionTarget: { CaptionTargetPreference.defaultTarget(ownLanguage: OwnLanguage.current()) },
            models: ModelInstaller(
                manifest: .qwen35Cleanup,
                folders: .liveCleanup,
                sources: ModelSource.servers(launchArguments: ProcessInfo.processInfo.arguments),
                environment: .live
            ),
            idleUnloadDelay: CleanupIdlePreference.load()
        )
    }

    /// How long a finished transcript waits at most for the model, which the press of the
    /// talk key or the translation key started to load. On an M5 Pro in a Release build,
    /// the model was loaded 1.1 s after the press, and the first load in a new process took
    /// 1.2 to 2.1 s, so only a hold under about 1.2 s waits at all. 3 s leaves room for a
    /// slower Mac or disk. Past it the text is pasted without the model, as when a cleanup
    /// takes too long.
    static let defaultLoadWait: Duration = .seconds(3)

    /// At launch: looks for the model with local files only, and loads it when cleanup or
    /// translation is on, so a failed load shows in Settings at once and the first
    /// dictation needs no wait. Without a dictation it is unloaded after
    /// `idleUnloadDelay`. Never goes online.
    func start() async {
        await models.prepare()
    }

    /// The closures for PushToTalkController.
    var model: CleanupModel {
        CleanupModel(
            isOn: { [weak self] in self?.isOn ?? false },
            waitUntilLoaded: { [weak self] in await self?.waitUntilLoaded() ?? false },
            dictationStarted: { [weak self] in self?.dictationStarted() },
            dictationEnded: { [weak self] in self?.dictationEnded() },
            complete: engine.complete
        )
    }

    /// The talk key or the translation key went down. Stops the idle timer, and loads the
    /// model again when it was unloaded while idle, so the load overlaps the recording.
    /// Loading, filling the prefix cache and warming up took about 1.2 s in a Release
    /// build, less than most holds.
    func dictationStarted() {
        isDictating = true
        loadWaitRanOut = false
        modelNeededNow(loadingAgainFrom: folder, for: "a dictation")
    }

    /// A dictation or captions need the model now. Stops the idle timer, and loads the model
    /// from `folder` again when it was unloaded while idle. True when it loads again.
    @discardableResult
    private func modelNeededNow(loadingAgainFrom folder: URL?, for use: String) -> Bool {
        idleTimer?.cancel()
        idleTimer = nil
        guard needsModel, engineState == .unloadedWhileIdle, let folder else { return false }
        // `load` starts only from unloaded or failed, so its other callers leave a model
        // unloaded while idle alone.
        engineState = .unloaded
        Logger.rewrite.notice("Loading the cleanup model again for \(use, privacy: .public)")
        load(from: folder)
        return true
    }

    /// The dictation is over, pasted or not. Loads the model for Projects when its first
    /// holder came during the dictation, and starts the idle timer.
    func dictationEnded() {
        isDictating = false
        if projectsLoadWaitsForDictation {
            projectsLoadWaitsForDictation = false
            loadForProjects()
        }
        scheduleIdleUnload()
    }

    /// Whether the model can clean up the transcript now. Waits for a load under way, at
    /// most `loadWait`, and false when cleanup is off, the model failed to load or the
    /// wait ran out.
    func waitUntilLoaded() async -> Bool {
        await waitUntilLoaded(for: "cleanup") { $0.isOn }
    }

    /// Whether the model can translate the transcript now, the same way.
    func waitUntilLoadedForTranslation() async -> Bool {
        await waitUntilLoaded(for: "translation") { $0.translationIsOn }
    }

    /// True when the model is in memory and nothing unloads it before the next dictation.
    private var isLoaded: Bool {
        engineState == .ready
    }

    /// Waits for a load under way while `isWanted` holds, once per dictation, so a
    /// translation that ran out of time is not followed by a second wait for cleanup.
    /// Logs how long it waited and for what, never text.
    private func waitUntilLoaded(for use: String, isWanted: (TextCleanup) -> Bool) async -> Bool {
        if isWanted(self), engineState == .loading, !loadWaitRanOut {
            let started = ContinuousClock.now
            await waitForLoadUnderWay()
            let loaded = isWanted(self) && isLoaded
            Logger.rewrite.notice("Waited \(started.duration(to: .now), privacy: .public) for the cleanup model for \(use, privacy: .public), loaded: \(loaded, privacy: .public)")
            return loaded
        }
        return isWanted(self) && isLoaded
    }

    /// Returns when the load under way ends, the last of cleanup and translation is turned
    /// off, or `loadWait` passes.
    private func waitForLoadUnderWay() async {
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { [sleep, loadWait] in
            guard (try? await sleep(loadWait)) != nil else { return }
            self.loadWaitRanOut = true
            self.resumeWaiter(id)
        }
        await withCheckedContinuation { continuation in
            loadWaiters[id] = continuation
        }
        timer.cancel()
    }

    private func resumeWaiter(_ id: Int) {
        loadWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeAllWaiters() {
        let waiters = loadWaiters.values
        loadWaiters = [:]
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Starts the idle timer again, unless cleanup and translation are off, a dictation is
    /// under way, captions or Projects hold the model, or it is not loaded.
    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        idleTimer = nil
        guard let idleUnloadDelay, needsModel, !isDictating, !captionsNeedModel, !projectsNeedModel, isLoaded else { return }
        idleTimer = Task { [weak self, sleep] in
            guard (try? await sleep(idleUnloadDelay)) != nil, !Task.isCancelled else { return }
            self?.unloadWhileIdle()
        }
    }

    /// Unloads the model after `idleUnloadDelay` without a dictation. Queued like every
    /// load and unload, so a press of the talk key during the unload loads the model again
    /// right after it. The unload drops the translation prefix caches too, and the next
    /// load fills them again.
    private func unloadWhileIdle() {
        idleTimer = nil
        guard needsModel, !isDictating, !captionsNeedModel, !projectsNeedModel, isLoaded else { return }
        engineState = .unloadedWhileIdle
        Logger.rewrite.notice("Unloading the cleanup model after no dictation for \(self.idleUnloadDelay ?? .zero, privacy: .public)")
        enqueue { [engine] in await engine.unload() }
    }

    /// The closures for PushToTalkController's translations.
    var translation: TranslationModel {
        TranslationModel(
            isReady: { [weak self] in self?.translationIsOn == true && self?.isLoaded == true },
            waitUntilLoaded: { [weak self] in await self?.waitUntilLoadedForTranslation() ?? false },
            direction: { [weak self] in self?.translationDirection ?? .automatic },
            complete: engine.translate
        )
    }

    /// Whether the model is wanted: cleanup or translation is on, captions run, or Projects
    /// holds it.
    var needsModel: Bool {
        isOn || translationIsOn || captionsNeedModel || projectsNeedModel
    }

    /// True while the Projects window is open or a request of the user runs there, see
    /// `projectsStarted()`.
    var projectsNeedModel: Bool {
        projectsHolders > 0
    }

    /// Whether captions can translate now: they run and the model is in memory. Captions
    /// never wait for a load, they show the transcript alone meanwhile.
    var isReadyForCaptions: Bool {
        captionsNeedModel && isLoaded
    }

    /// Meeting captions run in a mode that translates, from their start or from a switch
    /// away from Original only. Loads the model when it is in place, or again when it was
    /// unloaded while idle, and keeps it loaded until captions stop. Without the model the
    /// caption window offers the download, see `confirmCaptionDownload()`, and nothing goes
    /// online before the user agrees. With the model loaded already, the translation
    /// prompts are read ahead.
    func captionsStarted() {
        guard !captionsNeedModel else { return }
        captionsNeedModel = true
        let installed: URL? = if case .installed(let folder) = models.state { folder } else { nil }
        guard !modelNeededNow(loadingAgainFrom: installed, for: "captions"), let installed else { return }
        if isLoaded {
            prepareTranslation()
        } else {
            load(from: installed)
        }
    }

    /// Meeting captions stopped. Unloads the model and stops a download unless cleanup or
    /// translation still need it, and otherwise gives back the prefix caches only
    /// captions used and starts the idle timer.
    func captionsStopped() {
        guard captionsNeedModel else { return }
        captionsNeedModel = false
        isConfirmingCaptionDownload = false
        if needsModel {
            let generation = loadGeneration
            enqueue { [weak self, engine] in
                guard let self, generation == loadGeneration, isLoaded else { return }
                await engine.keepTranslationPrefixes(Self.keptRoutes(captionTarget: nil, dictationLanguage))
            }
            scheduleIdleUnload()
        } else {
            releaseModelIfUnneeded()
        }
    }

    /// The user agreed in the caption window to download the model. Only for as long as
    /// captions run, as for cleanup and translation, which stay off.
    func confirmCaptionDownload() {
        isConfirmingCaptionDownload = false
        guard captionsNeedModel else { return }
        models.download()
    }

    // MARK: Projects

    /// Projects takes a holder on the model: the Projects window when it opens, and a
    /// request of the user when it starts. Each holder gives it back with
    /// `projectsStopped()`. While one remains, the model is never unloaded for being idle.
    /// The first holder loads the model when it is in place, or again when it was unloaded
    /// while idle. During a dictation that load waits until the dictation is over, so it
    /// never competes with the speech model (AGENTS.md). Without the model nothing is
    /// downloaded, and `waitUntilLoadedForProjects()` says it is not there.
    func projectsStarted() {
        projectsHolders += 1
        guard projectsHolders == 1 else { return }
        guard !isDictating else {
            projectsLoadWaitsForDictation = true
            return
        }
        loadForProjects()
    }

    /// Loads the model for the holders of Projects, when it is in place and not loaded.
    private func loadForProjects() {
        guard projectsNeedModel else { return }
        let installed: URL? = if case .installed(let folder) = models.state { folder } else { nil }
        guard !modelNeededNow(loadingAgainFrom: installed, for: "Projects"), let installed, !isLoaded else { return }
        load(from: installed)
    }

    /// A holder of `projectsStarted()` lets go. After the last one, the model is unloaded
    /// at once when nothing else needs it, as after captions. While cleanup, translation or
    /// captions still need it, MLX's freed buffers go back and the model stays, until the
    /// idle time of cleanup and translation or for as long as captions run.
    func projectsStopped() {
        guard projectsHolders > 0 else { return }
        projectsHolders -= 1
        guard projectsHolders == 0 else { return }
        projectsLoadWaitsForDictation = false
        if needsModel {
            enqueue { [engine] in await engine.clearCache() }
            scheduleIdleUnload()
        } else {
            releaseModelIfUnneeded()
        }
    }

    /// How often Projects looks again whether Orra has found the model on disk.
    private static let projectsCheckInterval: Duration = .milliseconds(100)

    /// Whether Projects can run a job on the model now. Waits while Orra looks for the
    /// model on disk, at launch or after Try Again, while a load waits for the end of a
    /// dictation, and for a load under way, for as long as they take, since no dictation
    /// waits for this. False when no holder of `projectsStarted()` remains, when the model
    /// is not on this Mac, when it failed to load, and at once when the task is cancelled.
    func waitUntilLoadedForProjects() async -> Bool {
        // A model found on disk loads for the holders, see `load(from:)`, and one the
        // holders wanted during a dictation loads after it, see `projectsStarted()`.
        while projectsNeedModel, models.state == .checking || projectsLoadWaitsForDictation {
            guard (try? await sleep(Self.projectsCheckInterval)) != nil else { return false }
        }
        guard projectsNeedModel else { return false }
        if engineState == .unloadedWhileIdle {
            modelNeededNow(loadingAgainFrom: folder, for: "Projects")
        }
        if engineState == .loading {
            let started = ContinuousClock.now
            nextWaiter += 1
            let id = nextWaiter
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        loadWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeWaiter(id)
                }
            }
            Logger.rewrite.notice("Waited \(started.duration(to: .now), privacy: .public) for the cleanup model for Projects, loaded: \(self.projectsNeedModel && self.isLoaded, privacy: .public)")
        }
        return !Task.isCancelled && projectsNeedModel && isLoaded
    }

    /// The closures ProjectsModelQueue runs its jobs with: the model's job calls, each its
    /// own entry at the model gate, the wait for the model while Projects holds it, and a
    /// holder for each request of the user. The caller passes what makes a job pause, see
    /// ProjectsModelEnvironment.
    func projectsEnvironment(
        isDictating: @escaping () -> Bool,
        captionsOn: @escaping () -> Bool,
        memoryPressure: @escaping () -> ProjectsMemoryPressure.Level,
        voiceLoaded: @escaping () -> Bool,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ProjectsModelEnvironment {
        ProjectsModelEnvironment(
            startJob: engine.startJob,
            readSlice: engine.readSlice,
            writeBurst: engine.writeBurst,
            endJob: engine.endJob,
            isDictating: isDictating,
            captionsOn: captionsOn,
            memoryPressure: memoryPressure,
            voiceLoaded: voiceLoaded,
            physicalMemory: physicalMemory,
            waitUntilLoaded: { [weak self] in await self?.waitUntilLoadedForProjects() ?? false },
            holdModel: { [weak self] in self?.projectsStarted() },
            releaseModel: { [weak self] in self?.projectsStopped() },
            sleep: sleep
        )
    }

    /// The Projects switch in Settings is being turned on. True when Projects may go on at
    /// once: the model is in place or its download is being checked, or the user agreed to
    /// its download already, for cleanup, translation or Projects. Otherwise the page asks
    /// first, see `isConfirmingProjectsDownload` and `confirmProjectsDownload()`, and
    /// nothing goes online before the user agrees. That includes a download under way for
    /// captions alone, which stops when they do. False without asking while Orra still
    /// looks for the model on disk, see `canTurnOn`. Starts no download and loads nothing,
    /// since Projects loads the model only while its window is open or a request runs.
    func turnOnProjects() -> Bool {
        guard canTurnOn else { return false }
        switch models.state {
        case .installed, .verifying:
            return true
        case .checking, .missing, .failed, .downloading:
            if isOn || translationIsOn || projectsAgreedToDownload {
                return true
            }
            isConfirmingProjectsDownload = true
            return false
        }
    }

    /// The user agreed on the Projects page to download the model: in the question when
    /// turning Projects on, or with the button under the model's line, which names the
    /// size. The download goes on while Projects is on, also with its window closed, until
    /// `projectsTurnedOff()`.
    func confirmProjectsDownload() {
        isConfirmingProjectsDownload = false
        projectsAgreedToDownload = true
        models.download()
    }

    /// Whether Cancel Download may show on the Projects page: cleanup and translation are
    /// off and captions do not run, so the cancel stops nothing they wait for. Otherwise
    /// the cancel stays under the switch it turns off, or in the caption window.
    var canCancelProjectsDownload: Bool {
        !isOn && !translationIsOn && !captionsNeedModel
    }

    /// Cancel Download on the Projects page. The bytes stay for the next time, Projects
    /// stays on, and its page offers the download again. Does nothing while cleanup,
    /// translation or captions need the model, see `canCancelProjectsDownload`.
    func cancelProjectsDownload() {
        guard canCancelProjectsDownload else { return }
        projectsAgreedToDownload = false
        models.cancel()
    }

    /// Projects was turned off. Stops a download only Projects agreed to while nothing
    /// else needs the model. A download agreed to for cleanup or translation goes on.
    func projectsTurnedOff() {
        isConfirmingProjectsDownload = false
        guard projectsAgreedToDownload else { return }
        projectsAgreedToDownload = false
        if !needsModel, case .downloading = models.state {
            models.cancel()
        }
    }

    /// The switch on the Clean Up Text page was turned on. With the model in place cleanup
    /// starts at once. While translation is on, the user agreed to the download already,
    /// so cleanup is on at once and waits for the model like translation does. Otherwise
    /// Settings asks before anything is downloaded. While Orra still looks for the model on
    /// disk, Settings keeps the switch off, see `canTurnOn`.
    func turnOn() {
        guard !isOn, canTurnOn else { return }
        if case .installed(let folder) = models.state {
            setOn(true)
            load(from: folder)
        } else if translationIsOn {
            setOn(true)
        } else {
            isConfirmingDownload = true
        }
    }

    /// The Translation switch in Settings was turned on, which works like cleanup's
    /// switch, see `turnOn`. With the model loaded already, its translation prompts are
    /// read ahead, so the first translation is fast. A model unloaded while idle is left
    /// alone, and the next press of a key loads it and reads them.
    func turnOnTranslation() {
        guard !translationIsOn, canTurnOn else { return }
        if case .installed(let folder) = models.state {
            setTranslationOn(true)
            if isLoaded {
                prepareTranslation()
            } else if engineState != .unloadedWhileIdle {
                load(from: folder)
            }
        } else if isOn {
            setTranslationOn(true)
        } else {
            isConfirmingTranslationDownload = true
        }
    }

    /// The user picked which way to translate. Reads the prompt for the new target ahead
    /// while translation is on and the model is loaded. Captions have their own target.
    func setTranslationDirection(_ direction: TranslationDirection) {
        guard direction != translationDirection else { return }
        translationDirection = direction
        saveDirection(direction)
        if translationIsOn, isLoaded {
            prepareTranslation()
        }
    }

    /// The language Live Captions translate into: the one the user picked, or while there
    /// is none the default from their own language. Every sentence in another language
    /// goes into it, see CaptionTarget. The caption window and Settings show it.
    var captionTarget: TranslationTarget {
        pickedCaptionTarget ?? defaultCaptionTarget()
    }

    /// The user chose a caption target in the caption window or in Settings. Choosing the
    /// one they see already changes nothing, so a default does not turn into a pick.
    func pickCaptionTarget(_ target: TranslationTarget) {
        guard target != captionTarget else { return }
        setCaptionTarget(target)
    }

    /// Saves the language captions translate into: one the user picked, see
    /// `pickCaptionTarget`, or the one the launch step keeps for an earlier user, see
    /// LaunchMigrations. It counts from the next sentence. Reads its prompts ahead while
    /// captions run and the model is loaded.
    func setCaptionTarget(_ target: TranslationTarget) {
        guard target != pickedCaptionTarget else { return }
        pickedCaptionTarget = target
        saveCaptionTarget(target)
        guard captionsNeedModel else { return }
        Logger.captions.notice("Meeting captions now translate into \(self.captionTarget.logName, privacy: .public)")
        if isLoaded {
            prepareTranslation()
        }
    }

    /// The user's dictation language changed, or is known at launch. Drops the prompts of
    /// the language before and reads those of the new one ahead while translation or
    /// captions need the model and it is loaded. Otherwise the next load reads them.
    func setDictationLanguage(_ language: DictationLanguage) {
        guard language != dictationLanguage else { return }
        dictationLanguage = language
        if translationIsOn || captionsNeedModel, isLoaded {
            prepareTranslation()
        }
    }

    /// False while Orra looks for the model on disk, at launch or after Try Again, since
    /// only then does it know whether a download is needed.
    var canTurnOn: Bool {
        models.state != .checking
    }

    /// The user agreed to download the model for cleanup.
    func confirmDownload() {
        isConfirmingDownload = false
        setOn(true)
        models.download()
    }

    /// A new user started the welcome window's download, which includes the cleanup model,
    /// see SetupDownload. Its button names the download size, so nothing more is asked.
    /// With the model in place it loads at once. Otherwise its download follows the speech
    /// model's, which SetupDownload starts.
    func agreeToDownload() {
        setOn(true)
        if case .installed(let folder) = models.state {
            load(from: folder)
        }
    }

    /// The user agreed to download the model for translation.
    func confirmTranslationDownload() {
        isConfirmingTranslationDownload = false
        setTranslationOn(true)
        models.download()
    }

    /// Download, Resume Download or Try Again under a switch, which name the size
    /// themselves, while cleanup or translation is on.
    func download() {
        guard needsModel else { return }
        models.download()
    }

    /// Cancel Download under a switch. The bytes stay for the next time, and cleanup and
    /// translation are off until the user turns one on again, since neither works without
    /// the model. A download Projects agreed to stops too. Projects stays on, and its page
    /// offers the download again.
    func cancelDownload() {
        models.cancel()
        projectsAgreedToDownload = false
        setOn(false)
        setTranslationOn(false)
    }

    /// The cleanup switch was turned off. Stops a download and unloads the model unless
    /// translation still needs it.
    func turnOff() {
        guard isOn else { return }
        setOn(false)
        releaseModelIfUnneeded()
    }

    /// The translation switch was turned off. Stops a download and unloads the model
    /// unless cleanup still needs it.
    func turnOffTranslation() {
        guard translationIsOn else { return }
        setTranslationOn(false)
        releaseModelIfUnneeded()
    }

    /// Unloads the model once nothing needs it, and stops its download unless Projects
    /// agreed to it.
    private func releaseModelIfUnneeded() {
        guard !needsModel else { return }
        if case .downloading = models.state, !projectsAgreedToDownload {
            models.cancel()
        }
        loadGeneration += 1
        engineState = .unloaded
        idleTimer?.cancel()
        idleTimer = nil
        resumeAllWaiters()
        enqueue { [engine] in await engine.unload() }
    }

    /// Try Again after the model failed to load: checks the files, hashes included, and
    /// loads them again, or leads back to Download when one is damaged.
    func retryLoading() async {
        engineState = .unloaded
        await models.prepare(checkingHashes: true)
    }

    private func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        save(on)
    }

    private func setTranslationOn(_ on: Bool) {
        guard on != translationIsOn else { return }
        translationIsOn = on
        saveTranslation(on)
    }

    /// The targets whose translation prompts are read ahead for a direction of a user who
    /// dictates in Chinese: the fixed one, or both for the automatic direction, which picks
    /// one per dictation. English first, since most dictations into Orra are Chinese. Each
    /// takes about 0.8 s on the GPU and keeps about 110 MB, see docs/manual-testing.md.
    nonisolated static func preparedTargets(_ direction: TranslationDirection) -> [TranslationTarget] {
        preparedRoutes(direction, .chinese).map(\.target)
    }

    /// The routes whose prompts are read ahead for a direction and a dictation language:
    /// the route of the direction as it acts for that language, see
    /// TranslationDirection.effective(for:), or both of the language for Automatic.
    nonisolated static func preparedRoutes(_ direction: TranslationDirection, _ language: DictationLanguage) -> [TranslationRoute] {
        switch direction.effective(for: language) {
        case .automatic: language.translationRoutes
        case .english: [TranslationRoute(language, into: .english)]
        case .chinese, .japanese, .spanish: [TranslationRoute(language, into: language.translationLanguage)]
        }
    }

    /// The routes whose prompts are read ahead for the translation key's direction while
    /// translation is on and the caption target while captions run, nil for either one
    /// that is not wanted: the caption routes first, since captions translate without
    /// waiting, see CaptionTarget.preparedRoutes(into:for:), then those of the direction,
    /// each once. All are among `keptRoutes`, so they stay within the prefix caches
    /// RewriteEngine keeps.
    nonisolated static func preparedRoutes(direction: TranslationDirection?, captionTarget: TranslationTarget?, _ language: DictationLanguage) -> [TranslationRoute] {
        var routes = captionTarget.map { CaptionTarget.preparedRoutes(into: $0, for: language) } ?? []
        for route in direction.map({ preparedRoutes($0, language) }) ?? [] where !routes.contains(route) {
            routes.append(route)
        }
        return routes
    }

    /// The routes whose prefix caches RewriteEngine keeps: the two of the dictation
    /// language, and with a caption target, which is given while captions run, every route
    /// a sentence into it may take, see CaptionTarget.routes(into:). Four at most, see
    /// TranslationPrefixSlots.captionsLimit.
    nonisolated static func keptRoutes(captionTarget: TranslationTarget?, _ language: DictationLanguage) -> Set<TranslationRoute> {
        Set(language.translationRoutes).union(captionTarget.map(CaptionTarget.routes(into:)) ?? [])
    }

    /// Reads the translation prompts ahead after the work queued before, see
    /// RewriteEngine.prepareTranslation.
    private func prepareTranslation() {
        let generation = loadGeneration
        enqueue { [weak self] in
            // Unloaded, or translation off, since.
            guard let self, generation == loadGeneration else { return }
            await fillTranslationPrefixes()
        }
    }

    /// Drops the prompts of other dictation languages and of caption targets no longer
    /// chosen, and reads those of the caption target and the user's direction ahead. The
    /// other target of the same language stays when it is in memory, as it did before the
    /// dictation language.
    private func fillTranslationPrefixes() async {
        guard translationIsOn || captionsNeedModel, isLoaded else { return }
        let language = dictationLanguage
        await engine.keepTranslationPrefixes(Self.keptRoutes(captionTarget: captionsNeedModel ? captionTarget : nil, language))
        let routes = Self.preparedRoutes(
            direction: translationIsOn ? translationDirection : nil,
            captionTarget: captionsNeedModel ? captionTarget : nil,
            language
        )
        for route in routes {
            do {
                try await engine.prepareTranslation(route)
            } catch {
                Logger.rewrite.error("Reading the translation prompt ahead failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    private func load(from folder: URL) {
        guard needsModel, engineState == .unloaded || engineState == .failed else { return }
        self.folder = folder
        engineState = .loading
        loadGeneration += 1
        let generation = loadGeneration
        enqueue { [weak self, engine] in
            // Turned off, or off and on again, before its turn: the unload queued by
            // turning off runs next, and a newer load after it.
            guard let self, generation == loadGeneration else { return }
            // Reserves the model gate for the load and the prompts read after it, at
            // launch, at the press of a key and from Settings alike, so a voice model that
            // waits does not come in between, see ModelGate.reserve.
            let reservation = engine.gate?.reserve()
            defer { reservation?.end() }
            let loaded: Bool
            do {
                try await engine.load(folder)
                loaded = true
            } catch {
                // The type only, since a description may hold a path.
                Logger.rewrite.error("The cleanup model failed to load with \(String(reflecting: type(of: error)), privacy: .public)")
                loaded = false
            }
            // Turned off while loading. The unload queued then runs next.
            guard generation == loadGeneration else { return }
            engineState = loaded ? .ready : .failed
            resumeAllWaiters()
            // With translation on, its prompts are read before any other work on the model.
            if loaded {
                await fillTranslationPrefixes()
            }
            scheduleIdleUnload()
        }
    }

    /// Runs engine work after the work queued before it.
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = engineWork
        let task = Task {
            await previous?.value
            await work()
        }
        engineWork = task
        return task
    }

    /// Waits for the loads and unloads under way. Internal for tests.
    func waitForLoad() async {
        await engineWork?.value
    }
}

/// How long the cleanup model stays loaded without a dictation. No setting in the
/// interface yet. The default can be changed with
/// `defaults write io.github.db-ol.Orra cleanupIdleUnloadSeconds <seconds>`, where 0 keeps
/// the model loaded for as long as cleanup is on.
nonisolated enum CleanupIdlePreference {
    static let defaultsKey = "cleanupIdleUnloadSeconds"
    /// 15 minutes: long enough that the pauses within a stretch of writing, reading a reply
    /// or thinking, keep the model loaded, short enough that a meeting, a break or the night
    /// gives the memory back.
    static let defaultDelay: Duration = .seconds(15 * 60)

    /// The delay, nil to keep the model loaded.
    static func load(from defaults: UserDefaults = .standard) -> Duration? {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultDelay }
        let seconds = defaults.double(forKey: defaultsKey)
        return seconds > 0 ? .seconds(seconds) : nil
    }
}

/// What TextCleanup needs from the cleanup model. Closures, so tests pass a stand in.
struct CleanupEngine {
    /// Loads the model from an installed folder, see RewriteEngine.load.
    var load: @Sendable (URL) async throws -> Void
    var unload: @Sendable () async -> Void
    /// The model's answer for a transcript, see RewriteEngine.cleanUp.
    var complete: @Sendable (String) async throws -> String
    /// The model's answer for a transcript and a route, see RewriteEngine.translate.
    var translate: @Sendable (String, TranslationRoute) async throws -> String = { _, _ in throw RewriteError.notLoaded }
    /// Reads the translation prompt for a route ahead, see
    /// RewriteEngine.prepareTranslation.
    var prepareTranslation: @Sendable (TranslationRoute) async throws -> Void = { _ in }
    /// Drops the translation prompts of routes outside a set, see
    /// RewriteEngine.keepTranslationPrefixes.
    var keepTranslationPrefixes: @Sendable (Set<TranslationRoute>) async -> Void = { _ in }
    /// Begins a Projects job on a prompt with a maximum number of answer tokens, see
    /// RewriteEngine.startJob.
    var startJob: @Sendable (String, Int) async throws -> RewriteEngine.JobStart = { _, _ in throw RewriteError.notLoaded }
    /// Reads a number of a job's prompt tokens, see RewriteEngine.readSlice.
    var readSlice: @Sendable (Int, Int) async throws -> RewriteEngine.SliceRun = { _, _ in throw RewriteError.notLoaded }
    /// Writes a number of a job's answer tokens, see RewriteEngine.writeBurst.
    var writeBurst: @Sendable (Int, Int) async throws -> RewriteEngine.BurstRun = { _, _ in throw RewriteError.notLoaded }
    /// Ends a job with its answer, see RewriteEngine.endJob.
    var endJob: @Sendable (Int) async throws -> String = { _ in throw RewriteError.notLoaded }
    /// Gives MLX's freed buffers back, see RewriteEngine.clearCache.
    var clearCache: @Sendable () async -> Void = {}
    /// The model gate the cleanup model runs at, see `gated`. Nil when it runs at none, as
    /// a test's stand in does. A load reserves it, see TextCleanup.
    var gate: ModelGate? = nil

    /// The app's cleanup model, which runs only while it shares `gate`, see ModelGate.
    static func live(_ engine: RewriteEngine = RewriteEngine(), gate: ModelGate = .live) -> CleanupEngine {
        CleanupEngine(
            load: { try await engine.load(from: $0) },
            unload: { await engine.unload() },
            complete: { try await engine.cleanUp($0).answer },
            translate: { try await engine.translate($0, into: $1).answer },
            prepareTranslation: { try await engine.prepareTranslation(into: $0) },
            keepTranslationPrefixes: { await engine.keepTranslationPrefixes($0) },
            startJob: { try await engine.startJob($0, maximumTokens: $1) },
            readSlice: { try await engine.readSlice($0, tokens: $1) },
            writeBurst: { try await engine.writeBurst($0, tokens: $1) },
            endJob: { try await engine.endJob($0) },
            clearCache: { await engine.clearCache() }
        ).gated(gate)
    }
}
