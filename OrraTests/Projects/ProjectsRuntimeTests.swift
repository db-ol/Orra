import Foundation
import Synchronization
import Testing
@testable import Orra

/// Projects while it is on: nothing starts while it is off, everything stops at off, the
/// window holds the model and lets it go at close, the scan waits for the confirm, Mail and
/// the permission, what the scan saves is sorted, the window says what the scan and sorting
/// do, Explain Message Selected in Mail reads only a message in a chosen mailbox
/// (decision 18), and the Debug keys count only in Debug builds.
///
/// Each test has preferences of its own and a temporary folder, a fake Mail that never
/// sends an Apple Event, and a fake model, missing unless a test puts it there. Made up
/// people at .example addresses, nothing from the synthetic set.
@MainActor
struct ProjectsRuntimeTests {
    nonisolated static let own = "me@studio.example"
    /// The day the tests run on, 2026-10-19 at noon UTC.
    nonisolated static let today = Date(timeIntervalSince1970: 1_792_411_200)

    let suite = "io.github.db-ol.OrraTests.projects-runtime-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    let mail = FakeMail()
    let model = FakeModel()
    let tokenizer = TokenizerLoads()
    let machine = Machine()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private var storage: ProjectsStorage {
        ProjectsStorage(root: root.appendingPathComponent("Support", isDirectory: true))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// The runtime with fakes, and its switch and mailbox choice. `installed` says whether
    /// the cleanup model is on this Mac, `countsTokens` gives the explain service a
    /// tokenizer, `openFails` makes the start fail at the database, `folders` stands in for
    /// how the index reaches project folders, `keyDown` for the presses of the talk key,
    /// `retryLoading` for Try Loading Again, `download` for where the model's download
    /// stands, and `recognize` for text recognition, which by default finds no text. The
    /// dictation, Low Power Mode and heat come from `machine`.
    private func make(isOn: Bool = true, isVisible: Bool = true, opens: Count? = nil, installed: Installed = Installed(), countsTokens: Bool = false, openFails: Bool = false, folders: StallingFolders? = nil, keyDown: KeyDown? = nil, retryLoading: @escaping @Sendable () async -> Void = {}, download: Download = Download(), recognize: FolderIndex.Recognize? = nil) -> (ProjectsRuntime, ProjectsSwitch, MailChoice) {
        let projects = ProjectsSwitch(defaults: defaults, isVisible: isVisible, physicalMemory: 32 << 30, storage: storage)
        if isOn {
            projects.turnOn()
        }
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        let model = model
        let counter: (@Sendable (String) -> Int)? = countsTokens ? Self.countTokens : nil
        var watchFolders: FolderIndex.Watch = { _, _, _ in {} }
        var readText: @Sendable (URL) async -> Result<FileTextResult, FileSkipReason> = ProjectsRuntime.readFile
        var resolveFolders: @Sendable ([Data]) async -> [URL] = ProjectsRuntime.resolveFolders
        if let folders {
            watchFolders = folders.watch
            readText = { await folders.read($0) }
            resolveFolders = { await folders.resolve($0) }
        }
        let runtime = ProjectsRuntime(projects: projects, dependencies: ProjectsRuntime.Dependencies(
            storage: storage,
            bridge: mail.bridge,
            choice: choice,
            ownerOverride: { SortingService.Owner(addresses: [Self.own], name: "Me") },
            language: .en,
            isDictating: { [machine] in machine.isDictating },
            whenDictationStarts: { [keyDown] handler in keyDown?.handlers.append(handler) },
            modelEnvironment: { _ in model.environment },
            modelIsInstalled: { installed.value },
            modelDownloadStatus: { download.status },
            retryLoadingModel: retryLoading,
            loadTokenCounter: { [tokenizer] in try await tokenizer.load(counter) },
            handoff: ReplyHandoff(copy: { _ in true }, mail: mail.bridge, isOrraActive: { true }, bringMailToFront: {}),
            watchesMemoryPressure: false,
            watchFolders: watchFolders,
            readText: readText,
            recognizeText: recognize ?? RecognitionTestFiles.findsNothing,
            power: { [machine] in machine.power },
            resolveFolders: resolveFolders,
            openDatabase: { storage in
                opens?.add()
                if openFails {
                    // SQLITE_CANTOPEN.
                    throw ProjectsDatabase.Failure(step: .open, code: 14)
                }
                return try await ProjectsDatabase.open(in: storage)
            },
            now: { Self.today },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        ))
        return (runtime, projects, choice)
    }

    private func started(isVisible: Bool = true, installed: Installed = Installed(), countsTokens: Bool = false, folders: StallingFolders? = nil, keyDown: KeyDown? = nil, retryLoading: @escaping @Sendable () async -> Void = {}, download: Download = Download(), recognize: FolderIndex.Recognize? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (ProjectsRuntime, ProjectsSwitch, MailChoice) {
        let made = make(isVisible: isVisible, installed: installed, countsTokens: countsTokens, folders: folders, keyDown: keyDown, retryLoading: retryLoading, download: download, recognize: recognize)
        made.0.follow()
        try await waitUntil({ made.0.phase == .on }, sourceLocation: sourceLocation)
        return made
    }

    // MARK: Off

    @Test func nothingStartsWhileProjectsIsOff() async throws {
        defer { cleanUp() }
        let opens = Count()
        let (runtime, _, choice) = make(isOn: false, opens: opens)
        choice.choose([.inbox])
        choice.confirm()
        mail.update { $0.isRunning = true }
        runtime.follow()
        runtime.windowOpened()
        runtime.mailRunningChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runtime.phase == .off)
        #expect(!runtime.showsMenuItem)
        #expect(opens.value == 0)
        #expect(model.holds.value == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        // Asking whether Mail runs sends nothing, and nothing else was asked.
        #expect(mail.calls.allSatisfy { $0 == "isRunning" })
        #expect(await runtime.messageSelectedInMail() == .noMailboxChosen)
        #expect(!mail.calls.contains("selection"))
    }

    @Test func aBuildThatHidesProjectsNeverStartsIt() async throws {
        defer { cleanUp() }
        // A Debug run saved Projects as on. A release build reads the same preferences.
        defaults.set(true, forKey: ProjectsSwitch.key)
        let opens = Count()
        let (runtime, projects, _) = make(isOn: false, isVisible: false, opens: opens)
        runtime.follow()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!projects.isOn)
        #expect(runtime.phase == .off)
        #expect(opens.value == 0)
    }

    // MARK: On and off

    @Test func everythingStopsAndClosesWhenProjectsTurnsOff() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let folder = root.appendingPathComponent("Harbor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Quote for the harbor office".write(to: folder.appendingPathComponent("quote.txt"), atomically: true, encoding: .utf8)
        let project = Project(name: "Harbor", folders: [try Project.bookmark(of: folder)])
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id) != nil }
        choice.choose([.inbox])
        choice.confirm()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
        }
        runtime.mailRunningChanged()
        try await waitUntil { runtime.isScanning }
        var closed = 0
        runtime.closeWindow = { closed += 1 }
        runtime.windowOpened()
        #expect(model.holds.value == 1)
        let database = try #require(runtime.running?.database)

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(runtime.running == nil)
        #expect(!runtime.isScanning)
        #expect(!runtime.showsMenuItem)
        #expect(closed == 1)
        #expect(!runtime.isWindowOpen)
        #expect(model.holds.value == 0)
        #expect(runtime.indexReport(project.id) == nil)
        #expect(runtime.projectList.isEmpty)
        // The database is closed, so nothing writes into it any more.
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await database.run("SELECT 1")
        }
        // Turned on again, the project is still there.
        projects.turnOn()
        try await waitUntil { runtime.phase == .on }
        #expect(runtime.projectList.map(\.id) == [project.id])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func deleteAllClosesEverythingForgetsTheChoiceAndStartsAgainEmpty() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        try await runtime.add(Project(name: "Harbor"))
        choice.choose([.inbox])
        choice.confirm()
        let database = try #require(runtime.running?.database)
        await projects.measureStorage()
        #expect(projects.holdsData)

        await projects.deleteAllData()
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await database.run("SELECT 1")
        }
        #expect(!choice.isConfirmed)
        #expect(!projects.deleteFailed)
        // The switch stays on, so Projects starts again with nothing.
        try await waitUntil { runtime.phase == .on }
        #expect(runtime.projectList.isEmpty)
        await projects.turnOff(keepingData: false)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: The window

    @Test func theWindowHoldsTheModelAndLetsGoAtClose() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        #expect(model.holds.value == 0)
        runtime.windowOpened()
        runtime.windowOpened()
        #expect(model.holds.value == 1)
        #expect(runtime.windowHoldsModel)
        runtime.windowClosed()
        #expect(model.holds.value == 0)
        #expect(model.releases.value == 1)
        // Nothing of the user's runs on the model with the window closed.
        await #expect(throws: ProjectsRuntime.Failure.windowClosed) {
            _ = try await runtime.reviseService(startedAt: Self.today)
        }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func aWindowOpenWhileProjectsStartsHoldsTheModelOnceItRuns() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = make()
        runtime.windowOpened()
        #expect(model.holds.value == 0)
        runtime.follow()
        try await waitUntil { runtime.phase == .on }
        #expect(model.holds.value == 1)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(model.holds.value == 0)
    }

    /// Settings opens the window right after the switch goes on, before Projects runs and
    /// before the menus show it. Not while the switch is off.
    @Test func theWindowCanOpenOnceTheSwitchIsOnBeforeProjectsRuns() {
        defer { cleanUp() }
        let (runtime, projects, _) = make(isOn: false)
        #expect(!runtime.canOpenWindow)
        projects.turnOn()
        #expect(runtime.phase == .off)
        #expect(!runtime.showsMenuItem)
        #expect(runtime.canOpenWindow)
    }

    /// Delete All Projects Data stops Projects and closes the window while the switch stays
    /// on, so the window cannot open again until Projects runs anew.
    @Test(.timeLimit(.minutes(1))) func theWindowCannotOpenWhileADeleteRuns() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        var windowCloses = 0
        runtime.closeWindow = { windowCloses += 1 }
        runtime.windowOpened()
        let (closing, closed) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        projects.closeBeforeDelete = {
            await runtime.closeBeforeDelete()
            closed.yield()
            for await _ in released { break }
        }
        let deleting = Task { await projects.deleteAllData() }
        for await _ in closing { break }
        #expect(projects.isOn)
        #expect(projects.isDeleting)
        #expect(windowCloses == 1)
        #expect(!runtime.isWindowOpen)
        #expect(!runtime.canOpenWindow)
        release.yield()
        await deleting.value
        #expect(runtime.canOpenWindow)
        try await waitUntil { runtime.phase == .on }
        // The delete at off must not wait for a release again.
        projects.closeBeforeDelete = { await runtime.closeBeforeDelete() }
        await projects.turnOff(keepingData: false)
        try await waitUntil { runtime.phase == .off }
    }

    /// A window opened before Projects started closes when Projects turns off, also when
    /// the start failed, so it never stays open with Projects off.
    @Test func aWindowOpenAfterAFailedStartClosesWhenProjectsTurnsOff() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = make(openFails: true)
        var closed = 0
        runtime.closeWindow = { closed += 1 }
        runtime.windowOpened()
        runtime.follow()
        try await waitUntil { runtime.phase == .failed }
        #expect(runtime.isWindowOpen)
        #expect(closed == 0)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(closed == 1)
        #expect(!runtime.isWindowOpen)
        #expect(model.holds.value == 0)
    }

    /// Requests that start while the tokenizer loads wait for that one load, and the next
    /// window loads it again.
    @Test func requestsThatStartTogetherShareOneTokenizerLoad() async throws {
        defer { cleanUp() }
        let held = HeldWork()
        tokenizer.holds(held)
        let (runtime, projects, _) = try await started(countsTokens: true)
        runtime.windowOpened()
        let first = Task { _ = try await runtime.reviseService(startedAt: Self.today) }
        let second = Task { _ = try await runtime.reviseService(startedAt: Self.today) }
        try await waitUntil { held.began == 1 }
        try await Task.sleep(for: .milliseconds(50))
        held.release()
        try await first.value
        try await second.value
        #expect(tokenizer.count == 1)
        _ = try await runtime.reviseService(startedAt: Self.today)
        #expect(tokenizer.count == 1)
        runtime.windowClosed()
        runtime.windowOpened()
        _ = try await runtime.reviseService(startedAt: Self.today)
        #expect(tokenizer.count == 2)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A tokenizer load that failed is not kept, so the next request loads again.
    @Test func aFailedTokenizerLoadIsTriedAgain() async throws {
        defer { cleanUp() }
        tokenizer.failsNext()
        let (runtime, projects, _) = try await started(countsTokens: true)
        runtime.windowOpened()
        await #expect(throws: TestError.self) {
            _ = try await runtime.reviseService(startedAt: Self.today)
        }
        _ = try await runtime.reviseService(startedAt: Self.today)
        #expect(tokenizer.count == 2)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Counts the loads of the tokenizer, and holds them or fails the next one when a test
    /// asks.
    final class TokenizerLoads: Sendable {
        private struct State {
            var count = 0
            var failsNext = false
            var held: HeldWork?
        }

        private let state = Mutex(State())

        nonisolated var count: Int {
            state.withLock { $0.count }
        }

        nonisolated func holds(_ held: HeldWork) {
            state.withLock { $0.held = held }
        }

        nonisolated func failsNext() {
            state.withLock { $0.failsNext = true }
        }

        nonisolated func load(_ counter: (@Sendable (String) -> Int)?) async throws -> (@Sendable (String) -> Int)? {
            let (fails, held) = state.withLock { state in
                state.count += 1
                defer { state.failsNext = false }
                return (state.failsNext, state.held)
            }
            await held?.run()
            if fails {
                throw TestError()
            }
            return counter
        }
    }

    // MARK: The scan

    @Test func theScanWaitsForTheConfirmMailAndThePermission() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        // Not confirmed: nothing is asked.
        mail.update {
            $0.isRunning = true
            $0.permission = .notAsked
        }
        runtime.mailRunningChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runtime.isScanning)
        #expect(mail.permissionAsks.isEmpty)

        // Confirmed, but macOS has not asked the user yet.
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { mail.permissionAsks.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runtime.isScanning)

        // Mail quit, then the user allowed Orra in Settings and opened Mail again.
        mail.update { $0.isRunning = false }
        runtime.mailRunningChanged()
        #expect(!runtime.mailIsRunning)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
        }
        runtime.mailRunningChanged()
        try await waitUntil { runtime.isScanning }
        // The check never shows the prompt.
        #expect(!mail.permissionAsks.contains(true))

        // Forgetting the confirm stops the scan.
        choice.forget()
        try await waitUntil { !runtime.isScanning }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A permission check that gets no answer in time starts the scan, whose events never
    /// show the prompt. A refusal does not.
    @Test func aPermissionCheckWithoutAnAnswerStartsTheScan() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .denied
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { mail.permissionAsks.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runtime.isScanning)
        mail.update { $0.permission = .unknown }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.isScanning }
        #expect(mail.permissionAsks == [false, false])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test(.timeLimit(.minutes(1)))
    func whatTheScanSavesIsSorted() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        try await runtime.add(harbor)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [
                FakeMail.Message(id: 2, messageID: "b@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "The quote", text: "Could you check the quote by Friday?"),
                FakeMail.Message(id: 1, messageID: "a@kiln.example", from: "Ana Ruiz <ana@kiln.example>", subject: "Lunch", text: "Lunch on Thursday?"),
            ]
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.isScanning }
        try await waitUntil { runtime.mailChanges > 0 && mail.calls.contains("source") }
        let filed = try await listed(.project(harbor.id), runtime) { !$0.isEmpty }
        #expect(filed.map(\.messageID) == ["b@harbor.example"])
        #expect(filed.first?.level == .sure)
        // The line under the subject is its first sentence until it is explained.
        #expect(filed.first?.summary == "Could you check the quote by Friday?")
        #expect(runtime.mailReference(for: "b@harbor.example") == MailMessageRef(id: 2, mailbox: .inbox))
        // The batch may sort it after the one filed above.
        try await waitUntilListed("a@kiln.example", in: .needsProject, runtime) { $0.level != nil }
        #expect(try await runtime.list(.needsProject).map(\.messageID) == ["a@kiln.example"])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewProjectSortsNeedsAProjectAgain() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("c@harbor.example", from: "lu@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        let waiting = try await listed(.needsProject, runtime) { $0.first?.level != nil }
        #expect(waiting.map(\.messageID) == ["c@harbor.example"])

        let harbor = Project(name: "Harbor", domains: ["harbor.example"])
        try await runtime.add(harbor)
        let filed = try await listed(.project(harbor.id), runtime) { !$0.isEmpty }
        #expect(filed.map(\.messageID) == ["c@harbor.example"])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail the user moved to Needs a Project never takes the place of mail that sorting may
    /// still file: newer moves there, more than a batch and a page, leave the older emails
    /// to sort again when a project comes.
    @Test(.timeLimit(.minutes(1)))
    func sortingAgainLooksPastTheUsersMoves() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        runtime.listPage = 2
        runtime.resortBatchLimit = 2
        let store = try #require(runtime.running?.store)
        let older = (0..<3).map { "h\($0)@harbor.example" }
        let moved = (0..<5).map { "k\($0)@kiln.example" }
        try await store.save(
            older.enumerated().map { index, id in Self.message(id, from: "mei@harbor.example", day: Double(index) / 10) }
                + moved.enumerated().map { index, id in Self.message(id, from: "kai@kiln.example", day: 1 + Double(index) / 10) },
            ownAddresses: [Self.own], at: Self.today)
        var sorted = 0
        for id in older where try await store.saveDecision(SortingDecision(project: nil, level: .unsure, reasons: [.noSignal]), for: id) {
            sorted += 1
        }
        var movedThere = 0
        for id in moved where try await store.move(id, to: nil) {
            movedThere += 1
        }
        #expect(sorted == older.count && movedThere == moved.count)

        let harbor = Project(name: "Harbor", domains: ["harbor.example"])
        try await runtime.add(harbor)
        await runtime.untilResorted()
        let filed = try Set(await runtime.list(.project(harbor.id)).map(\.messageID))
        #expect(filed == Set(older))
        // The moves stay where the user put them.
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_messages WHERE project IS NULL AND moved_by_user = 1") == [[.integer(5)]])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Sorting again asks the model only about the newest emails a change reaches, a page of
    /// the list, and the user's moves take none of those places. The rules alone sort the
    /// older ones, which stay as they were unless the rules file them, so they never wait
    /// for the model. With the window closed, the likely filings of the page keep their
    /// place and wait for the model.
    @Test(.timeLimit(.minutes(1)))
    func sortingAgainAsksTheModelOnlyAboutTheNewestEmails() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        runtime.listPage = 2
        runtime.resortBatchLimit = 2
        let store = try #require(runtime.running?.store)
        // Oldest first: three emails no rule files, one of Harbor's domain, the two newest
        // that sorting may file, and a move of the user.
        let older = (0..<3).map { "o\($0)@kiln.example" }
        let newest = (0..<2).map { "n\($0)@kiln.example" }
        try await store.save(
            older.enumerated().map { index, id in Self.message(id, from: "kai@kiln.example", day: Double(index) / 10) }
                + [Self.message("h@harbor.example", from: "mei@harbor.example", day: 0.3)]
                + newest.enumerated().map { index, id in Self.message(id, from: "kai@kiln.example", day: 0.5 + Double(index) / 10) }
                + [Self.message("moved@kiln.example", from: "kai@kiln.example", day: 1)],
            ownAddresses: [Self.own], at: Self.today)
        // The sorting of new mail reads them first, with no project yet, so none of its
        // passes is left to change the decisions the test gives them.
        runtime.requestSort()
        _ = try await listed(.needsProject, runtime) { $0.count == 7 && $0.allSatisfy { $0.level != nil } }
        let modelSaidNone = SortingDecision(project: nil, level: .unsure, reasons: [.modelSaidNone, .noSignal])
        var sorted = 0
        for id in older + ["h@harbor.example"] + newest where try await store.saveDecision(modelSaidNone, for: id) {
            sorted += 1
        }
        #expect(sorted == 6)
        #expect(try await store.move("moved@kiln.example", to: nil))

        runtime.windowOpened()
        let harbor = Project(name: "Harbor", domains: ["harbor.example"])
        try await runtime.add(harbor)
        await runtime.untilResorted()
        #expect(model.jobs.value == newest.count)
        let filed = try await runtime.list(.project(harbor.id))
        #expect(Set(filed.map(\.messageID)) == Set(newest + ["h@harbor.example"]))
        #expect(filed.allSatisfy { $0.level == ($0.messageID == "h@harbor.example" ? .sure : .likely) })
        let left = try await runtime.list(.needsProject)
        #expect(Set(left.map(\.messageID)) == Set(older + ["moved@kiln.example"]))
        #expect(left.filter { older.contains($0.messageID) }.allSatisfy { $0.reasons == modelSaidNone.reasons })

        // With the window closed, the two likely filings, now the newest the change reaches,
        // keep their place and wait for the model, and the older ones stay as they were.
        runtime.windowClosed()
        try await runtime.add(Project(name: "Garden"))
        await runtime.untilResorted()
        #expect(model.jobs.value == newest.count)
        let reasons = try Dictionary(uniqueKeysWithValues: await runtime.list(.needsProject).map { ($0.messageID, $0.reasons) })
        #expect(older.allSatisfy { reasons[$0] == modelSaidNone.reasons })
        #expect(try await runtime.list(.project(harbor.id)).filter { $0.level == .likely }.map(\.messageID).sorted() == newest)
        #expect(try await store.waiting().map(\.messageID) == newest)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func twoMovesOfOneSenderOfferARuleThatTheProjectKeeps() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let harbor = Project(name: "Harbor")
        let garden = Project(name: "Garden")
        try await runtime.add(harbor)
        try await runtime.add(garden)
        let store = try #require(runtime.running?.store)
        try await store.save([
            Self.message("d1@kiln.example", from: "ana@kiln.example", day: 1),
            Self.message("d2@kiln.example", from: "ana@kiln.example", day: 2),
        ], ownAddresses: [Self.own], at: Self.today)
        #expect(await runtime.move("d1@kiln.example", to: garden.id) == nil)
        let offer = try #require(await runtime.move("d2@kiln.example", to: garden.id))
        #expect(offer == SortingService.RuleOffer(project: garden.id, rule: .sender("ana@kiln.example")))
        // A third email of hers waits in Needs a Project, since the model is not there.
        try await store.save([Self.message("d3@kiln.example", from: "ana@kiln.example", day: 2.5)], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("d3@kiln.example", in: .needsProject, runtime) { $0.level != nil }

        try await runtime.accept(offer)
        #expect(runtime.projectList.first { $0.id == garden.id }?.rules == [Project.Rule(kind: .sender, value: "ana@kiln.example")])
        // The rule files her mail in Needs a Project too.
        try await waitUntilListed("d3@kiln.example", in: .project(garden.id), runtime) { $0.level == .sure }
        #expect(try await runtime.list(.project(garden.id)).count == 3)

        try await runtime.forget(garden.id)
        #expect(runtime.projectList.map(\.id) == [harbor.id])
        #expect(try await runtime.list(.project(garden.id)).isEmpty)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Remove Rule on the project page: the rule is gone for good, mail read after it is
    /// sorted without it, and the mail it filed stays in the project.
    @Test(.timeLimit(.minutes(1)))
    func aRemovedRuleFilesNoNewMailAndLeavesWhatItFiled() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let rule = Project.Rule(kind: .sender, value: "ana@kiln.example")
        let garden = Project(name: "Garden", rules: [rule])
        try await runtime.add(garden)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("g1@kiln.example", from: "ana@kiln.example", day: 1)], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("g1@kiln.example", in: .project(garden.id), runtime) { $0.level == .sure }

        try await runtime.removeRule(rule, from: garden.id)
        #expect(runtime.projectList.first { $0.id == garden.id }?.rules == [])
        let saved = ProjectList(storage: storage)
        try await saved.load()
        #expect(saved.project(garden.id)?.rules == [])
        await #expect(throws: ProjectsRuntime.Failure.unknownProject) {
            try await runtime.removeRule(rule, from: UUID())
        }

        // Her next email waits in Needs a Project, since the model is not there to agree
        // with the one vote left, that she wrote in the project before.
        try await store.save([Self.message("g2@kiln.example", from: "ana@kiln.example", day: 2)], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("g2@kiln.example", in: .needsProject, runtime) { $0.level != nil }
        #expect(try await runtime.list(.project(garden.id)).map(\.messageID) == ["g1@kiln.example"])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Unticking a mailbox stops the pass that reads it, since a pass fixes its mailboxes
    /// when it begins. Ticking one more lets the pass go on.
    @Test func aMailboxTheUserUnticksIsNotReadFurther() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [FakeMail.Message(id: 1, messageID: "a@kiln.example", from: "Ana Ruiz <ana@kiln.example>", subject: "Lunch", text: "Lunch on Thursday?")]
            $0.sourceBlocks = true
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { mail.calls.contains("source") }
        choice.choose([.inbox, FakeMail.clients])
        try await Task.sleep(for: .milliseconds(100))
        #expect(mail.sourcesCancelled == 0)

        choice.choose([FakeMail.clients])
        try await waitUntil { mail.sourcesCancelled == 1 }
        // The scan starts again with the choice as it is now.
        try await waitUntil { runtime.isScanning }
        #expect(mail.calls.filter { $0 == "source" }.count == 1)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A linked name the choice does not hold makes Projects read Mail's mailbox names once
    /// since it started. One Mail does not list stays missing, for the project page.
    @Test func mailboxNamesAreReadOnceForALinkedMailbox() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        try await runtime.add(Project(name: "Harbor", mailboxes: ["Work/Clients/Harbor", "Work/Gone"]))
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.selection = [MailMessageRef(id: 7, mailbox: FakeMail.archive)]
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.missingMailboxes == ["Work/Gone"] }
        #expect(await runtime.messageSelectedInMail() == .notInChosenMailbox)
        #expect(mail.calls.filter { $0 == "mailboxes" }.count == 1)
        // The user's click in the project setup reads them again.
        _ = try await runtime.mailboxes()
        #expect(mail.calls.filter { $0 == "mailboxes" }.count == 2)
        try await runtime.update(Project(id: runtime.projectList[0].id, name: "Harbor", mailboxes: ["Work/Clients/Harbor"]))
        #expect(runtime.missingMailboxes.isEmpty)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: Sorting again after a change of the projects

    /// Mail read with no project, a first project that takes it as the model's guess, and
    /// later the project it belongs to, as in the round two test. The later project takes
    /// it back, and the guess never counts as people seen in the first.
    @Test(.timeLimit(.minutes(1)))
    func aNewProjectTakesBackTheMailTheModelFiledInAnother() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        let store = try #require(runtime.running?.store)
        // The user's reply to Kai's first email.
        var reply = Self.message("r1@studio.example", from: Self.own, day: 0.5)
        reply.to = [MailStore.Person(address: "kai@kiln.example")]
        reply.inReplyTo = ["k1@kiln.example"]
        reply.references = ["k1@kiln.example"]
        try await store.save([
            Self.message("k1@kiln.example", from: "kai@kiln.example"), reply,
            Self.message("k2@kiln.example", from: "kai@kiln.example", day: 1),
        ], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        _ = try await listed(.needsProject, runtime) { $0.count == 3 && $0.allSatisfy { $0.level != nil } }
        runtime.windowOpened()

        let alder = Project(name: "Alder")
        try await runtime.add(alder)
        await runtime.untilResorted()
        let guessed = try Dictionary(uniqueKeysWithValues: await runtime.list(.project(alder.id)).map { ($0.messageID, $0) })
        #expect(guessed["k1@kiln.example"]?.level == .likely)
        #expect(guessed["r1@studio.example"]?.reasons == [.thread])
        // Neither the guess of k1 nor the reply under it is people seen of Alder.
        #expect(guessed["k2@kiln.example"]?.level == .likely)
        #expect(guessed["k2@kiln.example"]?.reasons == [.model])

        let birch = Project(name: "Birch", people: [Project.Person(name: "Kai Moss", address: "kai@kiln.example")])
        try await runtime.add(birch)
        await runtime.untilResorted()
        let filed = try await runtime.list(.project(birch.id))
        #expect(Set(filed.map(\.messageID)) == ["k1@kiln.example", "r1@studio.example", "k2@kiln.example"])
        // The user wrote r1 to a person Birch lists.
        #expect(filed.allSatisfy { $0.level == .sure && $0.reasons == ($0.messageID == "r1@studio.example" ? [.thread, .person] : [.person]) })
        #expect(try await runtime.list(.project(alder.id)).isEmpty)
        // The rules alone took them back.
        #expect(model.jobs.value == 2)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A person removed from a project takes their mail out of it, unless another setting or
    /// a thread files it there. The mail waits for the model in Needs a Project, and its own
    /// filing no longer counts as people seen in the project it left.
    @Test(.timeLimit(.minutes(1)))
    func removingAPersonSendsTheirMailBackToNeedsAProject() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        try await runtime.add(Project(name: "Alder"))
        let birch = Project(name: "Birch", people: [Project.Person(name: "Sam Okafor", address: "sam@post.example")])
        try await runtime.add(birch)
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("s1@post.example", from: "sam@post.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("s1@post.example", in: .project(birch.id), runtime) { $0.level == .sure }

        try await runtime.update(Project(id: birch.id, name: "Birch"))
        await runtime.untilResorted()
        #expect(try await runtime.list(.project(birch.id)).isEmpty)
        let waiting = try #require(try await runtime.list(.needsProject).first(where: { $0.messageID == "s1@post.example" }))
        #expect(waiting.reasons == [.waitingForModel, .noSignal])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Sorting again never moves mail the user moved, or mail whose explanation holds a
    /// draft, which the user may have changed.
    @Test(.timeLimit(.minutes(1)))
    func sortingAgainKeepsTheUsersMovesAndDrafts() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let alder = Project(name: "Alder")
        try await runtime.add(alder)
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        let ids = ["e1@kiln.example", "e2@kiln.example", "e3@kiln.example"]
        try await store.save(ids.enumerated().map { day, id in Self.message(id, from: "kai@kiln.example", day: Double(day)) }, ownAddresses: [Self.own], at: Self.today)
        #expect(try await store.saveDecision(SortingDecision(project: nil, level: .unsure, reasons: [.noSignal]), for: ids[0]))
        #expect(try await store.save(MailStoreTests.explanation(ids[0], project: nil), at: Self.today))
        #expect(try await store.saveDecision(SortingDecision(project: alder.id, level: .likely, reasons: [.model]), for: ids[1]))
        #expect(try await store.save(MailStoreTests.explanation(ids[1], project: alder.id), at: Self.today))
        let typed = MailStore.EditedDraft(text: "Hi Kai, the tiles are ready.", editedFrom: "key")
        #expect(try await store.save(typed, for: ids[1], at: Self.today))
        #expect(try await store.move(ids[2], to: alder.id))

        try await runtime.add(Project(name: "Birch", people: [Project.Person(name: "Kai Moss", address: "kai@kiln.example")]))
        await runtime.untilResorted()
        #expect(await runtime.place(of: ids[0]) == .needsProject)
        #expect(await runtime.explanation(for: ids[0]) != nil)
        #expect(await runtime.place(of: ids[1]) == .project(alder.id))
        #expect(await runtime.editedDraft(of: ids[1]) == typed)
        let moved = try #require(await runtime.listed(ids[2]))
        #expect(moved.project == alder.id && moved.movedByUser)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Sorting again asks the model only where a change can alter its answer, here where a
    /// project the prompt shows changed. A fifth project, out of the three the prompt shows,
    /// and a Save with no change ask nothing.
    @Test(.timeLimit(.minutes(1)))
    func sortingAgainAsksTheModelOnlyWhereAChangeCanAlterItsAnswer() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        let alder = Project(name: "Alder")
        for project in [alder, Project(name: "Birch"), Project(name: "Cedar"), Project(name: "Dogwood")] {
            try await runtime.add(project)
        }
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        try await store.save([
            Self.message("e1@kiln.example", from: "kai@kiln.example"),
            Self.message("e2@kiln.example", from: "kai@kiln.example", day: 1),
        ], ownAddresses: [Self.own], at: Self.today)
        #expect(try await store.saveDecision(SortingDecision(project: alder.id, level: .likely, reasons: [.model]), for: "e1@kiln.example"))
        #expect(try await store.saveDecision(SortingDecision(project: nil, level: .unsure, reasons: [.modelSaidNone, .noSignal]), for: "e2@kiln.example"))
        runtime.windowOpened()

        try await runtime.add(Project(name: "Elm"))
        await runtime.untilResorted()
        #expect(model.jobs.value == 0)
        try await runtime.update(alder)
        await runtime.untilResorted()
        #expect(model.jobs.value == 0)
        // Its own words change the prompt of both emails.
        var described = alder
        described.description = "Tiles for the floor of the hall."
        try await runtime.update(described)
        await runtime.untilResorted()
        #expect(model.jobs.value == 2)
        #expect(await runtime.place(of: "e2@kiln.example") == .project(alder.id))
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A change that ends a run under way leaves nothing out: the next run sorts by both
    /// changes, so it asks again about what the run it ended was asking.
    @Test(.timeLimit(.minutes(1)))
    func aChangeThatEndsARunCarriesItsMailToTheNext() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        let alder = Project(name: "Alder")
        for project in [alder, Project(name: "Birch"), Project(name: "Cedar"), Project(name: "Dogwood")] {
            try await runtime.add(project)
        }
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e1@kiln.example", from: "kai@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        #expect(try await store.saveDecision(SortingDecision(project: alder.id, level: .likely, reasons: [.model]), for: "e1@kiln.example"))
        runtime.windowOpened()

        model.blocks.withLock { $0 = true }
        var described = alder
        described.description = "Tiles for the floor of the hall."
        try await runtime.update(described)
        try await waitUntil { model.jobs.value == 1 }
        model.blocks.withLock { $0 = false }
        // A fifth project alone asks nothing, see
        // sortingAgainAsksTheModelOnlyWhereAChangeCanAlterItsAnswer.
        try await runtime.add(Project(name: "Elm"))
        await runtime.untilResorted()
        #expect(model.ended.value == 1)
        #expect(model.jobs.value == 2)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Forget Project sorts again the mail the project reached, such as mail that it and
    /// another project, which list the same person, left to the model.
    @Test(.timeLimit(.minutes(1)))
    func forgettingAProjectSortsAgainWhatItReached() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let kai = Project.Person(name: "Kai Moss", address: "kai@kiln.example")
        let alder = Project(name: "Alder", people: [kai])
        let birch = Project(name: "Birch", people: [kai])
        try await runtime.add(alder)
        try await runtime.add(birch)
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("k1@kiln.example", from: "kai@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("k1@kiln.example", in: .needsProject, runtime) { $0.reasons == [.waitingForModel, .signalsDisagree] }

        try await runtime.forget(birch.id)
        await runtime.untilResorted()
        let filed = try await runtime.list(.project(alder.id))
        #expect(filed.map(\.messageID) == ["k1@kiln.example"])
        #expect(filed.first?.level == .sure && filed.first?.reasons == [.person])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The email the user reads stays in view when sorting moves it to another list, with
    /// its new project, and the list it left no longer holds it.
    @Test(.timeLimit(.minutes(1)))
    func theEmailTheUserReadsStaysInViewWhenSortingMovesIt() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let alder = Project(name: "Alder", domains: ["kiln.example"])
        try await runtime.add(alder)
        await runtime.untilResorted()
        let store = try #require(runtime.running?.store)
        let id = "k1@kiln.example"
        try await store.save([Self.message(id, from: "kai@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed(id, in: .project(alder.id), runtime) { $0.level == .sure }
        let window = ProjectsWindowModel(runtime: runtime)
        window.place = .project(alder.id)
        await window.reload()
        window.selectedMessageID = id
        #expect(window.selectedEmail?.project == alder.id)

        let birch = Project(name: "Birch", people: [Project.Person(name: "Kai Moss", address: "kai@kiln.example")])
        try await runtime.add(birch)
        await runtime.untilResorted()
        await window.reload()
        #expect(window.place == .project(alder.id))
        #expect(window.selectedEmail?.messageID == id)
        #expect(window.selectedEmail?.project == birch.id)
        #expect(window.selectedEmail?.level == .sure)
        #expect(window.rows.isEmpty)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: What the window says about mail

    /// Each batch the scan saves shows in the window at once, not sorted yet, also while
    /// sorting still waits for the model on mail saved before.
    @Test(.timeLimit(.minutes(1)))
    func eachSavedBatchShowsBeforeSortingEnds() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        model.blocks.withLock { $0 = true }
        let (runtime, projects, choice) = try await started(installed: Installed(true))
        try await runtime.add(Project(name: "Harbor"))
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        // The window holds the model, so sorting asks it, and it does not answer.
        runtime.windowOpened()
        try await waitUntil { model.jobs.value == 1 }
        let changes = runtime.mailChanges
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.mailChanges > changes }
        let saved = try #require(try await runtime.list(.needsProject).first { $0.messageID == Self.lunch.messageID })
        #expect(saved.level == nil)
        #expect(model.jobs.value == 1)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// While the cleanup model is not on this Mac, a line under the list says so: its
    /// download with a spinner, the check of its files, or Settings… while it is missing,
    /// where it downloads. Nothing once it is on this Mac, or while Projects is off.
    @Test func theWindowSaysWhileTheModelIsNotOnThisMac() async throws {
        defer { cleanUp() }
        let download = Download()
        let (runtime, projects, _) = try await started(download: download)
        #expect(Lines.modelLine(runtime: runtime) == nil)
        download.status = .downloading(bytes: 1_525_000_000, total: 3_050_000_000)
        let downloading = try #require(Lines.modelLine(runtime: runtime))
        #expect(downloading.text == CleanupLabels.progress(bytes: 1_525_000_000, total: 3_050_000_000))
        #expect(downloading.text.hasPrefix("Downloading the cleanup model: 50% of "))
        #expect(downloading.isActivity)
        #expect(downloading.action == nil)
        download.status = .verifying
        #expect(Lines.modelLine(runtime: runtime) == Line(text: "Checking the downloaded files…", isActivity: true))
        download.status = .missing
        #expect(Lines.modelLine(runtime: runtime) == Line(text: "The cleanup model is not on this Mac yet. Download it in Projects Settings to explain mail.", action: .settings))
        await projects.turnOff(keepingData: false)
        try await waitUntil { runtime.phase == .off }
        #expect(Lines.modelLine(runtime: runtime) == nil)
    }

    /// The window says why no mail comes in: no mailbox chosen, Mail not open, or Orra not
    /// allowed to control Mail, each with its way out. A notice of Explain Message Selected
    /// in Mail that says the same shows once.
    @Test func theWindowSaysWhyNoMailComesIn() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        #expect(problems(runtime) == [Line(text: "Projects reads no mail yet. Choose its mailboxes in Settings.", action: .settings)])
        choice.choose([.inbox])
        choice.confirm()
        #expect(problems(runtime) == [Line(text: "Mail is not open. Projects reads new mail while Mail runs.", action: .openMail)])

        mail.update {
            $0.isRunning = true
            $0.permission = .denied
        }
        runtime.mailRunningChanged()
        try await waitUntil { runtime.scanState == .notAllowed }
        #expect(!runtime.isScanning)
        let notAllowed = Line(text: "Orra is not allowed to read Mail yet. Allow it in Settings.", action: .settings)
        #expect(problems(runtime) == [notAllowed])
        #expect(Lines.lines(runtime: runtime, notice: .selection(.notAllowed)).isEmpty)
        #expect(!Lines.leadsToSettings(runtime: runtime, notice: .selection(.notAllowed)))

        // Allowed in Settings: the scan starts, and the line goes.
        mail.update { $0.permission = .allowed }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.isScanning }
        #expect(!Lines.mailLines(runtime: runtime).contains(notAllowed))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A pass that reads the mailboxes back to the days says so, with the emails it saved so
    /// far, and the line goes when the pass ends.
    @Test func aPassThatReadsBackSaysSoWithItsCount() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
            $0.holds = ["source"]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { mail.calls.contains("source") }
        #expect(runtime.scanState == .reading(saved: 0))
        #expect(Lines.mailLines(runtime: runtime) == [Line(text: "Reading mail…", isActivity: true)])
        // Mail gives the message. The pass counts the mailbox again at its end, which waits.
        mail.update { $0.holds = ["count"] }
        try await waitUntil { runtime.scanState == .reading(saved: 1) }
        #expect(Lines.mailLines(runtime: runtime).first == Line(text: "Reading mail… 1 email read.", isActivity: true))
        mail.update { $0.holds = [] }
        try await waitUntil { runtime.scanState == nil }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail that does not answer in time says so, and Try Again asks it at once, rather
    /// than after the longer wait, an hour in these tests.
    @Test func slowMailSaysSoAndTryAgainAsksAtOnce() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
            $0.failure = .timedOut
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.scanState == .mailIsSlow }
        #expect(problems(runtime) == [Line(text: "Mail is slow to answer. Projects tries again later.", action: .tryAgain)])

        mail.update { $0.failure = nil }
        runtime.readAgain()
        try await waitUntilListed(Self.lunch.messageID, in: .needsProject, runtime) { _ in true }
        try await waitUntil { runtime.scanState == nil }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail the store could not save says so, and Try Again reads it again, since the scan
    /// reads the mailboxes back to the days once it starts again.
    @Test func mailThatCouldNotBeSavedSaysSoAndTryAgainReadsIt() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let database = try #require(runtime.running?.database)
        // New mail cannot be saved, as on a full disk, while reading goes on.
        try await database.execute("CREATE TEMP TRIGGER no_new_mail BEFORE INSERT ON mail_messages BEGIN SELECT RAISE(ABORT, 'full'); END")
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.scanState == .failed }
        #expect(problems(runtime) == [Line(text: "Some mail could not be read.", action: .tryAgain)])
        #expect(try await runtime.list(.needsProject).isEmpty)

        try await database.execute("DROP TRIGGER no_new_mail")
        runtime.readAgain()
        try await waitUntilListed(Self.lunch.messageID, in: .needsProject, runtime) { _ in true }
        try await waitUntil { runtime.scanState == nil }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A message Mail gives with no source, as it may before it downloaded its body, ends no
    /// pass. The window still says that some mail could not be read, with Try Again, in
    /// place of No Mail. The next pass reads the inbox back for it, and the line stays until
    /// that pass ends, so it does not change each minute while Mail cannot give it.
    @Test func mailThatMailCannotGiveSaysSoUntilAPassReadsIt() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
            $0.withoutSource = [Self.lunch.id]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { runtime.scanState == .failed }
        #expect(problems(runtime) == [Line(text: "Some mail could not be read.", action: .tryAgain)])
        #expect(try await runtime.list(.needsProject).isEmpty)

        // The next pass, as the scan runs each minute, gets the source and waits there.
        let scan = try #require(runtime.running?.scan)
        mail.clearCalls()
        mail.update {
            $0.withoutSource = []
            $0.holds = ["source"]
        }
        let next = Task { await scan.scan() }
        try await waitUntil { mail.calls.contains("source") }
        #expect(runtime.scanState == .failed)
        mail.update { $0.holds = [] }
        #expect(await next.value.saved == 1)
        #expect(runtime.scanState == nil)
        try await waitUntilListed(Self.lunch.messageID, in: .needsProject, runtime) { _ in true }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A chosen mailbox that Mail no longer has, as after a rename in Mail, fails at each
    /// pass. The window says so with Try Again, and a pass after that changes nothing while
    /// it reads, so the line does not turn into Reading mail… each minute.
    @Test func aMailboxMailNoLongerHasKeepsItsLineAtEachPass() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [Self.lunch]
            $0.gone = [FakeMail.archive]
        }
        runtime.mailRunningChanged()
        choice.choose([FakeMail.archive, .inbox])
        choice.confirm()
        try await waitUntil { runtime.scanState == .failed }
        try await waitUntilListed(Self.lunch.messageID, in: .needsProject, runtime) { _ in true }

        // The next pass, as the scan polls each minute, waits while Mail counts the inbox.
        let scan = try #require(runtime.running?.scan)
        mail.clearCalls()
        mail.update { $0.holds = ["count"] }
        let poll = Task { await scan.scan() }
        try await waitUntil { mail.calls.filter { $0 == "count" }.count == 2 }
        #expect(runtime.scanState == .failed)
        mail.update { $0.holds = [] }
        #expect(await poll.value.error == .notFound)
        #expect(problems(runtime) == [Line(text: "Some mail could not be read.", action: .tryAgain)])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Sorting says so while a batch runs, such as while the model sorts with the window
    /// open.
    @Test func sortingSaysSoWhileABatchRuns() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        model.blocks.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        try await runtime.add(Project(name: "Harbor"))
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        try await waitUntil { model.jobs.value == 1 }
        #expect(runtime.isSorting)
        #expect(Lines.mailLines(runtime: runtime).first == Line(text: "Sorting mail…", isActivity: true))
        runtime.windowClosed()
        try await waitUntil { !runtime.isSorting }
        #expect(Lines.mailLines(runtime: runtime).first?.isActivity == false)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A list the store cannot read is not an empty list: the window says so, with Try
    /// Again, in place of No Mail.
    @Test func aListTheStoreCannotReadIsNotEmpty() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.reload()
        #expect(!window.listFailed)
        // The store fails, as it would on a damaged disk.
        await runtime.running?.store.close()
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await runtime.list(.needsProject)
        }
        await window.reload()
        #expect(window.listFailed)
        #expect(window.rows.isEmpty)
        // Another list starts anew.
        window.place = .setAside
        #expect(!window.listFailed)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// What the window says once a pass ended: Mail slow to answer, Orra not allowed, mail
    /// that could not be read or saved, or nothing. Messages Mail could not give are mail
    /// that could not be read, also when it gave the others, and so is mail of a pass the
    /// store ended. A pass that Projects, the confirm or Mail ended says nothing, since the
    /// window says why on its own.
    @Test func whatEndedAPassIsWhatTheWindowSays() {
        typealias Pass = MailScan.Pass
        func state(_ error: MailBridgeError?, read: Int = 0, unreadable: Int = 0, saveFailed: Bool = false) -> ProjectsRuntime.ScanState? {
            ProjectsRuntime.scanState(after: Pass(read: read, unreadable: unreadable, error: error), saveFailed: saveFailed)
        }
        #expect(state(nil) == nil)
        #expect(state(nil, read: 3) == nil)
        #expect(state(.timedOut) == .mailIsSlow)
        #expect(state(.notAnswered(code: -609)) == .mailIsSlow)
        #expect(state(.denied) == .notAllowed)
        #expect(state(.notAsked) == .notAllowed)
        for error in [MailBridgeError.notFound, .changedWhileReading, .unexpectedReply, .failed(code: -10_000)] {
            #expect(state(error) == .failed)
        }
        #expect(state(.mailNotRunning) == nil)
        #expect(state(nil, saveFailed: true) == .failed)
        #expect(state(nil, unreadable: 2) == .failed)
        #expect(state(nil, read: 3, unreadable: 1) == .failed)
        #expect(state(.timedOut, unreadable: 1) == .mailIsSlow)
        #expect(state(.mailNotRunning, unreadable: 1) == nil)
        for skip in [Pass.Skip.off, .notConfirmed, .mailNotRunning] {
            #expect(ProjectsRuntime.scanState(after: Pass(skipped: skip, unreadable: 1), saveFailed: true) == nil)
        }
        #expect(ProjectsRuntime.scanState(after: Pass(skipped: .storeFailed), saveFailed: false) == .failed)
    }

    // MARK: Project folders

    /// The user adds a folder whose bookmark takes long to resolve, such as on a share that
    /// hangs and recovers, and removes it again before it resolved. The late resolve
    /// starts nothing: the folder is neither read nor watched.
    @Test func aStaleFolderResolveDoesNotStartARemovedFolder() async throws {
        defer { cleanUp() }
        let folders = StallingFolders()
        let (runtime, projects, _) = try await started(folders: folders)
        let alpha = try folder("Alpha", holding: "alpha.txt")
        var project = Project(name: "Harbor")
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id)?.isIndexing == false }

        project.folders = [try Project.bookmark(of: alpha)]
        try await runtime.update(project)
        try await waitUntil { folders.isHolding }
        project.folders = []
        try await runtime.update(project)
        folders.letGo()
        try await waitUntil { folders.heldResolveReturned }
        try await Task.sleep(for: .milliseconds(100))
        let index = try #require(runtime.running?.index)
        await index.waitUntilIdle()
        #expect(!folders.readFiles.contains("alpha.txt"))
        #expect(!folders.watchedFolders.joined().contains("Alpha"))
        #expect(runtime.indexReport(project.id)?.indexed == 0)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The same with a folder added next to it: the late resolve of the first folder alone
    /// does not drop the second one from the index.
    @Test func aStaleFolderResolveDoesNotDropAFolderAddedSince() async throws {
        defer { cleanUp() }
        let folders = StallingFolders()
        let (runtime, projects, _) = try await started(folders: folders)
        let alpha = try Project.bookmark(of: folder("Alpha", holding: "alpha.txt"))
        let beta = try Project.bookmark(of: folder("Beta", holding: "beta.txt"))
        var project = Project(name: "Harbor")
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id)?.isIndexing == false }

        project.folders = [alpha]
        try await runtime.update(project)
        try await waitUntil { folders.isHolding }
        project.folders = [alpha, beta]
        try await runtime.update(project)
        try await waitUntil { runtime.indexReport(project.id)?.indexed == 2 }
        folders.letGo()
        try await waitUntil { folders.heldResolveReturned }
        try await Task.sleep(for: .milliseconds(100))
        let index = try #require(runtime.running?.index)
        await index.waitUntilIdle()
        #expect(folders.watchedFolders.last == ["Alpha", "Beta"])
        #expect(runtime.indexReport(project.id)?.indexed == 2)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Projects starts with a saved project whose folder takes long to resolve, such as on
    /// a share that hangs. Turning Projects off does not wait for it, and once it resolves,
    /// the folder is neither read nor watched.
    @Test(.timeLimit(.minutes(1))) func aStalledFolderResolveDoesNotHoldUpTurningProjectsOff() async throws {
        defer { cleanUp() }
        let project = try await savedProjectWithAFolder()
        let folders = StallingFolders()
        let (runtime, projects, _) = make(folders: folders)
        runtime.follow()
        try await waitUntil { folders.isHolding }

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        folders.letGo()
        try await waitUntil { folders.heldResolveReturned }
        try await Task.sleep(for: .milliseconds(100))
        #expect(folders.readFiles.isEmpty)
        #expect(folders.watchedFolders.isEmpty)
        #expect(runtime.indexReport(project.id) == nil)
    }

    /// The same for Delete All Projects Data, which stops Projects first: it does not wait
    /// for the folder, and Projects starts again with no data while the folder still
    /// resolves.
    @Test(.timeLimit(.minutes(1))) func aStalledFolderResolveDoesNotHoldUpDeleteAll() async throws {
        defer { cleanUp() }
        let project = try await savedProjectWithAFolder()
        let folders = StallingFolders()
        let (runtime, projects, _) = make(folders: folders)
        runtime.follow()
        try await waitUntil { folders.isHolding }

        let deleted = Count()
        let deleting = Task {
            await projects.deleteAllData()
            deleted.add()
        }
        try await waitUntil { deleted.value == 1 }
        #expect(!projects.deleteFailed)
        try await waitUntil { runtime.phase == .on }
        #expect(runtime.projectList.isEmpty)
        folders.letGo()
        try await waitUntil { folders.heldResolveReturned }
        try await Task.sleep(for: .milliseconds(100))
        #expect(folders.readFiles.isEmpty)
        #expect(folders.watchedFolders.isEmpty)
        #expect(runtime.indexReport(project.id) == nil)
        await deleting.value
        await projects.turnOff(keepingData: false)
        try await waitUntil { runtime.phase == .off }
    }

    /// Turning Projects off and on again while the folder still resolves starts no other
    /// resolve of it, so a share that hangs holds one thread however often the user tries.
    /// Once it resolves, Projects as it runs now indexes the folder.
    @Test(.timeLimit(.minutes(1))) func aStalledFolderResolveServesTheNextStartsToo() async throws {
        defer { cleanUp() }
        let project = try await savedProjectWithAFolder()
        let folders = StallingFolders()
        let (runtime, projects, _) = make(folders: folders)
        runtime.follow()
        try await waitUntil { folders.isHolding }

        for _ in 0..<2 {
            await projects.turnOff(keepingData: true)
            try await waitUntil { runtime.phase == .off }
            projects.turnOn()
            try await waitUntil { runtime.phase == .on }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(folders.resolves == 1)
        #expect(folders.watchedFolders.isEmpty)
        folders.letGo()
        try await waitUntil { folders.watchedFolders == [["Alpha"]] }
        #expect(runtime.indexReport(project.id) != nil)
        #expect(folders.resolves == 1)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The email view reads where a project's folders are now: their real paths, as the
    /// index keeps its files. A project the list does not hold has none, and nothing is read
    /// while Projects is off.
    @Test func theFoldersOfAProjectResolveToTheirRealPaths() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let alpha = try folder("Alpha", holding: "alpha.txt")
        let project = Project(name: "Harbor", folders: [try Project.bookmark(of: alpha)])
        try await runtime.add(project)
        let real = URL(fileURLWithPath: try #require(FolderWalk.realPath(alpha.path)), isDirectory: true)
        let roots = try #require(await runtime.folderRoots(of: project.id))
        #expect(roots == ProjectsEmailFiles.Roots(folders: [real]))
        #expect(ProjectsEmailFiles.place(of: real.appending(path: "Drawings/plan.pdf"), in: roots) == .inFolder(name: "Alpha", path: ["Drawings"]))
        #expect(await runtime.folderRoots(of: UUID()) == ProjectsEmailFiles.Roots())
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(await runtime.folderRoots(of: project.id) == nil)
    }

    /// A folder whose bookmark finds nothing, such as one on a disk that is not connected,
    /// is not available, by the path its bookmark keeps, next to the folders that are there.
    /// So its files are not taken for files that left the project.
    @Test func aFolderWhoseBookmarkFindsNothingIsNotAvailable() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let alpha = try folder("Alpha", holding: "alpha.txt")
        let gone = try folder("Gone", holding: "gone.txt")
        let goneBookmark = try Project.bookmark(of: gone)
        let goneReal = URL(fileURLWithPath: try #require(FolderWalk.realPath(gone.path)), isDirectory: true)
        try FileManager.default.removeItem(at: gone)
        let project = Project(name: "Harbor", folders: [goneBookmark, try Project.bookmark(of: alpha)])
        try await runtime.add(project)
        let roots = try #require(await runtime.folderRoots(of: project.id))
        let alphaReal = URL(fileURLWithPath: try #require(FolderWalk.realPath(alpha.path)), isDirectory: true)
        #expect(roots == ProjectsEmailFiles.Roots(folders: [alphaReal], unavailable: [goneReal]))
        #expect(ProjectsEmailFiles.place(of: goneReal.appending(path: "Plans/plan.pdf"), in: roots) == .unavailable(name: "Gone", path: ["Plans"]))
        #expect(ProjectsEmailFiles.place(of: alphaReal.appending(path: "alpha.txt"), in: roots) == .inFolder(name: "Alpha", path: []))

        let only = Project(name: "Kiln", folders: [goneBookmark])
        try await runtime.add(only)
        #expect(await runtime.folderRoots(of: only.id) == ProjectsEmailFiles.Roots(unavailable: [goneReal]))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Projects turns off while the email view waits for a project's folder to resolve, such
    /// as on a share that hangs. Once it resolves, nothing reads the folder.
    @Test(.timeLimit(.minutes(1))) func aFolderIsNotReadOnceProjectsTurnedOffDuringItsResolve() async throws {
        defer { cleanUp() }
        let folders = StallingFolders()
        let (runtime, projects, _) = try await started(folders: folders)
        var project = Project(name: "Harbor")
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id)?.isIndexing == false }
        project.folders = [try Project.bookmark(of: folder("Alpha", holding: "alpha.txt"))]
        try await runtime.update(project)
        try await waitUntil { folders.isHolding }
        let reads = HeldReads(holds: false)
        runtime.readRealPath = { await reads.read($0) }

        let roots = Task { await runtime.folderRoots(of: project.id) }
        try await Task.sleep(for: .milliseconds(100))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        folders.letGo()
        #expect(await roots.value == nil)
        #expect(reads.started.isEmpty)
    }

    /// The email view reads the real path of a project's folders one at a time. When the
    /// first takes long, as on a share that hangs, and Projects turns off or the user takes
    /// the second folder out of the project meanwhile, the second is never read.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func theNextFolderIsNotReadOnceProjectsChangedDuringARead(_ removesFolder: Bool) async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let alpha = try Project.bookmark(of: folder("Alpha", holding: "alpha.txt"))
        var project = Project(name: "Harbor", folders: [alpha, try Project.bookmark(of: folder("Beta", holding: "beta.txt"))])
        try await runtime.add(project)
        let reads = HeldReads()
        runtime.readRealPath = { await reads.read($0) }

        let roots = Task { await runtime.folderRoots(of: project.id) }
        try await waitUntil { reads.isHolding }
        if removesFolder {
            project.folders = [alpha]
            try await runtime.update(project)
        } else {
            await projects.turnOff(keepingData: true)
            try await waitUntil { runtime.phase == .off }
        }
        reads.letGo()
        #expect(await roots.value == nil)
        #expect(reads.started == ["Alpha"])
        if removesFolder {
            await projects.turnOff(keepingData: true)
            try await waitUntil { runtime.phase == .off }
        }
    }

    /// The list closes while the email view reads the real path of a project's first
    /// folder, as on a share that hangs, so the task that asked is cancelled. The second
    /// folder is never read.
    @Test(.timeLimit(.minutes(1))) func theNextFolderIsNotReadOnceTheListCloses() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let project = Project(name: "Harbor", folders: [
            try Project.bookmark(of: folder("Alpha", holding: "alpha.txt")),
            try Project.bookmark(of: folder("Beta", holding: "beta.txt")),
        ])
        try await runtime.add(project)
        let reads = HeldReads()
        runtime.readRealPath = { await reads.read($0) }

        let roots = Task { await runtime.folderRoots(of: project.id) }
        try await waitUntil { reads.isHolding }
        roots.cancel()
        reads.letGo()
        #expect(await roots.value == nil)
        #expect(reads.started == ["Alpha"])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A folder the user renamed, then took out of reach, is not available under the name
    /// it had when Orra last found it too, not only under the one it had when the user added
    /// it.
    @Test func aRenamedFolderThatIsGoneIsNotAvailableUnderItsLastName() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let old = try folder("Old lobby", holding: "plan.txt")
        let bookmark = try Project.bookmark(of: old)
        let added = URL(fileURLWithPath: try #require(FolderWalk.realPath(old.path)), isDirectory: true)
        let renamed = root.appendingPathComponent("Harbor lobby", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed)
        let project = Project(name: "Harbor", folders: [bookmark])
        try await runtime.add(project)
        let real = URL(fileURLWithPath: try #require(FolderWalk.realPath(renamed.path)), isDirectory: true)
        #expect(await runtime.folderRoots(of: project.id) == ProjectsEmailFiles.Roots(folders: [real]))

        try FileManager.default.removeItem(at: renamed)
        let roots = try #require(await runtime.folderRoots(of: project.id))
        #expect(roots.folders.isEmpty)
        #expect(roots.unavailable.map(\.path) == [real.path, added.path])
        #expect(ProjectsEmailFiles.place(of: real.appending(path: "Drawings/plan.pdf"), in: roots) == .unavailable(name: "Harbor lobby", path: ["Drawings"]))
        #expect(ProjectsEmailFiles.place(of: added.appending(path: "plan.txt"), in: roots) == .unavailable(name: "Old lobby", path: []))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The user takes the folder out of the project while the email view waits for it to
    /// resolve. Once it resolves, nothing reads it, and the view gets the folders as they
    /// are now when it asks again.
    @Test(.timeLimit(.minutes(1))) func aFolderTheProjectNoLongerHoldsIsNotReadOnceItResolves() async throws {
        defer { cleanUp() }
        let folders = StallingFolders()
        let (runtime, projects, _) = try await started(folders: folders)
        var project = Project(name: "Harbor")
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id)?.isIndexing == false }
        project.folders = [try Project.bookmark(of: folder("Alpha", holding: "alpha.txt"))]
        try await runtime.update(project)
        try await waitUntil { folders.isHolding }
        let reads = HeldReads(holds: false)
        runtime.readRealPath = { await reads.read($0) }

        let roots = Task { await runtime.folderRoots(of: project.id) }
        try await Task.sleep(for: .milliseconds(100))
        project.folders = []
        try await runtime.update(project)
        folders.letGo()
        #expect(await roots.value == nil)
        #expect(reads.started.isEmpty)
        #expect(await runtime.folderRoots(of: project.id) == ProjectsEmailFiles.Roots())
        #expect(reads.started.isEmpty)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: The model

    @Test func sortingAsksTheModelOnlyWhileTheWindowHoldsIt() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("h@kiln.example", in: .needsProject, runtime) { $0.level == .unsure }
        #expect(model.jobs.value == 0)

        runtime.windowOpened()
        try await waitUntilListed("h@kiln.example", in: .project(harbor.id), runtime) { $0.level == .likely }
        #expect(model.jobs.value == 1)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func closingTheWindowEndsTheBackgroundJob() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        model.blocks.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true))
        try await runtime.add(Project(name: "Harbor"))
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        try await waitUntil { model.jobs.value == 1 }
        runtime.windowClosed()
        try await waitUntil { model.ended.value == 1 }
        #expect(model.holds.value == 0)
        // The email waits for the model in Needs a Project.
        try await waitUntilListed("h@kiln.example", in: .needsProject, runtime) { $0.level == .unsure }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The model is installed while the window is open: the mail that waits is sorted (#140).
    @Test func theModelArrivingWhileTheWindowIsOpenSortsTheMailThatWaits() async throws {
        defer { cleanUp() }
        let installed = Installed()
        let (runtime, projects, _) = try await started(installed: installed)
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        try await waitUntilListed("h@kiln.example", in: .needsProject, runtime) { $0.level == .unsure }
        #expect(model.jobs.value == 0)

        model.isThere.withLock { $0 = true }
        installed.value = true
        try await waitUntilListed("h@kiln.example", in: .project(harbor.id), runtime) { $0.level == .likely }
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The press of a key reaches the model work at once: the call under way gives way and
    /// runs again, see ProjectsModelQueue.dictationStarted.
    @Test func theKeyDownReachesTheModelWork() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        model.blocks.withLock { $0 = true }
        let keyDown = KeyDown()
        let (runtime, projects, _) = try await started(installed: Installed(true), keyDown: keyDown)
        #expect(keyDown.handlers.count == 1)
        try await runtime.add(Project(name: "Harbor"))
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("h@kiln.example", from: "ana@kiln.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        try await waitUntil { model.jobs.value == 1 }
        keyDown.press()
        try await waitUntil { model.ended.value == 1 && model.jobs.value == 2 }
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Text recognition waits for a dictation, Live Captions, a request of the user, memory
    /// pressure, Low Power Mode and heat, and says the first that holds, so a pause that
    /// passes soon is never hidden behind a lasting one.
    @Test func recognitionWaitsForEachPauseInItsOrder() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        #expect(runtime.recognitionPause() == nil)
        machine.isDictating = true
        model.captionsOn.withLock { $0 = true }
        #expect(runtime.recognitionPause() == .dictation)
        machine.isDictating = false
        #expect(runtime.recognitionPause() == .captions)
        model.captionsOn.withLock { $0 = false }

        let request = Task { try await runtime.userRequest { try await Task.sleep(for: .seconds(3_600)) } }
        try await waitUntil { runtime.userRequestCount == 1 }
        #expect(runtime.recognitionPause() == .request)
        request.cancel()
        try await waitUntil { runtime.userRequestCount == 0 }

        let memory = try #require(runtime.running?.memory)
        memory.update(.warning)
        #expect(runtime.recognitionPause() == .memory)
        memory.update(.normal)
        machine.power = ProjectsRuntime.PowerState(isLowPowerModeOn: true, isHot: true)
        #expect(runtime.recognitionPause() == .lowPower)
        machine.power = ProjectsRuntime.PowerState(isLowPowerModeOn: false, isHot: true)
        #expect(runtime.recognitionPause() == .heat)
        machine.power = ProjectsRuntime.PowerState()
        #expect(runtime.recognitionPause() == nil)
        #expect(FolderIndex.RecognitionPause.allCases.filter(\.isLasting) == [.memory, .lowPower, .heat])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The press of a key and the start of a request of the user stop the page recognition
    /// reads at once, so it never runs beside them.
    @Test func theKeyDownAndARequestStopThePageUnderWay() async throws {
        defer { cleanUp() }
        let hold = TextRecognitionTests.Hold()
        let keyDown = KeyDown()
        let (runtime, projects, _) = try await started(keyDown: keyDown, recognize: { _, _ in
            await hold.untilCancelled()
            return .success(RecognitionResult())
        })
        let folder = root.appendingPathComponent("Harbor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: folder.appendingPathComponent("sign.png"))
        try await runtime.add(Project(name: "Harbor", folders: [try Project.bookmark(of: folder)]))
        await hold.untilBegun()
        keyDown.press()
        #expect(hold.cancelled == 1)
        // Without a dictation under way the page is read again at once.
        await hold.untilBegun(2)
        let request = Task { try await runtime.userRequest { try await Task.sleep(for: .seconds(3_600)) } }
        try await waitUntil { hold.cancelled == 2 }
        request.cancel()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Turning Projects off ends an explanation under way, and waits for it before the
    /// files close. Without that the fake model's job would wait for an hour.
    @Test(.timeLimit(.minutes(1))) func turningOffEndsARequestOfTheUser() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true)
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        try await runtime.add(harbor)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("e@harbor.example", in: .project(harbor.id), runtime) { $0.level == .sure }
        runtime.windowOpened()
        model.blocks.withLock { $0 = true }
        let explaining = Task { try await runtime.explain("e@harbor.example") }
        try await waitUntil { model.jobs.value == 1 }
        #expect(runtime.userRequestCount == 1)

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        await #expect(throws: CancellationError.self) {
            _ = try await explaining.value
        }
        #expect(model.ended.value == 1)
        #expect(runtime.userRequestCount == 0)
        #expect(model.holds.value == 0)
    }

    // MARK: Search terms

    /// The first Explain of an email asks the model for search terms, a request of the user
    /// before the explanation's own, and saves them with the explanation. Explain Again
    /// searches with the saved ones and asks the model for the explanation only.
    @Test(.timeLimit(.minutes(1))) func explainAsksForTermsOnceAndThenUsesTheSavedOnes() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true)
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        try await runtime.add(harbor)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("e@harbor.example", in: .project(harbor.id), runtime) { $0.level == .sure }
        runtime.windowOpened()
        let before = model.jobs.value
        let first = try await runtime.explain("e@harbor.example")
        #expect(first.searchTerms == ["lamp", "fixture"])
        #expect(model.termsJobs.value == 1)
        #expect(model.jobs.value == before + 2)
        #expect(await runtime.explanation(for: "e@harbor.example")?.searchTerms == ["lamp", "fixture"])

        let again = try await runtime.explain("e@harbor.example")
        #expect(again.searchTerms == ["lamp", "fixture"])
        #expect(model.termsJobs.value == 1)
        #expect(model.jobs.value == before + 3)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// An answer without terms leaves the explanation as before terms: nothing is saved, so
    /// the next Explain asks again.
    @Test(.timeLimit(.minutes(1))) func anAnswerWithoutTermsLeavesTheExplanationAsBefore() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        model.terms.withLock { $0 = "I cannot find any terms." }
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true)
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        try await runtime.add(harbor)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("e@harbor.example", in: .project(harbor.id), runtime) { $0.level == .sure }
        runtime.windowOpened()
        let first = try await runtime.explain("e@harbor.example")
        #expect(first.searchTerms == nil)
        #expect(model.termsJobs.value == 1)
        _ = try await runtime.explain("e@harbor.example")
        #expect(model.termsJobs.value == 2)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Forget Project ends the explanations under way, since one may hold excerpts of the
    /// project's files, and the store saves nothing of them.
    @Test(.timeLimit(.minutes(1))) func forgetProjectEndsAnExplanationUnderWay() async throws {
        defer { cleanUp() }
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true)
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        let maple = Project(name: "Maple")
        try await runtime.add(harbor)
        try await runtime.add(maple)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("e@harbor.example", in: .project(harbor.id), runtime) { $0.level == .sure }
        runtime.windowOpened()
        model.blocks.withLock { $0 = true }
        let jobs = model.jobs.value
        let explaining = Task { try await runtime.explain("e@harbor.example") }
        try await waitUntil { model.jobs.value == jobs + 1 }
        #expect(runtime.userRequestCount == 1)
        try await runtime.forget(maple.id)
        await #expect(throws: CancellationError.self) {
            _ = try await explaining.value
        }
        #expect(model.ended.value == 1)
        #expect(runtime.userRequestCount == 0)
        #expect(await runtime.explanation(for: "e@harbor.example") == nil)
        #expect(runtime.projectList.map(\.id) == [harbor.id])
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: The draft apart from other projects' passages

    /// An email of Harbor, whose folders hold nothing, while the folder of Kiln holds a file
    /// about the lamps that the model's search terms name, so its prompt shows that file of
    /// Kiln.
    private func harborEmailWithKilnLamps() async throws -> (ProjectsRuntime, ProjectsSwitch, Project) {
        model.isThere.withLock { $0 = true }
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true)
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        let folder = root.appendingPathComponent("Kiln", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "A lamp fixture for the studio lobby, hung along the north wall.".write(to: folder.appendingPathComponent("lamps.txt"), atomically: true, encoding: .utf8)
        let kiln = Project(name: "Kiln", folders: [try Project.bookmark(of: folder)])
        try await runtime.add(harbor)
        try await runtime.add(kiln)
        try await waitUntil { runtime.indexReport(kiln.id)?.indexed == 1 }
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("e@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        try await waitUntilListed("e@harbor.example", in: .project(harbor.id), runtime) { $0.level == .sure }
        runtime.windowOpened()
        return (runtime, projects, kiln)
    }

    /// The explanation's prompt shows the file of Kiln and asks for no draft, and a second
    /// request of the user, whose prompt holds nothing of Kiln, writes the draft.
    @Test(.timeLimit(.minutes(1))) func anotherProjectsPassageGetsTheDraftFromASecondRequest() async throws {
        defer { cleanUp() }
        let (runtime, projects, kiln) = try await harborEmailWithKilnLamps()
        let jobs = model.jobs.value
        let explanation = try await runtime.explain("e@harbor.example")
        #expect(model.jobs.value == jobs + 3)
        let prompts = model.prompts.withLock { Array($0.suffix(3)) }
        #expect(prompts[0].hasSuffix(SearchTermsPrompt.prefill))
        #expect(prompts[1].contains("<other_files>") && prompts[1].contains("north wall") && prompts[1].contains("its draft is written apart"))
        #expect(!prompts[2].contains("other_files") && !prompts[2].contains("north wall") && !prompts[2].contains("Kiln"))
        #expect(explanation.sourceProjects.contains(kiln.id))
        #expect(await runtime.explanation(for: "e@harbor.example") == explanation)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Forget Project ends both requests of an explanation that shows a file of the
    /// project: while the first one runs, the draft's request is never sent, and while the
    /// draft's request runs, it ends. Nothing is saved.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func forgetProjectEndsBothRequestsOfAnExplanation(duringTheDraft: Bool) async throws {
        defer { cleanUp() }
        let (runtime, projects, kiln) = try await harborEmailWithKilnLamps()
        model.blocksWhen.withLock {
            $0 = { prompt in !prompt.hasSuffix(SearchTermsPrompt.prefill) && prompt.contains("<other_files>") != duringTheDraft }
        }
        let jobs = model.jobs.value
        let explaining = Task { try await runtime.explain("e@harbor.example") }
        let started = jobs + (duringTheDraft ? 3 : 2)
        try await waitUntil { model.jobs.value == started }
        #expect(runtime.userRequestCount == 1)
        try await runtime.forget(kiln.id)
        await #expect(throws: CancellationError.self) {
            _ = try await explaining.value
        }
        #expect(model.ended.value == 1)
        #expect(model.jobs.value == started)
        #expect(runtime.userRequestCount == 0)
        #expect(await runtime.explanation(for: "e@harbor.example") == nil)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A dictation that starts as the first request ends holds the draft's request, which
    /// waits in the queue and runs once the dictation is over.
    @Test(.timeLimit(.minutes(1))) func aDictationHoldsTheDraftsRequestUntilItEnds() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await harborEmailWithKilnLamps()
        model.dictatesAfter.withLock { $0 = { $0.contains("<other_files>") } }
        let queue = try #require(runtime.running?.queue)
        let jobs = model.jobs.value
        let explaining = Task { try await runtime.explain("e@harbor.example") }
        try await waitUntil { queue.pause == .dictation }
        #expect(model.jobs.value == jobs + 2)
        model.dictating.withLock { $0 = false }
        let explanation = try await explaining.value
        #expect(model.jobs.value == jobs + 3)
        #expect(explanation.sources.keys.contains(where: ExplainPrompt.isOtherFileSource))
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Closing the window while an explanation waits lets it go on, and the explanation
    /// holds the model from start to end, so the last holder does not let go between the
    /// request of the explanation and the draft's, which would unload the model and load it
    /// again.
    @Test(.timeLimit(.minutes(1))) func anExplanationHoldsTheModelBetweenItsRequestsAfterTheWindowCloses() async throws {
        defer { cleanUp() }
        let (runtime, projects, kiln) = try await harborEmailWithKilnLamps()
        // A dictation starts as the terms job ends, so the explanation's request waits.
        model.dictatesAfter.withLock { $0 = { $0.hasSuffix(SearchTermsPrompt.prefill) } }
        let queue = try #require(runtime.running?.queue)
        let jobs = model.jobs.value
        let explaining = Task { try await runtime.explain("e@harbor.example") }
        try await waitUntil { queue.pause == .dictation }
        #expect(model.jobs.value == jobs + 1)
        runtime.windowClosed()
        let emptied = model.emptied.value
        #expect(model.holds.value > 0)
        model.dictatesAfter.withLock { $0 = nil }
        model.dictating.withLock { $0 = false }
        let explanation = try await explaining.value
        #expect(model.jobs.value == jobs + 3)
        #expect(explanation.sourceProjects.contains(kiln.id))
        #expect(model.emptied.value == emptied + 1)
        #expect(model.holds.value == 0)
        #expect(await runtime.explanation(for: "e@harbor.example") == explanation)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: Explain Message Selected in Mail

    @Test func explainSelectedMessageReadsOnlyAMessageInAChosenMailbox() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.selection = [MailMessageRef(id: 7, mailbox: FakeMail.archive)]
        }
        // No mailbox confirmed: Mail's selection is not even read.
        #expect(await runtime.messageSelectedInMail() == .noMailboxChosen)
        #expect(!mail.calls.contains("selection"))

        // The message sits in a mailbox the user did not choose: nothing more is read.
        choice.choose([FakeMail.clients])
        choice.confirm()
        #expect(await runtime.messageSelectedInMail() == .notInChosenMailbox)
        #expect(mail.calls.contains("selection"))
        #expect(!mail.calls.contains("headers"))
        #expect(!mail.calls.contains("source"))

        // Mail not running: nothing is asked.
        mail.update { $0.isRunning = false }
        mail.clearCalls()
        #expect(await runtime.messageSelectedInMail() == .mailNotRunning)
        #expect(!mail.calls.contains("selection"))

        // Nothing selected.
        mail.update {
            $0.isRunning = true
            $0.selection = []
        }
        #expect(await runtime.messageSelectedInMail() == .nothingSelected)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func explainSelectedMessageFindsAMessageOfTheInboxOfAllAccounts() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let message = FakeMail.Message(id: 5, messageID: "e@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [message]
            // Mail names a message of the inbox of all accounts by its account's inbox.
            $0.selection = [MailMessageRef(id: 5, mailbox: FakeMail.workInbox)]
        }
        choice.choose([.inbox])
        choice.confirm()
        #expect(await runtime.messageSelectedInMail() == .found("e@harbor.example"))
        #expect(mail.calls.contains("mailbox"))
        #expect(await runtime.place(of: "e@harbor.example") == .needsProject)

        // A message of the account's inbox that is not in the inbox of all accounts.
        mail.update { $0.selection = [MailMessageRef(id: 9, mailbox: FakeMail.workInbox)] }
        #expect(await runtime.messageSelectedInMail() == .notInChosenMailbox)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Which answer of Mail is under way when the user turns Projects off.
    nonisolated enum PendingAnswer: Sendable, CaseIterable {
        /// The selection, of a message of the inbox of all accounts.
        case selectionInInbox
        /// The selection, of a message in a mailbox the user chose.
        case selectionInChosenMailbox
        /// Whether the selected message is in the inbox of all accounts.
        case inboxLookup
    }

    /// The user turns Projects off and keeps its data while Mail has not answered yet. The
    /// choice stays confirmed, but once the answer comes nothing more is read from Mail.
    @Test(arguments: PendingAnswer.allCases)
    func explainSelectedMessageReadsNothingMoreOnceProjectsIsOff(_ pending: PendingAnswer) async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let inInbox = pending != .selectionInChosenMailbox
        let held = pending == .inboxLookup ? "mailbox" : "selection"
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [FakeMail.Message(id: 5, messageID: "e@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")]
            $0.selection = [MailMessageRef(id: 5, mailbox: inInbox ? FakeMail.workInbox : FakeMail.clients)]
            $0.holds = [held]
        }
        choice.choose([inInbox ? .inbox : FakeMail.clients])
        choice.confirm()
        let finding = Task { await runtime.messageSelectedInMail() }
        try await waitUntil { mail.calls.contains(held) }

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(choice.isConfirmed)
        mail.clearCalls()
        mail.update { $0.holds = [] }
        #expect(await finding.value == .noMailboxChosen)
        #expect(!mail.calls.contains("mailbox"))
        #expect(!mail.calls.contains("headers"))
    }

    /// The window shows the message in the list sorting files it in, selected.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageShowsTheMessageWhereItIsFiled() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        // The window waits until sorting filed the message, however long a busy test runner
        // takes for it. In the app it waits ProjectsRuntime.sortingWait at most.
        runtime.sortingWaitLimit = nil
        let harbor = Project(name: "Harbor", people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example")])
        try await runtime.add(harbor)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [FakeMail.Message(id: 5, messageID: "e@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")]
            $0.selection = [MailMessageRef(id: 5, mailbox: FakeMail.workInbox)]
        }
        choice.choose([.inbox])
        choice.confirm()
        let window = ProjectsWindowModel(runtime: runtime)
        #expect(window.place == .needsProject)
        await window.explainSelectedMessage()
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == "e@harbor.example")
        #expect(!window.isReadingSelection)
        #expect(window.notice == nil)
        // The window is closed, so no explanation starts.
        #expect(window.explaining["e@harbor.example"] == .failed(.other))

        // The user moves it: the list does not follow it.
        await window.move("e@harbor.example", to: nil)
        await window.reload()
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail == nil)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func explainSelectedMessageSaysWhenTheScanDidNotReadIt() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.selection = [MailMessageRef(id: 8, mailbox: FakeMail.clients)]
            $0.headers[8] = "Message-ID: <old@harbor.example>\r\nSubject: Old\r\n"
        }
        choice.choose([FakeMail.clients])
        choice.choose(days: 30)
        choice.confirm()
        #expect(await runtime.messageSelectedInMail() == .notRead(days: 30))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail may hold another message with the Message-ID of an email the store holds, such
    /// as one made to look like it, or one a mail program sent with an ID it used before.
    /// Explain Message Selected in Mail shows and explains the email the store holds only
    /// when the message selected is that email, and keeps no handle of another message
    /// for it.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageShowsNoOtherEmailWithItsMessageID() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.sortingWaitLimit = nil
        let id = "x@harbor.example"
        let email = FakeMail.Message(id: 100, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")
        let fields = email.source.components(separatedBy: "\r\n\r\n")[0] + "\r\n"
        let date = "Date: Sun, 18 Oct 2026 09:00:00 +0000\r\n"
        mail.update {
            $0.permission = .allowed
            $0.inbox = [email]
            $0.headers[999] = fields.replacingOccurrences(of: "Mei Tan <mei@harbor.example>", with: "Mallory <mallory@other.example>")
            $0.selection = [MailMessageRef(id: 999, mailbox: FakeMail.clients)]
        }
        choice.choose([.inbox, FakeMail.clients])
        choice.confirm()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runtime.isScanning)
        // Mail opens: the scan starts once Explain Message Selected in Mail reached Mail,
        // and reads the email of the inbox, not the message selected.
        mail.update { $0.isRunning = true }
        #expect(await runtime.messageSelectedInMail() == .otherEmail)
        let kept = MailMessageRef(id: 100, mailbox: .inbox)
        #expect(runtime.mailReference(for: id) == kept)

        // The store held the email before the click.
        try await waitUntilListed(id, in: .needsProject, runtime) { _ in true }
        #expect(await runtime.messageSelectedInMail() == .otherEmail)
        #expect(runtime.mailReference(for: id) == kept)
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explainSelectedMessage()
        #expect(window.notice == .selection(.otherEmail))
        #expect(ProjectsWindowText.selection(.otherEmail) == "This message looks like an email Projects read, but its sender, recipients or date differ, so Projects cannot explain it.")
        #expect(window.selectedEmail == nil)
        #expect(window.explaining[id] == nil)

        // Mei's sender and recipients, with another date.
        mail.update { $0.headers[999] = fields.replacingOccurrences(of: date, with: "Date: Mon, 19 Oct 2026 08:00:00 +0000\r\n") }
        #expect(await runtime.messageSelectedInMail() == .otherEmail)
        #expect(runtime.mailReference(for: id) == kept)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A copy of the email in another mailbox the user chose is the email itself.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageFindsTheEmailInAnotherMailbox() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.sortingWaitLimit = nil
        let id = "x@harbor.example"
        let email = FakeMail.Message(id: 100, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")
        let copy = MailMessageRef(id: 300, mailbox: FakeMail.clients)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [email]
            $0.headers[300] = email.source.components(separatedBy: "\r\n\r\n")[0] + "\r\n"
            $0.selection = [copy]
        }
        choice.choose([.inbox, FakeMail.clients])
        choice.confirm()
        try await waitUntilListed(id, in: .needsProject, runtime) { _ in true }
        #expect(await runtime.messageSelectedInMail() == .found(id))
        #expect(runtime.mailReference(for: id) == copy)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// An email past the first page of its list opens from a source and from Explain Message
    /// Selected in Mail, in a project and in Set Aside. The window finds its list and its
    /// place there in the store, and reads the list down to it.
    @Test(.timeLimit(.minutes(1)))
    func anEmailPastTheFirstPageOfItsListOpens() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.listPage = 3
        let store = try #require(runtime.running?.store)
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        await runtime.untilResorted()
        // The two oldest emails of the project and the oldest of Set Aside are past the
        // first page.
        let filed = try await saveOldestFirst(5, named: "h", as: SortingDecision(project: harbor.id, level: .sure, reasons: [.person]), in: store)
        let setAside = try await saveOldestFirst(4, named: "n", as: SortingDecision(project: nil, level: .setAside, reasons: [.listMail]), in: store)
        #expect(try await store.save(MailStoreTests.explanation(filed[0], project: harbor.id), at: Self.today))

        // A source cites the oldest email of the project.
        let window = ProjectsWindowModel(runtime: runtime)
        await window.show(filed[0])
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == filed[0])
        #expect(window.selectedEmail?.subject == "Order 0")
        #expect(window.selectedEmail?.isExplained == true)
        #expect(window.selectedEmail?.summary == "Sign A is 60 by 90 cm.")
        #expect(await runtime.explanation(for: filed[0])?.messageID == filed[0])

        // A source cites the oldest email of Set Aside, and the way back leads to the oldest
        // of the project again.
        await window.show(setAside[0])
        #expect(window.place == .setAside)
        #expect(window.selectedEmail?.messageID == setAside[0])
        #expect(window.previousEmail == filed[0])
        await window.showPreviousEmail()
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == filed[0])
        #expect(window.rows.count == filed.count)

        // In a new window, which reads the first page of Needs a Project, Explain Message
        // Selected in Mail finds the second oldest of the project selected in Mail.
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.selection = [MailMessageRef(id: 8, mailbox: FakeMail.clients)]
            $0.headers[8] = "Message-ID: <\(filed[1])>\r\nSubject: Order 1\r\n"
        }
        choice.choose([FakeMail.clients])
        choice.confirm()
        let another = ProjectsWindowModel(runtime: runtime)
        await another.explainSelectedMessage()
        #expect(another.notice == nil)
        #expect(another.place == .project(harbor.id))
        #expect(another.selectedEmail?.messageID == filed[1])
        #expect(another.limit == 6)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The email itself is found also when its headers hold an address that is not read
    /// exactly, which the scan left out, or no To, for which the scan took what Mail lists.
    @Test(.timeLimit(.minutes(1)), arguments: ["Project Team, \(ProjectsRuntimeTests.own)", nil])
    func explainSelectedMessageFindsTheEmailWithRecipientsReadAsTheScanReadThem(to: String?) async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.sortingWaitLimit = nil
        let id = "x@harbor.example"
        var email = FakeMail.Message(id: 100, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")
        email.to = to
        let selected = MailMessageRef(id: 100, mailbox: .inbox)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [email]
            $0.selection = [selected]
        }
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntilListed(id, in: .needsProject, runtime) { _ in true }
        #expect(await runtime.messageSelectedInMail() == .found(id))
        #expect(runtime.mailReference(for: id) == selected)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail quits and opens again while Explain Message Selected in Mail reads the message.
    /// The email is found, and the handle from the Mail session that ended is not kept.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageKeepsNoHandleOfAMailSessionThatEnded() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.sortingWaitLimit = nil
        let id = "x@harbor.example"
        let email = FakeMail.Message(id: 100, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")
        let copy = MailMessageRef(id: 300, mailbox: FakeMail.clients)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [email]
            $0.headers[300] = email.source.components(separatedBy: "\r\n\r\n")[0] + "\r\n"
            $0.selection = [copy]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox, FakeMail.clients])
        choice.confirm()
        try await waitUntilListed(id, in: .needsProject, runtime) { _ in true }
        mail.update { $0.holds = ["selection"] }
        let found = Task { await runtime.messageSelectedInMail() }
        try await waitUntil { mail.calls.contains("selection") }
        mail.update { $0.isRunning = false }
        runtime.mailRunningChanged()
        mail.update { $0.isRunning = true }
        runtime.mailRunningChanged()
        mail.update { $0.holds = [] }
        #expect(await found.value == .found(id))
        #expect(runtime.mailReference(for: id) != copy)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The window reads a list down to an older email for a few pages at most. An email
    /// older than that shows alone in the email view, and the list keeps what it read.
    @Test(.timeLimit(.minutes(1)))
    func anEmailPastThePagesTheWindowReadsDownShowsAlone() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        runtime.listPage = 2
        let store = try #require(runtime.running?.store)
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        await runtime.untilResorted()
        let pages = ProjectsWindowModel.maximumPagesDown
        let filed = try await saveOldestFirst(2 * pages + 1, named: "h", as: SortingDecision(project: harbor.id, level: .sure, reasons: [.person]), in: store)
        let window = ProjectsWindowModel(runtime: runtime)

        // A source cites the oldest, past the pages the window reads down.
        await window.show(filed[0])
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == filed[0])
        #expect(window.selectedEmail?.subject == "Order 0")
        #expect(window.rows.count == 2 && window.limit == 2 && window.hasOlderEmails)

        // A source of that email cites the next one, the last the window reads down to.
        await window.show(filed[1])
        #expect(window.selectedEmail?.messageID == filed[1])
        #expect(window.rows.count == 2 * pages && window.rows.last?.messageID == filed[1])

        await window.showPreviousEmail()
        #expect(window.selectedEmail?.messageID == filed[0])
        #expect(window.rows.count == 2 * pages)
        #expect(!window.rows.contains { $0.messageID == filed[0] })
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The store fails to save the message that the scan reads for Explain Message Selected
    /// in Mail, as on a full disk. The window says so, not that Projects has not read it.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageSaysWhenTheMessageCouldNotBeSaved() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        // No new email saves, while the store still reads.
        try await store.database.run("CREATE TEMP TRIGGER no_new_mail BEFORE INSERT ON mail_messages BEGIN SELECT RAISE(ABORT, 'full'); END")
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [FakeMail.Message(id: 5, messageID: "e@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Plans", text: "Here are the plans.")]
            $0.selection = [MailMessageRef(id: 5, mailbox: FakeMail.workInbox)]
        }
        choice.choose([.inbox])
        choice.confirm()
        #expect(await runtime.messageSelectedInMail() == .notSaved)
        #expect(ProjectsWindowText.selection(.notSaved) == "Projects could not save this message on this Mac. Try again later.")
        #expect(try await store.explainEmail("e@harbor.example") == nil)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A list reads its newest page of emails, 1,000 in the app, and says how many it
    /// holds, and Load Older Emails reads a page more. Another list starts again with a
    /// page.
    @Test(.timeLimit(.minutes(1)))
    func loadOlderEmailsReadsAPageMore() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        #expect(runtime.listPage == 1_000)
        runtime.listPage = 3
        let store = try #require(runtime.running?.store)
        let waiting = try await saveOldestFirst(4, named: "w", as: SortingDecision(project: nil, level: .unsure, reasons: [.noSignal]), in: store)
        let window = ProjectsWindowModel(runtime: runtime)
        #expect(window.place == .needsProject)
        await window.reload()
        #expect(window.rows.count == 3)
        #expect(window.rows.first?.messageID == waiting.last)
        #expect(window.total == 4)
        #expect(window.hasOlderEmails)
        #expect(ProjectsWindowText.olderEmails(shown: window.rows.count, total: window.total) == "Showing the newest 3 of 4 emails.")
        #expect(ProjectsWindowText.olderEmails(shown: 1_000, total: 1_234) == "Showing the newest 1,000 of 1,234 emails.")

        await window.loadOlderEmails()
        #expect(window.rows.count == 4)
        #expect(window.rows.last?.messageID == waiting[0])
        #expect(window.total == 4)
        #expect(!window.hasOlderEmails)

        window.place = .setAside
        await window.reload()
        #expect(window.limit == 3)
        #expect(window.rows.isEmpty && window.total == 0 && !window.hasOlderEmails)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Back to Previous Email returns to the list and the email a source left, with the same
    /// email view, one step at a time after sources that follow one another. Choosing
    /// another email, in the list or in Mail, or another list, ends the way back, also when
    /// the user comes back to the email the source showed.
    @Test func backToPreviousEmailReturnsWhereASourceLeft() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        await runtime.untilResorted()
        let filed = try await saveOldestFirst(3, named: "h", as: SortingDecision(project: harbor.id, level: .sure, reasons: [.person]), in: store)
        let waiting = try await saveOldestFirst(1, named: "w", as: SortingDecision(project: nil, level: .unsure, reasons: [.noSignal]), in: store)
        let window = ProjectsWindowModel(runtime: runtime)
        window.place = .project(harbor.id)
        await window.reload()
        window.selectedMessageID = filed[2]
        let view = window.emailModel(for: filed[2])
        #expect(window.previousEmail == nil)

        // A source shows an email of Needs a Project, and a source of that email the oldest
        // of the project.
        await window.show(waiting[0])
        #expect(window.place == .needsProject)
        #expect(window.selectedEmail?.messageID == waiting[0])
        #expect(window.previousEmail == filed[2])
        await window.show(filed[0])
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == filed[0])
        #expect(window.previousEmail == waiting[0])

        await window.showPreviousEmail()
        #expect(window.place == .needsProject)
        #expect(window.selectedEmail?.messageID == waiting[0])
        #expect(window.previousEmail == filed[2])
        await window.showPreviousEmail()
        #expect(window.place == .project(harbor.id))
        #expect(window.selectedEmail?.messageID == filed[2])
        #expect(window.emailModel(for: filed[2]) === view)
        #expect(window.previousEmail == nil)

        await window.show(filed[0])
        #expect(window.previousEmail == filed[2])
        window.selectedMessageID = filed[1]
        #expect(window.previousEmail == nil)
        window.selectedMessageID = filed[0]
        #expect(window.previousEmail == nil)

        await window.show(waiting[0])
        #expect(window.previousEmail == filed[0])
        window.place = .setAside
        window.place = .needsProject
        await window.reload()
        window.selectedMessageID = waiting[0]
        #expect(window.previousEmail == nil)

        // Explain Message Selected in Mail finds the email a source showed, after the user
        // chose another list.
        await window.show(filed[1])
        #expect(window.previousEmail == waiting[0])
        window.place = .setAside
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.selection = [MailMessageRef(id: 8, mailbox: FakeMail.clients)]
            $0.headers[8] = "Message-ID: <\(filed[1])>\r\nSubject: Order 1\r\n"
        }
        choice.choose([FakeMail.clients])
        choice.confirm()
        await window.explainSelectedMessage()
        #expect(window.selectedEmail?.messageID == filed[1])
        #expect(window.previousEmail == nil)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    @Test func explainingNeedsTheWindowAndTheModel() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("f@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        await #expect(throws: ProjectsRuntime.Failure.windowClosed) {
            _ = try await runtime.explain("f@harbor.example")
        }
        runtime.windowOpened()
        await #expect(throws: RewriteError.notLoaded) {
            _ = try await runtime.explain("f@harbor.example")
        }
        await #expect(throws: ProjectsRuntime.Failure.unknownEmail) {
            _ = try await runtime.explain("missing@harbor.example")
        }
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// An explanation that finds no model says why: the model is not on this Mac, also while
    /// it downloads, or it is and could not be loaded, which a download does not mend.
    @Test(arguments: [false, true])
    func anExplanationWithoutTheModelSaysWhetherItIsMissingOrCouldNotBeLoaded(installed: Bool) async throws {
        defer { cleanUp() }
        // The fake model never loads. Without the model files there is no tokenizer either.
        let (runtime, projects, _) = try await started(installed: Installed(installed), countsTokens: installed)
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("f@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explain("f@harbor.example")
        guard case .failed(let failure)? = window.explaining["f@harbor.example"] else {
            Issue.record("The explanation should have failed, not \(String(describing: window.explaining["f@harbor.example"]))")
            return
        }
        #expect(ProjectsWindowText.explainFailure(failure) == (installed ? "The cleanup model could not be loaded." : "The cleanup model is not on this Mac."))
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A change, a translation or the answer check that finds no model gets the note for
    /// why, as an explanation does.
    @Test(arguments: [false, true])
    func aRequestOnTheDraftWithoutTheModelSaysWhetherItIsMissingOrCouldNotBeLoaded(installed: Bool) async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started(installed: Installed(installed))
        do {
            try await runtime.userRequest { () async throws -> Void in throw RewriteError.notLoaded }
            Issue.record("The request should have failed")
        } catch {
            #expect(ProjectsEmailModel.note(error) == (installed ? .modelNotLoaded : .noModel))
        }
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Try Loading Again looks at the model again, and then explains the email with it.
    @Test func tryLoadingAgainLoadsTheModelAndExplainsTheEmail() async throws {
        defer { cleanUp() }
        let retries = Count()
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true, retryLoading: { [model] in
            retries.add()
            model.isThere.withLock { $0 = true }
        })
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("f@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explain("f@harbor.example")
        #expect(window.explaining["f@harbor.example"] == .failed(.modelNotLoaded))
        #expect(retries.value == 0)
        await window.loadModelAgain(explaining: "f@harbor.example")
        #expect(retries.value == 1)
        #expect(window.explaining["f@harbor.example"] == nil)
        #expect(window.explained["f@harbor.example"] == 1)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// A change of the draft that begins while Try Loading Again looks at the model keeps
    /// the draft. No explanation follows the load, since a new one would start the draft
    /// again and drop the version the change makes.
    @Test func tryLoadingAgainLeavesOutTheExplanationWhileTheDraftChanges() async throws {
        defer { cleanUp() }
        let meanwhile = Meanwhile()
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true, retryLoading: { [model] in
            model.isThere.withLock { $0 = true }
            await meanwhile.run()
        })
        let store = try #require(runtime.running?.store)
        let id = "f@harbor.example"
        try await store.save([Self.message(id, from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        let check = DraftCheckInput(
            draft: "", language: .en, recipients: [DraftCheckInput.Person(name: "", address: "mei@harbor.example")], projectPeople: [],
            own: [DraftCheckInput.Person(name: "Me", address: Self.own)], incomingText: "Could you send the plan?", today: Self.today)
        let explanation = Explanation(
            messageID: id, project: nil, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [], questions: [], draft: .checked(DraftCheck.Result(draft: "Hi Mei,\n\nHere is the plan.\n\nMe", language: .en)), draftCheck: check,
            sources: [:], removed: [:], problems: [], unknownSources: [])
        #expect(try await store.save(explanation, at: Self.today))
        runtime.windowOpened()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explain(id)
        #expect(window.explaining[id] == .failed(.modelNotLoaded))
        let email = window.emailModel(for: id)
        await email.load()
        #expect(email.hasDraft)
        // The user changes the draft while the model is looked at. The change's job waits
        // at the model until the test ends it.
        meanwhile.work = { [model] in
            model.blocks.withLock { $0 = true }
            email.perform { await $0.makeChange(.tone(.warm)) }
            for _ in 0..<1_000 where !email.isBusy {
                await Task.yield()
            }
        }
        // A task, so the test fails rather than waits for good when an explanation waits
        // behind the change.
        let returned = Count()
        let retrying = Task {
            await window.loadModelAgain(explaining: id)
            returned.add()
        }
        try await waitUntil { returned.value == 1 }
        #expect(email.isBusy)
        #expect(window.explaining[id] == nil)
        #expect(window.explained[id] == nil)
        email.cancelWork()
        retrying.cancel()
        await retrying.value
        try await waitUntil { !email.isBusy }
        #expect(await runtime.explanation(for: id) == explanation)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Try Loading Again explains its email once the model is loaded. When the user selected
    /// another email meanwhile and clicked Hide Explanation, that email stays as the user
    /// set it.
    @Test func tryLoadingAgainLeavesHideExplanationOfAnotherEmail() async throws {
        defer { cleanUp() }
        let meanwhile = Meanwhile()
        let (runtime, projects, _) = try await started(installed: Installed(true), countsTokens: true, retryLoading: { [model] in
            model.isThere.withLock { $0 = true }
            await meanwhile.run()
        })
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("f@harbor.example", from: "mei@harbor.example"), Self.message("g@harbor.example", from: "mei@harbor.example", day: 1)], ownAddresses: [Self.own], at: Self.today)
        runtime.windowOpened()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.show("f@harbor.example")
        await window.explain("f@harbor.example")
        #expect(window.explaining["f@harbor.example"] == .failed(.modelNotLoaded))
        // While the model is looked at, the user selects the other email and hides its
        // explanation.
        meanwhile.work = {
            await window.show("g@harbor.example")
            window.showsExplanation = false
        }
        await window.loadModelAgain(explaining: "f@harbor.example")
        #expect(window.explained["f@harbor.example"] == 1)
        #expect(window.selectedMessageID == "g@harbor.example")
        #expect(!window.showsExplanation)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// An email whose text Retention removed, or one too large to read, is not explained,
    /// also when Explain Message Selected in Mail reaches it outside the list the window
    /// shows.
    @Test func explainingNeedsTheEmailsText() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let store = try #require(runtime.running?.store)
        try await store.save([Self.message("old@harbor.example", from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today.addingTimeInterval(-91 * Retention.day))
        var large = Self.message("large@harbor.example", from: "mei@harbor.example", day: 1)
        large.text = ""
        large.visibleText = ""
        large.isTooLarge = true
        try await store.save([large], ownAddresses: [Self.own], at: Self.today)
        try await Retention.apply(to: store, now: Self.today)
        runtime.windowOpened()
        for id in ["old@harbor.example", "large@harbor.example"] {
            await #expect(throws: ProjectsRuntime.Failure.noText) {
                _ = try await runtime.explain(id)
            }
        }
        // The email view says why, so the window shows no failure.
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explain("large@harbor.example")
        #expect(window.explaining["large@harbor.example"] == nil)
        runtime.windowClosed()
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// An email the scan found too large to read shows with why it has no text, and is not
    /// explained, since Explain stays off for it.
    @Test(.timeLimit(.minutes(1)))
    func explainSelectedMessageShowsAnEmailTooLargeToReadWithoutExplainingIt() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.sortingWaitLimit = nil
        let store = try #require(runtime.running?.store)
        let id = "big@harbor.example"
        let email = FakeMail.Message(id: 5, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Drawings", text: "")
        // As the scan reads an email over MailScan.largestSource: its headers only.
        let listing = MailListing(
            message: MailMessageRef(id: 5, mailbox: .inbox), messageID: id, dateReceived: Self.today, sender: email.from,
            subject: email.subject, to: [Self.own], cc: [], size: MailScan.largestSource + 1)
        let scanned = await MailScan.parsed(headers: email.source.components(separatedBy: "\r\n\r\n")[0], attachments: [], listing: listing)
        #expect(scanned.isTooLarge)
        try await store.save([ProjectsRuntime.storeMessage(scanned, now: Self.today)], ownAddresses: [Self.own], at: Self.today)
        runtime.requestSort()
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [email]
            $0.selection = [MailMessageRef(id: 5, mailbox: FakeMail.workInbox)]
        }
        choice.choose([.inbox])
        choice.confirm()
        let window = ProjectsWindowModel(runtime: runtime)
        await window.explainSelectedMessage()
        let shown = try #require(window.selectedEmail)
        #expect(shown.messageID == id)
        #expect(shown.isTooLarge)
        #expect(ProjectsWindowText.noText(shown) == "Projects did not read this email, as it is too large. Read it in Mail.")
        #expect(window.explaining[id] == nil)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: The email view

    /// Open Reply in Mail finds mail read before Orra started: the scan keeps Mail's handle
    /// of each message it lists, also one it knows and does not read again. The handles go
    /// when Mail quits, and come back when the scan lists the mailbox again with the next
    /// Mail.
    @Test func theScanKeepsMailsHandlesOfTheMailItKnows() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        // More mail than a poll lists, all known before Orra started. The oldest is the one
        // to reply to.
        let count = MailScan.pollRangeSize + 5
        let ids = (1...count).map { "h\($0)@harbor.example" }
        try await store.save(ids.map { Self.message($0, from: "mei@harbor.example") }, ownAddresses: [Self.own], at: Self.today)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = ids.enumerated().map { position, id in
                FakeMail.Message(id: 100 + position, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "Could you send the plan?")
            }
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        let oldest = ids[count - 1]
        try await waitUntil { runtime.mailReference(for: oldest) != nil }
        #expect(runtime.mailReference(for: oldest) == MailMessageRef(id: 100 + count - 1, mailbox: .inbox))
        #expect(runtime.mailReference(for: ids[0]) == MailMessageRef(id: 100, mailbox: .inbox))
        // Known already, so no source was read again.
        #expect(!mail.calls.contains("source"))

        // Mail quits: the handles go and the scan stops.
        mail.update { $0.isRunning = false }
        runtime.mailRunningChanged()
        #expect(runtime.mailReference(for: oldest) == nil)
        #expect(!runtime.isScanning)

        // The next Mail gives the messages other ids. The scan starts again and lists the
        // inbox back to the days, beyond what a poll lists.
        mail.update {
            $0.isRunning = true
            for index in $0.inbox.indices {
                $0.inbox[index].id += 1_000
            }
        }
        runtime.mailRunningChanged()
        try await waitUntil { runtime.mailReference(for: oldest) != nil }
        #expect(runtime.mailReference(for: oldest) == MailMessageRef(id: 1_100 + count - 1, mailbox: .inbox))
        #expect(!mail.calls.contains("source"))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Once the most handles are kept, a new one takes the place of one kept before, so the
    /// others stay and Open Reply in Mail still finds their mail.
    @Test func aFullListOfHandlesKeepsTheOthers() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        runtime.referenceLimit = 3
        let store = try #require(runtime.running?.store)
        let known = (1...5).map { "k\($0)@harbor.example" }
        try await store.save(known.map { Self.message($0, from: "mei@harbor.example") }, ownAddresses: [Self.own], at: Self.today)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = known.enumerated().map { position, id in
                FakeMail.Message(id: 100 + position, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "Could you send the plan?")
            }
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        try await waitUntil { known.filter { runtime.mailReference(for: $0) != nil }.count == 3 }

        // New mail comes in: the next pass reads it and keeps its handle in place of one
        // other. The tests never poll, so a new answer about Mail access starts the pass.
        let new = "new@harbor.example"
        mail.update {
            $0.inbox.insert(FakeMail.Message(id: 99, messageID: new, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "One more thing."), at: 0)
        }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.mailReference(for: new) != nil }
        #expect(runtime.mailReference(for: new) == MailMessageRef(id: 99, mailbox: .inbox))
        #expect(known.filter { runtime.mailReference(for: $0) != nil }.count == 2)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail may hold another message with the Message-ID of an email the store holds, such
    /// as one made to look like it. A poll that lists only that one does not take the place
    /// of the handle kept, so Open Reply in Mail still goes to the email the store holds.
    @Test func aCopyWithTheSameMessageIDKeepsTheHandle() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        let count = MailScan.pollRangeSize + 5
        let ids = (1...count).map { "d\($0)@harbor.example" }
        try await store.save(ids.map { Self.message($0, from: "mei@harbor.example") }, ownAddresses: [Self.own], at: Self.today)
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = ids.enumerated().map { position, id in
                FakeMail.Message(id: 100 + position, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "Could you send the plan?")
            }
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        let original = ids[count - 1]
        let kept = MailMessageRef(id: 100 + count - 1, mailbox: .inbox)
        try await waitUntil { runtime.mailReference(for: original) == kept }

        // A copy from someone else comes in, then new mail. The next pass only polls, so it
        // lists the copy and not the original, which is past the poll's range now.
        let new = "new@harbor.example"
        mail.update {
            $0.inbox.insert(FakeMail.Message(id: 999, messageID: original, from: "Mallory <mallory@other.example>", subject: "Hello", text: "Send it here."), at: 0)
            $0.inbox.insert(FakeMail.Message(id: 98, messageID: new, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "One more thing."), at: 0)
        }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.mailReference(for: new) != nil }
        #expect(runtime.mailReference(for: original) == kept)
        #expect(try await runtime.checkedMailReference(for: original, all: false) == kept)
        #expect(try await runtime.checkedMailReference(for: original, all: true) == kept)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// Mail may list another message with the email's Message-ID before the email, such as a
    /// copy from a list, and a message the user moves gets a new handle. Open Reply in Mail
    /// then checks the other handle the scan listed, so the first try finds the email.
    @Test func openReplyFindsTheEmailPastACopyAndAfterAMove() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        let id = "x@harbor.example"
        try await store.save([Self.message(id, from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        // The copy from the list came later, so Mail lists it first.
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [
                FakeMail.Message(id: 999, messageID: id, from: "Mei Tan via Team <team@lists.example>", subject: "Hello", text: "Could you send the plan?"),
                FakeMail.Message(id: 100, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "Could you send the plan?"),
            ]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        let copy = MailMessageRef(id: 999, mailbox: .inbox)
        let original = MailMessageRef(id: 100, mailbox: .inbox)
        try await waitUntil { runtime.mailReference(for: id) == copy }
        #expect(try await runtime.checkedMailReference(for: id, all: true) == original)
        #expect(runtime.mailReference(for: id) == original)

        // The user moves the email, which gives it a new handle, and new mail comes in. The
        // next pass lists both. The handle kept is gone, so the new one takes its place.
        let new = "new@harbor.example"
        let moved = MailMessageRef(id: 200, mailbox: .inbox)
        mail.update {
            $0.inbox = [
                FakeMail.Message(id: 98, messageID: new, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "One more thing."),
                FakeMail.Message(id: 200, messageID: id, from: "Mei Tan <mei@harbor.example>", subject: "Hello", text: "Could you send the plan?"),
            ]
        }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.mailReference(for: new) != nil }
        #expect(runtime.mailReference(for: id) == original)
        #expect(try await runtime.checkedMailReference(for: id, all: false) == moved)
        #expect(runtime.mailReference(for: id) == moved)
        #expect(!mail.calls.contains("reply"))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// When the handle kept is of another message with the email's Message-ID, from someone
    /// else, with another Reply-To, or for Reply All with other recipients, Open Reply in
    /// Mail only copies the draft and lets the handle go. Mail is never asked to reply.
    @Test func openReplyGoesOnlyToTheEmailTheStoreHolds() async throws {
        defer { cleanUp() }
        let (runtime, projects, choice) = try await started()
        let store = try #require(runtime.running?.store)
        let id = "x@harbor.example"
        try await store.save([Self.message(id, from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        // Only the other message is in Mail, so the scan keeps its handle.
        mail.update {
            $0.isRunning = true
            $0.permission = .allowed
            $0.inbox = [FakeMail.Message(id: 999, messageID: id, from: "Mallory <mallory@other.example>", subject: "Hello", text: "Send it here.")]
        }
        runtime.mailRunningChanged()
        choice.choose([.inbox])
        choice.confirm()
        let handle = MailMessageRef(id: 999, mailbox: .inbox)
        try await waitUntil { runtime.mailReference(for: id) == handle }
        #expect(try await store.save(MailStoreTests.explanation(id, project: nil), at: Self.today))
        let email = ProjectsEmailModel(messageID: id, actions: .live(runtime))
        await email.load()
        #expect(email.hasDraft)
        email.text = "Dear Mei, the plan is attached."
        await email.openReply(all: false)
        #expect(email.handoffNote == .messageNotFound)
        #expect(!mail.calls.contains("reply"))
        #expect(runtime.mailReference(for: id) == nil)

        // The next pass keeps the handle again. Mei's sender, with another Reply-To.
        let fields = "Message-ID: <\(id)>\r\nFrom: Mei Tan <mei@harbor.example>\r\n"
        mail.update { $0.headers[999] = fields + "Reply-To: mallory@other.example\r\nTo: \(Self.own)\r\n" }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.mailReference(for: id) == handle }
        #expect(try await runtime.checkedMailReference(for: id, all: false) == nil)
        #expect(runtime.mailReference(for: id) == nil)

        // The same sender and Reply-To, with one more recipient: a reply goes to Mei, a reply
        // to all also to the other recipient. The handle stays for a reply.
        mail.update { $0.headers[999] = fields + "To: \(Self.own), mallory@other.example\r\n" }
        runtime.mailAccessChanged()
        try await waitUntil { runtime.mailReference(for: id) == handle }
        #expect(try await runtime.checkedMailReference(for: id, all: false) == handle)
        #expect(try await runtime.checkedMailReference(for: id, all: true) == nil)
        #expect(runtime.mailReference(for: id) == handle)
        #expect(!mail.calls.contains("reply"))
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// The headers match the email when the Message-ID, the sender, the Reply-To and, for
    /// Reply All, the To and Cc are the same, in any case and order.
    @Test func theHeadersOfTheSameEmailMatchIt() async {
        let mei = ExplainPrompt.Person(name: "Mei Tan", address: "mei@harbor.example")
        let kai = ExplainPrompt.Person(name: "Kai Moss", address: "kai@kiln.example")
        let me = ExplainPrompt.Person(name: "", address: Self.own)
        let email = ExplainService.Email(
            messageID: "x@harbor.example", date: Self.today, sender: mei, replyTo: [kai], to: [me, kai], cc: [mei],
            text: "", visibleText: "")
        func block(_ fields: [String]) -> String {
            fields.joined(separator: "\r\n") + "\r\n"
        }
        func headers(_ fields: String...) -> String {
            block(fields)
        }
        let id = "Message-ID: <x@harbor.example>"
        let same = headers(id, "From: \"Tan, Mei\" <MEI@Harbor.example>", "Reply-To: kai@kiln.example", "To: Kai <kai@kiln.example>, ME@studio.example", "Cc: mei@harbor.example")
        #expect(await ProjectsRuntime.isSameEmail(email, headers: same, all: true))
        let others = [
            headers("Message-ID: <y@harbor.example>", "From: mei@harbor.example", "Reply-To: kai@kiln.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"),
            headers(id, "From: mallory@other.example", "Reply-To: kai@kiln.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"),
            headers(id, "From: mei@harbor.example", "Reply-To: mallory@other.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"),
            headers(id, "From: mei@harbor.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"),
            headers(id, "Reply-To: kai@kiln.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"),
        ]
        for other in others {
            #expect(await ProjectsRuntime.isSameEmail(email, headers: other, all: false) == false)
        }
        // Other recipients count only for Reply All.
        let moreRecipients = headers(id, "From: mei@harbor.example", "Reply-To: kai@kiln.example", "To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example, mallory@other.example")
        #expect(await ProjectsRuntime.isSameEmail(email, headers: moreRecipients, all: false))
        #expect(await ProjectsRuntime.isSameEmail(email, headers: moreRecipients, all: true) == false)

        // Headers that only look the same to this check: cut at a limit, with an address
        // this check cannot read but Mail may reply to, or with one more sender.
        let from = "From: mei@harbor.example"
        let recipients = ["To: me@studio.example, kai@kiln.example", "Cc: mei@harbor.example"]
        let filler = Array(repeating: "X-Filler: a", count: 1_000)
        let lookAlikes = [
            block([id, from, "Reply-To: kai@kiln.example"] + filler + ["Reply-To: mallory@other.example"] + recipients),
            block([id, from, "Reply-To: kai@kiln.example, (" + String(repeating: "x", count: 70_000) + ") mallory@other.example"] + recipients),
            block([id, from, #"Reply-To: kai@kiln.example, "mallory x"@other.example"#] + recipients),
            block([id, from, "Reply-To: kai@kiln.example, mallory@[192.0.2.1]"] + recipients),
            block([id, from, "Reply-To: kai@kiln.example, mallory@other.example."] + recipients),
            block([id, from, "Reply-To: <mallory@other.example> <kai@kiln.example>"] + recipients),
            block([id, "From: mei@harbor.example, Mallory <mallory@other.example>", "Reply-To: kai@kiln.example"] + recipients),
            block([id, from, "From: mallory@other.example", "Reply-To: kai@kiln.example"] + recipients),
        ]
        for lookAlike in lookAlikes {
            #expect(await ProjectsRuntime.isSameEmail(email, headers: lookAlike, all: false) == false)
        }
        let unreadRecipient = block([id, from, "Reply-To: kai@kiln.example", "To: me@studio.example, kai@kiln.example", #"Cc: mei@harbor.example, "mallory x"@other.example"#])
        #expect(await ProjectsRuntime.isSameEmail(email, headers: unreadRecipient, all: false))
        #expect(await ProjectsRuntime.isSameEmail(email, headers: unreadRecipient, all: true) == false)
    }

    /// The scan's bridge hands each listing on with the session read before it began, so a
    /// listing under way when Mail quits brings no handle of the old Mail back.
    @Test func aListingCarriesTheSessionItBeganIn() async throws {
        let session = Mutex(1)
        let handed = Mutex<[Int?]>([])
        var bridge = mail.bridge
        bridge.listing = { _, _ in
            // Mail quits while it lists.
            session.withLock { $0 += 1 }
            return [MailListing(
                message: MailMessageRef(id: 1, mailbox: .inbox), messageID: "q@harbor.example", dateReceived: Self.today,
                sender: "mei@harbor.example", subject: "Hello", to: [Self.own], cc: [], size: 1_000)]
        }
        let remembering = ProjectsRuntime.remembering(
            bridge,
            session: { session.withLock { $0 } },
            listed: { listings, began in
                #expect(listings.map(\.messageID) == ["q@harbor.example"])
                handed.withLock { $0.append(began) }
            }
        )
        let listings = try await remembering.listing(.inbox, 1...1)
        #expect(listings.count == 1)
        #expect(handed.withLock { $0 } == [1])
    }

    /// A move from an Assign to Project menu keeps the window on its list and selects the
    /// next email. When it takes away versions of the draft, it waits for the user's yes.
    @Test func aMoveStaysOnTheListAndAsksBeforeItTakesADraftAway() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let store = try #require(runtime.running?.store)
        let harbor = Project(name: "Harbor")
        try await runtime.add(harbor)
        let ids = ["m1@kiln.example", "m2@kiln.example", "m3@kiln.example"]
        try await store.save(ids.enumerated().map { day, id in Self.message(id, from: "lu@kiln.example", day: Double(day)) }, ownAddresses: [Self.own], at: Self.today)
        try await waitUntilListed(ids[0], in: .needsProject, runtime) { _ in true }
        let model = ProjectsWindowModel(runtime: runtime)
        model.place = .needsProject
        await model.reload()
        let order = model.rows.map(\.messageID)
        #expect(Set(order) == Set(ids))

        // No draft to lose: it moves at once, and the next email is selected.
        model.selectedMessageID = order[1]
        await model.requestMove(order[1], to: harbor.id)
        #expect(model.pendingMove == nil)
        #expect(await runtime.place(of: order[1]) == .project(harbor.id))
        #expect(model.place == .needsProject)
        #expect(model.selectedMessageID == order[2])

        // With a version of its draft, the move waits until the user says yes.
        let check = DraftCheckInput(
            draft: "", language: .en, recipients: [DraftCheckInput.Person(name: "", address: "lu@kiln.example")], projectPeople: [],
            own: [DraftCheckInput.Person(name: "Me", address: Self.own)], incomingText: "Could you send the plan?", today: Self.today)
        let explanation = Explanation(
            messageID: order[2], project: nil, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [], questions: [], draft: .checked(DraftCheck.Result(draft: "Hi Lu,\n\nHere it is.\n\nMe", language: .en)), draftCheck: check,
            sources: [:], removed: [:], problems: [], unknownSources: [])
        #expect(try await store.save(explanation, at: Self.today))
        let version = ReviseService.Version(messageID: order[2], change: .tone(.warm), check: DraftCheck.Result(draft: "Hi Lu,\n\nHappy to send it.\n\nMe", language: .en))
        #expect(try await store.save(version, startedAt: Self.today, at: Self.today) == 1)
        await model.reload()
        await model.requestMove(order[2], to: harbor.id)
        let pending = try #require(model.pendingMove)
        #expect(pending == ProjectsWindowModel.PendingMove(messageID: order[2], project: harbor.id))
        #expect(await runtime.place(of: order[2]) == .needsProject)
        await model.confirmMove(pending)
        #expect(model.pendingMove == nil)
        #expect(await runtime.place(of: order[2]) == .project(harbor.id))
        // The last of the list went, so the one before it is selected.
        #expect(model.selectedMessageID == order[0])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    /// What the email view reads and changes through the runtime: the explanation, what a
    /// revision checks with, the versions with Undo, the deadline mark, and an email shown
    /// in its list.
    @Test func theEmailViewReadsTheExplanationAndTheVersions() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let store = try #require(runtime.running?.store)
        let id = "v@harbor.example"
        try await store.save([Self.message(id, from: "mei@harbor.example")], ownAddresses: [Self.own], at: Self.today)
        let check = DraftCheckInput(
            draft: "", language: .en, recipients: [DraftCheckInput.Person(name: "", address: "mei@harbor.example")], projectPeople: [],
            own: [DraftCheckInput.Person(name: "Me", address: Self.own)], incomingText: "Could you send the plan?", today: Self.today,
            imitatingDomains: ["harb0r.example"], asksForData: true)
        let explanation = Explanation(
            messageID: id, project: nil, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [Explanation.Point(text: "Mei asks for the plan by 23 October.", sources: [], flags: [])], questions: [],
            draft: .checked(DraftCheck.Result(draft: "Hi Mei,\n\nHere is the plan.\n\nMe", language: .en)), draftCheck: check,
            sources: [:], removed: [:], problems: [], unknownSources: [])
        #expect(try await store.save(explanation, at: Self.today))
        #expect(await runtime.explanation(for: id) == explanation)
        #expect(await runtime.email(id)?.text == "Could you send the plan?")

        let context = try #require(await runtime.reviseContext(for: explanation))
        #expect(context.messageID == id)
        #expect(context.emailText == "Could you send the plan?")
        #expect(context.language == .en)
        #expect(context.userLanguage == .en)
        #expect(context.ownName == "Me")
        #expect(context.recipients == check.recipients)
        #expect(context.incomingText == check.incomingText)
        #expect(context.imitatingDomains == ["harb0r.example"])
        #expect(context.asksForData)
        var noDraft = explanation
        noDraft.draftCheck = nil
        #expect(await runtime.reviseContext(for: noDraft) == nil)

        let version = ReviseService.Version(messageID: id, change: .tone(.warm), check: DraftCheck.Result(draft: "Hi Mei,\n\nHappy to share the plan.\n\nMe", language: .en))
        #expect(try await store.save(version, startedAt: Self.today, at: Self.today.addingTimeInterval(1)) == 1)
        // The version reads back equal, which the email view relies on to find its own.
        #expect(await runtime.versions(of: id).map(\.version) == [version])
        #expect(await runtime.removeNewestVersion(of: id))
        #expect(await runtime.versions(of: id).isEmpty)
        #expect(!(await runtime.removeNewestVersion(of: id)))

        let model = ProjectsWindowModel(runtime: runtime)
        model.place = .setAside
        await model.show(id)
        #expect(model.place == .needsProject)
        #expect(model.selectedMessageID == id)
        #expect(model.deadlines[id] == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23)))
        // The same email view each time, until the window closes, with the window's one
        // handoff at a time.
        let view = model.emailModel(for: id)
        #expect(model.emailModel(for: id) === view)
        #expect(view.handoffs === model.handoffs)
        model.forgetEmails()
        #expect(model.deadlines.isEmpty)
        #expect(model.emailModel(for: id) !== view)
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
    }

    // MARK: Files for a reply

    /// A project with a folder of the lamp email's files, indexed.
    private func harborWithFiles(_ runtime: ProjectsRuntime) async throws -> (project: Project, folder: URL) {
        let harbor = try folder("Harbor lobby", holding: "notes.txt")
        try "Floor plan of the lobby, revision 3.".write(to: harbor.appending(path: "floor-plan-v3.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: harbor.appending(path: "Slides.key"), withIntermediateDirectories: true)
        let project = Project(name: "Harbor", folders: [try Project.bookmark(of: harbor)])
        try await runtime.add(project)
        try await waitUntil { runtime.indexReport(project.id).map { !$0.isIndexing && $0.indexed > 0 } == true }
        return (project, URL(fileURLWithPath: try #require(FolderWalk.realPath(harbor.path)), isDirectory: true))
    }

    /// The files a request may mean come from the index of the projects' folders, after any
    /// dictation, and none while Projects is off.
    @Test func aRequestFindsItsFilesAfterTheDictation() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let (project, folder) = try await harborWithFiles(runtime)
        let request = try #require(FileRequests.find(in: "Please send the floor plan.", subject: "").first)
        let found = await runtime.requestedFiles(for: request, emailProject: project.id, scope: nil)
        #expect(found.map(\.url) == [folder.appending(path: "floor-plan-v3.txt")])
        #expect(found.map(\.project) == [project.id])

        machine.isDictating = true
        let waiting = Task { await runtime.requestedFiles(for: request, emailProject: project.id, scope: [project.id]) }
        try await Task.sleep(for: ProjectsRuntime.dictationCheck * 3)
        machine.isDictating = false
        #expect(await waiting.value.count == 1)

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(await runtime.requestedFiles(for: request, emailProject: project.id, scope: nil).isEmpty)
    }

    /// A file goes into a reply only when the index holds it in a folder a project holds now:
    /// a file Projects has not read, a file outside the folders and a package are refused,
    /// and so is everything while Projects is off.
    @Test func aReplyTakesOnlyAFileTheIndexHolds() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let (project, folder) = try await harborWithFiles(runtime)
        let plan = folder.appending(path: "floor-plan-v3.txt")
        let taken = try await runtime.replyFile(at: plan, first: project.id).get()
        #expect(taken.url == plan)
        #expect(taken.projects == [project.id])
        // Through a link outside the folders, the file is refused by its path, before
        // anything reads it, as a file dropped there would be.
        let link = root.appending(path: "Link to Harbor")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(await runtime.replyFile(at: link.appending(path: "floor-plan-v3.txt"), first: nil) == .failure(.notInAddedFolder))

        // The folder events are off in the tests, so the index never lists a new file.
        let unread = folder.appending(path: "new.txt")
        try "New".write(to: unread, atomically: true, encoding: .utf8)
        #expect(await runtime.replyFile(at: unread, first: project.id) == .failure(.notInAddedFolder))
        let outside = try self.folder("Elsewhere", holding: "other.txt").appending(path: "other.txt")
        #expect(await runtime.replyFile(at: outside, first: project.id) == .failure(.notInAddedFolder))
        #expect(await runtime.replyFile(at: folder.appending(path: "Slides.key"), first: project.id) == .failure(.package))

        // Checked again before its event with the folders of now.
        #expect(await runtime.recheck(taken) == .success(taken))
        var without = project
        without.folders = []
        try await runtime.update(without)
        #expect(await runtime.recheck(taken) == .failure(.notInAddedFolder))

        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(await runtime.replyFile(at: plan, first: project.id) == .failure(.notInAddedFolder))
        #expect(await runtime.recheck(taken) == .failure(.notInAddedFolder))
    }

    /// Projects turns off while a file is checked for a reply, after the folders of the
    /// first project were read and while those of the next one are, as on a share that
    /// hangs. The file in the first project's folder is refused, as Projects gives Mail
    /// nothing once it is off.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aFileCheckThatEndsAfterProjectsTurnedOffRefusesTheFile(_ isTick: Bool) async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let (project, folder) = try await harborWithFiles(runtime)
        let plan = folder.appending(path: "floor-plan-v3.txt")
        let taken = try await runtime.replyFile(at: plan, first: project.id).get()
        let kiln = Project(name: "Kiln", folders: [try Project.bookmark(of: self.folder("Kiln", holding: "kiln.txt"))])
        try await runtime.add(kiln)
        let reads = HeldReads(holding: "Kiln")
        runtime.readRealPath = { await reads.read($0) }

        let check = Task { isTick ? await runtime.replyFile(at: plan, first: project.id) : await runtime.recheck(taken) }
        try await waitUntil { reads.isHolding }
        #expect(reads.started == [folder.lastPathComponent, "Kiln"])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        reads.letGo()
        #expect(await check.value == .failure(.notInAddedFolder))
    }

    /// The projects for the lines about people outside a file's project, and the folder Add
    /// File… starts in.
    @Test func theReplyKnowsTheProjectsAndWhereAddFileStarts() async throws {
        defer { cleanUp() }
        let (runtime, projects, _) = try await started()
        let (project, folder) = try await harborWithFiles(runtime)
        #expect(runtime.replyProjects() == runtime.projectList.map(\.forExplanation))
        #expect(runtime.replyProjects().map(\.id) == [project.id])
        #expect(await runtime.defaultFolder(of: project.id) == folder)
        #expect(await runtime.defaultFolder(of: nil) == nil)
        #expect(await runtime.replyRoots() == [project.id: [folder]])
        await projects.turnOff(keepingData: true)
        try await waitUntil { runtime.phase == .off }
        #expect(await runtime.defaultFolder(of: project.id) == nil)
    }

    // MARK: Values

    @Test func theDebugKeysCountOnlyInDebugBuilds() {
        defer { cleanUp() }
        defaults.set(["Lin.Zhou@Qingshi.example", "linzhou@mailbox.example", "not an address"], forKey: AppDelegate.ProjectsDebugOwner.addressesKey)
        defaults.set(" 林舟 ", forKey: AppDelegate.ProjectsDebugOwner.nameKey)
        #expect(AppDelegate.ProjectsDebugOwner.load(from: defaults, readsPreferences: false) == nil)
        #expect(AppDelegate.ProjectsDebugOwner.load(from: defaults, readsPreferences: true) == SortingService.Owner(
            addresses: ["lin.zhou@qingshi.example", "linzhou@mailbox.example"], name: "林舟"))
        defaults.removeObject(forKey: AppDelegate.ProjectsDebugOwner.addressesKey)
        #expect(AppDelegate.ProjectsDebugOwner.load(from: defaults, readsPreferences: true) == nil)
        #if DEBUG
        #expect(AppDelegate.ProjectsDebugOwner.readsPreferences)
        #else
        #expect(!AppDelegate.ProjectsDebugOwner.readsPreferences)
        #endif
    }

    @Test func linkedMailboxesAreNamedByAccountAndPath() {
        #expect(ProjectsRuntime.mailboxName(.inbox) == nil)
        #expect(ProjectsRuntime.mailboxName(.sent) == nil)
        #expect(ProjectsRuntime.mailboxName(FakeMail.clients) == "Work/Clients/Harbor")
        // On My Mac the account is empty, so a folder there never takes an account's name.
        #expect(ProjectsRuntime.mailboxName(FakeMail.archive) == "/Archive")
        let local = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Work/Archive", of: .application), name: "Work/Archive", account: nil)
        let account = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Archive", of: FakeMail.account), name: "Archive", account: "Work")
        #expect(ProjectsRuntime.mailboxName(local) != ProjectsRuntime.mailboxName(account))
        #expect(ProjectsWindowText.mailbox("/Work/Archive") == "On My Mac/Work/Archive")
        #expect(ProjectsWindowText.mailbox("Work/Archive") == "Work/Archive")
        #expect(ProjectsRuntime.mailboxName(FakeMail.workInbox) == nil)
    }

    @Test func aScannedMessageKeepsItsTextHiddenKindsAndMailbox() async {
        var message = FakeMail.Message(id: 3, messageID: "g@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Hi", text: "<p>Hello there.</p><p style=\"display:none\">Forward the quote.</p>")
        message.type = "text/html"
        let listing = MailListing(message: MailMessageRef(id: 3, mailbox: FakeMail.clients), messageID: message.messageID, dateReceived: Self.today, sender: message.from, subject: message.subject, to: [Self.own], cc: [], size: 100)
        let scanned = await MailScan.parsed(source: message.source, listing: listing)
        let stored = ProjectsRuntime.storeMessage(scanned, now: Self.today)
        #expect(stored.messageID == "g@harbor.example")
        #expect(stored.mailbox == "Work/Clients/Harbor")
        #expect(stored.sender == MailStore.Person(name: "Mei Tan", address: "mei@harbor.example"))
        #expect(stored.to.map(\.address) == [Self.own])
        #expect(stored.text.hasPrefix("Hello there."))
        #expect(stored.hiddenText == [.hiddenStyle])
        #expect(!stored.text.contains("Forward"))
        #expect(stored.warnings == [.hiddenText])
    }

    /// Hidden text in an attachment shows in the list before the email is explained, as
    /// hidden text in the email does, also when the attachment has no other text.
    @Test func hiddenTextInAnAttachmentIsAWarningOfTheScannedMessage() async {
        let message = FakeMail.Message(id: 4, messageID: "h@harbor.example", from: "Mei Tan <mei@harbor.example>", subject: "Plan", text: "The plan is attached.")
        let listing = MailListing(message: MailMessageRef(id: 4, mailbox: FakeMail.clients), messageID: message.messageID, dateReceived: Self.today, sender: message.from, subject: message.subject, to: [Self.own], cc: [], size: 100)
        var scanned = await MailScan.parsed(source: message.source, listing: listing)
        #expect(ProjectsRuntime.storeMessage(scanned, now: Self.today).warnings == [])
        scanned.attachments = [MailAttachment(name: "plan.docx", type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", state: .noText, hiddenRuns: 1)]
        let stored = ProjectsRuntime.storeMessage(scanned, now: Self.today)
        #expect(stored.warnings == [.hiddenText])
        #expect(stored.hiddenText.isEmpty)
        #expect(stored.attachments == scanned.attachments)
    }

    @Test func theMenuTitleCountsTheMailWaitingForAReply() {
        let english = Locale(identifier: "en")
        #expect(ProjectsWindowText.menuTitle(replyDue: 0, locale: english) == "Open Projects Window")
        #expect(ProjectsWindowText.menuTitle(replyDue: 3, locale: english) == "Open Projects Window (3 to Reply)")
        // The window's name, as the catalog gives it elsewhere.
        let chinese = Locale(identifier: "zh-Hans")
        #expect(ProjectsWindowText.menuTitle(replyDue: 0, locale: chinese) == "打开“项目”窗口")
        #expect(ProjectsWindowText.menuTitle(replyDue: 3, locale: chinese) == "打开“项目”窗口（3 封待回复）")
    }

    // MARK: Helpers

    typealias Lines = ProjectsWindowView.StatusLines
    typealias Line = ProjectsWindowView.MailLine

    /// The lines about mail that say why Projects reads none or stopped reading, without
    /// the line about reading or sorting, which background work may show at any moment.
    private func problems(_ runtime: ProjectsRuntime) -> [Line] {
        Lines.mailLines(runtime: runtime).filter { !$0.isActivity }
    }

    /// An email in Mail's inbox, for the scan.
    nonisolated static let lunch = FakeMail.Message(id: 1, messageID: "a@kiln.example", from: "Ana Ruiz <ana@kiln.example>", subject: "Lunch", text: "Lunch on Thursday?")

    /// A tokenizer's count, about four bytes a token.
    nonisolated static func countTokens(_ text: String) -> Int {
        text.utf8.count / 4 + 1
    }

    /// Waits until a list holds the email in a state, which sorting on other tasks makes
    /// true. A bound, not a measure.
    private func waitUntilListed(_ messageID: String, in place: MailStore.Place, _ runtime: ProjectsRuntime, _ condition: (MailStore.Listed) -> Bool) async throws {
        for _ in 0..<2_000 {
            if let row = try await runtime.list(place).first(where: { $0.messageID == messageID }), condition(row) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The email did not show in its list as expected")
    }

    /// The list of `place` once it is as `condition` asks, however long sorting takes on a
    /// busy test runner. The test's time limit bounds the wait.
    private func listed(_ place: MailStore.Place, _ runtime: ProjectsRuntime, until condition: ([MailStore.Listed]) -> Bool) async throws -> [MailStore.Listed] {
        while true {
            let rows = try await runtime.list(place)
            if condition(rows) { return rows }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A project with a folder, saved by a run of Projects that ended, so the next start
    /// finds it in the project list and resolves its folder.
    private func savedProjectWithAFolder() async throws -> Project {
        let (first, projects, _) = try await started()
        let project = Project(name: "Harbor", folders: [try Project.bookmark(of: folder("Alpha", holding: "alpha.txt"))])
        try await first.add(project)
        await projects.turnOff(keepingData: true)
        try await waitUntil { first.phase == .off }
        return project
    }

    /// A folder under the test's folder that holds one text file.
    private func folder(_ name: String, holding file: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Notes for the harbor office".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return folder
    }

    private static func message(_ id: String, from sender: String, day: Double = 0) -> MailStore.Message {
        MailStore.Message(
            messageID: id, mailbox: nil, date: today.addingTimeInterval(-86_400 * (3 - day)),
            sender: MailStore.Person(address: sender), to: [MailStore.Person(address: own)],
            subject: "Hello", text: "Could you send the plan?", visibleText: "Could you send the plan?")
    }

    /// Saves `count` emails of Harbor an hour apart, each with a subject of its own, files
    /// them as `decision` says, and returns their Message-IDs, the oldest first.
    private func saveOldestFirst(_ count: Int, named name: String, as decision: SortingDecision, in store: MailStore) async throws -> [String] {
        let ids = (0..<count).map { "\(name)\($0)@harbor.example" }
        try await store.save(ids.enumerated().map { index, id in
            var message = Self.message(id, from: "mei@harbor.example")
            message.date = Self.today.addingTimeInterval(-3_600 * Double(count - index))
            message.subject = "Order \(index)"
            return message
        }, ownAddresses: [Self.own], at: Self.today)
        var filed = 0
        for id in ids where try await store.saveDecision(decision, for: id) {
            filed += 1
        }
        #expect(filed == count)
        return ids
    }

    /// A count that closures on any thread add to.
    final class Count: Sendable {
        private let count = Mutex(0)

        nonisolated func add(_ amount: Int = 1) {
            count.withLock { $0 += amount }
        }

        nonisolated var value: Int {
            count.withLock { $0 }
        }
    }

    /// What a test does while Try Loading Again looks at the model, set once the window is
    /// there.
    @MainActor final class Meanwhile {
        var work: () async -> Void = {}

        func run() async {
            await work()
        }
    }

    /// Whether a dictation is under way, and Low Power Mode and the heat of the Mac, which a
    /// test changes.
    final class Machine: Sendable {
        private let dictating = Mutex(false)
        private let state = Mutex(ProjectsRuntime.PowerState())

        var isDictating: Bool {
            get { dictating.withLock { $0 } }
            set { dictating.withLock { $0 = newValue } }
        }

        var power: ProjectsRuntime.PowerState {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    /// The presses of the talk key, as EngineTurns.whenDictationStarts hands them on.
    final class KeyDown {
        var handlers: [() -> Void] = []

        func press() {
            for handler in handlers {
                handler()
            }
        }
    }

    /// Whether the cleanup model is on this Mac, which a test changes and the runtime
    /// observes.
    @Observable final class Installed {
        var value: Bool

        init(_ value: Bool = false) {
            self.value = value
        }
    }

    /// Where the cleanup model's download stands, as the app maps it from the installer,
    /// which a test changes.
    @Observable final class Download {
        var status = ProjectsRuntime.ModelDownloadStatus.none
    }

    /// How the index reaches project folders, recorded by name: resolves bookmarks with
    /// Project.resolve, but holds the first resolve of a bookmark until the test lets it go,
    /// as on a share that hangs and recovers. Reads files with FileTextExtractor and
    /// watches nothing.
    final class StallingFolders: Sendable {
        private nonisolated struct State: Sendable {
            var holdsNext = true
            var held: CheckedContinuation<Void, Never>?
            var letGo = false
            var heldResolveReturned = false
            var resolves = 0
            var readFiles: [String] = []
            var watchedFolders: [[String]] = []
        }

        private let state = Mutex(State())

        nonisolated var isHolding: Bool {
            state.withLock { $0.held != nil }
        }

        /// How many resolves of one or more bookmarks started.
        nonisolated var resolves: Int {
            state.withLock { $0.resolves }
        }

        nonisolated var heldResolveReturned: Bool {
            state.withLock { $0.heldResolveReturned }
        }

        /// The names of the files read, in order.
        nonisolated var readFiles: [String] {
            state.withLock { $0.readFiles }
        }

        /// The names of the folders of each watch, in order.
        nonisolated var watchedFolders: [[String]] {
            state.withLock { $0.watchedFolders }
        }

        nonisolated func letGo() {
            let held = state.withLock { state in
                state.letGo = true
                defer { state.held = nil }
                return state.held
            }
            held?.resume()
        }

        nonisolated func resolve(_ bookmarks: [Data]) async -> [URL] {
            let holds = state.withLock { state in
                if !bookmarks.isEmpty {
                    state.resolves += 1
                }
                guard state.holdsNext, !bookmarks.isEmpty else { return false }
                state.holdsNext = false
                return true
            }
            guard holds else { return await Project.resolve(bookmarks) }
            await withCheckedContinuation { continuation in
                let goes = state.withLock { state in
                    if !state.letGo {
                        state.held = continuation
                    }
                    return state.letGo
                }
                if goes {
                    continuation.resume()
                }
            }
            let folders = await Project.resolve(bookmarks)
            state.withLock { $0.heldResolveReturned = true }
            return folders
        }

        nonisolated func read(_ file: URL) async -> Result<FileTextResult, FileSkipReason> {
            state.withLock { $0.readFiles.append(file.lastPathComponent) }
            return await ProjectsRuntime.readFile(file)
        }

        nonisolated func watch(_ folders: [URL], _ since: UInt64?, _ deliver: @escaping @Sendable (FolderEvents.Changes) -> Void) -> () -> Void {
            state.withLock { $0.watchedFolders.append(folders.map(\.lastPathComponent)) }
            return {}
        }
    }

    /// Reads the real path of a folder as the email view does, but holds the first read, or
    /// the first of the folder `holding` names, until the test lets it go, as a folder on a
    /// share that hangs would, and records the names of the folders it was asked for, in
    /// order. With `holds` false it only records them.
    final class HeldReads: Sendable {
        private nonisolated struct State: Sendable {
            var started: [String] = []
            var held: CheckedContinuation<Void, Never>?
            var letGo = false
            /// The name of the folder whose first read is held, nil for the first read of all.
            var holding: String?
        }

        private let state: Mutex<State>

        nonisolated init(holds: Bool = true, holding name: String? = nil) {
            state = Mutex(State(letGo: !holds, holding: name))
        }

        nonisolated var isHolding: Bool {
            state.withLock { $0.held != nil }
        }

        nonisolated var started: [String] {
            state.withLock { $0.started }
        }

        nonisolated func letGo() {
            let held = state.withLock { state in
                state.letGo = true
                defer { state.held = nil }
                return state.held
            }
            held?.resume()
        }

        nonisolated func read(_ folder: URL) async -> URL? {
            let first = state.withLock { state in
                let name = folder.lastPathComponent
                state.started.append(name)
                guard let holding = state.holding else { return state.started.count == 1 }
                return name == holding && state.started.filter { $0 == holding }.count == 1
            }
            if first {
                await withCheckedContinuation { continuation in
                    let goes = state.withLock { state in
                        if !state.letGo {
                            state.held = continuation
                        }
                        return state.letGo
                    }
                    if goes {
                        continuation.resume()
                    }
                }
            }
            return await FolderWalk.realPath(of: folder)
        }
    }

    /// The model, missing until a test puts it there. A job answers the first candidate of
    /// a sorting prompt at once, and the terms of `terms` to a prompt for search terms, or
    /// with `blocks` waits until it is cancelled. Counts the jobs, those ended by a cancel,
    /// those for search terms, the holders the window and the requests of the user take, and
    /// the times the last of them let go.
    final class FakeModel: Sendable {
        let holds = Count()
        let releases = Count()
        let emptied = Count()
        let jobs = Count()
        let ended = Count()
        let termsJobs = Count()
        let isThere = Mutex(false)
        let blocks = Mutex(false)
        let captionsOn = Mutex(false)
        /// Blocks, as `blocks` does, each job whose prompt it holds true for.
        let blocksWhen = Mutex<(@Sendable (String) -> Bool)?>(nil)
        /// Whether a dictation is under way, which pauses every job.
        let dictating = Mutex(false)
        /// Starts a dictation as a job whose prompt it holds true for ends.
        let dictatesAfter = Mutex<(@Sendable (String) -> Bool)?>(nil)
        /// The prompt of every job, in order.
        let prompts = Mutex<[String]>([])
        /// What the model writes after the prefill of the search terms prompt.
        let terms = Mutex(#"lamp", "fixture"]}"#)
        /// Whether the job under way is for search terms. One job runs at a time.
        private let asksForTerms = Mutex(false)

        @MainActor var environment: ProjectsModelEnvironment {
            ProjectsModelEnvironment(
                startJob: { [self] prompt, _ in
                    jobs.add()
                    prompts.withLock { $0.append(prompt) }
                    let forTerms = prompt.hasSuffix(SearchTermsPrompt.prefill)
                    asksForTerms.withLock { $0 = forTerms }
                    if forTerms {
                        termsJobs.add()
                    }
                    if blocks.withLock({ $0 }) || blocksWhen.withLock({ $0 })?(prompt) == true {
                        do {
                            try await Task.sleep(for: .seconds(3_600))
                        } catch {
                            ended.add()
                            throw error
                        }
                    }
                    return RewriteEngine.JobStart(id: 1, promptTokens: 10)
                },
                readSlice: { _, _ in RewriteEngine.SliceRun(read: 10, remaining: 0, ran: .zero) },
                writeBurst: { _, _ in RewriteEngine.BurstRun(written: 4, finished: true, ran: .zero) },
                endJob: { [self] _ in
                    if let prompt = prompts.withLock({ $0.last }), dictatesAfter.withLock({ $0 })?(prompt) == true {
                        dictating.withLock { $0 = true }
                    }
                    return asksForTerms.withLock { $0 } ? terms.withLock { $0 } : #"P1", "reason": "fits"}"#
                },
                isDictating: { [self] in dictating.withLock { $0 } },
                captionsOn: { [self] in captionsOn.withLock { $0 } },
                memoryPressure: { .normal },
                voiceLoaded: { false },
                physicalMemory: 32 << 30,
                waitUntilLoaded: { [self] in isThere.withLock { $0 } },
                holdModel: { [holds] in holds.add() },
                releaseModel: { [holds, releases, emptied] in
                    holds.add(-1)
                    releases.add()
                    if holds.value == 0 {
                        emptied.add()
                    }
                },
                sleep: { try await Task.sleep(for: $0) }
            )
        }
    }

    /// Mail as the bridge sees it, with the inbox of all accounts and the selection. Never
    /// sends an Apple Event.
    final class FakeMail: Sendable {
        nonisolated struct Message: Sendable {
            var id: Int
            var messageID: String
            var from: String
            var subject: String
            var text: String
            var type = "text/plain"
            /// The value of To, nil for a message without the field.
            var to: String? = ProjectsRuntimeTests.own

            var source: String {
                let to = to.map { "To: \($0)\r\n" } ?? ""
                return "Message-ID: <\(messageID)>\r\nDate: Sun, 18 Oct 2026 09:00:00 +0000\r\nFrom: \(from)\r\n\(to)Subject: \(subject)\r\nContent-Type: \(type); charset=utf-8\r\n\r\n\(text)\r\n"
            }
        }

        nonisolated struct State: Sendable {
            var isRunning = false
            var permission: MailPermission = .notAsked
            var permissionAsks: [Bool] = []
            var calls: [String] = []
            /// Newest first, as Mail lists the inbox.
            var inbox: [Message] = []
            var selection: [MailMessageRef] = []
            var headers: [Int: String] = [:]
            /// Reading a source waits until the pass is cancelled.
            var sourceBlocks = false
            var sourcesCancelled = 0
            /// What every call to Mail fails with, such as a timeout.
            var failure: MailBridgeError?
            /// Mailboxes Mail no longer has, as after a rename in Mail.
            var gone: Set<MailMailbox> = []
            /// Messages Mail gives with no source, as it may before it downloaded their body.
            var withoutSource: Set<Int> = []
            /// Calls, by name, that answer only once the test takes them out, also when
            /// their caller is cancelled, as an event Mail already got.
            var holds: Set<String> = []
        }

        nonisolated static let account = MailEvents.Specifier.textID(MailEvents.Code.account, "WORK-ACCOUNT", of: .application)
        nonisolated static let clients = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Clients/Harbor", of: account), name: "Clients/Harbor", account: "Work")
        nonisolated static let archive = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Archive", of: .application), name: "Archive", account: nil)
        /// The inbox of the account, as Mail names a selected message's mailbox.
        nonisolated static let workInbox = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "INBOX", of: account), name: "", account: nil)

        let state = Mutex(State())

        func update(_ change: (inout State) -> Void) {
            state.withLock { change(&$0) }
        }

        var calls: [String] {
            state.withLock { $0.calls }
        }

        var permissionAsks: [Bool] {
            state.withLock { $0.permissionAsks }
        }

        var sourcesCancelled: Int {
            state.withLock { $0.sourcesCancelled }
        }

        func clearCalls() {
            state.withLock { $0.calls = [] }
        }

        private nonisolated func record(_ call: String) -> State {
            state.withLock { state in
                state.calls.append(call)
                return state
            }
        }

        /// Waits while the test holds a call.
        private nonisolated func waitWhileHeld(_ call: String) async {
            while state.withLock({ $0.holds.contains(call) }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        private nonisolated func answer<T>(_ call: String, _ body: (State) throws -> T) throws -> T {
            let state = record(call)
            guard state.isRunning else { throw MailBridgeError.mailNotRunning }
            guard state.permission == .allowed else {
                throw state.permission == .denied ? MailBridgeError.denied : MailBridgeError.notAsked
            }
            if let failure = state.failure {
                throw failure
            }
            return try body(state)
        }

        var bridge: MailBridge {
            MailBridge(
                isRunning: { self.record("isRunning").isRunning },
                permission: { ask in
                    self.state.withLock { state in
                        state.permissionAsks.append(ask)
                        return state.isRunning ? state.permission : .mailNotRunning
                    }
                },
                lastPermission: { nil },
                accounts: { try self.answer("accounts") { _ in [] } },
                mailboxes: { try self.answer("mailboxes") { _ in [.inbox, .sent, Self.clients, Self.archive] } },
                count: { mailbox in
                    let count = try self.answer("count") { state in
                        guard !state.gone.contains(mailbox) else { throw MailBridgeError.notFound }
                        return mailbox == .inbox ? state.inbox.count : 0
                    }
                    await self.waitWhileHeld("count")
                    return count
                },
                listing: { mailbox, positions in
                    try self.answer("listing") { state in
                        guard mailbox == .inbox else { return [] }
                        return positions.compactMap { position in
                            guard state.inbox.indices.contains(position - 1) else { return nil }
                            let message = state.inbox[position - 1]
                            return MailListing(
                                message: MailMessageRef(id: message.id, mailbox: .inbox), messageID: message.messageID,
                                dateReceived: ProjectsRuntimeTests.today.addingTimeInterval(-Double(position) * 3_600),
                                sender: message.from, subject: message.subject, to: [ProjectsRuntimeTests.own], cc: [], size: 1_000)
                        }
                    }
                },
                headers: { reference in
                    try self.answer("headers") { state in
                        if let headers = state.headers[reference.id] { return headers }
                        guard let message = state.inbox.first(where: { $0.id == reference.id }) else { throw MailBridgeError.notFound }
                        return message.source.components(separatedBy: "\r\n\r\n")[0]
                    }
                },
                source: { reference in
                    let source = try self.answer("source") { state in
                        guard let message = state.inbox.first(where: { $0.id == reference.id }) else { throw MailBridgeError.notFound }
                        return state.withoutSource.contains(message.id) ? "" : message.source
                    }
                    await self.waitWhileHeld("source")
                    if self.state.withLock({ $0.sourceBlocks }) {
                        do {
                            try await Task.sleep(for: .seconds(3_600))
                        } catch {
                            self.state.withLock { $0.sourcesCancelled += 1 }
                            throw error
                        }
                    }
                    return source
                },
                attachments: { _ in try self.answer("attachments") { _ in [] } },
                mailbox: { reference in
                    let mailbox = try self.answer("mailbox") { state in
                        // Only messages of the inbox of all accounts are found there.
                        guard reference.mailbox == .inbox, state.inbox.contains(where: { $0.id == reference.id }) else { throw MailBridgeError.notFound }
                        return Self.workInbox
                    }
                    await self.waitWhileHeld("mailbox")
                    return mailbox
                },
                selection: {
                    let selection = try self.answer("selection") { $0.selection }
                    await self.waitWhileHeld("selection")
                    return selection
                },
                reply: { _, _ in try self.answer("reply") { _ in nil } },
                attach: { _, _ in try self.answer("attach") { _ in } }
            )
        }
    }
}
