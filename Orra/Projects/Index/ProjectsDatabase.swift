import Foundation
import SQLite3

/// The Projects database, projects.sqlite in `ProjectsStorage.indexFolder`, the only holder of
/// a SQLite handle in Orra. It holds the index of the project folders, see FolderIndex, and the
/// mail, drafts, chosen files and counts of moves of MailStore.
///
/// - The file and the files SQLite writes next to it are for the user alone (0600), in a
///   folder for the user alone (0700) that is left out of backups as a whole, so recent text
///   never goes into a backup through the WAL file either.
/// - WAL, temporary data in memory, and secure delete: SQLite overwrites what it deletes,
///   and FTS5 drops deleted rows from its full text index at once. FTS5 can do that from
///   SQLite 3.42. With an older SQLite, `compactAfterDeletes()` rewrites the full text index
///   and the file instead.
/// - The schema grows by `migrations`, each run once in a transaction and counted in
///   `user_version`. A database from a newer Orra is refused, never changed.
/// - Statements are prepared once and kept. Values are always bound, never written into
///   the SQL.
///
/// Open it only while Projects is on, and close it before Delete All Projects Data.
actor ProjectsDatabase {
    /// A value in a row or a parameter.
    nonisolated enum Value: Sendable, Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var integer: Int64? {
            if case .integer(let value) = self { return value }
            return nil
        }

        /// A real or an integer as a Double.
        var real: Double? {
            switch self {
            case .real(let value): value
            case .integer(let value): Double(value)
            default: nil
            }
        }

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    /// One step of the schema.
    nonisolated struct Migration: Sendable {
        /// The `user_version` once it ran. Steps run in this order, each once.
        var version: Int32
        /// One or more statements.
        var sql: String
    }

    /// Why a call failed, with SQLite's extended result code and never its message, which
    /// can quote the statement.
    nonisolated struct Failure: Error, Equatable, Sendable {
        nonisolated enum Step: String, Sendable {
            case open
            case settings
            case prepare
            case bind
            case step
            /// The database comes from a newer Orra, with steps this one does not know.
            case newerSchema
            /// This SQLite has no FTS5.
            case noFullText
            /// The database was closed.
            case closed
        }

        var step: Step
        var code: Int32
    }

    /// The database's file name in the index folder.
    nonisolated static let fileName = "projects.sqlite"
    /// The SQLite version, as `sqlite3_libversion_number()` gives it, from which FTS5 has
    /// the secure-delete option.
    nonisolated static let secureDeleteVersion: Int32 = 3_042_000

    /// The schema, in order. First the index of the project folders, see FolderIndex, then
    /// the tables of MailStore, see `MailStore.migration`, the text of attachments, see
    /// `MailStore.attachmentTextMigration`, whether an email was too large to read, see
    /// `MailStore.tooLargeMigration`, the text the user typed into drafts, see
    /// `MailStore.editedDraftMigration`, the names of every file and what text recognition
    /// needs, see `FolderIndex.fileTypesMigration`, and the files the user chose for an email,
    /// see `MailStore.chosenFilesMigration`.
    ///
    /// - index_files: one row for each file the index lists, with its text or with why it
    ///   gives none, and the size and modification date it had, so it is read again only
    ///   after it changes.
    /// - index_chunks: the chunks of a file's text.
    /// - index_chunk_words: FTS5 unicode61 over each chunk's words, which NLTokenizer found,
    ///   so a two character Chinese word matches, with the words of its file's name in a
    ///   column of their own, which a rename changes.
    /// - index_chunk_trigrams: FTS5 trigram over the chunks that hold Chinese characters, so
    ///   a run of three characters matches where the words were split another way, again
    ///   with the file's name in a column of its own.
    /// - index_watch: the last folder event of a project that the index took in.
    /// - index_file_names and index_file_name_trigrams: the words of each file's name and
    ///   folder, see FileNameSearch, apart from the chunks.
    /// - index_recognition_pages: the pages text recognition tried, see
    ///   `FolderIndex.fileTypesMigration`.
    nonisolated static let migrations: [Migration] = [
        Migration(version: 1, sql: """
            CREATE TABLE index_files (
                id INTEGER PRIMARY KEY,
                project TEXT NOT NULL,
                path TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified REAL NOT NULL,
                skip TEXT,
                hidden_runs INTEGER NOT NULL DEFAULT 0,
                text_bytes INTEGER NOT NULL DEFAULT 0,
                chunks INTEGER NOT NULL DEFAULT 0,
                UNIQUE (project, path)
            );
            CREATE TABLE index_chunks (
                id INTEGER PRIMARY KEY,
                file INTEGER NOT NULL REFERENCES index_files (id),
                project TEXT NOT NULL,
                page INTEGER,
                heading TEXT,
                modified REAL NOT NULL,
                text TEXT NOT NULL,
                chinese INTEGER NOT NULL
            );
            CREATE INDEX index_chunks_by_file ON index_chunks (file);
            CREATE INDEX index_chunks_by_project ON index_chunks (project, modified);
            CREATE VIRTUAL TABLE index_chunk_words USING fts5 (name, words, tokenize = 'unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE index_chunk_trigrams USING fts5 (name, text, tokenize = 'trigram');
            CREATE TABLE index_watch (
                project TEXT PRIMARY KEY,
                last_event INTEGER NOT NULL
            );
            """),
        MailStore.migration,
        MailStore.attachmentTextMigration,
        MailStore.tooLargeMigration,
        MailStore.editedDraftMigration,
        FolderIndex.fileTypesMigration,
        MailStore.chosenFilesMigration,
    ]

    /// The database file.
    nonisolated let file: URL
    /// Whether FTS5 drops deleted rows from its index at once. Otherwise
    /// `compactAfterDeletes()` rewrites it.
    nonisolated let hasFullTextSecureDelete: Bool
    private let connection: Connection

    /// The SQLite handle and the statements prepared on it, closed when the database goes
    /// away or is closed.
    private nonisolated final class Connection {
        var handle: OpaquePointer?
        var statements: [String: OpaquePointer] = [:]

        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        deinit {
            close()
        }

        func close() {
            for statement in statements.values {
                sqlite3_finalize(statement)
            }
            statements = [:]
            sqlite3_close_v2(handle)
            handle = nil
        }
    }

    private var handle: OpaquePointer? {
        connection.handle
    }

    /// Opens the database in `storage`, creating its folders and the file when needed, and
    /// brings its schema up to `migrations`. Off the main actor, since it reads and writes
    /// the disk. `libraryVersion` is SQLite's own, tests pass an older one.
    @concurrent
    nonisolated static func open(
        in storage: ProjectsStorage,
        migrations: [Migration] = ProjectsDatabase.migrations,
        libraryVersion: Int32 = sqlite3_libversion_number()
    ) async throws -> ProjectsDatabase {
        let database = try ProjectsDatabase(storage: storage, libraryVersion: libraryVersion)
        do {
            try await database.configure(migrations: migrations)
        } catch {
            await database.close()
            throw error
        }
        return database
    }

    private init(storage: ProjectsStorage, libraryVersion: Int32) throws {
        try storage.create()
        file = storage.indexFolder.appendingPathComponent(Self.fileName)
        hasFullTextSecureDelete = libraryVersion >= Self.secureDeleteVersion
        guard sqlite3_compileoption_used("ENABLE_FTS5") == 1 else {
            throw Failure(step: .noFullText, code: SQLITE_ERROR)
        }
        // SQLite refuses a path with a link anywhere in it, so the folder's real path, in
        // case a folder above it is a link. The file itself must not be one.
        guard let folder = realpath(storage.indexFolder.path, nil) else { throw Failure(step: .open, code: errno) }
        let path = String(cString: folder) + "/" + Self.fileName
        free(folder)
        try Self.createFile(path)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_EXRESCODE
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            throw Failure(step: .open, code: result)
        }
        connection = Connection(opened)
    }

    // MARK: Statements

    /// Runs one statement with its parameters and returns the rows it gives.
    @discardableResult
    func run(_ sql: String, _ parameters: [Value] = []) throws -> [[Value]] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in parameters.enumerated() {
            let result = Self.bind(value, at: Int32(index + 1), in: statement)
            guard result == SQLITE_OK else { throw Failure(step: .bind, code: result) }
        }
        var rows: [[Value]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw Failure(step: .step, code: result) }
            rows.append((0..<sqlite3_column_count(statement)).map { Self.column($0, of: statement) })
        }
    }

    /// Runs statements without parameters, such as the steps of the schema.
    func execute(_ sql: String) throws {
        guard let handle else { throw Failure(step: .closed, code: SQLITE_MISUSE) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw Failure(step: .step, code: sqlite3_extended_errcode(handle)) }
    }

    /// The row ID of the last row inserted.
    var lastInsertedRow: Int64 {
        handle.map(sqlite3_last_insert_rowid) ?? 0
    }

    /// Runs `body` in one transaction. A throw rolls back everything it did.
    func transaction<T: Sendable>(_ body: @Sendable (isolated ProjectsDatabase) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// After rows with text were deleted, makes sure their text is gone from the file. With
    /// an SQLite older than 3.42, FTS5 keeps deleted rows in its index until it merges, so
    /// both full text indexes are merged and the file is rewritten. In either case the WAL
    /// file is emptied, so no copy of a deleted page stays in it.
    func compactAfterDeletes() throws {
        if !hasFullTextSecureDelete {
            for table in try fullTextTables() {
                try run("INSERT INTO \(table) (\(table)) VALUES ('optimize')")
            }
            try execute("VACUUM")
        }
        try run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Closes the database. Every later call throws.
    func close() {
        connection.close()
    }

    // MARK: Opening

    /// Creates the file for the user alone when it is missing, without following a link, and
    /// narrows an older one. SQLite gives the files it writes next to it the same mode.
    private nonisolated static func createFile(_ path: String) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, ProjectsStorage.filePermissions)
        guard descriptor >= 0 else { throw Failure(step: .open, code: errno) }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, ProjectsStorage.filePermissions) == 0 else { throw Failure(step: .open, code: errno) }
    }

    private func configure(migrations: [Migration]) throws {
        guard let handle else { throw Failure(step: .closed, code: SQLITE_MISUSE) }
        sqlite3_busy_timeout(handle, 2_000)
        do {
            try run("PRAGMA journal_mode = WAL")
            try execute("""
                PRAGMA synchronous = NORMAL;
                PRAGMA temp_store = MEMORY;
                PRAGMA secure_delete = ON;
                PRAGMA foreign_keys = ON;
                PRAGMA trusted_schema = OFF;
                """)
        } catch let failure as Failure {
            throw Failure(step: .settings, code: failure.code)
        }
        try migrate(to: migrations)
        if hasFullTextSecureDelete {
            let tables = try fullTextTables()
            if !tables.isEmpty {
                try transaction { database in
                    for table in tables {
                        try database.run("INSERT INTO \(table) (\(table), rank) VALUES ('secure-delete', 1)")
                    }
                }
            }
        }
    }

    private func migrate(to migrations: [Migration]) throws {
        let current = Int32(try run("PRAGMA user_version").first?.first?.integer ?? 0)
        let known = migrations.map(\.version).max() ?? 0
        guard current <= known else { throw Failure(step: .newerSchema, code: SQLITE_ERROR) }
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            try transaction { database in
                try database.execute(migration.sql)
                try database.execute("PRAGMA user_version = \(migration.version)")
            }
        }
    }

    /// The FTS5 tables of the schema, by their names, which hold only letters, digits and
    /// underscores, so they can stand in SQL.
    private func fullTextTables() throws -> [String] {
        try run("SELECT name FROM sqlite_schema WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE % USING fts5%' ORDER BY name")
            .compactMap { $0.first?.text }
            .filter { name in
                !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
            }
    }

    // MARK: Values

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = connection.statements[sql] { return statement }
        guard let handle else { throw Failure(step: .closed, code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard result == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw Failure(step: .prepare, code: result)
        }
        connection.statements[sql] = statement
        return statement
    }

    /// SQLite copies the value before the call returns.
    private nonisolated static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private nonisolated static func bind(_ value: Value, at index: Int32, in statement: OpaquePointer) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case .integer(let number):
            return sqlite3_bind_int64(statement, index, number)
        case .real(let number):
            return sqlite3_bind_double(statement, index, number)
        case .text(let string):
            // With its length in bytes, so a NUL inside the text does not end it.
            return string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), transient) }
        case .blob(let data):
            guard !data.isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
            return data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        }
    }

    private nonisolated static func column(_ index: Int32, of statement: OpaquePointer) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
