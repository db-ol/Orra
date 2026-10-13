import Foundation
import Observation
import os

/// Cleanup and translation with the local text model: the two settings, the model's
/// download and loading, and the closures PushToTalkController calls.
///
/// Both are off until the user turns them on. They share one model, which translates as
/// well as it cleans up. Turning either on asks first when the model still has to be
/// downloaded and no download was agreed to for the other, and nothing goes online before
/// the user confirms. While either is on the model stays loaded, and turning the last one
/// off unloads it and stops a download. Translation works with cleanup off: the
/// translation prompt cleans up and translates in one answer, and the cleanup in it is
/// used only while cleanup is on, see TranslationStep.
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
    /// Whether the user turned translation on, so the translation key pastes translated
    /// text. Saved through `saveTranslation` whenever it changes.
    private(set) var translationIsOn: Bool
    /// Which way dictations are translated. Saved through `saveDirection` whenever it
    /// changes.
    private(set) var translationDirection: TranslationDirection
    /// True while the Clean Up Text page asks whether to download the model.
    var isConfirmingDownload = false
    /// True while Settings asks whether to download the model for translation.
    var isConfirmingTranslationDownload = false
    private(set) var engineState: EngineState = .unloaded
    let models: ModelInstaller

    @ObservationIgnored private let engine: CleanupEngine
    @ObservationIgnored private let save: (Bool) -> Void
    @ObservationIgnored private let saveTranslation: (Bool) -> Void
    @ObservationIgnored private let saveDirection: (TranslationDirection) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The latest load or unload. Each waits for the one before it, so they never overlap
    /// and never swap order.
    @ObservationIgnored private var engineWork: Task<Void, Never>?
    /// Counts the loads asked for, so a load the user turned off and on again since leaves
    /// the state alone.
    @ObservationIgnored private var loadGeneration = 0

    /// - Parameters:
    ///   - isOn: Whether cleanup is on, as saved.
    ///   - save: Saves the setting after the user changes it.
    ///   - translationIsOn: Whether translation is on, as saved.
    ///   - saveTranslation: Saves that setting after the user changes it.
    ///   - translationDirection: Which way to translate, as saved.
    ///   - saveDirection: Saves the direction after the user changes it.
    ///   - models: The installer for the cleanup model. Tests pass one with temporary
    ///     folders and a stand in network.
    ///   - engine: Loads and runs the model. Tests pass a stand in.
    init(
        isOn: Bool,
        save: @escaping (Bool) -> Void,
        translationIsOn: Bool = false,
        saveTranslation: @escaping (Bool) -> Void = { _ in },
        translationDirection: TranslationDirection = .automatic,
        saveDirection: @escaping (TranslationDirection) -> Void = { _ in },
        models: ModelInstaller,
        engine: CleanupEngine = .live()
    ) {
        self.isOn = isOn
        self.save = save
        self.translationIsOn = translationIsOn
        self.saveTranslation = saveTranslation
        self.translationDirection = translationDirection
        self.saveDirection = saveDirection
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
            translationIsOn: TranslationPreference.load(),
            saveTranslation: { TranslationPreference.save($0) },
            translationDirection: TranslationDirection.load(),
            saveDirection: { $0.save() },
            models: ModelInstaller(
                manifest: .qwen35Cleanup,
                folders: .liveCleanup,
                sources: ModelSource.servers(launchArguments: ProcessInfo.processInfo.arguments),
                environment: .live
            )
        )
    }

    /// At launch: looks for the model with local files only, and loads it when cleanup or
    /// translation is on. Never goes online.
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

    /// The closures for PushToTalkController's translations.
    var translation: TranslationModel {
        TranslationModel(
            isReady: { [weak self] in self?.translationIsOn == true && self?.engineState == .ready },
            direction: { [weak self] in self?.translationDirection ?? .automatic },
            complete: engine.translate
        )
    }

    /// Whether the model is wanted: cleanup or translation is on.
    var needsModel: Bool {
        isOn || translationIsOn
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
    /// read ahead, so the first translation is fast.
    func turnOnTranslation() {
        guard !translationIsOn, canTurnOn else { return }
        if case .installed(let folder) = models.state {
            setTranslationOn(true)
            if engineState == .ready {
                prepareTranslation()
            } else {
                load(from: folder)
            }
        } else if isOn {
            setTranslationOn(true)
        } else {
            isConfirmingTranslationDownload = true
        }
    }

    /// The user picked which way to translate. Reads the prompt for the new target ahead
    /// while translation is on and the model is loaded.
    func setTranslationDirection(_ direction: TranslationDirection) {
        guard direction != translationDirection else { return }
        translationDirection = direction
        saveDirection(direction)
        if translationIsOn, engineState == .ready {
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
    /// the model.
    func cancelDownload() {
        models.cancel()
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

    private func releaseModelIfUnneeded() {
        guard !needsModel else { return }
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

    private func setTranslationOn(_ on: Bool) {
        guard on != translationIsOn else { return }
        translationIsOn = on
        saveTranslation(on)
    }

    /// The targets whose translation prompts are read ahead for a direction: the fixed
    /// one, or both for the automatic direction, which picks one per dictation. English
    /// first, since most dictations into Orra are Chinese. Each takes about 0.8 s on the
    /// GPU and keeps about 110 MB, see docs/manual-testing.md.
    nonisolated static func preparedTargets(_ direction: TranslationDirection) -> [TranslationTarget] {
        switch direction {
        case .automatic: [.english, .chinese]
        case .english: [.english]
        case .chinese: [.chinese]
        }
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

    private func fillTranslationPrefixes() async {
        guard translationIsOn, engineState == .ready else { return }
        for target in Self.preparedTargets(translationDirection) {
            do {
                try await engine.prepareTranslation(target)
            } catch {
                Logger.rewrite.error("Reading the translation prompt ahead failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    private func load(from folder: URL) {
        guard needsModel, engineState == .unloaded || engineState == .failed else { return }
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
            // With translation on, its prompts are read before any other work on the model.
            if loaded {
                await fillTranslationPrefixes()
            }
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
    /// The model's answer for a transcript and a target, see RewriteEngine.translate.
    var translate: @Sendable (String, TranslationTarget) async throws -> String = { _, _ in throw RewriteError.notLoaded }
    /// Reads the translation prompt for a target ahead, see
    /// RewriteEngine.prepareTranslation.
    var prepareTranslation: @Sendable (TranslationTarget) async throws -> Void = { _ in }

    static func live(_ engine: RewriteEngine = RewriteEngine()) -> CleanupEngine {
        CleanupEngine(
            load: { try await engine.load(from: $0) },
            unload: { await engine.unload() },
            complete: { try await engine.cleanUp($0).answer },
            translate: { try await engine.translate($0, into: $1).answer },
            prepareTranslation: { try await engine.prepareTranslation(into: $0) }
        )
    }
}
