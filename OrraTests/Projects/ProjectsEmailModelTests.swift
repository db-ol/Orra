import Foundation
import Synchronization
import Testing
@testable import Orra

/// The email view of one email: the draft as the user edits it, a change from the change
/// box or a tone with its highlight and Undo, the talk key's words in the change box, the
/// answer check once per draft the model made, Show in My Language, the handoff to Mail with
/// one at a time for the window, the requests that the window's close ends, the source chips
/// and the deadline mark.
///
/// A fake model answers by the kind of request, a fake store keeps the versions, and a fake
/// Mail never sends an Apple Event. Made up people at .example addresses, nothing from the
/// synthetic set.
@MainActor
struct ProjectsEmailModelTests {
    typealias Person = DraftCheckInput.Person

    /// Monday 19 October 2026 at noon UTC.
    nonisolated static let today = Date(timeIntervalSince1970: 1_792_411_200)
    nonisolated static let id = "lamps-2@harbor.example"
    static let mei = Person(name: "Mei Tan", address: "mei@harbor.example")
    static let kai = Person(name: "Kai Moss", address: "kai@kiln.example")
    static let me = Person(name: "Lin", address: "me@studio.example")
    static let emailText = "Hi Lin,\n\nCould you confirm the lamp order by Friday? Please also send the floor plan.\n\nMei"
    static let draft = "Hi Mei,\n\nThe lamp order is [to confirm: lamp order]. I will send the floor plan today.\n\nLin"
    static let file = TextChunker.Chunk(
        file: URL(fileURLWithPath: "/Projects/Harbor/lamps.pdf"), page: 3, modified: today,
        heading: "Lamps", text: "Twelve brass lamps, delivery in week 47.")

    static func explanation(draft: String? = draft, flags: [DraftCheck.Flag] = [], recipients: [Person] = [mei]) -> Explanation {
        let check = DraftCheckInput(
            draft: "", language: .en, recipients: recipients, projectPeople: [mei], own: [me],
            incomingText: emailText, sourceTexts: [file.text], questionsForUser: ["Which lamp order?"], today: today)
        return Explanation(
            messageID: id, project: UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A11"), language: .en, today: today,
            reply: .reply(.en),
            warnings: [ExplainPrompt.Finding(warning: .link, place: .email)],
            modelWarnings: [],
            points: [Explanation.Point(text: "Mei asks you to confirm the lamp order by Friday, 23 October.", sources: ["this email", "F1"], flags: [])],
            questions: ["Which lamp order?"],
            draft: .checked(DraftCheck.Result(draft: draft, language: .en, flags: flags, outsideRecipients: recipients.filter { $0 != mei }.map(\.address))),
            draftCheck: check,
            sources: ["this email": .message(id), "F1": .file(file), "T1": .message("lamps-1@harbor.example"), "M1": .message("gone@harbor.example")],
            removed: [:], problems: [], unknownSources: [])
    }

    /// The model, the store of versions, the clipboard and Mail, all fakes.
    final class Fakes: Sendable {
        nonisolated struct State: Sendable {
            var revisions: [String] = []
            var translations: [String] = []
            var checks: [String] = []
            var prompts: [String] = []
            var versions: [MailStore.DraftVersion] = []
            var savesVersions = true
            var copies: [String] = []
            var replies: [Bool] = []
            /// The checks of Mail's handle before a reply, true for a reply to all.
            var referenceChecks: [Bool] = []
            var broughtForward = 0
            var mailIsRunning = true
            /// Whether Mail's reply waits until the test lets it go.
            var replyWaits = false
            /// Whether Mail's reply waits for `replyRelease`, also once its task is
            /// cancelled, as an event already sent to Mail does.
            var replyHolds = false
            var replyRelease: CheckedContinuation<Void, Never>?
            var replyStarted = false
            /// The requests that ran as the user's.
            var userRequests = 0
            /// Whether a request of the user waits until the test lets it go, as one waits
            /// for its turn at the model.
            var requestWaits = false
            /// Whether the removal of a version waits until the test lets it go.
            var removeWaits = false
        }

        let state = Mutex(State())

        nonisolated func update(_ change: (inout State) -> Void) {
            state.withLock { change(&$0) }
        }

        nonisolated var value: State {
            state.withLock { $0 }
        }

        /// Answers by the kind of request: the answer check, a translation, or a revision.
        nonisolated func run(_ request: ProjectsModelRequest) throws -> String {
            try state.withLock { state in
                state.prompts.append(request.prompt)
                if request.prompt.contains("<questions>") {
                    guard !state.checks.isEmpty else { throw RewriteError.notLoaded }
                    return state.checks.removeFirst()
                }
                if request.prompt.contains("from English into Chinese") {
                    guard !state.translations.isEmpty else { throw RewriteError.notLoaded }
                    return state.translations.removeFirst()
                }
                guard !state.revisions.isEmpty else { throw RewriteError.notLoaded }
                return state.revisions.removeFirst()
            }
        }

        nonisolated func save(_ version: ReviseService.Version) {
            state.withLock { state in
                guard state.savesVersions else { return }
                state.versions.append(MailStore.DraftVersion(number: (state.versions.last?.number ?? 0) + 1, made: ProjectsEmailModelTests.today, version: version))
            }
        }

        var bridge: MailBridge {
            MailBridge(
                isRunning: { [self] in value.mailIsRunning },
                permission: { _ in .allowed },
                lastPermission: { nil },
                accounts: { [] },
                mailboxes: { [] },
                count: { _ in 0 },
                listing: { _, _ in [] },
                headers: { _ in "" },
                source: { _ in "" },
                attachments: { _ in [] },
                mailbox: { _ in .inbox },
                selection: { [] },
                reply: { [self] _, all in
                    update {
                        $0.replies.append(all)
                        $0.replyStarted = true
                    }
                    if value.replyHolds {
                        await withCheckedContinuation { continuation in
                            update { $0.replyRelease = continuation }
                        }
                    }
                    while value.replyWaits {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
            )
        }
    }

    let fakes = Fakes()

    private func model(
        explanation: @escaping () -> Explanation? = { ProjectsEmailModelTests.explanation() },
        userLanguage: ProjectsLanguage = .en,
        reference: MailMessageRef? = MailMessageRef(id: 4, mailbox: .inbox),
        referenceFailure: MailBridgeError? = nil,
        handoffs: ProjectsEmailModel.Handoffs = ProjectsEmailModel.Handoffs()
    ) -> ProjectsEmailModel {
        let fakes = fakes
        return ProjectsEmailModel(messageID: Self.id, actions: ProjectsEmailModel.Actions(
            explanation: { _ in explanation() },
            versions: { _ in fakes.value.versions },
            removeNewestVersion: { _ in
                while fakes.value.removeWaits {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return fakes.state.withLock { state in
                    guard !state.versions.isEmpty else { return false }
                    state.versions.removeLast()
                    return true
                }
            },
            reviseContext: { explanation in
                guard let check = explanation.draftCheck else { return nil }
                return ReviseService.Context(
                    messageID: explanation.messageID, emailText: Self.emailText, language: .en, userLanguage: userLanguage,
                    ownName: "Lin", recipients: check.recipients, projectPeople: check.projectPeople, own: check.own,
                    incomingText: check.incomingText, sourceTexts: check.sourceTexts, today: Self.today, timeZone: TimeZone(identifier: "UTC")!)
            },
            reviseService: { _ in
                ReviseService(run: { try fakes.run($0) }, countTokens: { $0.count }, save: { fakes.save($0) })
            },
            userRequest: { request in
                fakes.update { $0.userRequests += 1 }
                while fakes.value.requestWaits {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try await request()
            },
            email: { id in
                guard id == Self.id || id == "lamps-1@harbor.example" else { return nil }
                return ExplainService.Email(
                    messageID: id, date: Self.today.addingTimeInterval(-86_400 * 3),
                    sender: ExplainPrompt.Person(name: "Mei Tan", address: "mei@harbor.example"),
                    text: id == Self.id ? Self.emailText : "The lamps are ordered.", visibleText: "")
            },
            mailReference: { _, all in
                fakes.update { $0.referenceChecks.append(all) }
                if let referenceFailure { throw referenceFailure }
                return reference
            },
            handoff: ReplyHandoff(
                copy: { text in
                    fakes.update { $0.copies.append(text) }
                    return true
                },
                mail: fakes.bridge,
                isOrraActive: { true },
                bringMailToFront: { fakes.update { $0.broughtForward += 1 } }
            ),
            userLanguage: userLanguage,
            now: { Self.today }
        ), handoffs: handoffs)
    }

    /// The model's answer check for the two questions of the email.
    static let bothAnswered = #"to_confirm", "quote": "The lamp order is [to confirm: lamp order]."}, "2": {"status": "answered", "quote": "I will send the floor plan"}}"#

    // MARK: Loading

    @Test func theDraftShowsAndKeepsTheUsersEditsUntilTheExplanationChanges() async {
        var current: Explanation? = Self.explanation()
        let model = model(explanation: { current })
        await model.load()
        #expect(model.text == Self.draft)
        #expect(!model.isEdited)
        #expect(model.hasDraft)
        model.text = Self.draft + "\nP.S. See you Friday."
        await model.load()
        #expect(model.isEdited)
        #expect(model.text.hasSuffix("See you Friday."))

        // Explained again: the new draft replaces the edits.
        current = Self.explanation(draft: "Hi Mei,\n\nNoted.\n\nLin")
        await model.load()
        #expect(model.text == "Hi Mei,\n\nNoted.\n\nLin")
        // Moved to another project: the explanation and its draft are gone.
        current = nil
        await model.load()
        #expect(model.explanation == nil)
        #expect(!model.hasDraft)
        #expect(model.text.isEmpty)
    }

    @Test func theSourcesNameThisEmailEarlierMailAndFiles() async {
        let model = model()
        await model.load()
        #expect(model.sources["this email"] == .thisEmail)
        #expect(model.sources["F1"] == .file(Self.file))
        #expect(model.sources["T1"] == .mail(messageID: "lamps-1@harbor.example", sender: "Mei Tan", date: Self.today.addingTimeInterval(-86_400 * 3)))
        #expect(model.sources["M1"] == .mail(messageID: "gone@harbor.example", sender: nil, date: nil))
        #expect(model.emailText == Self.emailText)

        #expect(ProjectsWindowText.source(.thisEmail) == "This email")
        #expect(ProjectsWindowText.source(.file(Self.file)) == "lamps.pdf, page 3")
        var word = Self.file
        word.page = nil
        #expect(ProjectsWindowText.source(.file(word)) == "lamps.pdf")
        #expect(ProjectsWindowText.source(.mail(messageID: "gone@harbor.example", sender: nil, date: nil)) == "An earlier email")
        #expect(ProjectsWindowText.source(model.sources["T1"]!).hasPrefix("Mei Tan, "))
        #expect(ProjectsEmailArea.SourceChip.isGone(.mail(messageID: "gone@harbor.example", sender: nil, date: nil)))
        #expect(!ProjectsEmailArea.SourceChip.isGone(.thisEmail))
    }

    // MARK: Changes

    @Test func aChangeMakesASavedVersionThatUndoTakesBack() async throws {
        let model = model()
        await model.load()
        let changed = "Hi Mei,\n\nThe lamp order is [to confirm: lamp order]. I will send the floor plan on Monday.\n\nLin"
        fakes.update {
            $0.revisions = [changed]
            $0.checks = [Self.bothAnswered]
        }
        model.instruction = "  Say Monday  "
        await model.applyInstruction()
        #expect(model.text == changed)
        #expect(model.instruction.isEmpty)
        #expect(model.changeNote == nil)
        #expect(model.versions.map(\.number) == [1])
        #expect(model.versions.first?.version.change == .instruction("Say Monday"))
        // The prompt held the draft and the user's words.
        let prompt = try #require(fakes.value.prompts.first)
        #expect(prompt.contains(Self.draft))
        #expect(prompt.contains("Say Monday"))
        // The change is highlighted.
        let change = try #require(model.lastChange)
        #expect(change.segments.filter { $0.kind == .removed }.map(\.text) == ["today"])
        #expect(change.segments.filter { $0.kind == .added }.map(\.text) == ["on Monday"])
        // The answer check ran for the new version.
        #expect(model.currentAnswers?.asked == 2)
        #expect(model.currentAnswers?.answered == 1)

        await model.undo()
        #expect(model.versions.isEmpty)
        #expect(model.text == Self.draft)
        #expect(model.lastChange == nil)
        // Nothing left to undo.
        await model.undo()
        #expect(model.text == Self.draft)
    }

    /// A change starts from the text in the editor, and Undo puts that text back.
    @Test func aChangeStartsFromTheUsersEdits() async throws {
        let model = model()
        await model.load()
        let edited = Self.draft.replacingOccurrences(of: "today", with: "tonight")
        model.text = edited
        let warmer = "Hi Mei,\n\nThanks so much. The lamp order is [to confirm: lamp order]. I will send the floor plan tonight.\n\nLin"
        fakes.update {
            $0.revisions = [warmer]
            $0.checks = [Self.bothAnswered]
        }
        await model.makeChange(.tone(.warm))
        #expect(model.text == warmer)
        #expect(fakes.value.prompts.first?.contains("tonight") == true)
        #expect(model.lastChange?.segments.filter { $0.kind == .added }.map(\.text) == ["Thanks so much. "])
        await model.undo()
        #expect(model.text == edited)
    }

    @Test func aVersionInAnotherLanguageLeavesTheDraftAsItWas() async {
        let model = model()
        await model.load()
        fakes.update { $0.revisions = ["梅女士你好，\n\n灯具订单待确认，平面图今天发给你。\n\n林"] }
        await model.makeChange(.instruction("Shorter"))
        #expect(model.changeNote == .heldBack)
        #expect(model.text == Self.draft)
        #expect(model.versions.isEmpty)
        #expect(fakes.value.versions.isEmpty)
        #expect(ProjectsWindowText.note(.heldBack, for: .change) == "The new version came back in another language, so the draft stays as it was.")
    }

    /// A version the store did not keep, such as after the email was explained again, never
    /// lands on the draft.
    @Test func aVersionTheStoreDidNotKeepIsDropped() async {
        let model = model()
        await model.load()
        fakes.update {
            $0.revisions = ["Hi Mei,\n\nNoted, [to confirm: lamp order].\n\nLin"]
            $0.savesVersions = false
        }
        await model.makeChange(.tone(.firm))
        #expect(model.changeNote == .notKept)
        #expect(model.text == Self.draft)
        #expect(model.versions.isEmpty)
    }

    @Test func aFailedChangeSaysWhy() async {
        let model = model()
        await model.load()
        // The fake model has no answer left, as when the model is not on this Mac.
        await model.makeChange(.tone(.formal))
        #expect(model.changeNote == .noModel)
        #expect(model.changing == nil)
        #expect(model.text == Self.draft)
        #expect(ProjectsEmailModel.note(ReviseService.Failure.cutShort) == .noAnswer)
        #expect(ProjectsEmailModel.note(ReviseService.Failure.tooLong) == .tooLong)
        #expect(ProjectsEmailModel.note(RewriteError.promptTooLong) == .tooLong)
        #expect(ProjectsEmailModel.note(ProjectsRuntime.Failure.windowClosed) == .noModel)
        #expect(ProjectsEmailModel.note(ReviseService.Failure.emptyDraft) == .emptyDraft)
        #expect(ProjectsEmailModel.note(CocoaError(.fileNoSuchFile)) == .other)
    }

    /// The new tone left a placeholder out, which the view names.
    @Test func aToneThatDropsAPlaceholderSaysSo() async {
        let model = model()
        await model.load()
        fakes.update {
            $0.revisions = ["Dear Mei,\n\nPlease confirm the lamp order. I will send the floor plan today.\n\nKind regards,\nLin"]
            $0.checks = [Self.bothAnswered]
        }
        await model.makeChange(.tone(.formal))
        #expect(model.versions.last?.version.droppedPlaceholders == ["[to confirm: lamp order]"])
        #expect(ProjectsWindowText.dropped(["[to confirm: lamp order]"], tone: true) == "The new tone left out [to confirm: lamp order]. Put it back before you send.")
    }

    // MARK: The talk key

    /// Decision 13: the talk key's words go into the change box and change the draft at
    /// once, as Change Draft would.
    @Test func theTalkKeysWordsChangeTheDraftAtOnce() async throws {
        let model = model()
        await model.load()
        let changed = "Hi Mei,\n\nThe lamp order is [to confirm: lamp order]. I will send the floor plan on Monday.\n\nLin"
        fakes.update {
            $0.revisions = [changed]
            $0.checks = [Self.bothAnswered]
        }
        #expect(model.takeDictation("Say Monday.", revises: true))
        #expect(model.instruction == "Say Monday.")
        try await waitUntil { !model.isWorking }
        #expect(model.text == changed)
        #expect(model.instruction.isEmpty)
        #expect(model.changeNote == nil)
        #expect(model.versions.map(\.version.change) == [.instruction("Say Monday.")])
        #expect(fakes.value.prompts.first?.contains("Say Monday.") == true)
        // The answer check ran for the new version, as after a click.
        #expect(model.currentAnswers?.asked == 2)
    }

    /// With the change after a dictation off, the words wait in the box after what it holds,
    /// spaced as the language needs, and nothing asks the model.
    @Test func withTheSettingOffTheWordsWaitInTheBox() async {
        let model = model()
        await model.load()
        model.instruction = "Shorter."
        #expect(model.takeDictation("Keep the price.", revises: false))
        #expect(model.instruction == "Shorter. Keep the price.")
        model.instruction = "更正式一点，"
        #expect(model.takeDictation("价格不变。", revises: false))
        #expect(model.instruction == "更正式一点，价格不变。")
        model.instruction = "Shorter\n"
        #expect(model.takeDictation("Keep the price.", revises: false))
        #expect(model.instruction == "Shorter\nKeep the price.")
        #expect(!model.isWorking)
        #expect(fakes.value.prompts.isEmpty)
        #expect(model.versions.isEmpty)
    }

    /// Without a draft to change, or without words, the box takes nothing, so the dictation
    /// is pasted as in any app.
    @Test func theBoxTakesNoWordsWithoutADraft() async {
        let none = model(explanation: { Self.explanation(draft: nil) })
        await none.load()
        #expect(!none.takeDictation("Shorter.", revises: true))
        #expect(none.instruction.isEmpty)
        let model = model()
        await model.load()
        #expect(!model.takeDictation(" \n", revises: true))
        #expect(model.instruction.isEmpty)
        #expect(!model.isWorking)
    }

    /// While a change runs, the box stays open, so it keeps the focus. Words said meanwhile
    /// change the draft once it ends, and the change that ends takes away only its own. The
    /// answer check then runs once, for the newest version.
    @Test func wordsSaidWhileAChangeRunsChangeTheDraftNext() async throws {
        let model = model()
        await model.load()
        let firmer = "Hi Mei,\n\nPlease confirm the lamp order: [to confirm: lamp order]. I will send the floor plan today.\n\nLin"
        let priced = "Hi Mei,\n\nPlease confirm the lamp order: [to confirm: lamp order]. The price stays. I will send the floor plan today.\n\nLin"
        fakes.update {
            $0.revisions = [firmer, priced]
            $0.checks = [Self.bothAnswered]
            $0.requestWaits = true
        }
        model.instruction = "Firmer."
        model.perform { await $0.applyInstruction() }
        try await waitUntil { model.isBusy }
        #expect(model.takeDictation("Keep the price.", revises: true))
        #expect(model.instruction == "Firmer. Keep the price.")
        fakes.update { $0.requestWaits = false }
        try await waitUntil { !model.isWorking }
        #expect(model.versions.map(\.version.change) == [.instruction("Firmer."), .instruction("Keep the price.")])
        #expect(model.text == priced)
        #expect(model.instruction.isEmpty)
        #expect(fakes.value.prompts.filter { $0.contains("<questions>") }.count == 1)
        #expect(model.currentAnswers?.asked == 2)
        // Words the user changed meanwhile all stay.
        #expect(ProjectsEmailModel.remainder(of: "Firm, and keep the price.", after: "Firmer.") == "Firm, and keep the price.")
        #expect(ProjectsEmailModel.remainder(of: "  Firmer.  ", after: "Firmer.") == "")
    }

    /// Words said while an undo runs change the draft once it is done, from the text it put
    /// back.
    @Test func wordsSaidWhileAnUndoRunsChangeTheDraftAfterIt() async throws {
        let model = model()
        await model.load()
        let firmer = "Hi Mei,\n\nPlease confirm the lamp order: [to confirm: lamp order]. I will send the floor plan today.\n\nLin"
        let monday = "Hi Mei,\n\nThe lamp order is [to confirm: lamp order]. I will send the floor plan on Monday.\n\nLin"
        fakes.update {
            $0.revisions = [firmer, monday]
            $0.checks = [Self.bothAnswered, Self.bothAnswered]
        }
        await model.makeChange(.tone(.firm))
        #expect(model.text == firmer)
        fakes.update { $0.removeWaits = true }
        model.perform { await $0.undo() }
        try await waitUntil { model.isBusy }
        #expect(model.takeDictation("Say Monday.", revises: true))
        fakes.update { $0.removeWaits = false }
        try await waitUntil { !model.isWorking }
        #expect(model.versions.map(\.version.change) == [.instruction("Say Monday.")])
        #expect(model.text == monday)
        #expect(fakes.value.prompts.last(where: { !$0.contains("<questions>") })?.contains(Self.draft) == true)
        #expect(model.instruction.isEmpty)
    }

    /// Words said while a change runs wait in the box with the setting off, and when the
    /// change gives no new draft, so a failed change is never tried again on its own.
    @Test func wordsSaidWhileAChangeRunsWaitWithTheSettingOffOrAfterAFailure() async throws {
        let model = model()
        await model.load()
        let firmer = "Hi Mei,\n\nPlease confirm the lamp order: [to confirm: lamp order]. I will send the floor plan today.\n\nLin"
        fakes.update {
            $0.revisions = [firmer]
            $0.checks = [Self.bothAnswered]
            $0.requestWaits = true
        }
        model.instruction = "Firmer."
        model.perform { await $0.applyInstruction() }
        try await waitUntil { model.isBusy }
        #expect(model.takeDictation("Keep the price.", revises: false))
        fakes.update { $0.requestWaits = false }
        try await waitUntil { !model.isWorking }
        #expect(model.versions.map(\.version.change) == [.instruction("Firmer.")])
        #expect(model.instruction == "Keep the price.")

        // The fake model has no answer left, so the next change fails.
        fakes.update { $0.requestWaits = true }
        model.perform { await $0.applyInstruction() }
        try await waitUntil { model.isBusy }
        #expect(model.takeDictation("Say Monday.", revises: true))
        fakes.update { $0.requestWaits = false }
        try await waitUntil { !model.isWorking }
        #expect(model.changeNote == .noModel)
        #expect(model.versions.count == 1)
        #expect(model.text == firmer)
        #expect(model.instruction == "Keep the price. Say Monday.")
        #expect(fakes.value.userRequests == 3)
    }

    // MARK: Checks

    /// Decision 9: one check on its own for each draft the model made in this window, after
    /// the explanation and after each version, and else only on a click.
    @Test func theAnswerCheckRunsOnceForEachDraftTheModelMade() async {
        let model = model()
        // A draft made in an earlier window: reading it asks the model nothing.
        await model.load()
        #expect(model.currentAnswers == nil)
        #expect(fakes.value.prompts.isEmpty)

        // Explained in this window: one check, as the user's request.
        fakes.update { $0.checks = [Self.bothAnswered] }
        await model.explained()
        #expect(model.currentAnswers?.asked == 2)
        #expect(fakes.value.userRequests == 1)
        #expect(ProjectsWindowText.answers(asked: 2, answered: 2) == "They asked 2 things, your draft answers 2.")
        #expect(ProjectsWindowText.answers(asked: 1, answered: 0) == "They asked 1 thing, your draft answers 0.")
        // Read again, or explained again with the same draft: no new check.
        await model.load()
        await model.explained()
        #expect(fakes.value.prompts.count == 1)

        // After an edit, only on a click.
        model.text += "\nThanks."
        #expect(model.currentAnswers == nil)
        await model.explained()
        #expect(fakes.value.prompts.count == 1)
        await model.checkAnswers()
        #expect(model.answersNote == .noModel)
        #expect(fakes.value.prompts.count == 2)
    }

    /// The requests of the email view end when the window closes, and save nothing.
    @Test func closingTheWindowEndsTheRequests() async throws {
        let model = model()
        await model.load()
        fakes.update { $0.replyWaits = true }
        // A request that waits in Mail's reply, as a model request waits for its slice.
        model.perform { await $0.openReply(all: false) }
        #expect(model.isWorking)
        try await waitUntil { fakes.value.replyStarted }
        model.cancelWork()
        #expect(!model.isWorking)
        try await waitUntil { !model.isHandingOff }
        // Cancelled before Mail answered: the draft is on the clipboard and nothing else.
        #expect(model.handoffNote == .outcome(.copied))
        #expect(fakes.value.broughtForward == 0)
    }

    /// The window closes once Mail was asked for the reply, which nothing can call back.
    /// Mail opens the reply window, but the draft is not copied again and Mail does not
    /// come to the front.
    @Test func closingTheWindowWhileMailMakesTheReplyLeavesTheClipboardAndMail() async throws {
        let model = model()
        await model.load()
        fakes.update { $0.replyHolds = true }
        model.perform { await $0.openReply(all: false) }
        try await waitUntil { fakes.value.replyRelease != nil }
        model.cancelWork()
        fakes.state.withLock { state in
            state.replyRelease?.resume()
            state.replyRelease = nil
        }
        try await waitUntil { !model.isHandingOff }
        #expect(model.handoffNote == .outcome(.replyOpened))
        #expect(fakes.value.copies == [Self.draft])
        #expect(fakes.value.broughtForward == 0)
    }

    @Test func theFlagsFollowTheTextInTheEditor() async {
        let flags: [DraftCheck.Flag] = [
            .output(OutputChecks.Finding(kind: .amountWithoutSource, text: "¥58,600")),
            .decidesQuestion(placeholders: 0, questions: 1),
        ]
        let model = model(explanation: { Self.explanation(draft: Self.draft + "\nThe total is ¥58,600.", flags: flags, recipients: [Self.mei, Self.kai]) })
        await model.load()
        #expect(model.flags == flags)
        #expect(model.outsideRecipients == ["kai@kiln.example"])
        #expect(model.offersReplyAll)
        model.text = Self.draft
        #expect(model.flags == [.decidesQuestion(placeholders: 0, questions: 1)])
        #expect(ProjectsWindowText.flag(flags[0]) == "No source holds this amount: ¥58,600")
        #expect(ProjectsWindowText.outsideRecipients(model.outsideRecipients) == "A reply to all reaches people outside the project: kai@kiln.example")
    }

    // MARK: Translation

    @Test func showInMyLanguageTranslatesEachVersion() async {
        let model = model(userLanguage: .zh)
        await model.load()
        #expect(model.offersTranslation)
        #expect(ProjectsWindowText.showTranslation(in: model.translationLanguage) == "Show in Chinese")
        fakes.update {
            $0.translations = ["梅女士你好，\n\n灯具订单[待确认：灯具订单]。平面图今天发给你。\n\n林", "梅女士你好，\n\n平面图周一发给你。\n\n林"]
            $0.revisions = ["Hi Mei,\n\nThe lamp order is [to confirm: lamp order]. I will send the floor plan on Monday.\n\nLin"]
            $0.checks = [Self.bothAnswered]
        }
        await model.showTranslation(true)
        #expect(model.currentTranslation?.text.hasPrefix("梅女士你好") == true)
        // Turned off and on again: no new request for the same draft.
        await model.showTranslation(false)
        await model.showTranslation(true)
        #expect(fakes.value.prompts.count == 1)

        await model.makeChange(.instruction("Say Monday"))
        #expect(model.currentTranslation?.text.contains("周一") == true)

        // An edit leaves the translation behind until the user asks again.
        model.text += "\nThanks."
        #expect(model.currentTranslation == nil)
        #expect(model.translation != nil)

        let english = self.model(userLanguage: .en)
        await english.load()
        #expect(!english.offersTranslation)
        // A Japanese or Spanish interface reads explanations in English (decision 8), so a
        // Chinese draft shows in English.
        let japanese = self.model(explanation: { Self.chineseExplanation() }, userLanguage: .other)
        await japanese.load()
        #expect(japanese.offersTranslation)
        #expect(ProjectsWindowText.showTranslation(in: japanese.translationLanguage) == "Show in English")
    }

    /// The explanation of a Chinese email, with a Chinese draft.
    static func chineseExplanation() -> Explanation {
        var explanation = explanation(draft: "梅女士你好，\n\n灯具订单[待确认：灯具订单]。\n\n林")
        explanation.reply = .reply(.zh)
        explanation.language = .zh
        return explanation
    }

    // MARK: Handoff

    @Test func openReplyHandsTheDraftInTheEditorToMail() async {
        let model = model()
        await model.load()
        model.text = Self.draft + "\nLin"
        await model.openReply(all: false)
        #expect(model.handoffNote == .outcome(.replyOpened))
        #expect(fakes.value.replies == [false])
        #expect(fakes.value.copies == [model.text, model.text])
        #expect(fakes.value.broughtForward == 1)
        #expect(ProjectsWindowText.handoff(.outcome(.replyOpened)) == "Mail opened the reply, and the draft is on the clipboard. Press ⌘V in the reply window.")

        await model.openReply(all: true)
        #expect(fakes.value.replies == [false, true])

        model.copy()
        #expect(model.handoffNote == .outcome(.copied))
        #expect(fakes.value.replies.count == 2)
    }

    /// Without Mail's handle of the email in this Mail session, the draft is only copied.
    /// While Mail does not run, which lets the handles go, the note says so.
    @Test func openReplyWithoutMailsHandleOnlyCopies() async {
        let model = model(reference: nil)
        await model.load()
        await model.openReply(all: false)
        #expect(model.handoffNote == .messageNotFound)
        #expect(fakes.value.copies == [Self.draft])
        #expect(fakes.value.replies.isEmpty)
        #expect(fakes.value.broughtForward == 0)
        #expect(ProjectsWindowText.handoff(.messageNotFound) == "Projects cannot find this email in Mail now, so the draft is only on the clipboard. Reply to it in Mail and press ⌘V.")

        fakes.update { $0.mailIsRunning = false }
        await model.openReply(all: false)
        #expect(model.handoffNote == .outcome(.copiedMailNotRunning))
        #expect(fakes.value.copies == [Self.draft, Self.draft])

        model.text = "  "
        await model.openReply(all: false)
        #expect(model.handoffNote == .outcome(.emptyDraft))
    }

    /// Mail's handle is checked for the kind of reply before Mail is asked. When Mail cannot
    /// say whether its message is this email, the draft is only copied and the note says
    /// what Mail answered. Mail was not asked to reply, so a timeout does not say that the
    /// reply may still open.
    @Test func openReplyChecksMailsHandleFirst() async {
        let model = model()
        await model.load()
        await model.openReply(all: true)
        #expect(fakes.value.referenceChecks == [true])
        #expect(fakes.value.replies == [true])

        let failures: [(MailBridgeError, ReplyHandoff.Outcome)] = [
            (.denied, .copiedReplyFailed(.denied)),
            (.mailNotRunning, .copiedMailNotRunning),
            (.timedOut, .copiedReplyFailed(.failed(code: -1712))),
        ]
        for (failure, note) in failures {
            let failing = self.model(referenceFailure: failure)
            await failing.load()
            await failing.openReply(all: false)
            #expect(failing.handoffNote == .outcome(note))
            #expect(!failing.isHandingOff)
        }
        #expect(fakes.value.referenceChecks == [true, false, false, false])
        #expect(fakes.value.replies == [true])
        #expect(fakes.value.copies == Array(repeating: Self.draft, count: 5))
        #expect(fakes.value.broughtForward == 1)
        #expect(ProjectsWindowText.handoff(.outcome(.copiedReplyFailed(.failed(code: -1712)))) == "Mail did not open the reply. The draft is on the clipboard.")
    }

    /// One handoff at a time for the whole window: while Mail opens the reply to one email,
    /// another email's Open Reply and Copy do nothing, so the clipboard keeps the draft of
    /// the reply window Mail brings forward.
    @Test func oneHandoffRunsAtATimeForTheWindow() async throws {
        let handoffs = ProjectsEmailModel.Handoffs()
        let first = model(handoffs: handoffs)
        let second = model(handoffs: handoffs)
        await first.load()
        await second.load()
        first.text = "First draft"
        second.text = "Second draft"
        fakes.update { $0.replyWaits = true }
        let running = Task { await first.openReply(all: false) }
        try await waitUntil { fakes.value.replyStarted }
        #expect(second.isHandingOff)
        await second.openReply(all: true)
        second.copy()
        #expect(second.handoffNote == nil)
        fakes.update { $0.replyWaits = false }
        await running.value
        #expect(!second.isHandingOff)
        #expect(fakes.value.replies == [false])
        #expect(fakes.value.copies == ["First draft", "First draft"])
        #expect(first.handoffNote == .outcome(.replyOpened))
    }

    // MARK: The deadline

    @Test func theDeadlineComesFromTheDatesThePointsNameAsOne() {
        func deadline(_ texts: String...) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return ProjectsEmailModel.deadline(in: texts, explainedOn: Self.today, now: Self.today, calendar: calendar)
        }
        func day(_ month: Int, _ day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        #expect(deadline("Mei asks you to confirm the lamp order by Friday, 23 October.") == day(10, 23))
        #expect(deadline("Payment is due on 30 Oct.") == day(10, 30))
        #expect(deadline("请在10月24日（周六）前确认报价。") == day(10, 24))
        #expect(deadline("报价10月28日截止。") == day(10, 28))
        #expect(deadline("截止日期为11月2日。") == day(11, 2))
        #expect(deadline("Reply by 2 November at the latest, or 25 October.") == day(11, 2))
        // The earliest of several.
        #expect(deadline("Send the plan before 30 October.", "Confirm the colors by 26 October.") == day(10, 26))
        // A date without a deadline word, a past one, and one near 前后 are no deadlines.
        #expect(deadline("The lamps arrive on 22 November.") == nil)
        #expect(deadline("Sent by Mei on 28 October.") == nil)
        #expect(deadline("Please reply by 12 October.") == nil)
        #expect(deadline("交期在11月22日前后。") == nil)
        // Today counts.
        #expect(deadline("Due 19 October.") == day(10, 19))
    }

    @Test func theDeadlineMarkSaysTodayTheWeekdayOrTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(ProjectsWindowText.deadline(Self.today, now: Self.today, calendar: calendar) == "Deadline today")
        let friday = try #require(ProjectsWindowText.deadline(Self.today.addingTimeInterval(86_400 * 4), now: Self.today, calendar: calendar))
        #expect(friday.hasPrefix("Deadline "))
        #expect(!friday.contains("today"))
        let later = try #require(ProjectsWindowText.deadline(Self.today.addingTimeInterval(86_400 * 20), now: Self.today, calendar: calendar))
        #expect(later != friday)
        #expect(later.hasPrefix("Deadline "))
        // A day that has passed, such as in a window left open past midnight, has no mark.
        #expect(ProjectsWindowText.deadline(Self.today.addingTimeInterval(-86_400), now: Self.today, calendar: calendar) == nil)
    }

    /// Waits for a condition, polling, for at most a few seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
