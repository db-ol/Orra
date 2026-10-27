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
/// - Images and PDF pages without a text layer wait for text recognition, see
///   TextRecognizer, which runs only while no sweep waits: projects in turn, in each PDFs
///   first, then images, the newest first, in jobs of up to `recognitionPages` pages. Before
///   every page it waits while a dictation is under way, while Live Captions run, while a
///   request of the user runs, and it ends its pass while memory runs low, in Low Power Mode
///   and while the Mac is hot, see `RecognitionPause`. A key press or a request of the user
///   stops the page under way at once, and any other pause within `pollInterval`. Each page
///   tried is kept with the file's size and date and how it went, so blank, timed out and
///   failed pages are not tried again, a restart goes on where it stopped, and a changed
///   file starts over. Recognized text is kept like any text, marked as recognized.
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
        /// pages recognition reads in one file are the recognizer's limit, see
        /// `TextRecognizer.Limits.pagesPerFile`.
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
        /// Images and PDFs whose text recognition has pages left. None once the project
        /// reached its text limit, since recognition stops then.
        var recognitionLeft = 0
        /// Why recognition waits, when it waits for a lasting reason the page says: memory,
        /// Low Power Mode or heat. Nil while it runs or waits for a short pause.
        var recognitionPause: RecognitionPause?
    }

    /// Why text recognition waits. A dictation, Live Captions and a request of the user pass
    /// soon. The others may last, and the project page says so.
    nonisolated enum RecognitionPause: String, Sendable, Equatable, CaseIterable {
        case dictation
        case captions
        /// A request of the user in the Projects window, such as an explanation.
        case request
        /// The memory pressure of the Mac is not normal.
        case memory
        case lowPower
        /// The thermal state of the Mac is serious or critical.
        case heat

        /// Whether the pause may last, so recognition ends its pass and the project page
        /// says why it waits.
        var isLasting: Bool {
            switch self {
            case .dictation, .captions, .request: false
            case .memory, .lowPower, .heat: true
            }
        }
    }

    /// Recognizes the text of a job's pages, see TextRecognizer, asking before every page
    /// whether it may go on.
    typealias Recognize = @Sendable (RecognitionJob, _ mayGoOn: @escaping @Sendable () async -> Bool) async -> Result<RecognitionResult, FileSkipReason>

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
    /// How often a wait for the end of a dictation looks again, and how often a page under
    /// way looks whether a pause began.
    nonisolated static let pollInterval: Duration = .milliseconds(100)
    /// The most pages one job of recognition tries, after which its result is written and
    /// the index looks whether a sweep waits (a guess).
    nonisolated static let recognitionPages = 10

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
    @ObservationIgnored private let recognize: Recognize
    @ObservationIgnored private let recognitionPause: () -> RecognitionPause?

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
        /// Rows recognition leaves until the next sweep: a file it could not read for a
        /// reason that can pass, such as no access, or one that changed after the sweep.
        var recognitionSkips: Set<Int64> = []
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
    /// Whether the worker is at text recognition: a job, or a wait for a short pause.
    @ObservationIgnored private var isRecognizing = false
    /// The job of recognition under way.
    @ObservationIgnored private var recognition: RecognitionTask?
    /// The project recognition read last, so projects take turns.
    @ObservationIgnored private var lastRecognized: UUID?
    /// The lasting pause recognition waits for, which the reports show.
    @ObservationIgnored private var lastingPause: RecognitionPause?

    /// A job of recognition under way, which a key press, a request of the user, a pause or
    /// a stop of its project cancels.
    private struct RecognitionTask {
        var project: UUID
        var task: Task<Result<RecognitionResult, FileSkipReason>, Never>
        /// Whether the index cancelled it, so the pages it did not try are tried again.
        var wasInterrupted = false
    }

    /// - Parameters:
    ///   - isDictating: true from the press of the talk key or the translation key until the
    ///     dictation is pasted or cancelled, see EngineTurns.isDictating.
    ///   - readText: reads one file, FileTextExtractor's by default. Tests pass a stand in.
    ///   - recognize: recognizes the text of a job's pages, TextRecognizer's by default.
    ///     Tests pass a stand in.
    ///   - recognitionPause: why recognition waits besides a dictation, nil when it may run.
    ///     ProjectsRuntime's says, see `ProjectsRuntime.recognitionPause()`. None by default.
    ///   - sleep: waits for a time. Tests pass one that does not.
    init(
        database: ProjectsDatabase,
        isDictating: @escaping () -> Bool,
        limits: Limits = Limits(),
        walk: FolderWalk = FolderWalk(),
        readText: @escaping @Sendable (URL) async -> Result<FileTextResult, FileSkipReason> = { await FileTextExtractor().text(of: $0) },
        recognize: @escaping Recognize = { await TextRecognizer().recognize($0, mayGoOn: $1) },
        recognitionPause: @escaping () -> RecognitionPause? = { nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        watch: @escaping Watch = FolderIndex.watchWithFolderEvents
    ) {
        self.database = database
        self.isDictating = isDictating
        self.limits = limits
        self.walk = walk
        self.readText = readText
        self.recognize = recognize
        self.recognitionPause = recognitionPause
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
        recognition?.task.cancel()
        timer?.cancel()
        wake?.finish()
    }

    // MARK: Starting and stopping

    /// Starts indexing a project's folders, or starts again with other folders. A project
    /// started with the same folders goes on as it was.
    func start(project id: UUID, folders: [URL]) {
        if let watched = projects[id], watched.folders == folders { return }
        stopWatching(id)
        stopRecognition(of: id)
        generations += 1
        projects[id] = Watched(folders: folders, generation: generations)
        reports[id, default: Report()].isIndexing = true
        startWorker()
        wake?.yield()
    }

    /// Stops indexing a project. What the index holds for it stays.
    func stop(project id: UUID) {
        stopWatching(id)
        stopRecognition(of: id)
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
        // A file being read for it is written before the worker sees the stop, and the page
        // recognition reads for it stops. This waits for them even when the calling task is
        // cancelled.
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

    /// Returns once no project waits for work, text recognition included. Changes that wait
    /// for the next tick do not count, and neither does recognition that waits for a lasting
    /// pause, such as Low Power Mode. For tests, and for code that must see the result of a
    /// start.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Whether no project waits for work, text recognition included.
    var isIdle: Bool {
        working == nil && !isRecognizing && !projects.values.contains { $0.sweepDue || !$0.pending.isEmpty }
    }

    /// Stops the page recognition reads now, at the press of the talk key or the translation
    /// key and when a request of the user starts, so recognition never runs beside them. The
    /// page is read again once the pause ends.
    func interruptRecognition() {
        guard recognition != nil else { return }
        recognition?.wasInterrupted = true
        recognition?.task.cancel()
    }

    /// Sweeps the projects whose folders changed since their last sweep. The timer calls it
    /// every `sweepGap`, and tests call it in its place.
    func sweepChangedProjects() {
        for (id, watched) in projects where watched.changedSinceSweep {
            projects[id]?.sweepDue = true
        }
        lookAgainAtRecognition()
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
        recognition?.task.cancel()
        timer?.cancel()
        wake?.finish()
        if let worker {
            stoppedWorker = worker
        }
        worker = nil
        timer = nil
        wake = nil
        // A stopped worker recognizes nothing more. `working` stays until it leaves its file,
        // see forget(project:).
        isRecognizing = false
        resumeIdleWaiters()
    }

    private func stopWatching(_ id: UUID) {
        projects[id]?.stopWatching?()
        projects[id]?.stopWatching = nil
    }

    /// Cancels the job of recognition of a project that stops or starts again.
    private func stopRecognition(of id: UUID) {
        if recognition?.project == id {
            recognition?.task.cancel()
        }
    }

    private func sweepAll() {
        for id in projects.keys {
            projects[id]?.sweepDue = true
        }
        lookAgainAtRecognition()
        wake?.yield()
    }

    /// The worker looks again at a lasting pause of recognition at each tick, so the index
    /// counts as busy until it looked.
    private func lookAgainAtRecognition() {
        if lastingPause != nil, worker != nil {
            isRecognizing = true
        }
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

    /// Sweeps the projects that wait for one, and recognizes text while none does, until
    /// nothing is left to do now.
    private func work() async {
        while !Task.isCancelled {
            if let id = nextProject() {
                working = id
                await process(id)
                leave(id)
                lastWorked = id
            } else if await !recognizeNext() {
                break
            }
        }
        isRecognizing = false
        resumeIdleWaiters()
    }

    /// The worker left its project, so a forget that waits for it goes on.
    private func leave(_ id: UUID) {
        working = nil
        let waiters = leaveWaiters
        leaveWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
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
            // A sweep writes the rows of changed files again, so recognition tries the rows
            // it left once more.
            watched.recognitionSkips = []
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

    // MARK: Recognition

    /// A row that waits for recognition, as the pass found it.
    private nonisolated struct Waiting: Sendable {
        var project: UUID
        var generation: Int
        var row: Int64
        var path: String
        var size: Int64
        /// Seconds since 1970, as the row holds it.
        var modified: Double
        /// The pages tried before for this size and date of the file.
        var done: Set<Int>
    }

    /// Reasons a whole file fails recognition for, which its row keeps until the file
    /// changes. Any other reason can pass, such as no access, and the row waits for the next
    /// sweep.
    nonisolated static let recognitionFailures: Set<FileSkipReason> = [.unreadable, .tooLarge, .tooSlow, .locked]

    /// Why recognition waits now, a dictation first, nil when it may run.
    private func currentPause() -> RecognitionPause? {
        isDictating() ? .dictation : recognitionPause()
    }

    /// Whether a project waits for a sweep or for changes the worker has not taken in, which
    /// go before recognition.
    private var sweepWaits: Bool {
        projects.values.contains { $0.sweepDue || !$0.pending.isEmpty }
    }

    /// Runs the next job of text recognition, or waits while a short pause lasts. Returns
    /// false when nothing is left to do now: no file waits, the files that wait are left
    /// until the next sweep, or recognition waits for a lasting pause, which the next tick
    /// of the timer looks at again. It runs only while no sweep waits, see `work()`.
    private func recognizeNext() async -> Bool {
        isRecognizing = true
        guard !projects.isEmpty, let next = await nextRecognition() else {
            showLastingPause(nil)
            isRecognizing = false
            return false
        }
        if let pause = currentPause() {
            guard !pause.isLasting else {
                showLastingPause(pause)
                isRecognizing = false
                return false
            }
            await waitWhilePaused()
            return true
        }
        showLastingPause(nil)
        guard !sweepWaits else { return true }
        await run(next)
        return true
    }

    /// Waits while a short pause lasts, until a sweep waits or the pause turns lasting.
    private func waitWhilePaused() async {
        while let pause = currentPause(), !pause.isLasting, !sweepWaits, !projects.isEmpty, !Task.isCancelled {
            try? await sleep(Self.pollInterval)
        }
    }

    /// Shows the lasting pause recognition waits for on the reports of the projects with
    /// files left, or takes it away.
    private func showLastingPause(_ pause: RecognitionPause?) {
        guard pause != lastingPause else { return }
        lastingPause = pause
        for id in Array(reports.keys) {
            let shown = (reports[id]?.recognitionLeft ?? 0) > 0 ? pause : nil
            if reports[id]?.recognitionPause != shown {
                reports[id]?.recognitionPause = shown
            }
        }
    }

    /// The next row that waits for recognition. The projects take turns, and in a project
    /// PDFs go before images, the newest first. Rows left until the next sweep are left out,
    /// and so is a project whose text reached its limit.
    private func nextRecognition() async -> Waiting? {
        let ids = projects.keys.sorted { $0.uuidString < $1.uuidString }
        let first = lastRecognized.flatMap { last in ids.firstIndex { $0.uuidString > last.uuidString } } ?? 0
        for id in ids[first...] + ids[..<first] {
            guard let watched = projects[id] else { continue }
            do {
                if let next = try await nextRecognition(in: id, watched: watched) {
                    return next
                }
            } catch let failure as ProjectsDatabase.Failure {
                Logger.projectsIndex.error("Recognition failed at \(failure.step.rawValue, privacy: .public) with SQLite error \(failure.code, privacy: .public)")
            } catch {
                Logger.projectsIndex.error("Recognition failed with error \((error as NSError).code, privacy: .public)")
            }
        }
        return nil
    }

    private func nextRecognition(in id: UUID, watched: Watched) async throws -> Waiting? {
        let project = Value.text(id.uuidString)
        guard let row = try await database.run("""
            SELECT id, path, size, modified FROM index_files
            WHERE project = ?1 AND recognize = 1 AND id NOT IN (SELECT value FROM json_each(?2))
            ORDER BY path LIKE '%.pdf' DESC, modified DESC, id LIMIT 1
            """, [project, .text(Self.jsonArray(watched.recognitionSkips))]).first,
              row.count == 4, let file = row[0].integer, let path = row[1].text, let size = row[2].integer, let modified = row[3].real
        else { return nil }
        let textBytes = try await database.run("SELECT coalesce(sum(text_bytes), 0) FROM index_files WHERE project = ?", [project]).first?.first?.integer ?? 0
        guard textBytes < limits.textBytes else {
            // Recognition stops here, and the page says the text limit was reached once.
            if reports[id].map({ $0.recognitionLeft > 0 || !$0.reachedTextLimit }) ?? false {
                await refreshReport(id, generation: watched.generation, isIndexing: reports[id]?.isIndexing ?? false)
            }
            return nil
        }
        let done = try await database.run(
            "SELECT page FROM index_recognition_pages WHERE file = ? AND size = ? AND modified = ?",
            [.integer(file), .integer(size), .real(modified)]
        ).compactMap { $0.first?.integer.map(Int.init) }
        return Waiting(project: id, generation: watched.generation, row: file, path: path, size: size, modified: modified, done: Set(done))
    }

    /// Whether the job of a project may read its next page: no pause, no sweep waits, and
    /// the project still runs as it did.
    private func mayRecognize(_ id: UUID, generation: Int) -> Bool {
        projects[id]?.generation == generation && currentPause() == nil && !sweepWaits
    }

    /// Runs one job of recognition on a row in a task of its own, which a key press, a
    /// request of the user, a pause or a stop of the project cancels, and writes what it
    /// read.
    private func run(_ next: Waiting) async {
        let id = next.project
        guard isCurrent(id, next.generation) else { return }
        working = id
        defer {
            leave(id)
            lastRecognized = id
        }
        let kind: RecognitionJob.Kind = FileTextExtractor.kind(ofExtension: (next.path as NSString).pathExtension) == .text(.pdf) ? .pdf : .image
        let job = RecognitionJob(
            file: URL(fileURLWithPath: next.path), kind: kind, size: next.size, modified: next.modified, done: next.done,
            pages: Self.recognitionPages)
        let mayGoOn: @Sendable () async -> Bool = { [weak self] in
            await self?.mayRecognize(id, generation: next.generation) ?? false
        }
        let started = ContinuousClock.now
        let recognize = self.recognize
        let task = Task.detached(priority: .background) {
            await recognize(job, mayGoOn)
        }
        recognition = RecognitionTask(project: id, task: task)
        let watcher = watchForPauses(project: id, generation: next.generation)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        watcher.cancel()
        let wasInterrupted = recognition?.wasInterrupted ?? false
        recognition = nil
        guard isCurrent(id, next.generation) else { return }
        await store(result, of: next, job: job, wasInterrupted: wasInterrupted, started: started)
    }

    /// Cancels the job under way once a pause begins or its project stops, looking every
    /// `pollInterval`, so a page under way gives way to Live Captions or memory pressure
    /// too, not only to the press of a key and a request of the user, which cancel it at
    /// once. The time decides only how soon, so it is the clock's own.
    private func watchForPauses(project id: UUID, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                if self.currentPause() != nil || self.projects[id]?.generation != generation {
                    self.interruptRecognition()
                    return
                }
            }
        }
    }

    /// Leaves a row until the next sweep of its project.
    private func leaveUntilSweep(_ row: Int64, project id: UUID) {
        projects[id]?.recognitionSkips.insert(row)
    }

    /// Writes what a job read, once no dictation is under way, in one transaction and only
    /// while the row is still the job's file: the chunks of the recognized pages, the pages
    /// tried, its text and hidden runs, and whether pages are left. A file that failed as a
    /// whole stops waiting and keeps any text it has. A reason that can pass, a file that
    /// changed, and a job that made no progress without being stopped leave the row until
    /// the next sweep.
    private func store(
        _ result: Result<RecognitionResult, FileSkipReason>, of next: Waiting, job: RecognitionJob, wasInterrupted: Bool,
        started: ContinuousClock.Instant
    ) async {
        let id = next.project
        if wasInterrupted {
            let tried = (try? result.get())?.tried.count ?? 0
            Logger.projectsIndex.notice("Recognition gave way to a pause after \(tried, privacy: .public) pages of a file")
        }
        let read: RecognitionResult
        switch result {
        case .success(let success):
            read = success
        case .failure(let reason) where Self.recognitionFailures.contains(reason):
            await waitWhileDictating()
            guard isCurrent(id, next.generation) else { return }
            do {
                try await database.transaction { [row = next.row, size = next.size, modified = next.modified] database in
                    // A file with text keeps it, and stops waiting.
                    _ = try database.run(
                        "UPDATE index_files SET recognize = 0, skip = CASE WHEN skip IS NULL THEN NULL ELSE ? END WHERE id = ? AND size = ? AND modified = ? AND recognize = 1",
                        [.text(reason.rawValue), .integer(row), .integer(size), .real(modified)])
                }
            } catch {
                // So a database that cannot write, such as on a full disk, never makes the
                // pass read the same file again and again.
                leaveUntilSweep(next.row, project: id)
                Self.logRecognitionFailure(error)
            }
            Logger.projectsIndex.notice("Index could not recognize the text of a file: \(reason.rawValue, privacy: .public)")
            await refreshReport(id, generation: next.generation, isIndexing: reports[id]?.isIndexing ?? false)
            return
        case .failure(let reason):
            leaveUntilSweep(next.row, project: id)
            projects[id]?.facts.skipped[reason, default: 0] += 1
            if let facts = projects[id]?.facts, facts.skippedFiles.count < FolderWalk.maximumListedSkips {
                projects[id]?.facts.skippedFiles.append(SkippedFile(url: job.file, reason: reason, modified: Date(timeIntervalSince1970: next.modified)))
            }
            await refreshReport(id, generation: next.generation, isIndexing: reports[id]?.isIndexing ?? false)
            return
        }
        let madeNoProgress = read.tried.isEmpty && !read.isDone
        if read.fileChanged || (madeNoProgress && !wasInterrupted && currentPause() == nil && !sweepWaits) {
            leaveUntilSweep(next.row, project: id)
            await refreshReport(id, generation: next.generation, isIndexing: reports[id]?.isIndexing ?? false)
            return
        }
        guard !madeNoProgress else { return }
        let prepared = await Self.recognizedChunks(read, file: job.file, modified: next.modified, chunker: chunker)
        await waitWhileDictating()
        guard isCurrent(id, next.generation) else { return }
        let isPDF = job.kind == .pdf
        do {
            try await database.transaction { [row = next.row, size = next.size, modified = next.modified] database in
                // Only while the row is still the job's file, as the sweep left it.
                guard try !database.run(
                    "SELECT 1 FROM index_files WHERE id = ?1 AND project = ?2 AND size = ?3 AND modified = ?4 AND recognize = 1",
                    [.integer(row), .text(id.uuidString), .integer(size), .real(modified)]).isEmpty else { return }
                try Self.insert(prepared.chunks, file: row, project: id, name: prepared.name, in: database)
                try database.run("DELETE FROM index_recognition_pages WHERE file = ? AND (size != ? OR modified != ?)", [.integer(row), .integer(size), .real(modified)])
                for (page, outcome) in read.tried {
                    try database.run(
                        "INSERT OR REPLACE INTO index_recognition_pages (file, page, size, modified, outcome) VALUES (?, ?, ?, ?, ?)",
                        [.integer(row), .integer(Int64(page)), .integer(size), .real(modified), .text(outcome.rawValue)])
                }
                try database.run(
                    "UPDATE index_files SET text_bytes = text_bytes + ?, chunks = chunks + ?, hidden_runs = hidden_runs + ? WHERE id = ?",
                    [.integer(prepared.textBytes), .integer(Int64(prepared.chunks.count)), .integer(Int64(read.hiddenRuns)), .integer(row)])
                // The file has text once any page gave some. Without, it waits while pages
                // are left, and then holds no text.
                let hasText = try database.run("SELECT text_bytes > 0 OR chunks > 0 FROM index_files WHERE id = ?", [.integer(row)]).first?.first?.integer == 1
                let skip: FileSkipReason? = hasText ? nil : !read.isDone ? .waitsForRecognition : isPDF ? .noText : .imageWithoutText
                try database.run(
                    "UPDATE index_files SET skip = ?, recognize = ? WHERE id = ?",
                    [skip.map { .text($0.rawValue) } ?? .null, .integer(read.isDone ? 0 : 1), .integer(row)])
            }
            let outcomes = read.tried.values
            let milliseconds = started.duration(to: .now) / .milliseconds(1)
            Logger.projectsIndex.notice(
                "Index recognized \(read.tried.count, privacy: .public) pages of a file in \(Int(milliseconds), privacy: .public) ms: \(outcomes.count { $0 == .text }, privacy: .public) with text, \(outcomes.count { $0 == .blank }, privacy: .public) blank, \(outcomes.count { $0 == .timedOut }, privacy: .public) timed out, \(outcomes.count { $0 == .failed }, privacy: .public) failed, \(read.hiddenRuns, privacy: .public) hidden runs, \(read.isDone ? "done" : "pages left", privacy: .public)")
        } catch {
            // So a database that cannot write, such as on a full disk, never makes the pass
            // read the same file again and again.
            leaveUntilSweep(next.row, project: id)
            Self.logRecognitionFailure(error)
        }
        await refreshReport(id, generation: next.generation, isIndexing: reports[id]?.isIndexing ?? false)
    }

    private nonisolated static func logRecognitionFailure(_ error: any Error) {
        if let failure = error as? ProjectsDatabase.Failure {
            Logger.projectsIndex.error("Recognition failed at \(failure.step.rawValue, privacy: .public) with SQLite error \(failure.code, privacy: .public)")
        } else {
            Logger.projectsIndex.error("Recognition failed with error \((error as NSError).code, privacy: .public)")
        }
    }

    /// The chunks of recognized pages with their words, the words of the file's name, and
    /// the bytes of their text. Off the main actor, since NLTokenizer takes a while.
    @concurrent
    private nonisolated static func recognizedChunks(
        _ read: RecognitionResult, file: URL, modified: Double, chunker: TextChunker
    ) async -> (chunks: [Prepared.Chunk], name: ChunkName, textBytes: Int64) {
        let text = FileTextResult(pages: read.pages, hiddenRuns: read.hiddenRuns, modified: Date(timeIntervalSince1970: modified), isCut: false)
        return (chunks(of: text, file: file, chunker: chunker), ChunkName(file), read.pages.reduce(0) { $0 + Int64($1.text.utf8.count) })
    }

    /// Reads the counts of a project's report again. The files left for recognition leave
    /// out those it leaves until the next sweep, and are none once the project's text
    /// reached its limit, since recognition stops then.
    private func refreshReport(_ id: UUID, generation: Int, isIndexing: Bool) async {
        let skips = projects[id]?.recognitionSkips ?? []
        guard let totals = try? await database.run("""
                SELECT sum(CASE WHEN skip IS NULL THEN 1 ELSE 0 END), sum(CASE WHEN skip IS NULL AND hidden_runs > 0 THEN 1 ELSE 0 END),
                sum(chunks), sum(text_bytes), sum(CASE WHEN skip IS NOT NULL AND skip != ?2 THEN 1 ELSE 0 END),
                sum(CASE WHEN recognize = 1 AND id NOT IN (SELECT value FROM json_each(?3)) THEN 1 ELSE 0 END)
                FROM index_files WHERE project = ?1
                """, [.text(id.uuidString), .text(FileSkipReason.waitsForRecognition.rawValue), .text(Self.jsonArray(skips))]).first,
              let watched = projects[id], watched.generation == generation, totals.count == 6 else { return }
        let textBytes = totals[3].integer ?? 0
        let waiting = Int(totals[5].integer ?? 0)
        let isFull = textBytes >= limits.textBytes
        let left = isFull ? 0 : waiting
        reports[id] = Report(
            indexed: Int(totals[0].integer ?? 0), chunks: Int(totals[2].integer ?? 0), textBytes: textBytes,
            hiddenText: Int(totals[1].integer ?? 0), skipped: watched.facts.skipped, refusedFolders: watched.facts.refusedFolders,
            reachedFileLimit: watched.facts.reachedFileLimit, reachedTextLimit: watched.facts.reachedTextLimit || (isFull && waiting > 0),
            isIndexing: isIndexing, nameOnly: Int(totals[4].integer ?? 0), reachedNameLimit: watched.facts.reachedNameLimit,
            recognitionLeft: left, recognitionPause: left > 0 ? lastingPause : nil)
    }

    /// A JSON array of row IDs, for json_each.
    private nonisolated static func jsonArray(_ rows: Set<Int64>) -> String {
        "[" + rows.sorted().map(String.init).joined(separator: ",") + "]"
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
        var chunkName = ChunkName()
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

    /// The words of a file's name, as the chunk tables hold them with each chunk, since the
    /// name says what the file is about.
    private nonisolated struct ChunkName: Sendable {
        var words = ""
        var trigramText = ""

        init() {}

        init(_ file: URL) {
            let name = FolderIndex.searchableName(file)
            words = ChunkSearch.indexedWords(name)
            trigramText = ChunkSearch.indexedTrigramText(name)
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
        prepared.chunkName = ChunkName(file.url)
        prepared.chunks = chunks(of: text, file: file.url, chunker: chunker)
        return prepared
    }

    /// The chunks of a file's text with their words. The heading counts as words of each
    /// chunk under it.
    private nonisolated static func chunks(of text: FileTextResult, file: URL, chunker: TextChunker) -> [Prepared.Chunk] {
        chunker.chunks(of: text, file: file).map { chunk in
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
        try insert(prepared.chunks, file: file, project: prepared.project, name: prepared.chunkName, in: database)
        try writeName(prepared.name, row: file, in: database)
        return removed
    }

    /// Inserts chunks of a file's row with their rows in the two full text tables.
    private static func insert(_ chunks: [Prepared.Chunk], file: Int64, project: UUID, name: ChunkName, in database: isolated ProjectsDatabase) throws {
        for chunk in chunks {
            let page: Value = chunk.page.map { .integer(Int64($0)) } ?? .null
            let heading: Value = chunk.heading.map { .text($0) } ?? .null
            let sheet: Value = chunk.sheet.map { .text($0) } ?? .null
            try database.run(
                "INSERT INTO index_chunks (file, project, page, heading, modified, text, chinese, sheet, recognized) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.integer(file), .text(project.uuidString), page, heading, .real(chunk.modified.timeIntervalSince1970), .text(chunk.text),
                 .integer(chunk.trigramText == nil ? 0 : 1), sheet, .integer(chunk.recognized ? 1 : 0)])
            let row = database.lastInsertedRow
            try database.run(
                "INSERT INTO index_chunk_words (rowid, name, words) VALUES (?, ?, ?)",
                [.integer(row), .text(name.words), .text(chunk.words)])
            if let trigramText = chunk.trigramText {
                try database.run(
                    "INSERT INTO index_chunk_trigrams (rowid, name, text) VALUES (?, ?, ?)",
                    [.integer(row), .text(name.trigramText), .text(trigramText)])
            }
        }
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
