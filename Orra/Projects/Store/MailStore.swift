import CryptoKit
import Foundation
import os

/// The mail Projects read, where sorting filed it, its reply mark, its latest explanation,
/// the versions of its draft and the counts of the user's moves, in the Projects database
/// (plan section 5, projects-store).
///
/// - Its tables come with `migration`, the second step of ProjectsDatabase. Every call runs
///   its statements and reads or writes their JSON on the database's actor, never on the
///   main actor. The words that find an email are worked out before, off both actors.
/// - The services read and save through closures the app makes from these calls, so they
///   never wait for the store: `sortingLookups` and `sortingSaves` for SortingService, and
///   the explain and draft calls for ExplainService and ReviseService.
/// - A decision is saved in one statement that also checks that the user did not move the
///   email and that its project still exists. It returns whether it saved.
/// - The counts of the user's moves are kept as SortingService gives them, by rule and
///   project, and never faded or reset here. SortingService fades them.
/// - Every email, count and draft of a project hangs on the project's row in
///   mail_projects, so Forget Project removes them all in one write, and nothing can be
///   filed in the project after it. `add(project:)` registers a new project.
/// - An explanation belongs to the project it was made for. When an email changes project,
///   its explanation and draft go, so no text of the project before stays with it.
/// - The thread of each email is worked out when it is saved, see MailThreads, and joined
///   again when an earlier message of the thread comes later.
/// - Text goes into the file only for the time Retention allows. What a delete removes is
///   overwritten, see ProjectsDatabase.compactAfterDeletes. The Message-ID of an email that
///   Forget Project or Retention removed is kept as a hash only, so the scan never reads that
///   email again, see `goneKey(_:)`.
///
/// Logs counts and error codes only.
nonisolated struct MailStore: Sendable {
    /// A person in a mail header, as it gives the name and the address.
    nonisolated struct Person: Sendable, Equatable, Codable {
        var name: String = ""
        var address: String
    }

    /// An attachment's name and MIME type. Phase 1 reads no attachment text (decision 14).
    nonisolated struct Attachment: Sendable, Equatable, Codable {
        var name: String
        var type: String
    }

    /// One email as the scan read it, through MIMEMessage, VisibleText and QuotedHistory.
    nonisolated struct Message: Sendable, Equatable {
        /// The Message-ID, without angle brackets.
        var messageID: String
        /// The Mail mailbox it was read from, in the form of `SortingInput.mailbox`.
        var mailbox: String?
        var date: Date
        var sender: Person
        var to: [Person] = []
        var cc: [Person] = []
        var replyTo: [Person] = []
        var subject: String = ""
        /// The Message-IDs of In-Reply-To and of References, oldest first, without angle
        /// brackets.
        var inReplyTo: [String] = []
        var references: [String] = []
        var list = ListMail()
        /// The email's own text: visible, without the quoted history.
        var text: String
        /// The visible text with its quoted history and signature, which the content checks
        /// read.
        var visibleText: String
        /// The kinds of text the email hides from its reader, as VisibleText found them.
        var hiddenText: [ProjectsHiddenText] = []
        var attachments: [Attachment] = []
        /// What the user sees about the email before it is explained. An explanation adds
        /// its own warnings.
        var warnings: [ProjectsWarning] = []
    }

    /// The lists of the Projects window.
    nonisolated enum Place: Sendable, Hashable {
        case project(UUID)
        /// Mail with no project yet: not sorted, unsure, or moved there by the user.
        case needsProject
        case setAside
    }

    /// An email in a list of the window.
    nonisolated struct Listed: Sendable, Equatable {
        var messageID: String
        var date: Date
        var sender: Person
        var subject: String
        var project: UUID?
        /// Nil until it is sorted.
        var level: SortingLevel?
        /// Why it was filed, strongest first. Empty when the user moved it or before it
        /// was sorted.
        var reasons: [SortingReason]
        var movedByUser: Bool
        /// Nil until it is sorted.
        var reply: ReplyRule.Decision?
        var warnings: [ProjectsWarning]
        var isExplained: Bool
        /// Whether the email's text is still kept, see Retention.
        var hasText: Bool
        /// The line under the subject (decision 16): the explanation's first point, or the
        /// first sentence of the email's own text until it is explained. Empty once
        /// Retention removed both.
        var summary: String
    }

    /// A version of a draft, from the user's instruction or a tone. The explanation holds
    /// the first draft.
    nonisolated struct DraftVersion: Sendable, Equatable {
        /// 1 for the first change after the explanation's draft, then counting up.
        var number: Int
        var made: Date
        var version: ReviseService.Version
    }

    /// The tables of the store, the second step of ProjectsDatabase.migrations.
    ///
    /// - mail_projects: the projects the list holds, which every row of a project hangs on.
    /// - mail_messages: one row for each email, with where sorting filed it and whether the
    ///   user moved it, whether sorting runs for it again (`waits`: its decision waits for
    ///   the model, or its thread changed), its reply mark, its text (until Retention removes
    ///   it), the words that find it as other mail of its project, its latest explanation as
    ///   JSON, and when its draft last changed.
    /// - mail_people: the sender, To, Cc and Reply-To of each email, with the address in
    ///   the form of ProjectsAddress, for the people seen in a project and those the user
    ///   wrote to.
    /// - mail_draft_versions: the versions of an email's draft, as JSON.
    /// - mail_tallies: the moves of one kind to a project, see SortingService.Tally.
    /// - mail_gone: the hash of each Message-ID that Forget Project or Retention removed,
    ///   until the scan can no longer reach it, see `goneKey(_:)` and `Retention.goneIDs`.
    static let migration = ProjectsDatabase.Migration(version: 2, sql: """
        CREATE TABLE mail_projects (
            id TEXT PRIMARY KEY
        ) WITHOUT ROWID;
        CREATE TABLE mail_messages (
            id INTEGER PRIMARY KEY,
            message_id TEXT NOT NULL UNIQUE,
            mailbox TEXT,
            date REAL NOT NULL,
            saved REAL NOT NULL,
            sender_name TEXT NOT NULL,
            sender TEXT NOT NULL,
            sender_key TEXT,
            subject TEXT NOT NULL,
            subject_key TEXT NOT NULL,
            thread_root TEXT NOT NULL,
            in_reply_to TEXT NOT NULL,
            refs TEXT NOT NULL,
            list_id TEXT,
            list_unsubscribe TEXT,
            precedence TEXT,
            attachments TEXT NOT NULL,
            hidden_text TEXT NOT NULL,
            warnings TEXT NOT NULL,
            project TEXT REFERENCES mail_projects (id) ON DELETE CASCADE,
            level TEXT,
            reasons TEXT NOT NULL DEFAULT '[]',
            waits INTEGER NOT NULL DEFAULT 0,
            moved_by_user INTEGER NOT NULL DEFAULT 0,
            reply TEXT,
            text TEXT,
            visible_text TEXT,
            words TEXT,
            explanation BLOB,
            explained REAL,
            explanation_draft INTEGER NOT NULL DEFAULT 0,
            draft_changed REAL
        );
        CREATE INDEX mail_messages_by_project ON mail_messages (project, date);
        CREATE INDEX mail_messages_by_thread ON mail_messages (thread_root);
        CREATE INDEX mail_messages_by_subject ON mail_messages (subject_key, date);
        CREATE INDEX mail_messages_by_date ON mail_messages (date);
        CREATE INDEX mail_messages_by_sender ON mail_messages (sender_key, date);
        CREATE TABLE mail_people (
            message INTEGER NOT NULL REFERENCES mail_messages (id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            position INTEGER NOT NULL,
            name TEXT NOT NULL,
            address TEXT NOT NULL,
            key TEXT,
            PRIMARY KEY (message, role, position)
        ) WITHOUT ROWID;
        CREATE INDEX mail_people_by_key ON mail_people (key);
        CREATE TABLE mail_draft_versions (
            message INTEGER NOT NULL REFERENCES mail_messages (id) ON DELETE CASCADE,
            number INTEGER NOT NULL,
            made REAL NOT NULL,
            version BLOB NOT NULL,
            PRIMARY KEY (message, number)
        ) WITHOUT ROWID;
        CREATE TABLE mail_tallies (
            project TEXT NOT NULL REFERENCES mail_projects (id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            value TEXT NOT NULL,
            count INTEGER NOT NULL,
            last REAL NOT NULL,
            PRIMARY KEY (project, kind, value)
        ) WITHOUT ROWID;
        CREATE TABLE mail_gone (
            id_hash TEXT PRIMARY KEY,
            until REAL NOT NULL
        ) WITHOUT ROWID;
        """)

    /// The most messages of a subject looked at to join a reply to its thread by subject.
    static let maximumSubjectMatches = 200
    /// The most messages of a thread the explanation gets, those nearest the email. The
    /// prompt shows 8 of them, and the reply rule reads who wrote when.
    static let maximumThreadMessages = 100
    /// The most mails the user sent that the forged quote check compares with, the newest.
    static let maximumSentTexts = 2_000
    /// An email's text and visible text are read this far, as far as the content checks
    /// read them. The words that find an email come from this much of its text too.
    static let readLength = ContentChecks.checkedLength
    /// The list reads this much of the text, for the first sentence.
    static let summaryReadLength = 1_000
    /// The most characters of the line under the subject.
    static let summaryLength = 200

    let database: ProjectsDatabase

    init(database: ProjectsDatabase) {
        self.database = database
    }

    /// Closes the database, before Delete All Projects Data. Every later call throws.
    func close() async {
        await database.close()
    }

    // MARK: Projects

    /// Registers a new project, so mail can be filed in it.
    func add(project: UUID) async throws {
        try await database.run("INSERT OR IGNORE INTO mail_projects (id) VALUES (?)", [.text(project.uuidString)])
    }

    /// Forget Project, for the store: removes the project with its emails, their drafts and
    /// the counts of moves to it, in one write. Mail filed in it after this is not saved,
    /// and the scan never reads its emails again. The project's index of files is
    /// FolderIndex's, see `FolderIndex.forget`.
    func forget(project: UUID) async throws {
        let id = project.uuidString
        let emails = try await database.transaction { database in
            let emails = try Self.deleteGone(where: "project = ?", [.text(id)], in: database)
            try database.run("DELETE FROM mail_projects WHERE id = ?", [.text(id)])
            return emails
        }
        try await database.compactAfterDeletes()
        Logger.projects.notice("Mail store: forgot a project with \(emails, privacy: .public) emails")
    }

    /// Registers the projects of the list, and removes the store's data of every other
    /// project. Returns the IDs of the projects the database held data for, its index
    /// included, that the list does not hold, so the caller can forget their index too.
    /// The user never forgot these projects, such as after a failed write of projects.json,
    /// so their emails are not kept as gone: the scan reads them again and sorting files
    /// them in the projects the list holds.
    func keep(projects: Set<UUID>) async throws -> Set<UUID> {
        let kept = projects.map(\.uuidString)
        let gone = try await database.transaction { database in
            for id in kept {
                try database.run("INSERT OR IGNORE INTO mail_projects (id) VALUES (?)", [.text(id)])
            }
            let known = try database.run("""
                SELECT id FROM mail_projects
                UNION SELECT project FROM index_files
                UNION SELECT project FROM index_watch
                """).compactMap { $0.first?.text }
            let gone = Set(known).subtracting(kept)
            for id in gone {
                try database.run("DELETE FROM mail_projects WHERE id = ?", [.text(id)])
            }
            return gone
        }
        if !gone.isEmpty {
            try await database.compactAfterDeletes()
        }
        return Set(gone.compactMap(UUID.init(uuidString:)))
    }

    // MARK: Saving mail

    /// The Message-IDs of these that the store holds, or that Forget Project or Retention
    /// removed, so a scan skips them and stops at the first one.
    func known(_ messageIDs: [String]) async throws -> Set<String> {
        guard !messageIDs.isEmpty else { return [] }
        let byKey = Dictionary(messageIDs.map { (Self.goneKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let ids = try Self.json(messageIDs)
        let keys = try Self.json(Array(byKey.keys))
        return try await database.transaction { database in
            let held = try database.run("SELECT message_id FROM mail_messages WHERE message_id IN (SELECT value FROM json_each(?))", [.text(ids)])
                .compactMap { $0.first?.text }
            let gone = try database.run("SELECT id_hash FROM mail_gone WHERE id_hash IN (SELECT value FROM json_each(?))", [.text(keys)])
                .compactMap { $0.first?.text.flatMap { byKey[$0] } }
            return Set(held + gone)
        }
    }

    /// Saves new emails, oldest first, each with the root of its thread, and returns the
    /// Message-IDs of those it saved. An email the store holds already, by its Message-ID,
    /// stays as it is, and so does one without a Message-ID. An email that Forget Project or
    /// Retention removed is not saved again.
    ///
    /// An email whose thread holds messages saved before it, which could not know it then,
    /// joins them to its thread's root. Sorting runs for them again, see `waiting()`, so their
    /// reply marks and projects count the whole thread. A reply joined only by its subject
    /// that comes before a first message without a reply prefix stays in a thread of its own.
    /// - Parameters:
    ///   - ownAddresses: the user's, which joining a reply to its thread by subject leaves out.
    ///   - now: when Orra read them, from which Retention counts.
    @discardableResult
    func save(_ messages: [Message], ownAddresses: [String], at now: Date) async throws -> [String] {
        guard !messages.isEmpty else { return [] }
        let own = Set(ownAddresses.compactMap(ProjectsAddress.normalized))
        let ordered = await Self.prepared(messages)
        let saved = try await database.transaction { database in
            var saved: [String] = []
            for (message, words, goneKey) in ordered {
                guard try database.run("SELECT 1 FROM mail_messages WHERE message_id = ?", [.text(message.messageID)]).isEmpty,
                      try database.run("SELECT 1 FROM mail_gone WHERE id_hash = ?", [.text(goneKey)]).isEmpty else { continue }
                let root = try Self.root(of: message, own: own, in: database)
                try Self.insert(message, root: root, words: words, at: now, in: database)
                if root != message.messageID {
                    // Messages saved before their parent took the parent's ID as their root.
                    try database.run("""
                        UPDATE mail_messages SET thread_root = ?1, waits = CASE WHEN moved_by_user = 0 THEN 1 ELSE waits END
                        WHERE thread_root = ?2
                        """, [.text(root), .text(message.messageID)])
                }
                saved.append(message.messageID)
            }
            return saved
        }
        Logger.projects.notice("Mail store: saved \(saved.count, privacy: .public) of \(messages.count, privacy: .public) emails")
        return saved
    }

    /// The emails with a Message-ID, oldest first, each with the words that find it and the
    /// key of its Message-ID in mail_gone. Off the main actor and the database's, since
    /// PromptHygiene and the tokenizer read long text.
    @concurrent
    private static func prepared(_ messages: [Message]) async -> [(message: Message, words: String, goneKey: String)] {
        messages.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
            .filter { !$0.messageID.isEmpty }
            .map { message in
                let text = cleaned(message.subject) + "\n" + cleaned(String(message.text.prefix(readLength)))
                return (message, Set(ChunkSearch.words(in: text)).sorted().joined(separator: "\n"), goneKey(message.messageID))
            }
    }

    // MARK: Sorting

    /// Where an email was filed, or nil when it is not known or not sorted yet.
    func filed(_ messageID: String) async throws -> SortingService.Filed? {
        let rows = try await database.run(
            "SELECT project, moved_by_user FROM mail_messages WHERE message_id = ? AND level IS NOT NULL",
            [.text(messageID)])
        guard let row = rows.first, row.count == 2 else { return nil }
        return SortingService.Filed(project: row[0].text.flatMap(UUID.init(uuidString:)), movedByUser: row[1].integer == 1)
    }

    /// For these addresses, in the form of ProjectsAddress, the projects whose mail held one
    /// of them as sender, To or Cc, with the addresses found in each. Needs a Project and
    /// Set Aside do not count.
    func peopleSeen(_ addresses: [String]) async throws -> [UUID: Set<String>] {
        guard !addresses.isEmpty else { return [:] }
        let rows = try await database.run("""
            SELECT DISTINCT m.project, p.key FROM mail_people p JOIN mail_messages m ON m.id = p.message
            WHERE p.key IN (SELECT value FROM json_each(?)) AND p.role IN ('from', 'to', 'cc') AND m.project IS NOT NULL
            """, [.text(try Self.json(addresses))])
        var seen: [UUID: Set<String>] = [:]
        for row in rows where row.count == 2 {
            guard let project = row[0].text.flatMap(UUID.init(uuidString:)), let address = row[1].text else { continue }
            seen[project, default: []].insert(address)
        }
        return seen
    }

    /// The other messages known in the email's thread, oldest first.
    func thread(of email: SortingService.Email) async throws -> [SortingService.ThreadMessage] {
        let threading = MailThreads.Message(
            messageID: email.messageID, inReplyTo: email.inReplyTo, references: email.references,
            subject: email.subject, people: [], date: email.date)
        return try await database.transaction { database in
            let root = try Self.storedRoot(of: email.messageID, in: database) ?? Self.root(of: threading, own: [], in: database)
            return try database.run(
                "SELECT message_id, sender, date FROM mail_messages WHERE thread_root = ? AND message_id != ? ORDER BY date, id",
                [.text(root), .text(email.messageID)]
            ).compactMap { row in
                guard row.count == 3, let id = row[0].text, let sender = row[1].text, let date = row[2].real else { return nil }
                return SortingService.ThreadMessage(messageID: id, sender: sender, date: Date(timeIntervalSince1970: date))
            }
        }
    }

    /// The emails never sorted, whose decision waits for the model, or whose thread an
    /// earlier message joined later, oldest first. Never one the user moved.
    func waiting() async throws -> [SortingService.Email] {
        try await database.transaction { database in
            try Self.rows(where: "moved_by_user = 0 AND (level IS NULL OR waits = 1) ORDER BY date, id", in: database)
                .map(\.sortingEmail)
        }
    }

    /// An email as sorting reads it, such as for a move.
    func sortingEmail(_ messageID: String) async throws -> SortingService.Email? {
        try await database.transaction { database in
            try Self.rows(where: "message_id = ?", [.text(messageID)], in: database).first?.sortingEmail
        }
    }

    /// The moves of one kind to a project, as `saveTally` kept them.
    func tally(_ rule: SortingCandidate.Rule, project: UUID) async throws -> SortingService.Tally? {
        let rule = Project.Rule(rule)
        let rows = try await database.run(
            "SELECT count, last FROM mail_tallies WHERE project = ? AND kind = ? AND value = ?",
            [.text(project.uuidString), .text(rule.kind.rawValue), .text(rule.value)])
        guard let row = rows.first, row.count == 2, let count = row[0].integer, let last = row[1].real else { return nil }
        return SortingService.Tally(count: Int(count), last: Date(timeIntervalSince1970: last))
    }

    /// Saves an email's decision and says whether it did. Nothing is saved for an email
    /// the user moved, for a project that no longer exists, or for an email the store does
    /// not hold. The check and the write are one statement. A decision for another project
    /// drops the email's explanation and draft.
    func saveDecision(_ decision: SortingDecision, for messageID: String) async throws -> Bool {
        let parameters: [ProjectsDatabase.Value] = [
            .text(messageID),
            Self.value(decision.project?.uuidString),
            .text(decision.level.rawValue),
            .text(try Self.json(decision.reasons.map(\.rawValue))),
            .integer(decision.waitsForModel ? 1 : 0),
        ]
        return try await database.transaction { database in
            let rows = try database.run("""
                UPDATE mail_messages SET \(Self.explanationForProject), project = ?2, level = ?3, reasons = ?4, waits = ?5
                WHERE message_id = ?1 AND moved_by_user = 0 AND (?2 IS NULL OR ?2 IN (SELECT id FROM mail_projects))
                RETURNING id
                """, parameters)
            try Self.dropVersionsWithoutExplanation(rows, in: database)
            return !rows.isEmpty
        }
    }

    /// The SET of an UPDATE that files an email in the project ?2: the explanation, which
    /// holds text of the project it was made for, and its draft stay only when the project
    /// stays. SQLite reads `project` here as it was before the UPDATE.
    private static let explanationForProject = """
        explanation = CASE WHEN project IS ?2 THEN explanation END, \
        explained = CASE WHEN project IS ?2 THEN explained END, \
        explanation_draft = CASE WHEN project IS ?2 THEN explanation_draft ELSE 0 END, \
        draft_changed = CASE WHEN project IS ?2 THEN draft_changed END
        """

    /// Removes the draft versions of the emails in `rows`, by their id in the first column,
    /// that have no explanation.
    private static func dropVersionsWithoutExplanation(_ rows: [[ProjectsDatabase.Value]], in database: isolated ProjectsDatabase) throws {
        for id in rows.compactMap({ $0.first?.integer }) {
            try database.run(
                "DELETE FROM mail_draft_versions WHERE message = ?1 AND (SELECT explanation FROM mail_messages WHERE id = ?1) IS NULL",
                [.integer(id)])
        }
    }

    /// Saves an email's reply mark.
    func saveReply(_ reply: ReplyRule.Decision, for messageID: String) async throws {
        try await database.run("UPDATE mail_messages SET reply = ? WHERE message_id = ?", [.text(Self.code(reply)), .text(messageID)])
    }

    /// Saves the user's move of an email to a project, or to Needs a Project with nil, and
    /// says whether it did. Sorting never files the email again. Nothing is saved for a
    /// project that no longer exists. A move to another project drops the email's
    /// explanation and draft.
    @discardableResult
    func move(_ messageID: String, to project: UUID?) async throws -> Bool {
        let level: SortingLevel = project == nil ? .unsure : .sure
        let parameters: [ProjectsDatabase.Value] = [.text(messageID), Self.value(project?.uuidString), .text(level.rawValue)]
        return try await database.transaction { database in
            let rows = try database.run("""
                UPDATE mail_messages SET \(Self.explanationForProject), project = ?2, level = ?3, reasons = '[]', waits = 0, moved_by_user = 1
                WHERE message_id = ?1 AND (?2 IS NULL OR ?2 IN (SELECT id FROM mail_projects))
                RETURNING id
                """, parameters)
            try Self.dropVersionsWithoutExplanation(rows, in: database)
            return !rows.isEmpty
        }
    }

    /// Keeps the moves of one kind to a project as given, and says whether it did. Nothing
    /// is kept for a project that no longer exists.
    @discardableResult
    func saveTally(_ tally: SortingService.Tally, rule: SortingCandidate.Rule, project: UUID) async throws -> Bool {
        let rule = Project.Rule(rule)
        let rows = try await database.run("""
            INSERT INTO mail_tallies (project, kind, value, count, last)
            SELECT ?1, ?2, ?3, ?4, ?5 WHERE ?1 IN (SELECT id FROM mail_projects)
            ON CONFLICT (project, kind, value) DO UPDATE SET count = excluded.count, last = excluded.last
            RETURNING project
            """, [
                .text(project.uuidString), .text(rule.kind.rawValue), .text(rule.value),
                .integer(Int64(tally.count)), .real(tally.last.timeIntervalSince1970),
            ])
        return !rows.isEmpty
    }

    /// The store's part of SortingService.Lookups. The app gives the projects, the user, the
    /// file names and the full text scores. A failed read is logged with its code and reads
    /// as nothing found.
    @MainActor
    func sortingLookups(
        projects: @escaping () async -> [SortingCandidate],
        owner: @escaping () async -> SortingService.Owner,
        fileNames: @escaping (UUID) async -> [String],
        scores: @escaping @Sendable (String) async -> [UUID: Double]
    ) -> SortingService.Lookups {
        SortingService.Lookups(
            projects: projects,
            owner: owner,
            fileNames: fileNames,
            filed: { id in await logged("reading a filed email", nil) { try await filed(id) } },
            peopleSeen: { addresses in await logged("reading people seen", [:]) { try await peopleSeen(addresses) } },
            thread: { email in await logged("reading a thread", []) { try await thread(of: email) } },
            scores: scores,
            waiting: { await logged("reading waiting emails", []) { try await waiting() } },
            tally: { rule, project in await logged("reading a count of moves", nil) { try await tally(rule, project: project) } }
        )
    }

    /// The saves of SortingService. A failed write is logged with its code, and a decision
    /// then counts as not saved.
    @MainActor
    func sortingSaves() -> SortingService.Saves {
        SortingService.Saves(
            decision: { id, decision in await logged("saving a decision", false) { try await saveDecision(decision, for: id) } },
            reply: { id, reply in await logged("saving a reply mark", ()) { try await saveReply(reply, for: id) } },
            move: { id, project in _ = await logged("saving a move", false) { try await move(id, to: project) } },
            tally: { rule, project, tally in _ = await logged("saving a count of moves", false) { try await saveTally(tally, rule: rule, project: project) } }
        )
    }

    // MARK: Explaining

    /// An email as the explanation reads it, or nil when the store does not hold it. Its
    /// text is empty once Retention removed it.
    func explainEmail(_ messageID: String) async throws -> ExplainService.Email? {
        try await database.transaction { database in
            try Self.rows(where: "message_id = ?", [.text(messageID)], in: database).first?.explainEmail
        }
    }

    /// The other messages of the email's thread with their own text, oldest first, at most
    /// `maximumThreadMessages`, those nearest the email. A message whose text Retention
    /// removed comes with an empty one.
    func threadMail(of email: ExplainService.Email) async throws -> [ExplainPrompt.Mail] {
        try await database.transaction { database in
            guard let root = try Self.storedRoot(of: email.messageID, in: database) else { return [] }
            return try Self.rows(
                where: "thread_root = ? AND message_id != ? ORDER BY abs(date - ?), id LIMIT ?",
                [.text(root), .text(email.messageID), .real(email.date.timeIntervalSince1970), .integer(Int64(Self.maximumThreadMessages))],
                in: database
            )
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            .map(\.promptMail)
        }
    }

    /// The project's other mail that shares the most words with the query, best first, then
    /// the newest, at most `query.limit`. Mail without a shared word, or without its text,
    /// is left out, as in phase 0.
    ///
    /// Splitting and comparing the words of every email of the project runs off the
    /// database's actor, see `rankedIDs`, so other reads and writes wait only for the two
    /// reads.
    func projectMail(_ query: ExplainService.MailQuery) async throws -> [ExplainPrompt.Mail] {
        guard query.limit > 0 else { return [] }
        let words = await Self.queryWords(in: query.text)
        guard !words.isEmpty else { return [] }
        let candidates = try await database.run(
            "SELECT id, message_id, words, date FROM mail_messages WHERE project = ? AND text IS NOT NULL AND words IS NOT NULL",
            [.text(query.project.uuidString)]
        )
        let ids = await Self.rankedIDs(candidates, words: words, excluding: query.excluding, limit: query.limit)
        return try await projectMail(ids: ids, in: query.project)
    }

    /// The emails of `ids` in that order that are still in `project`. An email that is
    /// gone, that moved to another project or to Needs a Project, or whose text Retention
    /// removed, since `rankedIDs` chose it is left out. Internal for tests.
    func projectMail(ids: [Int64], in project: UUID) async throws -> [ExplainPrompt.Mail] {
        guard !ids.isEmpty else { return [] }
        return try await database.transaction { database in
            let rows = try Self.rows(
                where: "id IN (SELECT value FROM json_each(?)) AND project = ? AND text IS NOT NULL",
                [.text(try Self.json(ids)), .text(project.uuidString)],
                in: database
            )
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0]?.promptMail }
        }
    }

    /// The words of an explain query that count for project mail: those longer than one
    /// character. Off the main actor and the database's, since the tokenizer reads long
    /// text.
    @concurrent
    private static func queryWords(in text: String) async -> Set<String> {
        Set(ChunkSearch.words(in: text).filter { $0.count > 1 })
    }

    /// The ids of the rows (id, Message-ID, words, date) that share the most `words`, then
    /// the newest, then the highest id, at most `limit`. A row without a shared word, or
    /// with a Message-ID in `excluding`, is left out. Off the main actor and the
    /// database's, since it splits the words of every email of a project. Internal for
    /// tests.
    @concurrent
    static func rankedIDs(_ rows: [[ProjectsDatabase.Value]], words: Set<String>, excluding: Set<String>, limit: Int) async -> [Int64] {
        rows.compactMap { row -> (id: Int64, shared: Int, date: Double)? in
            guard row.count == 4, let id = row[0].integer, let messageID = row[1].text, !excluding.contains(messageID),
                  let stored = row[2].text, let date = row[3].real else { return nil }
            let shared = words.intersection(stored.split(separator: "\n").map(String.init)).count
            return shared > 0 ? (id, shared, date) : nil
        }
        .sorted { ($0.shared, $0.date, $0.id) > ($1.shared, $1.date, $1.id) }
        .prefix(max(limit, 0))
        .map(\.id)
    }

    /// For ExplainService.Known, from the mail the user sent dated before the email:
    /// everyone the user wrote to, as To or Cc, each address once with the first name it
    /// came with, and the text of that mail, oldest first, at most the newest
    /// `maximumSentTexts`.
    ///
    /// Only the user's own mail counts. A stranger's earlier email never makes its sender
    /// or anyone it names known, so a second email from a lookalike address keeps its
    /// warnings. Mail forged as from the user's own address is not told apart here.
    /// SenderChecks gives such mail no warning either.
    ///
    /// Both are empty, and the texts nil, when the user's addresses are not known or the
    /// store holds no mail from them, since Orra then does not read the user's sent mail.
    func correspondence(before email: ExplainService.Email, ownAddresses: [String]) async throws -> (correspondents: [SenderChecks.Person], sentTexts: [String]?) {
        let own = Set(ownAddresses.compactMap(ProjectsAddress.normalized))
        guard !own.isEmpty else { return ([], nil) }
        let parameters: [ProjectsDatabase.Value] = [.real(email.date.timeIntervalSince1970), .text(email.messageID), .text(try Self.json(own.sorted()))]
        return try await database.transaction { database in
            let readsSentMail = try !database.run(
                "SELECT 1 FROM mail_messages WHERE sender_key IN (SELECT value FROM json_each(?)) LIMIT 1", [parameters[2]]).isEmpty
            guard readsSentMail else { return ([], nil) }
            let sentBefore = "m.date < ?1 AND m.message_id != ?2 AND m.sender_key IN (SELECT value FROM json_each(?3))"
            var seen: Set<String> = []
            var people: [SenderChecks.Person] = []
            for row in try database.run("""
                SELECT p.name, p.key FROM mail_people p JOIN mail_messages m ON m.id = p.message
                WHERE \(sentBefore) AND p.role IN ('to', 'cc') AND p.key IS NOT NULL
                ORDER BY m.date, m.id, CASE p.role WHEN 'to' THEN 0 ELSE 1 END, p.position
                """, parameters) where row.count == 2 {
                guard let name = row[0].text, let address = row[1].text, !own.contains(address), seen.insert(address).inserted else { continue }
                people.append(SenderChecks.Person(name: name, address: address))
            }
            let sent = try database.run("""
                SELECT text FROM (
                    SELECT substr(m.text, 1, ?4) AS text, m.date, m.id FROM mail_messages m
                    WHERE \(sentBefore) AND m.text IS NOT NULL ORDER BY m.date DESC, m.id DESC LIMIT ?5
                ) ORDER BY date, id
                """, parameters + [.integer(Int64(Self.readLength)), .integer(Int64(Self.maximumSentTexts))]).compactMap { $0.first?.text }
            return (people, sent)
        }
    }

    /// Saves the email's latest explanation in place of the one before, and adds its
    /// warnings to the email's. A new explanation starts the draft again, so the versions of
    /// the draft before go. Says whether it saved: nothing is saved for an email the store
    /// does not hold, or one that moved to another project while it was explained.
    @discardableResult
    func save(_ explanation: Explanation, at now: Date) async throws -> Bool {
        let data = try JSONEncoder().encode(explanation)
        return try await database.transaction { database in
            let hasDraft: Bool = if case .checked = explanation.draft { true } else { false }
            let kinds = explanation.warningKinds
            guard let row = try database.run(
                "SELECT id, warnings FROM mail_messages WHERE message_id = ? AND project IS ?",
                [.text(explanation.messageID), Self.value(explanation.project?.uuidString)]).first,
                  row.count == 2, let id = row[0].integer else { return false }
            let before = Self.decoded([ProjectsWarning].self, row[1]) ?? []
            let warnings = ProjectsWarning.allCases.filter { before.contains($0) || kinds.contains($0) }
            try database.run("""
                UPDATE mail_messages SET explanation = ?2, explained = ?3, explanation_draft = ?4,
                    draft_changed = CASE WHEN ?4 = 1 THEN ?3 ELSE NULL END, warnings = ?5
                WHERE id = ?1
                """, [.integer(id), .blob(data), .real(now.timeIntervalSince1970), .integer(hasDraft ? 1 : 0), .text(try Self.json(warnings))])
            try database.run("DELETE FROM mail_draft_versions WHERE message = ?", [.integer(id)])
            return true
        }
    }

    /// The email's latest explanation, or nil when there is none, Retention removed it, or
    /// it was written by an Orra whose explanations read differently.
    func explanation(for messageID: String) async throws -> Explanation? {
        try await database.transaction { database in
            guard let value = try database.run("SELECT explanation FROM mail_messages WHERE message_id = ?", [.text(messageID)]).first?.first else { return nil }
            return Self.decoded(Explanation.self, value)
        }
    }

    // MARK: Drafts

    /// Adds a version of the email's draft and returns its number. Returns nil and saves
    /// nothing when the store does not hold the email, or when its explanation, which holds
    /// the first draft, is gone or newer than the revision: a revision that ends after the
    /// email was explained again, moved or forgotten never lands on the new draft.
    /// - Parameters:
    ///   - started: when the revision started, from the clock that `now` reads.
    @discardableResult
    func save(_ version: ReviseService.Version, startedAt started: Date, at now: Date) async throws -> Int? {
        let data = try JSONEncoder().encode(version)
        return try await database.transaction { database in
            guard let number = try database.run("""
                INSERT INTO mail_draft_versions (message, number, made, version)
                SELECT m.id, COALESCE((SELECT MAX(v.number) FROM mail_draft_versions v WHERE v.message = m.id), 0) + 1, ?2, ?3
                FROM mail_messages m WHERE m.message_id = ?1 AND m.explained <= ?4
                RETURNING number
                """, [.text(version.messageID), .real(now.timeIntervalSince1970), .blob(data), .real(started.timeIntervalSince1970)]
            ).first?.first?.integer else { return nil }
            try database.run("UPDATE mail_messages SET draft_changed = ? WHERE message_id = ?", [.real(now.timeIntervalSince1970), .text(version.messageID)])
            return Int(number)
        }
    }

    /// The versions of the email's draft, oldest first. A version written by an Orra whose
    /// versions read differently is left out.
    func versions(of messageID: String) async throws -> [DraftVersion] {
        try await database.transaction { database in
            try database.run("""
                SELECT v.number, v.made, v.version FROM mail_draft_versions v JOIN mail_messages m ON m.id = v.message
                WHERE m.message_id = ? ORDER BY v.number
                """, [.text(messageID)]).compactMap { row in
                guard row.count == 3, let number = row[0].integer, let made = row[1].real,
                      let version = Self.decoded(ReviseService.Version.self, row[2]) else { return nil }
                return DraftVersion(number: Int(number), made: Date(timeIntervalSince1970: made), version: version)
            }
        }
    }

    /// Removes the newest version of the email's draft, for undo, and says whether there
    /// was one.
    @discardableResult
    func removeNewestVersion(of messageID: String, at now: Date) async throws -> Bool {
        try await database.transaction { database in
            let removed = try database.run("""
                DELETE FROM mail_draft_versions
                WHERE message = (SELECT id FROM mail_messages WHERE message_id = ?1)
                    AND number = (SELECT MAX(v.number) FROM mail_draft_versions v JOIN mail_messages m ON m.id = v.message WHERE m.message_id = ?1)
                RETURNING number
                """, [.text(messageID)])
            guard !removed.isEmpty else { return false }
            try database.run("UPDATE mail_messages SET draft_changed = ? WHERE message_id = ?", [.real(now.timeIntervalSince1970), .text(messageID)])
            return true
        }
    }

    /// The explanation's save closure. A failed write is logged with its code.
    func explanationSave(now: @escaping @Sendable () -> Date = Date.init) -> @Sendable (Explanation) async -> Void {
        { explanation in await logged("saving an explanation", ()) { _ = try await save(explanation, at: now()) } }
    }

    /// ReviseService's save closure for one revision, which the window makes when the
    /// revision starts, with `started` read from `now`. A failed write is logged with its
    /// code.
    func versionSave(startedAt started: Date, now: @escaping @Sendable () -> Date = Date.init) -> @Sendable (ReviseService.Version) async -> Void {
        { version in await logged("saving a draft version", ()) { _ = try await save(version, startedAt: started, at: now()) } }
    }

    // MARK: The window

    /// The emails of a list, newest first, at most `limit`.
    func list(_ place: Place, limit: Int = 1_000) async throws -> [Listed] {
        let condition: String
        var parameters: [ProjectsDatabase.Value] = []
        switch place {
        case .project(let id):
            condition = "project = ?"
            parameters = [.text(id.uuidString)]
        case .needsProject:
            condition = "project IS NULL AND (level IS NULL OR level = 'unsure')"
        case .setAside:
            condition = "level = 'setAside'"
        }
        parameters.append(.integer(Int64(max(0, limit))))
        let values = parameters
        return try await database.transaction { database in
            try Self.rows(where: "\(condition) ORDER BY date DESC, id DESC LIMIT ?", values, people: false, textLength: Self.summaryReadLength, in: database)
                .map(\.listed)
        }
    }

    /// How many emails wait for a reply, for the menu.
    func replyDueCount() async throws -> Int {
        Int(try await database.run("SELECT COUNT(*) FROM mail_messages WHERE reply LIKE 'reply-%'").first?.first?.integer ?? 0)
    }

    /// The emails the store holds and the files the index holds text for, for the
    /// diagnostic report.
    func counts() async throws -> (emails: Int, files: Int) {
        try await database.transaction { database in
            let emails = try database.run("SELECT COUNT(*) FROM mail_messages").first?.first?.integer ?? 0
            let files = try database.run("SELECT COUNT(*) FROM index_files WHERE skip IS NULL").first?.first?.integer ?? 0
            return (Int(emails), Int(files))
        }
    }

    /// The first sentence of an email's own text, for the line under the subject: its first
    /// line with text, up to the end of its first sentence, at most `summaryLength`
    /// characters, with the spaces in it collapsed.
    static func firstSentence(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        var sentence = ""
        var characters = line.prefix(summaryLength).makeIterator()
        var next = characters.next()
        while let character = next {
            sentence.append(character)
            next = characters.next()
            // A full stop ends a sentence only before a space or the end, so 3.5 m does not.
            if "。！？!?".contains(character) || (character == "." && (next == nil || next == " ")) {
                break
            }
        }
        return sentence
    }

    // MARK: Rows

    /// An email as the store holds it.
    private nonisolated struct Row: Sendable {
        var id: Int64
        var messageID: String
        var mailbox: String?
        var date: Date
        var sender: Person
        var subject: String
        var inReplyTo: [String]
        var references: [String]
        var list: ListMail
        var attachments: [Attachment]
        var hiddenText: [ProjectsHiddenText]
        var warnings: [ProjectsWarning]
        var project: UUID?
        var level: SortingLevel?
        var reasons: [SortingReason]
        var movedByUser: Bool
        var reply: ReplyRule.Decision?
        var text: String?
        var visibleText: String?
        var isExplained: Bool
        /// The text of the explanation's first point, nil without one.
        var firstPoint: String?
        /// The To, Cc and Reply-To, by their role.
        var people: [String: [Person]] = [:]

        var to: [Person] { people["to"] ?? [] }
        var cc: [Person] { people["cc"] ?? [] }
        var replyTo: [Person] { people["replyTo"] ?? [] }

        var sortingEmail: SortingService.Email {
            SortingService.Email(
                messageID: messageID, sender: sender.address, recipients: (to + cc).map(\.address),
                date: date, subject: subject, text: text ?? "", attachmentNames: attachments.map(\.name),
                mailbox: mailbox, inReplyTo: inReplyTo, references: references, list: list)
        }

        var explainEmail: ExplainService.Email {
            ExplainService.Email(
                messageID: messageID, date: date, sender: MailStore.promptPerson(sender),
                replyTo: replyTo.map(MailStore.promptPerson), to: to.map(MailStore.promptPerson), cc: cc.map(MailStore.promptPerson),
                subject: subject, attachments: attachments.map { ContentChecks.Input.Attachment(name: $0.name, type: $0.type) },
                text: text ?? "", visibleText: visibleText ?? "", hiddenText: hiddenText, list: list, project: project)
        }

        var promptMail: ExplainPrompt.Mail {
            ExplainPrompt.Mail(
                messageID: messageID, date: date, sender: MailStore.promptPerson(sender),
                to: to.map(MailStore.promptPerson), cc: cc.map(MailStore.promptPerson), subject: subject,
                attachmentNames: attachments.map(\.name), text: text ?? "")
        }

        var listed: Listed {
            let point = firstPoint.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
            return Listed(
                messageID: messageID, date: date, sender: sender, subject: subject, project: project,
                level: level, reasons: reasons, movedByUser: movedByUser, reply: reply, warnings: warnings,
                isExplained: isExplained, hasText: text != nil,
                summary: point.isEmpty ? MailStore.firstSentence(text ?? "") : String(point.prefix(MailStore.summaryLength)))
        }
    }

    /// The columns of a Row, with the text and the visible text read `textLength` far.
    private static func rowColumns(textLength: Int) -> String {
        """
        id, message_id, mailbox, date, sender_name, sender, subject, in_reply_to, refs, list_id, list_unsubscribe, \
        precedence, attachments, hidden_text, warnings, project, level, reasons, moved_by_user, reply, \
        substr(text, 1, \(textLength)), substr(visible_text, 1, \(textLength)), explanation IS NOT NULL, \
        CASE WHEN json_valid(CAST(explanation AS TEXT)) THEN json_extract(CAST(explanation AS TEXT), '$.points[0].text') END
        """
    }

    /// The rows that meet `condition`, which may end in ORDER BY and LIMIT, with their
    /// people unless `people` is false, and their text and visible text read `textLength`
    /// far.
    private static func rows(
        where condition: String,
        _ parameters: [ProjectsDatabase.Value] = [],
        people: Bool = true,
        textLength: Int = readLength,
        in database: isolated ProjectsDatabase
    ) throws -> [Row] {
        var rows = try database.run("SELECT \(rowColumns(textLength: textLength)) FROM mail_messages WHERE \(condition)", parameters).compactMap(row)
        guard people, !rows.isEmpty else { return rows }
        var byMessage: [Int64: [String: [Person]]] = [:]
        for person in try database.run(
            "SELECT message, role, name, address FROM mail_people WHERE message IN (SELECT value FROM json_each(?)) AND role != 'from' ORDER BY message, role, position",
            [.text(try json(rows.map(\.id)))]) where person.count == 4 {
            guard let message = person[0].integer, let role = person[1].text, let name = person[2].text, let address = person[3].text else { continue }
            byMessage[message, default: [:]][role, default: []].append(Person(name: name, address: address))
        }
        for index in rows.indices {
            rows[index].people = byMessage[rows[index].id] ?? [:]
        }
        return rows
    }

    private static func row(_ values: [ProjectsDatabase.Value]) -> Row? {
        guard values.count == 24, let id = values[0].integer, let messageID = values[1].text, let date = values[3].real,
              let senderName = values[4].text, let sender = values[5].text, let subject = values[6].text else { return nil }
        return Row(
            id: id,
            messageID: messageID,
            mailbox: values[2].text,
            date: Date(timeIntervalSince1970: date),
            sender: Person(name: senderName, address: sender),
            subject: subject,
            inReplyTo: decoded([String].self, values[7]) ?? [],
            references: decoded([String].self, values[8]) ?? [],
            list: ListMail(listID: values[9].text, listUnsubscribe: values[10].text, precedence: values[11].text),
            attachments: decoded([Attachment].self, values[12]) ?? [],
            hiddenText: (decoded([String].self, values[13]) ?? []).compactMap(ProjectsHiddenText.init(rawValue:)),
            warnings: (decoded([String].self, values[14]) ?? []).compactMap(ProjectsWarning.init(rawValue:)),
            project: values[15].text.flatMap(UUID.init(uuidString:)),
            level: values[16].text.flatMap(SortingLevel.init(rawValue:)),
            reasons: (decoded([String].self, values[17]) ?? []).compactMap(SortingReason.init(rawValue:)),
            movedByUser: values[18].integer == 1,
            reply: values[19].text.flatMap(reply),
            text: values[20].text,
            visibleText: values[21].text,
            isExplained: values[22].integer == 1,
            firstPoint: values[23].text
        )
    }

    private static func insert(_ message: Message, root: String, words: String, at now: Date, in database: isolated ProjectsDatabase) throws {
        guard let id = try database.run("""
            INSERT INTO mail_messages (
                message_id, mailbox, date, saved, sender_name, sender, sender_key, subject, subject_key, thread_root,
                in_reply_to, refs, list_id, list_unsubscribe, precedence, attachments, hidden_text, warnings,
                text, visible_text, words)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
            RETURNING id
            """, [
                .text(message.messageID),
                value(message.mailbox),
                .real(message.date.timeIntervalSince1970),
                .real(now.timeIntervalSince1970),
                .text(message.sender.name),
                .text(message.sender.address),
                value(ProjectsAddress.normalized(message.sender.address)),
                .text(message.subject),
                .text(MailThreads.subjectKey(message.subject).key),
                .text(root),
                .text(try json(message.inReplyTo)),
                .text(try json(message.references)),
                value(message.list.listID),
                value(message.list.listUnsubscribe),
                value(message.list.precedence),
                .text(try json(message.attachments)),
                .text(try json(message.hiddenText.map(\.rawValue))),
                .text(try json(ProjectsWarning.allCases.filter(message.warnings.contains).map(\.rawValue))),
                .text(message.text),
                .text(message.visibleText),
                .text(words),
            ]).first?.first?.integer else { return }
        let people: [(role: String, people: [Person])] = [
            ("from", [message.sender]), ("to", message.to), ("cc", message.cc), ("replyTo", message.replyTo),
        ]
        for (role, group) in people {
            for (position, person) in group.enumerated() {
                try database.run(
                    "INSERT INTO mail_people (message, role, position, name, address, key) VALUES (?, ?, ?, ?, ?, ?)",
                    [.integer(id), .text(role), .integer(Int64(position)), .text(person.name), .text(person.address),
                     value(ProjectsAddress.normalized(person.address))])
            }
        }
    }

    // MARK: Threads

    private static func root(of message: Message, own: Set<String>, in database: isolated ProjectsDatabase) throws -> String {
        let people = ([message.sender] + message.to + message.cc).compactMap { ProjectsAddress.normalized($0.address) }
        let threading = MailThreads.Message(
            messageID: message.messageID, inReplyTo: message.inReplyTo, references: message.references,
            subject: message.subject, people: Set(people), date: message.date)
        return try root(of: threading, own: own, in: database)
    }

    /// The root of the thread by MailThreads, reading the emails the store holds.
    private static func root(of message: MailThreads.Message, own: Set<String>, in database: isolated ProjectsDatabase) throws -> String {
        var failure: (any Error)?
        let root = MailThreads.root(
            of: message,
            ownAddresses: own,
            known: { id in
                do {
                    return try known(id, in: database)
                } catch {
                    failure = error
                    return nil
                }
            },
            sameSubject: { key in
                do {
                    return try sameSubject(key, near: message.date, in: database)
                } catch {
                    failure = error
                    return []
                }
            })
        if let failure { throw failure }
        return root
    }

    private static func storedRoot(of messageID: String, in database: isolated ProjectsDatabase) throws -> String? {
        try database.run("SELECT thread_root FROM mail_messages WHERE message_id = ?", [.text(messageID)]).first?.first?.text
    }

    private static func known(_ messageID: String, in database: isolated ProjectsDatabase) throws -> MailThreads.Known? {
        guard let row = try database.run(
            "SELECT id, thread_root, subject_key, date FROM mail_messages WHERE message_id = ?", [.text(messageID)]).first else { return nil }
        return try threadEntry(messageID: messageID, row: row, in: database)
    }

    private static func sameSubject(_ key: String, near date: Date, in database: isolated ProjectsDatabase) throws -> [MailThreads.Known] {
        let rows = try database.run("""
            SELECT id, thread_root, subject_key, date, message_id FROM mail_messages
            WHERE subject_key = ? AND date BETWEEN ? AND ? ORDER BY date DESC, id DESC LIMIT ?
            """, [
                .text(key),
                .real(date.addingTimeInterval(-MailThreads.subjectWindow).timeIntervalSince1970),
                .real(date.addingTimeInterval(MailThreads.subjectWindow).timeIntervalSince1970),
                .integer(Int64(maximumSubjectMatches)),
            ])
        return try rows.compactMap { row in
            guard row.count == 5, let messageID = row[4].text else { return nil }
            return try threadEntry(messageID: messageID, row: row, in: database)
        }
    }

    private static func threadEntry(messageID: String, row: [ProjectsDatabase.Value], in database: isolated ProjectsDatabase) throws -> MailThreads.Known? {
        guard row.count >= 4, let id = row[0].integer, let root = row[1].text, let key = row[2].text, let date = row[3].real else { return nil }
        let people = try database.run(
            "SELECT key FROM mail_people WHERE message = ? AND key IS NOT NULL AND role IN ('from', 'to', 'cc')",
            [.integer(id)]).compactMap { $0.first?.text }
        return MailThreads.Known(messageID: messageID, root: root, subjectKey: key, people: Set(people), date: Date(timeIntervalSince1970: date))
    }

    // MARK: Gone mail

    /// The key of a Message-ID in mail_gone: its SHA-256 in hex, so the store never keeps
    /// the ID of an email it removed, which often holds a host or an address.
    static func goneKey(_ messageID: String) -> String {
        SHA256.hash(data: Data(messageID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes the emails that meet `condition`, with their people and drafts, and keeps
    /// their Message-IDs as gone until `Retention.goneIDs` after Orra read them, so the scan
    /// never reads them again. Returns how many it deleted.
    static func deleteGone(where condition: String, _ parameters: [ProjectsDatabase.Value], in database: isolated ProjectsDatabase) throws -> Int {
        let rows = try database.run("SELECT message_id, saved FROM mail_messages WHERE \(condition)", parameters)
        for row in rows where row.count == 2 {
            guard let messageID = row[0].text, let saved = row[1].real else { continue }
            try database.run("""
                INSERT INTO mail_gone (id_hash, until) VALUES (?1, ?2)
                ON CONFLICT (id_hash) DO UPDATE SET until = max(until, excluded.until)
                """, [.text(goneKey(messageID)), .real(saved + Retention.goneIDs)])
        }
        return try database.run("DELETE FROM mail_messages WHERE \(condition) RETURNING id", parameters).count
    }

    // MARK: Values

    /// The reply mark in the store: the reason for no reply, or reply- and the language.
    static func code(_ reply: ReplyRule.Decision) -> String {
        switch reply {
        case .noReply(let reason): reason.rawValue
        case .reply(let language): "reply-" + language.rawValue
        }
    }

    static func reply(_ code: String) -> ReplyRule.Decision? {
        if code.hasPrefix("reply-") {
            return ProjectsLanguage(rawValue: String(code.dropFirst("reply-".count))).map(ReplyRule.Decision.reply)
        }
        return ReplyRule.NoReplyReason(rawValue: code).map(ReplyRule.Decision.noReply)
    }

    private static func promptPerson(_ person: Person) -> ExplainPrompt.Person {
        ExplainPrompt.Person(name: person.name, address: person.address)
    }

    /// The text without what PromptHygiene takes out, for the words that find an email, so
    /// hidden lines never steer which mail the explanation reads.
    private static func cleaned(_ text: String) -> String {
        PromptHygiene.withoutMarkers(PromptHygiene(text, source: .mail).text)
    }

    private static func value(_ text: String?) -> ProjectsDatabase.Value {
        text.map(ProjectsDatabase.Value.text) ?? .null
    }

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ value: ProjectsDatabase.Value) -> T? {
        let data: Data
        switch value {
        case .text(let text): data = Data(text.utf8)
        case .blob(let blob): data = blob
        default: return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Runs `body`, and on a failure logs what failed with the error's code and gives
    /// `fallback`.
    private func logged<T>(_ action: StaticString, _ fallback: T, _ body: () async throws -> T) async -> T {
        do {
            return try await body()
        } catch {
            Self.log(error, action)
            return fallback
        }
    }

    static func log(_ error: any Error, _ action: StaticString) {
        let action = "\(action)"
        if let failure = error as? ProjectsDatabase.Failure {
            Logger.projects.error("Mail store: \(action, privacy: .public) failed at \(failure.step.rawValue, privacy: .public) with \(failure.code, privacy: .public)")
        } else {
            let error = error as NSError
            Logger.projects.error("Mail store: \(action, privacy: .public) failed with \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        }
    }
}
