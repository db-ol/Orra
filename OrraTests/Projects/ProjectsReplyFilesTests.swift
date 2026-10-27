import Foundation
import Synchronization
import Testing
@testable import Orra

/// The files of a reply in the email view: the files an email asks for, the ticks, the people
/// outside a ticked file's project, the claim of a draft that a file is attached, and Open
/// Reply in Mail with files and without a draft. A fake runtime gives the files and checks
/// them, a fake clipboard and a fake Mail behind the real MailBridge record what happened,
/// and no test sends an Apple Event or touches a file. Made up people at .example addresses.
@MainActor
struct ProjectsReplyFilesTests {
    typealias Person = DraftCheckInput.Person

    /// Monday 19 October 2026 at noon UTC.
    nonisolated static let today = Date(timeIntervalSince1970: 1_792_411_200)
    nonisolated static let id = "lamps-2@harbor.example"
    nonisolated static let harbor = UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A11")!
    nonisolated static let kiln = UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A12")!
    static let mei = Person(name: "Mei Tan", address: "mei@harbor.example")
    static let kai = Person(name: "Kai Moss", address: "kai@kiln.example")
    static let me = Person(name: "Lin", address: "me@studio.example")
    static let draft = "Hi Mei,\n\nThe lamp order is [to confirm: lamp order].\n\nLin"
    static let request = FileRequest(sentence: "Please also send the floor plan.", object: "the floor plan", kinds: ["floorPlan"], fileNames: [])
    static let facts = Explanation.ReplyFacts(
        requests: [request], senderIsKnown: true, reply: ["mei@harbor.example"], replyAll: ["mei@harbor.example", "kai@kiln.example"])
    static let drawings = URL(fileURLWithPath: "/Users/someone/Projects/Harbor lobby/Drawings", isDirectory: true)
    static let plan = drawings.appending(path: "floor-plan-v3.pdf")
    static let olderPlan = drawings.appending(path: "floor-plan-v2.pdf")
    static let sketch = URL(fileURLWithPath: "/Users/someone/Projects/Kiln studio/Sketches/平面图草图.png")
    static let projects = [
        ExplainService.Project(id: harbor, name: "Harbor lobby", people: [ExplainPrompt.Person(name: "Mei Tan", address: "mei@harbor.example")], domains: ["harbor.example"]),
        ExplainService.Project(id: kiln, name: "Kiln studio", people: [ExplainPrompt.Person(name: "Kai Moss", address: "kai@kiln.example")]),
    ]
    nonisolated static let session = MailEvents.Session(processIdentifier: 811, launched: Date(timeIntervalSince1970: 1_761_400_000))

    static func explanation(
        draft: String? = draft, reply: ReplyRule.Decision = .reply(.en), warnings: [ProjectsWarning] = [],
        facts: Explanation.ReplyFacts? = facts, project: UUID? = harbor
    ) -> Explanation {
        let check = DraftCheckInput(
            draft: "", language: .en, recipients: [mei, kai], projectPeople: [mei], own: [me],
            incomingText: "Please also send the floor plan.", sourceTexts: [], questionsForUser: [], today: today)
        let drafted: Explanation.Draft = switch reply {
        case .noReply(let reason): .noReply(reason)
        case .reply(.other): .noDraft
        case .reply: draft.map { .checked(DraftCheck.Result(draft: $0, language: .en)) } ?? .missing
        }
        return Explanation(
            messageID: id, project: project, language: .en, today: today, reply: reply,
            warnings: warnings.map { ExplainPrompt.Finding(warning: $0, place: .email) },
            modelWarnings: [], points: [], questions: [], draft: drafted,
            draftCheck: drafted == .noDraft ? nil : check, sources: [:], removed: [:], problems: [], unknownSources: [],
            replyFacts: facts)
    }

    /// A file as the checks give it, with an identity of its own: its number on the volume
    /// comes from its path, so two files are two files.
    static func file(_ url: URL, projects: [UUID] = [harbor], size: Int64 = 1_000, number: UInt64? = nil) -> ReplyFile {
        ReplyFile(url: url, projects: projects, identity: ReplyFile.Identity(
            device: 16_777_231, fileSystem: 26, number: number ?? Self.number(of: url),
            made: Date(timeIntervalSince1970: 1_760_000_000), size: size, modified: Date(timeIntervalSince1970: 1_761_000_000)))
    }

    /// The file at a path after a rename to another name, the same file with the same
    /// identity, as ReplyFiles.recheck gives it.
    static func renamed(_ url: URL, to name: URL) -> ReplyFile {
        var moved = file(url)
        moved.url = name
        return moved
    }

    /// A number for a path, one of its own for each path in these tests.
    nonisolated static func number(of url: URL) -> UInt64 {
        url.path.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// The runtime's lookups, the clipboard and Mail, all fakes, which record what happened.
    final class Fakes: Sendable {
        enum Step: Equatable, Sendable {
            case copy(String)
            case reply(all: Bool)
            case attach(URL)
            case front
        }

        struct State: Sendable {
            var steps: [Step] = []
            /// The searches for requested files, with their scope.
            var searches: [[UUID]?] = []
            /// What a search finds.
            var found: [RequestedFile] = []
            /// What a tick of a path gives, the file itself at that path by default.
            var ticks: [String: Result<ReplyFile, ReplyFileProblem>] = [:]
            /// What the check right before the event gives, the file as it is by default.
            var checks: [String: Result<ReplyFile, ReplyFileProblem>] = [:]
            /// The error code of Mail's answer to each file's attach event, none when Mail
            /// takes it.
            var attachFailures: [URL: Int] = [:]
            var listed: MailStore.Listed?
            /// What happens while a file is checked, as the user or a warning changing the
            /// ticks while a handoff runs.
            var whileChecking: (@Sendable (URL) async -> Void)?
            /// The paths checked again, in order.
            var rechecked: [String] = []
        }

        let state = Mutex(State())

        nonisolated func update(_ change: (inout State) -> Void) {
            state.withLock { change(&$0) }
        }

        nonisolated var value: State {
            state.withLock { $0 }
        }

        @MainActor
        var actions: ProjectsReplyFiles.Actions {
            ProjectsReplyFiles.Actions(
                requestedFiles: { [self] _, _, scope in
                    update { $0.searches.append(scope) }
                    return value.found
                },
                replyFile: { [self] url, _ in
                    value.ticks[url.path] ?? .success(ProjectsReplyFilesTests.file(url))
                },
                recheck: { [self] file in
                    update { $0.rechecked.append(file.url.path) }
                    if let whileChecking = value.whileChecking {
                        await whileChecking(file.url)
                    }
                    return value.checks[file.url.path] ?? .success(file)
                },
                replyProjects: { ProjectsReplyFilesTests.projects },
                defaultFolder: { _ in ProjectsReplyFilesTests.drawings },
                listed: { [self] _ in value.listed })
        }

        /// Mail behind the real MailBridge: the reply is outgoing message 77 of the session,
        /// and an attach event fails with the code a test sets for its file.
        var bridge: MailBridge {
            MailBridge(events: MailEvents(
                isRunning: { true },
                send: { [self] request in
                    switch request {
                    case .reply(_, let all):
                        update { $0.steps.append(.reply(all: all)) }
                        return .reference(.id(MailEvents.Code.outgoingMessage, 77, of: .application))
                    case .attach(let url, _, _):
                        let failure = state.withLock { state -> Int? in
                            state.steps.append(.attach(url))
                            return state.attachFailures[url]
                        }
                        if let failure {
                            throw MailEvents.Failure(code: failure)
                        }
                        return .missing
                    case .get, .count:
                        return .missing
                    }
                },
                permission: { _ in 0 },
                session: { ProjectsReplyFilesTests.session }))
        }
    }

    let fakes = Fakes()

    private func model(
        referenceFailure: MailBridgeError? = nil,
        explanation: @escaping () -> Explanation? = { ProjectsReplyFilesTests.explanation() }
    ) -> ProjectsEmailModel {
        let fakes = fakes
        var actions = ProjectsEmailModel.Actions(
            explanation: { _ in explanation() },
            versions: { _ in [] },
            removeNewestVersion: { _ in false },
            editedDraft: { _ in nil },
            saveEditedDraft: { _, _ in Task { true } },
            reviseContext: { _ in nil },
            reviseService: { _ in throw RewriteError.notLoaded },
            userRequest: { request in try await request() },
            email: { _ in nil },
            mailReference: { _, _ in
                if let referenceFailure { throw referenceFailure }
                return MailMessageRef(id: 4, mailbox: .inbox)
            },
            handoff: ReplyHandoff(
                copy: { text in
                    fakes.update { $0.steps.append(.copy(text)) }
                    return true
                },
                mail: fakes.bridge,
                isOrraActive: { true },
                bringMailToFront: { fakes.update { $0.steps.append(.front) } }),
            userLanguage: .en,
            now: { Self.today },
            highlight: { before, after in ProjectsDraftDiff.segments(from: before, to: after) })
        actions.replyFiles = fakes.actions
        let model = ProjectsEmailModel(messageID: Self.id, actions: actions)
        model.saveDelay = .zero
        return model
    }

    /// Waits until the files of every request were looked for.
    private func loaded(_ model: ProjectsEmailModel) async throws {
        await model.load()
        try await waitUntil { !model.replyFiles.isLooking }
    }

    // MARK: Files This Email Asks For

    @Test func theRequestsShowOnlyWhenAReplyIsDue() async throws {
        fakes.update { $0.found = [RequestedFile(url: Self.plan, project: Self.harbor, modified: Self.today)] }
        let due = model()
        try await loaded(due)
        #expect(due.replyFiles.groups.map(\.request) == [Self.request])
        #expect(due.replyFiles.groups.first?.files?.map(\.url) == [Self.plan])
        #expect(fakes.value.searches == [nil])

        let notDue = model { Self.explanation(reply: .noReply(.answeredLater)) }
        try await loaded(notDue)
        #expect(!notDue.replyFiles.hasRequests)
        #expect(!notDue.replyFiles.offersFiles)
        // An explanation from before 0.6.1 has no facts and shows no section.
        let before = model { Self.explanation(facts: nil) }
        try await loaded(before)
        #expect(!before.replyFiles.hasRequests)
        #expect(fakes.value.searches == [nil])
    }

    @Test func nothingIsTickedUntilTheUserTicks() async throws {
        fakes.update { $0.found = [RequestedFile(url: Self.plan, project: Self.harbor, modified: Self.today)] }
        let model = model()
        try await loaded(model)
        #expect(model.replyFiles.ticked.isEmpty)
        #expect(!model.replyFiles.isTicked(Self.plan))
        await model.replyFiles.setTicked(Self.plan, true)
        #expect(model.replyFiles.ticked.map(\.url) == [Self.plan])
        // Explain Again keeps the ticks and finds nothing ticked by itself.
        await model.load()
        #expect(model.replyFiles.ticked.map(\.url) == [Self.plan])
    }

    /// A file ticked in one list is ticked everywhere it shows, once, by its real path.
    @Test func aTickAddsTheFileOnceEverywhere() async throws {
        let model = model()
        try await loaded(model)
        let link = URL(fileURLWithPath: "/Users/someone/Link to Drawings/floor-plan-v3.pdf")
        fakes.update { $0.ticks[link.path] = .success(Self.file(Self.plan)) }
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.add([link])
        #expect(model.replyFiles.ticked.map(\.url) == [Self.plan])
        #expect(model.replyFiles.isTicked(Self.plan))
        await model.replyFiles.setTicked(Self.plan, false)
        #expect(model.replyFiles.ticked.isEmpty)
    }

    @Test func tenFilesAtMost() async throws {
        let model = model()
        try await loaded(model)
        for number in 1...ReplyFiles.maximum {
            await model.replyFiles.setTicked(Self.drawings.appending(path: "plan-\(number).pdf"), true)
        }
        #expect(!model.replyFiles.reachedCap)
        let eleventh = Self.drawings.appending(path: "plan-11.pdf")
        await model.replyFiles.setTicked(eleventh, true)
        #expect(model.replyFiles.ticked.count == ReplyFiles.maximum)
        #expect(!model.replyFiles.isTicked(eleventh))
        #expect(model.replyFiles.reachedCap)
        model.replyFiles.remove(model.replyFiles.ticked[0])
        #expect(!model.replyFiles.reachedCap)
        await model.replyFiles.setTicked(eleventh, true)
        #expect(model.replyFiles.isTicked(eleventh))
    }

    /// A sender that looks spoofed, by the explanation's warnings or its list's, gets no
    /// search, no tick and no file for the handoff.
    @Test func aSpoofedSenderGetsNoFilesAndPassesNone() async throws {
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        #expect(model.replyFiles.ticked.count == 1)

        let spoofed = self.model { Self.explanation(warnings: [.lookalikeDomain]) }
        try await loaded(spoofed)
        #expect(spoofed.replyFiles.scope == .spoofed)
        #expect(spoofed.replyFiles.groups.first?.files == [])
        #expect(fakes.value.searches == [nil])
        await spoofed.replyFiles.setTicked(Self.plan, true)
        await spoofed.replyFiles.add([Self.plan])
        #expect(spoofed.replyFiles.ticked.isEmpty)
        #expect(!spoofed.replyFiles.offersFiles)

        // By the list's warnings, after the user ticked a file: the tick goes and the handoff
        // passes no file.
        fakes.update { $0.listed = Self.listed(warnings: [.senderNameMismatch]) }
        await model.load()
        #expect(model.replyFiles.senderLooksSpoofed)
        #expect(model.replyFiles.handoffFiles.isEmpty)
        await model.openReply(all: false)
        #expect(!fakes.value.steps.contains { if case .attach = $0 { true } else { false } })
    }

    /// A flagged email looks in its own project's folders only, and in none without a
    /// project. Mail set aside shows no request.
    @Test func aFlaggedEmailSearchesItsOwnProjectOnly() async throws {
        let flagged = model { Self.explanation(warnings: [.forwardRequest]) }
        try await loaded(flagged)
        #expect(flagged.replyFiles.scope == .ownProject(Self.harbor))
        #expect(fakes.value.searches == [[Self.harbor]])
        let none = model { Self.explanation(warnings: [.instructionToAssistant], project: nil) }
        try await loaded(none)
        #expect(none.replyFiles.scope == .nowhere)
        #expect(none.replyFiles.groups.first?.files == [])
        fakes.update { $0.listed = Self.listed(level: .setAside) }
        let setAside = model { Self.explanation(project: nil) }
        try await loaded(setAside)
        #expect(!setAside.replyFiles.hasRequests)
        #expect(fakes.value.searches == [[Self.harbor]])
        // An email that is not flagged looks everywhere.
        fakes.update { $0.listed = nil }
        let plain = model { Self.explanation(project: nil) }
        try await loaded(plain)
        #expect(plain.replyFiles.scope == .everyProject)
        #expect(fakes.value.searches == [[Self.harbor], nil])
    }

    /// A file found for an earlier request shows there only.
    @Test func aFileShowsUnderTheFirstRequestThatFoundIt() async throws {
        let second = FileRequest(sentence: "And the floor plan of the annex.", object: "the floor plan of the annex", kinds: ["floorPlan"], fileNames: [])
        var facts = Self.facts
        facts.requests = [Self.request, second]
        fakes.update { $0.found = [RequestedFile(url: Self.plan, project: Self.harbor, modified: Self.today)] }
        let model = model { Self.explanation(facts: facts) }
        try await loaded(model)
        #expect(model.replyFiles.groups.map { $0.files?.map(\.url) } == [[Self.plan], []])
    }

    @Test func theOutsideLineNamesThePeopleOutsideTheFilesProjects() async throws {
        let model = model()
        try await loaded(model)
        #expect(model.replyFiles.outside(of: Self.file(Self.plan)) == ["kai@kiln.example"])
        #expect(model.replyFiles.outside(of: Self.file(Self.sketch, projects: [Self.kiln])) == ["mei@harbor.example"])
        #expect(model.replyFiles.outside(of: Self.file(Self.plan, projects: [Self.harbor, Self.kiln])).isEmpty)
        // Without facts, the people the draft check names.
        let before = self.model { Self.explanation(facts: nil) }
        try await loaded(before)
        #expect(before.replyFiles.outside(of: Self.file(Self.plan)) == ["kai@kiln.example"])
    }

    @Test func theUnknownSenderLineFollowsTheFacts() async throws {
        var facts = Self.facts
        facts.senderIsKnown = false
        let unknown = model { Self.explanation(facts: facts) }
        try await loaded(unknown)
        #expect(unknown.replyFiles.senderIsUnknown)
        let known = model()
        try await loaded(known)
        #expect(!known.replyFiles.senderIsUnknown)
    }

    // MARK: The handoff with files

    @Test func openReplyChecksThenPassesTheFilesInOrder() async throws {
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.sketch, true)
        await model.openReply(all: true)
        #expect(fakes.value.steps == [.copy(Self.draft), .reply(all: true), .attach(Self.plan), .attach(Self.sketch), .copy(Self.draft), .front])
        #expect(model.handoffNote == .outcome(.replyOpened(files: [.attached, .attached])))
        #expect(model.handoffFiles == ProjectsEmailModel.HandoffFiles(withDraft: true, given: 2, attached: 2, notAttached: []))
        #expect(!model.isAttaching)
        // Copy takes the draft only.
        model.copy()
        #expect(model.handoffFiles == nil)
    }

    /// A file the index followed through a rename goes in from its new place, and stays
    /// ticked there.
    @Test func aRenamedFileIsAttachedFromItsNewPlace() async throws {
        let renamed = Self.drawings.appending(path: "floor-plan-v3-final.pdf")
        fakes.update { $0.checks[Self.plan.path] = .success(Self.renamed(Self.plan, to: renamed)) }
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.openReply(all: false)
        #expect(fakes.value.steps.contains(.attach(renamed)))
        #expect(!fakes.value.steps.contains(.attach(Self.plan)))
        #expect(model.replyFiles.ticked.map(\.url) == [renamed])
        #expect(model.handoffFiles?.attached == 1)
    }

    @Test func aFileOutsideTheFoldersIsNotPassedAndSaysWhy() async throws {
        fakes.update { $0.checks[Self.plan.path] = .failure(.notInAddedFolder) }
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.sketch, true)
        await model.openReply(all: false)
        #expect(!fakes.value.steps.contains(.attach(Self.plan)))
        #expect(fakes.value.steps.contains(.attach(Self.sketch)))
        #expect(model.replyFiles.problem(at: Self.plan) == .notInAddedFolder)
        #expect(model.handoffFiles?.notAttached == [.init(file: Self.file(Self.plan), problem: .notChecked(.notInAddedFolder))])
        // Orra kept it back, so the note does not ask to drag it, and its row cannot be
        // dragged out.
        #expect(ProjectsWindowText.handoffLines(try #require(model.handoffNote), files: model.shownHandoffFiles) == [
            "Mail opened the reply with 1 file attached, and the draft is on the clipboard. Press ⌘V in the reply window.",
            "Orra checked these files again and did not attach them:",
            "floor-plan-v3.pdf: No longer in a folder you added to a project.",
        ])
        #expect(!model.replyFiles.canDrag(try #require(model.replyFiles.ticked.first { $0.url == Self.plan })))
        #expect(model.replyFiles.canDrag(try #require(model.replyFiles.ticked.first { $0.url == Self.sketch })))
    }

    @Test func theNoteListsTheFilesMailDidNotTake() async throws {
        fakes.update { $0.attachFailures[Self.sketch] = -10000 }
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.sketch, true)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.openReply(all: false)
        let note = try #require(model.handoffFiles)
        #expect(note.attached == 1)
        #expect(note.notAttached == [.init(file: Self.file(Self.sketch), problem: .refused(code: -10000))])
        let lines = ProjectsWindowText.handoffLines(try #require(model.handoffNote), files: note)
        #expect(lines.first == "Mail opened the reply with 1 file attached, and the draft is on the clipboard. Press ⌘V in the reply window.")
        #expect(lines.contains("These files are not attached. Drag them from Attachments for the Reply into the reply window:"))
        #expect(lines.last == "平面图草图.png: Mail did not take it.")
    }

    /// A file that goes off the reply while the handoff runs is not given to Mail, and the
    /// note leaves it out. The window turns the ticks off meanwhile, so here the sketch goes
    /// while the plan is checked, as a warning would take it.
    @Test func aFileTakenOffTheReplyWhileTheHandoffRunsIsNotGiven() async throws {
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.sketch, true)
        let (plan, sketch) = (Self.plan, Self.sketch)
        fakes.update { state in
            state.whileChecking = { url in
                guard url == plan else { return }
                await MainActor.run {
                    if let ticked = model.replyFiles.ticked.first(where: { $0.url == sketch }) {
                        model.replyFiles.remove(ticked)
                    }
                }
            }
        }
        await model.openReply(all: false)
        #expect(fakes.value.steps == [.copy(Self.draft), .reply(all: false), .attach(Self.plan), .copy(Self.draft), .front])
        #expect(model.handoffNote == .outcome(.replyOpened(files: [.attached, .notAttached(.unticked)])))
        #expect(model.handoffFiles == ProjectsEmailModel.HandoffFiles(withDraft: true, given: 2, attached: 1, notAttached: []))
    }

    /// A warning that the sender may not be who they claim, which arrives while the handoff
    /// checks a file, takes every file off the reply, and Mail is asked for none of them,
    /// the file under its check included.
    @Test func aSpoofWarningDuringTheHandoffStopsEveryFileNotYetGiven() async throws {
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.sketch, true)
        let (plan, fakes) = (Self.plan, fakes)
        let spoofed = Self.listed(warnings: [.lookalikeDomain])
        fakes.update { state in
            state.whileChecking = { url in
                guard url == plan else { return }
                fakes.update { $0.listed = spoofed }
                await model.load()
            }
        }
        await model.openReply(all: false)
        #expect(!fakes.value.steps.contains { if case .attach = $0 { true } else { false } })
        #expect(model.handoffNote == .outcome(.replyOpened(files: [.notAttached(.unticked), .notAttached(.unticked)])))
        #expect(model.replyFiles.ticked.isEmpty)
        #expect(model.replyFiles.senderLooksSpoofed)
    }

    /// A blank draft with ticked files goes as no draft does: the line above the buttons
    /// says so, as the footer and the missing Copy do, since the handoff puts nothing on the
    /// clipboard. Without files a blank draft is as before.
    @Test func aBlankDraftWithFilesSaysTheReplyOpensWithoutTheClipboard() async throws {
        let model = model()
        try await loaded(model)
        #expect(model.handsOffDraft)
        model.text = " \n"
        #expect(model.handsOffDraft)
        await model.replyFiles.setTicked(Self.plan, true)
        #expect(!model.handsOffDraft)
        #expect(ProjectsWindowText.handoffLine(hasDraft: model.handsOffDraft, hasFiles: true) == "Open Reply in Mail opens the reply with the files you ticked. Write your reply in Mail, check the recipients and send it yourself.")
        model.text = Self.draft
        #expect(model.handsOffDraft)
        #expect(ProjectsWindowText.handoffLine(hasDraft: model.handsOffDraft, hasFiles: true) == "Open Reply in Mail puts the draft on the clipboard and adds the files you ticked. Press ⌘V in the reply window, check the recipients and the files, and send it yourself.")
        // An email without a draft never hands one off.
        let none = self.model { Self.explanation(reply: .reply(.other)) }
        try await loaded(none)
        await none.replyFiles.setTicked(Self.plan, true)
        #expect(!none.handsOffDraft)
    }

    /// A ticked file's row can be dragged out only while its file passed its last check. The
    /// pointer on the row checks it again, at most once in a pause, and a rename the check
    /// follows moves the row to the new name.
    @Test func aRowCanBeDraggedOnlyWhileItsFilePassedItsLastCheck() async throws {
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        let ticked = try #require(model.replyFiles.ticked.first)
        #expect(model.replyFiles.canDrag(ticked))
        // Its folder left the project.
        fakes.update { $0.checks[Self.plan.path] = .failure(.notInAddedFolder) }
        await model.replyFiles.recheck(ticked)
        #expect(!model.replyFiles.canDrag(ticked))
        #expect(model.replyFiles.problem(at: Self.plan) == .notInAddedFolder)
        // Within the pause the pointer checks nothing again.
        fakes.update { $0.checks[Self.plan.path] = nil }
        await model.replyFiles.recheck(ticked)
        #expect(fakes.value.rechecked == [Self.plan.path])
        #expect(!model.replyFiles.canDrag(ticked))
        // After it, the file passes again, and so does its row.
        model.replyFiles.recheckPause = .zero
        await model.replyFiles.recheck(ticked)
        #expect(fakes.value.rechecked == [Self.plan.path, Self.plan.path])
        #expect(model.replyFiles.canDrag(ticked))
        #expect(model.replyFiles.problem(at: Self.plan) == nil)
        let final = Self.drawings.appending(path: "floor-plan-v3-final.pdf")
        fakes.update { $0.checks[Self.plan.path] = .success(Self.renamed(Self.plan, to: final)) }
        await model.replyFiles.recheck(ticked)
        #expect(model.replyFiles.ticked.map(\.url) == [final])
        #expect(model.replyFiles.canDrag(try #require(model.replyFiles.ticked.first)))
    }

    /// A file the note says Mail did not take shows there by the name its row has now, and
    /// leaves the note once the user takes it off the reply, as Attachments for the Reply no
    /// longer holds it to drag, with the line that says to drag files from there.
    @Test func theNoteFollowsTheRowsOfTheFilesItNames() async throws {
        fakes.update { $0.attachFailures[Self.sketch] = -10000 }
        let model = model()
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.replyFiles.setTicked(Self.sketch, true)
        await model.openReply(all: false)
        let note = try #require(model.handoffNote)
        let attached = "Mail opened the reply with 1 file attached, and the draft is on the clipboard. Press ⌘V in the reply window."
        #expect(ProjectsWindowText.handoffLines(note, files: model.shownHandoffFiles) == [
            attached,
            "These files are not attached. Drag them from Attachments for the Reply into the reply window:",
            "平面图草图.png: Mail did not take it.",
        ])
        let renamed = Self.sketch.deletingLastPathComponent().appending(path: "平面图草图-2.png")
        fakes.update { $0.checks[Self.sketch.path] = .success(Self.renamed(Self.sketch, to: renamed)) }
        await model.replyFiles.recheck(try #require(model.replyFiles.ticked.first { $0.url == Self.sketch }))
        #expect(ProjectsWindowText.handoffLines(note, files: model.shownHandoffFiles).last == "平面图草图-2.png: Mail did not take it.")
        model.replyFiles.remove(try #require(model.replyFiles.ticked.first { $0.url == renamed }))
        #expect(ProjectsWindowText.handoffLines(note, files: model.shownHandoffFiles) == [attached])
    }

    /// Where the files are looked for follows the warnings about the email itself and its
    /// attachments. Hidden text in a project file, a line to an assistant in a message of the
    /// thread and a claim to come from Orra in the project's other mail are about those
    /// texts and keep no project out, also once the list holds their kinds, as the store
    /// adds every kind an explanation found to the email's.
    @Test func onlyTheEmailsOwnWarningsNarrowWhereFilesAreLookedFor() async throws {
        let elsewhere = [
            ExplainPrompt.Finding(warning: .hiddenText, place: .file("F1")),
            ExplainPrompt.Finding(warning: .instructionToAssistant, place: .thread("T1")),
            ExplainPrompt.Finding(warning: .claimsToBeOrra, place: .projectMail("M1")),
        ]
        fakes.update { $0.listed = Self.listed(warnings: [.hiddenText, .instructionToAssistant, .claimsToBeOrra]) }
        var plainExplanation = Self.explanation()
        plainExplanation.warnings = elsewhere
        let plainOne = plainExplanation
        let plain = model { plainOne }
        try await loaded(plain)
        #expect(plain.replyFiles.scope == .everyProject)
        #expect(fakes.value.searches == [nil])
        // In an attachment of the email, hidden text keeps other projects out.
        var attachedExplanation = plainExplanation
        attachedExplanation.warnings.append(ExplainPrompt.Finding(warning: .hiddenText, place: .attachment("A1")))
        let attachedOne = attachedExplanation
        let flagged = model { attachedOne }
        try await loaded(flagged)
        #expect(flagged.replyFiles.scope == .ownProject(Self.harbor))
        #expect(fakes.value.searches == [nil, [Self.harbor]])
        #expect(ProjectsReplyFiles.scopeWarnings(elsewhere, listed: [.hiddenText, .senderNameMismatch]) == [.senderNameMismatch])
        #expect(ProjectsReplyFiles.scopeWarnings([ExplainPrompt.Finding(warning: .forwardRequest, place: .email)], listed: []) == [.forwardRequest])
    }

    /// An email Projects wrote no draft for gets Open Reply in Mail once a file is ticked,
    /// and nothing goes on the clipboard.
    @Test func withoutADraftOpenReplyAttachesWithoutTheClipboard() async throws {
        let model = model { Self.explanation(reply: .reply(.other)) }
        try await loaded(model)
        #expect(!model.hasDraft)
        #expect(model.replyFiles.offersFiles)
        #expect(!model.canHandOff)
        // A reply to all reaches Kai too.
        #expect(model.offersReplyAll)
        await model.replyFiles.setTicked(Self.plan, true)
        #expect(model.canHandOff)
        await model.openReply(all: false)
        #expect(fakes.value.steps == [.reply(all: false), .attach(Self.plan), .front])
        #expect(model.handoffFiles == ProjectsEmailModel.HandoffFiles(withDraft: false, given: 1, attached: 1, notAttached: []))
        let lines = ProjectsWindowText.handoffLines(try #require(model.handoffNote), files: model.handoffFiles)
        #expect(lines == ["Mail opened the reply with 1 file attached. Write your reply there."])
    }

    /// A blank draft with ticked files opens the reply with the files and puts nothing on the
    /// clipboard, as for an email without a draft. Without files a blank draft changes
    /// nothing, as before.
    @Test func aBlankDraftWithFilesOpensTheReplyWithoutTheClipboard() async throws {
        let model = model()
        try await loaded(model)
        model.text = "  \n"
        await model.openReply(all: false)
        #expect(model.handoffNote == .outcome(.emptyDraft))
        #expect(model.handoffFiles == nil)
        #expect(fakes.value.steps.isEmpty)
        await model.replyFiles.setTicked(Self.plan, true)
        await model.openReply(all: false)
        #expect(fakes.value.steps == [.reply(all: false), .attach(Self.plan), .front])
        #expect(model.handoffFiles?.withDraft == false)
    }

    /// When Mail cannot confirm the email, no reply opens and no file goes, and the note
    /// says so.
    @Test func noFileGoesWhenTheReplyDoesNotOpen() async throws {
        let failing = model(referenceFailure: .denied)
        try await loaded(failing)
        await failing.replyFiles.setTicked(Self.plan, true)
        await failing.openReply(all: false)
        #expect(failing.handoffNote == .outcome(.copiedReplyFailed(.denied)))
        #expect(failing.handoffFiles == ProjectsEmailModel.HandoffFiles(withDraft: true, given: 1, attached: 0, notAttached: []))
        let lines = ProjectsWindowText.handoffLines(try #require(failing.handoffNote), files: failing.handoffFiles)
        #expect(lines == ["Orra may not control Mail, so the draft is only on the clipboard. Allow it in Settings.", "No files were attached."])
        #expect(!fakes.value.steps.contains { if case .attach = $0 { true } else { false } })
    }

    // MARK: The draft's claim

    @Test func theClaimLineFollowsTheSettledTextAndTheTicks() async throws {
        let model = model()
        try await loaded(model)
        #expect(!model.replyFiles.claimsAttachment)
        model.text = Self.draft + "\n\nAttached is the floor plan."
        try await waitUntil { model.replyFiles.claimsAttachment }
        await model.replyFiles.setTicked(Self.plan, true)
        #expect(!model.replyFiles.claimsAttachment)
        model.replyFiles.remove(model.replyFiles.ticked[0])
        #expect(model.replyFiles.claimsAttachment)
        model.text = Self.draft + "\n\n附上平面图。"
        try await waitUntil { model.saveNote == .saved }
        #expect(model.replyFiles.claimsAttachment)
        model.text = Self.draft + "\n\nThanks for the attached plan."
        try await waitUntil { !model.replyFiles.claimsAttachment }
    }

    /// The claim line never shows for a sender that looks spoofed, who gets no files.
    @Test func aSpoofedSenderGetsNoClaimLine() async throws {
        let model = model { Self.explanation(draft: Self.draft + "\n\nAttached is the floor plan.", warnings: [.lookalikeDomain]) }
        try await loaded(model)
        model.text = model.text + " "
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.replyFiles.claimsAttachment)
    }

    // MARK: How long the ticks last

    @Test func theTicksGoWithTheExplanation() async throws {
        var current: Explanation? = Self.explanation()
        let model = model { current }
        try await loaded(model)
        await model.replyFiles.setTicked(Self.plan, true)
        current = Self.explanation(draft: "Hi Mei,\n\nNoted.\n\nLin")
        await model.load()
        #expect(model.replyFiles.ticked.count == 1)
        current = nil
        await model.load()
        #expect(model.replyFiles.ticked.isEmpty)
        #expect(!model.replyFiles.hasRequests)
        // Closing the window ends the look under way.
        current = Self.explanation()
        await model.load()
        model.cancelWork()
        #expect(!model.replyFiles.isLooking)
    }

    @Test func addFileRefusesAPathTheIndexDoesNotHold() async throws {
        let downloads = URL(fileURLWithPath: "/Users/someone/Downloads/brochure.pdf")
        let cloud = URL(fileURLWithPath: "/Users/someone/Projects/Harbor lobby/cloud.pdf")
        let package = URL(fileURLWithPath: "/Users/someone/Projects/Harbor lobby/Lobby.key")
        fakes.update { state in
            state.ticks[downloads.path] = .failure(.notInAddedFolder)
            state.ticks[cloud.path] = .failure(.notDownloaded)
            state.ticks[package.path] = .failure(.package)
        }
        let model = model()
        try await loaded(model)
        await model.replyFiles.add([downloads, cloud, package, Self.plan])
        #expect(model.replyFiles.ticked.map(\.url) == [Self.plan])
        #expect(model.replyFiles.refusals == [
            .init(problem: .notInAddedFolder, name: "brochure.pdf"),
            .init(problem: .notDownloaded, name: "cloud.pdf"),
            .init(problem: .package, name: "Lobby.key"),
        ])
        #expect(model.replyFiles.refusals.map(ProjectsWindowText.refusal) == [
            "Orra attaches only files in the folders you added to a project, once Projects has read them. Add the file's folder to a project first, then wait until Projects has read it.",
            "cloud.pdf is not downloaded to this Mac. Download it in Finder first.",
            "Orra attaches single files only, not packages such as some Keynote or Pages documents.",
        ])
        // Where Add File… starts.
        #expect(await model.replyFiles.defaultFolder() == Self.drawings)
    }

    // MARK: Words

    /// Every reason, scope and state of the files of a reply has words of its own.
    @Test func everyValueOfTheReplyFilesHasWords() {
        let problems: [ReplyFileProblem] = [.notInAddedFolder, .moved, .changed, .notDownloaded, .package]
        #expect(Set(problems.map(ProjectsWindowText.replyFileProblem)).count == problems.count)
        let attach: [ReplyHandoff.AttachProblem] = [.unticked, .noReplyNamed, .replyClosed, .refused(code: -1), .timedOut, .afterTimeOut, .notAllowed, .mailQuit]
        let reasons = attach.map(ProjectsWindowText.attachProblem) + problems.map { ProjectsWindowText.attachProblem(.notChecked($0)) }
        #expect(Set(reasons).count == reasons.count)
        #expect(!reasons.contains(""))
        #expect(ProjectsWindowText.scope(.everyProject) == nil)
        let scopes: [ProjectsReplyFiles.Scope] = [.ownProject(Self.harbor), .nowhere, .spoofed]
        #expect(Set(scopes.compactMap(ProjectsWindowText.scope)).count == scopes.count)
        let lines = [(true, false), (true, true), (false, true)].map { ProjectsWindowText.handoffLine(hasDraft: $0.0, hasFiles: $0.1) }
        #expect(Set(lines).count == lines.count)
        let refusals = problems.map { ProjectsWindowText.refusal(.init(problem: $0, name: "plan.pdf")) }
        #expect(refusals[ReplyFileProblem.notDownloaded.index(in: problems)] == "plan.pdf is not downloaded to this Mac. Download it in Finder first.")
        #expect(Set(refusals).count == 3)
        #expect(ProjectsWindowText.attachCap == "Orra attaches at most 10 files to one reply.")
        #expect(ProjectsWindowText.largeTotal(25_000_000, locale: Locale(identifier: "en_US")) == "These files add up to 25 MB, more than many mail servers take.")
        #expect(ProjectsWindowText.outside(project: "Harbor lobby", addresses: ["kai@kiln.example", "pat@new.example"]) == "Your reply may reach people outside Harbor lobby: kai@kiln.example, pat@new.example")
        #expect(ProjectsWindowText.saysMailIsNotOpen(.outcome(.copiedMailNotRunning)))
        #expect(ProjectsWindowText.saysMailIsNotOpen(.outcome(.mailNotRunning)))
        #expect(!ProjectsWindowText.saysMailIsNotOpen(.outcome(.replyFailed(.denied))))
        // Without files and with a draft, the note is as before.
        #expect(ProjectsWindowText.handoffLines(.outcome(.replyOpened(files: [])), files: nil) == [ProjectsWindowText.handoff(.outcome(.replyOpened(files: [])))])
        let three = ProjectsEmailModel.HandoffFiles(withDraft: true, given: 3, attached: 3, notAttached: [])
        #expect(ProjectsWindowText.handoffLines(.outcome(.replyOpened(files: [.attached, .attached, .attached])), files: three) == ["Mail opened the reply with 3 files attached, and the draft is on the clipboard. Press ⌘V in the reply window."])
        let none = ProjectsEmailModel.HandoffFiles(withDraft: false, given: 1, attached: 0, notAttached: [.init(file: Self.file(Self.drawings.appending(path: "plan.pdf")), problem: .replyClosed)])
        #expect(ProjectsWindowText.handoffLines(.outcome(.replyOpened(files: [.notAttached(.replyClosed)])), files: none) == [
            "Mail opened the reply. Write your reply there.",
            "These files are not attached. Drag them from Attachments for the Reply into the reply window:",
            "plan.pdf: The reply window closed first.",
        ])
        #expect(ProjectsWindowText.request(Self.request) == "The email asks: Please also send the floor plan.")
        #expect(ProjectsWindowText.attachLabel("plan.pdf") == "Attach plan.pdf to the reply")
        #expect(ProjectsWindowText.removeLabel("plan.pdf") == "Remove plan.pdf from the reply")
    }

    /// The words of the files of a reply in Chinese, as the catalog gives them.
    @Test func theWordsOfTheFilesOfAReplyReadInChinese() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        #expect(chinese.localizedString(forKey: "Files This Email Asks For", value: nil, table: nil) == "对方要的文件")
        #expect(chinese.localizedString(forKey: "Attach to Reply", value: nil, table: nil) == "附加到回复")
        #expect(chinese.localizedString(forKey: "Attachments for the Reply", value: nil, table: nil) == "回复的附件")
    }

    static func listed(warnings: [ProjectsWarning] = [], level: SortingLevel? = .sure) -> MailStore.Listed {
        MailStore.Listed(
            messageID: id, date: today, sender: MailStore.Person(address: "mei@harbor.example"), subject: "Lobby lamps",
            project: harbor, level: level, reasons: [], movedByUser: false, reply: .reply(.en), warnings: warnings,
            isExplained: true, hasText: true, summary: "")
    }
}

private extension ReplyFileProblem {
    func index(in problems: [ReplyFileProblem]) -> Int {
        problems.firstIndex(of: self) ?? 0
    }
}
