import Foundation
import Observation
import os

extension Logger {
    /// The index of the project folders. Counts, times and error codes only, never a path,
    /// a file name or text.
    nonisolated static let projectsIndex = Logger(subsystem: ProblemReport.subsystem, category: "projects-index")
}

/// Keeps the text of each project's folders in the Projects database, for ChunkSearch.
///
/// - Each project is started with its folders and stopped by its UUID. One background task
///   at low priority does the work of all projects, one file at a time, and projects take
///   turns.
/// - A sweep lists the folders with FolderWalk, removes the files that are gone, and reads
///   the documents that are new or whose size or modification date changed with
///   FileTextExtractor. It cuts their text with TextChunker and keeps the chunks in two full
///   text tables, see ProjectsDatabase and ChunkSearch.
/// - Every other file the walk lists gets a row without being opened: an image waits for
///   text recognition, and any other file, such as a drawing, an archive or a video, is
///   known by its name only. Every row has a name entry, the words of the file's name and
///   of its folder in two full text tables of their own, see FileNameSearch, which stay
///   apart from the chunks.
/// - A project is swept when it starts, every hour, and at the first tick of the timer
///   (every `sweepGap`) after its folders changed (FolderEvents). So a folder that keeps
///   changing is swept at most once in that time. Renames and removals are taken in at
///   once: a rename moves a file's rows, so a moved file is not read again, and a removal
///   drops its text.
/// - It waits while a dictation is under way, before the walk, before each file and before
///   each write.
/// - A project lists at most 5,000 documents and 20,000 other files, which are the documents
///   past the 5,000, the images and the files known by name. Images take the room the
///   documents leave of the 5,000, those the index holds first, then new ones newest first,
///   and the rest are known by name. A project holds about 200 MB of text.
///   The document that passes the text limit is the last one read whose text the index did
///   not hold, and the ones after it are known by name. A file with text in the index is
///   read again when it changes, even past the limit, so its old text never stays, and it
///   never loses its text for room.
/// - A file that gives no text is kept with why and with its size and modification date,
///   so a file that took too long is not read again until it changes. Reasons that can pass
///   without a change, such as no access, are tried again at each sweep.
/// - Files that are not on this Mac, such as iCloud files or folders removed to save space,
///   keep their text in the index. Nothing inside a folder that is not on this Mac is
///   looked at, since that would download it.
/// - Folders FolderWalk refuses, such as one that holds Mail's data, are never watched.
///
/// It never writes, moves or deletes anything in the folders. Main actor state, since the
/// window shows the reports. The walk, the bookkeeping of a sweep, the reading, the chunking
/// and the database run off the main actor.
@Observable
final class FolderIndex {
    /// The limits of one project.
    nonisolated struct Limits: Sendable, Equatable {
        /// Documents the walk lists, and the images that take the room they leave. The
        /// pages recognition reads in one file are the recognizer's limit.
        var files = 5_000
        /// Files the walk lists besides the documents of `files`: documents past it, images,
        /// whether they take the room of `files` or not, and every other kind of file.
        var names = 20_000
        /// UTF-8 bytes of text.
        var textBytes: Int64 = 200_000_000
    }

    /// What the index holds for a project, for its page in the Projects window.
    nonisolated struct Report: Sendable, Equatable {
        /// Files with text in the index.
        var indexed = 0
        var chunks = 0
        /// UTF-8 bytes of text in the index.
        var textBytes: Int64 = 0
        /// Files indexed after hidden text was dropped from them.
        var hiddenText = 0
        /// Files and folders skipped without a row, by reason: those the last walk skipped,
        /// and those whose read failed for a reason that can pass, such as no access.
        var skipped: [FileSkipReason: Int] = [:]
        /// Added folders that cannot be indexed, and why.
        var refusedFolders: [URL: FolderWalk.Refusal] = [:]
        /// Whether documents or images are known by name only for lack of room.
        var reachedFileLimit = false
        var reachedTextLimit = false
        /// Whether the index works on this project now.
        var isIndexing = false
        /// Files known by name only: their text is not read or not found, such as a
        /// drawing, an archive, a locked PDF or an image without text. Files that wait for
        /// recognition are not among them.
        var nameOnly = 0
        /// Whether the folders hold more files than the index lists by name.
        var reachedNameLimit = false
    }

    /// A file that gives no text, and why.
    nonisolated struct SkippedFile: Sendable, Equatable {
        var url: URL
        var reason: FileSkipReason
        /// The modification date the file had, when the index read it.
        var modified: Date?
    }

    /// Watches folders from an event ID, hands each batch of changes to a closure, and gives
    /// back a closure that stops the watch. The app's uses FolderEvents, tests pass a stand in.
    typealias Watch = (_ folders: [URL], _ since: UInt64?, _ deliver: @escaping @Sendable (FolderEvents.Changes) -> Void) -> () -> Void

    /// Reasons a file gives no text that can pass without a change to the file. They are not
    /// kept, so the file is tried again at the next sweep.
    nonisolated static let passingSkips: Set<FileSkipReason> = [.noAccess, .dataless, .notDownloaded, .cancelled]
    /// Reasons of rows the project page only counts, since a folder may hold many such
    /// files and they are expected.
    nonisolated static let countedSkips: Set<FileSkipReason> = [.archive, .unsupportedFormat, .imageWithoutText, .overFileLimit, .waitsForRecognition]
    /// Reasons of a stored row that the next sweep reads again, unchanged as its file may be:
    /// a file past the limit of files may fit now, and a release may read a format it knew
    /// by name before.
    nonisolated static let rereadSkips: Set<FileSkipReason> = [.overFileLimit, .unsupportedFormat, .archive]
    /// How often the timer ticks. A project whose folders changed is swept at the next tick
    /// (a guess).
    nonisolated static let sweepGap: Duration = .seconds(60)
    /// Every this many ticks, every project is swept, an hour (a guess).
    nonisolated static let ticksPerFullSweep = 60
    /// How often a wait for the end of a dictation looks again.
    nonisolated static let pollInterval: Duration = .milliseconds(100)

    /// The reports of the started projects.
    private(set) var reports: [UUID: Report] = [:]

    @ObservationIgnored let database: ProjectsDatabase
    @ObservationIgnored let limits: Limits
    @ObservationIgnored private let isDictating: () -> Bool
    @ObservationIgnored private let walk: FolderWalk
    @ObservationIgnored private let readText: @Sendable (URL) async -> Result<FileTextResult, FileSkipReason>
    @ObservationIgnored private let chunker = TextChunker()
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let watch: Watch

    /// A started project.
    private struct Watched {
        var folders: [URL]
        /// Counts starts, so work for an earlier start of the same project stops.
        var generation: Int
        var sweepDue = true
        /// Changes the worker has not taken in yet.
        var pending = FolderEvents.Changes()
        /// Whether the folders changed since the last sweep began, so the next tick sweeps
        /// them.
        var changedSinceSweep = false
        var stopWatching: (() -> Void)?
        /// What the last sweep found that the database does not keep.
        var facts = SweepFacts()
    }

    private nonisolated struct SweepFacts: Sendable {
        var skipped: [FileSkipReason: Int] = [:]
        var skippedFiles: [SkippedFile] = []
        var refusedFolders: [URL: FolderWalk.Refusal] = [:]
        var reachedFileLimit = false
        var reachedTextLimit = false
        var reachedNameLimit = false
    }

    @ObservationIgnored private var projects: [UUID: Watched] = [:]
    @ObservationIgnored private var generations = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// A stopped worker that may still be finishing its file. The next worker waits for it,
    /// so only one works at a time.
    @ObservationIgnored private var stoppedWorker: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    /// The project the worker reads now.
    @ObservationIgnored private var working: UUID?
    /// The project the worker read last.
    @ObservationIgnored private var lastWorked: UUID?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Waits for the worker to leave its project, see forget(project:).
    @ObservationIgnored private var leaveWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - isDictating: true from the press of the talk key or the translation key until the
    ///     dictation is pasted or cancelled, see EngineTurns.isDictating.
    ///   - readText: reads one file, FileTextExtractor's by default. Tests pass a stand in.
    ///   - sleep: waits for a time. Tests pass one that does not.
    init(
        database: ProjectsDatabase,
        isDictating: @escaping () -> Bool,
        limits: Limits = Limits(),
        walk: FolderWalk = FolderWalk(),
        readText: @escaping @Sendable (URL) async -> Result<FileTextResult, FileSkipReason> = { await FileTextExtractor().text(of: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        watch: @escaping Watch = FolderIndex.watchWithFolderEvents
    ) {
        self.database = database
        self.isDictating = isDictating
        self.limits = limits
        self.walk = walk
        self.readText = readText
        self.sleep = sleep
        self.watch = watch
    }

    /// Stops the folder events and the worker, in case the index goes away without
    /// `stopAll()`, so nothing keeps watching the folders.
    isolated deinit {
        for watched in projects.values {
            watched.stopWatching?()
        }
        worker?.cancel()
        stoppedWorker?.cancel()
        timer?.cancel()
        wake?.finish()
    }

    // MARK: Starting and stopping

    /// Starts indexing a project's folders, or starts again with other folders. A project
    /// started with the same folders goes on as it was.
    func start(project id: UUID, folders: [URL]) {
        if let watched = projects[id], watched.folders == folders { return }
        stopWatching(id)
        generations += 1
        projects[id] = Watched(folders: folders, generation: generations)
        reports[id, default: Report()].isIndexing = true
        startWorker()
        wake?.yield()
    }

    /// Stops indexing a project. What the index holds for it stays.
    func stop(project id: UUID) {
        stopWatching(id)
        projects[id] = nil
        reports[id] = nil
        if projects.isEmpty {
            stopWorker()
        }
    }

    /// Stops every project, such as when Projects is turned off.
    func stopAll() {
        for id in projects.keys {
            stopWatching(id)
        }
        projects = [:]
        reports = [:]
        stopWorker()
    }

    /// Stops a project and removes everything the index holds for it.
    func forget(project id: UUID) async throws {
        stop(project: id)
        // A file being read for it is written before the worker sees the stop. This waits
        // for that file even when the calling task is cancelled.
        while working == id {
            await withCheckedContinuation { leaveWaiters.append($0) }
        }
        let removed = try await database.transaction { database in
            let removed = try Self.removeRows(project: id, in: database)
            try database.run("DELETE FROM index_watch WHERE project = ?", [.text(id.uuidString)])
            return removed
        }
        if removed {
            try await database.compactAfterDeletes()
        }
        Logger.projectsIndex.notice("Index forgot a project")
    }

    /// Returns once no project waits for work. Changes that wait for the next tick do not
    /// count. For tests, and for code that must see the result of a start.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Whether no project waits for work.
    var isIdle: Bool {
        working == nil && !projects.values.contains { $0.sweepDue || !$0.pending.isEmpty }
    }

    /// Sweeps the projects whose folders changed since their last sweep. The timer calls it
    /// every `sweepGap`, and tests call it in its place.
    func sweepChangedProjects() {
        for (id, watched) in projects where watched.changedSinceSweep {
            projects[id]?.sweepDue = true
        }
        wake?.yield()
    }

    // MARK: What it holds

    /// The files of a project that give no text, with why: those the index read and those
    /// the last walk skipped for a reason worth telling, at most `limit`. Reasons the page
    /// only counts, see `countedSkips`, are left out.
    func skippedFiles(project id: UUID, limit: Int = FolderWalk.maximumListedSkips) async throws -> [SkippedFile] {
        let counted = "[" + Self.countedSkips.map { "\"\($0.rawValue)\"" }.sorted().joined(separator: ",") + "]"
        let rows = try await database.run(
            "SELECT path, skip, modified FROM index_files WHERE project = ? AND skip IS NOT NULL AND skip NOT IN (SELECT value FROM json_each(?)) ORDER BY path LIMIT ?",
            [.text(id.uuidString), .text(counted), .integer(Int64(limit))])
        var files = rows.compactMap { row -> SkippedFile? in
            guard row.count == 3, let path = row[0].text, let reason = row[1].text.flatMap(FileSkipReason.init(rawValue:)) else { return nil }
            return SkippedFile(url: URL(fileURLWithPath: path), reason: reason, modified: row[2].real.map(Date.init(timeIntervalSince1970:)))
        }
        files += projects[id]?.facts.skippedFiles ?? []
        return Array(files.sorted { $0.url.path < $1.url.path }.prefix(limit))
    }

    /// The files of a project that hid text, which the index dropped.
    func filesWithHiddenText(project id: UUID) async throws -> [URL] {
        try await database.run(
            "SELECT path FROM index_files WHERE project = ? AND skip IS NULL AND hidden_runs > 0 ORDER BY path",
            [.text(id.uuidString)]
        ).compactMap { $0.first?.text.map { URL(fileURLWithPath: $0) } }
    }

    /// The names of a project's documents with text in the index, for the attachment names
    /// that sorting compares, see SortingService.Lookups.fileNames. Images are left out
    /// whatever their text, so a camera's names, such as IMG_2041, never become words of
    /// sorting.
    func fileNames(project id: UUID) async throws -> [String] {
        try await database.run(
            "SELECT path FROM index_files WHERE project = ? AND skip IS NULL ORDER BY path",
            [.text(id.uuidString)]
        ).compactMap { row in
            guard let url = row.first?.text.map({ URL(fileURLWithPath: $0) }),
                  case .text = FileTextExtractor.kind(ofExtension: url.pathExtension) else { return nil }
            return url.lastPathComponent
        }
    }

    /// A project's files with text in the index, each with its modification date and the
    /// start of its text, for FileVersions, see ExplainService.Lookups.files.
    func versionFiles(project id: UUID) async throws -> [FileVersions.File] {
        try await database.run("""
            SELECT f.path, f.modified, (SELECT c.text FROM index_chunks c WHERE c.file = f.id ORDER BY c.id LIMIT 1)
            FROM index_files f WHERE f.project = ? AND f.skip IS NULL ORDER BY f.path
            """, [.text(id.uuidString)]
        ).compactMap { row in
            guard row.count == 3, let path = row[0].text, let modified = row[1].real else { return nil }
            return FileVersions.File(url: URL(fileURLWithPath: path), modified: Date(timeIntervalSince1970: modified), head: row[2].text ?? "")
        }
    }

    // MARK: The worker

    private func startWorker() {
        guard worker == nil else { return }
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        let previous = stoppedWorker
        stoppedWorker = nil
        worker = Task(priority: .background) { [weak self] in
            await previous?.value
            for await _ in wakes {
                guard let self else { return }
                await self.work()
            }
        }
        timer = Task(priority: .background) { [weak self, sleep] in
            var ticks = 0
            while true {
                do {
                    try await sleep(Self.sweepGap)
                } catch {
                    return
                }
                ticks += 1
                guard !Task.isCancelled, let self else { return }
                if ticks.isMultiple(of: Self.ticksPerFullSweep) {
                    self.sweepAll()
                } else {
                    self.sweepChangedProjects()
                }
            }
        }
    }

    private func stopWorker() {
        worker?.cancel()
        timer?.cancel()
        wake?.finish()
        if let worker {
            stoppedWorker = worker
        }
        worker = nil
        timer = nil
        wake = nil
        // `working` stays until the stopped worker leaves its file, see forget(project:).
        resumeIdleWaiters()
    }

    private func stopWatching(_ id: UUID) {
        projects[id]?.stopWatching?()
        projects[id]?.stopWatching = nil
    }

    private func sweepAll() {
        for id in projects.keys {
            projects[id]?.sweepDue = true
        }
        wake?.yield()
    }

    private func received(_ changes: FolderEvents.Changes, project id: UUID, generation: Int) {
        guard projects[id]?.generation == generation else { return }
        projects[id]?.pending.merge(changes, limit: FolderEvents.limit)
        projects[id]?.changedSinceSweep = true
        wake?.yield()
    }

    private func isCurrent(_ id: UUID, _ generation: Int) -> Bool {
        !Task.isCancelled && projects[id]?.generation == generation
    }

    private func work() async {
        while !Task.isCancelled, let id = nextProject() {
            working = id
            await process(id)
            working = nil
            lastWorked = id
            let waiters = leaveWaiters
            leaveWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        resumeIdleWaiters()
    }

    /// The next project with work, in turn, so a project whose folders keep changing never
    /// holds back the others.
    private func nextProject() -> UUID? {
        let due = projects.filter { $0.value.sweepDue || !$0.value.pending.isEmpty }.keys.sorted { $0.uuidString < $1.uuidString }
        guard let lastWorked else { return due.first }
        return due.first { $0.uuidString > lastWorked.uuidString } ?? due.first
    }

    private func resumeIdleWaiters() {
        guard isIdle || worker == nil else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func process(_ id: UUID) async {
        guard var watched = projects[id] else { return }
        let generation = watched.generation
        let changes = watched.pending
        let sweepDue = watched.sweepDue
        watched.pending = FolderEvents.Changes()
        watched.sweepDue = false
        if sweepDue {
            watched.changedSinceSweep = false
        }
        projects[id] = watched
        reports[id]?.isIndexing = true
        do {
            await waitWhileDictating()
            var removedText = false
            if isCurrent(id, generation) {
                if watched.stopWatching == nil {
                    try await startWatching(id, generation: generation)
                }
                removedText = try await apply(changes, project: id)
            }
            if sweepDue, isCurrent(id, generation), try await sweep(id, generation: generation) {
                removedText = true
            }
            await waitWhileDictating()
            if removedText {
                try await database.compactAfterDeletes()
            }
            if changes.lastEventID > 0, isCurrent(id, generation) {
                try await storeLastEvent(changes.lastEventID, project: id)
            }
        } catch let failure as ProjectsDatabase.Failure {
            Logger.projectsIndex.error("Index failed at \(failure.step.rawValue, privacy: .public) with SQLite error \(failure.code, privacy: .public)")
        } catch {
            Logger.projectsIndex.error("Index failed with error \((error as NSError).code, privacy: .public)")
        }
        let next = projects[id]
        await refreshReport(id, generation: generation, isIndexing: next?.sweepDue == true || next?.pending.isEmpty == false)
    }

    /// Starts watching the folders before the first sweep, so nothing that changes during it
    /// is missed, from the last event the index took in. A folder FolderWalk refuses, such as
    /// one that holds Mail's data or the home folder, is never watched. A missing one is, so
    /// its files are seen once it appears.
    private func startWatching(_ id: UUID, generation: Int) async throws {
        guard let folders = projects[id]?.folders else { return }
        var watchable: [URL] = []
        for folder in folders {
            let refusal = await walk.refusal(for: folder)
            if refusal == nil || refusal == .notAFolder {
                watchable.append(folder)
            }
        }
        let rows = try await database.run("SELECT last_event FROM index_watch WHERE project = ?", [.text(id.uuidString)])
        guard isCurrent(id, generation) else { return }
        guard !watchable.isEmpty else {
            projects[id]?.stopWatching = {}
            return
        }
        let since = rows.first?.first?.integer.map { UInt64(bitPattern: $0) }
        let deliver: @Sendable (FolderEvents.Changes) -> Void = { [weak self] changes in
            Task { @MainActor in
                self?.received(changes, project: id, generation: generation)
            }
        }
        projects[id]?.stopWatching = watch(watchable, since, deliver)
    }

    private func storeLastEvent(_ event: UInt64, project id: UUID) async throws {
        try await database.run(
            "INSERT INTO index_watch (project, last_event) VALUES (?, ?) ON CONFLICT (project) DO UPDATE SET last_event = excluded.last_event",
            [.text(id.uuidString), .integer(Int64(bitPattern: event))])
    }

    /// Moves the rows of renamed files and removes the rows of removed ones. Returns whether
    /// text was removed.
    private func apply(_ changes: FolderEvents.Changes, project id: UUID) async throws -> Bool {
        guard !changes.renamed.isEmpty || !changes.removed.isEmpty else { return false }
        return try await database.transaction { database in
            var removed = false
            for rename in changes.renamed {
                removed = try Self.applyRename(rename, project: id, in: database) || removed
            }
            for path in changes.removed {
                removed = try Self.removeRows(project: id, under: path, in: database) || removed
            }
            return removed
        }
    }

    // MARK: Sweeping

    /// A file the database holds, as the last sweep left it.
    private nonisolated struct Stored: Sendable {
        var size: Int64
        var modified: Double
        var textBytes: Int64
        /// The raw value of why the row holds no text, nil when it holds the file's text.
        var skip: String?

        /// Whether the row is of the file as the walk found it.
        func matches(_ file: FolderWalk.File) -> Bool {
            size == file.size && modified == file.modified.timeIntervalSince1970
        }

        /// Whether a sweep writes the row again even when its file did not change, see
        /// `FolderIndex.rereadSkips`.
        var mustBeWritten: Bool {
            skip.flatMap(FileSkipReason.init(rawValue:)).map(FolderIndex.rereadSkips.contains) ?? false
        }
    }

    /// A row a sweep writes without reading its file: a file known by name, or an image
    /// that waits for recognition.
    private nonisolated struct Unread: Sendable {
        var file: FolderWalk.File
        var skip: FileSkipReason
    }

    /// What a sweep must do, found off the main actor.
    private nonisolated struct Survey: Sendable {
        var facts = SweepFacts()
        var listed = 0
        /// The files the database holds that are gone, by path.
        var gone: [String] = []
        /// The rows to write without reading their files.
        var unread: [Unread] = []
        /// The documents to read: first those with text in the database, then those it
        /// holds without text, then new ones.
        var changed: [FolderWalk.File] = []
        /// The text bytes the database holds for the changed files with text, by path.
        var storedBytes: [String: Int64] = [:]
        /// The documents the database holds by name as past the limit, unchanged, which the
        /// text limit may hold back again without writing them again.
        var namedPastLimit: Set<String> = []
        /// The text bytes of the files the database holds that stay as they are.
        var keptBytes: Int64 = 0
        /// The real paths of the added folders, which give the folders of the names.
        var roots: [String] = []
    }

    /// The rows a sweep writes in one transaction when it writes them without reading.
    nonisolated static let rowsPerWrite = 200

    /// Lists the folders, removes the files that are gone, writes the files known by name
    /// and the images that wait for recognition, and reads the new and changed documents.
    /// Then it writes the name entries that rows lack. Returns whether text was removed.
    private func sweep(_ id: UUID, generation: Int) async throws -> Bool {
        guard let folders = projects[id]?.folders else { return false }
        let started = ContinuousClock.now
        await waitWhileDictating()
        guard isCurrent(id, generation),
              let survey = try await Self.survey(project: id, folders: folders, limits: limits, walk: walk, database: database),
              isCurrent(id, generation)
        else { return false }
        var facts = survey.facts
        var removedText = false
        if !survey.gone.isEmpty {
            await waitWhileDictating()
            guard isCurrent(id, generation) else { return false }
            removedText = try await database.transaction { [gone = survey.gone] database in
                var removed = false
                for path in gone {
                    removed = try Self.removeRows(project: id, path: path, in: database) || removed
                }
                return removed
            }
        }

        // The rows without a read go first, so every file can be found by its name while the
        // documents are read.
        let unread = try await writeUnread(survey.unread, project: id, generation: generation)
        var written = unread.written
        var waiting = unread.waiting
        removedText = removedText || unread.removed

        var textBytes = survey.keptBytes
        var read = 0
        var skipped = 0
        var heldBack: [Unread] = []
        for (offset, file) in survey.changed.enumerated() {
            guard isCurrent(id, generation) else { break }
            let holdsText = survey.storedBytes[file.url.path] != nil
            // The limit holds back the documents whose text the index does not hold, so a
            // changed file never keeps its old text. Those after it come last in the list,
            // and are known by name.
            if !holdsText, textBytes >= limits.textBytes {
                facts.reachedTextLimit = true
                heldBack = survey.changed[offset...].filter { !survey.namedPastLimit.contains($0.url.path) }
                    .map { Unread(file: $0, skip: .overFileLimit) }
                break
            }
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            let result = await readText(file.url)
            if case .failure(.cancelled) = result { break }
            let prepared = await Self.prepare(result, file: file, project: id, chunker: chunker)
            if case .failure = result {
                skipped += 1
            }
            if prepared.skip == .waitsForRecognition {
                waiting += 1
            }
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            let removed: Bool
            if let skip = prepared.skip, Self.passingSkips.contains(skip) {
                facts.skipped[skip, default: 0] += 1
                if facts.skippedFiles.count < FolderWalk.maximumListedSkips {
                    facts.skippedFiles.append(SkippedFile(url: file.url, reason: skip, modified: file.modified))
                }
                removed = try await database.transaction { database in
                    try Self.removeRows(project: id, path: prepared.path, in: database)
                }
            } else {
                removed = try await database.transaction { database in
                    try Self.store(prepared, in: database)
                }
                textBytes += prepared.textBytes
            }
            removedText = removedText || removed
            read += 1
            if read % 25 == 0 {
                await refreshReport(id, generation: generation, isIndexing: true)
            }
        }
        if !heldBack.isEmpty, isCurrent(id, generation) {
            let (count, _, removed) = try await writeUnread(heldBack, project: id, generation: generation)
            written += count
            removedText = removedText || removed
        }
        var named = 0
        if isCurrent(id, generation) {
            named = try await writeMissingNames(id, roots: survey.roots, generation: generation)
        }
        if isCurrent(id, generation) {
            projects[id]?.facts = facts
        }
        let milliseconds = started.duration(to: .now) / .milliseconds(1)
        Logger.projectsIndex.notice(
            "Index sweep: \(survey.listed, privacy: .public) files listed, \(read, privacy: .public) read, \(skipped, privacy: .public) without text, \(written, privacy: .public) written without a read, \(waiting, privacy: .public) wait for recognition, \(named, privacy: .public) names added, \(survey.gone.count, privacy: .public) removed, in \(Int(milliseconds), privacy: .public) ms")
        return removedText
    }

    /// Writes rows without reading their files, in transactions of `rowsPerWrite`, and
    /// returns how many it wrote, how many of them wait for recognition, and whether text
    /// was removed.
    private func writeUnread(_ unread: [Unread], project id: UUID, generation: Int) async throws -> (written: Int, waiting: Int, removed: Bool) {
        var written = 0
        var waiting = 0
        var removedText = false
        for start in stride(from: 0, to: unread.count, by: Self.rowsPerWrite) {
            let batch = Array(unread[start..<min(start + Self.rowsPerWrite, unread.count)])
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            let rows = await Self.prepare(batch, project: id)
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            let removed = try await database.transaction { database in
                try rows.reduce(false) { removed, row in try Self.store(row, in: database) || removed }
            }
            removedText = removedText || removed
            written += batch.count
            waiting += batch.count { $0.skip == .waitsForRecognition }
            await refreshReport(id, generation: generation, isIndexing: true)
        }
        return (written, waiting, removedText)
    }

    /// Walks the folders and compares what they hold with what the database holds. Nil when
    /// the walk was cut short, since it would remove what it did not reach.
    @concurrent
    private nonisolated static func survey(
        project id: UUID, folders: [URL], limits: Limits, walk: FolderWalk, database: ProjectsDatabase
    ) async throws -> Survey? {
        var survey = Survey()
        var listed: [(path: String, file: FolderWalk.File)] = []
        var paths = Set<String>()
        var documents = 0
        var names = 0
        for folder in folders {
            guard documents < limits.files || names < limits.names else {
                survey.facts.reachedFileLimit = true
                survey.facts.reachedNameLimit = true
                break
            }
            let listing: FolderWalk.Listing
            do {
                listing = try await walk.list(folder, documents: max(0, limits.files - documents), names: max(0, limits.names - names))
            } catch {
                survey.facts.refusedFolders[folder] = error
                continue
            }
            guard !listing.wasCancelled else { return nil }
            survey.roots.append(listing.folder.path)
            for file in listing.files {
                let path = file.url.path
                guard paths.insert(path).inserted else { continue }
                listed.append((path, file))
                if case .text = file.kind {
                    documents += 1
                } else {
                    names += 1
                }
            }
            survey.facts.skipped.merge(listing.skipCounts, uniquingKeysWith: +)
            for skip in listing.skipped where survey.facts.skippedFiles.count < FolderWalk.maximumListedSkips {
                survey.facts.skippedFiles.append(SkippedFile(url: skip.url, reason: skip.reason))
            }
            survey.facts.reachedFileLimit = survey.facts.reachedFileLimit || listing.reachedLimit
            survey.facts.reachedNameLimit = survey.facts.reachedNameLimit || listing.reachedNameLimit
        }
        survey.listed = listed.count

        let rows = try await database.run(
            "SELECT path, size, modified, text_bytes, skip FROM index_files WHERE project = ?", [.text(id.uuidString)])
        var stored: [String: Stored] = [:]
        for row in rows where row.count == 5 {
            guard let path = row[0].text, let size = row[1].integer, let modified = row[2].real else { continue }
            stored[path] = Stored(size: size, modified: modified, textBytes: row[3].integer ?? 0, skip: row[4].text)
        }
        var away = AwayFromThisMac(roots: survey.roots, walk: walk)
        for (path, row) in stored where !paths.contains(path) {
            if away.holds(path) {
                survey.keptBytes += row.textBytes
            } else {
                survey.gone.append(path)
            }
        }
        survey.gone.sort()

        var withoutText: [FolderWalk.File] = []
        var new: [FolderWalk.File] = []
        var images: [(path: String, file: FolderWalk.File)] = []
        func document(_ path: String, _ file: FolderWalk.File) {
            guard let row = stored[path] else {
                new.append(file)
                return
            }
            if row.matches(file), !row.mustBeWritten {
                survey.keptBytes += row.textBytes
            } else if row.skip == nil {
                survey.changed.append(file)
                survey.storedBytes[path] = row.textBytes
            } else {
                withoutText.append(file)
                if row.matches(file), row.skip == FileSkipReason.overFileLimit.rawValue {
                    survey.namedPastLimit.insert(path)
                }
            }
        }
        func name(_ path: String, _ file: FolderWalk.File, _ reason: FileSkipReason) {
            if let row = stored[path], row.matches(file), row.skip == reason.rawValue { return }
            survey.unread.append(Unread(file: file, skip: reason))
        }
        func image(_ path: String, _ file: FolderWalk.File) {
            if let row = stored[path], row.matches(file), !row.mustBeWritten {
                survey.keptBytes += row.textBytes
            } else {
                survey.unread.append(Unread(file: file, skip: .waitsForRecognition))
            }
        }
        for (path, file) in listed {
            switch file.kind {
            case .text:
                document(path, file)
            case .nameOnly(.overFileLimit) where stored[path].map({ $0.skip == nil }) == true:
                // A document with text never loses it for room, as a changed file is read
                // past the text limit.
                document(path, file)
            case .image:
                images.append((path, file))
            case .nameOnly(let reason):
                name(path, file, reason)
            }
        }
        // Images take the room the documents leave: those the database holds first, those
        // with text whatever the room, then new ones, newest first. The rest are known by
        // name.
        let newestFirst = { (images: [(path: String, file: FolderWalk.File)]) in
            images.sorted { $0.file.modified != $1.file.modified ? $0.file.modified > $1.file.modified : $0.path < $1.path }
        }
        let held = images.filter { stored[$0.path].map { !$0.mustBeWritten } ?? false }
        let withText = held.filter { stored[$0.path]?.skip == nil }
        let heldPaths = Set(held.map(\.path))
        var room = max(0, limits.files - documents) - withText.count
        for (path, file) in withText {
            image(path, file)
        }
        for (path, file) in newestFirst(held.filter { stored[$0.path]?.skip != nil }) + newestFirst(images.filter { !heldPaths.contains($0.path) }) {
            if room > 0 {
                room -= 1
                image(path, file)
            } else {
                survey.facts.reachedFileLimit = true
                name(path, file, .overFileLimit)
            }
        }
        survey.changed += withoutText + new
        return survey
    }

    /// Tells whether a file the walk did not list is only away from this Mac, so its text
    /// stays: it or a folder above it, up to its added folder, is dataless, or it is an
    /// iCloud file that is not downloaded. It looks at the folders from the added one down
    /// and stops at the first dataless one, since looking inside it would download it.
    private nonisolated struct AwayFromThisMac {
        private nonisolated enum Place {
            case present
            case dataless
            case missing
        }

        /// The added folders, by their real paths.
        let roots: [String]
        let walk: FolderWalk
        private var folders: [String: Place] = [:]

        init(roots: [String], walk: FolderWalk) {
            self.roots = roots
            self.walk = walk
        }

        mutating func holds(_ path: String) -> Bool {
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return false }
            var folder = root
            var above = [root]
            for part in path.dropFirst(root.count + 1).split(separator: "/").dropLast() {
                folder += "/" + part
                above.append(folder)
            }
            for folder in above {
                let place = folders[folder] ?? look(at: folder)
                folders[folder] = place
                switch place {
                case .present: continue
                case .dataless: return true
                case .missing: return false
                }
            }
            switch look(at: path) {
            case .dataless: return true
            case .missing: return false
            case .present: return !walk.isDownloaded(URL(fileURLWithPath: path))
            }
        }

        private func look(at path: String) -> Place {
            guard let flags = walk.flags(path) else { return .missing }
            return flags & UInt32(SF_DATALESS) != 0 ? .dataless : .present
        }
    }

    private func waitWhileDictating() async {
        while isDictating() && !Task.isCancelled {
            try? await sleep(Self.pollInterval)
        }
    }

    private func refreshReport(_ id: UUID, generation: Int, isIndexing: Bool) async {
        guard let totals = try? await database.run("""
                SELECT sum(CASE WHEN skip IS NULL THEN 1 ELSE 0 END), sum(CASE WHEN skip IS NULL AND hidden_runs > 0 THEN 1 ELSE 0 END),
                sum(chunks), sum(text_bytes), sum(CASE WHEN skip IS NOT NULL AND skip != ?2 THEN 1 ELSE 0 END)
                FROM index_files WHERE project = ?1
                """, [.text(id.uuidString), .text(FileSkipReason.waitsForRecognition.rawValue)]).first,
              let watched = projects[id], watched.generation == generation, totals.count == 5 else { return }
        reports[id] = Report(
            indexed: Int(totals[0].integer ?? 0), chunks: Int(totals[2].integer ?? 0), textBytes: totals[3].integer ?? 0,
            hiddenText: Int(totals[1].integer ?? 0), skipped: watched.facts.skipped, refusedFolders: watched.facts.refusedFolders,
            reachedFileLimit: watched.facts.reachedFileLimit, reachedTextLimit: watched.facts.reachedTextLimit,
            isIndexing: isIndexing, nameOnly: Int(totals[4].integer ?? 0), reachedNameLimit: watched.facts.reachedNameLimit)
    }

    /// Writes the name entries that rows lack, those of an index from before names and
    /// those of files a rename moved, with the folders the added folders' real paths give.
    /// A row under none of them keeps none. Returns how many it wrote.
    private func writeMissingNames(_ id: UUID, roots: [String], generation: Int) async throws -> Int {
        let rows = try await database.run(
            "SELECT id, path FROM index_files WHERE project = ? AND folder IS NULL ORDER BY id", [.text(id.uuidString)])
        let missing = rows.compactMap { row -> Missing? in
            guard row.count == 2, let id = row[0].integer, let path = row[1].text else { return nil }
            return Missing(row: id, path: path)
        }
        var written = 0
        for start in stride(from: 0, to: missing.count, by: Self.rowsPerWrite) {
            let batch = Array(missing[start..<min(start + Self.rowsPerWrite, missing.count)])
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            let named = await Self.names(of: batch, roots: roots)
            await waitWhileDictating()
            guard isCurrent(id, generation) else { break }
            written += try await database.transaction { database in
                var count = 0
                for found in named {
                    // Only a row that still lacks its entry, in case the row changed meanwhile.
                    guard try !database.run("SELECT 1 FROM index_files WHERE id = ? AND folder IS NULL", [.integer(found.row)]).isEmpty else { continue }
                    try database.run("UPDATE index_files SET folder = ? WHERE id = ?", [.text(found.folder), .integer(found.row)])
                    try Self.writeName(found.entry, row: found.row, in: database)
                    count += 1
                }
                return count
            }
        }
        return written
    }

    /// A row without a name entry.
    private nonisolated struct Missing: Sendable {
        var row: Int64
        var path: String
    }

    /// A row's folder inside its added folder and its name entry.
    private nonisolated struct Named: Sendable {
        var row: Int64
        var folder: String
        var entry: NameEntry
    }

    /// The folders and name entries of rows, from the real paths of the added folders. Off
    /// the main actor, since NLTokenizer takes a while.
    @concurrent
    private nonisolated static func names(of rows: [Missing], roots: [String]) async -> [Named] {
        let roots = roots.sorted { $0.count > $1.count }
        var entries = NameEntries()
        return rows.compactMap { missing in
            guard let root = roots.first(where: { missing.path.hasPrefix($0 + "/") }) else { return nil }
            let folder = (String(missing.path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
            return Named(row: missing.row, folder: folder, entry: entries.entry(path: missing.path, folder: folder))
        }
    }

    // MARK: Rows

    /// A file ready to be written: its chunks with their words and trigram text, or why it
    /// gives no text, and its name entry.
    private nonisolated struct Prepared: Sendable {
        nonisolated struct Chunk: Sendable {
            var page: Int?
            var heading: String?
            var modified: Date
            var text: String
            var words: String
            /// Nil for a chunk without Chinese characters, which the trigram table leaves out.
            var trigramText: String?
            var sheet: String?
            var recognized: Bool
        }

        var project: UUID
        var path: String
        /// Its folder inside its added folder, "" at the top.
        var folder: String
        var size: Int64
        var modified: Date
        var skip: FileSkipReason?
        /// Whether pages of the file, or the image, wait for recognition.
        var recognize = false
        var name = NameEntry()
        /// The file name as the chunk tables hold it.
        var nameWords = ""
        var nameTrigramText = ""
        var hiddenRuns = 0
        var textBytes: Int64 = 0
        var chunks: [Chunk] = []

        init(project: UUID, file: FolderWalk.File, skip: FileSkipReason?) {
            self.project = project
            path = file.url.path
            folder = file.folder
            size = file.size
            modified = file.modified
            self.skip = skip
        }
    }

    /// A file's name entry: the words of its name, with its extension as one more word, and
    /// the words of its folder, as index_file_names holds them, and the same text for
    /// index_file_name_trigrams when either holds a Chinese character.
    private nonisolated struct NameEntry: Sendable, Equatable {
        var name = ""
        var folder = ""
        var trigramName: String?
        var trigramFolder: String?
    }

    /// Makes name entries, keeping the words of each folder it saw, since many files share
    /// one.
    private nonisolated struct NameEntries {
        private var folders: [String: (words: String, trigrams: String?)] = [:]

        mutating func entry(path: String, folder: String) -> NameEntry {
            let file = URL(fileURLWithPath: path)
            let name = FolderIndex.searchableName(file)
            let folderWords: (words: String, trigrams: String?)
            if let known = folders[folder] {
                folderWords = known
            } else {
                let text = FolderIndex.searchableText(folder.replacingOccurrences(of: "/", with: " "))
                folderWords = (ChunkSearch.indexedWords(text), ChunkSearch.hasChinese(text) ? ChunkSearch.indexedTrigramText(text) : nil)
                folders[folder] = folderWords
            }
            var entry = NameEntry(name: ChunkSearch.indexedWords(name), folder: folderWords.words)
            let fileExtension = ChunkSearch.indexedWords(file.pathExtension)
            if !fileExtension.isEmpty {
                entry.name += entry.name.isEmpty ? fileExtension : " " + fileExtension
            }
            if ChunkSearch.hasChinese(name) || folderWords.trigrams != nil {
                entry.trigramName = ChunkSearch.indexedTrigramText(name)
                entry.trigramFolder = folderWords.trigrams ?? ChunkSearch.indexedTrigramText(FolderIndex.searchableText(folder))
            }
            return entry
        }
    }

    /// Makes a file ready to be written from what its read gave: its chunks and their words,
    /// or why it gives no text. A PDF with no text but with pages a scan may hold waits for
    /// recognition. The heading counts as words of each chunk under it, and the file name as
    /// words of each chunk of the file, since they say what it is about.
    @concurrent
    private nonisolated static func prepare(
        _ result: Result<FileTextResult, FileSkipReason>, file: FolderWalk.File, project: UUID, chunker: TextChunker
    ) async -> Prepared {
        var entries = NameEntries()
        let text: FileTextResult
        switch result {
        case .success(let read):
            text = read
        case .failure(let reason):
            var prepared = Prepared(project: project, file: file, skip: reason)
            prepared.name = entries.entry(path: prepared.path, folder: file.folder)
            return prepared
        }
        let skip: FileSkipReason? = text.pages.isEmpty ? (text.pagesWithoutText.isEmpty ? .noText : .waitsForRecognition) : nil
        var prepared = Prepared(project: project, file: file, skip: skip)
        prepared.recognize = !text.pagesWithoutText.isEmpty
        prepared.name = entries.entry(path: prepared.path, folder: file.folder)
        prepared.hiddenRuns = text.hiddenRuns
        prepared.textBytes = text.pages.reduce(0) { $0 + Int64($1.text.utf8.count) }
        let name = searchableName(file.url)
        prepared.nameWords = ChunkSearch.indexedWords(name)
        prepared.nameTrigramText = ChunkSearch.indexedTrigramText(name)
        prepared.chunks = chunker.chunks(of: text, file: file.url).map { chunk in
            var searchable = chunk.text
            if let heading = chunk.heading, !chunk.text.hasPrefix(heading) {
                searchable = heading + "\n" + searchable
            }
            return Prepared.Chunk(
                page: chunk.page, heading: chunk.heading, modified: chunk.modified, text: chunk.text,
                words: ChunkSearch.indexedWords(searchable),
                trigramText: ChunkSearch.hasChinese(chunk.text) ? ChunkSearch.indexedTrigramText(searchable) : nil,
                sheet: chunk.sheet, recognized: chunk.recognized == true)
        }
        return prepared
    }

    /// Makes rows ready to be written without a read: files known by name, and images that
    /// wait for recognition.
    @concurrent
    private nonisolated static func prepare(_ rows: [Unread], project: UUID) async -> [Prepared] {
        var entries = NameEntries()
        return rows.map { row in
            var prepared = Prepared(project: project, file: row.file, skip: row.skip)
            prepared.recognize = row.skip == .waitsForRecognition
            prepared.name = entries.entry(path: prepared.path, folder: row.file.folder)
            return prepared
        }
    }

    /// A file's name without its extension, with hyphens and underscores as spaces.
    nonisolated static func searchableName(_ file: URL) -> String {
        searchableText(file.deletingPathExtension().lastPathComponent)
    }

    /// A text with hyphens and underscores as spaces, as names and folders are searched.
    nonisolated static func searchableText(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// Writes a file in place of what the database held for its path. Returns whether text
    /// was removed.
    private static func store(_ prepared: Prepared, in database: isolated ProjectsDatabase) throws -> Bool {
        let project = Value.text(prepared.project.uuidString)
        let removed = try removeRows(project: prepared.project, path: prepared.path, in: database)
        let skip: Value = prepared.skip.map { .text($0.rawValue) } ?? .null
        try database.run(
            "INSERT INTO index_files (project, path, size, modified, skip, hidden_runs, text_bytes, chunks, folder, recognize) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [project, .text(prepared.path), .integer(prepared.size), .real(prepared.modified.timeIntervalSince1970), skip,
             .integer(Int64(prepared.hiddenRuns)), .integer(prepared.textBytes), .integer(Int64(prepared.chunks.count)),
             .text(prepared.folder), .integer(prepared.recognize ? 1 : 0)])
        let file = database.lastInsertedRow
        for chunk in prepared.chunks {
            let page: Value = chunk.page.map { .integer(Int64($0)) } ?? .null
            let heading: Value = chunk.heading.map { .text($0) } ?? .null
            let sheet: Value = chunk.sheet.map { .text($0) } ?? .null
            try database.run(
                "INSERT INTO index_chunks (file, project, page, heading, modified, text, chinese, sheet, recognized) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.integer(file), project, page, heading, .real(chunk.modified.timeIntervalSince1970), .text(chunk.text),
                 .integer(chunk.trigramText == nil ? 0 : 1), sheet, .integer(chunk.recognized ? 1 : 0)])
            let row = database.lastInsertedRow
            try database.run(
                "INSERT INTO index_chunk_words (rowid, name, words) VALUES (?, ?, ?)",
                [.integer(row), .text(prepared.nameWords), .text(chunk.words)])
            if let trigramText = chunk.trigramText {
                try database.run(
                    "INSERT INTO index_chunk_trigrams (rowid, name, text) VALUES (?, ?, ?)",
                    [.integer(row), .text(prepared.nameTrigramText), .text(trigramText)])
            }
        }
        try writeName(prepared.name, row: file, in: database)
        return removed
    }

    /// Writes the name entry of a row, in place of any it had.
    private static func writeName(_ entry: NameEntry, row: Int64, in database: isolated ProjectsDatabase) throws {
        try database.run("DELETE FROM index_file_names WHERE rowid = ?", [.integer(row)])
        try database.run("DELETE FROM index_file_name_trigrams WHERE rowid = ?", [.integer(row)])
        try database.run("INSERT INTO index_file_names (rowid, name, folder) VALUES (?, ?, ?)", [.integer(row), .text(entry.name), .text(entry.folder)])
        if let name = entry.trigramName, let folder = entry.trigramFolder {
            try database.run("INSERT INTO index_file_name_trigrams (rowid, name, folder) VALUES (?, ?, ?)", [.integer(row), .text(name), .text(folder)])
        }
    }

    private typealias Value = ProjectsDatabase.Value

    /// The condition for the file at the path in parameter `name`, or every file in the
    /// folder at that path. The range lets SQLite search the (project, path) index: a path
    /// below the folder starts with the path and "/", and "0" follows "/".
    private nonisolated static func atOrUnder(_ name: String) -> String {
        "path >= \(name) AND path < \(name) || '0' AND (path = \(name) OR substr(path, length(\(name)) + 1, 1) = '/')"
    }

    /// Removes the rows of the files that match `condition`, with the project as the first
    /// parameter: their chunks, their name entries, and the pages tried for recognition with
    /// them, see `fileTypesMigration`. Returns whether a row was removed, since each held at
    /// least a name.
    private static func removeFiles(where condition: String, _ parameters: [Value], in database: isolated ProjectsDatabase) throws -> Bool {
        let files = "SELECT id FROM index_files WHERE project = ?1 AND \(condition)"
        let count = try database.run("SELECT count(*) FROM (\(files))", parameters).first?.first?.integer ?? 0
        guard count > 0 else { return false }
        try database.run("DELETE FROM index_chunk_words WHERE rowid IN (SELECT id FROM index_chunks WHERE file IN (\(files)))", parameters)
        try database.run("DELETE FROM index_chunk_trigrams WHERE rowid IN (SELECT id FROM index_chunks WHERE file IN (\(files)))", parameters)
        try database.run("DELETE FROM index_chunks WHERE file IN (\(files))", parameters)
        try database.run("DELETE FROM index_file_names WHERE rowid IN (\(files))", parameters)
        try database.run("DELETE FROM index_file_name_trigrams WHERE rowid IN (\(files))", parameters)
        // index_recognition_pages goes with its rows, ON DELETE CASCADE.
        try database.run("DELETE FROM index_files WHERE project = ?1 AND \(condition)", parameters)
        return true
    }

    /// Removes the file at `path`. Returns whether text was removed.
    private static func removeRows(project: UUID, path: String, in database: isolated ProjectsDatabase) throws -> Bool {
        try removeFiles(where: "path = ?2", [.text(project.uuidString), .text(path)], in: database)
    }

    /// Removes the file at `path`, or every file in the folder at `path`.
    private static func removeRows(project: UUID, under path: String, in database: isolated ProjectsDatabase) throws -> Bool {
        try removeFiles(where: atOrUnder("?2"), [.text(project.uuidString), .text(path)], in: database)
    }

    /// Removes every file of a project.
    private static func removeRows(project: UUID, in database: isolated ProjectsDatabase) throws -> Bool {
        try removeFiles(where: "1", [.text(project.uuidString)], in: database)
    }

    /// Moves the rows of a renamed file, or of every file in a renamed folder. What the new
    /// place held before is replaced. A renamed file's chunks get the words of its new name.
    /// The moved rows lose their name entries, which the next sweep writes again with their
    /// new names and folders. A rename whose old place holds nothing, such as one a sweep
    /// already took in, changes nothing. Returns whether text was removed.
    private static func applyRename(_ rename: FolderEvents.Rename, project: UUID, in database: isolated ProjectsDatabase) throws -> Bool {
        let old: [Value] = [.text(project.uuidString), .text(rename.from)]
        guard try !database.run("SELECT 1 FROM index_files WHERE project = ?1 AND \(atOrUnder("?2")) LIMIT 1", old).isEmpty else { return false }
        // What the new place held goes. The moved rows lose their name entries, so text goes
        // either way.
        _ = try removeRows(project: project, under: rename.to, in: database)
        let name = searchableName(URL(fileURLWithPath: rename.to))
        let chunks = "SELECT id FROM index_chunks WHERE file IN (SELECT id FROM index_files WHERE project = ?1 AND path = ?2)"
        try database.run("UPDATE index_chunk_words SET name = ?3 WHERE rowid IN (\(chunks))", old + [.text(ChunkSearch.indexedWords(name))])
        try database.run("UPDATE index_chunk_trigrams SET name = ?3 WHERE rowid IN (\(chunks))", old + [.text(ChunkSearch.indexedTrigramText(name))])
        let moved = "SELECT id FROM index_files WHERE project = ?1 AND \(atOrUnder("?2"))"
        try database.run("DELETE FROM index_file_names WHERE rowid IN (\(moved))", old)
        try database.run("DELETE FROM index_file_name_trigrams WHERE rowid IN (\(moved))", old)
        try database.run("UPDATE index_files SET folder = NULL WHERE project = ?1 AND \(atOrUnder("?2"))", old)
        try database.run(
            "UPDATE index_files SET path = ?2 || substr(path, length(?3) + 1) WHERE project = ?1 AND \(atOrUnder("?3"))",
            [.text(project.uuidString), .text(rename.to), .text(rename.from)])
        return true
    }

    // MARK: Schema

    /// The sixth step of ProjectsDatabase.migrations: what the index needs for more kinds of
    /// files and for text recognition.
    ///
    /// - index_files gains `folder`, the file's folder inside its added folder, NULL until
    ///   its name entry is written, and `recognize`, 1 while pages of the file, or the
    ///   image, wait for recognition.
    /// - index_chunks gains `sheet`, the name of a workbook's sheet, and `recognized`, 1 for
    ///   text recognition gave.
    /// - index_file_names and index_file_name_trigrams hold one name entry for each row, with
    ///   the row's id as rowid, see NameEntry and FileNameSearch.
    /// - index_recognition_pages keeps each page recognition tried, by the file's row and
    ///   the page, 0 for an image, with the size and modification date the file had then and
    ///   the outcome: text, blank, timedOut or failed. So a file moves on past pages that
    ///   gave nothing, and a restart goes on where it stopped. A row's pages go with it.
    /// - PDFs 0.6.0 stored, with text or as holding none, wait for recognition, which looks
    ///   at their pages for ones without a text layer. Their text is not read again.
    nonisolated static let fileTypesMigration = ProjectsDatabase.Migration(version: 6, sql: """
        ALTER TABLE index_files ADD COLUMN folder TEXT;
        ALTER TABLE index_files ADD COLUMN recognize INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE index_chunks ADD COLUMN sheet TEXT;
        ALTER TABLE index_chunks ADD COLUMN recognized INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX index_files_waiting ON index_files (project, modified) WHERE recognize = 1;
        CREATE VIRTUAL TABLE index_file_names USING fts5 (name, folder, tokenize = 'unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE index_file_name_trigrams USING fts5 (name, folder, tokenize = 'trigram');
        CREATE TABLE index_recognition_pages (
            file INTEGER NOT NULL REFERENCES index_files (id) ON DELETE CASCADE,
            page INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            outcome TEXT NOT NULL,
            PRIMARY KEY (file, page)
        ) WITHOUT ROWID;
        UPDATE index_files SET recognize = 1 WHERE path LIKE '%.pdf' AND (skip IS NULL OR skip = 'noText');
        UPDATE index_files SET skip = 'waitsForRecognition' WHERE recognize = 1 AND skip = 'noText';
        """)

    // MARK: Watching

    /// Watches with FolderEvents.
    nonisolated static func watchWithFolderEvents(
        _ folders: [URL], since: UInt64?, deliver: @escaping @Sendable (FolderEvents.Changes) -> Void
    ) -> () -> Void {
        let events = FolderEvents(folders: folders.map(\.path), since: since, deliver: deliver)
        events.start()
        return { events.stop() }
    }
}
