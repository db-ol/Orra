import Foundation
import Observation
import os

/// Projects while it is on (plan section 5, projects-window): the database and the project
/// list, the index of each project's folders, the scan of the chosen Mail mailboxes, the
/// sorting, and the model work of the Projects window.
///
/// - Nothing starts while Projects is off or in a build that hides it, see ProjectsSwitch.
///   It starts when the switch goes on and stops when it goes off. Stopping closes the
///   window, stops the scan, the sorting, the index, Retention and the model work, and closes
///   the project list and the database.
/// - The scan starts once the user confirmed the mailbox choice (decision 17), Mail runs, and
///   macOS allows Orra to control Mail. That check never shows the prompt, and neither do
///   the scan's events. A pass fixes its mailboxes and days when it begins, so a change that
///   takes a mailbox away or shortens the days stops the pass under way and starts the scan
///   again.
/// - The model loads only while the window is open or a request of the user runs (AGENTS.md).
///   The window holds it from when it opens until it closes, and closing it ends the
///   background work. With the window closed, new mail is sorted by the rules only. A request
///   of the user runs in a task the runtime keeps, see `userRequest(_:)`, so turning Projects
///   off ends it before the files close.
/// - Mail that waits is sorted after each save of the scan, when the window opens, and when
///   the cleanup model arrives while the window is open. When a project is added, changed
///   or forgotten, when the index of a changed project finishes, and when the user accepts
///   a rule, the mail the change reaches is sorted again, filed or not, since mail read
///   before had nothing to go to or went where the projects of then sent it, see
///   `resort(after:)`. A newer change ends the run under way, and the next run sorts by
///   both.
/// - The window lists each batch the scan saves at once, before sorting ends, and says what
///   the scan does: a pass that reads the mailboxes back to the days, and what ended the last
///   pass, see `ScanState`. Try Again starts the scan again at once, see `readAgain()`.
/// - Mail's handle of each email the scan lists is kept for Open Reply in Mail. The handles
///   hold for one Mail session, so the scan stops when Mail quits and starts again with Mail,
///   which lists every chosen mailbox back to the chosen days again.
/// - Delete All Projects Data waits for `closeBeforeDelete()`, which stops everything,
///   closes the files and forgets the mailbox choice, so nothing is read again before the
///   user confirms anew. Projects starts again with no data once the delete is done.
///
/// Logs counts, times and error codes only.
@Observable
final class ProjectsRuntime {
    /// What the runtime takes from the app. Closures and values, so tests pass fakes and
    /// code in Orra/Projects never reaches the pasteboard, the preferences or another app.
    nonisolated struct Dependencies {
        /// Where Projects keeps its data.
        var storage: ProjectsStorage
        var bridge: MailBridge
        /// The mailboxes the user chose in Settings, one instance for the app.
        var choice: MailChoice
        /// The user's addresses and name in a Debug build that sets them, read at each
        /// start. With them the scan never asks Mail for its accounts.
        var ownerOverride: () -> SortingService.Owner?
        /// The language of explanations, see ProjectsLanguage.forExplanations.
        var language: ProjectsLanguage
        /// True from the press of the talk key or the translation key until the dictation is
        /// pasted or cancelled, see EngineTurns.isDictating.
        var isDictating: () -> Bool
        /// Runs a closure at each press of the talk key or the translation key, before the
        /// dictation reserves the model gate, see EngineTurns.whenDictationStarts.
        var whenDictationStarts: (@escaping () -> Void) -> Void
        /// The model's closures for the queue, given the memory pressure the runtime
        /// watches, see TextCleanup.projectsEnvironment.
        var modelEnvironment: (_ memoryPressure: @escaping () -> ProjectsMemoryPressure.Level) -> ProjectsModelEnvironment
        /// Whether the cleanup model is on this Mac, read where it can be observed.
        var modelIsInstalled: () -> Bool
        /// Where the cleanup model's download stands while the model is not on this Mac, for
        /// the line under the mail list, read where it can be observed.
        var modelDownloadStatus: () -> ModelDownloadStatus
        /// Try Loading Again: looks at the cleanup model's files, hashes included, and loads
        /// the model again, see TextCleanup.retryLoading().
        var retryLoadingModel: @Sendable () async -> Void
        /// The cleanup model's tokenizer, or nil without the model, see ProjectsTokenCounter.
        var loadTokenCounter: @Sendable () async throws -> (@Sendable (String) -> Int)?
        /// Hands a draft to Mail or to the clipboard on the user's click, see ReplyHandoff.
        var handoff: ReplyHandoff
        /// Whether the memory pressure of the Mac is watched. Tests leave it normal.
        var watchesMemoryPressure: Bool
        /// Watches project folders, FolderEvents in the app.
        var watchFolders: FolderIndex.Watch
        /// Reads one file of a project folder, FileTextExtractor in the app.
        var readText: @Sendable (URL) async -> Result<FileTextResult, FileSkipReason>
        /// Recognizes the text of an image or of scanned PDF pages in a project folder,
        /// TextRecognizer in the app.
        var recognizeText: FolderIndex.Recognize
        /// Whether Low Power Mode is on and whether this Mac is hot, ProcessInfo's in the app.
        var power: @Sendable () -> PowerState
        /// Where a project's folders are now, Project.resolve in the app.
        var resolveFolders: @Sendable ([Data]) async -> [URL]
        /// Opens the database, ProjectsDatabase.open in the app.
        var openDatabase: @Sendable (ProjectsStorage) async throws -> ProjectsDatabase
        var now: @Sendable () -> Date
        /// Waits between the passes of the scan, the sweeps of the index and the runs of
        /// Retention.
        var sleep: @Sendable (Duration) async throws -> Void

        init(
            storage: ProjectsStorage,
            bridge: MailBridge,
            choice: MailChoice,
            ownerOverride: @escaping () -> SortingService.Owner?,
            language: ProjectsLanguage,
            isDictating: @escaping () -> Bool,
            whenDictationStarts: @escaping (@escaping () -> Void) -> Void = { _ in },
            modelEnvironment: @escaping (_ memoryPressure: @escaping () -> ProjectsMemoryPressure.Level) -> ProjectsModelEnvironment,
            modelIsInstalled: @escaping () -> Bool,
            modelDownloadStatus: @escaping () -> ModelDownloadStatus = { .none },
            retryLoadingModel: @escaping @Sendable () async -> Void = {},
            loadTokenCounter: @escaping @Sendable () async throws -> (@Sendable (String) -> Int)?,
            handoff: ReplyHandoff,
            watchesMemoryPressure: Bool = true,
            watchFolders: @escaping FolderIndex.Watch = FolderIndex.watchWithFolderEvents,
            readText: @escaping @Sendable (URL) async -> Result<FileTextResult, FileSkipReason> = ProjectsRuntime.readFile,
            recognizeText: @escaping FolderIndex.Recognize = ProjectsRuntime.recognize,
            power: @escaping @Sendable () -> PowerState = ProjectsRuntime.power,
            resolveFolders: @escaping @Sendable ([Data]) async -> [URL] = ProjectsRuntime.resolveFolders,
            openDatabase: @escaping @Sendable (ProjectsStorage) async throws -> ProjectsDatabase = ProjectsRuntime.openDatabase,
            now: @escaping @Sendable () -> Date = Date.init,
            sleep: @escaping @Sendable (Duration) async throws -> Void = ProjectsRuntime.sleep
        ) {
            self.storage = storage
            self.bridge = bridge
            self.choice = choice
            self.ownerOverride = ownerOverride
            self.language = language
            self.isDictating = isDictating
            self.whenDictationStarts = whenDictationStarts
            self.modelEnvironment = modelEnvironment
            self.modelIsInstalled = modelIsInstalled
            self.modelDownloadStatus = modelDownloadStatus
            self.retryLoadingModel = retryLoadingModel
            self.loadTokenCounter = loadTokenCounter
            self.handoff = handoff
            self.watchesMemoryPressure = watchesMemoryPressure
            self.watchFolders = watchFolders
            self.readText = readText
            self.recognizeText = recognizeText
            self.power = power
            self.resolveFolders = resolveFolders
            self.openDatabase = openDatabase
            self.now = now
            self.sleep = sleep
        }
    }

    /// Reads a file of a project folder with FileTextExtractor.
    @concurrent
    nonisolated static func readFile(_ url: URL) async -> Result<FileTextResult, FileSkipReason> {
        await FileTextExtractor().text(of: url)
    }

    /// Recognizes the text of a job's pages with TextRecognizer.
    @concurrent
    nonisolated static func recognize(_ job: RecognitionJob, mayGoOn: @escaping @Sendable () async -> Bool) async -> Result<RecognitionResult, FileSkipReason> {
        await TextRecognizer().recognize(job, mayGoOn: mayGoOn)
    }

    /// The states of the Mac that make text recognition wait.
    nonisolated struct PowerState: Sendable, Equatable {
        var isLowPowerModeOn = false
        /// The thermal state is serious or critical.
        var isHot = false
    }

    /// Low Power Mode and the thermal state, as ProcessInfo says now.
    nonisolated static func power() -> PowerState {
        let info = ProcessInfo.processInfo
        return PowerState(
            isLowPowerModeOn: info.isLowPowerModeEnabled,
            isHot: info.thermalState == .serious || info.thermalState == .critical)
    }

    /// Where a project's folders are now, with Project.resolve.
    @concurrent
    nonisolated static func resolveFolders(_ bookmarks: [Data]) async -> [URL] {
        await Project.resolve(bookmarks)
    }

    /// Opens the Projects database.
    @concurrent
    nonisolated static func openDatabase(_ storage: ProjectsStorage) async throws -> ProjectsDatabase {
        try await ProjectsDatabase.open(in: storage)
    }

    @concurrent
    nonisolated static func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    /// Where Projects stands.
    nonisolated enum Phase: Equatable, Sendable {
        case off
        case starting
        case on
        /// Everything has stopped, and the files are closing.
        case stopping
        /// The database or the project list could not be opened. Nothing runs.
        case failed
    }

    /// Why an action of the window did nothing.
    nonisolated enum Failure: Error, Equatable {
        /// Projects is not running.
        case off
        /// The window is closed, so no model work of the user starts.
        case windowClosed
        /// The store holds no email with this Message-ID.
        case unknownEmail
        /// The store keeps no text of the email to explain, see ProjectsWindowText.noText.
        case noText
        /// The list holds no project with this ID.
        case unknownProject
        /// The cleanup model is on this Mac but is not loaded, as after a load that failed,
        /// so a request of the user found no model, see `userRequest(_:)`.
        case modelNotLoaded
    }

    /// What Explain Message Selected in Mail found there (decision 18).
    nonisolated enum SelectedMessage: Equatable, Sendable {
        /// The message, by its Message-ID, which the store holds.
        case found(String)
        /// The user has not confirmed a mailbox choice, so nothing was read.
        case noMailboxChosen
        case mailNotRunning
        case nothingSelected
        /// The message is in a mailbox the user did not choose or link, so nothing more was
        /// read.
        case notInChosenMailbox
        /// The message is in a chosen mailbox, but the scan has not read it, such as mail
        /// older than the days the user chose.
        case notRead(days: Int)
        /// The scan has not reached the message yet, since a pass still reads the mailboxes.
        case stillReading
        /// The pass of the scan for the message ended as the store failed to save what it
        /// read, or to say which mail it knows, such as on a full disk.
        case notSaved
        /// The store holds another email with the message's Message-ID, see
        /// `isSelectedEmail`, such as when the message was made to look like it. The store
        /// keeps one email for each Message-ID, so that email is not shown for it.
        case otherEmail
        /// Orra may not control Mail.
        case notAllowed
        case failed(MailBridgeError)
    }

    /// What the window says about the scan: a pass that reads the mailboxes back to the
    /// days, or what ended the last pass. Nil while the scan only looks for new mail.
    nonisolated enum ScanState: Equatable, Sendable {
        /// A pass reads a mailbox back to the chosen days, which takes a while, with the
        /// emails it saved so far.
        case reading(saved: Int)
        /// Mail did not answer in time, so the scan waits longer before it asks again.
        case mailIsSlow
        /// macOS does not allow Orra to control Mail.
        case notAllowed
        /// Mail could not give some mail, or what the scan read could not be saved.
        case failed
    }

    /// Where the cleanup model's download stands, for the line under the mail list while the
    /// model is not on this Mac. The app maps it from the installer of TextCleanup.
    nonisolated enum ModelDownloadStatus: Equatable, Sendable {
        /// The model is on this Mac, or Orra still looks for it on disk.
        case none
        /// The model downloads, with the bytes so far and in all.
        case downloading(bytes: Int64, total: Int64)
        /// Orra checks the files it downloaded.
        case verifying
        /// The model is not on this Mac and no download runs, also after one failed.
        case missing
    }

    /// What runs while Projects is on.
    struct Running {
        let database: ProjectsDatabase
        let store: MailStore
        let list: ProjectList
        let index: FolderIndex
        let search: ChunkSearch
        let memory: ProjectsMemoryPressure
        let model: ProjectsModelEnvironment
        let queue: ProjectsModelQueue
        let sorting: SortingService
        let scan: MailScan
        let retention: Task<Void, Never>
    }

    /// How long the scan waits after Mail did not give the names of its mailboxes before it
    /// asks again, to find a linked mailbox (a guess). Once Mail gave them, the scan never
    /// asks again while Projects runs.
    nonisolated static let mailboxListingGap: TimeInterval = 600
    /// The most Mail handles of messages kept for the window. They hold for one Mail session.
    /// About as many as the emails within the longest days a busy mailbox holds (a guess).
    nonisolated static let maximumReferences = 20_000
    /// The most emails read at once to sort them again with the rules alone when the
    /// projects change. Sorting goes on with the next ones until it sorted them all.
    nonisolated static let resortBatch = 200
    /// The most emails read at once to sort them again with the model when the projects
    /// change (a guess). New mail and Explain Message Selected in Mail wait for the batch
    /// under way, see SortingService, so it is small.
    nonisolated static let resortModelBatch = 20

    private(set) var phase: Phase = .off
    /// What runs, nil while Projects is off.
    private(set) var running: Running?
    /// Whether the Projects window is open.
    private(set) var isWindowOpen = false
    /// Whether the open window holds the model, which it does while Projects runs.
    private(set) var windowHoldsModel = false
    /// Whether Mail runs, as last read.
    private(set) var mailIsRunning = false
    /// What the scan does, or what ended its last pass, for the window.
    private(set) var scanState: ScanState?
    /// How many emails wait for a reply, for the menu.
    private(set) var replyDueCount = 0
    /// Counts the changes of the mail the window lists, so it reads its lists again.
    private(set) var mailChanges = 0
    /// The linked mailboxes that Mail did not list the last time it gave the names of its
    /// mailboxes, by the name projects link them with.
    private(set) var missingMailboxes: Set<String> = []

    @ObservationIgnored let projects: ProjectsSwitch
    @ObservationIgnored let dependencies: Dependencies
    /// Closes the Projects window, which AppDelegate sets.
    @ObservationIgnored var closeWindow: () -> Void = {}
    @ObservationIgnored private var wantsOn = false
    /// The start or stop under way, which the next one waits for.
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var isFollowing = false
    @ObservationIgnored private var scanStarted = false
    @ObservationIgnored private var scanCheck: Task<Void, Never>?
    /// Whether the pass under way could not save what it read.
    @ObservationIgnored private var passSaveFailed = false
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    @ObservationIgnored private var sortAgain = false
    @ObservationIgnored private var countTask: Task<Void, Never>?
    /// The user as last read, so sorting prepares again when it changes.
    @ObservationIgnored private var lastOwner: SortingService.Owner?
    /// The explain service, while the window is open.
    @ObservationIgnored private var explainService: ExplainService?
    /// The load of the tokenizer's count, kept while the window is open. Requests that come
    /// while it loads wait for the same load, so the tokenizer file is read once.
    @ObservationIgnored private var tokenCounterLoad: Task<(@Sendable (String) -> Int)?, any Error>?
    /// Mailboxes by the name projects link them with, see `mailboxName(_:)`.
    @ObservationIgnored private var knownMailboxes: [String: MailMailbox] = [:]
    /// Whether Mail gave the names of its mailboxes since Projects started.
    @ObservationIgnored private var mailboxesListed = false
    /// When the scan last asked Mail for them.
    @ObservationIgnored private var lastMailboxListing: Date?
    /// Mail's handles of the messages read or listed in this Mail session, by Message-ID.
    @ObservationIgnored private var references: [String: MailMessageRef] = [:]
    /// For a Message-ID whose handle is kept, the other handle a later listing gave, such as
    /// of a copy from a list or of the email after the user moved it. It takes the place of
    /// the handle kept when that one is let go, see `checkedMailReference(for:all:)`.
    @ObservationIgnored private var listedAgain: [String: MailMessageRef] = [:]
    /// Counts the times the handles were let go, at a stop and when Mail quits, so a listing
    /// that began before never brings old ones back.
    @ObservationIgnored private var referenceSession = 0
    /// The most handles kept, `maximumReferences` in the app. Tests set fewer.
    @ObservationIgnored var referenceLimit = ProjectsRuntime.maximumReferences
    /// The emails a list of the window reads at once, `MailStore.listPage` in the app. When
    /// the projects change, sorting again asks the model only about as many of the newest
    /// emails the change reaches that the rules left to it. Tests set fewer.
    @ObservationIgnored var listPage = MailStore.listPage
    /// The emails read at once to sort them again with the rules alone, `resortBatch` in
    /// the app. Tests set fewer.
    @ObservationIgnored var resortBatchLimit = ProjectsRuntime.resortBatch
    /// The emails read at once to sort them again with the model, `resortModelBatch` in the
    /// app. Tests set fewer.
    @ObservationIgnored var resortModelBatchLimit = ProjectsRuntime.resortModelBatch
    /// How long Explain Message Selected in Mail waits for sorting to file a message,
    /// `sortingWait` in the app. Nil waits until sorting filed it, for tests that check the
    /// list the window then shows, so the speed of a busy test runner does not decide that
    /// list.
    @ObservationIgnored var sortingWaitLimit: Duration? = ProjectsRuntime.sortingWait
    /// Reads the real path of a project folder for the email view, see
    /// `folderRoots(of:)`, FolderWalk.realPath(of:) in the app. Tests hold it, as a folder on
    /// a share that hangs would hold it.
    @ObservationIgnored var readRealPath: @Sendable (URL) async -> URL? = FolderWalk.realPath(of:)
    @ObservationIgnored private var modelWasInstalled = false
    /// Projects whose index is at work, so sorting prepares again when one finishes.
    @ObservationIgnored private var indexing: Set<UUID> = []
    /// The mailbox choice as last seen, so a change that takes a mailbox away or shortens
    /// the days stops the pass under way.
    @ObservationIgnored private var followedChoice: (mailboxes: Set<MailMailbox>, days: Int)?
    /// The sorting again after a change of the projects under way, which a newer one ends.
    @ObservationIgnored private var resortTask: Task<Void, Never>?
    /// The changes of the projects since the last run of sorting again that ended, which the
    /// next run sorts by, so a run that a newer change ends loses nothing.
    @ObservationIgnored private var pendingChange: SortingService.Change?
    /// Projects added or changed whose index has not finished since, so the mail they reach
    /// is sorted again with their file names once it does.
    @ObservationIgnored private var resortAfterIndex: Set<UUID> = []
    /// The requests of the user under way, which stopping ends, see `userRequest(_:)`.
    @ObservationIgnored private var userRequests: [UUID: UserRequest] = [:]
    /// The resolves of project folders under way, by their bookmarks, see
    /// `resolve(_:)`. They outlive a stop, since a resolve cannot be cancelled.
    @ObservationIgnored private var resolving: [[Data]: Task<[URL], Never>] = [:]
    /// Where each folder bookmark last found its folder while Orra runs, so a folder that
    /// is not available now, such as on a disk that is not connected, is also known by where
    /// it was last, after the user renamed or moved it too, see `folderRoots(of:)`.
    @ObservationIgnored private var lastFound: [Data: URL] = [:]
    /// The newest write of the text the user typed into each email's draft since Projects
    /// started, by Message-ID, which stopping waits for, see `saveEditedDraft(_:for:)`.
    @ObservationIgnored private var draftSaves: [String: Task<Bool, Never>] = [:]

    /// A request of the user under way: how to end it, and a task that ends with it.
    private struct UserRequest {
        let cancel: () -> Void
        let ended: Task<Void, Never>
    }

    init(projects: ProjectsSwitch, dependencies: Dependencies) {
        self.projects = projects
        self.dependencies = dependencies
    }

    /// Whether the menus show Open Projects Window: while Projects is on, also while it
    /// starts or after it failed to start, so the window can say why.
    var showsMenuItem: Bool {
        phase != .off && phase != .stopping
    }

    /// Whether the Projects window may open: while the switch is on, also right after it
    /// went on and before Projects has started, as when Settings opens the window then.
    /// Never during Delete All Projects Data, which stops Projects and closes the window
    /// while the switch stays on.
    var canOpenWindow: Bool {
        projects.isOn && !projects.isDeleting
    }

    /// Why the model work waits now, nil while it runs or when none runs.
    var pause: ProjectsModelQueue.Pause? {
        running?.queue.pause
    }

    /// Whether sorting works on a batch of mail now, for the window.
    var isSorting: Bool {
        (running?.sorting.unfinishedBatches ?? 0) > 0
    }

    /// The user's projects, in the order they were added.
    var projectList: [Project] {
        running?.list.projects ?? []
    }

    /// The report of a project's index, nil while it is not indexed.
    func indexReport(_ project: UUID) -> FolderIndex.Report? {
        running?.index.reports[project]
    }

    /// The mailbox choice, for the window's lines.
    var choice: MailChoice {
        dependencies.choice
    }

    /// Hands a draft to Mail or the clipboard, for the email view.
    var handoff: ReplyHandoff {
        dependencies.handoff
    }

    // MARK: Following the switch

    /// Starts following the switch at launch: Projects starts now when it is on, and starts
    /// and stops with it from then on. Delete All Projects Data waits for
    /// `closeBeforeDelete()`.
    func follow() {
        guard !isFollowing else { return }
        isFollowing = true
        projects.closeBeforeDelete = { [weak self] in
            await self?.closeBeforeDelete()
        }
        modelWasInstalled = dependencies.modelIsInstalled()
        // The model work gives way at the press of a key, before the dictation reserves the
        // model gate, see ProjectsModelQueue.dictationStarted, and so does the page text
        // recognition reads.
        dependencies.whenDictationStarts { [weak self] in
            self?.running?.queue.dictationStarted()
            self?.running?.index.interruptRecognition()
        }
        followSwitch()
        followChoice()
        followModel()
        matchSwitch()
    }

    private func followSwitch() {
        withObservationTracking {
            _ = projects.isOn
            _ = projects.isDeleting
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.matchSwitch()
                self?.followSwitch()
            }
        }
    }

    /// Starts or stops the scan with the confirm. A pass fixes its mailboxes and days when
    /// it begins, so one that takes a mailbox away or shortens the days stops the pass under
    /// way, and the scan starts again with the choice as it is now.
    private func followChoice() {
        let choice = withObservationTracking {
            _ = dependencies.choice.isConfirmed
            return (mailboxes: Set(dependencies.choice.mailboxes), days: dependencies.choice.days)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.followChoice()
            }
        }
        if let before = followedChoice, !choice.mailboxes.isSuperset(of: before.mailboxes) || choice.days < before.days {
            restartScan()
        }
        followedChoice = choice
        updateScan()
    }

    /// Sorts the mail that waits for the model when the model arrives while the window is
    /// open (#140).
    private func followModel() {
        let installed = withObservationTracking {
            dependencies.modelIsInstalled()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.followModel()
            }
        }
        if installed, !modelWasInstalled, windowHoldsModel {
            requestSort()
        }
        modelWasInstalled = installed
    }

    /// Prepares sorting again whenever a project's index finishes a sweep, since its file
    /// names count for sorting. When the project was added or changed since, the mail it
    /// reaches is sorted again too.
    private func followIndex(_ index: FolderIndex) {
        let reports = withObservationTracking {
            index.reports
        } onChange: { [weak self, weak index] in
            DispatchQueue.main.async {
                guard let self, let index, self.running?.index === index else { return }
                self.followIndex(index)
            }
        }
        let working = Set(reports.filter(\.value.isIndexing).keys)
        let finished = indexing.subtracting(working)
        indexing = working
        // Read from the reports, not from the change, so a sweep that ended before this
        // looked counts too.
        let indexed = resortAfterIndex.filter { reports[$0]?.isIndexing == false }
        if !finished.isEmpty || !indexed.isEmpty {
            running?.sorting.projectsChanged()
        }
        if !indexed.isEmpty {
            resortAfterIndex.subtract(indexed)
            resort(after: SortingService.Change(projects: indexed))
        }
    }

    /// Starts or stops Projects to match the switch, after the start or stop under way.
    private func matchSwitch() {
        let wanted = projects.isOn && !projects.isDeleting
        guard wanted != wantsOn else { return }
        wantsOn = wanted
        enqueue { runtime in
            if wanted {
                await runtime.startNow()
            } else {
                await runtime.stopNow()
            }
        }
    }

    /// Runs a start or a stop after the one before it.
    @discardableResult
    private func enqueue(_ work: @escaping (ProjectsRuntime) async -> Void) -> Task<Void, Never> {
        let previous = transition
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        transition = task
        return task
    }

    /// Stops everything and closes the list and the database, then forgets the mailbox
    /// choice, before Delete All Projects Data removes the files.
    func closeBeforeDelete() async {
        wantsOn = false
        await enqueue { runtime in await runtime.stopNow() }.value
        dependencies.choice.forget()
    }

    /// Tries to start again after a start failed.
    func retry() {
        guard phase == .failed, wantsOn else { return }
        enqueue { runtime in await runtime.startNow() }
    }

    // MARK: Starting and stopping

    private func startNow() async {
        guard wantsOn, running == nil else { return }
        phase = .starting
        let started = ContinuousClock.now
        let database: ProjectsDatabase
        do {
            database = try await dependencies.openDatabase(dependencies.storage)
        } catch {
            Logger.projects.error("Projects could not open its database: \(Self.logName(error), privacy: .public)")
            phase = .failed
            return
        }
        let store = MailStore(database: database)
        let list = ProjectList(storage: dependencies.storage)
        // Before the index, whose text recognition waits while memory runs low. It starts
        // watching below, once Projects runs.
        let memory = ProjectsMemoryPressure()
        let index = FolderIndex(
            database: database,
            isDictating: dependencies.isDictating,
            readText: dependencies.readText,
            recognize: dependencies.recognizeText,
            recognitionPause: { [weak self] in self?.recognitionPause() },
            sleep: dependencies.sleep,
            watch: dependencies.watchFolders
        )
        do {
            try await list.load()
            try await list.reconcile(mail: store, index: index)
        } catch {
            Logger.projects.error("Projects could not open its project list: \(Self.logName(error), privacy: .public)")
            await list.close()
            await store.close()
            phase = .failed
            return
        }
        guard wantsOn else {
            await list.close()
            await store.close()
            phase = .off
            return
        }
        if dependencies.watchesMemoryPressure {
            memory.start()
        }
        let model = dependencies.modelEnvironment({ [memory] in memory.level })
        let queue = ProjectsModelQueue(environment: model)
        let search = ChunkSearch(database: database)
        let sorting = SortingService(
            lookups: store.sortingLookups(
                projects: { [list] in list.projects.map(\.candidate) },
                owner: { [weak self] in await self?.owner() ?? SortingService.Owner(addresses: []) },
                fileNames: { [index] project in (try? await index.fileNames(project: project)) ?? [] },
                scores: { [search] text in (try? await search.projectScores(text)) ?? [:] }
            ),
            saves: store.sortingSaves(),
            windowIsOpen: { [weak self] in self?.windowHoldsModel ?? false },
            ask: { [queue] request in try await queue.run(request) },
            now: dependencies.now
        )
        let scan = MailScan(
            bridge: Self.remembering(
                dependencies.bridge,
                session: { [weak self] in await self?.referenceSession },
                listed: { [weak self] listings, session in await self?.rememberListed(listings, session: session) }
            ),
            choice: dependencies.choice,
            lookups: MailScan.Lookups(
                known: { [store] ids in try await Self.known(ids, in: store) },
                linkedMailboxes: { [weak self] in await self?.linkedMailboxes() ?? [] }
            ),
            save: { [weak self] messages in try await self?.saveScanned(messages) },
            report: { [weak self] report in self?.scanReported(report) },
            ownerOverride: dependencies.ownerOverride(),
            isOn: { [projects] in projects.isOn },
            isDictating: dependencies.isDictating,
            now: dependencies.now,
            sleep: dependencies.sleep
        )
        let retention = Retention.start(store: store, now: dependencies.now, sleep: dependencies.sleep, removed: { [weak self] in
            await self?.mailChanged()
        })
        forgetReferences()
        running = Running(
            database: database, store: store, list: list, index: index, search: search, memory: memory,
            model: model, queue: queue, sorting: sorting, scan: scan, retention: retention
        )
        phase = .on
        // A folder can take long to resolve, and a stop or a delete waits for this start,
        // so each project's folders resolve in a task of their own.
        for project in list.projects {
            Task { [weak self] in
                await self?.startIndex(project)
            }
        }
        followIndex(index)
        mailIsRunning = dependencies.bridge.isRunning()
        updateScan()
        if isWindowOpen {
            attachWindow()
        }
        requestSort()
        mailChanged()
        Logger.projects.notice("Projects started with \(list.projects.count, privacy: .public) projects in \(Self.seconds(started.duration(to: .now)), privacy: .public)")
    }

    private func stopNow() async {
        guard let running else {
            // The window can open before Projects runs, see canOpenWindow. It closes here
            // too, after a failed start or a start the switch overtook.
            if isWindowOpen {
                closeWindow()
                isWindowOpen = false
                detachWindow()
            }
            if phase == .failed {
                phase = .off
            }
            return
        }
        closeWindow()
        isWindowOpen = false
        detachWindow()
        let requests = Array(userRequests.values)
        userRequests = [:]
        for request in requests {
            request.cancel()
        }
        scanCheck?.cancel()
        scanCheck = nil
        running.scan.stop()
        scanStarted = false
        show(nil)
        passSaveFailed = false
        sortTask?.cancel()
        sortTask = nil
        sortAgain = false
        resortTask?.cancel()
        resortTask = nil
        pendingChange = nil
        resortAfterIndex = []
        running.sorting.stop()
        running.queue.cancelBackground()
        running.index.stopAll()
        running.retention.cancel()
        running.memory.stop()
        countTask?.cancel()
        countTask = nil
        self.running = nil
        // The writes of the text the user typed into drafts, with those that closing the
        // window started. None starts from here on, since nothing runs.
        let draftSaves = Array(self.draftSaves.values)
        self.draftSaves = [:]
        phase = .stopping
        lastOwner = nil
        knownMailboxes = [:]
        mailboxesListed = false
        lastMailboxListing = nil
        missingMailboxes = []
        forgetReferences()
        indexing = []
        replyDueCount = 0
        mailChanges += 1
        // A request of the user ends at its next slice of the model. It saves nothing into
        // the files after they close.
        for request in requests {
            await request.ended.value
        }
        for save in draftSaves {
            _ = await save.value
        }
        await running.list.close()
        await running.store.close()
        // Off once the files are closed.
        phase = .off
        Logger.projects.notice("Projects stopped, \(requests.count, privacy: .public) requests of the user ended")
    }

    // MARK: The window

    /// The window opened: while Projects runs, it holds the model until it closes, the
    /// explain service is made, and the mail that waits for the model is sorted.
    func windowOpened() {
        guard !isWindowOpen else { return }
        isWindowOpen = true
        Logger.projects.notice("Projects window opened")
        attachWindow()
    }

    /// The window closed: background work ends, the model is let go, and the explain
    /// service with its tokenizer goes. A request of the user under way holds the model
    /// until it ends.
    func windowClosed() {
        guard isWindowOpen else { return }
        isWindowOpen = false
        Logger.projects.notice("Projects window closed")
        detachWindow()
    }

    private func attachWindow() {
        guard let running, isWindowOpen, !windowHoldsModel else { return }
        windowHoldsModel = true
        running.model.holdModel()
        explainService = ExplainService(
            lookups: explainLookups(running),
            run: { [queue = running.queue] request in try await queue.run(request) },
            loadTokenCounter: { [weak self] in try await self?.tokenCounter() },
            save: running.store.explanationSave(now: dependencies.now),
            language: dependencies.language,
            now: dependencies.now
        )
        mailRunningChanged()
        requestSort()
    }

    private func detachWindow() {
        explainService = nil
        tokenCounterLoad = nil
        guard windowHoldsModel else { return }
        windowHoldsModel = false
        if let running {
            running.queue.cancelBackground()
            running.model.releaseModel()
        }
    }

    /// The tokenizer's count, loaded once while the window is open. A failed load, or one
    /// that found no model, is not kept, so the next request tries again.
    private func tokenCounter() async throws -> (@Sendable (String) -> Int)? {
        if let tokenCounterLoad {
            return try await tokenCounterLoad.value
        }
        let load = Task { [loader = dependencies.loadTokenCounter] in try await loader() }
        if windowHoldsModel {
            tokenCounterLoad = load
        }
        do {
            let loaded = try await load.value
            if loaded == nil, tokenCounterLoad == load {
                tokenCounterLoad = nil
            }
            return loaded
        } catch {
            if tokenCounterLoad == load {
                tokenCounterLoad = nil
            }
            throw error
        }
    }

    // MARK: Mail

    /// Mail started or quit, which AppDelegate hears from the workspace.
    func mailRunningChanged() {
        let running = dependencies.bridge.isRunning()
        if running != mailIsRunning {
            mailIsRunning = running
            // Mail's handles hold for one Mail session only. The scan stops with Mail, so it
            // starts again with the next Mail and lists the mailboxes back to the days, which
            // gives the handles of the mail it knows again.
            if !running {
                forgetReferences()
                scanCheck?.cancel()
                scanCheck = nil
                if scanStarted, let scan = self.running?.scan {
                    scan.stop()
                    scanStarted = false
                }
                // The window says that Mail is not open.
                show(nil)
            }
        }
        updateScan()
    }

    /// Settings changed whether Orra may control Mail. A scan that waits after a refusal
    /// starts again at once.
    func mailAccessChanged() {
        readAgain()
    }

    /// Try Again in the window, after Mail did not answer or the scan failed: the scan stops
    /// with the wait it is in and starts again at once, once the check allows it. Its first
    /// pass reads the mailboxes back to the days, so it also reads what a failed save lost.
    func readAgain() {
        restartScan()
        updateScan()
    }

    /// Stops the scan with the pass under way, which reads no further, and starts it again
    /// once the check allows it. The new pass reads the mailboxes and days as they are now.
    private func restartScan() {
        guard let running, scanStarted else { return }
        running.scan.stop()
        scanStarted = false
        show(nil)
        updateScan()
    }

    /// Starts the scan once the user confirmed the mailbox choice, Mail runs and macOS
    /// allows Orra to control Mail, and stops it when the confirm is forgotten. A check that
    /// gets no answer in time starts it too: its events never show the prompt, and it waits
    /// longer after each refusal.
    private func updateScan() {
        guard let running else { return }
        guard dependencies.choice.isConfirmed else {
            if scanStarted {
                running.scan.stop()
                scanStarted = false
            }
            // The window says that Projects reads no mail yet.
            show(nil)
            return
        }
        guard !scanStarted, scanCheck == nil, dependencies.bridge.isRunning() else { return }
        let bridge = dependencies.bridge
        scanCheck = Task { [weak self] in
            // Never asks, so macOS never shows its prompt here.
            let permission = await bridge.permission(false)
            // Cancelled when Mail quit or Projects stopped, which let go of this check, and a
            // newer one may run.
            guard let self, !Task.isCancelled else { return }
            self.scanCheck = nil
            guard let current = self.running, current.scan === running.scan, !self.scanStarted,
                  self.dependencies.choice.isConfirmed else { return }
            guard permission == .allowed || permission == .unknown else {
                Logger.projectsMail.notice("Mail scan: not started, permission \(String(describing: permission), privacy: .public)")
                if permission == .denied || permission == .notAsked {
                    self.show(.notAllowed)
                }
                return
            }
            self.show(nil)
            current.scan.start()
            self.scanStarted = true
        }
    }

    /// Whether the scan runs, for tests.
    var isScanning: Bool {
        scanStarted
    }

    /// What a pass of the scan told: one that reads the mailboxes back to the days shows as
    /// reading, and its end shows what stopped it, if anything. A poll changes nothing until
    /// it ends, so the window does not flicker each minute. Neither does a pass after one
    /// that failed, which reads back what failed and may fail the same way, as a mailbox
    /// Mail no longer has does at each pass.
    private func scanReported(_ report: MailScan.Report) {
        guard running != nil else { return }
        switch report {
        case .began(let readsBack):
            passSaveFailed = false
            if readsBack, scanState != .failed {
                show(.reading(saved: 0))
            }
        case .ended(let pass):
            show(Self.scanState(after: pass, saveFailed: passSaveFailed))
        }
    }

    /// What the window says once a pass ended: why it stopped, that some mail could not be
    /// read or saved, or nothing. A message Mail gives with no source, or not at all, ends no
    /// pass, and later passes read it again. A pass the store ended, since it could not save
    /// what the pass read or say which mail it knows, says that some mail could not be read,
    /// and the next pass reads that mailbox back. A pass that Projects, the confirm or Mail
    /// ended says nothing, since the window says why on its own.
    nonisolated static func scanState(after pass: MailScan.Pass, saveFailed: Bool) -> ScanState? {
        if pass.skipped == .storeFailed {
            return .failed
        }
        guard pass.skipped == nil else { return nil }
        if saveFailed {
            return .failed
        }
        switch pass.error {
        case .notAnswered?, .timedOut?: return .mailIsSlow
        case .denied?, .notAsked?: return .notAllowed
        case .notFound?, .changedWhileReading?, .unexpectedReply?, .failed?: return .failed
        case .mailNotRunning?: return nil
        case nil: return pass.unreadable > 0 ? .failed : nil
        }
    }

    /// Changes what the window says about the scan, only when it differs, since each change
    /// makes the window draw again.
    private func show(_ state: ScanState?) {
        if scanState != state {
            scanState = state
        }
    }

    /// The user's addresses and name: the Debug override, else Mail's accounts once the
    /// scan may read them, else none. Sorting prepares again when they change.
    func owner() async -> SortingService.Owner {
        guard let running else { return SortingService.Owner(addresses: []) }
        if let owner = await running.scan.owner() {
            if owner != lastOwner {
                lastOwner = owner
                running.sorting.projectsChanged()
            }
            return owner
        }
        return lastOwner ?? SortingService.Owner(addresses: [])
    }

    /// Saves what the scan read, lists it in the window at once as not sorted yet, and sorts
    /// the mail that waits. A batch sorting still works on, such as while the model is paused
    /// or slow, does not hold the new mail back from the window. A failed save is logged with
    /// its code and thrown, so the scan reads that mail again in its next pass, and the window
    /// says so.
    private func saveScanned(_ messages: [MailScan.Message]) async throws {
        guard let running, !messages.isEmpty else { return }
        // Kept before the first wait, so a stop or Mail's quit meanwhile lets them go. Handles
        // from before Mail quit are not kept.
        if dependencies.bridge.isRunning() {
            for message in messages {
                remember(message.reference, for: message.messageID)
            }
        }
        let owner = await owner()
        let now = dependencies.now()
        do {
            let saved = try await running.store.save(messages.map { Self.storeMessage($0, now: now) }, ownAddresses: owner.addresses, at: now)
            Logger.projects.notice("Projects saved \(saved.count, privacy: .public) of \(messages.count, privacy: .public) emails the scan read")
            if self.running?.database === running.database, !saved.isEmpty {
                if case .reading(let before)? = scanState {
                    show(.reading(saved: before + saved.count))
                }
                mailChanged()
            }
        } catch {
            Logger.projects.error("Projects could not save the emails the scan read: \(Self.logName(error), privacy: .public)")
            if self.running?.database === running.database {
                passSaveFailed = true
                show(.failed)
            }
            throw error
        }
        requestSort()
    }

    /// Sorts the mail that waits, after the sorting under way.
    func requestSort() {
        guard let sorting = running?.sorting else { return }
        guard sortTask == nil else {
            sortAgain = true
            return
        }
        sortTask = Task { [weak self] in
            repeat {
                self?.sortAgain = false
                await sorting.sortWaiting()
                guard !Task.isCancelled else { return }
                self?.mailChanged()
            } while self?.sortAgain == true
            self?.sortTask = nil
        }
    }

    /// Waits until sorting decided where an email goes, for at most `sortingWaitLimit`, such
    /// as for a message the scan just saved. It never waits for the sorting of other mail.
    func waitUntilSorted(_ messageID: String) async {
        guard let running else { return }
        let store = running.store
        let limit = sortingWaitLimit
        let started = ContinuousClock.now
        while limit.map({ started.duration(to: .now) < $0 }) ?? true, !Task.isCancelled, self.running?.database === running.database {
            if (try? await store.filed(messageID)) != nil {
                return
            }
            try? await Task.sleep(for: Self.selectionPoll)
        }
    }

    /// How long Explain Message Selected in Mail waits for sorting to file a message the
    /// scan just saved, so the message shows in its list and is explained for its project
    /// (a guess).
    nonisolated static let sortingWait: Duration = .seconds(2)

    /// Sorts again, after a change of the projects, the mail it reaches, which the user did
    /// not move, see `MailStore.resortIDs(reaching:)`. First the rules alone go through all
    /// of it, oldest first, `resortBatchLimit` emails at a time. They save what they file on
    /// their own, and send a filing whose setting is gone to Needs a Project, so the moves
    /// they decide show at once, and no such filing votes for its old project while the
    /// model decides. Then the model goes through the newest `listPage` of what the rules
    /// left to it, see `MailStore.resortPage(_:newest:)`, `resortModelBatchLimit` emails at
    /// a time, so the model work stays within that bound, and it is asked only where the
    /// email waits for it or the change can alter its answer, see
    /// `SortingService.sortAgain(_:after:rulesOnly:)`. Each batch reads its emails when its
    /// turn comes. A newer change ends the run under way, and the next run sorts by both,
    /// so one runs at a time and a run cut short loses nothing.
    private func resort(after change: SortingService.Change) {
        guard let running else { return }
        let store = running.store
        let sorting = running.sorting
        let newest = listPage
        let rulesBatch = max(1, resortBatchLimit)
        let modelBatch = max(1, resortModelBatchLimit)
        let pending = pendingChange.map { $0.union(change) } ?? change
        pendingChange = pending
        let previous = resortTask
        previous?.cancel()
        resortTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let reached = try? await store.resortIDs(reaching: pending) else { return }
            var ids = reached
            for rulesOnly in [true, false] {
                if !rulesOnly {
                    // The model on the newest of what the rules left to it, as they left it.
                    guard !Task.isCancelled, let page = try? await store.resortPage(reached, newest: newest) else { return }
                    ids = page
                }
                let batch = rulesOnly ? rulesBatch : modelBatch
                for start in stride(from: 0, to: ids.count, by: batch) {
                    guard !Task.isCancelled, self?.running?.sorting === sorting else { return }
                    await sorting.sortAgain(Array(ids[start..<min(start + batch, ids.count)]), after: pending.projects, rulesOnly: rulesOnly)
                    // Also when a newer change ended it, since some emails may have moved.
                    self?.mailChanged()
                }
            }
            guard !Task.isCancelled else { return }
            self?.pendingChange = nil
        }
    }

    /// What a change of a project touched, nil before for a new project and nil after for
    /// a forgotten one: the project, and the people, domains and linked mailboxes it gained
    /// or lost, its sender and domain rules among them. Internal for tests.
    nonisolated static func change(from before: Project?, to after: Project?) -> SortingService.Change {
        func addresses(_ project: Project?) -> Set<String> {
            let people = project?.people.map(\.address) ?? []
            let rules = project?.rules.filter { $0.kind == .sender }.map(\.value) ?? []
            return Set((people + rules).compactMap(ProjectsAddress.normalized))
        }
        func domains(_ project: Project?) -> Set<String> {
            let rules = project?.rules.filter { $0.kind == .domain }.map(\.value) ?? []
            return Set(((project?.domains ?? []) + rules).compactMap { domain -> String? in
                // As SortingSignals compares a domain.
                let trimmed = SortingText.address(domain)
                let bare = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
                return bare.isEmpty ? nil : bare
            })
        }
        return SortingService.Change(
            projects: Set([before?.id, after?.id].compactMap { $0 }),
            addresses: addresses(before).symmetricDifference(addresses(after)),
            domains: domains(before).symmetricDifference(domains(after)),
            mailboxes: Set(before?.mailboxes ?? []).symmetricDifference(after?.mailboxes ?? []))
    }

    /// Waits until the sorting again after a change of the projects ends, also one that a
    /// newer change started meanwhile, for tests.
    func untilResorted() async {
        while let task = resortTask {
            await task.value
            if task == resortTask { return }
        }
    }

    /// The mail changed: the window reads its lists again and the menu its count.
    private func mailChanged() {
        mailChanges += 1
        guard let store = running?.store else { return }
        countTask?.cancel()
        countTask = Task { [weak self] in
            guard let count = try? await store.replyDueCount(), !Task.isCancelled else { return }
            self?.replyDueCount = count
        }
    }

    /// The emails of a list of the window, newest first, at most `limit`, none while
    /// Projects does not run. Throws when the store could not read them, which the window
    /// says, since an empty list would say there is no mail.
    func list(_ place: MailStore.Place, limit: Int = MailStore.listPage) async throws -> [MailStore.Listed] {
        guard let store = running?.store else { return [] }
        do {
            return try await store.list(place, limit: limit)
        } catch {
            Logger.projects.error("Projects could not read a list of mail: \(Self.logName(error), privacy: .public)")
            throw error
        }
    }

    /// An email as a list of the window shows it, read alone, nil when the store does not
    /// hold it.
    func listed(_ messageID: String) async -> MailStore.Listed? {
        try? await running?.store.listed(messageID)
    }

    /// How many emails a list of the window holds.
    func count(_ place: MailStore.Place) async -> Int {
        (try? await running?.store.count(place)) ?? 0
    }

    /// The list that holds an email and how many emails come before it there, nil when the
    /// store does not hold it.
    func position(of messageID: String) async -> (place: MailStore.Place, index: Int)? {
        try? await running?.store.position(of: messageID)
    }

    /// Where an email is listed, for Explain Message Selected in Mail.
    func place(of messageID: String) async -> MailStore.Place {
        await position(of: messageID)?.place ?? .needsProject
    }

    /// The user moves an email to a project, or to Needs a Project with nil. Returns the rule
    /// to offer after two moves of the same kind.
    func move(_ messageID: String, to project: UUID?) async -> SortingService.RuleOffer? {
        guard let running, let email = try? await running.store.sortingEmail(messageID) else { return nil }
        let offer = await running.sorting.move(email, to: project)
        mailChanged()
        return offer
    }

    /// Adds the rule the user accepted to its project, and sorts again the mail the rule
    /// reaches.
    func accept(_ offer: SortingService.RuleOffer) async throws {
        guard let running else { throw Failure.off }
        guard let before = running.list.project(offer.project) else { throw Failure.unknownProject }
        let rule = Project.Rule(offer.rule)
        guard !before.rules.contains(rule) else { return }
        var project = before
        project.rules.append(rule)
        try await running.list.update(project)
        running.sorting.projectsChanged()
        resort(after: Self.change(from: before, to: project))
    }

    /// Removes a rule from its project, for Remove Rule on the project page. Mail read from
    /// now on is sorted without it. The mail it filed stays where it is, and nothing is
    /// sorted again.
    func removeRule(_ rule: Project.Rule, from projectID: UUID) async throws {
        guard let running else { throw Failure.off }
        guard var project = running.list.project(projectID) else { throw Failure.unknownProject }
        guard project.rules.contains(rule) else { return }
        project.rules.removeAll { $0 == rule }
        try await running.list.update(project)
        running.sorting.projectsChanged()
    }

    // MARK: Projects

    /// Adds a project, starts indexing its folders and sorts again the mail it reaches.
    func add(_ project: Project) async throws {
        guard let running else { throw Failure.off }
        let before = running.list.project(project.id)
        try await running.list.add(project, mail: running.store)
        projectChanged(project, change: Self.change(from: before, to: project))
    }

    /// Saves a changed project, indexes its folders as they are now and sorts again the mail
    /// the change reaches. A change of the folders alone, or a Save with no change, sorts
    /// nothing again until the index of the folders finishes. A linked mailbox it no longer
    /// has is not read further. Its rules stay as the list has them, since Edit Project does
    /// not change rules, so a rule added or removed while its sheet was open stays so.
    func update(_ project: Project) async throws {
        guard let running else { throw Failure.off }
        var project = project
        let before = running.list.project(project.id)
        if let before {
            project.rules = before.rules
        }
        let linked = linkedNames
        try await running.list.update(project)
        if !linkedNames.isSuperset(of: linked) {
            restartScan()
        }
        // Sorting reads the project without its folders.
        projectChanged(project, change: before?.candidate == project.candidate ? nil : Self.change(from: before, to: project))
    }

    /// Starts indexing the project's folders as they are now, and sorts again the mail
    /// `change` reaches, if any.
    private func projectChanged(_ project: Project, change: SortingService.Change?) {
        running?.sorting.projectsChanged()
        updateMissingMailboxes()
        Task { [weak self] in
            await self?.startIndex(project, resortAfter: true)
        }
        if let change {
            resort(after: change)
        }
        mailChanged()
    }

    /// Forget Project: removes the project with its mail, drafts, counts and index, and
    /// sorts again the mail the change reaches, since the project no longer counts among
    /// the candidates. Its linked mailbox is not read further.
    func forget(_ project: UUID) async throws {
        guard let running else { throw Failure.off }
        let before = running.list.project(project)
        let linked = linkedNames
        try await running.list.forget(project, mail: running.store, index: running.index)
        resortAfterIndex.remove(project)
        if !linkedNames.isSuperset(of: linked) {
            restartScan()
        }
        running.sorting.projectsChanged()
        updateMissingMailboxes()
        resort(after: Self.change(from: before, to: nil))
        mailChanged()
    }

    /// The names of the mailboxes linked to a project.
    private var linkedNames: Set<String> {
        Set(running?.list.projects.flatMap(\.mailboxes) ?? [])
    }

    /// The files of a project that give no text, with why.
    func skippedFiles(_ project: UUID) async -> [FolderIndex.SkippedFile] {
        (try? await running?.index.skippedFiles(project: project)) ?? []
    }

    /// The files of a project whose hidden text the index left out.
    func filesWithHiddenText(_ project: UUID) async -> [URL] {
        (try? await running?.index.filesWithHiddenText(project: project)) ?? []
    }

    /// Where a project's folders are now.
    func folders(of project: Project) async -> [URL] {
        await resolve(project.folders)
    }

    /// A project's folders as they are now, for the files of an explanation in the email
    /// view: the real path of each folder that is there, as the index keeps its files, and
    /// where each folder whose bookmark finds nothing was, such as one on a disk that is not
    /// connected: where the bookmark last found it while Orra runs, and the path it keeps
    /// from when the user added the folder. The bookmarks resolve as for the index, see
    /// `resolve(_:)`, and when some find nothing, each resolves alone to tell which. Then
    /// the real paths are read one folder at a time. It reads the folders' own metadata
    /// only, never what is inside them.
    ///
    /// Empty for a project the list does not hold. Nil while Projects is off, and when
    /// Projects stopped, is turning off or the project's folders changed meanwhile, as in
    /// `startIndex(_:resortAfter:)`, or the task that asked was cancelled, as when the list
    /// closed: after every wait, before the next folder is read and before it returns, so no
    /// folder is read after Projects turned off, for a folder the project no longer holds or
    /// for a list that closed, also when one folder takes long. The view asks again once
    /// the folders changed.
    func folderRoots(of projectID: UUID) async -> ProjectsEmailFiles.Roots? {
        // The switch itself, since `wantsOn` follows it a moment later.
        guard projects.isOn, !projects.isDeleting, let list = running?.list else { return nil }
        guard let project = list.project(projectID) else { return ProjectsEmailFiles.Roots() }
        func isCurrent() -> Bool {
            !Task.isCancelled && projects.isOn && !projects.isDeleting && running?.list === list
                && list.project(projectID)?.folders == project.folders
        }
        var folders = await resolve(project.folders)
        guard isCurrent() else { return nil }
        var missing: [Data] = []
        if folders.isEmpty {
            missing = project.folders
        } else if folders.count < project.folders.count {
            folders = []
            for bookmark in project.folders {
                let found = await resolve([bookmark])
                guard isCurrent() else { return nil }
                folders += found
                if found.isEmpty {
                    missing.append(bookmark)
                }
            }
        }
        var roots: [URL] = []
        for folder in folders {
            if let root = await readRealPath(folder) {
                roots.append(root)
            }
            guard isCurrent() else { return nil }
        }
        var unavailable: [URL] = []
        for bookmark in missing {
            for place in [lastFound[bookmark], Project.savedPath(of: bookmark)].compactMap({ $0 }) where !unavailable.contains(place) {
                unavailable.append(place)
            }
        }
        return ProjectsEmailFiles.Roots(folders: roots, unavailable: unavailable)
    }

    /// Where these folders are now. A resolve of the same folders under way is waited for,
    /// not started again, so a share that hangs holds one thread for each set of folders,
    /// however often Projects is turned off and on meanwhile.
    private func resolve(_ bookmarks: [Data]) async -> [URL] {
        if let resolve = resolving[bookmarks] {
            return await resolve.value
        }
        let resolveFolders = dependencies.resolveFolders
        let resolve = Task { await resolveFolders(bookmarks) }
        resolving[bookmarks] = resolve
        let folders = await resolve.value
        if resolving[bookmarks] == resolve {
            resolving[bookmarks] = nil
        }
        // The folders come in the order of their bookmarks, without those not found, so only
        // a resolve that found every folder tells which bookmark found which.
        if folders.count == bookmarks.count {
            for (bookmark, folder) in zip(bookmarks, folders) {
                lastFound[bookmark] = folder
            }
        }
        return folders
    }

    /// Starts indexing a project's folders as they are now. With `resortAfter`, the mail the
    /// project reaches is sorted again once the sweep that starts here ends. A folder can
    /// take long to resolve, such as on a share that hangs, so no start or stop of Projects
    /// waits for this, and a later start waits for the same resolve, see `resolve(_:)`. When
    /// the project's folders changed meanwhile, or Projects stopped or is turning off, this
    /// starts nothing, since the start for the change or the next start of Projects counts.
    private func startIndex(_ project: Project, resortAfter: Bool = false) async {
        guard let index = running?.index else { return }
        let folders = await resolve(project.folders)
        // The switch itself, since `wantsOn` follows it a moment later.
        guard projects.isOn, !projects.isDeleting, running?.index === index,
              running?.list.project(project.id)?.folders == project.folders else { return }
        index.start(project: project.id, folders: folders)
        if resortAfter, !folders.isEmpty, index.reports[project.id]?.isIndexing == true {
            resortAfterIndex.insert(project.id)
        }
    }

    // MARK: Mailboxes

    /// Every mailbox in Mail, for linking one to a project. Only on the user's click, only
    /// while Projects is on and only while Mail runs.
    func mailboxes() async throws -> [MailMailbox] {
        guard running != nil else { throw Failure.off }
        let mailboxes = try await dependencies.bridge.mailboxes()
        if running != nil {
            learnMailboxes(mailboxes)
        }
        return mailboxes.filter { Self.mailboxName($0) != nil }
    }

    /// The name a project links a mailbox with, in the form of `SortingInput.mailbox`: the
    /// account's name and the mailbox's path, such as "Work/Clients/Harbor". On My Mac the
    /// account is empty, such as "/Clients/Harbor", which no account's name gives, so a
    /// folder On My Mac never takes the name of an account's mailbox. Nil for the inbox and
    /// the sent mailbox of all accounts, and for a mailbox without a name.
    nonisolated static func mailboxName(_ mailbox: MailMailbox) -> String? {
        guard mailbox.kind == .mailbox, !mailbox.name.isEmpty else { return nil }
        return (mailbox.account ?? "") + "/" + mailbox.name
    }

    private func rememberMailbox(_ mailbox: MailMailbox) {
        if let name = Self.mailboxName(mailbox) {
            knownMailboxes[name] = mailbox
        }
    }

    /// Keeps the mailboxes Mail listed in place of those known before, which a rename in
    /// Mail may have made wrong, and says which linked ones Mail no longer has.
    private func learnMailboxes(_ listed: [MailMailbox]) {
        knownMailboxes = [:]
        for mailbox in dependencies.choice.mailboxes + listed {
            rememberMailbox(mailbox)
        }
        mailboxesListed = true
        updateMissingMailboxes()
    }

    /// Notes the linked mailboxes that Mail did not list, for the project page. Nothing is
    /// missing before Mail listed its mailboxes.
    private func updateMissingMailboxes() {
        let missing: Set<String> = mailboxesListed ? linkedNames.filter { knownMailboxes[$0] == nil } : []
        if missing != missingMailboxes {
            missingMailboxes = missing
        }
    }

    /// The mailboxes linked to a project, for the scan and Explain Message Selected in Mail.
    /// While a linked one is not known from the choice or the user's click in the project
    /// setup, it reads the names of Mail's mailboxes once since Projects started, again only
    /// after Mail did not answer, and at most every `mailboxListingGap`. It never reads them
    /// again for a name Mail did not list, which the project page shows.
    private func linkedMailboxes() async -> [MailMailbox] {
        guard let running else { return [] }
        let names = linkedNames
        guard !names.isEmpty else { return [] }
        for mailbox in dependencies.choice.mailboxes {
            rememberMailbox(mailbox)
        }
        let now = dependencies.now()
        if !mailboxesListed, !names.allSatisfy({ knownMailboxes[$0] != nil }),
           lastMailboxListing.map({ now.timeIntervalSince($0) >= Self.mailboxListingGap }) ?? true {
            lastMailboxListing = now
            do {
                let listed = try await dependencies.bridge.mailboxes()
                guard self.running?.list === running.list else { return [] }
                learnMailboxes(listed)
                Logger.projectsMail.notice("Projects read the names of \(listed.count, privacy: .public) mailboxes for \(names.count, privacy: .public) linked ones")
            } catch {
                Logger.projectsMail.notice("Projects could not read the names of the mailboxes: \(String(describing: error), privacy: .public)")
            }
        }
        return names.sorted().compactMap { knownMailboxes[$0] }
    }

    /// Keeps Mail's handle of a message the scan read or the user selected in Mail. Once
    /// `referenceLimit` are kept, a new one takes the place of one kept before, so the others
    /// stay.
    private func remember(_ reference: MailMessageRef, for messageID: String) {
        if references[messageID] == nil, references.count >= referenceLimit, !references.isEmpty {
            listedAgain[references.remove(at: references.startIndex).key] = nil
        }
        references[messageID] = reference
        if listedAgain[messageID] == reference {
            listedAgain[messageID] = nil
        }
    }

    /// Lets go of Mail's handles, which hold for one Mail session, at a stop and when Mail
    /// quits.
    private func forgetReferences() {
        references = [:]
        listedAgain = [:]
        referenceSession += 1
    }

    /// Keeps Mail's handles of the messages the scan listed, also those it knows already and
    /// does not read again, so Open Reply in Mail finds mail read before Orra or Mail
    /// started. A handle kept already stays, and another one listed for its Message-ID is
    /// kept in `listedAgain`: Mail may hold more than one message with it, such as a copy
    /// from a list, and a message the user moved gets a new handle. Once `referenceLimit`
    /// are kept, a listing adds no other Message-ID. A listing that began before Mail quit or
    /// Projects stopped keeps nothing.
    private func rememberListed(_ listings: [MailListing], session: Int?) {
        guard session == referenceSession, running != nil, dependencies.bridge.isRunning() else { return }
        for listing in listings where !listing.messageID.isEmpty {
            if let kept = references[listing.messageID] {
                if kept != listing.message { listedAgain[listing.messageID] = listing.message }
            } else if references.count < referenceLimit {
                references[listing.messageID] = listing.message
            }
        }
    }

    /// The bridge the scan reads with, which hands each listing to `listed` before the scan
    /// gets it, with the `session` read when the listing began.
    nonisolated static func remembering(
        _ bridge: MailBridge,
        session: @escaping @Sendable () async -> Int?,
        listed: @escaping @Sendable ([MailListing], Int?) async -> Void
    ) -> MailBridge {
        var bridge = bridge
        let listing = bridge.listing
        bridge.listing = { mailbox, positions in
            let began = await session()
            let listings = try await listing(mailbox, positions)
            await listed(listings, began)
            return listings
        }
        return bridge
    }

    /// Mail's handle of a message the scan read or listed in this Mail session. Nil after
    /// Mail quit, until the scan lists the mailboxes again.
    func mailReference(for messageID: String) -> MailMessageRef? {
        references[messageID]
    }

    /// Mail's handle of the email for Open Reply in Mail, or Reply All with `all`, once Mail
    /// gave the headers of the message under it and they match the email the store holds,
    /// see `isSameEmail`. Mail may hold another message with the same Message-ID, such as a
    /// copy from a list or one made to look like the email, and the handle kept may be that
    /// one's. A handle whose message is gone or another one is let go, and the one listed
    /// again takes its place and is checked next. Nil when neither matches, and when the
    /// message differs only in who a reply to all adds, which keeps the handle for a reply.
    /// Throws what Mail answered when it did not give the headers.
    func checkedMailReference(for messageID: String, all: Bool) async throws -> MailMessageRef? {
        guard let running, references[messageID] != nil else { return nil }
        let session = referenceSession
        guard let email = try? await running.store.explainEmail(messageID) else { return nil }
        var checked: Set<MailMessageRef> = []
        // Mail quit or Projects stopped meanwhile when the session changed, which let the
        // handles go.
        while session == referenceSession, let reference = references[messageID], checked.insert(reference).inserted {
            let headers: String
            do {
                headers = try await dependencies.bridge.headers(reference)
            } catch MailBridgeError.notFound {
                forgetReference(reference, for: messageID)
                continue
            }
            guard session == referenceSession else { return nil }
            if await Self.isSameEmail(email, headers: headers, all: all) {
                return session == referenceSession ? reference : nil
            }
            Logger.projects.notice("Open Reply: Mail's message is not the email the store holds, so it is not used")
            if all, await Self.isSameEmail(email, headers: headers, all: false) { return nil }
            forgetReference(reference, for: messageID)
        }
        return nil
    }

    /// Lets go of the handle of a message, unless another one took its place meanwhile. The
    /// handle listed again for it, if any, takes its place.
    private func forgetReference(_ reference: MailMessageRef, for messageID: String) {
        if references[messageID] == reference {
            references[messageID] = listedAgain.removeValue(forKey: messageID)
        } else if listedAgain[messageID] == reference {
            listedAgain[messageID] = nil
        }
    }

    /// Whether a message with these headers is the email, as far as a reply goes: the same
    /// Message-ID, the sender alone in From and the same Reply-To, which say who a reply
    /// goes to, and with `all` the same To and Cc, which a reply to all adds. Addresses
    /// compare in their normalized form and as sets, since Mail may list them in another
    /// order. Headers cut at a limit do not match, nor do address fields with an entry not
    /// read exactly, see `MailHeaders.exactAddresses(_:)`, since Mail may still reply to it.
    @concurrent
    nonisolated static func isSameEmail(_ email: ExplainService.Email, headers text: String, all: Bool) async -> Bool {
        let headers = MailHeaders(parsing: text)
        func addresses(_ name: String) -> Set<String>? {
            headers.exactAddresses(name).map { Set($0.map(\.address)) }
        }
        func addresses(_ people: [ExplainPrompt.Person]) -> Set<String> {
            Set(people.compactMap { ProjectsAddress.normalized($0.address) })
        }
        guard !headers.isCut, headers.messageID == email.messageID,
              let sender = ProjectsAddress.normalized(email.sender.address),
              addresses("From") == Set([sender]),
              addresses("Reply-To") == addresses(email.replyTo) else { return false }
        guard all else { return true }
        return addresses("To") == addresses(email.to) && addresses("Cc") == addresses(email.cc)
    }

    /// Whether a message selected in Mail is the email the store holds with its Message-ID,
    /// for Explain Message Selected in Mail. Its headers are read as the scan read the
    /// email's for the store, see `MailScan.Message`: the first sender in From, the
    /// addresses of Reply-To, To and Cc as sets, and the date. A From, To, Cc or Date that
    /// the headers lack matches, since the scan then took what Mail lists. So the email
    /// itself always matches, also with an entry not read exactly, and a copy of it in
    /// another mailbox has the same headers. The subject is left out, since the store keeps
    /// it as Mail lists it, which may differ from the header in its spaces or its decoding
    /// (a guess). Open Reply in Mail checks the message again, strictly, see `isSameEmail`.
    @concurrent
    nonisolated static func isSelectedEmail(_ email: ExplainService.Email, headers text: String) async -> Bool {
        let headers = MailHeaders(parsing: text)
        func addresses(_ people: [ExplainPrompt.Person]) -> Set<String> {
            Set(people.compactMap { ProjectsAddress.normalized($0.address) })
        }
        func matches(_ read: [MailAddressHeader], _ people: [ExplainPrompt.Person]) -> Bool {
            Set(read.map(\.address)) == addresses(people)
        }
        guard headers.messageID == email.messageID else { return false }
        if let date = headers.date, date != email.date {
            return false
        }
        if let sender = headers.from.first, sender.address != ProjectsAddress.normalized(email.sender.address) {
            return false
        }
        return matches(headers.replyTo, email.replyTo)
            && (headers.to.isEmpty || matches(headers.to, email.to))
            && (headers.cc.isEmpty || matches(headers.cc, email.cc))
    }

    // MARK: Explaining

    /// Explains an email, saves the explanation and returns it. Only while the window is
    /// open, and only while the store keeps the email's text: the window offers no Explain
    /// without it, but Explain Message Selected in Mail may reach an email its list does not
    /// show. Throws what ExplainService throws, and CancellationError when Projects stops.
    func explain(_ messageID: String) async throws -> Explanation {
        guard let running else { throw Failure.off }
        guard let service = explainService else { throw Failure.windowClosed }
        let store = running.store
        defer { mailChanged() }
        return try await userRequest {
            guard let email = try await store.explainEmail(messageID) else { throw Failure.unknownEmail }
            guard try await store.hasText(messageID) else { throw Failure.noText }
            return try await service.explain(email)
        }
    }

    /// Runs a request of the user, such as an explanation or a revision of the email view,
    /// in a task the runtime keeps. Turning Projects off or Delete All ends it, and waits
    /// for it before the files close, so nothing of it runs or saves after that. Cancelling
    /// the caller's task ends it too. A request that finds no model throws
    /// Failure.modelNotLoaded while the model is on this Mac, so the window offers Try
    /// Loading Again rather than a download.
    func userRequest<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        guard running != nil else { throw Failure.off }
        let task = Task { try await work() }
        let id = UUID()
        userRequests[id] = UserRequest(cancel: { task.cancel() }, ended: Task { _ = await task.result })
        defer { userRequests[id] = nil }
        // Text recognition waits while a request of the user runs, and the page it reads
        // gives way now.
        running?.index.interruptRecognition()
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch RewriteError.notLoaded where dependencies.modelIsInstalled() {
            throw Failure.modelNotLoaded
        }
    }

    /// Whether a request of the user runs, for tests.
    var userRequestCount: Int {
        userRequests.count
    }

    /// Why the text recognition of the folder index waits now, nil when it may run: a
    /// dictation, Live Captions, a request of the user, memory pressure that is not normal,
    /// Low Power Mode, or a thermal state of serious or critical, in that order. Asked
    /// before every page, see FolderIndex.
    func recognitionPause() -> FolderIndex.RecognitionPause? {
        if dependencies.isDictating() { return .dictation }
        guard let running else { return nil }
        if running.model.captionsOn() { return .captions }
        if !userRequests.isEmpty { return .request }
        if running.memory.level != .normal { return .memory }
        let power = dependencies.power()
        if power.isLowPowerModeOn { return .lowPower }
        if power.isHot { return .heat }
        return nil
    }

    /// The email's latest explanation, nil when there is none.
    func explanation(for messageID: String) async -> Explanation? {
        try? await running?.store.explanation(for: messageID)
    }

    /// An email the store holds, for the email view: the text of this email and the sender
    /// and date of an earlier one that a point cites. Nil when the store does not hold it.
    func email(_ messageID: String) async -> ExplainService.Email? {
        try? await running?.store.explainEmail(messageID)
    }

    /// The versions of the email's draft, oldest first.
    func versions(of messageID: String) async -> [MailStore.DraftVersion] {
        (try? await running?.store.versions(of: messageID)) ?? []
    }

    /// Undo of a change: removes the newest version of the email's draft, and says whether
    /// there was one.
    func removeNewestVersion(of messageID: String) async -> Bool {
        guard let store = running?.store else { return false }
        return (try? await store.removeNewestVersion(of: messageID, at: dependencies.now())) ?? false
    }

    /// The text the user typed into the email's draft, nil when there is none.
    func editedDraft(of messageID: String) async -> MailStore.EditedDraft? {
        try? await running?.store.editedDraft(of: messageID)
    }

    /// Keeps the text the user typed into the email's draft, or with nil removes it, and
    /// gives the write, which says whether the store did. The write starts at once in the
    /// store that runs now, after the one before it for the same email, so the newest text
    /// lands last. A stop waits for it before it closes the store, also when the window
    /// that saved it closes as Projects turns off. A failed write is logged with its code.
    func saveEditedDraft(_ edited: MailStore.EditedDraft?, for messageID: String) -> Task<Bool, Never> {
        guard let store = running?.store else { return Task { false } }
        let before = draftSaves[messageID]
        let now = dependencies.now()
        let save = Task {
            _ = await before?.value
            do {
                return try await store.save(edited, for: messageID, at: now)
            } catch {
                MailStore.log(error, "saving the text typed into a draft")
                return false
            }
        }
        draftSaves[messageID] = save
        return save
    }

    /// What a revision, the translation and the answer check of the explanation's draft
    /// need: the values the first draft was checked with, the email's own text, the user's
    /// name and language, and today. Nil when the explanation has no draft in Chinese or
    /// English, or while Projects does not run.
    func reviseContext(for explanation: Explanation) async -> ReviseService.Context? {
        guard let running, let check = explanation.draftCheck, let language = explanation.reply.draftLanguage else { return nil }
        let email = try? await running.store.explainEmail(explanation.messageID)
        let owner = await owner()
        return ReviseService.Context(
            messageID: explanation.messageID,
            emailText: email?.text ?? "",
            language: language,
            userLanguage: dependencies.language,
            ownName: owner.name ?? "",
            recipients: check.recipients,
            projectPeople: check.projectPeople,
            own: check.own,
            incomingText: check.incomingText,
            sourceTexts: check.sourceTexts,
            today: dependencies.now(),
            timeZone: .current,
            imitatingDomains: check.imitatingDomains,
            asksForData: check.asksForData
        )
    }

    /// The language explanations are in, which the user reads, see
    /// ProjectsLanguage.forExplanations.
    var userLanguage: ProjectsLanguage {
        dependencies.language
    }

    /// A service for one revision of a draft, which saves its version as made when the
    /// revision started (#146). Only while the window is open. Run each revision through
    /// `userRequest(_:)`, so turning Projects off ends it.
    func reviseService(startedAt started: Date) async throws -> ReviseService {
        guard let running else { throw Failure.off }
        guard windowHoldsModel else { throw Failure.windowClosed }
        guard let countTokens = try await tokenCounter() else { throw RewriteError.notLoaded }
        return ReviseService(
            run: { [queue = running.queue] request in try await queue.run(request) },
            countTokens: countTokens,
            save: running.store.versionSave(startedAt: started, now: dependencies.now)
        )
    }

    private func explainLookups(_ running: Running) -> ExplainService.Lookups {
        let store = running.store
        let search = running.search
        let index = running.index
        return ExplainService.Lookups(
            known: { [weak self] email in
                guard let self else { throw CancellationError() }
                return try await self.known(before: email)
            },
            thread: { email in try await store.threadMail(of: email) },
            projectMail: { query in try await store.projectMail(query) },
            search: { text, project, limit in try await search.search(text, in: [project], limit: limit) },
            newest: { project, limit in try await search.newest(project, limit: limit) },
            files: { project in try await index.versionFiles(project: project) }
        )
    }

    private func known(before email: ExplainService.Email) async throws -> ExplainService.Known {
        guard let running else { throw Failure.off }
        let owner = await owner()
        let correspondence = try await running.store.correspondence(before: email, ownAddresses: owner.addresses)
        return ExplainService.Known(
            ownName: owner.name ?? "",
            ownAddresses: owner.addresses,
            projects: running.list.projects.map(\.forExplanation),
            correspondents: correspondence.correspondents,
            sentTexts: correspondence.sentTexts
        )
    }

    // MARK: Explain Message Selected in Mail

    /// Finds the message selected in Mail, for Explain Message Selected in Mail. Reads
    /// Mail's selection only on that click, and only after the user confirmed a mailbox
    /// choice. Reads more only of a message in a chosen or linked mailbox (decision 18). A
    /// message the scan has not read yet makes it read the mailboxes once. Reads nothing
    /// more once Projects stops or the choice is forgotten, which the user can do while Mail
    /// answers. Finds the email the store holds with the message's Message-ID only when the
    /// message is that email, see `isSelectedEmail`, and only then keeps its handle, unless
    /// Mail quit meanwhile.
    func messageSelectedInMail() async -> SelectedMessage {
        guard let running else { return .noMailboxChosen }
        guard dependencies.choice.isConfirmed else { return .noMailboxChosen }
        let bridge = dependencies.bridge
        guard bridge.isRunning() else { return .mailNotRunning }
        // The handle of the message holds for this Mail session only.
        let session = referenceSession
        do {
            guard let selected = try await bridge.selection().first else { return .nothingSelected }
            guard stillReads(running) else { return .noMailboxChosen }
            let chosen = try await isChosen(selected, running)
            guard stillReads(running) else { return .noMailboxChosen }
            guard chosen else {
                Logger.projects.notice("Explain Message Selected in Mail: the message is not in a chosen mailbox")
                return .notInChosenMailbox
            }
            // Mail answered, so Orra may control it: the scan starts if it waited for that.
            updateScan()
            let headers = try await bridge.headers(selected)
            guard let messageID = await Self.messageID(in: headers) else { return .notRead(days: dependencies.choice.days) }
            guard stillReads(running) else { return .noMailboxChosen }
            var email = try await running.store.explainEmail(messageID)
            if email == nil {
                switch await readUntilSaved(messageID, store: running.store, scan: running.scan) {
                case .saved: email = try await running.store.explainEmail(messageID)
                case .notFound: return .notRead(days: dependencies.choice.days)
                case .stillReading: return .stillReading
                case .storeFailed: return .notSaved
                }
            }
            guard let email else { return .notRead(days: dependencies.choice.days) }
            // Mail may hold another message with this Message-ID, and the store keeps the
            // one the scan read first.
            guard await Self.isSelectedEmail(email, headers: headers) else {
                Logger.projects.notice("Explain Message Selected in Mail: the message is not the email the store holds with its Message-ID")
                return .otherEmail
            }
            guard stillReads(running) else { return .noMailboxChosen }
            // Not when Mail quit meanwhile, which let go of the handles of its session.
            if session == referenceSession {
                remember(selected, for: messageID)
            }
            return .found(messageID)
        } catch let error as MailBridgeError {
            Logger.projects.notice("Explain Message Selected in Mail failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .mailNotRunning: return .mailNotRunning
            case .denied, .notAsked: return .notAllowed
            default: return .failed(error)
            }
        } catch {
            Logger.projects.error("Explain Message Selected in Mail failed: \(Self.logName(error), privacy: .public)")
            return .failed(.failed(code: (error as NSError).code))
        }
    }

    /// Whether Projects still runs as when Explain Message Selected in Mail began, with the
    /// mailbox choice confirmed, so it may ask Mail more.
    private func stillReads(_ running: Running) -> Bool {
        self.running?.scan === running.scan && dependencies.choice.isConfirmed
    }

    /// Whether a message selected in Mail is in a chosen or linked mailbox. Mail names a
    /// message of the inbox or the sent mailbox of all accounts by the mailbox of its
    /// account, so for those two the message is looked for there by its id. False without
    /// asking Mail once Projects stopped or the choice was forgotten, see `stillReads`.
    private func isChosen(_ message: MailMessageRef, _ running: Running) async throws -> Bool {
        let linked = await linkedMailboxes()
        guard stillReads(running) else { return false }
        let chosen = dependencies.choice.mailboxes + linked
        if chosen.contains(message.mailbox) {
            return true
        }
        for special in [MailMailbox.inbox, MailMailbox.sent] where chosen.contains(special) {
            guard stillReads(running) else { return false }
            do {
                _ = try await dependencies.bridge.mailbox(MailMessageRef(id: message.id, mailbox: special))
                return true
            } catch MailBridgeError.notFound {
                continue
            }
        }
        return false
    }

    /// What a wait for the scan to read a message found.
    private enum ReadOutcome {
        case saved
        /// A pass of its own ran to its end without the message.
        case notFound
        /// A pass still read the mailboxes when the wait ended.
        case stillReading
        /// A pass of its own ended without the message, as the store failed.
        case storeFailed
    }

    /// Runs a pass of the scan and waits until it saved the message, for at most about
    /// `selectionWait`. While another pass runs, which may read it too, it tries again
    /// after that pass.
    private func readUntilSaved(_ messageID: String, store: MailStore, scan: MailScan) async -> ReadOutcome {
        let pass = PassState()
        func startPass() {
            pass.isRunning = true
            Task {
                let result = await scan.scan()
                pass.isRunning = false
                pass.isDone = result.skipped != .busy
                pass.storeFailed = result.skipped == .storeFailed
            }
        }
        startPass()
        let started = ContinuousClock.now
        while started.duration(to: .now) < Self.selectionWait, !Task.isCancelled, running?.scan === scan {
            if (try? await store.explainEmail(messageID)) != nil {
                return .saved
            }
            if pass.isDone {
                if (try? await store.explainEmail(messageID)) != nil {
                    return .saved
                }
                return pass.storeFailed ? .storeFailed : .notFound
            }
            if !pass.isRunning {
                startPass()
            }
            try? await Task.sleep(for: Self.selectionPoll)
        }
        return (try? await store.explainEmail(messageID)) != nil ? .saved : .stillReading
    }

    /// Whether a pass of the scan that Explain Message Selected in Mail started runs,
    /// whether one ran to its end, and whether that one ended as the store failed.
    private final class PassState {
        var isRunning = false
        var isDone = false
        var storeFailed = false
    }

    /// How long Explain Message Selected in Mail waits for the scan to read the message.
    nonisolated static let selectionWait: Duration = .seconds(30)
    nonisolated static let selectionPoll: Duration = .milliseconds(250)

    @concurrent
    private nonisolated static func messageID(in headers: String) async -> String? {
        MailHeaders(parsing: headers).messageID
    }

    // MARK: The diagnostic report

    /// The counts of the diagnostic report, nil while Projects does not run.
    func counts() async -> ProblemReport.ProjectsCounts? {
        guard let running, let counts = try? await running.store.counts() else { return nil }
        return ProblemReport.ProjectsCounts(projects: running.list.projects.count, emails: counts.emails, files: counts.files)
    }

    // MARK: Helpers

    /// The store's form of a message the scan read.
    nonisolated static func storeMessage(_ message: MailScan.Message, now: Date) -> MailStore.Message {
        func person(_ header: MailAddressHeader) -> MailStore.Person {
            MailStore.Person(name: header.name, address: header.address)
        }
        let sender = message.from.first.map(person) ?? MailStore.Person(address: message.sender)
        let hidden = message.visible?.findings ?? []
        return MailStore.Message(
            messageID: message.messageID,
            mailbox: mailboxName(message.reference.mailbox),
            date: message.date ?? message.dateReceived ?? now,
            sender: sender,
            to: message.to.map(person),
            cc: message.cc.map(person),
            replyTo: message.replyTo.map(person),
            subject: message.subject,
            inReplyTo: message.inReplyTo,
            references: message.references,
            list: message.list,
            text: message.history?.ownText ?? "",
            visibleText: message.visible?.text ?? "",
            hiddenText: hidden,
            attachments: message.attachments,
            // Hidden text in the email or in an attachment shows before it is explained.
            warnings: hidden.isEmpty && !message.attachments.contains { $0.hiddenRuns > 0 } ? [] : [.hiddenText],
            isTooLarge: message.isTooLarge
        )
    }

    /// Which of these the store knows. A failure is logged with its code and thrown, so the
    /// scan ends its pass rather than read every message again, or skip mail it never saved.
    private nonisolated static func known(_ ids: [String], in store: MailStore) async throws -> Set<String> {
        do {
            return try await store.known(ids)
        } catch {
            MailStore.log(error, "reading known Message-IDs")
            throw error
        }
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    /// An error for the log, by its kind and code only.
    private nonisolated static func logName(_ error: any Error) -> String {
        if let failure = error as? ProjectsDatabase.Failure { return "\(failure.step.rawValue) \(failure.code)" }
        if let failure = error as? ProjectList.Failure { return "\(failure)" }
        if error is DecodingError { return "unreadable" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
