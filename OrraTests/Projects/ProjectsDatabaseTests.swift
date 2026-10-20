import Foundation
import SQLite3
import Testing
@testable import Orra

/// The Projects database in a temporary root, never the real Application Support.
struct ProjectsDatabaseTests {
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectsDatabaseTests-\(UUID().uuidString)", isDirectory: true))

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func permissions(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Whether a folder is left out of backups, read fresh rather than from the URL's cache.
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try URL(fileURLWithPath: url.path, isDirectory: true).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    /// The bytes of the database and the files SQLite writes next to it.
    private func bytesOnDisk(_ database: ProjectsDatabase) -> Data {
        ["", "-wal", "-shm", "-journal"].reduce(into: Data()) { bytes, suffix in
            bytes += (try? Data(contentsOf: URL(fileURLWithPath: database.file.path + suffix))) ?? Data()
        }
    }

    @Test func theFileAndTheFilesNextToItAreForTheUserAloneInAFolderLeftOutOfBackups() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await database.run("INSERT INTO index_watch (project, last_event) VALUES ('p', 1)")
        #expect(database.file.path == storage.indexFolder.appendingPathComponent("projects.sqlite").path)
        for suffix in ["", "-wal", "-shm"] {
            let path = database.file.path + suffix
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try permissions(path) == 0o600)
        }
        #expect(try permissions(storage.folder.path) == 0o700)
        #expect(try permissions(storage.indexFolder.path) == 0o700)
        #expect(try isExcludedFromBackup(storage.indexFolder))
        #expect(try !isExcludedFromBackup(storage.folder))
        await database.close()
    }

    @Test func anOlderFileIsNarrowed() async throws {
        defer { cleanUp() }
        try storage.create()
        let path = storage.indexFolder.appendingPathComponent(ProjectsDatabase.fileName).path
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]))
        let database = try await ProjectsDatabase.open(in: storage)
        #expect(try permissions(path) == 0o600)
        await database.close()
    }

    /// A link in place of the file could point anywhere, so it is never opened.
    @Test func aLinkInPlaceOfTheFileIsRefused() async throws {
        defer { cleanUp() }
        try storage.create()
        let elsewhere = storage.root.appendingPathComponent("elsewhere.sqlite")
        #expect(FileManager.default.createFile(atPath: elsewhere.path, contents: nil))
        try FileManager.default.createSymbolicLink(
            at: storage.indexFolder.appendingPathComponent(ProjectsDatabase.fileName), withDestinationURL: elsewhere)
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await ProjectsDatabase.open(in: storage)
        }
        #expect(try Data(contentsOf: elsewhere).isEmpty)
    }

    @Test func theSettingsKeepDeletedTextOutOfTheFile() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        #expect(try await database.run("PRAGMA journal_mode").first == [.text("wal")])
        #expect(try await database.run("PRAGMA temp_store").first == [.integer(2)])
        #expect(try await database.run("PRAGMA secure_delete").first == [.integer(1)])
        #expect(try await database.run("PRAGMA foreign_keys").first == [.integer(1)])
        #expect(try await database.run("PRAGMA trusted_schema").first == [.integer(0)])
        #expect(try await database.run("PRAGMA user_version").first == [.integer(Int64(ProjectsDatabase.migrations.count))])
        // macOS 15 has SQLite 3.43 or later, so FTS5 drops deleted rows at once.
        #expect(sqlite3_libversion_number() >= ProjectsDatabase.secureDeleteVersion)
        #expect(database.hasFullTextSecureDelete)
        for table in ["index_chunk_words", "index_chunk_trigrams"] {
            #expect(try await database.run("SELECT v FROM \(table)_config WHERE k = 'secure-delete'") == [[.integer(1)]])
        }
        await database.close()
    }

    /// Text of deleted rows leaves no trace in the file, whether FTS5 drops deleted rows at
    /// once or, with an older SQLite, the index is merged and the file rewritten.
    @Test(arguments: [nil, 3_041_000] as [Int32?])
    func deletedTextLeavesNoTrace(libraryVersion: Int32?) async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage, libraryVersion: libraryVersion ?? sqlite3_libversion_number())
        #expect(database.hasFullTextSecureDelete == (libraryVersion == nil))
        if libraryVersion != nil {
            #expect(try await database.run("SELECT v FROM index_chunk_words_config WHERE k = 'secure-delete'").isEmpty)
        }
        let secret = "zanzibarquokka"
        try await database.transaction { database in
            for row in 1...300 {
                try database.run(
                    "INSERT INTO index_chunk_words (rowid, name, words) VALUES (?, ?, ?)",
                    [.integer(Int64(row)), .text("brief"), .text("\(secret)\(row) plain words \(row)")])
                try database.run(
                    "INSERT INTO index_chunk_trigrams (rowid, name, text) VALUES (?, ?, ?)",
                    [.integer(Int64(row)), .text("brief"), .text("合同\(secret)\(row)")])
            }
        }
        try await database.run("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(bytesOnDisk(database).range(of: Data(secret.utf8)) != nil)
        try await database.transaction { database in
            try database.run("DELETE FROM index_chunk_words")
            try database.run("DELETE FROM index_chunk_trigrams")
        }
        try await database.compactAfterDeletes()
        #expect(bytesOnDisk(database).range(of: Data(secret.utf8)) == nil)
        await database.close()
    }

    @Test func migrationsRunOnceInOrderAndAFailedOneChangesNothing() async throws {
        defer { cleanUp() }
        let first = ProjectsDatabase.Migration(version: 1, sql: "CREATE TABLE a (x);")
        let second = ProjectsDatabase.Migration(version: 2, sql: "CREATE TABLE b (x); INSERT INTO b VALUES (1);")
        var database = try await ProjectsDatabase.open(in: storage, migrations: [second, first])
        #expect(try await database.run("PRAGMA user_version").first == [.integer(2)])
        #expect(try await database.run("SELECT x FROM b") == [[.integer(1)]])
        await database.close()

        // Again, nothing runs twice: CREATE TABLE a would fail.
        database = try await ProjectsDatabase.open(in: storage, migrations: [first, second])
        #expect(try await database.run("SELECT count(*) FROM b") == [[.integer(1)]])
        await database.close()

        let broken = ProjectsDatabase.Migration(version: 3, sql: "CREATE TABLE c (x); CREATE TABLE broken (")
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await ProjectsDatabase.open(in: storage, migrations: [first, second, broken])
        }
        database = try await ProjectsDatabase.open(in: storage, migrations: [first, second])
        #expect(try await database.run("PRAGMA user_version").first == [.integer(2)])
        #expect(try await database.run("SELECT name FROM sqlite_schema WHERE name = 'c'").isEmpty)
        await database.close()
    }

    /// A database from a newer Orra is left as it is.
    @Test func aNewerDatabaseIsRefused() async throws {
        defer { cleanUp() }
        let first = ProjectsDatabase.Migration(version: 1, sql: "CREATE TABLE a (x);")
        let second = ProjectsDatabase.Migration(version: 2, sql: "CREATE TABLE b (x);")
        try await ProjectsDatabase.open(in: storage, migrations: [first, second]).close()
        await #expect(throws: ProjectsDatabase.Failure(step: .newerSchema, code: SQLITE_ERROR)) {
            try await ProjectsDatabase.open(in: storage, migrations: [first])
        }
        let database = try await ProjectsDatabase.open(in: storage, migrations: [first, second])
        #expect(try await database.run("PRAGMA user_version").first == [.integer(2)])
        await database.close()
    }

    @Test func aThrowRollsTheTransactionBack() async throws {
        defer { cleanUp() }
        struct Stop: Error {}
        let database = try await ProjectsDatabase.open(in: storage)
        await #expect(throws: Stop.self) {
            try await database.transaction { database in
                try database.run("INSERT INTO index_watch (project, last_event) VALUES ('p', 1)")
                throw Stop()
            }
        }
        #expect(try await database.run("SELECT count(*) FROM index_watch") == [[.integer(0)]])
        // The next transaction works.
        try await database.transaction { database in
            _ = try database.run("INSERT INTO index_watch (project, last_event) VALUES ('p', 2)")
        }
        #expect(try await database.run("SELECT last_event FROM index_watch") == [[.integer(2)]])
        await database.close()
    }

    /// Every kind of value comes back as it went in, from a statement prepared once and
    /// used again.
    @Test func valuesComeBackAsTheyWentIn() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage, migrations: [
            ProjectsDatabase.Migration(version: 1, sql: "CREATE TABLE v (id INTEGER PRIMARY KEY, value);"),
        ])
        let values: [ProjectsDatabase.Value] = [
            .null, .integer(-42), .integer(Int64.max), .real(3.5), .text(""), .text("合同 v3，付款条款"), .text("a\u{0}b"),
            .text("'; DROP TABLE v; --"), .blob(Data()), .blob(Data([0, 1, 2, 255])),
        ]
        for value in values {
            try await database.run("INSERT INTO v (value) VALUES (?)", [value])
            #expect(await database.lastInsertedRow > 0)
        }
        #expect(try await database.run("SELECT value FROM v ORDER BY id").map { $0[0] } == values)
        #expect(try await database.run("SELECT count(*) FROM v WHERE value = ?", [.text("合同 v3，付款条款")]) == [[.integer(1)]])
        await database.close()
    }

    @Test func aClosedDatabaseRefusesEveryCall() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        await database.close()
        await #expect(throws: ProjectsDatabase.Failure(step: .closed, code: SQLITE_MISUSE)) {
            try await database.run("SELECT 1")
        }
    }
}
