import Foundation
import os

/// Sorts new mail into the user's projects: the rules first, and the model as tie breaker
/// while the Projects window is open (plan section 8).
///
/// Each email goes through these steps, oldest first, so the message a reply answers is
/// filed before the reply:
/// 1. PromptHygiene takes hidden characters, comments, chat template tokens and lines that
///    address an assistant out of the email's text and subject. Lines that ask for a filing
///    never vote and never reach the prompt, see FilingRequests.
/// 2. SortingSignals finds the thread, the user's settings, people seen before, attachment
///    names, the projects' own words and the full text scores.
/// 3. SortingPolicy decides from the rules alone.
/// 4. When the rules leave it to the model and the Projects window is open, the model
///    chooses among the top candidates through ProjectsModelQueue, as background work.
///    With the window closed, the email waits in Needs a Project, and `sortWaiting()` sorts
///    it again once the window opens.
/// 5. SortingPolicy decides with the model's answer. The decision and the reply due mark,
///    see ReplyRule, are saved.
///
/// It reads and saves only through closures, so it never waits for the store and tests pass
/// fakes. The text work runs off the main actor. Batches run one at a time, in the order
/// they came.
///
/// A move by the user is saved and counted by the other side's address and by its domain.
/// After two moves of the same kind to one project, `move(_:to:)` offers a rule. Counts
/// halve for every 30 days without such a move, so an old habit does not win forever.
///
/// Logs counts and times only.
final class SortingService {
    /// One email as the service sorts it, from the mail the scan read.
    nonisolated struct Email: Sendable, Equatable {
        /// The Message-ID, without angle brackets.
        var messageID: String
        /// The sender, an address or "Name <address>".
        var sender: String
        /// The To and Cc addresses.
        var recipients: [String] = []
        var date: Date
        var subject: String
        /// The email's own text: its visible text without quoted history, see VisibleText
        /// and QuotedHistory. The service cleans it with PromptHygiene.
        var text: String
        var attachmentNames: [String] = []
        /// The Mail mailbox it is in, in the form of `SortingInput.mailbox`.
        var mailbox: String? = nil
        /// The Message-IDs of In-Reply-To, without angle brackets.
        var inReplyTo: [String] = []
        /// The Message-IDs of References, oldest first, without angle brackets.
        var references: [String] = []
        /// The list headers.
        var list = ListMail()
    }

    /// The user, from Mail's accounts or the override of a Debug build.
    nonisolated struct Owner: Sendable, Equatable {
        /// The user's own addresses.
        var addresses: [String]
        /// The user's name, for the prompt.
        var name: String? = nil
    }

    /// Where an email seen before was filed.
    nonisolated struct Filed: Sendable, Equatable {
        /// The project, nil for Needs a Project and Set Aside.
        var project: UUID?
        /// Whether the user moved it there.
        var movedByUser = false
    }

    /// Another message of an email's thread, for the reply due mark.
    nonisolated struct ThreadMessage: Sendable, Equatable {
        var messageID: String
        /// The sender, an address or "Name <address>".
        var sender: String
        var date: Date
    }

    /// The moves of one kind to one project, as counted so far.
    nonisolated struct Tally: Sendable, Equatable {
        var count: Int
        /// When the last move of this kind was counted.
        var last: Date

        /// The count at `date`: halved for every `SortingService.fadePeriod` since the last
        /// move.
        func count(at date: Date) -> Int {
            let periods = max(date.timeIntervalSince(last), 0) / SortingService.fadePeriod
            return periods >= Double(Int.bitWidth - 1) ? 0 : count >> Int(periods)
        }
    }

    /// A rule the window offers the user after moves of the same kind.
    nonisolated struct RuleOffer: Sendable, Equatable {
        var project: UUID
        /// `.sender` or `.domain`.
        var rule: SortingCandidate.Rule
    }

    /// What the service reads. Closures, so it never waits for the store and tests pass fakes.
    struct Lookups {
        /// The user's projects. People seen and file names come from the closures below.
        var projects: () async -> [SortingCandidate]
        var owner: () async -> Owner
        /// The names of the files in a project's folders, see FolderIndex.
        var fileNames: (UUID) async -> [String]
        /// Where a message was filed, by its Message-ID, or nil when it is not known or not
        /// sorted yet.
        var filed: (String) async -> Filed?
        /// For these addresses, the projects whose mail held each one before, with the
        /// addresses found in each. Needs a Project and Set Aside do not count.
        var peopleSeen: ([String]) async -> [UUID: Set<String>]
        /// The other messages known in the email's thread, earlier and later ones.
        var thread: (Email) async -> [ThreadMessage]
        /// The full text score of each project for a text, see ChunkSearch.projectScores.
        var scores: @Sendable (String) async -> [UUID: Double]
        /// The emails without a decision, or whose decision waits for the model, see
        /// `SortingDecision.waitsForModel`. Never one the user moved.
        var waiting: () async -> [Email]
        /// The moves of one kind to a project counted so far, nil before the first.
        var tally: (SortingCandidate.Rule, UUID) async -> Tally?
    }

    /// What the service saves. Closures, so it never waits for the store and tests pass fakes.
    struct Saves {
        /// An email's decision, by its Message-ID.
        var decision: (String, SortingDecision) async -> Void
        /// An email's reply due mark, by its Message-ID.
        var reply: (String, ReplyRule.Decision) async -> Void
        /// The user moved an email to a project, or to Needs a Project with nil. Its replies
        /// then only vote for that project, see SortingPolicy.
        var move: (String, UUID?) async -> Void
        var tally: (SortingCandidate.Rule, UUID, Tally) async -> Void
    }

    /// Moves of the same kind to one project before a rule is offered (plan section 8, a
    /// guess).
    nonisolated static let movesForOffer = 2
    /// A count of moves halves after this long without another (a guess).
    nonisolated static let fadePeriod: TimeInterval = 30 * 86_400
    /// The most Message-IDs of In-Reply-To and References looked up for the thread.
    nonisolated static let maximumParentLookups = 20

    private let lookups: Lookups
    private let saves: Saves
    private let windowIsOpen: () -> Bool
    private let ask: (ProjectsModelRequest) async throws -> String
    private let now: () -> Date
    /// The projects prepared for sorting, until they change.
    private var setup: Setup?
    /// Counts the calls of `projectsChanged()`, so a preparation under way is not kept.
    private var setupGeneration = 0
    /// The batch under way or the last one, which the next one waits for.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - windowIsOpen: whether the Projects window is open. The model is asked only while
    ///     it is.
    ///   - ask: runs a request on the model, ProjectsModelQueue.run in the app.
    ///   - now: the time, for the counts of moves.
    init(
        lookups: Lookups,
        saves: Saves,
        windowIsOpen: @escaping () -> Bool,
        ask: @escaping (ProjectsModelRequest) async throws -> String,
        now: @escaping () -> Date = Date.init
    ) {
        self.lookups = lookups
        self.saves = saves
        self.windowIsOpen = windowIsOpen
        self.ask = ask
        self.now = now
    }

    // MARK: Sorting

    /// Sorts new emails, oldest first, after the batch under way. Returns once they are
    /// saved, or when the caller's task is cancelled. The email under way then is not saved.
    func sort(_ emails: [Email]) async {
        await inTurn { await self.process(emails) }
    }

    /// Sorts the emails that wait for the model or were never sorted, such as when the
    /// window opens.
    func sortWaiting() async {
        await inTurn { await self.process(await self.lookups.waiting()) }
    }

    /// Prepares the projects again before the next email. Call it when the projects, their
    /// files or the user's addresses change.
    func projectsChanged() {
        setup = nil
        setupGeneration += 1
    }

    // MARK: Corrections

    /// Saves the user's move of an email, counts it, and returns a rule to offer after
    /// `movesForOffer` moves of the same kind to the same project: a sender rule for the
    /// other side's address, else a domain rule for its domain. A domain of the user's own
    /// addresses, and a rule the project has already, are never offered. An offer starts
    /// the counts of the move again, so a declined offer comes back only after as many
    /// moves again.
    @discardableResult
    func move(_ email: Email, to project: UUID?) async -> RuleOffer? {
        await saves.move(email.messageID, project)
        guard let project else {
            Logger.projects.notice("Sorting: the user moved an email to Needs a Project")
            return nil
        }
        let setup = await currentSetup()
        let own = Set(setup.projects.ownAddresses)
        guard let candidate = setup.projects.candidates.first(where: { $0.id == project }),
              let other = Self.otherSide(of: email, own: own) else {
            Logger.projects.notice("Sorting: the user moved an email, counted nothing")
            return nil
        }
        var kinds: [SortingCandidate.Rule] = [.sender(other)]
        let ownDomains = Set(own.compactMap { Self.domain(of: $0) })
        if let domain = Self.domain(of: other), !ownDomains.contains(domain) {
            kinds.append(.domain(domain))
        }
        let time = now()
        var counts: [Int] = []
        for kind in kinds {
            counts.append((await lookups.tally(kind, project)?.count(at: time) ?? 0) + 1)
        }
        let offered = zip(kinds, counts).first { kind, count in count >= Self.movesForOffer && !candidate.rules.contains(kind) }?.0
        for (kind, count) in zip(kinds, counts) {
            // An offer starts every count of this move again, so a declined sender rule is
            // not followed by a domain rule for the same moves.
            await saves.tally(kind, project, Tally(count: offered == nil ? count : 0, last: time))
        }
        let offer = offered.map { RuleOffer(project: project, rule: $0) }
        Logger.projects.notice("Sorting: the user moved an email, counted \(kinds.count, privacy: .public) kinds, rule offered: \(offer != nil, privacy: .public)")
        return offer
    }

    // MARK: Batches

    /// What sorting compares each email with, until the projects change.
    private nonisolated struct Setup: Sendable {
        let projects: SortingProjects
        let owner: Owner
    }

    /// What the rules found for one email.
    private nonisolated struct Ruled: Sendable {
        var signals: SortingSignals
        var decision: SortingDecision
        /// The prompt, when the decision waits for the model.
        var prompt: SortingPrompt?
        var reply: ReplyRule.Decision
    }

    /// Counts and times of one batch, for the log.
    private struct BatchLog {
        var levels: [SortingLevel: Int] = [:]
        var asked = 0
        var modelTime: Duration = .zero
        var waiting = 0
        /// Decisions not saved, since the user moved the email meanwhile.
        var keptMoves = 0
    }

    /// Runs `work` after the batch before it, and cancels it with the caller's task.
    private func inTurn(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await work()
        }
        tail = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func process(_ emails: [Email]) async {
        guard !emails.isEmpty, !Task.isCancelled else { return }
        let started = ContinuousClock.now
        let setup = await currentSetup()
        let ordered = emails.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        var log = BatchLog()
        var modelIsThere = true
        for email in ordered {
            guard !Task.isCancelled,
                  await sortOne(email, setup: setup, modelIsThere: &modelIsThere, log: &log) else { break }
        }
        let sorted = log.levels.values.reduce(0, +)
        Logger.projects.notice("Sorting: \(sorted, privacy: .public) of \(emails.count, privacy: .public) emails in \(Self.seconds(started.duration(to: .now)), privacy: .public): \(log.levels[.sure] ?? 0, privacy: .public) sure, \(log.levels[.likely] ?? 0, privacy: .public) likely, \(log.levels[.unsure] ?? 0, privacy: .public) unsure, \(log.levels[.setAside] ?? 0, privacy: .public) set aside. The model was asked \(log.asked, privacy: .public) times for \(Self.seconds(log.modelTime), privacy: .public), \(log.waiting, privacy: .public) wait for it, \(log.keptMoves, privacy: .public) moved by the user meanwhile")
    }

    /// Sorts one email and saves what it found. False when the caller's task was cancelled
    /// before the decision was saved.
    private func sortOne(_ email: Email, setup: Setup, modelIsThere: inout Bool, log: inout BatchLog) async -> Bool {
        let parent = await parent(of: email)
        let people = Self.people(of: email, own: Set(setup.projects.ownAddresses))
        let seen = people.isEmpty ? [:] : await lookups.peopleSeen(people)
        let thread = await lookups.thread(email)
        let ruled = await Self.rules(
            for: email, parent: parent, thread: thread,
            projects: setup.projects.withPeopleSeen(seen), owner: setup.owner, scores: lookups.scores)
        var decision = ruled.decision
        if decision.waitsForModel, modelIsThere, windowIsOpen(), let prompt = ruled.prompt {
            let asked = ContinuousClock.now
            log.asked += 1
            do {
                let request = ProjectsModelRequest(prompt: prompt.text, maximumTokens: SortingPrompt.maximumTokens, priority: .background)
                let answer = try await ask(request)
                decision = SortingPolicy.decide(ruled.signals, model: prompt.answer(SortingPrompt.prefill + answer))
            } catch RewriteError.promptTooLong {
                // It never fits, so it goes to Needs a Project rather than wait for ever.
                decision = SortingPolicy.decide(ruled.signals, model: .invalid)
            } catch RewriteError.notLoaded {
                // The model is not on this Mac or not loaded. The rest of the batch waits too.
                modelIsThere = false
            } catch {
                // The window closed, which ends background work, or an unload dropped the job
                // twice. The email waits for the model.
            }
            log.modelTime += asked.duration(to: .now)
        }
        guard !Task.isCancelled else { return false }
        if let filed = await lookups.filed(email.messageID), filed.movedByUser {
            log.keptMoves += 1
        } else {
            await saves.decision(email.messageID, decision)
            log.levels[decision.level, default: 0] += 1
            if decision.waitsForModel {
                log.waiting += 1
            }
        }
        await saves.reply(email.messageID, ruled.reply)
        if ruled.reply == .noReply(.sentByUser) {
            // The user answered the earlier messages of the thread.
            let own = Set(setup.owner.addresses.compactMap(ProjectsAddress.normalized))
            for message in thread where message.date < email.date {
                guard let sender = ProjectsAddress.normalized(message.sender), !own.contains(sender) else { continue }
                await saves.reply(message.messageID, .noReply(.answeredLater))
            }
        }
        return true
    }

    /// The projects prepared for sorting, prepared again after `projectsChanged()`.
    private func currentSetup() async -> Setup {
        if let setup {
            return setup
        }
        let generation = setupGeneration
        let owner = await lookups.owner()
        var candidates = await lookups.projects()
        for index in candidates.indices {
            candidates[index].peopleSeen = []
            candidates[index].fileNames = await lookups.fileNames(candidates[index].id)
        }
        let fresh = Setup(projects: await SortingProjects.prepare(candidates, ownAddresses: owner.addresses), owner: owner)
        if generation == setupGeneration {
            setup = fresh
        }
        return fresh
    }

    /// Where the nearest known message that the email answers was filed: In-Reply-To
    /// first, then References from the newest. Nil when none is known.
    private func parent(of email: Email) async -> Filed? {
        var asked = Set<String>()
        for id in email.inReplyTo + email.references.reversed() where id != email.messageID && !asked.contains(id) {
            guard asked.count < Self.maximumParentLookups else { break }
            asked.insert(id)
            if let filed = await lookups.filed(id) {
                return filed
            }
        }
        return nil
    }

    // MARK: Off the main actor

    /// The rules' decision, the prompt when the decision waits for the model, and the reply
    /// due mark. Off the main actor, since hygiene, the words and the full text search take
    /// a while.
    @concurrent
    private nonisolated static func rules(
        for email: Email,
        parent: Filed?,
        thread: [ThreadMessage],
        projects: SortingProjects,
        owner: Owner,
        scores: @Sendable (String) async -> [UUID: Double]
    ) async -> Ruled {
        let input = SortingInput(
            messageID: email.messageID,
            sender: address(email.sender),
            recipients: email.recipients.map(address),
            subject: cleaned(email.subject),
            text: cleaned(email.text),
            attachmentNames: email.attachmentNames,
            mailbox: email.mailbox,
            parentProject: parent?.project,
            parentMovedByUser: parent?.movedByUser ?? false,
            list: email.list)
        let signals = await SortingSignals.gather(for: input, among: projects, score: scores)
        let decision = SortingPolicy.decide(signals, model: nil)
        let prompt = decision.waitsForModel ? SortingPrompt(input: input, signals: signals, projects: projects, ownName: owner.name) : nil
        let reply = ReplyRule(ownAddresses: owner.addresses).decision(
            sender: email.sender, date: email.date,
            thread: thread.map { ReplyRule.Message(sender: $0.sender, date: $0.date) },
            list: email.list, text: email.text, subject: email.subject)
        return Ruled(signals: signals, decision: decision, prompt: prompt, reply: reply)
    }

    /// The text through PromptHygiene, without the markers that stand where it took text
    /// out, so they neither vote nor reach the prompt. Blank lines stay.
    private nonisolated static func cleaned(_ text: String) -> String {
        var cleaned = PromptHygiene(text, source: .mail).text
        for marker in PromptHygiene.Markers(.en).all {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        return cleaned
    }

    /// The address in its one form, or the text trimmed and lowercased when it is not one
    /// address.
    private nonisolated static func address(_ text: String) -> String {
        ProjectsAddress.normalized(text) ?? SortingText.address(text)
    }

    /// The addresses of the email that are not the user's, each once.
    private nonisolated static func people(of email: Email, own: Set<String>) -> [String] {
        var people: [String] = []
        for address in ([email.sender] + email.recipients).compactMap(ProjectsAddress.normalized)
        where !own.contains(address) && !people.contains(address) {
            people.append(address)
        }
        return people
    }

    /// The other side of an email: its sender, or for mail the user sent its one recipient
    /// who is not the user. Nil when the sender is not one address, or the user wrote to
    /// several people.
    private nonisolated static func otherSide(of email: Email, own: Set<String>) -> String? {
        guard let sender = ProjectsAddress.normalized(email.sender) else { return nil }
        guard own.contains(sender) else { return sender }
        let others = Set(email.recipients.compactMap(ProjectsAddress.normalized)).subtracting(own)
        return others.count == 1 ? others.first : nil
    }

    private nonisolated static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? nil : String(domain)
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }
}
