import Foundation
import Synchronization
import Testing
@testable import Orra

/// Projects while it is on: nothing starts while it is off, everything stops at off, the
/// window holds the model and lets it go at close, the scan waits for the confirm, Mail and
/// the permission, what the scan saves is sorted, Explain Selected Message reads only a
/// message in a chosen mailbox (decision 18), and the Debug keys count only in Debug builds.
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
    /// how the index reaches project folders, and `keyDown` for the presses of the talk key.
    private func make(isOn: Bool = true, isVisible: Bool = true, opens: Count? = nil, installed: Installed = Installed(), countsTokens: Bool = false, openFails: Bool = false, folders: StallingFolders? = nil, keyDown: KeyDown? = nil) -> (ProjectsRuntime, ProjectsSwitch, MailChoice) {
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
            isDictating: { false },
            whenDictationStarts: { [keyDown] handler in keyDown?.handlers.append(handler) },
            modelEnvironment: { _ in model.environment },
            modelIsInstalled: { installed.value },
            loadTokenCounter: { [tokenizer] in try await tokenizer.load(counter) },
            handoff: ReplyHandoff(copy: { _ in true }, mail: mail.bridge, isOrraActive: { true }, bringMailToFront: {}),
            watchesMemoryPressure: false,
            watchFolders: watchFolders,
            readText: readText,
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

    /// Waits for a condition, which work on other tasks makes true. A bound, not a measure.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The condition did not come true")
    }

    private func started(isVisible: Bool = true, installed: Installed = Installed(), countsTokens: Bool = false, folders: StallingFolders? = nil, keyDown: KeyDown? = nil) async throws -> (ProjectsRuntime, ProjectsSwitch, MailChoice) {
        let made = make(isVisible: isVisible, installed: installed, countsTokens: countsTokens, folders: folders, keyDown: keyDown)
        made.0.follow()
        try await waitUntil { made.0.phase == .on }
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
        #expect(await runtime.list(.needsProject).map(\.messageID) == ["a@kiln.example"])
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
        #expect(await runtime.list(.project(garden.id)).count == 3)

        try await runtime.forget(garden.id)
        #expect(runtime.projectList.map(\.id) == [harbor.id])
        #expect(await runtime.list(.project(garden.id)).isEmpty)
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

    // MARK: Explain Selected Message

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
        let email = ProjectsEmailModel(messageID: id, actions: .live(runtime))
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

    /// A move from a Move To menu keeps the window on its list and selects the next email.
    /// When it takes away versions of the draft, it waits for the user's yes.
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

    /// A tokenizer's count, about four bytes a token.
    nonisolated static func countTokens(_ text: String) -> Int {
        text.utf8.count / 4 + 1
    }

    /// Waits until a list holds the email in a state, which sorting on other tasks makes
    /// true. A bound, not a measure.
    private func waitUntilListed(_ messageID: String, in place: MailStore.Place, _ runtime: ProjectsRuntime, _ condition: (MailStore.Listed) -> Bool) async throws {
        for _ in 0..<2_000 {
            if let row = await runtime.list(place).first(where: { $0.messageID == messageID }), condition(row) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The email did not show in its list as expected")
    }

    /// The list of `place` once it is as `condition` asks, however long sorting takes on a
    /// busy test runner. The test's time limit bounds the wait.
    private func listed(_ place: MailStore.Place, _ runtime: ProjectsRuntime, until condition: ([MailStore.Listed]) -> Bool) async throws -> [MailStore.Listed] {
        while true {
            let rows = await runtime.list(place)
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
            var readFiles: [String] = []
            var watchedFolders: [[String]] = []
        }

        private let state = Mutex(State())

        nonisolated var isHolding: Bool {
            state.withLock { $0.held != nil }
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

    /// The model, missing until a test puts it there. A job answers the first candidate of
    /// a sorting prompt at once, or with `blocks` waits until it is cancelled. Counts the
    /// jobs, those ended by a cancel, and the holders the window and the requests of the
    /// user take.
    final class FakeModel: Sendable {
        let holds = Count()
        let releases = Count()
        let jobs = Count()
        let ended = Count()
        let isThere = Mutex(false)
        let blocks = Mutex(false)

        @MainActor var environment: ProjectsModelEnvironment {
            ProjectsModelEnvironment(
                startJob: { [self] _, _ in
                    jobs.add()
                    if blocks.withLock({ $0 }) {
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
                endJob: { _ in #"P1", "reason": "fits"}"# },
                isDictating: { false },
                captionsOn: { false },
                memoryPressure: { .normal },
                voiceLoaded: { false },
                physicalMemory: 32 << 30,
                waitUntilLoaded: { [self] in isThere.withLock { $0 } },
                holdModel: { [holds] in holds.add() },
                releaseModel: { [holds, releases] in
                    holds.add(-1)
                    releases.add()
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

            var source: String {
                "Message-ID: <\(messageID)>\r\nDate: Sun, 18 Oct 2026 09:00:00 +0000\r\nFrom: \(from)\r\nTo: \(ProjectsRuntimeTests.own)\r\nSubject: \(subject)\r\nContent-Type: \(type); charset=utf-8\r\n\r\n\(text)\r\n"
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
                count: { mailbox in try self.answer("count") { mailbox == .inbox ? $0.inbox.count : 0 } },
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
                        return message.source
                    }
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
                reply: { _, _ in try self.answer("reply") { _ in } }
            )
        }
    }
}
