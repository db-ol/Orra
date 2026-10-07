import CryptoKit
import Darwin
import Foundation
import os

extension Logger {
    /// Finding, downloading and installing the speech model. States, file names and sizes
    /// only, never file contents or paths.
    nonisolated static let modelDownload = Logger(subsystem: "io.github.db-ol.Orra", category: "model-download")
}

/// One file of the speech model, pinned by its size and SHA-256.
nonisolated struct ModelFile: Sendable, Equatable {
    let name: String
    let size: Int64
    /// Lowercase hex.
    let sha256: String
    /// Whether an interrupted download continues from the bytes on disk with a Range
    /// request. Only the weights do. The small files are always fetched whole, because
    /// modelscope.cn answers a Range request on them with a cut and shifted body.
    var resumable = false
}

/// The files of one model, pinned to a commit on each server. Orra checks every file against
/// these values before it uses it, so no server decides what Orra accepts.
/// docs/model-download.md explains how to move the pin.
nonisolated struct ModelManifest: Sendable, Equatable {
    /// The repository, owner/name. It is the same on Hugging Face and ModelScope.
    let id: String
    /// The Hugging Face commit. hf-mirror.com serves the same commits.
    let huggingFaceRevision: String
    /// ModelScope's own commit with the same files.
    let modelScopeRevision: String
    /// In download order. Small files come first, so a fresh download asks each server for
    /// a small file before the weights.
    let files: [ModelFile]

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// The repository name without its owner.
    var name: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// The installed folder's name. It carries the revision, so files of another pin are
    /// never mistaken for these.
    var folderName: String {
        "\(name)-\(huggingFaceRevision.prefix(8))"
    }

    /// Qwen3-ASR 1.7B in the 8 bit MLX build. Hugging Face main as of 2026-10-07. The
    /// weights last changed in commit b79258c5, and only README.md changed after that.
    /// ModelScope lists the same sizes and SHA-256 values at its commit.
    static let qwen3 = ModelManifest(
        id: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
        huggingFaceRevision: "e5450a26d1fd417c45fc9c405651ddc3180a27a6",
        modelScopeRevision: "c38cf3b531e3cdf954823174e8ab32b6a182751c",
        files: [
            ModelFile(name: "config.json", size: 7_188, sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"),
            ModelFile(name: "tokenizer_config.json", size: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            ModelFile(name: "model.safetensors.index.json", size: 78_968, sha256: "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"),
            ModelFile(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ModelFile(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "model.safetensors", size: 2_463_307_541, sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c", resumable: true),
        ]
    )
}

/// The servers that carry the model. Each one serves the same pinned files, and Orra checks
/// every file, so a server can make a download fail but cannot change the model.
nonisolated enum ModelSource: String, Sendable, CaseIterable {
    case huggingFace = "huggingface.co"
    case modelScope = "modelscope.cn"
    case hfMirror = "hf-mirror.com"

    /// The order Orra tries them in, and the one place to change it. Hugging Face first.
    /// ModelScope next, because in mainland China, where Hugging Face cannot be reached, it
    /// sends the weights from its own servers there. hf-mirror.com last, because it hands
    /// the weights on to Hugging Face's own download servers. docs/model-download.md has
    /// the details.
    static let order: [ModelSource] = [.huggingFace, .modelScope, .hfMirror]

    /// The address of one file at the pinned commit.
    func url(for file: ModelFile, in manifest: ModelManifest) -> URL {
        let path = switch self {
        case .huggingFace, .hfMirror: "\(manifest.id)/resolve/\(manifest.huggingFaceRevision)/\(file.name)"
        case .modelScope: "models/\(manifest.id)/resolve/\(manifest.modelScopeRevision)/\(file.name)"
        }
        // Built from the pinned values above, which hold only URL safe characters.
        return URL(string: "https://\(rawValue)/\(path)")!
    }

    /// The servers a download tries. A Debug build launched with `-ModelServer <host>`, for
    /// example `-ModelServer hf-mirror.com`, tries only that server, so each path can be
    /// tested by hand. Release builds ignore the argument.
    static func servers(launchArguments: [String]) -> [ModelSource] {
        #if DEBUG
        if let flag = launchArguments.firstIndex(of: "-ModelServer"),
           flag + 1 < launchArguments.count,
           let forced = ModelSource(rawValue: launchArguments[flag + 1]) {
            return [forced]
        }
        #endif
        return order
    }
}

/// Where the model lives on disk.
nonisolated struct ModelFolders: Sendable {
    /// ~/Library/Application Support/io.github.db-ol.Orra/Models in the app. Tests pass
    /// temporary folders.
    let models: URL
    /// Folders where speech-swift may have left a copy of the model, in
    /// ~/Library/Caches/qwen3-speech. Orra reuses their files and never changes them.
    let oldCopies: [URL]

    /// The folder speech-swift loads from. Filled only by one rename, once every file in
    /// the staging folder matched its hash.
    func installed(_ manifest: ModelManifest) -> URL {
        models.appendingPathComponent(manifest.folderName, isDirectory: true)
    }

    /// Hidden, next to the installed folder on the same volume, so the final rename is
    /// atomic. It survives relaunches, which is what lets a download resume.
    func staging(_ manifest: ModelManifest) -> URL {
        models.appendingPathComponent(".download-" + manifest.folderName, isDirectory: true)
    }

    /// The app's folders. Computing them touches nothing on disk.
    static var live: ModelFolders {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ModelFolders(
            models: support.appendingPathComponent("io.github.db-ol.Orra/Models", isDirectory: true),
            oldCopies: speechSwiftFolders(for: ModelManifest.qwen3.id, in: caches.appendingPathComponent("qwen3-speech", isDirectory: true))
        )
    }

    /// The folders speech-swift downloads a model to: the current layout
    /// (models/<owner>/<name>) and the legacy one (<owner>_<name>).
    static func speechSwiftFolders(for id: String, in base: URL) -> [URL] {
        var current = base.appendingPathComponent("models", isDirectory: true)
        for part in id.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
        }
        return [current, base.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)]
    }
}

/// Local file work for the model: sizes, hashes, the staging folder and the install.
/// Hashing and copying take seconds, so callers run these off the main actor.
nonisolated enum ModelDisk {
    /// Room left on the disk after a download or a copy, for everything else on the Mac.
    static let spaceMargin: Int64 = 500_000_000

    /// The size of a regular file, or nil when there is none.
    static func size(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Every pinned file is there at its exact size. Reads sizes only, so it is cheap
    /// enough for every launch. Other files in the folder are ignored.
    static func isComplete(_ folder: URL, _ manifest: ModelManifest) -> Bool {
        manifest.files.allSatisfy { size(folder.appendingPathComponent($0.name)) == $0.size }
    }

    /// The bytes of one file that a download keeps: all of a complete file and the start of
    /// partial weights. A partial small file is fetched again whole, so it counts nothing.
    static func keptBytes(_ file: ModelFile, length: Int64?) -> Int64 {
        guard let length else { return 0 }
        if length == file.size { return length }
        return file.resumable && length < file.size ? length : 0
    }

    /// The bytes in a folder that a download keeps.
    static func bytesPresent(_ folder: URL, _ manifest: ModelManifest) -> Int64 {
        manifest.files.reduce(0) { $0 + keptBytes($1, length: size(folder.appendingPathComponent($1.name))) }
    }

    /// SHA-256 in lowercase hex, read in 8 MiB pieces into one buffer.
    static func sha256(of url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 8 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            let count = read(descriptor, buffer.baseAddress, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The pinned files in a folder that are missing, have another size or another hash.
    /// Hashes every file of the right size.
    static func damagedFiles(in folder: URL, _ manifest: ModelManifest) throws -> [String] {
        var damaged: [String] = []
        for file in manifest.files {
            let url = folder.appendingPathComponent(file.name)
            guard size(url) == file.size else {
                damaged.append(file.name)
                continue
            }
            if try sha256(of: url) != file.sha256 {
                damaged.append(file.name)
            }
        }
        return damaged
    }

    /// Leaves a folder out of Time Machine backups. The flag stays on through a rename.
    static func excludeFromBackup(_ folder: URL) throws {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// Creates the staging folder if needed, left out of backups from the start, so up to
    /// 2.5 GB of partial download never goes into a backup either.
    @discardableResult
    static func makeStaging(_ manifest: ModelManifest, _ folders: ModelFolders) throws -> URL {
        let staging = folders.staging(manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try excludeFromBackup(staging)
        return staging
    }

    /// Hashes every file in the staging folder and deletes the ones that do not match.
    /// When all match, moves the folder into place with one rename. Returns the names it
    /// deleted, empty once the model is installed.
    static func verifyAndInstall(_ manifest: ModelManifest, _ folders: ModelFolders) throws -> [String] {
        let staging = folders.staging(manifest)
        let damaged = try damagedFiles(in: staging, manifest)
        for name in damaged {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
            Logger.modelDownload.error("\(name, privacy: .public) did not match its pinned size and SHA-256 and was deleted")
        }
        guard damaged.isEmpty else { return damaged }
        try excludeFromBackup(staging)
        let installed = folders.installed(manifest)
        if FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.removeItem(at: installed)
        }
        try FileManager.default.moveItem(at: staging, to: installed)
        Logger.modelDownload.notice("Installed the speech model, \(manifest.totalBytes, privacy: .public) bytes")
        return []
    }

    /// Clones a file, which on APFS shares the data blocks and takes no space. When cloning
    /// is not possible, copies it, but only when told there is room.
    static func cloneOrCopy(_ source: URL, to target: URL, copyAllowed: Bool) -> Bool {
        if clonefile(source.path, target.path, 0) == 0 { return true }
        guard copyAllowed else { return false }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            return false
        }
    }

    /// Moves what is left of an installed folder that is incomplete or damaged into the
    /// staging folder, so a download fetches only what is missing, then removes the
    /// installed folder. A file the staging folder already holds whole is kept there.
    static func moveBackToStaging(_ manifest: ModelManifest, _ folders: ModelFolders) throws {
        let installed = folders.installed(manifest)
        let staging = try makeStaging(manifest, folders)
        for file in manifest.files {
            let source = installed.appendingPathComponent(file.name)
            let target = staging.appendingPathComponent(file.name)
            guard size(source) != nil, size(target) != file.size else { continue }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: source, to: target)
        }
        try FileManager.default.removeItem(at: installed)
    }

    /// Once the model is installed, removes the staging folder and the folders of other
    /// revisions of the same model. Nothing outside the Models folder, and no other model.
    static func removeLeftovers(_ manifest: ModelManifest, _ folders: ModelFolders) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.models.path)) ?? []
        for name in names where name != manifest.folderName
            && (name.hasPrefix(manifest.name + "-") || name.hasPrefix(".download-" + manifest.name + "-")) {
            do {
                try FileManager.default.removeItem(at: folders.models.appendingPathComponent(name, isDirectory: true))
                Logger.modelDownload.notice("Removed the leftover folder \(name, privacy: .public)")
            } catch {
                Logger.modelDownload.error("Could not remove the leftover folder \(name, privacy: .public)")
            }
        }
    }

    /// Free space for files the user asked for, on the volume that holds `url` or its
    /// nearest existing parent. Nil when the system does not say.
    static func freeSpace(at url: URL) -> Int64? {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
}

/// What launch and Try Again do with the model: local files only, never the network.
nonisolated enum ModelPreparation {
    enum Result: Sendable, Equatable {
        case installed(URL)
        case missing(bytesPresent: Int64)
    }

    /// Finds the installed model, or finishes an install that a quit interrupted, or
    /// reuses the copy speech-swift left in the old cache folders.
    ///
    /// At launch it checks the installed folder by size only. With `checkingHashes`, used
    /// after the model failed to load, it hashes the installed files too, and a damaged one
    /// sends the rest back to the staging folder, so Download fetches only that file.
    @concurrent
    static func run(_ manifest: ModelManifest, _ folders: ModelFolders, checkingHashes: Bool = false, freeSpace: @escaping @Sendable (URL) -> Int64?) async -> Result {
        let installed = folders.installed(manifest)
        let staging = folders.staging(manifest)
        do {
            if ModelDisk.isComplete(installed, manifest) {
                let damaged = try checkingHashes ? ModelDisk.damagedFiles(in: installed, manifest) : []
                if damaged.isEmpty {
                    ModelDisk.removeLeftovers(manifest, folders)
                    return .installed(installed)
                }
                for name in damaged {
                    try? FileManager.default.removeItem(at: installed.appendingPathComponent(name))
                    Logger.modelDownload.error("Installed \(name, privacy: .public) did not match its pinned SHA-256 and was deleted")
                }
            }
            if FileManager.default.fileExists(atPath: installed.path) {
                try ModelDisk.moveBackToStaging(manifest, folders)
                Logger.modelDownload.notice("Moved an incomplete installed model back to the download folder")
            }
            try reuseOldCopies(manifest, folders, freeSpace: freeSpace)
            if ModelDisk.isComplete(staging, manifest), try ModelDisk.verifyAndInstall(manifest, folders).isEmpty {
                ModelDisk.removeLeftovers(manifest, folders)
                return .installed(installed)
            }
        } catch {
            Logger.modelDownload.error("Checking the model files failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        }
        return .missing(bytesPresent: ModelDisk.bytesPresent(staging, manifest))
    }

    /// Fills the staging folder from an old copy, for every file it lacks whole and an old
    /// copy has at the pinned size. The hash is checked before the install.
    private static func reuseOldCopies(_ manifest: ModelManifest, _ folders: ModelFolders, freeSpace: @Sendable (URL) -> Int64?) throws {
        let staging = folders.staging(manifest)
        var reusable: [(file: ModelFile, old: URL)] = []
        for file in manifest.files where ModelDisk.size(staging.appendingPathComponent(file.name)) != file.size {
            let candidates = folders.oldCopies.map { $0.appendingPathComponent(file.name) }
            if let old = candidates.first(where: { ModelDisk.size($0) == file.size }) {
                reusable.append((file, old))
            }
        }
        guard !reusable.isEmpty else { return }
        try ModelDisk.makeStaging(manifest, folders)
        for (file, old) in reusable {
            let target = staging.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            let room = (freeSpace(staging) ?? 0) >= file.size + ModelDisk.spaceMargin
            if ModelDisk.cloneOrCopy(old, to: target, copyAllowed: room) {
                Logger.modelDownload.notice("Reused \(file.name, privacy: .public) from the old cache")
            } else {
                Logger.modelDownload.notice("Could not reuse \(file.name, privacy: .public) from the old cache")
            }
        }
    }
}
