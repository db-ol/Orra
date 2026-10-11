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

    @ObservationIgnored private let engine: RewriteEngine
    @ObservationIgnored private let save: (Bool) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - isOn: As saved.
    ///   - save: Saves the setting after the user changes it.
    ///   - models: The installer for the cleanup model. Tests pass one with temporary
    ///     folders and a stand in network.
    ///   - engine: Loads and runs the model.
    init(isOn: Bool, save: @escaping (Bool) -> Void, models: ModelInstaller, engine: RewriteEngine = RewriteEngine()) {
        self.isOn = isOn
        self.save = save
        self.models = models
        self.engine = engine
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
        models.onInstalled = { [weak self] folder in
            self?.load(from: folder)
        }
        await models.prepare()
    }

    /// The closures for PushToTalkController.
    var model: CleanupModel {
        CleanupModel(
            isReady: { [weak self] in self?.isOn == true && self?.engineState == .ready },
            complete: { [engine] text in try await engine.cleanUp(text).answer }
        )
    }

    /// The switch in Settings was turned on. With the model in place cleanup starts at
    /// once, otherwise Settings asks before anything is downloaded.
    func turnOn() {
        guard !isOn else { return }
        if case .installed(let folder) = models.state {
            setOn(true)
            load(from: folder)
        } else {
            isConfirmingDownload = true
        }
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
        loadTask?.cancel()
        loadTask = nil
        engineState = .unloaded
        Task { [engine] in await engine.unload() }
    }

    /// Try Again after the model failed to load: checks the files, hashes included, and
    /// loads them again, or leads back to Download when one is damaged.
    func retryLoading() {
        engineState = .unloaded
        Task { await models.prepare(checkingHashes: true) }
    }

    private func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        save(on)
    }

    private func load(from folder: URL) {
        guard isOn, engineState == .unloaded || engineState == .failed else { return }
        engineState = .loading
        loadTask = Task { [weak self, engine] in
            let loaded: Bool
            do {
                try await engine.load(from: folder)
                loaded = true
            } catch {
                Logger.rewrite.error("The cleanup model failed to load: \(String(describing: error), privacy: .public)")
                loaded = false
            }
            guard let self else { return }
            guard !Task.isCancelled, isOn else {
                // Turned off while loading. When it was turned on again since, the newer
                // load keeps the model.
                if !isOn {
                    await engine.unload()
                }
                return
            }
            engineState = loaded ? .ready : .failed
            loadTask = nil
        }
    }

    /// Waits for a load that is under way. Internal for tests.
    func waitForLoad() async {
        await loadTask?.value
    }
}
