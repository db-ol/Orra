import Foundation
import os

/// One email explained, with the checks of the code around the model's answer. The window
/// shows it as plain text only.
nonisolated struct Explanation: Sendable, Equatable, Codable {
    nonisolated struct Point: Sendable, Equatable, Codable {
        /// The point without its source brackets, as the model wrote it.
        var text: String
        /// Its source ids that are in `sources`, such as F2, in order.
        var sources: [String]
        /// What OutputChecks found in it: a date with a weekday it does not fall on, or an
        /// amount that no source in the prompt holds.
        var flags: [OutputChecks.Finding]
    }

    nonisolated enum Draft: Sendable, Equatable, Codable {
        /// The model's draft after DraftCheck. Its draft is nil when DraftCheck held it
        /// back, since it is not in the language the reply rule chose.
        case checked(DraftCheck.Result)
        /// No reply is due, by the reply rule. A draft the model wrote anyway is dropped.
        case noReply(ReplyRule.NoReplyReason)
        /// A reply is due, but the email is in neither Chinese nor English, so no draft is
        /// written.
        case noDraft
        /// A reply is due, but the model wrote no draft, or wrote that none is due.
        case missing
        /// The draft went `Retention.drafts` after its last change, see Retention. The rest
        /// of the explanation stays as long as the email's text.
        case expired
    }

    /// The email's Message-ID, without angle brackets.
    var messageID: String
    var project: UUID?
    /// The language of the explanation, Chinese or English.
    var language: ProjectsLanguage
    /// The day the explanation counts from, as its dates and the draft check do.
    var today: Date
    /// The decision of ReplyRule, which the draft follows whatever the model wrote.
    var reply: ReplyRule.Decision
    /// The warnings the code found, each with where it is: the sender and content checks
    /// and hidden text of the email, a reply that reaches someone outside the project's
    /// people, what PromptHygiene took out of each part of the prompt, and project files
    /// with hidden runs. The user always sees them, whatever the model wrote.
    var warnings: [ExplainPrompt.Finding]
    /// The model's own warnings, one per line.
    var modelWarnings: [String]
    var points: [Point]
    /// The questions only the user can answer before replying.
    var questions: [String]
    var draft: Draft
    /// What DraftCheck checks a draft of this reply with, so a revision is checked as the
    /// first draft was. Set for every reply due in Chinese or English, also when the model
    /// wrote no draft, and nil otherwise. Its draft is empty, since `draft` holds the
    /// checked one.
    var draftCheck: DraftCheckInput?
    /// What the source ids of the points stand for: 本邮件 or this email, F1, O1, M1, T1 and
    /// A1. A file's excerpt says why it was in the prompt, see ExplainPrompt.FileOrigin, and
    /// an O id is an excerpt of a file of another project, whose origin names it.
    var sources: [String: ExplainPrompt.Source]
    /// What PromptHygiene took out of each place of the prompt, for the user to see. Never
    /// for the model or a log.
    var removed: [ExplainPrompt.Place: [PromptHygiene]]
    /// What was wrong with the form of the model's answer.
    var problems: [ExplainAnswer.Problem]
    /// Source ids the model named that the prompt does not have, each once.
    var unknownSources: [String]
    /// The search terms the model gave for the email, which the search used, so Explain
    /// Again searches with them too. Nil before 0.6.1, and when the model gave none.
    var searchTerms: [String]? = nil

    /// The kinds of `warnings`, each once, in the order of `ProjectsWarning.allCases`.
    var warningKinds: [ProjectsWarning] {
        let kinds = Set(warnings.map(\.warning))
        return ProjectsWarning.allCases.filter(kinds.contains)
    }

    /// The projects the explanation names: the email's, and the project of each file whose
    /// excerpt it holds. MailStore saves it only while they all exist.
    var sourceProjects: Set<UUID> {
        var projects = Set(sources.values.compactMap { source -> UUID? in
            guard case .file(_, let origin?) = source else { return nil }
            return origin.project
        })
        if let project {
            projects.insert(project)
        }
        return projects
    }

    /// Whether it holds an excerpt of a file in the folders of `project`, for Forget Project.
    func holdsFiles(of project: UUID) -> Bool {
        sources.values.contains { source in
            guard case .file(_, let origin?) = source else { return false }
            return origin.project == project
        }
    }

    /// Whether a point cites an excerpt of another project's file, see
    /// `ExplainPrompt.Source.isOtherProjectFile(emailProject:)`.
    var citesOtherProjectFile: Bool {
        points.contains { point in
            point.sources.contains { sources[$0]?.isOtherProjectFile(emailProject: project) == true }
        }
    }
}

nonisolated extension ExplainPrompt.Source {
    /// Whether this is an excerpt of a file of another project than `project`, the email's
    /// project or nil: a file whose origin names another project, which the user did not
    /// choose. A file the user chose for the email counts as the email's own, whatever its
    /// folder. The draft check, the window's note and Forget Project go by it, while the
    /// window labels every file whose origin names another project with that project.
    func isOtherProjectFile(emailProject project: UUID?) -> Bool {
        guard case .file(_, let origin?) = self, let other = origin.project, other != project else { return false }
        return origin.reason != .chosen
    }
}

/// Explains an email and drafts its reply through the sliced model (projects-explain-service).
///
/// For one email it:
/// - gathers by closure the user's own addresses, the projects and the people the user
///   knows, the other messages of the thread, and for an email in a project the chunks
///   that search finds, at most 2 of one file before the other files, the newest files
///   when search finds fewer than 3, the project's files for their versions, and the
///   project's other mail. Search reads the email's subject and text after PromptHygiene,
///   so hidden lines never steer it.
/// - runs the sender and content checks and the hygiene of the email and its attachments
///   before the search, and searches with the email's search terms too, see
///   `files(for:project:known:query:warnings:lookups:rule:perFileChunks:)`: the terms saved
///   with the email's explanation or new ones from the model, see SearchTerms. An email in
///   Needs a Project gets passages of the folders of the user's projects that match three of
///   its terms, and an email in a project up to two passages of other projects' folders
///   that rank above every passage of its own project that a term matches, after its
///   project's own passages, see `OtherProjectsRule`. A term that names the user, the
///   sender or a recipient or that is a date brings in none of them, and neither does an
///   email with a warning of `otherProjectWarnings`. They go into <other_files>, for the
///   warnings, points and questions only. Mail set aside gets no files and asks for no
///   terms. Without terms only the email's words search, and only its project's folders.
/// - decides the reply with ReplyRule.
/// - builds ExplainPrompt off the main actor, counting with the cleanup model's own
///   tokenizer, see ProjectsTokenCounter, and runs it through ProjectsModelQueue as a
///   request of the user with at most `ExplainPrompt.maximumTokens` tokens. A prompt with
///   passages of other projects asks for no draft, and a second request with the prompt the
///   email would get without them writes the draft, see `explain(_:)`. The draft check
///   still takes out of that draft the data, the copied sentences and the names of those
///   projects, see `otherProjectNames(_:)`, as a second guard.
/// - asks the model once more when its answer repeated an item of a list and wrote no
///   draft, since a small model that repeats a few lines goes on until its limit. The
///   second prompt goes on from the answer up to the repeat, see
///   `rest(_:written:countTokens:)`. When the second request fails, the first answer
///   counts, without its repeats, while a cancel still saves nothing.
/// - reads the answer with ExplainAnswer, runs OutputChecks on every point and DraftCheck
///   on the draft, and saves the Explanation through a closure before it returns it.
/// - shows the model's warnings, points and questions as `OutputChecks.shown` gives them:
///   links by their host only, and when the email asks for personal data, a credential or
///   confidential project data and a reply reaches someone outside the project, none of
///   the codes and numbers the recipients do not already have. A sender whose domain
///   imitates a known one gets a draft that names that domain nowhere and repeats nothing
///   from the email, which is why its draft check counts the email as holding nothing.
///
/// The warnings found in code go into the prompt's checks by kind only. A project file or
/// an attachment with hidden runs gives a hidden_text warning, and so does an email in which
/// VisibleText found hidden text. The content checks read the text of each attachment too,
/// and what they find there is noted at that attachment.
/// A reply is checked for everyone a reply to all reaches. A recipient who is neither among
/// the project's people nor at one of its domains gives the recipient_not_in_project_people
/// warning, and the draft carries no project data to them that they do not already have.
///
/// Nothing here waits for the store. The log holds counts and times only. The service
/// keeps the parsed tokenizer once it has loaded it, so the window creates the service
/// when it opens and lets it go when it closes.
final class ExplainService {
    /// The email to explain, as projects-mail-text gives it.
    nonisolated struct Email: Sendable, Equatable {
        /// The Message-ID, without angle brackets.
        var messageID: String
        var date: Date
        var sender: ExplainPrompt.Person
        /// The Reply-To addresses, which a reply goes to instead of the sender.
        var replyTo: [ExplainPrompt.Person] = []
        var to: [ExplainPrompt.Person] = []
        var cc: [ExplainPrompt.Person] = []
        var subject: String = ""
        /// The attachments with what Projects read of them, see MailAttachment. Their text
        /// goes into the prompt after the email's, and the checks read it.
        var attachments: [MailAttachment] = []
        /// The email's own text: visible, and without the quoted history when the quoted
        /// message is in the thread.
        var text: String
        /// The visible text with its quoted history and signature, which the content checks
        /// read, since a forged quote sits there.
        var visibleText: String
        /// The kinds of text the email hides from its reader, as VisibleText found them.
        var hiddenText: [ProjectsHiddenText] = []
        /// The list headers, for the reply rule.
        var list = ListMail()
        /// The email's project, or nil while it has none.
        var project: UUID? = nil
        /// Whether sorting set the email aside as list mail, which gets no files and no
        /// search terms.
        var isSetAside = false
    }

    /// A project as the explanation needs it.
    nonisolated struct Project: Sendable, Equatable {
        var id: UUID
        var name: String
        /// What the user wrote about it.
        var description: String = ""
        /// The people the user listed, with their roles.
        var people: [ExplainPrompt.Person] = []
        /// The domains the user listed, such as harbor.example.
        var domains: [String] = []
    }

    /// The user and the people the user knows, for the reply rule and the checks.
    nonisolated struct Known: Sendable, Equatable {
        var ownName: String = ""
        var ownAddresses: [String] = []
        /// All of the user's projects.
        var projects: [Project] = []
        /// Everyone the user wrote to before, read from the user's own mail only, so no
        /// stranger's email ever makes its sender, or anyone it names, known.
        var correspondents: [SenderChecks.Person] = []
        /// The text of the mail the user sent, or nil when Orra does not read sent mail,
        /// which leaves quotes of the user unchecked.
        var sentTexts: [String]? = nil
    }

    /// What the project's other mail is asked for.
    nonisolated struct MailQuery: Sendable, Equatable {
        var project: UUID
        /// The email's subject and text after PromptHygiene.
        var text: String
        /// The Message-IDs of the email and its thread, which the prompt shows elsewhere.
        var excluding: Set<String>
        var limit: Int
    }

    /// The closures the service reads with. They never wait for the store to be ready.
    nonisolated struct Lookups: Sendable {
        /// The user and the people the user knows, for this email.
        var known: @Sendable (Email) async throws -> Known
        /// The other messages of the email's thread, each with its own text.
        var thread: @Sendable (Email) async throws -> [ExplainPrompt.Mail]
        /// The project's other mail, best first for the query.
        var projectMail: @Sendable (MailQuery) async throws -> [ExplainPrompt.Mail]
        /// The best chunks for a query, see ChunkSearch.search(_:).
        var search: @Sendable (ChunkSearch.Query) async throws -> [ChunkSearch.Hit]
        /// The chunks of a project's newest files, see ChunkSearch.newest.
        var newest: @Sendable (_ project: UUID, _ limit: Int) async throws -> [ChunkSearch.Hit]
        /// A project's files with their start, for FileVersions.
        var files: @Sendable (_ project: UUID) async throws -> [FileVersions.File]
        /// The email's search terms: those saved with its explanation, or new ones from the
        /// model, see SearchTerms.ask. Nil when there are none, which searches with the
        /// email's words alone, as before search terms.
        var terms: @Sendable (Email) async throws -> [String]? = { _ in nil }
    }

    /// The chunks asked for to fill up the prompt. ChunkSearch.newest gives a file's
    /// chunks in a row, so this many cover the 3 newest files of most projects. A newest
    /// file longer than about 136,000 characters fills the whole list, and the fill up
    /// then shows that file only.
    nonisolated static let newestChunks = 200
    /// The most of the project's other mail asked for, as many as the prompt shows.
    nonisolated static let projectMailLimit = 3
    /// The passages of other projects an email in a project gets at most, after its project's
    /// own. An email in Needs a Project gets up to `ExplainPrompt.chunkLimit`.
    nonisolated static let otherProjectChunks = 2
    /// The passages of one file the prompt takes before those of other files, so a long file
    /// that matches many words, such as a log, leaves room for other files. In the synthetic
    /// set's retrieval supplement one log took five or six of the six places of many emails.
    /// The email's project fills the places other files leave with more of its passages, see
    /// `capped(_:perFile:limit:fill:)`, and other projects never get more than this.
    nonisolated static let perFileChunks = 2
    /// The chunks a search asks for, so `perFileChunks` leaves enough of other files.
    nonisolated static let searchedChunks = ExplainPrompt.chunkLimit * 4
    /// The warnings that keep the files of other projects out of an explanation, in the
    /// email, its header or an attachment: a stranger's mail must not pull the user's other
    /// projects into the prompt, and a request for a file is a common phishing pattern.
    nonisolated static let otherProjectWarnings: Set<ProjectsWarning> = [
        .hiddenText, .instructionToAssistant, .claimsToBeOrra, .lookalikeDomain, .senderNameMismatch, .forgedQuote,
        .paymentChange, .unknownSenderPayment, .forwardRequest, .confidentialDataRequest, .personalDataRequest,
        .credentialRequest, .attachmentNameSpoofing,
    ]

    private let lookups: Lookups
    /// Runs a prompt on the model, see ProjectsModelQueue.run.
    private let run: (ProjectsModelRequest) async throws -> String
    /// Loads the count closure of the model's tokenizer, or gives nil when the model is
    /// not on this Mac, see ProjectsTokenCounter.
    private let loadTokenCounter: @Sendable () async throws -> (@Sendable (String) -> Int)?
    private let save: (Explanation) async -> Void
    private let language: ProjectsLanguage
    private let timeZone: TimeZone
    private let now: () -> Date
    private let draftApart: Bool
    /// Loaded once.
    private var countTokens: (@Sendable (String) -> Int)?

    /// - Parameters:
    ///   - language: the language of explanations, see ProjectsLanguage.forExplanations.
    ///   - now: today, which evaluations pin.
    ///   - draftApart: whether the draft of an email whose prompt shows passages of other
    ///     projects comes from a second prompt without them, see
    ///     `explain(_:)`. Evaluations turn it off to measure one request, as before.
    init(
        lookups: Lookups,
        run: @escaping (ProjectsModelRequest) async throws -> String,
        loadTokenCounter: @escaping @Sendable () async throws -> (@Sendable (String) -> Int)?,
        save: @escaping (Explanation) async -> Void,
        language: ProjectsLanguage,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init,
        draftApart: Bool = true
    ) {
        self.lookups = lookups
        self.run = run
        self.loadTokenCounter = loadTokenCounter
        self.save = save
        self.language = language == .zh ? .zh : .en
        self.timeZone = timeZone
        self.now = now
        self.draftApart = draftApart
    }

    /// Explains the email, saves the explanation and returns it. Throws
    /// RewriteError.notLoaded when the model is not on this Mac, RewriteError.promptTooLong
    /// when even the trimmed prompt is too long, CancellationError when the caller's task
    /// is cancelled, and what a lookup throws.
    ///
    /// When the prompt shows a passage of another project, which the user did not choose for
    /// the email, the model gets two requests of the user, one after the other: that prompt,
    /// for the warnings, points and questions, which asks for no draft, and the prompt the
    /// email would get had no other project been searched, the project's own passages with
    /// the newest files that fill them up, for the draft alone. So no draft is written from
    /// another project's passages, whatever the model does with them. Every other email gets
    /// one request, whose prompt is as it was. Neither request has a time limit, as one had
    /// none, and both wait for a dictation, Live Captions, memory pressure and the voice
    /// rule in ProjectsModelQueue. A cancel, as by Forget Project, closing the window or
    /// turning Projects off, ends the request under way and saves nothing, and the draft's
    /// request is not sent after the first one was cancelled. When the first request fails,
    /// nothing is saved and the second is not sent, as with one request. When only the
    /// draft's request fails, or its prompt is over the budget, the explanation is saved
    /// without a draft, as when the model writes none, as a failed second request of
    /// `rest(_:written:countTokens:)` leaves the first answer.
    func explain(_ email: Email) async throws -> Explanation {
        let started = ContinuousClock.now
        do {
            let countTokens = try await tokenCounter()
            let known = try await lookups.known(email)
            let project = email.project.flatMap { id in known.projects.first { $0.id == id } }
            let thread = try await lookups.thread(email)
            var gathered = Gathered(email: email, known: known, project: project, thread: thread, today: now())
            // Every warning that keeps other projects out is found before the search.
            let rules = await Self.ruleWarnings(email, known: known)
            let attachments = await Self.attachmentWarnings(email, known: known)
            gathered.ruleWarnings = rules
            gathered.attachmentWarnings = attachments
            let warnings = await Self.retrievalWarnings(email, rules: rules, attachments: attachments)
            let query = await Self.searchText(email)
            gathered.take(try await Self.files(for: email, project: project, known: known, query: query, warnings: warnings, lookups: lookups))
            if let project {
                let excluding = Set(thread.map(\.messageID) + [email.messageID])
                gathered.projectMail = try await lookups.projectMail(MailQuery(project: project.id, text: query, excluding: excluding, limit: Self.projectMailLimit))
            }
            try Task.checkCancellation()

            let prepared = await Self.prepare(gathered, language: language, timeZone: timeZone, countTokens: countTokens, draftApart: draftApart)
            guard prepared.prompt.tokens <= ExplainPrompt.tokenBudget else { throw RewriteError.promptTooLong }
            let modelStarted = ContinuousClock.now
            let written = try await answer(prepared, countTokens: countTokens)
            var draft: DraftApart?
            if draftApart, prepared.reply.draftLanguage != nil, prepared.prompt.sources.keys.contains(where: ExplainPrompt.isOtherFileSource) {
                try Task.checkCancellation()
                draft = try await self.draft(gathered, countTokens: countTokens)
            }
            let modelTime = modelStarted.duration(to: .now)
            let explanation = await Self.finish(prepared, written: written, draft: draft, timeZone: timeZone)
            await save(explanation)
            Logger.projects.notice("Explained an email in \(Self.seconds(started.duration(to: .now)), privacy: .public), the model took \(Self.seconds(modelTime), privacy: .public): \(Self.summary(prepared.prompt, explanation, prepared.gathered, draft: draft), privacy: .public)")
            return explanation
        } catch {
            Logger.projects.notice("Explaining an email ended by \(Self.logName(error), privacy: .public) after \(Self.seconds(started.duration(to: .now)), privacy: .public)")
            throw error
        }
    }

    /// Runs a prompt as a request of the user and returns what the model wrote. An answer
    /// that repeated an item of a list and wrote no draft gets a second request for the
    /// rest, see `rest(_:written:countTokens:)`.
    private func answer(_ prepared: Prepared, countTokens: @escaping @Sendable (String) -> Int) async throws -> String {
        let started = ContinuousClock.now
        var written = try await run(ProjectsModelRequest(prompt: prepared.prompt.text, maximumTokens: ExplainPrompt.maximumTokens, priority: .user))
        if let rest = await Self.rest(prepared, written: written, countTokens: countTokens) {
            let looped = started.duration(to: .now)
            do {
                written = rest.text + (try await run(rest.request))
                Logger.projects.notice("The model repeated an item of its \(rest.section.rawValue, privacy: .public) and wrote no draft in \(Self.seconds(looped), privacy: .public), and a second request wrote the rest in \(Self.seconds(started.duration(to: .now) - looped), privacy: .public)")
            } catch let error where !(error is CancellationError) {
                // The first answer, without its repeats, is better than none.
                try Task.checkCancellation()
                Logger.projects.notice("The model repeated an item of its \(rest.section.rawValue, privacy: .public) and wrote no draft in \(Self.seconds(looped), privacy: .public), and a second request for the rest ended by \(Self.logName(error), privacy: .public) after \(Self.seconds(started.duration(to: .now) - looped), privacy: .public)")
            }
        }
        return written
    }

    /// The draft written apart from other projects' passages: the prompt the email gets
    /// without them, and what the model wrote for it, nil when that request failed or its
    /// prompt was over the budget. Throws only a cancel.
    nonisolated struct DraftApart: Sendable {
        var prepared: Prepared
        var written: String?
    }

    /// Asks for the draft with the prompt the email would get had no other project been
    /// searched: the gathered passages without those of other projects, so the project's own
    /// passages take every place and the newest files fill them up as for any email.
    private func draft(_ gathered: Gathered, countTokens: @escaping @Sendable (String) -> Int) async throws -> DraftApart {
        var own = gathered
        own.others = []
        own.otherFiles = [:]
        let prepared = await Self.prepare(own, language: language, timeZone: timeZone, countTokens: countTokens)
        guard prepared.prompt.tokens <= ExplainPrompt.tokenBudget else {
            Logger.projects.notice("The prompt for the draft without other projects' passages is over the budget, so the explanation has no draft")
            return DraftApart(prepared: prepared, written: nil)
        }
        let started = ContinuousClock.now
        do {
            let written = try await answer(prepared, countTokens: countTokens)
            Logger.projects.notice("The draft without other projects' passages took \(Self.seconds(started.duration(to: .now)), privacy: .public)")
            return DraftApart(prepared: prepared, written: written)
        } catch let error where !(error is CancellationError) {
            // The explanation is better than none, as when the model writes no draft.
            try Task.checkCancellation()
            Logger.projects.notice("The request for the draft without other projects' passages ended by \(Self.logName(error), privacy: .public) after \(Self.seconds(started.duration(to: .now)), privacy: .public), so the explanation has no draft")
            return DraftApart(prepared: prepared, written: nil)
        }
    }

    private func tokenCounter() async throws -> @Sendable (String) -> Int {
        if let countTokens {
            return countTokens
        }
        guard let loaded = try await loadTokenCounter() else { throw RewriteError.notLoaded }
        countTokens = loaded
        return loaded
    }

    // MARK: Before the model

    /// What the lookups gave for one email.
    nonisolated struct Gathered: Sendable {
        var email: Email
        var known: Known
        var project: Project?
        var thread: [ExplainPrompt.Mail]
        var today: Date
        var hits: [ChunkSearch.Hit] = []
        var newest: [ChunkSearch.Hit] = []
        var files: [FileVersions.File] = []
        var projectMail: [ExplainPrompt.Mail] = []
        /// The email's search terms, nil without any.
        var terms: [String]? = nil
        /// Passages of other projects' files, for <other_files>.
        var others: [ChunkSearch.Hit] = []
        /// The files of each project of `others`, for their versions.
        var otherFiles: [UUID: [FileVersions.File]] = [:]
        /// Whether other projects were searched, or why not, for the log.
        var otherProjects: Files.OtherProjects? = nil
        /// The warnings of `ruleWarnings(_:known:)` and `attachmentWarnings(_:known:)`, as
        /// `explain` found them before the search, or nil, which has `prepare` find them.
        var ruleWarnings: [ProjectsWarning]? = nil
        var attachmentWarnings: [Int: [ProjectsWarning]]? = nil

        /// Takes what the search gave.
        mutating func take(_ files: Files) {
            hits = files.hits
            newest = files.newest
            self.files = files.files
            terms = files.terms
            others = files.others
            otherFiles = files.otherFiles
            otherProjects = files.otherProjects
        }
    }

    /// The passages of project files an email gets, see
    /// `files(for:project:known:query:warnings:lookups:)`.
    nonisolated struct Files: Sendable, Equatable {
        /// Whether the folders of other projects were searched, or why not, by kind.
        nonisolated enum OtherProjects: String, Sendable {
            case searched
            /// No passage of another project ranks above the best passage of the email's
            /// project that a term matches, see `OtherProjectsRule.InProject.rankedAbove`.
            case notNeeded = "not needed"
            /// There are no search terms, so the email's words search its project alone.
            case noTerms = "no terms"
            /// The terms only name the user, the sender or a recipient, or a date, see
            /// `SearchTerms.withoutNamesAndDates(_:people:own:)`.
            case namesAndDates = "only names and dates"
            /// A check found one of `otherProjectWarnings`.
            case warned
            /// The email is set aside.
            case setAside = "set aside"
            /// The user has no other project.
            case none = "no other project"
        }

        /// The passages of the email's project that search found, best first.
        var hits: [ChunkSearch.Hit] = []
        /// The chunks of its newest files, when search found fewer than
        /// `ExplainPrompt.fillUpTo`.
        var newest: [ChunkSearch.Hit] = []
        /// The project's files with their start, for FileVersions.
        var files: [FileVersions.File] = []
        /// The search terms, nil without any.
        var terms: [String]? = nil
        /// Passages a term matched in the folders of the user's other projects, best first,
        /// none of a file that the email's project holds too.
        var others: [ChunkSearch.Hit] = []
        /// The files of each project of `others`, for their versions.
        var otherFiles: [UUID: [FileVersions.File]] = [:]
        var otherProjects: OtherProjects
    }

    /// How the passages of other projects' folders come into an email, see
    /// `files(for:project:known:query:warnings:lookups:rule:perFileChunks:)`. The app keeps
    /// the default, and evaluations try the others.
    nonisolated struct OtherProjectsRule: Sendable, Equatable {
        /// For an email in a project.
        nonisolated enum InProject: Sendable, Equatable {
            /// One ranking of the passages of all the user's projects, with the query of the
            /// email's own project: its words and its terms. A passage of another project comes
            /// in only when it ranks above every passage of the email's project that a term
            /// matches. Such a passage answers the terms better than anything the project
            /// holds, while a project that holds what the email is about keeps its own files.
            /// The passages come after the project's own, so the project keeps every passage
            /// it would have without them.
            case rankedAbove
            /// The rule before: the folders of other projects are searched when fewer than this
            /// many of the project's own passages matched a term. Above
            /// `ExplainPrompt.chunkLimit` they are searched for every email.
            case ownTermMatches(Int)
        }

        var inProject = InProject.rankedAbove
        /// The terms, of those that name no one and no date, that a passage of another project
        /// must match for an email in Needs a Project, each a different term. A word as common
        /// as appointment, service or garden matches some file of almost every user, while a
        /// file about the email's matter holds several of its terms. A term and its other
        /// language count as two when a passage holds both.
        var needsProjectTerms = 3
        /// Whether the terms that only name a person or a date search the email's own project
        /// too. They never search another project's folders.
        var namesSearchTheProject = true
    }

    /// The passages of project files for an email, with its search terms. Off the main
    /// actor, since the search reads the index. In order:
    /// 1. Mail set aside gets nothing and asks for no terms.
    /// 2. Other projects are allowed when none of `otherProjectWarnings` is among
    ///    `warnings`, those of the email and of its attachments.
    /// 3. The terms come from the lookup for an email in a project, and for one without a
    ///    project while other projects are allowed and the user has a project to search.
    /// 4. In a project: the best passages for the email's words and terms, the newest files
    ///    when fewer than `ExplainPrompt.fillUpTo` come back, and the project's files. When
    ///    other projects are allowed, up to `otherProjectChunks` passages of their folders that
    ///    rank above the project's own, after them, see
    ///    `OtherProjectsRule.InProject.rankedAbove`, none of a file the project holds, so a
    ///    folder added to two projects stays the email's own.
    /// 5. Without a project, with other projects allowed and terms: up to
    ///    `ExplainPrompt.chunkLimit` passages of all projects' folders, each matching
    ///    `OtherProjectsRule.needsProjectTerms` different terms.
    /// 6. The files of each project of those passages, for their versions.
    ///
    /// A term that names the user, the sender or a recipient, or that is only a date, never
    /// brings in a passage of another project, also when it comes from a list saved before,
    /// see `SearchTerms.withoutNamesAndDates(_:people:own:)`: such a term matches passages of
    /// every project. With only such terms no other project is searched.
    ///
    /// Each list takes at most `perFileChunks` passages of one file from the best
    /// `searchedChunks` of its search, and the email's project's list then fills the places
    /// that are left with the passages it passed over, so a project whose matching text sits
    /// in one long file still gets `ExplainPrompt.chunkLimit` passages, as in 0.6.0. `rule`
    /// and `perFileChunks` are the app's, evaluations try others, and a nil `perFileChunks`
    /// searches for `ExplainPrompt.chunkLimit` chunks and takes them all, as 0.6.0 did.
    @concurrent
    nonisolated static func files(
        for email: Email, project: Project?, known: Known, query: String, warnings: Set<ProjectsWarning>, lookups: Lookups,
        rule: OtherProjectsRule = OtherProjectsRule(), perFileChunks: Int? = ExplainService.perFileChunks
    ) async throws -> Files {
        guard !email.isSetAside else { return Files(otherProjects: .setAside) }
        let allowed = warnings.isDisjoint(with: otherProjectWarnings)
        guard project != nil || allowed else { return Files(otherProjects: .warned) }
        let others = known.projects.map(\.id).filter { $0 != project?.id }
        // Without a project and without any project to search, terms would serve nothing.
        guard project != nil || !others.isEmpty else { return Files(otherProjects: .none) }
        var found = Files(terms: try await lookups.terms(email), otherProjects: .searched)
        let terms = found.terms ?? []
        // Names and dates match passages of every project, so they search no other project.
        let people = ([email.sender] + email.replyTo + email.to + email.cc).map(\.name)
        let usable = SearchTerms.withoutNamesAndDates(found.terms, people: people, own: known.ownName) ?? []
        let searched = perFileChunks == nil ? ExplainPrompt.chunkLimit : searchedChunks
        var ownQuery: ChunkSearch.Query?
        if let project {
            let query = ChunkSearch.Query(text: query, terms: rule.namesSearchTheProject ? terms : usable, projects: [project.id], limit: searched)
            ownQuery = query
            let hits = try await lookups.search(query)
            found.hits = capped(hits, perFile: perFileChunks, limit: ExplainPrompt.chunkLimit, fill: true)
            if found.hits.count < ExplainPrompt.fillUpTo {
                found.newest = try await lookups.newest(project.id, newestChunks)
            }
            found.files = try await lookups.files(project.id)
        }
        if !allowed {
            found.otherProjects = .warned
        } else if terms.isEmpty {
            found.otherProjects = .noTerms
        } else if others.isEmpty {
            found.otherProjects = .none
        } else if usable.isEmpty {
            found.otherProjects = .namesAndDates
        } else {
            // A file the email's project holds stays its own, and a passage in the folders of
            // two other projects comes once.
            let own = Set(found.files.map(\.url.path) + (found.hits + found.newest).map(\.file.path))
            var seen = Set<String>()
            func isNew(_ hit: ChunkSearch.Hit) -> Bool {
                hit.project != project?.id && !own.contains(hit.file.path)
                    && seen.insert(hit.file.path + "\u{0}" + String(hit.page ?? 0) + "\u{0}" + hit.text).inserted
            }
            func matchesUsable(_ hit: ChunkSearch.Hit, least: Int = 1) -> Bool {
                Set(hit.matchedTerms).intersection(usable).count >= least
            }
            if let project, var ranking = ownQuery {
                var candidates: [ChunkSearch.Hit] = []
                switch rule.inProject {
                case .rankedAbove:
                    ranking.projects = [project.id] + others
                    let ranked = try await lookups.search(ranking)
                    let gate = ranked.firstIndex { $0.project == project.id && $0.matchedTerm } ?? ranked.endIndex
                    candidates = ranked[..<gate].filter { matchesUsable($0) && isNew($0) }
                case .ownTermMatches(let least):
                    if found.hits.count(where: \.matchedTerm) < least {
                        let hits = try await lookups.search(ChunkSearch.Query(text: query, terms: usable, projects: others, termsOnly: true, limit: searched))
                        candidates = hits.filter(isNew)
                    }
                }
                found.others = capped(candidates, perFile: perFileChunks, limit: otherProjectChunks)
                if found.others.isEmpty {
                    found.otherProjects = .notNeeded
                }
            } else {
                let hits = try await lookups.search(ChunkSearch.Query(text: query, terms: usable, projects: others, termsOnly: true, limit: searched))
                found.others = capped(hits.filter { matchesUsable($0, least: rule.needsProjectTerms) && isNew($0) }, perFile: perFileChunks, limit: ExplainPrompt.chunkLimit)
            }
            var projects: [UUID] = []
            for hit in found.others where !projects.contains(hit.project) {
                projects.append(hit.project)
            }
            for id in projects {
                found.otherFiles[id] = try await lookups.files(id)
            }
        }
        return found
    }

    /// The first `limit` hits, in their order, with at most `perFile` of one file, then with
    /// `fill` the hits it passed over, in their order, while places are left. The first
    /// `limit` of all when `perFile` is nil.
    nonisolated static func capped(_ hits: [ChunkSearch.Hit], perFile: Int?, limit: Int, fill: Bool = false) -> [ChunkSearch.Hit] {
        guard let perFile else { return Array(hits.prefix(limit)) }
        var taken: [String: Int] = [:]
        var kept: [ChunkSearch.Hit] = []
        var passed: [ChunkSearch.Hit] = []
        for hit in hits where kept.count < limit {
            if taken[hit.file.path, default: 0] < perFile {
                taken[hit.file.path, default: 0] += 1
                kept.append(hit)
            } else {
                passed.append(hit)
            }
        }
        if fill {
            kept += passed.prefix(max(limit - kept.count, 0))
        }
        return kept
    }

    /// The prompt and what the checks after the model need.
    nonisolated struct Prepared: Sendable {
        var gathered: Gathered
        var reply: ReplyRule.Decision
        var prompt: ExplainPrompt
        /// Everyone a reply to all reaches, the user left out.
        var recipients: [ExplainPrompt.Person]
    }

    /// Decides the reply, runs the sender and content checks and builds the prompt, which
    /// with `draftApart` asks for no draft when it shows passages of other projects, see
    /// `ExplainPrompt.Input.draftApart`. Off the main actor, since the checks, the hygiene
    /// and the token counts read long text.
    @concurrent
    nonisolated static func prepare(_ gathered: Gathered, language: ProjectsLanguage, timeZone: TimeZone, countTokens: @Sendable (String) -> Int, draftApart: Bool = true) async -> Prepared {
        let email = gathered.email
        let known = gathered.known
        let ownAddresses = Set(known.ownAddresses.compactMap(ProjectsAddress.normalized))
        let reply = ReplyRule(ownAddresses: known.ownAddresses).decision(
            sender: email.sender.address,
            date: email.date,
            thread: gathered.thread.map { ReplyRule.Message(sender: $0.sender.address, date: $0.date) },
            list: email.list,
            text: email.text,
            subject: email.subject
        )
        let recipients = replyRecipients(of: email, ownAddresses: ownAddresses)
        var warnings = if let found = gathered.ruleWarnings { found } else { await ruleWarnings(email, known: known) }
        if let project = gathered.project, case .reply = reply, recipients.contains(where: { !isInProject($0.address, project) }) {
            warnings.append(.recipientNotInProjectPeople)
        }

        var input = ExplainPrompt.Input(
            email: ExplainPrompt.Mail(
                messageID: email.messageID,
                date: email.date,
                sender: email.sender,
                to: email.to,
                cc: email.cc,
                subject: email.subject,
                attachmentNames: email.attachments.map(\.name),
                text: email.text
            ),
            reply: reply,
            language: language,
            today: gathered.today,
            timeZone: timeZone,
            ownName: known.ownName,
            ownAddresses: known.ownAddresses
        )
        if let project = gathered.project {
            input.project = ExplainPrompt.Project(name: project.name, description: project.description, people: project.people)
        }
        input.chunks = gathered.hits.map(chunk)
        input.newestChunks = gathered.newest.map(chunk)
        // Why each file is in the prompt. The fill leaves out every file search found, so a
        // file has one reason, and a hit counts over the fill all the same.
        for hit in gathered.newest {
            input.fileOrigins[hit.file] = ExplainPrompt.FileOrigin(reason: .newest, project: hit.project)
        }
        for hit in gathered.hits {
            input.fileOrigins[hit.file] = ExplainPrompt.FileOrigin(reason: .match, project: hit.project)
        }
        input.versions = FileVersions(gathered.files)
        input.otherChunks = gathered.others.map { hit in
            ExplainPrompt.OtherChunk(chunk: chunk(hit), project: hit.project, projectName: known.projects.first { $0.id == hit.project }?.name ?? "")
        }
        input.otherVersions = gathered.otherFiles.mapValues(FileVersions.init)
        input.filesWithHiddenText = Set((gathered.hits + gathered.newest + gathered.others).filter { $0.fileHiddenRuns > 0 }.map(\.file))
        input.projectMail = gathered.projectMail
        input.thread = gathered.thread
        input.attachments = email.attachments
        input.attachmentWarnings = if let found = gathered.attachmentWarnings { found } else { await attachmentWarnings(email, known: known) }
        input.warnings = ProjectsWarning.allCases.filter(Set(warnings).contains)
        input.draftApart = draftApart
        let prompt = ExplainPrompt(input, countTokens: countTokens)
        return Prepared(gathered: gathered, reply: reply, prompt: prompt, recipients: recipients)
    }

    /// The warnings about the email that code finds: the sender and content checks, and
    /// hidden text that VisibleText found, in the order of `ProjectsWarning.allCases`. The
    /// checks of the attachments' names are among them, those of their text are not, see
    /// `attachmentWarnings(_:known:)`.
    @concurrent
    nonisolated static func ruleWarnings(_ email: Email, known: Known) async -> [ProjectsWarning] {
        let own = ownPeople(known)
        let people = knownPeople(known)
        var warnings = Set(SenderChecks.warnings(for: SenderChecks.Input(
            sender: SenderChecks.Person(name: email.sender.name, address: email.sender.address),
            people: people,
            domains: guardedDomains(known.projects),
            own: own
        )))
        warnings.formUnion(await ContentChecks.warnings(for: ContentChecks.Input(
            subject: email.subject,
            text: email.visibleText,
            attachments: email.attachments.map { ContentChecks.Input.Attachment(name: $0.name, type: $0.type) },
            senderIsKnown: senderIsKnown(email.sender.address, people: people, projects: known.projects),
            own: own,
            sentTexts: known.sentTexts
        )))
        if !email.hiddenText.isEmpty {
            warnings.insert(.hiddenText)
        }
        return ProjectsWarning.allCases.filter(warnings.contains)
    }

    /// What the content checks find in the text of each attachment Projects read, by its
    /// index in the email's attachments, in the order of `ProjectsWarning.allCases`. The
    /// text is the sender's own, so no quote of the user is looked for in it.
    @concurrent
    nonisolated static func attachmentWarnings(_ email: Email, known: Known) async -> [Int: [ProjectsWarning]] {
        let own = ownPeople(known)
        let isKnown = senderIsKnown(email.sender.address, people: knownPeople(known), projects: known.projects)
        var found: [Int: [ProjectsWarning]] = [:]
        for (index, attachment) in email.attachments.enumerated() {
            guard let text = attachment.text, !text.isEmpty else { continue }
            let warnings = Set(await ContentChecks.warnings(for: ContentChecks.Input(
                subject: "", text: text, senderIsKnown: isKnown, own: own)))
            if !warnings.isEmpty {
                found[index] = ProjectsWarning.allCases.filter(warnings.contains)
            }
        }
        return found
    }

    /// Every warning that keeps the files of other projects out, found before the search:
    /// `rules` and `attachments`, the warnings of `ruleWarnings(_:known:)` and
    /// `attachmentWarnings(_:known:)`, and what PromptHygiene finds in the email's header,
    /// subject, attachment names and text and in the text of each attachment, with hidden
    /// text where an attachment's reader dropped hidden runs, see
    /// ExplainPrompt.hygieneWarnings. The prompt notes the same findings once it is built.
    @concurrent
    nonisolated static func retrievalWarnings(_ email: Email, rules: [ProjectsWarning], attachments: [Int: [ProjectsWarning]]) async -> Set<ProjectsWarning> {
        let mail = ExplainPrompt.Mail(
            messageID: email.messageID, date: email.date, sender: email.sender, to: email.to, cc: email.cc,
            subject: email.subject, attachmentNames: email.attachments.map(\.name), text: email.text)
        return Set(rules).union(attachments.values.joined()).union(ExplainPrompt.hygieneWarnings(of: mail, attachments: email.attachments))
    }

    /// The user, by name and each address, for the checks.
    private nonisolated static func ownPeople(_ known: Known) -> [SenderChecks.Person] {
        known.ownAddresses.map { SenderChecks.Person(name: known.ownName, address: $0) }
    }

    /// The people of every project and everyone the user exchanged mail with, for the checks.
    private nonisolated static func knownPeople(_ known: Known) -> [SenderChecks.Person] {
        known.projects.flatMap { $0.people.map { SenderChecks.Person(name: $0.name, address: $0.address) } } + known.correspondents
    }

    /// The domains the sender checks guard against every kind of lookalike: those the user
    /// listed for projects, and those of project people that no other project shares, so a
    /// mail provider that people of two projects use stays out. Lowercased and sorted.
    nonisolated static func guardedDomains(_ projects: [Project]) -> [String] {
        var owners: [String: Set<UUID>] = [:]
        for project in projects {
            for domain in project.domains.map(domainForm) where !domain.isEmpty {
                owners[domain, default: []].insert(project.id)
            }
            for person in project.people {
                if let address = ProjectsAddress.normalized(person.address), let domain = address.split(separator: "@").last {
                    owners[String(domain), default: []].insert(project.id)
                }
            }
        }
        let listed = Set(projects.flatMap(\.domains).map(domainForm).filter { !$0.isEmpty })
        return listed.union(owners.filter { $0.value.count == 1 }.keys).sorted()
    }

    /// Whether the sender is among the people the user knows, or at a domain the user
    /// listed for a project.
    private nonisolated static func senderIsKnown(_ sender: String, people: [SenderChecks.Person], projects: [Project]) -> Bool {
        guard let address = ProjectsAddress.normalized(sender) else { return false }
        if people.contains(where: { ProjectsAddress.normalized($0.address) == address }) {
            return true
        }
        return projects.contains { project in isAtDomain(address, project.domains) }
    }

    /// Everyone a reply to all reaches: the Reply-To addresses, or the sender without them,
    /// then To and Cc. Each address once, without the user's own. An address that does not
    /// parse stays as it is, so the draft check counts it as outside the project.
    nonisolated static func replyRecipients(of email: Email, ownAddresses: Set<String>) -> [ExplainPrompt.Person] {
        let first = email.replyTo.isEmpty ? [email.sender] : email.replyTo
        var seen: Set<String> = []
        var recipients: [ExplainPrompt.Person] = []
        for person in first + email.to + email.cc {
            let key = ProjectsAddress.normalized(person.address) ?? person.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !ownAddresses.contains(key), seen.insert(key).inserted else { continue }
            recipients.append(person)
        }
        return recipients
    }

    /// Whether the address is one of the project's people, or at one of its domains.
    nonisolated static func isInProject(_ address: String, _ project: Project) -> Bool {
        guard let address = ProjectsAddress.normalized(address) else { return false }
        return project.people.contains { ProjectsAddress.normalized($0.address) == address } || isAtDomain(address, project.domains)
    }

    /// The domain of an address, lowercased, or nil when the address does not parse.
    private nonisolated static func domain(of address: String) -> String? {
        ProjectsAddress.normalized(address)?.split(separator: "@").last.map(String.init)
    }

    private nonisolated static func isAtDomain(_ address: String, _ domains: [String]) -> Bool {
        guard let domain = address.split(separator: "@").last.map(String.init) else { return false }
        return domains.map(domainForm).contains { !$0.isEmpty && (domain == $0 || domain.hasSuffix("." + $0)) }
    }

    /// A domain as the user may write it, such as "@Harbor.example", in the form of an
    /// address's domain: harbor.example.
    private nonisolated static func domainForm(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@."))).lowercased()
    }

    /// The text search and the project's other mail are found with: the subject and the
    /// email's own text, without what PromptHygiene takes out, cut to the characters a
    /// search reads. Off the main actor, since the hygiene reads the whole text.
    @concurrent
    nonisolated static func searchText(_ email: Email) async -> String {
        let text = PromptHygiene.withoutMarkers(PromptHygiene(email.subject + "\n" + email.text, source: .mail).text)
        return String(text.prefix(ChunkSearch.maximumQueryCharacters))
    }

    private nonisolated static func chunk(_ hit: ChunkSearch.Hit) -> TextChunker.Chunk {
        TextChunker.Chunk(
            file: hit.file, page: hit.page, modified: hit.modified, heading: hit.heading, text: hit.text, sheet: hit.sheet,
            recognized: hit.recognized ? true : nil)
    }

    // MARK: After the model

    /// The second request for an answer that repeated an item of a list and wrote no draft.
    nonisolated struct Rest: Sendable {
        /// The list the model repeated.
        var section: ExplainAnswer.Section
        /// What comes before the second answer: the first one up to the repeat, and the
        /// heading of the next section.
        var text: String
        var request: ProjectsModelRequest
    }

    /// The second request when the answer repeated an item of a list and has no draft, as
    /// when the model repeats a few lines until its limit, or nil. ExplainAnswer ends the
    /// last list that repeated before the repeat with at most `ExplainAnswer.loopItems`
    /// items, see `ExplainAnswer.loop`, and the second prompt is the first one with the
    /// answer up to there and the heading of the next section, so the model goes on from
    /// that heading. The answer goes in as a block, see `ExplainPrompt.block`, so a chat
    /// template token the model spelled out cannot end its turn. The two answers together
    /// write at most `ExplainPrompt.maximumTokens`. Nil when the second prompt would pass
    /// the budget. Off the main actor, since it reads the answer and counts the prompt.
    @concurrent
    nonisolated static func rest(_ prepared: Prepared, written: String, countTokens: @Sendable (String) -> Int) async -> Rest? {
        let prompt = prepared.prompt
        let prefill = ExplainPrompt.prefill(prompt.language)
        let answer = ExplainAnswer(prefill + written, sources: prompt.sources.keys, rules: prompt.rules)
        guard let loop = answer.loop,
              let next = ExplainAnswer.Section.allCases.drop(while: { $0 != loop.section }).dropFirst().first else { return nil }
        let kept = loop.kept.hasPrefix(prefill) ? String(loop.kept.dropFirst(prefill.count)) : loop.kept
        let text = ExplainPrompt.block(kept) + "\n\n" + ExplainPrompt.Headings(prompt.language).heading(next) + "\n"
        let tokens = countTokens(text)
        guard tokens < ExplainPrompt.maximumTokens, countTokens(prompt.text + text) <= ExplainPrompt.tokenBudget else { return nil }
        return Rest(section: loop.section, text: text, request: ProjectsModelRequest(prompt: prompt.text + text, maximumTokens: ExplainPrompt.maximumTokens - tokens, priority: .user))
    }

    /// Reads the answer and runs the checks on it. Off the main actor, since the checks
    /// read every source of the prompt. With `apart`, the draft written without other
    /// projects' passages, the explanation takes its warnings, points, questions and sources
    /// from `written` and its draft from `apart`, which DraftCheck checks with the sources of
    /// its own prompt and, as a second guard, with the passages of other projects that the
    /// first prompt held.
    @concurrent
    nonisolated static func finish(_ prepared: Prepared, written: String, draft apart: DraftApart? = nil, timeZone: TimeZone) async -> Explanation {
        let gathered = prepared.gathered
        let email = gathered.email
        let prompt = prepared.prompt
        let answer = ExplainAnswer(ExplainPrompt.prefill(prompt.language) + written, sources: prompt.sources.keys, rules: prompt.rules)
        let texts = sourceTexts(prepared)
        let draftAnswer = apart.flatMap { apart in
            apart.written.map { ExplainAnswer(ExplainPrompt.prefill(apart.prepared.prompt.language) + $0, sources: apart.prepared.prompt.sources.keys, rules: apart.prepared.prompt.rules) }
        }
        // The draft of a prompt that asked for none says nothing, so the form of the draft is
        // that of the answer the draft comes from.
        var problems = answer.problems
        if apart != nil {
            let ofDraft: (ExplainAnswer.Problem) -> Bool = { $0 == .missing(.draft) || $0 == .repeated(.draft) }
            problems.removeAll(where: ofDraft)
            problems += draftAnswer?.problems.filter(ofDraft) ?? []
        }

        // What the window shows of the model's text: links by their host, and with a
        // request for data from someone outside the project none of the values the
        // recipients do not already have. A reply that reaches nobody counts as going
        // outside, as in DraftCheck.
        let found = Set(prompt.checks.filter(\.place.isTheEmail).map(\.warning))
        let reachesOutside = prepared.recipients.isEmpty || prepared.recipients.contains { recipient in
            gathered.project.map { !isInProject(recipient.address, $0) } ?? true
        }
        let asksForData = reachesOutside && !found.isDisjoint(with: [.personalDataRequest, .credentialRequest, .confidentialDataRequest])
        let imitating = found.contains(.lookalikeDomain) ? domain(of: email.sender.address).map { [$0] } ?? [] : []
        func shown(_ text: String) -> String {
            OutputChecks.shown(text, withholding: asksForData ? texts.incoming : nil, language: prompt.language)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // An amount a point takes from another project's file has a source too.
        let allSources = [texts.incoming] + texts.other + texts.otherProjects
        let points = answer.points.map { point in
            let text = shown(point.text)
            return Explanation.Point(
                text: text,
                sources: point.sources,
                flags: OutputChecks.findings(in: text, sources: allSources, today: gathered.today, calendar: calendar)
            )
        }

        let draft: Explanation.Draft
        var draftCheck: DraftCheckInput?
        switch prepared.reply {
        case .noReply(let reason):
            draft = .noReply(reason)
        case .reply(let language) where language == .other:
            draft = .noDraft
        case .reply(let language):
            let own = gathered.known.ownAddresses.map { DraftCheckInput.Person(name: gathered.known.ownName, address: $0) }
            let recipients = prepared.recipients.map { DraftCheckInput.Person(name: $0.name, address: $0.address) }
            var people = gathered.project?.people.map { DraftCheckInput.Person(name: $0.name, address: $0.address) } ?? []
            // People at the project's domains count as its people, as in phase 0.
            if let project = gathered.project {
                people += recipients.filter { isInProject($0.address, project) && !people.contains($0) }
            }
            // A draft written apart is checked with what its own prompt held, and the passages
            // of other projects in the first prompt stay a second guard.
            let draftTexts = apart.map { sourceTexts($0.prepared) } ?? texts
            let input = DraftCheckInput(
                draft: "",
                language: language,
                recipients: recipients,
                projectPeople: people,
                own: own,
                incomingText: imitating.isEmpty ? draftTexts.incoming : "",
                sourceTexts: draftTexts.other,
                questionsForUser: answer.questions.map(shown),
                today: gathered.today,
                imitatingDomains: imitating,
                asksForData: asksForData,
                otherProjectTexts: texts.otherProjects.isEmpty ? nil : texts.otherProjects,
                otherProjectNames: texts.otherProjects.isEmpty ? nil : otherProjectNames(prepared)
            )
            draftCheck = input
            let written = apart == nil ? answer.draft : (draftAnswer?.draft ?? .missing)
            if case .reply(let text) = written {
                var checked = input
                checked.draft = text
                draft = .checked(await DraftCheck.check(checked))
            } else {
                draft = .missing
            }
        }

        return Explanation(
            messageID: email.messageID,
            project: gathered.project?.id,
            language: prompt.language,
            today: gathered.today,
            reply: prepared.reply,
            warnings: prompt.checks,
            modelWarnings: answer.warnings.map(shown),
            points: points,
            questions: answer.questions.map(shown),
            draft: draft,
            draftCheck: draftCheck,
            sources: prompt.sources,
            removed: prompt.removed,
            problems: problems,
            unknownSources: answer.unknownSources,
            searchTerms: gathered.terms
        )
    }

    /// The texts of the prompt for the checks after the model. `incoming` is what the
    /// recipients of a reply already have: the email with its quoted history, and the
    /// earlier messages of its thread that every recipient outside the project was on.
    /// `other` is the rest of what the model read of the email's project: the project's
    /// description, the excerpts of its files and the other mail in the prompt, with the
    /// people of its headers. `otherProjects` holds the excerpts of other projects' files,
    /// see `ExplainPrompt.Source.isOtherProjectFile(emailProject:)`, which no draft carries.
    nonisolated static func sourceTexts(_ prepared: Prepared) -> (incoming: String, other: [String], otherProjects: [String]) {
        let gathered = prepared.gathered
        let email = gathered.email
        let own = Set(gathered.known.ownAddresses.compactMap(ProjectsAddress.normalized))
        // DraftCheck lets project data go to the project's people anyway, so only the
        // recipients outside the project decide what a reply may repeat. Without a project
        // every recipient is outside. One whose address does not parse was on no earlier
        // message, and a reply that reaches nobody counts as going outside, as in DraftCheck.
        let outside = prepared.recipients.filter { recipient in
            gathered.project.map { !isInProject(recipient.address, $0) } ?? true
        }
        var messages: [String: ExplainPrompt.Mail] = [:]
        for mail in gathered.projectMail + gathered.thread {
            messages[mail.messageID] = mail
        }
        // The recipients have the attachments too.
        var incoming = [email.subject, email.visibleText] + email.attachments.compactMap(\.text)
        var other: [String] = []
        var otherProjects: [String] = []
        if let description = gathered.project?.description, !description.isEmpty {
            other.append(description)
        }
        for id in prepared.prompt.sources.keys.sorted() {
            let source = prepared.prompt.sources[id]
            switch source {
            case .file(let chunk, _):
                if source?.isOtherProjectFile(emailProject: gathered.project?.id) == true {
                    otherProjects.append(chunk.text)
                } else {
                    other.append(chunk.text)
                }
            case .attachment:
                // In `incoming` already.
                continue
            case .message(let messageID):
                guard messageID != email.messageID, let mail = messages[messageID] else { continue }
                let people = Set(([mail.sender] + mail.to + mail.cc).compactMap { ProjectsAddress.normalized($0.address) })
                let wasOnIt = !prepared.recipients.isEmpty
                    && gathered.thread.contains { $0.messageID == messageID }
                    && mail.date <= email.date
                    && outside.allSatisfy { ProjectsAddress.normalized($0.address).map(people.contains) ?? false }
                if wasOnIt {
                    incoming.append(mail.text)
                } else {
                    other.append(mail.text)
                    let header = headerPeople(of: mail, own: own)
                    if !header.isEmpty { other.append(header) }
                }
            case nil:
                continue
            }
        }
        return (incoming.joined(separator: "\n\n"), other, otherProjects)
    }

    /// The names that belong to the projects whose excerpts are among the other projects'
    /// texts of `sourceTexts(_:)`, which no draft carries either: each project's name, or each
    /// part of a name such as "2027 台历印制 / 2027 desk calendar print run", the names of its
    /// people, and the names its domains spell in two words or more, as
    /// bridgeway-talent.example spells Bridgeway Talent. A domain the email's own project lists
    /// stays out. Nil when there are none.
    nonisolated static func otherProjectNames(_ prepared: Prepared) -> [String]? {
        let gathered = prepared.gathered
        var projects: [UUID] = []
        for id in prepared.prompt.sources.keys.sorted() {
            guard let source = prepared.prompt.sources[id], source.isOtherProjectFile(emailProject: gathered.project?.id),
                  case .file(_, let origin?) = source, let project = origin.project, !projects.contains(project) else { continue }
            projects.append(project)
        }
        let ownDomains = Set((gathered.project?.domains ?? []).map(domainForm))
        var names: [String] = []
        for id in projects {
            guard let project = gathered.known.projects.first(where: { $0.id == id }) else { continue }
            names += project.name.split(whereSeparator: { "/／|｜".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            names += project.people.map(\.name)
            for domain in project.domains.map(domainForm) where !ownDomains.contains(domain) {
                for label in domain.split(separator: ".").dropLast() {
                    let words = label.split(separator: "-")
                    if words.count >= 2 {
                        names.append(words.joined(separator: " "))
                    }
                }
            }
        }
        var seen = Set<String>()
        let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// The people of a mail's header, which the prompt shows with it, one a line and
    /// without the user, so the draft check protects their names and addresses as it does
    /// those in the mail's text.
    private nonisolated static func headerPeople(of mail: ExplainPrompt.Mail, own: Set<String>) -> String {
        ([mail.sender] + mail.to + mail.cc)
            .filter { person in ProjectsAddress.normalized(person.address).map { !own.contains($0) } ?? true }
            .map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Log

    /// Counts and kinds only.
    private nonisolated static func summary(_ prompt: ExplainPrompt, _ explanation: Explanation, _ gathered: Gathered, draft apart: DraftApart?) -> String {
        let files = prompt.sources.keys.filter { $0.hasPrefix("F") }.count
        let otherFiles = prompt.sources.keys.filter(ExplainPrompt.isOtherFileSource).count
        // The reasons of the project's own excerpts, the F ids.
        let reasons = prompt.sources.compactMap { id, source -> ExplainPrompt.FileOrigin.Reason? in
            guard id.hasPrefix("F"), case .file(_, let origin) = source else { return nil }
            return origin?.reason
        }
        let found = reasons.filter { $0 == .match }.count
        let newest = reasons.filter { $0 == .newest }.count
        let terms = gathered.terms.map { "\($0.count) search terms" } ?? "no search terms"
        let otherProjects = gathered.otherProjects.map { "other projects \($0.rawValue)" } ?? "other projects not searched"
        let thread = prompt.sources.keys.filter { $0.hasPrefix("T") }.count
        let projectMail = prompt.sources.keys.filter { $0.hasPrefix("M") }.count
        let attachments = prompt.sources.keys.filter { $0.hasPrefix("A") }.count
        var draft: String
        switch explanation.draft {
        case .checked(let result):
            draft = (result.draft == nil ? "held back" : "checked") + " with \(result.removals.count) removals and \(result.flags.count) flags"
        case .noReply: draft = "no reply due"
        case .noDraft: draft = "no draft for the language"
        case .missing: draft = "missing"
        case .expired: draft = "expired"
        }
        if let apart {
            draft += apart.written == nil ? ", its request without other projects' passages failed" : ", written by a request of \(apart.prepared.prompt.tokens) prompt tokens without other projects' passages"
        }
        let flagged = explanation.points.filter { !$0.flags.isEmpty }.count
        return "\(terms), \(otherProjects), \(prompt.tokens) prompt tokens with \(files) excerpts (\(found) found by search, \(newest) of the newest files), \(otherFiles) excerpts of other projects, \(thread) thread messages, \(projectMail) project mails and \(attachments) attachments, \(explanation.points.count) points of which \(flagged) flagged, \(explanation.questions.count) questions, \(explanation.warnings.count) warnings in code and \(explanation.modelWarnings.count) from the model, draft \(draft), \(explanation.problems.count) problems of form"
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", duration / .seconds(1))
    }

    /// The kind of error, never its description, which could hold text.
    private nonisolated static func logName(_ error: any Error) -> String {
        if let error = error as? RewriteError {
            return "RewriteError.\(error)"
        }
        if error is CancellationError {
            return "cancellation"
        }
        return String(reflecting: type(of: error))
    }
}
