import Foundation
import Observation
import os

/// Cleanup with the local text model: the setting, the model's download and loading, and
/// the closures PushToTalkController calls.
///
/// Off until the user turns it on. Turning it on asks first when the model still has to be
/// downloaded, and nothing goes online before the user confirms. While cleanup is on the
/// model stays loaded, and turning it off unloads it and stops a download.
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
    private(set) var engineState: EngineState = .unloaded
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

    /// - Parameters:
    ///   - isOn: As saved.
    ///   - save: Saves the setting after the user changes it.
    ///   - models: The installer for the cleanup model. Tests pass one with temporary
    ///     folders and a stand in network.
    ///   - engine: Loads and runs the model. Tests pass a stand in.
    init(isOn: Bool, save: @escaping (Bool) -> Void, models: ModelInstaller, engine: CleanupEngine = .live()) {
        self.isOn = isOn
        self.save = save
        self.models = models
        self.engine = engine
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
                manifest: .qwen3Cleanup,
                folders: .liveCleanup,
                sources: ModelSource.servers(launchArguments: ProcessInfo.processInfo.arguments),
                environment: .live
            )
        )
    }

    /// At launch: looks for the model with local files only, and loads it when cleanup is
    /// on. Never goes online.
    func start() async {
        await models.prepare()
    }

    /// The closures for PushToTalkController.
    var model: CleanupModel {
        CleanupModel(
            isReady: { [weak self] in self?.isOn == true && self?.engineState == .ready },
            complete: engine.complete
        )
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

    private func load(from folder: URL) {
        guard isOn, engineState == .unloaded || engineState == .failed else { return }
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
