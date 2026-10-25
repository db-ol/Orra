import Foundation
import Observation
import os

/// A project the user set up, as projects.json keeps it. Sorting and the explanation read it
/// through `candidate` and `forExplanation`.
nonisolated struct Project: Sendable, Equatable, Identifiable, Codable {
    /// A person the user listed for the project, with a role in the user's own words.
    nonisolated struct Person: Sendable, Equatable, Codable {
        var name: String
        var address: String
        var role: String = ""
    }

    /// A rule the user made, which files mail on its own, see SortingCandidate.Rule. Kept in
    /// a form of its own, so projects.json does not change when the sorting types do.
    nonisolated struct Rule: Sendable, Hashable, Codable {
        nonisolated enum Kind: String, Sendable, Codable, CaseIterable {
            case sender
            case domain
            case list
            case subjectCode
        }

        var kind: Kind
        var value: String

        init(kind: Kind, value: String) {
            self.kind = kind
            self.value = value
        }

        init(_ rule: SortingCandidate.Rule) {
            switch rule {
            case .sender(let value): self.init(kind: .sender, value: value)
            case .domain(let value): self.init(kind: .domain, value: value)
            case .list(let value): self.init(kind: .list, value: value)
            case .subjectCode(let value): self.init(kind: .subjectCode, value: value)
            }
        }

        /// The rule as sorting reads it.
        var sorting: SortingCandidate.Rule {
            switch kind {
            case .sender: .sender(value)
            case .domain: .domain(value)
            case .list: .list(value)
            case .subjectCode: .subjectCode(value)
            }
        }
    }

    var id: UUID
    var name: String
    /// What the user wrote about the project.
    var description = ""
    /// The project's folders as plain bookmarks, without a security scope since Orra has no
    /// sandbox, so a folder the user moves or renames is still found. See `bookmark(of:)`.
    var folders: [Data] = []
    var people: [Person] = []
    /// Domains whose mail belongs to the project, such as harbor.example.
    var domains: [String] = []
    var rules: [Rule] = []
    /// The Mail mailboxes linked to the project, in the form of `SortingInput.mailbox`.
    var mailboxes: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        folders: [Data] = [],
        people: [Person] = [],
        domains: [String] = [],
        rules: [Rule] = [],
        mailboxes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.folders = folders
        self.people = people
        self.domains = domains
        self.rules = rules
        self.mailboxes = mailboxes
    }

    /// The project as sorting reads it. SortingService adds the people seen and the file
    /// names.
    var candidate: SortingCandidate {
        SortingCandidate(
            id: id,
            name: name,
            description: description,
            people: people.map { SortingCandidate.Person(name: $0.name, address: $0.address) },
            domains: domains,
            rules: rules.map(\.sorting),
            mailboxes: mailboxes
        )
    }

    /// The project as the explanation reads it.
    var forExplanation: ExplainService.Project {
        ExplainService.Project(
            id: id,
            name: name,
            description: description,
            people: people.map { ExplainPrompt.Person(name: $0.name, address: $0.address, role: $0.role) },
            domains: domains
        )
    }

    /// A plain bookmark of a folder the user added, for `folders`. It reads the folder's
    /// own metadata only, never what is inside.
    static func bookmark(of folder: URL) throws -> Data {
        try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folders are now, in the order of `folders`. A bookmark that no longer
    /// finds its folder is left out. It never shows a window and never mounts a volume.
    /// It reads the disk on a thread of its own: a folder on a share that hangs can hold
    /// that thread for long, and a thread that Swift tasks share would hold up their other
    /// work, such as the dictation's.
    static func resolve(_ bookmarks: [Data]) async -> [URL] {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: resolveNow(bookmarks))
            }
            thread.name = "Orra project folders"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func resolveNow(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { bookmark in
            var isStale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale)
        }
    }
}

/// The user's projects, kept in projects.json in the Projects folder (plan section 2.4),
/// which backups include, unlike the database in its Index folder.
///
/// - The file is written whole and atomically, for the user alone (0600) in a folder for
///   the user alone (0700). Writes run off the main actor, one at a time and in the order
///   the changes came, so the file always ends with the last change.
/// - A file that cannot be read, or one from a newer Orra, is never written over: every
///   change then fails until it loads.
/// - Adding a project registers it in the mail store first, so sorting may file mail in
///   it. Forget Project removes the project's mail, drafts and counts, then its index, then
///   the project itself, see `forget(_:mail:index:)`.
/// - `close()` comes before Delete All Projects Data, so no write brings projects.json back.
/// - It also keeps the suggestions of Suggested Projects the user dismissed, by a hash of
///   each, so they do not come back, see ProjectSuggestions.dismissalKey(_:).
///
/// Logs counts and error codes only, never a name.
@Observable
final class ProjectList {
    nonisolated enum Failure: Error, Equatable {
        /// projects.json comes from a newer Orra. It stays as it is.
        case newerFormat
        /// The list was not loaded, so nothing is written over the file.
        case notLoaded
        /// The list was closed before its data was deleted.
        case closed
        /// No project in the list has this ID.
        case unknownProject
    }

    /// The file's name in the Projects folder.
    nonisolated static let fileName = "projects.json"
    /// The most dismissed suggestions kept. A newer one takes the place of the oldest.
    nonisolated static let maximumDismissedSuggestions = 500
    /// The form of the file this Orra writes. A file with a higher one is refused.
    nonisolated static let formatVersion = 1

    /// The projects, in the order the user added them.
    private(set) var projects: [Project] = []
    /// The keys of the suggestions the user dismissed, oldest first.
    private(set) var dismissedSuggestions: [String] = []
    /// Whether the file was read, or found missing, so changes may be written.
    private(set) var isLoaded = false
    @ObservationIgnored let storage: ProjectsStorage
    @ObservationIgnored private var isClosed = false
    /// The write under way or the last one, which the next one waits for.
    @ObservationIgnored private var lastWrite: Task<Void, any Error>?

    init(storage: ProjectsStorage = .live) {
        self.storage = storage
    }

    /// projects.json.
    var file: URL {
        Self.file(in: storage)
    }

    /// The project with this ID.
    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Reads projects.json. A missing file is an empty list.
    func load() async throws {
        guard !isClosed else { throw Failure.closed }
        do {
            let stored = try await Self.read(Self.file(in: storage))
            projects = stored.projects
            dismissedSuggestions = stored.dismissedSuggestions ?? []
            isLoaded = true
            Logger.projects.notice("Projects: loaded \(self.projects.count, privacy: .public) projects")
        } catch {
            Logger.projects.error("Projects: the project list could not be read: \(Self.logName(error), privacy: .public)")
            throw error
        }
    }

    /// Adds a project and saves the list. It is registered in the mail store first, so mail
    /// can be filed in it from the moment sorting sees it. When the list cannot be saved,
    /// the project leaves the list again, so nothing is filed in a project that the next
    /// start would not know.
    func add(_ project: Project, mail: MailStore) async throws {
        try checkWritable()
        guard self.project(project.id) == nil else { return try await update(project) }
        try await mail.add(project: project.id)
        try checkWritable()
        projects.append(project)
        do {
            try await save()
        } catch {
            projects.removeAll { $0.id == project.id }
            throw error
        }
    }

    /// Changes a project in the list and saves it. When the list cannot be saved, the
    /// project is as it was, unless a later change came meanwhile.
    func update(_ project: Project) async throws {
        try checkWritable()
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw Failure.unknownProject }
        let before = projects[index]
        projects[index] = project
        do {
            try await save()
        } catch {
            if let index = projects.firstIndex(where: { $0.id == project.id }), projects[index] == project {
                projects[index] = before
            }
            throw error
        }
    }

    /// Forget Project: removes everything Projects keeps for the project. Its mail, drafts
    /// and counts go first, in one write after which nothing can be filed in it, then its
    /// index of files, then the project in projects.json. A step that fails leaves the
    /// project in the list, so the user can try again.
    func forget(_ id: UUID, mail: MailStore, index: FolderIndex) async throws {
        try checkWritable()
        guard project(id) != nil else { throw Failure.unknownProject }
        try await mail.forget(project: id)
        try await index.forget(project: id)
        try checkWritable()
        guard let position = projects.firstIndex(where: { $0.id == id }) else { throw Failure.unknownProject }
        let forgotten = projects.remove(at: position)
        do {
            try await save()
        } catch {
            if project(id) == nil {
                projects.insert(forgotten, at: min(position, projects.count))
            }
            throw error
        }
        Logger.projects.notice("Projects: forgot a project, \(self.projects.count, privacy: .public) left")
    }

    /// Makes the database agree with the list when Projects starts: every project in the list
    /// is registered in the mail store, and the data of projects the list no longer holds is
    /// removed, such as after projects.json came back from a backup.
    func reconcile(mail: MailStore, index: FolderIndex) async throws {
        try checkWritable()
        let gone = try await mail.keep(projects: Set(projects.map(\.id)))
        for id in gone.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await index.forget(project: id)
        }
        if !gone.isEmpty {
            Logger.projects.notice("Projects: removed the data of \(gone.count, privacy: .public) projects no longer in the list")
        }
    }

    /// Keeps a suggestion the user dismissed, by its key, and saves the list. When the list
    /// cannot be saved, the suggestion is not kept.
    func dismissSuggestion(_ key: String) async throws {
        try checkWritable()
        guard !dismissedSuggestions.contains(key) else { return }
        dismissedSuggestions.append(key)
        if dismissedSuggestions.count > Self.maximumDismissedSuggestions {
            dismissedSuggestions.removeFirst(dismissedSuggestions.count - Self.maximumDismissedSuggestions)
        }
        do {
            try await save()
        } catch {
            dismissedSuggestions.removeAll { $0 == key }
            throw error
        }
    }

    /// Waits for the writes under way and refuses every later change, before Delete All
    /// Projects Data, so projects.json is not written again once it is deleted.
    func close() async {
        isClosed = true
        _ = await lastWrite?.result
        projects = []
        dismissedSuggestions = []
        isLoaded = false
    }

    // MARK: The file

    /// What projects.json holds. A file from before Suggested Projects has no dismissed
    /// suggestions, and an older Orra reads the file without them.
    private nonisolated struct Stored: Codable {
        var version: Int
        var projects: [Project]
        var dismissedSuggestions: [String]?
    }

    /// The form of projects.json alone.
    private nonisolated struct StoredVersion: Decodable {
        var version: Int
    }

    private func checkWritable() throws {
        guard !isClosed else { throw Failure.closed }
        guard isLoaded else { throw Failure.notLoaded }
    }

    /// Writes the list as it is now, after the writes before it.
    private func save() async throws {
        let data = try Self.encoded(Stored(version: Self.formatVersion, projects: projects, dismissedSuggestions: dismissedSuggestions))
        let previous = lastWrite
        let storage = storage
        let write = Task {
            _ = await previous?.result
            try await Self.write(data, in: storage)
        }
        lastWrite = write
        do {
            try await write.value
        } catch {
            Logger.projects.error("Projects: the project list could not be saved: \(Self.logName(error), privacy: .public)")
            throw error
        }
    }

    private nonisolated static func file(in storage: ProjectsStorage) -> URL {
        storage.folder.appendingPathComponent(fileName)
    }

    private nonisolated static func encoded(_ stored: Stored) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(stored)
    }

    @concurrent
    private nonisolated static func read(_ file: URL) async throws -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return Stored(version: formatVersion, projects: [])
        }
        // The version first, so a newer file is refused before its projects are read.
        guard try JSONDecoder().decode(StoredVersion.self, from: data).version <= formatVersion else { throw Failure.newerFormat }
        return try JSONDecoder().decode(Stored.self, from: data)
    }

    /// Writes the file atomically, then narrows it to the user, inside a folder only the user
    /// can open.
    @concurrent
    private nonisolated static func write(_ data: Data, in storage: ProjectsStorage) async throws {
        try storage.create()
        let file = file(in: storage)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: ProjectsStorage.filePermissions], ofItemAtPath: file.path)
    }

    /// An error for the log, by its kind and code only.
    private nonisolated static func logName(_ error: any Error) -> String {
        if let failure = error as? Failure { return "\(failure)" }
        if let failure = error as? ProjectsDatabase.Failure { return "\(failure.step.rawValue) \(failure.code)" }
        if error is DecodingError { return "unreadable" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
