import CryptoKit
import Foundation
import Testing
@testable import Orra

/// The pinned model, its folders, and what launch does with local files. Every test works
/// in temporary folders, never in the app's own.
struct ModelFilesTests {
    @Test func pinnedValues() {
        let manifest = ModelManifest.qwen3
        #expect(manifest.totalBytes == 2_467_854_870)
        #expect(manifest.files.map(\.name) == ["config.json", "tokenizer_config.json", "model.safetensors.index.json", "merges.txt", "vocab.json", "model.safetensors"])
        for file in manifest.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(file.name)")
        }
        // Only the weights resume with a Range request. The small files are fetched whole.
        #expect(manifest.files.filter(\.resumable).map(\.name) == ["model.safetensors"])
        #expect(manifest.id == SpeechModel.id)
        #expect(manifest.name == "Qwen3-ASR-1.7B-MLX-8bit")
        #expect(manifest.folderName == "Qwen3-ASR-1.7B-MLX-8bit-e5450a26")
        #expect(manifest.huggingFaceRevision.count == 40)
        #expect(manifest.modelScopeRevision.count == 40)
    }

    @Test func sourceURLs() {
        let config = ModelManifest.qwen3.files[0]
        let weights = ModelManifest.qwen3.files[5]
        #expect(ModelSource.huggingFace.url(for: config, in: .qwen3).absoluteString
            == "https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/e5450a26d1fd417c45fc9c405651ddc3180a27a6/config.json")
        #expect(ModelSource.modelScope.url(for: config, in: .qwen3).absoluteString
            == "https://modelscope.cn/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/c38cf3b531e3cdf954823174e8ab32b6a182751c/config.json")
        #expect(ModelSource.hfMirror.url(for: config, in: .qwen3).absoluteString
            == "https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/e5450a26d1fd417c45fc9c405651ddc3180a27a6/config.json")
        #expect(ModelSource.huggingFace.url(for: weights, in: .qwen3).absoluteString
            == "https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/e5450a26d1fd417c45fc9c405651ddc3180a27a6/model.safetensors")
        #expect(ModelSource.modelScope.url(for: weights, in: .qwen3).absoluteString
            == "https://modelscope.cn/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/c38cf3b531e3cdf954823174e8ab32b6a182751c/model.safetensors")
    }

    @Test func serverOrder() {
        #expect(ModelSource.order == [.huggingFace, .modelScope, .hfMirror])
        #expect(Set(ModelSource.order) == Set(ModelSource.allCases))
        #expect(ModelSource.servers(launchArguments: ["/Applications/Orra.app/Contents/MacOS/Orra"]) == ModelSource.order)
        #expect(ModelSource.servers(launchArguments: ["Orra", "-ModelServer", "example.com"]) == ModelSource.order)
        #expect(ModelSource.servers(launchArguments: ["Orra", "-ModelServer"]) == ModelSource.order)
        #if DEBUG
        #expect(ModelSource.servers(launchArguments: ["Orra", "-ModelServer", "hf-mirror.com"]) == [.hfMirror])
        #expect(ModelSource.servers(launchArguments: ["Orra", "-ModelServer", "modelscope.cn"]) == [.modelScope])
        #else
        #expect(ModelSource.servers(launchArguments: ["Orra", "-ModelServer", "hf-mirror.com"]) == ModelSource.order)
        #endif
    }

    /// Only computes the paths. Nothing is read or written there.
    @Test func liveFolders() {
        let folders = ModelFolders.live
        #expect(folders.models.path.hasSuffix("/Library/Application Support/io.github.db-ol.Orra/Models"))
        #expect(folders.oldCopies.count == 2)
        #expect(folders.oldCopies[0].path.hasSuffix("/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit"))
        #expect(folders.oldCopies[1].path.hasSuffix("/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-1.7B-MLX-8bit"))
        #expect(folders.installed(.qwen3).path.hasSuffix("/io.github.db-ol.Orra/Models/Qwen3-ASR-1.7B-MLX-8bit-e5450a26"))
        #expect(folders.staging(.qwen3).path.hasSuffix("/io.github.db-ol.Orra/Models/.download-Qwen3-ASR-1.7B-MLX-8bit-e5450a26"))
    }

    @Test func isCompleteChecksSizes() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let folder = temporary.installed
        #expect(!ModelDisk.isComplete(folder, temporary.manifest))
        try temporary.writeAll(to: folder)
        #expect(ModelDisk.isComplete(folder, temporary.manifest))
        // A file the manifest does not name changes nothing.
        try Data("extra".utf8).write(to: folder.appendingPathComponent("README.md"))
        #expect(ModelDisk.isComplete(folder, temporary.manifest))
        // A file of another size does.
        try Data(TestModel.contents["vocab.json"]!.dropLast()).write(to: folder.appendingPathComponent("vocab.json"))
        #expect(!ModelDisk.isComplete(folder, temporary.manifest))
        try temporary.write(["vocab.json"], to: folder)
        #expect(ModelDisk.isComplete(folder, temporary.manifest))
        // So does a missing one, or a folder in its place.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("config.json"))
        #expect(!ModelDisk.isComplete(folder, temporary.manifest))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("config.json"), withIntermediateDirectories: false)
        #expect(!ModelDisk.isComplete(folder, temporary.manifest))
    }

    @Test func sha256KnownAnswers() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
        let empty = temporary.root.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try ModelDisk.sha256(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let abc = temporary.root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        #expect(try ModelDisk.sha256(of: abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Longer than one 8 MiB read.
        let long = temporary.root.appendingPathComponent("long")
        let data = Data((0..<(9 << 20) + 3).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
        try data.write(to: long)
        #expect(try ModelDisk.sha256(of: long) == TestModel.hex(data))
        #expect(throws: (any Error).self) {
            try ModelDisk.sha256(of: temporary.root.appendingPathComponent("missing"))
        }
    }

    @Test func keptBytesCountWhatADownloadKeeps() throws {
        let weights = TestModel.manifest.files[5]
        let vocab = TestModel.manifest.files[4]
        #expect(ModelDisk.keptBytes(weights, length: nil) == 0)
        #expect(ModelDisk.keptBytes(weights, length: 1_000) == 1_000)
        #expect(ModelDisk.keptBytes(weights, length: weights.size) == weights.size)
        // Too long is fetched again.
        #expect(ModelDisk.keptBytes(weights, length: weights.size + 1) == 0)
        // A partial small file is fetched again whole.
        #expect(ModelDisk.keptBytes(vocab, length: 1_000) == 0)
        #expect(ModelDisk.keptBytes(vocab, length: vocab.size) == vocab.size)

        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.write(["config.json"], to: temporary.staging)
        try TestModel.contents["vocab.json"]!.prefix(500).write(to: temporary.staging.appendingPathComponent("vocab.json"))
        try TestModel.weights.prefix(1_234).write(to: temporary.staging.appendingPathComponent("model.safetensors"))
        #expect(ModelDisk.bytesPresent(temporary.staging, temporary.manifest) == TestModel.size("config.json") + 1_234)
    }

    @Test func launchWithNothingOffersTheDownloadAndCreatesNothing() async {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .missing(bytesPresent: 0))
        #expect(!FileManager.default.fileExists(atPath: temporary.root.path))
    }

    @Test func launchFindsInstalled() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        #expect(temporary.isInstalled())
    }

    @Test func launchReusesOldCopy() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let old = temporary.folders.oldCopies[0]
        try temporary.writeAll(to: old)
        let before = try Self.snapshot(old)

        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        #expect(temporary.isInstalled())
        #expect(try temporary.isExcludedFromBackup(temporary.installed))
        // The old copy is left as it was.
        #expect(try Self.snapshot(old) == before)
    }

    @Test func launchReusesTheLegacyLayout() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.folders.oldCopies[1])
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        #expect(temporary.isInstalled())
    }

    @Test func launchDropsDamagedOldFile() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let old = temporary.folders.oldCopies[0]
        try temporary.writeAll(to: old, damaging: ["vocab.json"])
        let before = try Self.snapshot(old)

        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        // The other five stay as a head start for the download.
        #expect(result == .missing(bytesPresent: temporary.manifest.totalBytes - TestModel.size("vocab.json")))
        #expect(!FileManager.default.fileExists(atPath: temporary.installed.path))
        let staged = try FileManager.default.contentsOfDirectory(atPath: temporary.staging.path)
        #expect(Set(staged) == Set(temporary.manifest.files.map(\.name)).subtracting(["vocab.json"]))
        #expect(try temporary.isExcludedFromBackup(temporary.staging))
        #expect(try Self.snapshot(old) == before)
    }

    @Test func launchFinishesInterruptedInstall() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        // Every file was downloaded, and Orra quit before the rename.
        try temporary.writeAll(to: temporary.staging)
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        #expect(temporary.isInstalled())
        #expect(try temporary.isExcludedFromBackup(temporary.installed))
    }

    @Test func launchCleansOtherRevisions() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let models = temporary.folders.models
        let leftovers = ["Model-8bit-0123abcd", ".download-Model-8bit-0123abcd", ".download-\(temporary.manifest.folderName)"]
        for name in leftovers + ["Other-Model-0123abcd"] {
            try temporary.write(["config.json"], to: models.appendingPathComponent(name, isDirectory: true))
        }
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        let names = try FileManager.default.contentsOfDirectory(atPath: models.path)
        // Another model's folder stays.
        #expect(Set(names) == [temporary.manifest.folderName, "Other-Model-0123abcd"])
    }

    @Test func launchMovesAnIncompleteInstallBackToStaging() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        try FileManager.default.removeItem(at: temporary.installed.appendingPathComponent("vocab.json"))

        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .missing(bytesPresent: temporary.manifest.totalBytes - TestModel.size("vocab.json")))
        #expect(!FileManager.default.fileExists(atPath: temporary.installed.path))
        #expect(ModelDisk.bytesPresent(temporary.staging, temporary.manifest) == temporary.manifest.totalBytes - TestModel.size("vocab.json"))

        // With the missing file back in an old copy, the next launch installs again.
        try temporary.write(["vocab.json"], to: temporary.folders.oldCopies[0])
        let again = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(again == .installed(temporary.installed))
        #expect(temporary.isInstalled())
    }

    /// After a failed load, Try Again hashes the installed files, which launch does not.
    @Test func checkingHashesSendsADamagedInstallBackToStaging() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed, damaging: ["merges.txt"])
        // Sizes only: the damage goes unnoticed.
        let launch = await ModelPreparation.run(temporary.manifest, temporary.folders, freeSpace: { _ in 100_000_000_000 })
        #expect(launch == .installed(temporary.installed))

        let checked = await ModelPreparation.run(temporary.manifest, temporary.folders, checkingHashes: true, freeSpace: { _ in 100_000_000_000 })
        #expect(checked == .missing(bytesPresent: temporary.manifest.totalBytes - TestModel.size("merges.txt")))
        #expect(!FileManager.default.fileExists(atPath: temporary.installed.path))
        let staged = try FileManager.default.contentsOfDirectory(atPath: temporary.staging.path)
        #expect(Set(staged) == Set(temporary.manifest.files.map(\.name)).subtracting(["merges.txt"]))
    }

    @Test func checkingHashesKeepsAnIntactInstall() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        try temporary.writeAll(to: temporary.installed)
        let result = await ModelPreparation.run(temporary.manifest, temporary.folders, checkingHashes: true, freeSpace: { _ in 100_000_000_000 })
        #expect(result == .installed(temporary.installed))
        #expect(temporary.isInstalled())
    }

    @Test func freeSpaceIsReadFromTheNearestExistingFolder() throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let space = try #require(ModelDisk.freeSpace(at: temporary.staging))
        #expect(space > 0)
    }

    /// Names, sizes, contents and modification dates of the files in a folder.
    private static func snapshot(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[name] = "\(attributes[.size] ?? 0) \(modified) \(TestModel.hex(try Data(contentsOf: url)))"
        }
        return result
    }
}
