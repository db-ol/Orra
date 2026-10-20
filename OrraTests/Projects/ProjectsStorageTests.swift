import Foundation
import Testing
@testable import Orra

/// Where Projects keeps its data: in a temporary root, never the real Application Support.
struct ProjectsStorageTests {
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectsStorageTests-\(UUID().uuidString)", isDirectory: true))

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    /// The permissions of a file or folder.
    private func permissions(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Whether a folder is left out of backups, read fresh rather than from the URL's cache.
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    /// Writes `bytes` bytes at `url` that only the user can read, as Projects writes.
    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: ProjectsStorage.filePermissions], ofItemAtPath: url.path)
    }

    @Test func theAppKeepsProjectsInItsOwnApplicationSupportFolder() {
        let live = ProjectsStorage.live
        #expect(live.folder.path.hasSuffix("/Library/Application Support/io.github.db-ol.Orra/Projects"))
        #expect(live.indexFolder.path.hasSuffix("/Library/Application Support/io.github.db-ol.Orra/Projects/Index"))
        #expect(ProjectsStorage.folderPermissions == 0o700)
        #expect(ProjectsStorage.filePermissions == 0o600)
    }

    /// Only the user can open either folder. The index is left out of backups, the folder with
    /// the project list is not.
    @Test func createMakesBothFoldersForTheUserAloneAndKeepsTheIndexOutOfBackups() throws {
        defer { cleanUp() }
        try storage.create()
        #expect(try permissions(storage.folder) == 0o700)
        #expect(try permissions(storage.indexFolder) == 0o700)
        #expect(try isExcludedFromBackup(storage.indexFolder))
        #expect(try !isExcludedFromBackup(storage.folder))
        // Again changes nothing.
        try storage.create()
        #expect(try permissions(storage.indexFolder) == 0o700)
    }

    /// Folders made earlier with wider permissions are narrowed.
    @Test func olderFoldersAreNarrowed() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: storage.indexFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.folder.path)
        try storage.create()
        #expect(try permissions(storage.folder) == 0o700)
        #expect(try permissions(storage.indexFolder) == 0o700)
        #expect(try isExcludedFromBackup(storage.indexFolder))
    }

    /// Every file in both folders counts. A link counts as nothing and is never followed.
    @Test func sizeCountsEveryFileProjectsKeeps() async throws {
        defer { cleanUp() }
        #expect(await storage.size() == 0)
        try storage.create()
        #expect(await storage.size() == 0)
        try write(300, to: storage.folder.appendingPathComponent("projects.json"))
        try write(2_000, to: storage.indexFolder.appendingPathComponent("projects.sqlite"))
        try write(50, to: storage.indexFolder.appendingPathComponent("projects.sqlite-wal"))
        #expect(await storage.size() == 2_350)
        let outside = storage.root.appendingPathComponent("outside.bin")
        try write(10_000, to: outside)
        try FileManager.default.createSymbolicLink(at: storage.folder.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(await storage.size() == 2_350)
    }

    /// Delete All removes the folder with everything in it, and nothing of Orra's beside it,
    /// nor what a link inside points to.
    @Test func deleteAllRemovesOnlyWhatProjectsKeeps() async throws {
        defer { cleanUp() }
        try storage.create()
        try write(300, to: storage.folder.appendingPathComponent("projects.json"))
        try write(2_000, to: storage.indexFolder.appendingPathComponent("projects.sqlite"))
        let voice = storage.root.appendingPathComponent("Voice/voice-sample.dat")
        try write(100, to: voice)
        let outside = storage.root.appendingPathComponent("outside.bin")
        try write(10, to: outside)
        try FileManager.default.createSymbolicLink(at: storage.indexFolder.appendingPathComponent("link"), withDestinationURL: outside)
        try await storage.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        #expect(FileManager.default.fileExists(atPath: voice.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(await storage.size() == 0)
        // Nothing left to delete is no error.
        try await storage.deleteAll()
    }
}
