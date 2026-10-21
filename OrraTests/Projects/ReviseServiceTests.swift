import Foundation
import Synchronization
import Testing
@testable import Orra

/// The revise service with a fake model and a fake store. The cases are written for these
/// tests, with invented people and companies at .example addresses. Today is pinned to
/// Sunday 18 October 2026, and tokens are counted as characters.
struct ReviseServiceTests {
    typealias Person = DraftCheckInput.Person

    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let today = ISO8601DateFormatter().date(from: "2026-10-18T10:00:00+08:00")!
    static let bai = Person(name: "Bai Lu", address: "bai.lu@lumenhaus.example")
    static let iris = Person(name: "Iris Fang", address: "iris.fang@printworks.example")
    static let owen = Person(name: "Owen Pike", address: "owen@pike-build.example")
    static let nadia = Person(name: "Nadia Frost", address: "nadia@frostline.example")
    static let email = "Hi Bai Lu,\n\nWill the revised proof reach you by Wednesday? Please also confirm the paper stock.\n\nIris"
    static let draft = "Hi Iris,\n\nThanks for the proof. It should reach us by Wednesday. The paper stock is [to confirm: paper stock].\n\nBest,\nBai Lu"

    static func context(language: ProjectsLanguage = .en, userLanguage: ProjectsLanguage = .zh, to recipients: [Person] = [iris], email: String = email) -> ReviseService.Context {
        ReviseService.Context(
            messageID: "proof-3@printworks.example",
            emailText: email,
            language: language,
            userLanguage: userLanguage,
            ownName: "Bai Lu",
            recipients: recipients,
            projectPeople: [iris, owen],
            own: [bai],
            incomingText: email,
            sourceTexts: ["Quote v2: paper 120 g, 3,000 copies, total ¥18,400. Owen Pike checks the proofs."],
            today: today,
            timeZone: shanghai
        )
    }

    /// The model answers in turn with the answers it was given, and keeps the requests.
    /// Without answers left it throws `notLoaded`.
    final class FakeModel: Sendable {
        private let state: Mutex<(answers: [Result<String, RewriteError>], requests: [ProjectsModelRequest])>

        init(_ answers: [Result<String, RewriteError>]) {
            state = Mutex((answers, []))
        }

        convenience init(answering answers: String...) {
            self.init(answers.map { .success($0) })
        }

        func run(_ request: ProjectsModelRequest) throws -> String {
            try state.withLock { state in
                state.requests.append(request)
                guard !state.answers.isEmpty else { throw RewriteError.notLoaded }
                return try state.answers.removeFirst().get()
            }
        }

        var requests: [ProjectsModelRequest] {
            state.withLock { $0.requests }
        }
    }

    /// The versions saved.
    final class FakeStore: Sendable {
        private let versions = Mutex<[ReviseService.Version]>([])

        func save(_ version: ReviseService.Version) {
            versions.withLock { $0.append(version) }
        }

        var saved: [ReviseService.Version] {
            versions.withLock { $0 }
        }
    }

    private func service(_ model: FakeModel, _ store: FakeStore = FakeStore()) -> ReviseService {
        ReviseService(
            run: { try model.run($0) },
            countTokens: { $0.count },
            save: { store.save($0) }
        )
    }

    // MARK: Revision

    @Test func aRevisionRunsAsTheUsersRequestAndIsSaved() async throws {
        let written = "Hi Iris,\n\nThanks for the proof. It should reach us by Thursday. The paper stock is [to confirm: paper stock].\n\nBest,\nBai Lu"
        let model = FakeModel(answering: written)
        let store = FakeStore()
        let version = try await service(model, store).revise(Self.draft, .instruction("Say Thursday"), flags: [], context: Self.context())
        #expect(version.draft == written)
        #expect(version.change == .instruction("Say Thursday"))
        #expect(version.messageID == "proof-3@printworks.example")
        #expect(version.check.removals.isEmpty)
        #expect(version.check.flags.isEmpty)
        #expect(store.saved == [version])

        let request = try #require(model.requests.first)
        #expect(model.requests.count == 1)
        #expect(request.priority == .user)
        #expect(request.prompt.contains("<draft>\n" + Self.draft + "\n</draft>\n\n<instruction>\nSay Thursday\n</instruction>"))
        #expect(request.prompt.hasSuffix(RevisePrompt.Revision.prefill(.en)))
        #expect(request.maximumTokens == RevisePrompt.answerTokens(forDraftTokens: Self.draft.count + "Say Thursday".count))
    }

    /// The model's heading before the draft goes, as the prefill's echo.
    @Test func theAnswerIsReadWithItsPrefill() async throws {
        let model = FakeModel(answering: "New draft:\nHi Iris,\n\nThursday works.\n\nBai Lu")
        let version = try await service(model).revise(Self.draft, .tone(.warm), flags: [], context: Self.context())
        #expect(version.draft == "Hi Iris,\n\nThursday works.\n\nBai Lu")
        #expect(version.change == .tone(.warm))
        #expect(model.requests.first?.prompt.contains(RevisePrompt.Revision.instruction(for: .warm, language: .en)) == true)
    }

    /// A tone change gets the draft's placeholders back where the model put their marks.
    @Test func aToneKeepsThePlaceholders() async throws {
        let model = FakeModel(answering: "Dear Iris,\n\nThank you for the proof, which should reach us by Wednesday. The paper stock is [P1].\n\nKind regards,\nBai Lu")
        let version = try await service(model).revise(Self.draft, .tone(.formal), flags: [], context: Self.context())
        #expect(version.draft == "Dear Iris,\n\nThank you for the proof, which should reach us by Wednesday. The paper stock is [to confirm: paper stock].\n\nKind regards,\nBai Lu")
        #expect(model.requests.first?.prompt.contains("The paper stock is [P1].") == true)
        #expect(model.requests.first?.prompt.contains("<email>") == false)
        #expect(version.droppedPlaceholders.isEmpty)

        let dropping = FakeModel(answering: "Dear Iris,\n\nPlease confirm the paper stock.\n\nKind regards,\nBai Lu")
        let dropped = try await service(dropping).revise(Self.draft, .tone(.firm), flags: [], context: Self.context())
        #expect(dropped.droppedPlaceholders == ["[to confirm: paper stock]"])
        #expect(dropped.draft == "Dear Iris,\n\nPlease confirm the paper stock.\n\nKind regards,\nBai Lu")
    }

    /// An instruction may settle a placeholder. The version says which are gone, and
    /// DraftCheck's count of the first draft's questions is not used.
    @Test func aVersionSaysWhichPlaceholdersAreGone() async throws {
        let model = FakeModel(answering: "Hi Iris,\n\nThanks for the proof. It should reach us by Wednesday. We will use 150 g paper.\n\nBest,\nBai Lu")
        let version = try await service(model).revise(Self.draft, .instruction("Use 150 g"), flags: [], context: Self.context())
        #expect(version.droppedPlaceholders == ["[to confirm: paper stock]"])
        #expect(version.check.flags.isEmpty)

        // A placeholder a sentence held that the check took out is gone too.
        let claiming = FakeModel(answering: "Hi Iris,\n\nI have already forwarded the stock, [to confirm: paper stock].\n\nBai Lu")
        let checked = try await service(claiming).revise(Self.draft, .instruction("Shorter"), flags: [], context: Self.context())
        #expect(checked.check.removals.map(\.kind) == [.actionClaim])
        #expect(checked.droppedPlaceholders == ["[to confirm: paper stock]"])
    }

    /// Every new version goes through DraftCheck: links and action claims go, and so does
    /// project data the model added for someone outside the project.
    @Test func theCheckTakesOutWhatTheModelAdded() async throws {
        let written = "Hi Nadia,\n\nThe total is ¥18,400. I have already forwarded the proof. Details at https://pay.example/x.\n\nBai Lu"
        let model = FakeModel(answering: written)
        let store = FakeStore()
        let version = try await service(model, store).revise("Hi Nadia,\n\nThanks.\n\nBai Lu", .instruction("Say more"), flags: [], context: Self.context(to: [Self.nadia], email: "Hi, what did the print job cost? Nadia"))
        let draft = try #require(version.draft)
        #expect(!draft.contains("18,400"))
        #expect(!draft.contains("forwarded"))
        #expect(!draft.contains("pay.example"))
        #expect(Set(version.check.removals.map(\.kind)) == [.projectData, .actionClaim, .link])
        #expect(version.check.outsideRecipients == ["nadia@frostline.example"])
        #expect(store.saved == [version])
    }

    /// What the user typed into the draft and what the instruction gives stay, even for
    /// someone outside the project. Only an amount the model added goes.
    @Test func whatTheUserGaveStays() async throws {
        let before = "Hi Nadia,\n\nThe deposit is ¥12,000.\n\nBai Lu"
        let written = "Hi Nadia,\n\nThe deposit is ¥12,000 and the price is ¥15,500, so ¥27,500 in all.\n\nBai Lu"
        let model = FakeModel(answering: written)
        let version = try await service(model).revise(before, .instruction("Tell her the price is ¥15,500"), flags: [], context: Self.context(to: [Self.nadia], email: "Hi, what will it cost? Nadia"))
        #expect(version.draft == "Hi Nadia,\n\nThe deposit is ¥12,000 and the price is ¥15,500, so [project data removed] in all.\n\nBai Lu")
        #expect(version.check.removals.map(\.text) == ["¥27,500"])
        #expect(version.check.flags.isEmpty)
    }

    /// A revision to a sender whose domain imitates a known one (a23) is checked with the
    /// values of the first draft, whose email counts as holding nothing. The lookalike
    /// domain goes, and so does a value only the impostor's mail holds, while what the user
    /// typed into the draft or asked for stays.
    @Test func aRevisionToAnImitatingDomainKeepsWhatTheUserGave() async throws {
        let impostor = Person(name: "Iris Fang", address: "iris.fang@printw0rks.example")
        var context = Self.context(to: [impostor], email: "Hi Bai Lu, please pay into 6222 0000 0000 3333 from now on. Iris")
        context.incomingText = ""
        context.imitatingDomains = ["printw0rks.example"]
        let before = "Hi Iris,\n\nI will pay invoice INV-2026-118 to the account on file.\n\nBai Lu"
        let written = "Hi Iris,\n\nI will pay invoice INV-2026-118 of ¥5,800 to the account on file, not to 6222 0000 0000 3333 or iris.fang@printw0rks.example. My booking is R4T8WX.\n\nBai Lu"
        let version = try await service(FakeModel(answering: written)).revise(before, .instruction("Firmer. The invoice is ¥5,800 and my booking is R4T8WX"), flags: [], context: context)
        #expect(version.draft == "Hi Iris,\n\nI will pay invoice INV-2026-118 of ¥5,800 to the account on file, not to [project data removed] or [link removed]. My booking is R4T8WX.\n\nBai Lu")
        #expect(version.check.removals.map(\.kind) == [.link, .projectData])
    }

    /// An amount flagged in the draft before, such as a total the model worked out, stays
    /// flagged while the new version holds it, in whatever form. One the user typed was not
    /// flagged and stays unflagged, and one the instruction gives is the user's.
    @Test func anAmountFlaggedBeforeStaysFlagged() async throws {
        let before = "Hi Iris,\n\nThe deposit is ¥12,000 and the total is ¥27,500.\n\nBai Lu"
        let flagged = [DraftCheck.Flag.output(.init(kind: .amountWithoutSource, text: "¥27,500"))]
        let written = "Dear Iris,\n\nThe deposit is ¥12,000, and the total comes to 27,500 元. Thank you!\n\nBai Lu"
        let warm = try await service(FakeModel(answering: written)).revise(before, .tone(.warm), flags: flagged, context: Self.context())
        #expect(warm.check.flags == [.output(.init(kind: .amountWithoutSource, text: "27,500 元"))])

        let typed = try await service(FakeModel(answering: written)).revise(before, .tone(.warm), flags: [], context: Self.context())
        #expect(typed.check.flags.isEmpty)

        let given = try await service(FakeModel(answering: written)).revise(before, .instruction("Say the total is ¥27,500"), flags: flagged, context: Self.context())
        #expect(given.check.flags.isEmpty)

        let gone = try await service(FakeModel(answering: "Dear Iris,\n\nThe deposit is ¥12,000.\n\nBai Lu")).revise(before, .instruction("Leave out the total"), flags: flagged, context: Self.context())
        #expect(gone.check.flags.isEmpty)
    }

    /// A version in another language than the reply rule's is held back and not saved.
    @Test func aVersionInAnotherLanguageIsHeldBack() async throws {
        let model = FakeModel(answering: "Dear Ms Fang,\n\nThank you for the proof.\n\nBai Lu")
        let store = FakeStore()
        let version = try await service(model, store).revise("方经理您好，\n\n打样已收到，谢谢。\n\n白露", .tone(.formal), flags: [], context: Self.context(language: .zh))
        #expect(version.draft == nil)
        #expect(version.check.language == .en)
        #expect(store.saved.isEmpty)
    }

    @Test func aFailedOrEmptyAnswerSavesNothing() async {
        let store = FakeStore()
        let empty = service(FakeModel(answering: "New draft:\n\n"), store)
        await #expect(throws: ReviseService.Failure.emptyAnswer) {
            try await empty.revise(Self.draft, .instruction("Shorter"), flags: [], context: Self.context())
        }
        let failing = service(FakeModel([.failure(.notLoaded)]), store)
        await #expect(throws: RewriteError.notLoaded) {
            try await failing.revise(Self.draft, .instruction("Shorter"), flags: [], context: Self.context())
        }
        #expect(store.saved.isEmpty)
    }

    /// An answer as long as the model may write may lack its end, such as the signature,
    /// so it is neither saved nor shown.
    @Test func anAnswerCutShortSavesNothing() async throws {
        let store = FakeStore()
        let limit = RevisePrompt.answerTokens(forDraftTokens: Self.draft.count + "Longer".count)
        let model = FakeModel(answering: "Hi Iris,\n\n" + String(repeating: "a", count: limit))
        await #expect(throws: ReviseService.Failure.cutShort) {
            try await service(model, store).revise(Self.draft, .instruction("Longer"), flags: [], context: Self.context())
        }
        #expect(model.requests.first?.maximumTokens == limit)
        #expect(store.saved.isEmpty)

        let translating = FakeModel(answering: String(repeating: "译", count: RevisePrompt.answerTokens(forDraftTokens: Self.draft.count)))
        await #expect(throws: ReviseService.Failure.cutShort) {
            try await service(translating).translate(Self.draft, context: Self.context(userLanguage: .zh))
        }
    }

    /// Nothing reaches the model for a request that cannot work.
    @Test func inputsThatCannotWorkRunNothing() async {
        let model = FakeModel(answering: "unused")
        let revise = service(model)
        await #expect(throws: ReviseService.Failure.noDraftLanguage) {
            try await revise.revise(Self.draft, .instruction("Shorter"), flags: [], context: Self.context(language: .other))
        }
        await #expect(throws: ReviseService.Failure.emptyDraft) {
            try await revise.revise(" \n", .instruction("Shorter"), flags: [], context: Self.context())
        }
        // A draft made only of the prompt's tags is empty too.
        await #expect(throws: ReviseService.Failure.emptyDraft) {
            try await revise.revise("<draft>\n</draft>", .instruction("Shorter"), flags: [], context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.emptyInstruction) {
            try await revise.revise(Self.draft, .instruction("  "), flags: [], context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.tooLong) {
            try await revise.revise(String(repeating: "Thanks. ", count: 1_200), .instruction("Shorter"), flags: [], context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.tooLong) {
            try await revise.revise(Self.draft, .instruction(String(repeating: "a", count: RevisePrompt.instructionLimit + 1)), flags: [], context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.emptyDraft) {
            try await revise.translate("<draft></draft>", context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.emptyDraft) {
            try await revise.checkAnswers(of: "<draft></draft>", context: Self.context())
        }
        #expect(model.requests.isEmpty)
    }

    /// Cancelling the caller ends the request, and nothing is saved.
    @Test func cancellingTheCallerSavesNothing() async {
        let store = FakeStore()
        let started = AsyncStream<Void>.makeStream()
        let waiting = ReviseService(
            run: { _ in
                started.continuation.yield()
                try await Task.sleep(for: .seconds(60))
                return "Hi Iris"
            },
            countTokens: { $0.count },
            save: { store.save($0) }
        )
        let task = Task {
            try await waiting.revise(Self.draft, .instruction("Shorter"), flags: [], context: Self.context())
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.saved.isEmpty)
    }

    // MARK: Translation

    @Test func theDraftIsTranslatedIntoTheUsersLanguage() async throws {
        let translation = "方女士你好，\n\n谢谢你寄来的打样，周三前应该能到。纸张 [待确认：纸张]。\n\n白露"
        let model = FakeModel(answering: translation)
        let shown = try await service(model).translate(Self.draft, context: Self.context(userLanguage: .zh))
        #expect(shown == translation)
        let request = try #require(model.requests.first)
        #expect(request.priority == .user)
        #expect(request.prompt.contains("from English into Chinese"))
        #expect(request.prompt.hasSuffix(RevisePrompt.Translation.prefill(.zh)))
    }

    /// A draft in the user's own language needs no translation and no model call. Every
    /// interface but Chinese reads English.
    @Test func aDraftInTheUsersLanguageNeedsNoCall() async throws {
        let model = FakeModel(answering: "unused")
        #expect(try await service(model).translate(Self.draft, context: Self.context(userLanguage: .en)) == nil)
        #expect(try await service(model).translate(Self.draft, context: Self.context(userLanguage: .other)) == nil)
        #expect(model.requests.isEmpty)
    }

    /// Names kept in Chinese characters do not make an English translation Chinese.
    @Test func namesKeptAsTheyAreDoNotDecideTheLanguage() async throws {
        let draft = "唐总、许工：\n\n收到，谢谢。\n\n白露\n远帆家居"
        let translation = "Dear 唐总 and 许工,\n\nReceived, thank you.\n\n白露\n远帆家居"
        let model = FakeModel(answering: translation, draft)
        let translate = service(model)
        #expect(try await translate.translate(draft, context: Self.context(language: .zh, userLanguage: .en)) == translation)
        await #expect(throws: ReviseService.Failure.wrongLanguage) {
            try await translate.translate(draft, context: Self.context(language: .zh, userLanguage: .en))
        }
    }

    @Test func aTranslationInTheWrongLanguageIsRefused() async {
        let model = FakeModel(answering: "Hi Iris,\n\nThanks for the proof.\n\nBai Lu", "")
        let translate = service(model)
        await #expect(throws: ReviseService.Failure.wrongLanguage) {
            try await translate.translate(Self.draft, context: Self.context(userLanguage: .zh))
        }
        await #expect(throws: ReviseService.Failure.emptyAnswer) {
            try await translate.translate(Self.draft, context: Self.context(userLanguage: .zh))
        }
        await #expect(throws: ReviseService.Failure.noDraftLanguage) {
            try await translate.translate(Self.draft, context: Self.context(language: .other))
        }
    }

    // MARK: Answer check

    @Test func theCheckSaysWhichQuestionsTheDraftAnswers() async throws {
        let model = FakeModel(answering: #"answered", "quote": "It should reach us by Wednesday."}, "2": {"status": "to_confirm", "quote": "The paper stock is [to confirm: paper stock]."}}"#)
        let answers = try await service(model).checkAnswers(of: Self.draft, context: Self.context())
        #expect(answers.questions == [
            .init(text: "Will the revised proof reach you by Wednesday?", status: .answered),
            .init(text: "Please also confirm the paper stock.", status: .toConfirm),
        ])
        #expect(answers.asked == 2)
        #expect(answers.answered == 1)
        let request = try #require(model.requests.first)
        #expect(request.priority == .user)
        #expect(request.maximumTokens == 220)
        #expect(request.prompt.contains("<questions>\n1. Will the revised proof reach you by Wednesday?\n2. Please also confirm the paper stock.\n</questions>"))
    }

    /// A status counts only with words of the draft that deal with the question. A thank
    /// you deals with none.
    @Test func aStatusWithoutTheDraftsWordsDoesNotCount() async throws {
        let model = FakeModel(answering: #"answered", "quote": "It reaches us on Wednesday."}, "2": {"status": "answered", "quote": "Thanks for the proof."}}"#)
        let answers = try await service(model).checkAnswers(of: Self.draft, context: Self.context())
        #expect(answers.questions.map(\.status) == [.notAnswered, .notAnswered])
        #expect(answers.answered == 0)
    }

    @Test func anEmailWithoutQuestionsNeedsNoCall() async throws {
        let model = FakeModel(answering: "unused")
        let answers = try await service(model).checkAnswers(of: Self.draft, context: Self.context(email: "Hi Bai Lu,\n\nThe proof is in the mail.\n\nIris"))
        #expect(answers == ReviseService.Answers())
        #expect(answers.asked == 0)
        #expect(model.requests.isEmpty)
    }

    @Test func anUnreadableCheckThrows() async {
        let check = service(FakeModel(answering: "Both are answered."))
        await #expect(throws: ReviseService.Failure.unreadableAnswer) {
            try await check.checkAnswers(of: Self.draft, context: Self.context())
        }
        await #expect(throws: ReviseService.Failure.emptyDraft) {
            try await check.checkAnswers(of: "", context: Self.context())
        }
    }
}
