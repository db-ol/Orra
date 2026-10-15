import Foundation
import Observation

/// The two folders the voice model loads from: the model, and Qwen3-TTS's speech
/// tokenizer or CosyVoice3's speaker encoder.
nonisolated struct VoiceModelFolders: Equatable, Sendable {
    var model: URL
    var codec: URL
}

/// The voice model's two downloads, the model and its speech tokenizer or speaker encoder,
/// as one thing for Settings. Each goes through a ModelInstaller of its own, pinned and
/// checked like the speech and cleanup models. Nothing goes online until the user starts
/// the download. Holds the downloads of the voice model Settings shows, see `select`.
@Observable
final class VoiceModels {
    private(set) var kind: VoiceEngineKind
    private(set) var model: ModelInstaller
    private(set) var codec: ModelInstaller
    /// Called each time one of the two is in place, so the voice model loads once both
    /// are. AppDelegate sets it.
    @ObservationIgnored var onInstalled: () -> Void = {}
    @ObservationIgnored private let makeInstaller: (ModelManifest) -> ModelInstaller

    /// Only Hugging Face and hf-mirror.com carry the repositories at these commits.
    nonisolated static let sources: [ModelSource] = [.huggingFace, .hfMirror]

    /// - Parameters:
    ///   - kind: The voice model whose downloads these are.
    ///   - makeInstaller: Makes the installer of one download. Tests pass stand ins.
    init(kind: VoiceEngineKind, makeInstaller: @escaping (ModelManifest) -> ModelInstaller) {
        self.kind = kind
        self.makeInstaller = makeInstaller
        let manifests = kind.manifests
        model = makeInstaller(manifests.model)
        codec = makeInstaller(manifests.codec)
        watchInstalls()
    }

    static func live(kind: VoiceEngineKind) -> VoiceModels {
        VoiceModels(kind: kind) { manifest in
            ModelInstaller(manifest: manifest, folders: .liveCleanup, sources: sources, environment: .live)
        }
    }

    /// Switches to the downloads of another voice model, at once, so `folders` never
    /// gives the old model's folders to the new model. A download of the old one stops,
    /// and its bytes stay on disk for a later Download. Both models' folders stay, so
    /// switching back needs no download. Call `prepare` next.
    func select(_ kind: VoiceEngineKind) {
        guard kind != self.kind else { return }
        cancel()
        self.kind = kind
        let manifests = kind.manifests
        model = makeInstaller(manifests.model)
        codec = makeInstaller(manifests.codec)
        watchInstalls()
    }

    private func watchInstalls() {
        model.onInstalled = { [weak self] _ in self?.onInstalled() }
        codec.onInstalled = { [weak self] _ in self?.onInstalled() }
    }

    /// Both folders once both are installed.
    var folders: VoiceModelFolders? {
        guard case .installed(let model) = model.state, case .installed(let codec) = codec.state else { return nil }
        return VoiceModelFolders(model: model, codec: codec)
    }

    var totalBytes: Int64 {
        model.manifest.totalBytes + codec.manifest.totalBytes
    }

    var status: VoiceModelStatus {
        VoiceModelStatus(model.state, codec.state, modelTotal: model.manifest.totalBytes, codecTotal: codec.manifest.totalBytes)
    }

    /// Looks at local files only.
    func prepare() async {
        await model.prepare()
        await codec.prepare()
    }

    /// Downloads whatever is missing, both at once.
    func download() {
        model.download()
        codec.download()
    }

    func cancel() {
        model.cancel()
        codec.cancel()
    }
}

/// Where the two downloads stand together, for one line and one button in Settings.
nonisolated enum VoiceModelStatus: Equatable, Sendable {
    case checking
    /// The bytes still to download.
    case missing(bytesLeft: Int64)
    case downloading(bytes: Int64, total: Int64)
    case verifying
    case failed
    case installed

    init(_ model: ModelInstaller.State, _ codec: ModelInstaller.State, modelTotal: Int64, codecTotal: Int64) {
        let states = [(model, modelTotal), (codec, codecTotal)]
        func present(_ state: ModelInstaller.State, _ total: Int64) -> Int64 {
            switch state {
            case .missing(let bytes): bytes
            case .downloading(let bytes, _): bytes
            case .verifying, .installed: total
            case .checking, .failed: 0
            }
        }
        let total = modelTotal + codecTotal
        let bytes = states.reduce(Int64(0)) { $0 + present($1.0, $1.1) }
        if states.allSatisfy({ if case .installed = $0.0 { true } else { false } }) {
            self = .installed
        } else if states.contains(where: { if case .checking = $0.0 { true } else { false } }) {
            self = .checking
        } else if states.contains(where: { if case .downloading = $0.0 { true } else { false } }) {
            self = .downloading(bytes: bytes, total: total)
        } else if states.contains(where: { if case .verifying = $0.0 { true } else { false } }) {
            self = .verifying
        } else if states.contains(where: { if case .failed = $0.0 { true } else { false } }) {
            self = .failed
        } else {
            self = .missing(bytesLeft: total - bytes)
        }
    }

    /// The line under Speak Translation, nil once installed.
    var line: String? {
        switch self {
        case .checking, .installed:
            nil
        case .missing:
            String(localized: "The voice model is not on this Mac yet.")
        case .downloading(let bytes, let total):
            String(localized: "Downloading the voice model: \(ModelInstaller.State.percent(bytes, of: total))% of \(ModelInstaller.State.size(total))")
        case .verifying:
            String(localized: "Checking the downloaded files…")
        case .failed:
            String(localized: "The voice model could not be downloaded.")
        }
    }

    /// The button, nil when there is none.
    var buttonTitle: String? {
        switch self {
        case .missing(let left):
            String(localized: "Download Voice Model (\(ModelInstaller.State.size(left)))")
        case .downloading:
            String(localized: "Cancel Download")
        case .failed:
            String(localized: "Try Again")
        case .checking, .verifying, .installed:
            nil
        }
    }
}
