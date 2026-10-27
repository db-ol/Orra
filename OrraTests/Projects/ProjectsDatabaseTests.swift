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
        for table in ["index_chunk_words", "index_chunk_trigrams", "index_file_names", "index_file_name_trigrams"] {
            #expect(try await database.run("SELECT v FROM \(table)_config WHERE k = 'secure-delete'") == [[.integer(1)]], "\(table)")
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

    /// Step 6 adds the columns and tables of more file types and of text recognition, and
    /// marks the PDFs 0.6.0 stored, those with text and the scans it held as without text, for
    /// recognition. Every other row stays as it was.
    @Test func stepSixMarksThePDFsOfAnEarlierIndex() async throws {
        defer { cleanUp() }
        let early = try await ProjectsDatabase.open(in: storage, migrations: Array(ProjectsDatabase.migrations.prefix(5)))
        let rows: [(String, String?)] = [("/p/Report.PDF", nil), ("/p/scan.pdf", "noText"), ("/p/locked.pdf", "locked"), ("/p/brief.docx", nil), ("/p/empty.txt", "noText")]
        for (path, skip) in rows {
            try await early.run(
                "INSERT INTO index_files (project, path, size, modified, skip) VALUES ('p', ?, 1, 1, ?)", [.text(path), skip.map { .text($0) } ?? .null])
        }
        await early.close()

        let database = try await ProjectsDatabase.open(in: storage)
        #expect(try await database.run("PRAGMA user_version").first == [.integer(7)])
        #expect(ProjectsDatabase.migrations.map(\.version).suffix(2) == [6, 7])
        let marked = try await database.run("SELECT path, skip, recognize, folder FROM index_files ORDER BY path")
        #expect(marked == [
            [.text("/p/Report.PDF"), .null, .integer(1), .null],
            [.text("/p/brief.docx"), .null, .integer(0), .null],
            [.text("/p/empty.txt"), .text("noText"), .integer(0), .null],
            [.text("/p/locked.pdf"), .text("locked"), .integer(0), .null],
            [.text("/p/scan.pdf"), .text("waitsForRecognition"), .integer(1), .null],
        ])
        let columns = try await database.run("SELECT name FROM pragma_table_info('index_chunks') ORDER BY name").compactMap { $0.first?.text }
        #expect(columns.contains("sheet") && columns.contains("recognized"))
        let tables = try await database.run("SELECT name FROM sqlite_schema WHERE type IN ('table', 'index') ORDER BY name").compactMap { $0.first?.text }
        for name in ["index_file_names", "index_file_name_trigrams", "index_recognition_pages", "index_files_waiting"] {
            #expect(tables.contains(name), "\(name)")
        }
        // A file's tried pages go with its row.
        try await database.run("INSERT INTO index_recognition_pages (file, page, size, modified, outcome) SELECT id, 2, 1, 1, 'blank' FROM index_files WHERE path = '/p/scan.pdf'")
        try await database.run("DELETE FROM index_files WHERE path = '/p/scan.pdf'")
        #expect(try await database.run("SELECT count(*) FROM index_recognition_pages") == [[.integer(0)]])
        await database.close()
    }

    /// Step 7 adds the files the user chose for each email. A database at step 6 gains them,
    /// and an email's choices go with the email and with the project of each file.
    @Test func stepSevenKeepsTheChosenFilesWithTheirEmailAndProject() async throws {
        defer { cleanUp() }
        let early = try await ProjectsDatabase.open(in: storage, migrations: Array(ProjectsDatabase.migrations.prefix(6)))
        #expect(try await early.run("PRAGMA user_version").first == [.integer(6)])
        await early.close()

        let database = try await ProjectsDatabase.open(in: storage)
        #expect(try await database.run("PRAGMA user_version").first == [.integer(7)])
        let tables = try await database.run("SELECT name FROM sqlite_schema WHERE type IN ('table', 'index') ORDER BY name").compactMap { $0.first?.text }
        #expect(tables.contains("mail_chosen_files") && tables.contains("mail_chosen_files_by_project"))
        for project in ["harbor", "kiln"] {
            try await database.run("INSERT INTO mail_projects (id) VALUES (?)", [.text(project)])
        }
        func addEmail(_ id: String) async throws -> Int64 {
            try await database.run("""
                INSERT INTO mail_messages (message_id, date, saved, sender_name, sender, subject, subject_key, thread_root, in_reply_to, refs, attachments, hidden_text, warnings)
                VALUES (?1, 1, 1, '', 'kim@quay.example', 'Plans', 'plans', ?1, '[]', '[]', '[]', '[]', '[]') RETURNING id
                """, [.text(id)]).first?.first?.integer ?? -1
        }
        func choose(_ message: Int64, _ files: [(String, String)]) async throws {
            for (project, path) in files {
                try await database.run("INSERT INTO mail_chosen_files (message, project, path) VALUES (?, ?, ?)", [.integer(message), .text(project), .text(path)])
            }
        }
        func chosen() async throws -> [String] {
            try await database.run("SELECT path FROM mail_chosen_files ORDER BY path").compactMap { $0.first?.text }
        }
        let first = try await addEmail("a@test.example")
        let second = try await addEmail("b@test.example")
        try await choose(first, [("harbor", "/p/plan.pdf"), ("kiln", "/k/lamps.md")])
        try await choose(second, [("harbor", "/p/budget.xlsx")])
        // One row for each file of an email.
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await choose(first, [("kiln", "/p/plan.pdf")])
        }
        try await database.run("DELETE FROM mail_projects WHERE id = 'kiln'")
        #expect(try await chosen() == ["/p/budget.xlsx", "/p/plan.pdf"])
        try await database.run("DELETE FROM mail_messages WHERE id = ?", [.integer(first)])
        #expect(try await chosen() == ["/p/budget.xlsx"])
        try await database.run("DELETE FROM mail_projects WHERE id = 'harbor'")
        #expect(try await chosen().isEmpty)
        #expect(try await database.run("SELECT count(*) FROM mail_messages WHERE id = ?", [.integer(second)]) == [[.integer(1)]])
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
