import Foundation
import Observation
import os

/// Puts the speech model in place and publishes where that stands, for the menu, the
/// welcome window and the menu bar icon. Launch looks at local files only. Only Download
/// Speech Model, Resume Download and Try Again, in the menu or the welcome window, go
/// online, see docs/model-download.md.
///
/// The download, the hashing and every file write run off the main actor. The main actor
/// only reads a few file sizes and assigns the state.
@Observable
final class ModelInstaller {
    nonisolated enum State: Equatable, Sendable {
        /// Looking at the files on disk, at launch or after a failed load.
        case checking
        /// Not installed yet. The bytes on disk that a download keeps.
        case missing(bytesPresent: Int64)
        /// The bytes on disk, and the server in use once one is asked.
        case downloading(bytes: Int64, source: ModelSource?)
        /// Hashing the downloaded files.
        case verifying
        case failed(ModelDownload.Failure)
        /// In this folder, ready to load.
        case installed(URL)
    }

    private(set) var state: State = .checking
    let manifest: ModelManifest
    /// Called each time the model is in place, so the speech model loads. AppDelegate sets it.
    @ObservationIgnored var onInstalled: (URL) -> Void = { _ in }

    @ObservationIgnored private let folders: ModelFolders
    @ObservationIgnored private let sources: [ModelSource]
    @ObservationIgnored private let environment: ModelDownload.Environment
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var isPreparing = false
    /// Held during a download and its check, so the Mac does not fall asleep while idle.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger.modelDownload

    /// - Parameters:
    ///   - manifest: The pinned files.
    ///   - folders: Where they go. Tests pass temporary folders.
    ///   - sources: The servers, in the order they are tried.
    ///   - environment: The network, the free space check and the pauses. Tests pass
    ///     stand ins.
    init(manifest: ModelManifest, folders: ModelFolders, sources: [ModelSource] = ModelSource.order, environment: ModelDownload.Environment) {
        self.manifest = manifest
        self.folders = folders
        self.sources = sources
        self.environment = environment
    }

    /// The app's installer. Creating it touches neither the disk nor the network.
    static func live() -> ModelInstaller {
        ModelInstaller(
            manifest: .qwen3,
            folders: .live,
            sources: ModelSource.servers(launchArguments: ProcessInfo.processInfo.arguments),
            environment: .live
        )
    }

    /// Looks for the model with local files only, at launch, and from Try Again after the
    /// model failed to load. Then the hashes are checked too, so a damaged file leads to
    /// Download instead of the same failure again. Does nothing while a download runs.
    func prepare(checkingHashes: Bool = false) async {
        guard job == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        state = .checking
        let result = await ModelPreparation.run(manifest, folders, checkingHashes: checkingHashes, freeSpace: environment.freeSpace)
        switch result {
        case .installed(let folder):
            logger.notice("The speech model is installed")
            state = .installed(folder)
            onInstalled(folder)
        case .missing(let bytes):
            logger.notice("The speech model is not installed, \(bytes, privacy: .public) of \(self.manifest.totalBytes, privacy: .public) bytes on disk")
            state = .missing(bytesPresent: bytes)
        }
    }

    /// Download Speech Model, Resume Download and Try Again, in the menu or the welcome
    /// window. Starts at the first server and keeps the bytes already on disk. Does nothing
    /// unless the model is missing or the last download failed.
    func download() {
        switch state {
        case .missing, .failed:
            break
        case .checking, .downloading, .verifying, .installed:
            return
        }
        guard job == nil, !isPreparing else { return }
        let start = ModelDisk.bytesPresent(folders.staging(manifest), manifest)
        state = .downloading(bytes: start, source: nil)
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading the speech model")
        let (events, continuation) = AsyncStream<ModelDownload.Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        job = Task { [manifest, folders, sources, environment] in
            async let installed = Self.run(manifest, folders, sources, environment, continuation)
            for await event in events {
                switch event {
                case .progress(let bytes, let source):
                    state = .downloading(bytes: bytes, source: source)
                case .verifying:
                    state = .verifying
                }
            }
            let result: Result<URL, any Error>
            do {
                result = .success(try await installed)
            } catch {
                result = .failure(error)
            }
            finish(result)
        }
    }

    /// Cancel Download, in the menu or the welcome window. The bytes on disk stay for
    /// Resume Download.
    func cancel() {
        job?.cancel()
    }

    /// True while Orra tells macOS that a download is running. Internal for tests.
    var isKeepingTheMacAwake: Bool {
        activity != nil
    }

    /// Waits for the current download to end. Internal for tests.
    func waitForDownload() async {
        await job?.value
    }

    private func finish(_ result: Result<URL, any Error>) {
        job = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        switch result {
        case .success(let folder):
            state = .installed(folder)
            onInstalled(folder)
        case .failure(let failure as ModelDownload.Failure):
            logger.error("Download failed: \(String(describing: failure), privacy: .public)")
            state = .failed(failure)
        case .failure:
            let bytes = ModelDisk.bytesPresent(folders.staging(manifest), manifest)
            logger.notice("Download cancelled with \(bytes, privacy: .public) bytes on disk")
            state = .missing(bytesPresent: bytes)
        }
    }

    /// The download, off the main actor. Ends the event stream when it returns or throws.
    @concurrent
    nonisolated private static func run(_ manifest: ModelManifest, _ folders: ModelFolders, _ sources: [ModelSource], _ environment: ModelDownload.Environment, _ events: AsyncStream<ModelDownload.Event>.Continuation) async throws -> URL {
        defer { events.finish() }
        return try await ModelDownload.run(manifest, folders, sources: sources, environment: environment) { event in
            events.yield(event)
        }
    }
}

/// The text for each state, in the menu and the welcome window, kept here so tests can
/// read it.
nonisolated extension ModelInstaller.State {
    /// The lines above the button. Empty once the model is installed, where the speech
    /// model's own lines take over.
    func menuLines(total: Int64) -> [String] {
        switch self {
        case .checking:
            [String(localized: "Preparing the speech model…")]
        case .missing:
            [String(localized: "Orra needs its speech model to transcribe."), String(localized: "The model comes from Hugging Face or a mirror. Your speech stays on this Mac.")]
        case .downloading(let bytes, let source):
            [String(localized: "Downloading the speech model: \(Self.percent(bytes, of: total))% of \(Self.size(total))")] + (source.map { [String(localized: "From \($0.rawValue)")] } ?? [])
        case .verifying:
            [String(localized: "Checking the downloaded files…")]
        case .failed(.offline):
            [String(localized: "This Mac is offline. Connect to the internet, then try again.")]
        case .failed(.unreachable):
            [String(localized: "Orra could not download the model from Hugging Face or its mirrors.")]
        case .failed(.notEnoughSpace(let needed, let available)):
            [String(localized: "The download needs \(Self.size(needed)) of free space and \(Self.size(available)) is free.")]
        case .failed(.damaged):
            [String(localized: "The downloaded files did not match the expected checksums.")]
        case .failed(.couldNotSave):
            [String(localized: "Orra could not save the model files.")]
        case .installed:
            []
        }
    }

    /// The menu's button, or nil when there is none. Before any download it says how much
    /// will be downloaded.
    func buttonTitle(total: Int64) -> String? {
        switch self {
        case .missing(let bytes) where bytes > 0:
            String(localized: "Resume Download (\(Self.size(total - bytes)) left)")
        case .missing:
            String(localized: "Download Speech Model (\(Self.size(total)))")
        case .downloading:
            String(localized: "Cancel Download")
        case .failed:
            String(localized: "Try Again")
        case .checking, .verifying, .installed:
            nil
        }
    }

    /// The menu bar icon until the model is installed, nil after that.
    var symbolName: String? {
        switch self {
        case .checking, .downloading, .verifying:
            "hourglass"
        case .missing:
            "arrow.down.circle"
        case .failed:
            "exclamationmark.triangle"
        case .installed:
            nil
        }
    }

    /// Decimal units, as Finder shows file sizes: "2.47 GB".
    static func size(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false, locale: Locale(identifier: "en_US")))
    }

    static func percent(_ bytes: Int64, of total: Int64) -> Int64 {
        total > 0 ? min(max(bytes * 100 / total, 0), 100) : 0
    }
}
