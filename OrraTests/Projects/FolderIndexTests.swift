import Foundation
import Synchronization
import Testing
@testable import Orra

/// The index of project folders, on files made in a temporary folder, with a database in a
/// temporary root, stand ins for the folder events and the dictation, and a sleep that only
/// yields. The tests call the timer's tick themselves. No time decides a result.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FolderIndexTests {
    /// The names of the files read, in order.
    final class Reads: Sendable {
        let names = Mutex<[String]>([])

        var all: [String] {
            names.withLock { $0 }
        }
    }

    /// Paths whose stat flags say dataless, for the walk.
    final class Dataless: Sendable {
        let paths = Mutex<Set<String>>([])

        func add(_ paths: [String]) {
            self.paths.withLock { $0.formUnion(paths) }
        }
    }

    /// Whether a dictation is under way, as EngineTurns says, and how often a worker asked.
    final class Dictation: Sendable {
        private let value = Mutex(false)
        private let asked = Mutex(0)

        var isOn: Bool {
            get {
                asked.withLock { $0 += 1 }
                return value.withLock { $0 }
            }
            set { value.withLock { $0 = newValue } }
        }

        var checks: Int {
            asked.withLock { $0 }
        }
    }

    /// Holds the reads that wait on it until the test opens it, and counts how many were in
    /// flight at once.
    final class Gate: Sendable {
        private struct State {
            var waiting: [CheckedContinuation<Void, Never>] = []
            var arrivals: [CheckedContinuation<Void, Never>] = []
            var isOpen = false
            var reading = 0
            var mostReading = 0
        }

        private let state = Mutex(State())

        var waiting: Int {
            state.withLock { $0.waiting.count }
        }

        /// The most reads in flight at once, from the start of a read to its end.
        var mostReading: Int {
            state.withLock { $0.mostReading }
        }

        /// Reads a file after waiting here, and counts it as in flight until it is read.
        func read(_ url: URL) async -> Result<FileTextResult, FileSkipReason> {
            state.withLock { state in
                state.reading += 1
                state.mostReading = max(state.mostReading, state.reading)
            }
            defer { state.withLock { $0.reading -= 1 } }
            await wait()
            return await FileTextExtractor().text(of: url)
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let arrivals = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
                    guard !state.isOpen else { return nil }
                    state.waiting.append(continuation)
                    defer { state.arrivals = [] }
                    return state.arrivals
                }
                guard let arrivals else {
                    continuation.resume()
                    return
                }
                for arrival in arrivals {
                    arrival.resume()
                }
            }
        }

        /// Returns once a read waits.
        func untilARead() async {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state in
                    guard state.waiting.isEmpty else { return true }
                    state.arrivals.append(continuation)
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        }

        func open() {
            let waiting = state.withLock { state in
                state.isOpen = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for waiter in waiting {
                waiter.resume()
            }
        }
    }

    /// A project folder, a database and a FolderIndex with stand ins.
    @MainActor
    final class Fixture {
        let alpha = UUID()
        let beta = UUID()
        /// The project folder, at its real path, as the walk gives it.
        let folderURL: URL
        let storage: ProjectsStorage
        let database: ProjectsDatabase
        let reads = Reads()
        let dataless = Dataless()
        let dictation: Dictation
        private(set) var index: FolderIndex!
        /// Called at each short sleep, such as a wait for a dictation.
        var onSleep: (() async -> Void)?
        private(set) var sleeps = 0
        private(set) var deliveries: [@Sendable (FolderEvents.Changes) -> Void] = []
        private(set) var watched: [[URL]] = []
        private(set) var watchedSince: [UInt64?] = []
        private(set) var stops = 0

        init(
            limits: FolderIndex.Limits = FolderIndex.Limits(),
            dictation: Dictation = Dictation(),
            read: (@Sendable (URL) async -> Result<FileTextResult, FileSkipReason>)? = nil
        ) async throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("FolderIndexTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            let real = try #require(made.path.withCString { realpath($0, nil) }.map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
            folderURL = URL(fileURLWithPath: real + "/Alpha", isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            storage = ProjectsStorage(root: URL(fileURLWithPath: real + "/Support", isDirectory: true))
            database = try await ProjectsDatabase.open(in: storage)
            self.dictation = dictation
            let reads = reads
            let dataless = dataless
            let reader = read ?? { await FileTextExtractor().text(of: $0) }
            index = FolderIndex(
                database: database,
                isDictating: { dictation.isOn },
                limits: limits,
                walk: FolderWalk(flags: { path in
                    dataless.paths.withLock { $0.contains(path) } ? UInt32(SF_DATALESS) : FolderWalk.statFlags(path)
                }),
                readText: { url in
                    reads.names.withLock { $0.append(url.lastPathComponent) }
                    return await reader(url)
                },
                sleep: { [weak self] duration in
                    if duration >= FolderIndex.sweepGap {
                        try await Task.sleep(for: duration)
                    } else {
                        await self?.slept()
                    }
                },
                watch: { [unowned self] folders, since, deliver in
                    self.deliveries.append(deliver)
                    self.watched.append(folders)
                    self.watchedSince.append(since)
                    return { [unowned self] in self.stops += 1 }
                })
        }

        var folder: String {
            folderURL.path
        }

        var dictating: Bool {
            get { dictation.isOn }
            set { dictation.isOn = newValue }
        }

        private func slept() async {
            sleeps += 1
            await onSleep?()
            await Task.yield()
        }

        func cleanUp() async {
            index.stopAll()
            await database.close()
            try? FileManager.default.removeItem(at: folderURL.deletingLastPathComponent())
        }

        /// Writes a file in the project folder, or at a path inside the temporary root.
        @discardableResult
        func write(_ name: String, _ text: String, modified: Date? = nil) throws -> URL {
            let url = URL(fileURLWithPath: name.hasPrefix("/") ? name : folder + "/" + name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }

        /// Hands changes to the index as FolderEvents would, and waits until it took them in.
        func deliver(_ changes: FolderEvents.Changes) async {
            deliveries.last?(changes)
            for _ in 0..<1_000 where index.isIdle {
                await Task.yield()
            }
            await index.waitUntilIdle()
        }

        /// Ticks the timer, and waits until the sweeps it started are done.
        func tick() async {
            index.sweepChangedProjects()
            await index.waitUntilIdle()
        }

        /// Hands changes to the index and ticks the timer.
        func deliverAndTick(_ changes: FolderEvents.Changes) async {
            await deliver(changes)
            await tick()
        }

        func start(_ project: UUID? = nil, folders: [URL]? = nil) async {
            index.start(project: project ?? alpha, folders: folders ?? [folderURL])
            await index.waitUntilIdle()
        }

        func search(_ text: String, in projects: [UUID]? = nil) async throws -> [ChunkSearch.Hit] {
            try await ChunkSearch(database: database).search(text, in: projects)
        }

        func count(_ sql: String) async throws -> Int64 {
            try await database.run(sql).first?.first?.integer ?? -1
        }

        /// Every chunk has its row in the words table, and every chunk with Chinese its row
        /// in the trigram table, and nothing else is there.
        func expectTablesAgree() async throws {
            #expect(try await count("SELECT count(*) FROM index_chunk_words") == count("SELECT count(*) FROM index_chunks"))
            #expect(try await count("SELECT count(*) FROM index_chunk_words WHERE rowid NOT IN (SELECT id FROM index_chunks)") == 0)
            #expect(try await count("SELECT count(*) FROM index_chunk_trigrams") == count("SELECT count(*) FROM index_chunks WHERE chinese = 1"))
            #expect(try await count("SELECT count(*) FROM index_chunk_trigrams WHERE rowid NOT IN (SELECT id FROM index_chunks)") == 0)
            #expect(try await count("SELECT count(*) FROM index_chunks WHERE file NOT IN (SELECT id FROM index_files)") == 0)
        }
    }

    /// Runs `body` with a fixture, and cleans up before it returns, also after a failure.
    private func withFixture(
        limits: FolderIndex.Limits = FolderIndex.Limits(),
        dictation: Dictation = Dictation(),
        read: (@Sendable (URL) async -> Result<FileTextResult, FileSkipReason>)? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(limits: limits, dictation: dictation, read: read)
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    @Test func indexesTheTextOfAFolderAndSearchFindsIt() async throws {
        try await withFixture { fixture in
            try fixture.write("合同.md", "# 付款\n\n合同付款条款需要确认。")
            try fixture.write("sub/notes.txt", "The print run is 500 calendars.")
            try fixture.write("budget.xlsx", "x")
            try fixture.write(".draft.md", "hidden")
            try fixture.write("empty.txt", "   \n")
            await fixture.start()

            #expect(fixture.reads.all.sorted() == ["empty.txt", "notes.txt", "合同.md"])
            let report = try #require(fixture.index.reports[fixture.alpha])
            #expect(report.indexed == 2)
            #expect(report.chunks == 2)
            #expect(report.textBytes == Int64("# 付款\n\n合同付款条款需要确认。".utf8.count + "The print run is 500 calendars.".utf8.count))
            #expect(report.hiddenText == 0)
            #expect(report.skipped == [.spreadsheetOrSlides: 1, .hidden: 1, .noText: 1])
            #expect(report.refusedFolders.isEmpty)
            #expect(!report.reachedFileLimit && !report.reachedTextLimit && !report.isIndexing)

            let hit = try #require(try await fixture.search("合同", in: [fixture.alpha]).first)
            #expect(hit.file.path == fixture.folder + "/合同.md")
            #expect(hit.heading == "付款")
            #expect(hit.project == fixture.alpha)
            #expect(try await fixture.search("calendars").map(\.file.lastPathComponent) == ["notes.txt"])
            // The file name counts as words of its chunks.
            #expect(try await fixture.search("notes").map(\.file.lastPathComponent) == ["notes.txt"])

            let skipped = try await fixture.index.skippedFiles(project: fixture.alpha)
            #expect(skipped.map(\.url.lastPathComponent) == ["budget.xlsx", "empty.txt"])
            #expect(skipped.map(\.reason) == [.spreadsheetOrSlides, .noText])
            #expect(skipped[1].modified != nil)
            #expect(fixture.watchedSince == [nil])
            try await fixture.expectTablesAgree()
        }
    }

    /// Changed folders are swept at the next tick, which reads only what changed and drops
    /// what is gone.
    @Test func aSweepAtTheNextTickReadsOnlyWhatChangedAndDropsWhatIsGone() async throws {
        try await withFixture { fixture in
            let old = Date(timeIntervalSince1970: 1_760_000_000)
            try fixture.write("合同.md", "合同付款条款需要确认。", modified: old)
            try fixture.write("notes.txt", "The print run is 500 calendars.", modified: old)
            try fixture.write("same.txt", "Lamps arrive on Friday.", modified: old)
            await fixture.start()
            #expect(fixture.reads.all.count == 3)

            try fixture.write("notes.txt", "The print run is 800 posters.", modified: old.addingTimeInterval(60))
            try fixture.write("new.md", "New brochure text.")
            try FileManager.default.removeItem(atPath: fixture.folder + "/合同.md")
            await fixture.deliver(FolderEvents.Changes(changed: [fixture.folder + "/notes.txt", fixture.folder + "/new.md"], lastEventID: 7))
            // Nothing is read before the tick.
            #expect(fixture.reads.all.count == 3)
            #expect(fixture.index.isIdle)

            await fixture.tick()
            #expect(fixture.reads.all.dropFirst(3).sorted() == ["new.md", "notes.txt"])
            #expect(try await fixture.search("合同").isEmpty)
            #expect(try await fixture.search("calendars").isEmpty)
            #expect(try await fixture.search("posters").count == 1)
            #expect(try await fixture.search("lamps").count == 1)
            #expect(fixture.index.reports[fixture.alpha]?.indexed == 3)
            try await fixture.expectTablesAgree()

            // A tick without changes sweeps nothing.
            await fixture.tick()
            #expect(fixture.reads.all.count == 5)
        }
    }

    /// A rename moves the file's row at once, so the file is not read again. A renamed folder
    /// moves the rows of its files.
    @Test func aRenameMovesTheRowWithoutReadingTheFileAgain() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "The print run is 500 calendars.")
            try fixture.write("sub/plan.md", "灯具采购计划。")
            await fixture.start()
            #expect(fixture.reads.all.count == 2)

            try FileManager.default.moveItem(atPath: fixture.folder + "/notes.txt", toPath: fixture.folder + "/Print notes.txt")
            try FileManager.default.moveItem(atPath: fixture.folder + "/sub", toPath: fixture.folder + "/plans")
            await fixture.deliver(FolderEvents.Changes(renamed: [
                FolderEvents.Rename(from: fixture.folder + "/notes.txt", to: fixture.folder + "/Print notes.txt"),
                FolderEvents.Rename(from: fixture.folder + "/sub", to: fixture.folder + "/plans"),
            ]))
            #expect(try await fixture.search("calendars").map(\.file.path) == [fixture.folder + "/Print notes.txt"])
            #expect(try await fixture.search("灯具采购").map(\.file.path) == [fixture.folder + "/plans/plan.md"])

            await fixture.tick()
            #expect(fixture.reads.all.count == 2)
            #expect(try await fixture.count("SELECT count(*) FROM index_files") == 2)
            try await fixture.expectTablesAgree()
        }
    }

    /// A rename a sweep already took in, such as one replayed from the stored event, finds
    /// nothing at its old path and leaves the new path as it is.
    @Test func aRenameWhoseOldPathHoldsNothingChangesNothing() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "The print run is 500 calendars.")
            await fixture.start()
            await fixture.deliverAndTick(FolderEvents.Changes(renamed: [
                FolderEvents.Rename(from: fixture.folder + "/draft.txt", to: fixture.folder + "/notes.txt"),
            ]))
            #expect(fixture.reads.all == ["notes.txt"])
            #expect(try await fixture.search("calendars").count == 1)
        }
    }

    /// A removal drops the text at once, without waiting for the tick.
    @Test func aRemovalDropsTheTextAtOnce() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "The print run is 500 calendars.")
            try fixture.write("sub/plan.md", "灯具采购计划。")
            try fixture.write("sub plan.md", "Lamps arrive on Friday.")
            await fixture.start()
            try FileManager.default.removeItem(atPath: fixture.folder + "/notes.txt")
            try FileManager.default.removeItem(atPath: fixture.folder + "/sub")
            await fixture.deliver(FolderEvents.Changes(removed: [fixture.folder + "/notes.txt", fixture.folder + "/sub"]))
            #expect(try await fixture.search("calendars").isEmpty)
            #expect(try await fixture.search("灯具采购").isEmpty)
            // A file whose name starts with the removed folder's name stays.
            #expect(try await fixture.search("lamps").count == 1)
            #expect(try await fixture.count("SELECT count(*) FROM index_files") == 1)
            try await fixture.expectTablesAgree()
        }
    }

    /// A file that took too long is kept with why and its modification date, so it is read
    /// again only once it changes.
    @Test func aSlowFileIsSkippedUntilItChanges() async throws {
        try await withFixture(read: { url in
            url.lastPathComponent == "slow.pdf" ? .failure(.tooSlow) : await FileTextExtractor().text(of: url)
        }) { fixture in
            let old = Date(timeIntervalSince1970: 1_760_000_000)
            try fixture.write("slow.pdf", "%PDF", modified: old)
            try fixture.write("notes.txt", "Calendars.")
            await fixture.start()
            #expect(fixture.reads.all.sorted() == ["notes.txt", "slow.pdf"])
            #expect(fixture.index.reports[fixture.alpha]?.skipped == [.tooSlow: 1])
            let skipped = try await fixture.index.skippedFiles(project: fixture.alpha)
            #expect(skipped == [FolderIndex.SkippedFile(url: URL(fileURLWithPath: fixture.folder + "/slow.pdf"), reason: .tooSlow, modified: old)])

            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(fixture.reads.all.count == 2)

            try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(1)], ofItemAtPath: fixture.folder + "/slow.pdf")
            await fixture.deliverAndTick(FolderEvents.Changes(changed: [fixture.folder + "/slow.pdf"]))
            #expect(fixture.reads.all.count == 3)
            #expect(fixture.reads.all.last == "slow.pdf")
        }
    }

    /// No access can pass without a change to the file, so it is tried at every sweep and
    /// only counted.
    @Test func aFileWithoutAccessIsTriedAgain() async throws {
        try await withFixture(read: { url in
            url.lastPathComponent == "locked.txt" ? .failure(.noAccess) : await FileTextExtractor().text(of: url)
        }) { fixture in
            try fixture.write("locked.txt", "Secret.")
            await fixture.start()
            #expect(fixture.index.reports[fixture.alpha]?.skipped == [.noAccess: 1])
            #expect(try await fixture.count("SELECT count(*) FROM index_files") == 0)
            #expect(try await fixture.index.skippedFiles(project: fixture.alpha).map(\.reason) == [.noAccess])
            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(fixture.reads.all == ["locked.txt", "locked.txt"])
        }
    }

    @Test func itWaitsWhileADictationIsUnderWay() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "Calendars.")
            fixture.dictating = true
            var readWhileDictating = false
            fixture.onSleep = { @MainActor [unowned fixture] in
                readWhileDictating = readWhileDictating || !fixture.reads.all.isEmpty
                if fixture.sleeps == 3 {
                    fixture.dictating = false
                }
            }
            await fixture.start()
            #expect(fixture.sleeps == 3)
            #expect(!readWhileDictating)
            #expect(fixture.reads.all == ["notes.txt"])
            #expect(fixture.index.reports[fixture.alpha]?.indexed == 1)
        }
    }

    /// The writes wait too: a dictation that starts while a file is read holds its chunks
    /// back until it ends.
    @Test func aDictationThatStartsDuringAReadHoldsTheWrite() async throws {
        let dictation = Dictation()
        try await withFixture(dictation: dictation, read: { url in
            dictation.isOn = true
            return await FileTextExtractor().text(of: url)
        }) { fixture in
            try fixture.write("notes.txt", "Calendars.")
            var chunksWhileDictating: Int64 = -1
            fixture.onSleep = { [unowned fixture] in
                chunksWhileDictating = (try? await fixture.count("SELECT count(*) FROM index_chunks")) ?? -1
                fixture.dictating = false
            }
            await fixture.start()
            #expect(fixture.sleeps == 1)
            #expect(chunksWhileDictating == 0)
            #expect(try await fixture.count("SELECT count(*) FROM index_chunks") == 1)
        }
    }

    @Test func aProjectHoldsAtMostItsFiles() async throws {
        try await withFixture(limits: FolderIndex.Limits(files: 2)) { fixture in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try fixture.write(name, "Text of \(name).")
            }
            await fixture.start()
            let report = try #require(fixture.index.reports[fixture.alpha])
            #expect(report.indexed == 2)
            #expect(report.reachedFileLimit)
            #expect(!report.reachedTextLimit)
        }
    }

    /// The new file that passes the text limit is the last new one read. A changed file's
    /// old text counts only until its new text replaces it.
    @Test func aProjectStopsReadingNewFilesPastItsText() async throws {
        try await withFixture(limits: FolderIndex.Limits(textBytes: 50)) { fixture in
            let old = Date(timeIntervalSince1970: 1_760_000_000)
            for name in ["a.txt", "b.txt"] {
                try fixture.write(name, "Twenty bytes of text", modified: old)
            }
            await fixture.start()
            #expect(fixture.reads.all == ["a.txt", "b.txt"])
            #expect(fixture.index.reports[fixture.alpha]?.reachedTextLimit == false)

            try fixture.write("a.txt", "Posters arrive today", modified: old.addingTimeInterval(60))
            for name in ["c.txt", "d.txt"] {
                try fixture.write(name, "Twenty bytes of text", modified: old)
            }
            await fixture.deliverAndTick(FolderEvents.Changes(changed: [fixture.folder + "/a.txt", fixture.folder + "/c.txt", fixture.folder + "/d.txt"]))
            // 20 bytes stay with b.txt and a.txt brings 20 again, so c.txt still fits and
            // passes the limit, and d.txt waits.
            #expect(fixture.reads.all == ["a.txt", "b.txt", "a.txt", "c.txt"])
            let report = try #require(fixture.index.reports[fixture.alpha])
            #expect(report.indexed == 3)
            #expect(report.textBytes == 60)
            #expect(report.reachedTextLimit)

            // A later sweep reads nothing more.
            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(fixture.reads.all.count == 4)
        }
    }

    /// A file the index holds is read again when it changes, even when the files left as
    /// they are already pass the limit, so its old text never stays.
    @Test func aChangedFileIsReadAgainPastTheTextLimit() async throws {
        try await withFixture(limits: FolderIndex.Limits(textBytes: 30)) { fixture in
            let old = Date(timeIntervalSince1970: 1_760_000_000)
            let large = "Forty bytes of text that the index holds"
            try fixture.write("a.txt", "Lamps", modified: old)
            try fixture.write("b.txt", large, modified: old)
            await fixture.start()
            #expect(fixture.reads.all == ["a.txt", "b.txt"])

            try fixture.write("a.txt", "Posters", modified: old.addingTimeInterval(60))
            try fixture.write("c.txt", "Twenty bytes of text", modified: old)
            await fixture.deliverAndTick(FolderEvents.Changes(changed: [fixture.folder + "/a.txt", fixture.folder + "/c.txt"]))
            #expect(fixture.reads.all == ["a.txt", "b.txt", "a.txt"])
            #expect(try await fixture.search("posters").map(\.file.lastPathComponent) == ["a.txt"])
            #expect(try await fixture.search("lamps").isEmpty)
            let report = try #require(fixture.index.reports[fixture.alpha])
            #expect(report.textBytes == Int64("Posters".utf8.count + large.utf8.count))
            #expect(report.reachedTextLimit)
        }
    }

    @Test func filesThatHidTextAreCounted() async throws {
        try await withFixture(read: { url in
            guard url.lastPathComponent == "brief.txt" else { return await FileTextExtractor().text(of: url) }
            return .success(FileTextResult(pages: [.init(number: nil, text: "The print run is 500 calendars.")], hiddenRuns: 2, modified: .now, isCut: false))
        }) { fixture in
            try fixture.write("brief.txt", "x")
            try fixture.write("plain.txt", "Calendars too.")
            await fixture.start()
            #expect(fixture.index.reports[fixture.alpha]?.hiddenText == 1)
            #expect(try await fixture.index.filesWithHiddenText(project: fixture.alpha).map(\.lastPathComponent) == ["brief.txt"])
            let hits = try await fixture.search("calendars")
            #expect(Dictionary(uniqueKeysWithValues: hits.map { ($0.file.lastPathComponent, $0.fileHiddenRuns) }) == ["brief.txt": 2, "plain.txt": 0])
        }
    }

    /// What sorting and the explanation read of a project's files: the names of the files
    /// with text, and each with its date and the start of its text, never a skipped one.
    @Test func sortingAndTheExplanationReadTheFilesWithText() async throws {
        try await withFixture { fixture in
            let old = Date(timeIntervalSince1970: 1_760_000_000)
            try fixture.write("plan_v2.txt", "替代 v1\n\nThe print run is 500 calendars.", modified: old)
            try fixture.write("sub/合同.md", "合同付款条款需要确认。", modified: old)
            try fixture.write("budget.xlsx", "x")
            await fixture.start()
            #expect(try await fixture.index.fileNames(project: fixture.alpha) == ["plan_v2.txt", "合同.md"])
            let files = try await fixture.index.versionFiles(project: fixture.alpha)
            #expect(files.map(\.url.lastPathComponent) == ["plan_v2.txt", "合同.md"])
            #expect(files.first?.head.hasPrefix("替代 v1") == true)
            #expect(files.allSatisfy { abs($0.modified.timeIntervalSince(old)) < 1 })
            #expect(try await fixture.index.fileNames(project: UUID()).isEmpty)
        }
    }

    /// A file removed to save space cannot be read without a download, so its text stays.
    @Test func aFileNoLongerOnThisMacKeepsItsText() async throws {
        try await withFixture { fixture in
            let notes = try fixture.write("notes.txt", "The print run is 500 calendars.")
            await fixture.start()
            fixture.dataless.add([notes.path])
            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(try await fixture.search("calendars").count == 1)
            #expect(fixture.index.reports[fixture.alpha]?.skipped[.dataless] == 1)
            #expect(fixture.reads.all == ["notes.txt"])
        }
    }

    /// A folder removed to save space lists none of its files, and they keep their text. A
    /// file that is really gone does not.
    @Test func theFilesOfAFolderNoLongerOnThisMacKeepTheirText() async throws {
        try await withFixture { fixture in
            try fixture.write("sub/plan.md", "灯具采购计划。")
            try fixture.write("sub/deeper/notes.txt", "The print run is 500 calendars.")
            try fixture.write("gone.txt", "Lamps arrive on Friday.")
            await fixture.start()
            fixture.dataless.add([fixture.folder + "/sub"])
            try FileManager.default.removeItem(atPath: fixture.folder + "/gone.txt")
            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(try await fixture.search("灯具采购").count == 1)
            #expect(try await fixture.search("calendars").count == 1)
            #expect(try await fixture.search("lamps").isEmpty)
            #expect(fixture.reads.all.count == 3)
            #expect(fixture.index.reports[fixture.alpha]?.textBytes == Int64("灯具采购计划。".utf8.count + "The print run is 500 calendars.".utf8.count))
        }
    }

    /// The walk names at most `FolderWalk.maximumListedSkips` skipped files. Files not on
    /// this Mac past them keep their text too.
    @Test func filesNoLongerOnThisMacPastTheListedSkipsKeepTheirText() async throws {
        try await withFixture { fixture in
            // The walk takes the folders of a folder last name first, so these fill the list
            // of skips before it reaches the notes.
            var away: [String] = []
            for number in 0..<FolderWalk.maximumListedSkips {
                try away.append(fixture.write("b/away \(number).txt", "Away.").path)
            }
            fixture.dataless.add(away)
            try fixture.write("a/notes.txt", "The print run is 500 calendars.")
            await fixture.start()
            #expect(fixture.reads.all == ["notes.txt"])
            #expect(fixture.index.reports[fixture.alpha]?.skipped[.dataless] == FolderWalk.maximumListedSkips)

            fixture.dataless.add([fixture.folder + "/a/notes.txt"])
            await fixture.deliverAndTick(FolderEvents.Changes(mustSweep: true))
            #expect(fixture.index.reports[fixture.alpha]?.skipped[.dataless] == FolderWalk.maximumListedSkips + 1)
            #expect(try await fixture.search("calendars").count == 1)
        }
    }

    /// Added folders the walk refuses are reported and never watched. A missing folder is
    /// watched, so its files are seen once it appears.
    @Test func refusedAndRemovedFolders() async throws {
        try await withFixture { fixture in
            let second = URL(fileURLWithPath: fixture.folder + "/../Second", isDirectory: true).standardizedFileURL
            try fixture.write(second.path + "/plan.txt", "Lamps arrive on Friday.")
            try fixture.write("notes.txt", "Calendars.")
            let missing = URL(fileURLWithPath: fixture.folder + "/../Missing", isDirectory: true).standardizedFileURL
            // A folder named like Mail's data, such as one in a backup, made up for the test.
            let mailCopy = URL(fileURLWithPath: fixture.folder + "/../Backup/Library/Mail", isDirectory: true).standardizedFileURL
            try fixture.write(mailCopy.path + "/note.txt", "Posters.")
            await fixture.start(folders: [fixture.folderURL, second, missing, mailCopy])
            let report = try #require(fixture.index.reports[fixture.alpha])
            #expect(report.indexed == 2)
            #expect(report.refusedFolders == [missing: .notAFolder, mailCopy: .mailData])
            #expect(fixture.watched == [[fixture.folderURL, second, missing]])
            #expect(!fixture.reads.all.contains("note.txt"))

            // Without the second folder, its files leave the index.
            await fixture.start(folders: [fixture.folderURL])
            #expect(try await fixture.search("lamps").isEmpty)
            #expect(fixture.index.reports[fixture.alpha]?.indexed == 1)
            #expect(fixture.stops == 1)
            try await fixture.expectTablesAgree()
        }
    }

    @Test func theLastEventIsKeptForTheNextStart() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "Calendars.")
            await fixture.start()
            await fixture.deliver(FolderEvents.Changes(changed: [fixture.folder + "/notes.txt"], lastEventID: 4_242))
            fixture.index.stop(project: fixture.alpha)
            #expect(fixture.stops == 1)
            #expect(fixture.index.reports[fixture.alpha] == nil)
            await fixture.start()
            #expect(fixture.watchedSince == [nil, 4_242])
        }
    }

    /// Stopping keeps what the index holds. Forgetting a project removes all of it, and
    /// nothing of the other projects.
    @Test func stopKeepsTheIndexAndForgetRemovesIt() async throws {
        try await withFixture { fixture in
            try fixture.write("notes.txt", "灯具采购合同已经签好。")
            let other = URL(fileURLWithPath: fixture.folder + "/../Other", isDirectory: true).standardizedFileURL
            try fixture.write(other.path + "/plan.txt", "灯具采购合同还在谈。")
            await fixture.start(fixture.alpha)
            await fixture.start(fixture.beta, folders: [other])
            #expect(try await fixture.search("灯具采购").count == 2)

            fixture.index.stop(project: fixture.alpha)
            #expect(try await fixture.search("灯具采购", in: [fixture.alpha]).count == 1)

            try await fixture.index.forget(project: fixture.beta)
            #expect(try await fixture.search("灯具采购", in: [fixture.beta]).isEmpty)
            #expect(try await fixture.search("灯具采购", in: [fixture.alpha]).count == 1)
            #expect(try await fixture.count("SELECT count(*) FROM index_files WHERE project = '\(fixture.beta.uuidString)'") == 0)
            try await fixture.expectTablesAgree()
            #expect(fixture.index.isIdle)
        }
    }

    /// Forgetting a project while one of its files is read waits for that file, without
    /// polling, even when the task that forgets is cancelled, and then removes all of it.
    @Test func forgetWaitsForTheFileBeingRead() async throws {
        let gate = Gate()
        try await withFixture(read: { url in
            if url.lastPathComponent == "slow.txt" {
                await gate.wait()
            }
            return await FileTextExtractor().text(of: url)
        }) { fixture in
            try fixture.write("notes.txt", "Calendars.")
            try fixture.write("slow.txt", "Posters.")
            fixture.index.start(project: fixture.alpha, folders: [fixture.folderURL])
            await gate.untilARead()

            let forgetting = Task { try await fixture.index.forget(project: fixture.alpha) }
            forgetting.cancel()
            for _ in 0..<100 {
                await Task.yield()
            }
            gate.open()
            try await forgetting.value
            #expect(fixture.sleeps == 0)
            #expect(try await fixture.count("SELECT count(*) FROM index_files") == 0)
            #expect(try await fixture.count("SELECT count(*) FROM index_chunks") == 0)
            try await fixture.expectTablesAgree()
        }
    }

    /// A project started again right after its stop waits until the stopped worker left its
    /// file, so only one worker reads at a time.
    @Test func aWorkerStartedAgainWaitsForTheStoppedOne() async throws {
        let gate = Gate()
        let dictation = Dictation()
        try await withFixture(dictation: dictation, read: { url in
            await gate.read(url)
        }) { fixture in
            try fixture.write("slow.txt", "Posters.")
            fixture.index.start(project: fixture.alpha, folders: [fixture.folderURL])
            await gate.untilARead()
            let checks = dictation.checks
            fixture.index.stop(project: fixture.alpha)
            fixture.index.start(project: fixture.alpha, folders: [fixture.folderURL])
            for _ in 0..<100 {
                await Task.yield()
            }
            // A worker asks about the dictation first, on the main actor, so one that does
            // not wait for the stopped worker asks within these yields.
            #expect(dictation.checks == checks)
            #expect(gate.waiting == 1)
            gate.open()
            await fixture.index.waitUntilIdle()
            #expect(gate.mostReading == 1)
            #expect(fixture.reads.all == ["slow.txt", "slow.txt"])
            #expect(try await fixture.count("SELECT count(*) FROM index_files") == 1)
            #expect(fixture.index.isIdle)
        }
    }
}
