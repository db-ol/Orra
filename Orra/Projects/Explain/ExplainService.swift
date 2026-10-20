import Foundation
import os

/// One email explained, with the checks of the code around the model's answer. The window
/// shows it as plain text only.
nonisolated struct Explanation: Sendable, Equatable {
    nonisolated struct Point: Sendable, Equatable {
        /// The point without its source brackets, as the model wrote it.
        var text: String
        /// Its source ids that are in `sources`, such as F2, in order.
        var sources: [String]
        /// What OutputChecks found in it: a date with a weekday it does not fall on, or an
        /// amount that no source in the prompt holds.
        var flags: [OutputChecks.Finding]
    }

    nonisolated enum Draft: Sendable, Equatable {
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
    /// What the source ids of the points stand for: 本邮件 or this email, F1, M1 and T1.
    var sources: [String: ExplainPrompt.Source]
    /// What PromptHygiene took out of each place of the prompt, for the user to see. Never
    /// for the model or a log.
    var removed: [ExplainPrompt.Place: [PromptHygiene]]
    /// What was wrong with the form of the model's answer.
    var problems: [ExplainAnswer.Problem]
    /// Source ids the model named that the prompt does not have, each once.
    var unknownSources: [String]

    /// The kinds of `warnings`, each once, in the order of `ProjectsWarning.allCases`.
    var warningKinds: [ProjectsWarning] {
        let kinds = Set(warnings.map(\.warning))
        return ProjectsWarning.allCases.filter(kinds.contains)
    }
}

/// Explains an email and drafts its reply through the sliced model (projects-explain-service).
///
/// For one email it:
/// - gathers by closure the user's own addresses, the projects and the people the user
///   knows, the other messages of the thread, and for an email in a project the chunks
///   that search finds, the newest files when search finds fewer than 3, the project's
///   files for their versions, and the project's other mail. Search reads the email's
///   subject and text after PromptHygiene, so hidden lines never steer it.
/// - decides the reply with ReplyRule, and runs the sender and content checks.
/// - builds ExplainPrompt off the main actor, counting with the cleanup model's own
///   tokenizer, see ProjectsTokenCounter, and runs it through ProjectsModelQueue as a
///   request of the user with at most `ExplainPrompt.maximumTokens` tokens.
/// - reads the answer with ExplainAnswer, runs OutputChecks on every point and DraftCheck
///   on the draft, and saves the Explanation through a closure before it returns it.
///
/// The warnings found in code go into the prompt's checks by kind only. A project file
/// with hidden runs gives a hidden_text warning, and so does an email in which VisibleText
/// found hidden text. A reply is checked for everyone a reply to all reaches. A recipient
/// who is neither among the project's people nor at one of its domains gives the
/// recipient_not_in_project_people warning, and the draft carries no project data to them.
///
/// Nothing here waits for the store. The log holds counts and times only.
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
        var attachments: [ContentChecks.Input.Attachment] = []
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
        /// Everyone the user exchanged mail with, read from mail other than this email, so
        /// a stranger's first email never makes its sender known.
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
        /// The best chunks of a project's files for a text, see ChunkSearch.search.
        var search: @Sendable (_ text: String, _ project: UUID, _ limit: Int) async throws -> [ChunkSearch.Hit]
        /// The chunks of a project's newest files, see ChunkSearch.newest.
        var newest: @Sendable (_ project: UUID, _ limit: Int) async throws -> [ChunkSearch.Hit]
        /// A project's files with their start, for FileVersions.
        var files: @Sendable (_ project: UUID) async throws -> [FileVersions.File]
    }

    /// The chunks asked for to fill up the prompt. ChunkSearch.newest gives a file's
    /// chunks in a row, so this many cover the 3 newest files of most projects.
    nonisolated static let newestChunks = 200
    /// The most of the project's other mail asked for, as many as the prompt shows.
    nonisolated static let projectMailLimit = 3

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
    /// Loaded once.
    private var countTokens: (@Sendable (String) -> Int)?

    /// - Parameters:
    ///   - language: the language of explanations, see ProjectsLanguage.forExplanations.
    ///   - now: today, which evaluations pin.
    init(
        lookups: Lookups,
        run: @escaping (ProjectsModelRequest) async throws -> String,
        loadTokenCounter: @escaping @Sendable () async throws -> (@Sendable (String) -> Int)?,
        save: @escaping (Explanation) async -> Void,
        language: ProjectsLanguage,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.lookups = lookups
        self.run = run
        self.loadTokenCounter = loadTokenCounter
        self.save = save
        self.language = language == .zh ? .zh : .en
        self.timeZone = timeZone
        self.now = now
    }

    /// Explains the email, saves the explanation and returns it. Throws
    /// RewriteError.notLoaded when the model is not on this Mac, RewriteError.promptTooLong
    /// when even the trimmed prompt is too long, CancellationError when the caller's task
    /// is cancelled, and what a lookup throws.
    func explain(_ email: Email) async throws -> Explanation {
        let started = ContinuousClock.now
        do {
            let countTokens = try await tokenCounter()
            let known = try await lookups.known(email)
            let project = email.project.flatMap { id in known.projects.first { $0.id == id } }
            let thread = try await lookups.thread(email)
            var gathered = Gathered(email: email, known: known, project: project, thread: thread, today: now())
            if let project {
                let query = Self.searchText(email)
                gathered.hits = try await lookups.search(query, project.id, ExplainPrompt.chunkLimit)
                if gathered.hits.count < ExplainPrompt.fillUpTo {
                    gathered.newest = try await lookups.newest(project.id, Self.newestChunks)
                }
                gathered.files = try await lookups.files(project.id)
                let excluding = Set(thread.map(\.messageID) + [email.messageID])
                gathered.projectMail = try await lookups.projectMail(MailQuery(project: project.id, text: query, excluding: excluding, limit: Self.projectMailLimit))
            }
            try Task.checkCancellation()

            let prepared = await Self.prepare(gathered, language: language, timeZone: timeZone, countTokens: countTokens)
            guard prepared.prompt.tokens <= ExplainPrompt.tokenBudget else { throw RewriteError.promptTooLong }
            let modelStarted = ContinuousClock.now
            let written = try await run(ProjectsModelRequest(prompt: prepared.prompt.text, maximumTokens: ExplainPrompt.maximumTokens, priority: .user))
            let modelTime = modelStarted.duration(to: .now)
            let explanation = await Self.finish(prepared, written: written, timeZone: timeZone)
            await save(explanation)
            Logger.projects.notice("Explained an email in \(Self.seconds(started.duration(to: .now)), privacy: .public), the model took \(Self.seconds(modelTime), privacy: .public): \(Self.summary(prepared.prompt, explanation), privacy: .public)")
            return explanation
        } catch {
            Logger.projects.notice("Explaining an email ended by \(Self.logName(error), privacy: .public) after \(Self.seconds(started.duration(to: .now)), privacy: .public)")
            throw error
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
    }

    /// The prompt and what the checks after the model need.
    nonisolated struct Prepared: Sendable {
        var gathered: Gathered
        var reply: ReplyRule.Decision
        var prompt: ExplainPrompt
        /// Everyone a reply to all reaches, the user left out.
        var recipients: [ExplainPrompt.Person]
    }

    /// Decides the reply, runs the sender and content checks and builds the prompt. Off
    /// the main actor, since the checks, the hygiene and the token counts read long text.
    @concurrent
    nonisolated static func prepare(_ gathered: Gathered, language: ProjectsLanguage, timeZone: TimeZone, countTokens: @Sendable (String) -> Int) async -> Prepared {
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
        var warnings = await ruleWarnings(email, known: known)
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
        input.versions = FileVersions(gathered.files)
        input.filesWithHiddenText = Set((gathered.hits + gathered.newest).filter { $0.fileHiddenRuns > 0 }.map(\.file))
        input.projectMail = gathered.projectMail
        input.thread = gathered.thread
        input.warnings = ProjectsWarning.allCases.filter(Set(warnings).contains)
        let prompt = ExplainPrompt(input, countTokens: countTokens)
        return Prepared(gathered: gathered, reply: reply, prompt: prompt, recipients: recipients)
    }

    /// The warnings about the email that code finds: the sender and content checks, and
    /// hidden text that VisibleText found, in the order of `ProjectsWarning.allCases`.
    @concurrent
    nonisolated static func ruleWarnings(_ email: Email, known: Known) async -> [ProjectsWarning] {
        let own = known.ownAddresses.map { SenderChecks.Person(name: known.ownName, address: $0) }
        let people = known.projects.flatMap { $0.people.map { SenderChecks.Person(name: $0.name, address: $0.address) } } + known.correspondents
        var warnings = Set(SenderChecks.warnings(for: SenderChecks.Input(
            sender: SenderChecks.Person(name: email.sender.name, address: email.sender.address),
            people: people,
            domains: guardedDomains(known.projects),
            own: own
        )))
        warnings.formUnion(await ContentChecks.warnings(for: ContentChecks.Input(
            subject: email.subject,
            text: email.visibleText,
            attachments: email.attachments,
            senderIsKnown: senderIsKnown(email.sender.address, people: people, projects: known.projects),
            own: own,
            sentTexts: known.sentTexts
        )))
        if !email.hiddenText.isEmpty {
            warnings.insert(.hiddenText)
        }
        return ProjectsWarning.allCases.filter(warnings.contains)
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
    /// email's own text, without what PromptHygiene takes out.
    nonisolated static func searchText(_ email: Email) -> String {
        PromptHygiene.withoutMarkers(PromptHygiene(email.subject + "\n" + email.text, source: .mail).text)
    }

    private nonisolated static func chunk(_ hit: ChunkSearch.Hit) -> TextChunker.Chunk {
        TextChunker.Chunk(file: hit.file, page: hit.page, modified: hit.modified, heading: hit.heading, text: hit.text)
    }

    // MARK: After the model

    /// Reads the answer and runs the checks on it. Off the main actor, since the checks
    /// read every source of the prompt.
    @concurrent
    nonisolated static func finish(_ prepared: Prepared, written: String, timeZone: TimeZone) async -> Explanation {
        let gathered = prepared.gathered
        let email = gathered.email
        let prompt = prepared.prompt
        let answer = ExplainAnswer(ExplainPrompt.prefill(prompt.language) + written, sources: prompt.sources.keys)
        let texts = sourceTexts(prepared)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let allSources = [texts.incoming] + texts.other
        let points = answer.points.map { point in
            Explanation.Point(
                text: point.text,
                sources: point.sources,
                flags: OutputChecks.findings(in: point.text, sources: allSources, today: gathered.today, calendar: calendar)
            )
        }

        let draft: Explanation.Draft
        switch prepared.reply {
        case .noReply(let reason):
            draft = .noReply(reason)
        case .reply(let language) where language == .other:
            draft = .noDraft
        case .reply(let language):
            if case .reply(let text) = answer.draft {
                let own = gathered.known.ownAddresses.map { DraftCheckInput.Person(name: gathered.known.ownName, address: $0) }
                let recipients = prepared.recipients.map { DraftCheckInput.Person(name: $0.name, address: $0.address) }
                var people = gathered.project?.people.map { DraftCheckInput.Person(name: $0.name, address: $0.address) } ?? []
                // People at the project's domains count as its people, as in phase 0.
                if let project = gathered.project {
                    people += recipients.filter { isInProject($0.address, project) && !people.contains($0) }
                }
                draft = .checked(await DraftCheck.check(DraftCheckInput(
                    draft: text,
                    language: language,
                    recipients: recipients,
                    projectPeople: people,
                    own: own,
                    incomingText: texts.incoming,
                    sourceTexts: texts.other,
                    questionsForUser: answer.questions,
                    today: gathered.today
                )))
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
            modelWarnings: answer.warnings,
            points: points,
            questions: answer.questions,
            draft: draft,
            sources: prompt.sources,
            removed: prompt.removed,
            problems: answer.problems,
            unknownSources: answer.unknownSources
        )
    }

    /// The texts of the prompt for the checks after the model. `incoming` is what the
    /// recipients of a reply already have: the email with its quoted history, and the
    /// earlier messages of its thread that one of them was on. `other` is the rest of what
    /// the model read: the project's description, the excerpts of its files and the other
    /// mail in the prompt.
    nonisolated static func sourceTexts(_ prepared: Prepared) -> (incoming: String, other: [String]) {
        let gathered = prepared.gathered
        let email = gathered.email
        let reached = Set(prepared.recipients.compactMap { ProjectsAddress.normalized($0.address) })
        var messages: [String: ExplainPrompt.Mail] = [:]
        for mail in gathered.projectMail + gathered.thread {
            messages[mail.messageID] = mail
        }
        var incoming = [email.subject, email.visibleText]
        var other: [String] = []
        if let description = gathered.project?.description, !description.isEmpty {
            other.append(description)
        }
        for id in prepared.prompt.sources.keys.sorted() {
            switch prepared.prompt.sources[id] {
            case .file(let chunk):
                other.append(chunk.text)
            case .message(let messageID):
                guard messageID != email.messageID, let mail = messages[messageID] else { continue }
                let people = ([mail.sender] + mail.to + mail.cc).compactMap { ProjectsAddress.normalized($0.address) }
                let wasOnIt = gathered.thread.contains { $0.messageID == messageID } && mail.date <= email.date && !reached.isDisjoint(with: people)
                if wasOnIt {
                    incoming.append(mail.text)
                } else {
                    other.append(mail.text)
                }
            case nil:
                continue
            }
        }
        return (incoming.joined(separator: "\n\n"), other)
    }

    // MARK: Log

    /// Counts only.
    private nonisolated static func summary(_ prompt: ExplainPrompt, _ explanation: Explanation) -> String {
        let files = prompt.sources.keys.filter { $0.hasPrefix("F") }.count
        let thread = prompt.sources.keys.filter { $0.hasPrefix("T") }.count
        let projectMail = prompt.sources.keys.filter { $0.hasPrefix("M") }.count
        let draft: String
        switch explanation.draft {
        case .checked(let result):
            draft = (result.draft == nil ? "held back" : "checked") + " with \(result.removals.count) removals and \(result.flags.count) flags"
        case .noReply: draft = "no reply due"
        case .noDraft: draft = "no draft for the language"
        case .missing: draft = "missing"
        }
        let flagged = explanation.points.filter { !$0.flags.isEmpty }.count
        return "\(prompt.tokens) prompt tokens with \(files) excerpts, \(thread) thread messages and \(projectMail) project mails, \(explanation.points.count) points of which \(flagged) flagged, \(explanation.questions.count) questions, \(explanation.warnings.count) warnings in code and \(explanation.modelWarnings.count) from the model, draft \(draft), \(explanation.problems.count) problems of form"
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
