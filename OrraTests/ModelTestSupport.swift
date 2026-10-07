import CryptoKit
import Foundation
@testable import Orra

/// A small stand in for the speech model: the six file names of the real one with made up
/// contents, about 3.3 MB in all, pinned the same way. The bytes come from a fixed seed, so
/// a shifted or cut copy never matches by chance.
enum TestModel {
    static let sizes: [String: Int] = [
        "config.json": 7_188,
        "tokenizer_config.json": 12_487,
        "model.safetensors.index.json": 78_968,
        "merges.txt": 100_000,
        "vocab.json": 120_000,
        "model.safetensors": 3_000_000,
    ]

    static let contents: [String: Data] = {
        var files: [String: Data] = [:]
        for (name, count) in sizes {
            var state = UInt64(truncatingIfNeeded: name.hashValueStable)
            var bytes = [UInt8](repeating: 0, count: count)
            for index in bytes.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
            files[name] = Data(bytes)
        }
        return files
    }()

    static let manifest = ModelManifest(
        id: "owner/Model-8bit",
        huggingFaceRevision: ModelManifest.qwen3.huggingFaceRevision,
        modelScopeRevision: ModelManifest.qwen3.modelScopeRevision,
        files: ModelManifest.qwen3.files.map {
            ModelFile(name: $0.name, size: Int64(contents[$0.name]!.count), sha256: hex(contents[$0.name]!), resumable: $0.resumable)
        }
    )

    static var weights: Data {
        contents["model.safetensors"]!
    }

    static func size(_ name: String) -> Int64 {
        Int64(contents[name]!.count)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    /// A hash that stays the same from run to run, unlike hashValue.
    var hashValueStable: UInt64 {
        utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// Temporary folders laid out like the app's: Models under Application Support, and both
/// of speech-swift's cache layouts. Tests never touch the real ones.
struct TemporaryModelFolders {
    let root: URL
    let folders: ModelFolders

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orra-model-test-\(UUID().uuidString)", isDirectory: true)
        let caches = root.appendingPathComponent("Caches/qwen3-speech", isDirectory: true)
        folders = ModelFolders(
            models: root.appendingPathComponent("Application Support/io.github.db-ol.Orra/Models", isDirectory: true),
            oldCopies: ModelFolders.speechSwiftFolders(for: TestModel.manifest.id, in: caches)
        )
    }

    var manifest: ModelManifest {
        TestModel.manifest
    }

    var installed: URL {
        folders.installed(manifest)
    }

    var staging: URL {
        folders.staging(manifest)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes stand in files into a folder. A damaged file keeps its size and has its first
    /// byte flipped.
    func write(_ names: [String], to folder: URL, damaging damaged: Set<String> = []) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            var data = TestModel.contents[name]!
            if damaged.contains(name) {
                data[data.startIndex] ^= 0xFF
            }
            try data.write(to: folder.appendingPathComponent(name))
        }
    }

    func writeAll(to folder: URL, damaging damaged: Set<String> = []) throws {
        try write(manifest.files.map(\.name), to: folder, damaging: damaged)
    }

    /// The installed folder holds exactly the stand in files, and the staging folder is gone.
    func isInstalled() -> Bool {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: installed.path)) ?? [])
        return names == Set(manifest.files.map(\.name))
            && manifest.files.allSatisfy { (try? Data(contentsOf: installed.appendingPathComponent($0.name))) == TestModel.contents[$0.name] }
            && !FileManager.default.fileExists(atPath: staging.path)
    }

    func isExcludedFromBackup(_ folder: URL) throws -> Bool {
        try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }
}
