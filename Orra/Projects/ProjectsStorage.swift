import Foundation

/// Where Projects keeps its data on this Mac:
/// ~/Library/Application Support/io.github.db-ol.Orra/Projects in the app.
///
/// Only the user can open its folders (0700) and read its files (0600). The project list sits
/// in the folder itself and is backed up. The index sits in its Index folder, which is left
/// out of backups as a whole, so a database there and the files SQLite writes next to it
/// never go into a backup.
///
/// This is the only Projects code that removes files: Delete All Projects Data, and turning
/// Projects off with Delete. Projects never writes, moves or deletes anything in the user's
/// own folders.
nonisolated struct ProjectsStorage: Sendable {
    /// Orra's folder in Application Support. Tests pass a temporary one.
    let root: URL

    /// Only the user can open a folder of Projects.
    static let folderPermissions: mode_t = 0o700
    /// Only the user can read or write a file of Projects.
    static let filePermissions: mode_t = 0o600

    /// The folder of everything Projects keeps.
    var folder: URL {
        root.appendingPathComponent("Projects", isDirectory: true)
    }

    /// The folder of the index, left out of backups.
    var indexFolder: URL {
        folder.appendingPathComponent("Index", isDirectory: true)
    }

    /// The app's folders. Computing them touches nothing on disk.
    static var live: ProjectsStorage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProjectsStorage(root: support.appendingPathComponent("io.github.db-ol.Orra", isDirectory: true))
    }

    /// Creates both folders for the user alone, and leaves the index out of backups. Either
    /// may be older than these rules, so both are set again.
    func create() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for url in [folder, indexFolder] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.folderPermissions])
            try fileManager.setAttributes([.posixPermissions: Self.folderPermissions], ofItemAtPath: url.path)
        }
        try ModelDisk.excludeFromBackup(indexFolder)
    }

    /// The bytes of every file Projects keeps, 0 when it keeps none. Off the main actor, since
    /// an index can hold many files. Links are skipped, never followed.
    @concurrent
    func size() async -> Int64 {
        sizeNow()
    }

    private func sizeNow() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes everything Projects keeps, with its folder. Nothing to delete is no error.
    /// Off the main actor, since an index can hold many files.
    @concurrent
    func deleteAll() async throws {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
