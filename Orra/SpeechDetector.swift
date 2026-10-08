import CryptoKit
import Foundation
import SpeechVAD

/// Tells whether a recording holds speech, with Silero VAD v6.2.1 (MIT), which ships inside
/// the app: Orra/SileroVAD, 1.2 MB, from Hugging Face aufklarer/Silero-VAD-v6.2.1-MLX at
/// revision 0046cea4. Nothing is downloaded.
///
/// An actor, so the model runs off the main actor, one recording at a time.
actor SpeechDetector {
    /// The bundled files, their names in the folder speech-swift loads from, and their
    /// pinned SHA-256.
    static let files: [(bundled: String, loaded: String, sha256: String)] = [
        ("silero-vad.safetensors", "model.safetensors", "8367dac03e6c9ae0e20b71886655e9b9cdc459eac66625e8afd770573e43bc0b"),
        ("silero-vad-config.json", "config.json", "59a798e628bf152b85db67cc5441cbc704b140a2e61854e2052d879c1d051813"),
    ]

    private var model: SileroVADModel?
    private var failed = false
    private let folder: URL
    private let bundle: Bundle

    /// - Parameters:
    ///   - folder: Where the files are copied for loading. Tests pass a temporary folder.
    ///   - bundle: Where the bundled files are.
    init(folder: URL = SpeechDetector.liveFolder, bundle: Bundle = .main) {
        self.folder = folder
        self.bundle = bundle
    }

    /// ~/Library/Caches/io.github.db-ol.Orra/SileroVAD-v6.2.1. A cache, because the app
    /// can always copy it again.
    static var liveFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.db-ol.Orra/SileroVAD-v6.2.1", isDirectory: true)
    }

    /// Whether the samples, 16 kHz mono, hold speech. Nil when the detector cannot run, so
    /// the recording is transcribed as before.
    func hasSpeech(_ samples: [Float]) async -> Bool? {
        guard let model = await loadedModel() else { return nil }
        return !model.detectSpeech(audio: samples, sampleRate: RecordingLimits.sampleRate).isEmpty
    }

    /// Loads the model ahead of the first recording. False when it cannot be loaded.
    @discardableResult
    func load() async -> Bool {
        await loadedModel() != nil
    }

    /// Loads once. A failure is not retried, and dictation goes on without the detector.
    private func loadedModel() async -> SileroVADModel? {
        if let model { return model }
        guard !failed else { return nil }
        do {
            try prepareFolder()
            let loaded = try await SileroVADModel.fromPretrained(engine: .mlx, cacheDir: folder, offlineMode: true)
            model = loaded
            return loaded
        } catch {
            failed = true
            return nil
        }
    }

    /// Copies the bundled files into the folder unless they are there with the pinned hash.
    /// Checks the bundled copies against the pinned hashes first.
    func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in Self.files {
            let target = folder.appendingPathComponent(file.loaded)
            if (try? Self.sha256(of: target)) == file.sha256 { continue }
            let name = file.bundled as NSString
            guard let source = bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension)
                ?? bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: "SileroVAD") else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard try Self.sha256(of: source) == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
