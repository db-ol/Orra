import Foundation
import Observation
import os

/// Cleanup with the local text model: the setting, the model's download and loading, and
/// the closures PushToTalkController calls.
///
/// Off until the user turns it on. Turning it on asks first when the model still has to be
/// downloaded, and nothing goes online before the user confirms. While cleanup is on the
/// model is loaded at launch and stays loaded while the user dictates. After
/// `idleUnloadDelay` without a dictation it is unloaded, and the next press of the talk key
/// loads it again while the user speaks, see `dictationStarted()`. Turning cleanup off
/// unloads it and stops a download.
@Observable
final class TextCleanup {
    nonisolated enum EngineState: Equatable, Sendable {
        case unloaded
        case loading
        case ready
        case failed
    }

    /// Whether the user turned cleanup on. Saved through `save` whenever it changes.
    private(set) var isOn: Bool
    /// True while Settings asks whether to download the model.
    var isConfirmingDownload = false
    /// Whether cleanup can run. Ready also covers a model unloaded after a while without a
    /// dictation, see `isUnloadedWhileIdle`, since the next dictation loads it again and
    /// Settings has nothing to show for it.
    private(set) var engineState: EngineState = .unloaded
    /// True while the model is out of memory because nobody dictated for
    /// `idleUnloadDelay`. The state stays ready, and the next press of the talk key loads
    /// the model again.
    private(set) var isUnloadedWhileIdle = false
    let models: ModelInstaller

    @ObservationIgnored private let engine: CleanupEngine
    @ObservationIgnored private let save: (Bool) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
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
    /// True from the press of the talk key until the dictation is over. No idle unload
    /// happens in between.
    @ObservationIgnored private var isDictating = false
    /// Transcripts waiting for the load under way, resumed when it ends, when cleanup is
    /// turned off or when their wait is over.
    @ObservationIgnored private var loadWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiter = 0

    /// - Parameters:
    ///   - isOn: As saved.
    ///   - save: Saves the setting after the user changes it.
    ///   - models: The installer for the cleanup model. Tests pass one with temporary
    ///     folders and a stand in network.
    ///   - engine: Loads and runs the model. Tests pass a stand in.
    ///   - idleUnloadDelay: How long the model stays loaded without a dictation, nil for
    ///     as long as cleanup is on.
    ///   - loadWait: The longest a finished transcript waits for the model to load.
    ///   - sleep: Waits for a time. Tests pass a clock they move.
    init(
        isOn: Bool,
        save: @escaping (Bool) -> Void,
        models: ModelInstaller,
        engine: CleanupEngine = .live(),
        idleUnloadDelay: Duration? = CleanupIdlePreference.defaultDelay,
        loadWait: Duration = TextCleanup.defaultLoadWait,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.isOn = isOn
        self.save = save
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
    /// talk key started to load. On an M5 Pro in a Release build, the model was loaded 1.1 s
    /// after the press, and the first load in a new process took 1.2 to 2.1 s, so only a
    /// hold under about 1.2 s waits at all. 3 s leaves room for a slower Mac or disk. Past
    /// it the ruled text is pasted, as when a cleanup takes too long.
    static let defaultLoadWait: Duration = .seconds(3)

    /// At launch: looks for the model with local files only, and loads it when cleanup is
    /// on, so a failed load shows in Settings at once and the first dictation needs no
    /// wait. Without a dictation it is unloaded after `idleUnloadDelay`. Never goes online.
    func start() async {
        await models.prepare()
    }

    /// The closures for PushToTalkController.
    var model: CleanupModel {
        CleanupModel(
            waitUntilLoaded: { [weak self] in await self?.waitUntilLoaded() ?? false },
            dictationStarted: { [weak self] in self?.dictationStarted() },
            dictationEnded: { [weak self] in self?.dictationEnded() },
            complete: engine.complete
        )
    }

    /// The talk key went down. Stops the idle timer, and loads the model again when it was
    /// unloaded while idle, so the load overlaps the recording. Loading, filling the prefix
    /// cache and warming up took about 1.2 s in a Release build, less than most holds.
    func dictationStarted() {
        isDictating = true
        idleTimer?.cancel()
        idleTimer = nil
        guard isOn, isUnloadedWhileIdle, let folder else { return }
        isUnloadedWhileIdle = false
        engineState = .unloaded
        Logger.rewrite.notice("Loading the cleanup model again for a dictation")
        load(from: folder)
    }

    /// The dictation is over, pasted or not. Starts the idle timer.
    func dictationEnded() {
        isDictating = false
        scheduleIdleUnload()
    }

    /// Whether the model can clean up the transcript now. Waits for a load under way, at
    /// most `loadWait`, and false when cleanup is off, the model failed to load or the
    /// wait ran out. Logs how long it waited, never text.
    func waitUntilLoaded() async -> Bool {
        if isOn, engineState == .loading {
            let started = ContinuousClock.now
            await waitForLoadUnderWay()
            let loaded = isOn && engineState == .ready && !isUnloadedWhileIdle
            Logger.rewrite.notice("Waited \(started.duration(to: .now), privacy: .public) for the cleanup model, loaded: \(loaded, privacy: .public)")
            return loaded
        }
        return isOn && engineState == .ready && !isUnloadedWhileIdle
    }

    /// Returns when the load under way ends, cleanup is turned off, or `loadWait` passes.
    private func waitForLoadUnderWay() async {
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { [sleep, loadWait] in
            guard (try? await sleep(loadWait)) != nil else { return }
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

    /// Starts the idle timer again, unless cleanup is off, a dictation is under way or the
    /// model is not loaded.
    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        idleTimer = nil
        guard let idleUnloadDelay, isOn, !isDictating, engineState == .ready, !isUnloadedWhileIdle else { return }
        idleTimer = Task { [weak self, sleep] in
            guard (try? await sleep(idleUnloadDelay)) != nil, !Task.isCancelled else { return }
            self?.unloadWhileIdle()
        }
    }

    /// Unloads the model after `idleUnloadDelay` without a dictation. Queued like every
    /// load and unload, so a press of the talk key during the unload loads the model again
    /// right after it.
    private func unloadWhileIdle() {
        idleTimer = nil
        guard isOn, !isDictating, engineState == .ready, !isUnloadedWhileIdle else { return }
        isUnloadedWhileIdle = true
        Logger.rewrite.notice("Unloading the cleanup model after no dictation for \(self.idleUnloadDelay ?? .zero, privacy: .public)")
        enqueue { [engine] in await engine.unload() }
    }

    /// The switch in Settings was turned on. With the model in place cleanup starts at
    /// once, otherwise Settings asks before anything is downloaded. While Orra still looks
    /// for the model on disk, Settings keeps the switch off, see `canTurnOn`.
    func turnOn() {
        guard !isOn, canTurnOn else { return }
        if case .installed(let folder) = models.state {
            setOn(true)
            load(from: folder)
        } else {
            isConfirmingDownload = true
        }
    }

    /// False while Orra looks for the model on disk, at launch or after Try Again, since
    /// only then does it know whether a download is needed.
    var canTurnOn: Bool {
        models.state != .checking
    }

    /// The user agreed to download the model.
    func confirmDownload() {
        isConfirmingDownload = false
        setOn(true)
        models.download()
    }

    /// Download, Resume Download or Try Again under the switch, which name the size
    /// themselves, while cleanup is on.
    func download() {
        guard isOn else { return }
        models.download()
    }

    /// Cancel Download under the switch. The bytes stay for the next time, and cleanup is
    /// off until the user turns it on again.
    func cancelDownload() {
        models.cancel()
        setOn(false)
    }

    /// The switch was turned off: stops a download and unloads the model.
    func turnOff() {
        guard isOn else { return }
        setOn(false)
        if case .downloading = models.state {
            models.cancel()
        }
        loadGeneration += 1
        loadTask = nil
        engineState = .unloaded
        isUnloadedWhileIdle = false
        idleTimer?.cancel()
        idleTimer = nil
        resumeAllWaiters()
        enqueue { [engine] in await engine.unload() }
    }

    /// Try Again after the model failed to load: checks the files, hashes included, and
    /// loads them again, or leads back to Download when one is damaged.
    func retryLoading() async {
        engineState = .unloaded
        isUnloadedWhileIdle = false
        await models.prepare(checkingHashes: true)
    }

    private func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        save(on)
    }

    private func load(from folder: URL) {
        guard isOn, engineState == .unloaded || engineState == .failed else { return }
        self.folder = folder
        engineState = .loading
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = enqueue { [weak self, engine] in
            // Turned off, or off and on again, before its turn: the unload queued by
            // turning off runs next, and a newer load after it.
            guard let self, generation == loadGeneration else { return }
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
            loadTask = nil
            resumeAllWaiters()
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

    static func live(_ engine: RewriteEngine = RewriteEngine()) -> CleanupEngine {
        CleanupEngine(
            load: { try await engine.load(from: $0) },
            unload: { await engine.unload() },
            complete: { try await engine.cleanUp($0).answer }
        )
    }
}
