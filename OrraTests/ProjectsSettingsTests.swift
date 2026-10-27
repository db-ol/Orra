import Foundation
import Synchronization
import Testing
@testable import Orra

/// Mail access and the mailboxes on the Projects page, over a fake Mail that never sends an
/// Apple Event: macOS is asked only after the click and Orra's explanation, the line after
/// a no, the mailboxes Mail lists, and the scan reading nothing before Start Reading Mail.
/// The mailboxes and the mail are made up for these tests, at .example addresses.
@MainActor
struct ProjectsSettingsTests {
    typealias MailAccess = ProjectsSettings.MailAccess

    nonisolated static let now = Date(timeIntervalSince1970: 1_792_300_000)
    nonisolated static let account = MailEvents.Specifier.textID(MailEvents.Code.account, "5C12-account", of: .application)
    nonisolated static let archive = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Archive", of: account), name: "Archive", account: "Studio")
    nonisolated static let imported = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "orra-test", of: .application), name: "orra-test", account: nil)
    nonisolated static let drafts = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "Drafts", of: account), name: "Drafts", account: "Studio")
    nonisolated static let deniedLine = "Orra is not allowed to control Mail. Turn on Mail under Orra in Privacy & Security, Automation."

    let suite = "io.github.db-ol.OrraTests.projects-settings-\(UUID().uuidString)"
    let defaults: UserDefaults
    let mail = FakeMail()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func access(
        suggests: Bool = false,
        isOn: @escaping () -> Bool = { true }
    ) -> MailAccess {
        MailAccess(bridge: mail.bridge, choice: MailChoice(defaults: defaults, suggestsInboxAndSent: suggests), isOn: isOn)
    }

    // MARK: Access

    /// Showing the page, coming back to Orra and Mail starting never ask macOS. Only the
    /// click on Allow Mail Access… and Continue under Orra's explanation do.
    @Test func macOSIsAskedOnlyAfterTheClickAndTheExplanation() async {
        defer { cleanUp() }
        mail.answer = .allowed
        mail.remembered = .notAsked
        let access = access()
        await access.show()
        await access.refresh()
        #expect(mail.asks.isEmpty)
        // Nothing is listed while macOS has not been asked yet.
        #expect(mail.listings == 0)
        #expect(access.access == .unknown)
        #expect(access.line == nil)
        access.allowClicked()
        #expect(access.isExplaining)
        #expect(mail.asks.isEmpty)
        await access.ask()
        #expect(!access.isExplaining)
        #expect(mail.asks == [true])
        #expect(access.access == .allowed)
        #expect(access.listed == mail.mailboxes)
        #expect(access.line == nil)
    }

    /// Right after launch the bridge has learned nothing. The first look lists once, with
    /// events that never bring up the prompt, and so learns that macOS has not asked the
    /// user yet. After that nothing is listed until the user allows access.
    @Test func theFirstLookAfterLaunchListsOnceAndAsksNothing() async {
        defer { cleanUp() }
        mail.remembered = nil
        mail.listingError = .notAsked
        let access = access()
        await access.show()
        #expect(mail.asks.isEmpty)
        #expect(mail.listings == 1)
        #expect(access.access == .unknown)
        #expect(access.listed == nil)
        #expect(!access.listFailed)
        #expect(access.line == nil)
        await access.refresh()
        await access.show()
        #expect(mail.listings == 1)
        #expect(mail.asks.isEmpty)
    }

    /// The same first look after an earlier run allowed access shows it as allowed, still
    /// without a permission check.
    @Test func theFirstLookAfterLaunchFindsAnEarlierYes() async {
        defer { cleanUp() }
        mail.remembered = nil
        let access = access()
        await access.show()
        #expect(mail.asks.isEmpty)
        #expect(access.access == .allowed)
        #expect(access.listed == mail.mailboxes)
    }

    /// With the access remembered from an earlier request, showing the page lists the
    /// mailboxes without asking macOS.
    @Test func aRememberedAnswerIsShownWithoutAsking() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let access = access()
        await access.show()
        #expect(access.access == .allowed)
        #expect(access.listed == mail.mailboxes)
        #expect(mail.asks.isEmpty)
        // Each time the page shows, the mailboxes are listed again.
        await access.show()
        #expect(mail.listings == 2)
        // A look while they are listed lists nothing.
        await access.refresh()
        #expect(mail.listings == 2)
    }

    /// While Mail does not run, Allow Mail Access… is gray and the line says to open Mail
    /// first, before any click. A click that gets through asks nothing, and nothing here opens
    /// Mail.
    @Test func whileMailIsClosedTheClickSaysToOpenItFirst() async {
        defer { cleanUp() }
        mail.isRunning = false
        let access = access()
        await access.show()
        #expect(!access.canAsk)
        #expect(access.line == "Open Mail first. Orra can check or ask for access only while Mail is open.")
        access.allowClicked()
        #expect(!access.isExplaining)
        #expect(access.note == nil)
        await access.ask()
        #expect(mail.asks.isEmpty)
        #expect(mail.listings == 0)
        #expect(!access.mailIsRunning)
        // Mail starts, and the line goes.
        mail.isRunning = true
        await access.refresh()
        #expect(access.mailIsRunning)
        #expect(access.canAsk)
        #expect(access.line == nil)
    }

    /// Mail quits while the explanation shows: Continue asks nothing, and the line says to
    /// open Mail.
    @Test func mailQuittingBeforeContinueAsksNothing() async {
        defer { cleanUp() }
        let access = access()
        access.allowClicked()
        #expect(access.isExplaining)
        mail.isRunning = false
        await access.ask()
        #expect(mail.asks.isEmpty)
        #expect(access.note == nil)
        #expect(access.line == "Open Mail first. Orra can check or ask for access only while Mail is open.")
    }

    /// After a restart with Mail closed, the bridge has learned nothing. A user who confirmed
    /// mailboxes allowed access before, since Start Reading Mail confirms only then, so the
    /// page asks to open Mail to check the access, never to allow it again. Once Mail runs,
    /// the listing learns the answer without asking macOS.
    @Test func aReturningUserWithMailClosedOpensMailToCheck() async {
        defer { cleanUp() }
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        choice.choose([Self.archive])
        choice.confirm()
        mail.isRunning = false
        mail.remembered = nil
        let access = MailAccess(bridge: mail.bridge, choice: choice, isOn: { true })
        await access.show()
        #expect(access.access == .unknown)
        #expect(access.line == "Open Mail to check access.")
        #expect(mail.listings == 0)
        // The user opens Mail.
        mail.isRunning = true
        await access.mailLaunched(retryAfter: .zero)
        #expect(access.access == .allowed)
        #expect(access.line == nil)
        #expect(mail.asks.isEmpty)
        // The same after a no in System Settings, which the listing learns as well.
        let refused = MailAccess(bridge: mail.bridge, choice: choice, isOn: { true })
        mail.isRunning = false
        mail.remembered = nil
        await refused.show()
        #expect(refused.line == "Open Mail to check access.")
        mail.isRunning = true
        mail.listingError = .denied
        await refused.mailLaunched(retryAfter: .zero)
        #expect(refused.access == .denied)
        #expect(refused.line == Self.deniedLine)
        #expect(mail.asks.isEmpty)
    }

    /// -1743: one line that leads to Privacy & Security, Automation, and no button that
    /// asks again.
    @Test func aNoShowsTheWayToSystemSettings() async {
        defer { cleanUp() }
        mail.answer = .denied
        mail.remembered = .notAsked
        let access = access()
        access.allowClicked()
        await access.ask()
        #expect(access.access == .denied)
        #expect(access.line == Self.deniedLine)
        #expect(access.listed == nil)
        #expect(!access.listFailed)
        #expect(ProjectsSettings.automationSettings.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        // The user turns Mail on for Orra in System Settings and comes back. The next look
        // lists the mailboxes, without asking macOS again.
        mail.listingError = nil
        await access.refresh()
        #expect(access.access == .allowed)
        #expect(access.line == nil)
        #expect(access.listed == mail.mailboxes)
        #expect(mail.asks == [true])
    }

    /// A no that an earlier event learned shows the same line when the page opens.
    @Test func aRememberedNoShowsTheLine() async {
        defer { cleanUp() }
        mail.remembered = .denied
        mail.listingError = .denied
        let access = access()
        await access.show()
        #expect(access.access == .denied)
        #expect(access.line == Self.deniedLine)
        #expect(mail.asks.isEmpty)
    }

    @Test func noAnswerAsksToTryAgain() async {
        defer { cleanUp() }
        mail.answer = .unknown
        mail.remembered = .notAsked
        let access = access()
        access.allowClicked()
        await access.ask()
        #expect(access.access == .unknown)
        #expect(access.note == .noAnswer)
        #expect(access.line == "macOS gave no answer. Try again.")
        // A second click clears the line and explains again.
        access.allowClicked()
        #expect(access.line == nil)
        #expect(access.isExplaining)
    }

    /// A permission check that says Mail does not run while Mail still runs, as -600 from a
    /// busy Mail may: the page says to try again, never to open the Mail that is open.
    @Test func aMinus600WhileMailRunsAsksToTryAgain() async {
        defer { cleanUp() }
        mail.answer = .mailNotRunning
        mail.remembered = .notAsked
        let access = access()
        access.allowClicked()
        await access.ask()
        #expect(mail.asks == [true])
        #expect(access.mailIsRunning)
        #expect(access.access == .unknown)
        #expect(access.note == .noAnswer)
        #expect(access.line == "macOS gave no answer. Try again.")
    }

    /// macOS took longer than the limit, and the user answered its prompt later. The next
    /// look learns the answer from the listing, and the line about no answer goes, so it
    /// never hides the way to System Settings.
    @Test(arguments: [MailPermission.allowed, .denied])
    func anAnswerAfterTheTimeLimitReplacesTheNote(later: MailPermission) async {
        defer { cleanUp() }
        mail.answer = .unknown
        mail.remembered = .notAsked
        let access = access()
        access.allowClicked()
        await access.ask()
        #expect(access.note == .noAnswer)
        #expect(access.line == "macOS gave no answer. Try again.")
        mail.listingError = later == .denied ? .denied : nil
        await access.refresh()
        #expect(mail.asks == [true])
        #expect(access.note == nil)
        switch later {
        case .denied:
            #expect(access.access == .denied)
            #expect(access.line == Self.deniedLine)
        default:
            #expect(access.access == .allowed)
            #expect(access.line == nil)
            #expect(access.listed == mail.mailboxes)
        }
    }

    /// After a no, the line leads to System Settings whatever the page noted before and
    /// whether Mail runs. While Mail is closed and the access is not known, the line says to
    /// open Mail, first or to check the access.
    @Test func aNoComesBeforeAnyNote() {
        for running in [false, true] {
            for confirmed in [false, true] {
                #expect(MailAccess.line(access: .denied, note: .noAnswer, mailIsRunning: running, confirmed: confirmed) == Self.deniedLine)
                #expect(MailAccess.line(access: .denied, note: nil, mailIsRunning: running, confirmed: confirmed) == Self.deniedLine)
                #expect(MailAccess.line(access: .allowed, note: .noAnswer, mailIsRunning: running, confirmed: confirmed) == nil)
            }
        }
        #expect(MailAccess.line(access: .unknown, note: nil, mailIsRunning: true, confirmed: false) == nil)
        #expect(MailAccess.line(access: .unknown, note: .noAnswer, mailIsRunning: true, confirmed: true) == "macOS gave no answer. Try again.")
        #expect(MailAccess.line(access: .unknown, note: .noAnswer, mailIsRunning: false, confirmed: false) == "Open Mail first. Orra can check or ask for access only while Mail is open.")
        #expect(MailAccess.line(access: .unknown, note: nil, mailIsRunning: false, confirmed: true) == "Open Mail to check access.")
    }

    @Test func accessFollowsWhatTheBridgeLearned() {
        #expect(MailAccess.access(nil) == .unknown)
        #expect(MailAccess.access(.allowed) == .allowed)
        #expect(MailAccess.access(.denied) == .denied)
        #expect(MailAccess.access(.notAsked) == .unknown)
        #expect(MailAccess.access(.mailNotRunning) == .unknown)
        #expect(MailAccess.access(.unknown) == .unknown)
    }

    /// While Projects is off, nothing is asked or listed, and the choice cannot be
    /// confirmed.
    @Test func nothingHappensWhileProjectsIsOff() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let access = access(isOn: { false })
        await access.show()
        access.allowClicked()
        await access.ask()
        #expect(!access.isExplaining)
        #expect(mail.asks.isEmpty)
        #expect(mail.listings == 0)
        access.choose(Self.archive, true)
        #expect(!access.canStartReading)
        access.startReading()
        #expect(!access.choice.isConfirmed)
    }

    /// A listing Mail does not answer offers Try Again, and a listing refused for access
    /// shows the access line instead.
    @Test func aListingMailDoesNotAnswerOffersTryAgain() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        mail.listingError = .timedOut
        let access = access()
        await access.show()
        #expect(access.listed == nil)
        #expect(access.listFailed)
        mail.listingError = nil
        await access.refresh()
        #expect(!access.listFailed)
        #expect(access.listed == mail.mailboxes)
    }

    /// Mail did not answer the listing at its start. One more look after the pause lists
    /// the mailboxes without Try Again.
    @Test func aListingRightAfterMailStartsIsTriedOnceMore() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        mail.nextListingError = .notAnswered(code: -609)
        let access = access()
        await access.mailLaunched(retryAfter: .zero)
        #expect(mail.listings == 2)
        #expect(!access.listFailed)
        #expect(access.listed == mail.mailboxes)
    }

    /// A listing that worked, or that failed for access, is not tried again.
    @Test func onlyAListingMailDidNotAnswerIsTriedAgain() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let access = access()
        await access.mailLaunched(retryAfter: .zero)
        #expect(mail.listings == 1)
        let refused = MailAccess(bridge: mail.bridge, choice: MailChoice(defaults: defaults, suggestsInboxAndSent: false), isOn: { true })
        mail.listingError = .denied
        await refused.mailLaunched(retryAfter: .zero)
        #expect(mail.listings == 2)
        #expect(refused.access == .denied)
    }

    /// Projects turned off while Mail listed its mailboxes: their names are not kept.
    @Test func aListingThatEndsAfterTurningOffIsDropped() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let on = Mutex(true)
        mail.whileListing = { on.withLock { $0 = false } }
        let access = access(isOn: { on.withLock { $0 } })
        await access.show()
        #expect(mail.listings == 1)
        #expect(access.listed == nil)
        #expect(access.rows.isEmpty)
    }

    /// Turning Projects off forgets the names listed and what the page said, and keeps the
    /// choice, which only Delete forgets.
    @Test func turningOffForgetsTheListedNames() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let access = access()
        await access.show()
        access.choose(Self.archive, true)
        access.allowClicked()
        #expect(access.listed == mail.mailboxes)
        #expect(access.isExplaining)
        access.projectsTurnedOff()
        #expect(access.listed == nil)
        #expect(!access.isExplaining)
        #expect(access.choice.mailboxes == [Self.archive])
        #expect(access.rows == [Self.archive])
        // A listing Mail did not answer, and a question macOS did not answer.
        mail.listingError = .timedOut
        await access.show()
        #expect(access.listFailed)
        mail.answer = .unknown
        access.allowClicked()
        await access.ask()
        #expect(access.note == .noAnswer)
        access.projectsTurnedOff()
        #expect(!access.listFailed)
        #expect(access.note == nil)
    }

    // MARK: Mailboxes

    /// The picker shows the two of all accounts on their own, then each place in the order
    /// it first comes, so a chosen mailbox Mail did not list joins its account.
    @Test func thePickerGroupsTheMailboxesByPlace() {
        let rows = MailAccess.rows(listed: [.inbox, .sent, Self.archive, Self.imported], chosen: [Self.drafts])
        let groups = MailAccess.groups(rows)
        #expect(groups.map(\.place) == [nil, "Studio", "On My Mac"])
        #expect(groups.map(\.mailboxes) == [[.inbox, .sent], [Self.archive, Self.drafts], [Self.imported]])
        #expect(MailAccess.groups([]).isEmpty)
        #expect(MailAccess.groups([Self.imported]).map(\.place) == ["On My Mac"])
    }

    /// A Debug build suggests no mailbox, so nothing is ticked and Start Reading Mail
    /// waits for a tick.
    @Test func aDebugBuildSuggestsNoMailbox() async {
        defer { cleanUp() }
        #if DEBUG
        #expect(!MailChoice.suggestsInboxAndSentByDefault)
        #expect(MailChoice(defaults: defaults).mailboxes.isEmpty)
        #endif
        mail.remembered = .allowed
        let access = MailAccess(bridge: mail.bridge, choice: MailChoice(defaults: defaults), isOn: { true })
        #if DEBUG
        #expect(access.rows.isEmpty)
        await access.show()
        #expect(access.rows == mail.mailboxes)
        #expect(access.rows.allSatisfy { !access.isChosen($0) })
        #expect(!access.canStartReading)
        #endif
    }

    /// A release build suggests the inbox and the sent mailbox, ticked and shown before
    /// Mail lists anything.
    @Test func aReleaseBuildSuggestsInboxAndSent() async {
        defer { cleanUp() }
        let access = access(suggests: true)
        #expect(access.rows == [.inbox, .sent])
        #expect(access.isChosen(.inbox))
        #expect(access.isChosen(.sent))
        // Not before Orra may read Mail.
        #expect(!access.canStartReading)
    }

    /// Only the ticked mailboxes are saved, never the others the picker lists.
    @Test func onlyTickedMailboxesAreSaved() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        let access = access()
        await access.show()
        access.choose(Self.archive, true)
        access.choose(Self.archive, true)
        #expect(access.choice.mailboxes == [Self.archive])
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes == [Self.archive])
        let saved = defaults.data(forKey: MailChoice.mailboxesKey) ?? Data()
        let names = try? JSONDecoder().decode([MailMailbox].self, from: saved).map(\.name)
        #expect(names == ["Archive"])
        access.choose(Self.archive, false)
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes.isEmpty)
    }

    /// The picker lists what Mail lists, then the chosen mailboxes it did not list, each
    /// once.
    @Test func theRowsKeepChosenMailboxesMailDidNotList() {
        let rows = MailAccess.rows(listed: [.inbox, .sent, Self.archive], chosen: [Self.imported, Self.archive])
        #expect(rows == [.inbox, .sent, Self.archive, Self.imported])
        #expect(MailAccess.rows(listed: [], chosen: [.inbox]) == [.inbox])
    }

    /// The scan reads the mailboxes a project links along with the ticked ones, so unticking
    /// one here does not stop it. The page lists each linked one with its project, ticked or
    /// not, once for each project that links it, and marks one that Mail no longer has,
    /// which the scan skips.
    @Test func aLinkedMailboxShowsWithItsProjectTickedOrNot() async throws {
        defer { cleanUp() }
        mail.remembered = .allowed
        let archive = try #require(ProjectsRuntime.mailboxName(Self.archive))
        let harbor = Project(name: "Harbor lobby", mailboxes: [archive, "/Harbor 2026"])
        let kiln = Project(name: "Kiln", mailboxes: [archive])
        let access = MailAccess(
            bridge: mail.bridge, choice: MailChoice(defaults: defaults, suggestsInboxAndSent: false),
            projects: { [harbor, kiln, Project(name: "Garden")] }, missingMailboxes: { ["/Harbor 2026"] }, isOn: { true })
        await access.show()
        access.choose(Self.archive, true)
        access.choose(Self.archive, false)
        #expect(!access.isChosen(Self.archive))
        #expect(access.links == [
            MailAccess.Link(mailbox: archive, project: harbor.id, projectName: "Harbor lobby"),
            MailAccess.Link(mailbox: "/Harbor 2026", project: harbor.id, projectName: "Harbor lobby", isMissing: true),
            MailAccess.Link(mailbox: archive, project: kiln.id, projectName: "Kiln"),
        ])
        #expect(access.links.map { MailAccess.note(for: $0) } == ["Also read for “Harbor lobby”", "Also read for “Harbor lobby”", "Also read for “Kiln”"])
        // Without projects, as while Projects is off, there is nothing to list.
        #expect(MailAccess(bridge: mail.bridge, choice: MailChoice(defaults: defaults), isOn: { true }).links.isEmpty)
    }

    @Test func mailboxesAreNamedInTheUsersLanguage() {
        #expect(MailAccess.title(.inbox) == "Inbox (all accounts)")
        #expect(MailAccess.title(.sent) == "Sent (all accounts)")
        #expect(MailAccess.title(Self.archive) == "Archive")
        #expect(MailAccess.place(.inbox) == nil)
        #expect(MailAccess.place(Self.archive) == "Studio")
        #expect(MailAccess.place(Self.imported) == "On My Mac")
    }

    /// The scan reads nothing before Start Reading Mail, even with access allowed and a
    /// mailbox ticked, and reads the ticked mailbox after it. Only the mailboxes were
    /// listed before.
    @Test func nothingIsScannedBeforeTheConfirm() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        mail.put(message: 1, in: Self.imported)
        let access = access()
        var saved: [MailScan.Message] = []
        let scan = MailScan(
            bridge: mail.bridge,
            choice: access.choice,
            lookups: MailScan.Lookups(known: { _ in [] }, linkedMailboxes: { [] }),
            save: { saved += $0 },
            isOn: { true },
            now: { Self.now }
        )
        await access.show()
        access.choose(Self.imported, true)
        #expect(access.canStartReading)
        let before = await scan.scan()
        #expect(before.skipped == .notConfirmed)
        #expect(mail.mailReads == 0)
        #expect(saved.isEmpty)
        access.startReading()
        #expect(access.choice.isConfirmed)
        #expect(!access.canStartReading)
        let after = await scan.scan()
        #expect(after.skipped == nil)
        #expect(after.saved == 1)
        #expect(saved.map(\.messageID) == ["m1@studio.example"])
        #expect(mail.asks.isEmpty)
    }

    /// Start Reading Mail is gray until Orra may read Mail and a mailbox is ticked, and the
    /// line beside it says which comes first.
    @Test func startReadingMailSaysWhyItIsGray() async {
        defer { cleanUp() }
        #expect(MailAccess.startBlocker(access: .unknown, ticked: true) == .access)
        #expect(MailAccess.startBlocker(access: .denied, ticked: false) == .access)
        #expect(MailAccess.startBlocker(access: .allowed, ticked: false) == .mailbox)
        #expect(MailAccess.startBlocker(access: .allowed, ticked: true) == nil)
        #expect(ProjectsSettings.startLine(.access) == "Allow Mail access first.")
        #expect(ProjectsSettings.startLine(.mailbox) == "Tick at least one mailbox first.")
        #expect(ProjectsSettings.startLine(nil) == "Nothing is read before you click Start Reading Mail.")

        mail.remembered = .notAsked
        mail.listingError = .notAsked
        let access = access()
        await access.show()
        #expect(access.startBlocker == .access)
        access.allowClicked()
        await access.ask()
        #expect(access.access == .allowed)
        #expect(access.startBlocker == .mailbox)
        #expect(!access.canStartReading)
        access.choose(Self.archive, true)
        #expect(access.startBlocker == nil)
        #expect(access.canStartReading)
    }

    // MARK: Set Up Projects

    /// Each step of the checklist in each of its states, and the current step: the first of
    /// the first four that waits for the user. A step that runs, such as the download, waits
    /// for Orra, so the next one not done is current then. The optional last step never is.
    @Test func theSetupStepsFollowTheirState() {
        typealias Setup = ProjectsSettings.Setup
        let folder = URL(fileURLWithPath: "/tmp/model")
        func setup(model: ModelInstaller.State = .installed(folder), engine: TextCleanup.EngineState = .ready, mail running: Bool = true, access: MailAccess.Access = .allowed, asking: Bool = false, confirmed: Bool = false, projects: Bool = false) -> Setup {
            Setup(model: model, engine: engine, mailIsRunning: running, access: access, isAsking: asking, confirmed: confirmed, hasProjects: projects)
        }

        // Step 1, the cleanup model.
        #expect(setup().model == .done)
        #expect(setup(engine: .unloadedWhileIdle).model == .done)
        #expect(setup(engine: .failed).model == .todo)
        #expect(setup(model: .checking).model == .inProgress)
        #expect(setup(model: .downloading(bytes: 5, source: nil)).model == .inProgress)
        #expect(setup(model: .verifying).model == .inProgress)
        #expect(setup(model: .missing(bytesPresent: 0)).model == .todo)
        #expect(setup(model: .failed(.offline)).model == .todo)
        // Step 2, Mail.
        #expect(setup(mail: true).mail == .done)
        #expect(setup(mail: false).mail == .todo)
        // Step 3, Mail access.
        #expect(setup(access: .allowed).access == .done)
        #expect(setup(access: .unknown).access == .todo)
        #expect(setup(access: .unknown, asking: true).access == .inProgress)
        #expect(setup(access: .denied).access == .todo)
        // Step 4, the mailboxes, and step 5, a first project.
        #expect(setup().mailboxes == .todo)
        #expect(setup(confirmed: true).mailboxes == .done)
        #expect(setup().project == .todo)
        #expect(setup(projects: true).project == .done)

        // The current step.
        #expect(setup(model: .missing(bytesPresent: 0), mail: false, access: .unknown).current == .model)
        #expect(setup(model: .downloading(bytes: 5, source: nil), mail: false, access: .unknown).current == .mail)
        #expect(setup(model: .downloading(bytes: 5, source: nil), mail: true, access: .unknown).current == .access)
        #expect(setup(model: .verifying, access: .unknown, asking: true).current == .mailboxes)
        #expect(setup(engine: .failed).current == .model)
        #expect(setup(access: .denied).current == .access)
        #expect(setup().current == .mailboxes)
        #expect(setup(projects: true).current == .mailboxes)
        // Every step that waits is done, so none is current, also without a project.
        #expect(setup(confirmed: true).current == nil)
        #expect(setup(model: .downloading(bytes: 5, source: nil), confirmed: true).current == nil)
    }

    // MARK: The Projects window

    /// Start Reading Mail says whether it confirmed the choice, so the page opens the
    /// Projects window then, and only then: not before access is allowed and a mailbox is
    /// ticked, not while Projects is off, and not a second time.
    @Test func onlyTheConfirmOfStartReadingMailOpensTheWindow() async {
        defer { cleanUp() }
        mail.remembered = .allowed
        var on = true
        let access = access(isOn: { on })
        await access.show()
        // No mailbox ticked yet.
        #expect(!access.startReading())
        access.choose(Self.imported, true)
        on = false
        #expect(!access.startReading())
        #expect(!access.choice.isConfirmed)
        on = true
        #expect(access.startReading())
        #expect(access.choice.isConfirmed)
        // Confirmed once, so the button is gone and nothing opens again.
        #expect(!access.startReading())
    }

    /// Without access, Start Reading Mail confirms nothing and opens nothing, even with a
    /// mailbox ticked.
    @Test func withoutAccessStartReadingMailOpensNothing() async {
        defer { cleanUp() }
        mail.remembered = .denied
        mail.listingError = .denied
        let access = access(suggests: true)
        await access.show()
        #expect(access.isChosen(.inbox))
        #expect(!access.startReading())
        #expect(!access.choice.isConfirmed)
    }

    /// Mail as a test plays it: whether it runs, what macOS answers when asked, what the
    /// bridge remembers, the mailboxes, and one mailbox with mail for the scan. Records the
    /// asks, the listings and the reads of mail.
    final class FakeMail: Sendable {
        private struct State {
            var isRunning = true
            var answer = MailPermission.allowed
            var remembered: MailPermission?
            var asks: [Bool] = []
            var listings = 0
            var listingError: MailBridgeError?
            /// An error for the next listing only, as Mail gives while it starts.
            var nextListingError: MailBridgeError?
            /// Runs during each listing, as the user would meanwhile.
            var whileListing: (@Sendable () -> Void)?
            var mailboxes: [MailMailbox] = [.inbox, .sent, ProjectsSettingsTests.archive, ProjectsSettingsTests.imported]
            var box: MailMailbox?
            var messages: [(listing: MailListing, source: String)] = []
            var mailReads = 0
        }

        private let state = Mutex(State())

        var isRunning: Bool {
            get { state.withLock { $0.isRunning } }
            set { state.withLock { $0.isRunning = newValue } }
        }

        /// What macOS answers when asked.
        var answer: MailPermission {
            get { state.withLock { $0.answer } }
            set { state.withLock { $0.answer = newValue } }
        }

        var remembered: MailPermission? {
            get { state.withLock { $0.remembered } }
            set { state.withLock { $0.remembered = newValue } }
        }

        var listingError: MailBridgeError? {
            get { state.withLock { $0.listingError } }
            set { state.withLock { $0.listingError = newValue } }
        }

        var nextListingError: MailBridgeError? {
            get { state.withLock { $0.nextListingError } }
            set { state.withLock { $0.nextListingError = newValue } }
        }

        var whileListing: (@Sendable () -> Void)? {
            get { state.withLock { $0.whileListing } }
            set { state.withLock { $0.whileListing = newValue } }
        }

        var asks: [Bool] {
            state.withLock { $0.asks }
        }

        var listings: Int {
            state.withLock { $0.listings }
        }

        var mailboxes: [MailMailbox] {
            state.withLock { $0.mailboxes }
        }

        /// Counts, listings and sources of messages read.
        var mailReads: Int {
            state.withLock { $0.mailReads }
        }

        /// A message an hour old in a mailbox, the only one with mail.
        func put(message number: Int, in mailbox: MailMailbox) {
            let messageID = "m\(number)@studio.example"
            let source = [
                "Message-ID: <\(messageID)>",
                "From: Mei Tan <mei.tan@studio.example>",
                "To: Bai Lu <bai.lu@lumenhaus.example>",
                "Subject: Floor plan \(number)",
                "Content-Type: text/plain; charset=utf-8",
                "",
                "The floor plan is attached.",
                "",
            ].joined(separator: "\r\n")
            let listing = MailListing(
                message: MailMessageRef(id: number, mailbox: mailbox), messageID: messageID,
                dateReceived: ProjectsSettingsTests.now - 3_600, sender: "Mei Tan <mei.tan@studio.example>",
                subject: "Floor plan \(number)", to: ["bai.lu@lumenhaus.example"], cc: [], size: source.utf8.count
            )
            state.withLock {
                $0.box = mailbox
                $0.messages.append((listing, source))
            }
        }

        var bridge: MailBridge {
            MailBridge(
                isRunning: { self.isRunning },
                permission: { ask in
                    self.state.withLock { state in
                        state.asks.append(ask)
                        let answer = state.isRunning ? state.answer : .mailNotRunning
                        state.remembered = answer
                        if answer == .allowed {
                            state.listingError = nil
                        } else if answer == .denied {
                            state.listingError = .denied
                        }
                        return answer
                    }
                },
                lastPermission: { self.remembered },
                accounts: { throw MailBridgeError.failed(code: -1) },
                mailboxes: {
                    self.whileListing?()
                    return try self.state.withLock { state in
                        state.listings += 1
                        guard state.isRunning else { throw MailBridgeError.mailNotRunning }
                        if let error = state.nextListingError ?? state.listingError {
                            state.nextListingError = nil
                            // As the real bridge, a refusal is remembered.
                            switch error {
                            case .denied: state.remembered = .denied
                            case .notAsked: state.remembered = .notAsked
                            default: break
                            }
                            throw error
                        }
                        state.remembered = .allowed
                        return state.mailboxes
                    }
                },
                count: { mailbox in
                    self.state.withLock { state in
                        state.mailReads += 1
                        return mailbox == state.box ? state.messages.count : 0
                    }
                },
                listing: { mailbox, positions in
                    try self.state.withLock { state in
                        state.mailReads += 1
                        let listings = mailbox == state.box ? state.messages.map(\.listing) : []
                        guard positions.lowerBound >= 1, positions.upperBound <= listings.count else { throw MailBridgeError.notFound }
                        return Array(listings[(positions.lowerBound - 1)..<positions.upperBound])
                    }
                },
                headers: { _ in throw MailBridgeError.notFound },
                source: { message in
                    try self.state.withLock { state in
                        state.mailReads += 1
                        guard let found = state.messages.first(where: { $0.listing.message == message }) else { throw MailBridgeError.notFound }
                        return found.source
                    }
                },
                attachments: { _ in [] },
                mailbox: { _ in throw MailBridgeError.unexpectedReply },
                selection: { [] },
                reply: { _, _ in nil },
                attach: { _, _ in }
            )
        }
    }
}
