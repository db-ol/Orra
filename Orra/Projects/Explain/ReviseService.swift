import Foundation

/// Changes a draft reply with the cleanup model, translates it back for reading, and checks
/// which of the email's questions it answers. Each request runs through ProjectsModelQueue
/// as one of the user's, through the `run` closure, and DraftCheck runs on every new
/// version before the user sees it.
///
/// The service takes what it needs as values and closures, so it never waits for the store:
/// the window passes the email's context, and a new version leaves through `save`. A version
/// that DraftCheck holds back for its language is returned but not saved.
///
/// A new version is checked with the values of the first draft, and with the draft before
/// it and the user's instruction as text the recipients may get, next to the email. So
/// what the user typed into the draft or asked for stays, and only what the model added is
/// held to the check, such as project data for someone outside the project or an amount no
/// source holds.
nonisolated struct ReviseService: Sendable {
    /// What the prompts and the draft check need about the email a draft replies to. The
    /// window has it from the explanation.
    nonisolated struct Context: Sendable, Equatable {
        typealias Person = DraftCheckInput.Person

        /// The email the draft replies to, by its Message-ID without angle brackets.
        var messageID: String
        /// The email's own text, as ExplainPrompt reads it.
        var emailText: String
        /// The language of the draft from the reply rule, zh or en.
        var language: ProjectsLanguage
        /// The language the user reads, from `ProjectsLanguage.forExplanations`.
        var userLanguage: ProjectsLanguage
        /// The user's name, for the prompts.
        var ownName: String = ""
        /// The values of DraftCheckInput, as the first draft was checked with them.
        var recipients: [Person]
        var projectPeople: [Person]
        var own: [Person] = []
        var incomingText: String
        var sourceTexts: [String] = []
        var questionsForUser: [String] = []
        var today: Date
        var timeZone: TimeZone
    }

    /// A new version of a draft.
    nonisolated struct Version: Sendable, Equatable {
        /// The email the draft replies to.
        var messageID: String
        /// What the user asked for.
        var change: RevisePrompt.Change
        /// The draft check of what the model wrote. Its draft is the new version, or nil
        /// when the check held it back for its language.
        var check: DraftCheck.Result
        /// For a tone, the placeholders of the draft that the new version leaves out. A
        /// tone settles none, so the window says which went missing.
        var droppedPlaceholders: [String] = []

        /// The new version, or nil when it was held back.
        var draft: String? {
            check.draft
        }
    }

    /// The questions of an email and how a draft deals with each.
    nonisolated struct Answers: Sendable, Equatable {
        nonisolated struct Question: Sendable, Equatable {
            /// The question as the email words it.
            var text: String
            var status: RevisePrompt.AnswerCheck.Status
        }

        var questions: [Question] = []

        /// How many questions the email asks.
        var asked: Int {
            questions.count
        }

        /// How many of them the draft answers.
        var answered: Int {
            questions.count(where: { $0.status == .answered })
        }
    }

    nonisolated enum Failure: Error, Equatable {
        /// The draft's language is neither Chinese nor English, so Orra writes no draft.
        case noDraftLanguage
        /// The draft is empty.
        case emptyDraft
        /// The instruction is empty.
        case emptyInstruction
        /// The draft or the instruction does not fit into a prompt.
        case tooLong
        /// The model wrote nothing that can be used.
        case emptyAnswer
        /// The answer check's answer is no JSON with an entry for the questions.
        case unreadableAnswer
        /// The translation came back in another language than the one asked for.
        case wrongLanguage
    }

    /// Runs a prompt on the model and returns what the model wrote, without the prefill,
    /// see ProjectsModelQueue.run.
    var run: @Sendable (ProjectsModelRequest) async throws -> String
    /// The tokens of a text, for the prompt budget.
    var countTokens: @Sendable (String) -> Int
    /// Keeps a new version, such as in the store's drafts.
    var save: @Sendable (Version) async -> Void

    /// A new version of `draft`, from the user's instruction or in a tone, checked with
    /// DraftCheck, and saved unless the check held it back.
    @concurrent
    func revise(_ draft: String, _ change: RevisePrompt.Change, context: Context) async throws -> Version {
        guard context.language == .zh || context.language == .en else { throw Failure.noDraftLanguage }
        guard !draft.allSatisfy(\.isWhitespace) else { throw Failure.emptyDraft }
        var said = ""
        if case .instruction(let words) = change {
            guard !words.allSatisfy(\.isWhitespace) else { throw Failure.emptyInstruction }
            said = words
        }
        let input = RevisePrompt.Revision.Input(
            draft: draft, change: change, emailText: context.emailText, language: context.language,
            ownName: context.ownName, today: context.today, timeZone: context.timeZone
        )
        guard let prompt = RevisePrompt.Revision(input, countTokens: countTokens) else { throw Failure.tooLong }
        let answer = try await run(ProjectsModelRequest(prompt: prompt.text, maximumTokens: prompt.maximumTokens, priority: .user))
        guard let written = RevisePrompt.Revision.draft(RevisePrompt.Revision.prefill(context.language) + answer, placeholders: prompt.placeholders) else {
            throw Failure.emptyAnswer
        }
        try Task.checkCancellation()
        let check = await DraftCheck.check(DraftCheckInput(
            draft: written,
            language: context.language,
            recipients: context.recipients,
            projectPeople: context.projectPeople,
            own: context.own,
            incomingText: [context.incomingText, draft, said].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            sourceTexts: context.sourceTexts,
            questionsForUser: context.questionsForUser,
            today: context.today
        ))
        try Task.checkCancellation()
        let dropped = RevisePrompt.Revision.dropped(answer, placeholders: prompt.placeholders)
        let version = Version(messageID: context.messageID, change: change, check: check, droppedPlaceholders: dropped)
        if version.draft != nil {
            await save(version)
        }
        return version
    }

    /// The draft in the language the user reads, for reading next to it, or nil when the
    /// draft is in that language already, which needs no model call.
    @concurrent
    func translate(_ draft: String, context: Context) async throws -> String? {
        guard context.language == .zh || context.language == .en else { throw Failure.noDraftLanguage }
        let target: ProjectsLanguage = context.userLanguage == .zh ? .zh : .en
        guard target != context.language else { return nil }
        guard !draft.allSatisfy(\.isWhitespace) else { throw Failure.emptyDraft }
        guard let prompt = RevisePrompt.Translation(draft: draft, from: context.language, to: target, ownName: context.ownName, countTokens: countTokens) else {
            throw Failure.tooLong
        }
        let answer = try await run(ProjectsModelRequest(prompt: prompt.text, maximumTokens: prompt.maximumTokens, priority: .user))
        guard let translation = RevisePrompt.Translation.translation(RevisePrompt.Translation.prefill(target) + answer) else {
            throw Failure.emptyAnswer
        }
        guard ProjectsLanguage.reading(translation) == target else { throw Failure.wrongLanguage }
        return translation
    }

    /// Which of the email's questions `draft` answers. An email without questions needs no
    /// model call.
    @concurrent
    func checkAnswers(of draft: String, context: Context) async throws -> Answers {
        let questions = RevisePrompt.AnswerCheck.questions(in: context.emailText)
        guard !questions.isEmpty else { return Answers() }
        guard !draft.allSatisfy(\.isWhitespace) else { throw Failure.emptyDraft }
        guard let prompt = RevisePrompt.AnswerCheck(
            questions: questions, emailText: context.emailText, draft: draft, language: context.language,
            ownName: context.ownName, countTokens: countTokens
        ) else { throw Failure.tooLong }
        let answer = try await run(ProjectsModelRequest(prompt: prompt.text, maximumTokens: prompt.maximumTokens, priority: .user))
        guard let statuses = RevisePrompt.AnswerCheck.statuses(RevisePrompt.AnswerCheck.prefill + answer, count: prompt.questions.count, draft: draft) else {
            throw Failure.unreadableAnswer
        }
        return Answers(questions: zip(prompt.questions, statuses).map { Answers.Question(text: $0, status: $1) })
    }
}
