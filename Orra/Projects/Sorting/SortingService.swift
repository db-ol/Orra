import Foundation
import Observation
import os

/// Sorts new mail into the user's projects: the rules first, and the model as tie breaker
/// while the Projects window is open (plan section 8).
///
/// Each email goes through these steps, oldest first, so the message a reply answers is
/// filed before the reply:
/// 1. PromptHygiene takes hidden characters, comments, chat template tokens and lines that
///    address an assistant out of the email's text, subject, attachment names and any
///    sender or recipient that is not one address. Lines that ask for a filing never vote
///    and never reach the prompt, see FilingRequests.
/// 2. SortingSignals finds the thread, the user's settings, people seen before, attachment
///    names, the projects' own words and the full text scores.
/// 3. SortingPolicy decides from the rules alone.
/// 4. When the rules leave it to the model and the Projects window is open, the model
///    chooses among the top candidates through ProjectsModelQueue, as background work.
///    With the window closed, the email waits in Needs a Project, or a likely filing in its
///    project, and `sortWaiting()` sorts it again once the window opens.
/// 5. SortingPolicy decides with the model's answer. The decision and the reply due mark,
///    see ReplyRule, are saved.
///
/// After a change of the projects, `sortAgain(_:after:rulesOnly:)` sorts again the mail the
/// change reaches, filed or not, see ProjectsRuntime. It saves a decision only when it
/// changes, and asks the model only where the change can alter its answer.
///
/// It reads and saves only through closures, so it never waits for the store and tests pass
/// fakes. The text work runs off the main actor. Batches run one at a time, in the order
/// they came, and each email is compared with the projects as they are when its turn
/// comes. `stop()` ends them all.
///
/// A move by the user is saved and counted by the other side's address and by its domain.
/// After two moves of the same kind to one project, `move(_:to:)` offers a rule. A count
/// starts over after 30 days without such a move, as learned word pairs do, so an old
/// habit does not win forever. Moves run one at a time too, apart from the batches, so a
/// move never waits for the model.
///
/// The window shows that sorting works while a batch is not finished, see
/// `unfinishedBatches`.
///
/// Logs counts and times only.
@Observable
final class SortingService {
    /// One email as the service sorts it, from the mail the scan read.
    nonisolated struct Email: Sendable, Equatable {
        /// The Message-ID, without angle brackets.
        var messageID: String
        /// The sender, an address or "Name <address>".
        var sender: String
        /// The To and Cc addresses. Sorting reads the first `maximumRecipients`.
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
        /// Where sorting filed it before, nil for an email never sorted.
        var decided: SortingDecision? = nil
    }

    /// The user, from Mail's accounts or the override of a Debug build.
    nonisolated struct Owner: Sendable, Equatable {
        /// The user's own addresses, in any form ProjectsAddress reads.
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

    /// What a change of the projects touched, so sorting again reads the mail it can reach
    /// and asks the model only where it can alter the answer, see ProjectsRuntime.
    nonisolated struct Change: Sendable, Equatable {
        /// The projects the change touched.
        var projects: Set<UUID> = []
        /// The people and sender rules that a project gained or lost, in the form of
        /// ProjectsAddress.
        var addresses: Set<String> = []
        /// The domains and domain rules that a project gained or lost, trimmed, lowercased
        /// and without a leading @.
        var domains: Set<String> = []
        /// The linked mailboxes that a project gained or lost.
        var mailboxes: Set<String> = []

        /// This change and `other` as one, as when a newer change ends a run of sorting
        /// again before it is done.
        func union(_ other: Change) -> Change {
            Change(
                projects: projects.union(other.projects), addresses: addresses.union(other.addresses),
                domains: domains.union(other.domains), mailboxes: mailboxes.union(other.mailboxes))
        }
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

        /// The count at `date`: zero once more than `SortingService.fadePeriod` passed since
        /// the last move, as CorrectionStore starts a learned word pair over.
        func count(at date: Date) -> Int {
            date.timeIntervalSince(last) > SortingService.fadePeriod ? 0 : count
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
        /// For these addresses, the projects whose mail held one of them before, with those
        /// of the addresses found in each. The addresses are in the form of ProjectsAddress,
        /// at most `maximumRecipients` and the sender. Needs a Project and Set Aside do not
        /// count, and neither does a guess of the model, see MailStore.peopleSeen.
        var peopleSeen: ([String]) async -> [UUID: Set<String>]
        /// The other messages known in the email's thread, earlier and later ones.
        var thread: (Email) async -> [ThreadMessage]
        /// The full text score of each project for a text, see ChunkSearch.projectScores.
        var scores: @Sendable (String) async -> [UUID: Double]
        /// The emails without a decision, whose decision waits for the model, see
        /// `SortingDecision.waitsForModel`, or that `Saves.wait` kept in place, each with
        /// where it is filed. Never one the user moved.
        var waiting: () async -> [Email]
        /// The moves of one kind to a project, as `Saves.tally` saved them, nil before the
        /// first.
        var tally: (SortingCandidate.Rule, UUID) async -> Tally?
    }

    /// What the service saves. Closures, so it never waits for the store and tests pass fakes.
    struct Saves {
        /// Saves an email's decision, by its Message-ID, and says whether it did. The store
        /// saves nothing for an email the user moved, and checks that in the same write (such
        /// as an UPDATE with WHERE moved_by_user = 0), since the user may move the email while
        /// the model thinks. It also saves nothing for a project that no longer exists, such
        /// as after Forget Project, and nothing that takes an email with a draft to another
        /// project, since the user would lose the draft without being asked.
        var decision: (String, SortingDecision) async -> Bool
        /// An email's reply due mark, by its Message-ID.
        var reply: (String, ReplyRule.Decision) async -> Void
        /// The user moved an email to a project, or to Needs a Project with nil. Its replies
        /// then only vote for that project, see SortingPolicy.
        var move: (String, UUID?) async -> Void
        /// The moves of one kind to a project. The store keeps the tally as given, by the
        /// rule and the project, and never fades or resets it. The service does that.
        var tally: (SortingCandidate.Rule, UUID, Tally) async -> Void
        /// Keeps an email where it is filed and marks it to sort again, by its Message-ID,
        /// such as a likely filing while the model cannot answer. The store marks nothing
        /// for an email the user moved.
        var wait: (String) async -> Void = { _ in }
    }

    /// Moves of the same kind to one project before a rule is offered (plan section 8, a
    /// guess).
    nonisolated static let movesForOffer = 2
    /// A count of moves starts over after this long without another (a guess).
    nonisolated static let fadePeriod: TimeInterval = 30 * 86_400
    /// The most Message-IDs of In-Reply-To and References looked up for the thread.
    nonisolated static let maximumParentLookups = 20
    /// The most To and Cc addresses of an email that sorting reads. The headers may hold
    /// tens of thousands, and the prompt shows 10.
    nonisolated static let maximumRecipients = 100
    /// Mail providers whose addresses many unrelated people share, with the domains under
    /// them. A domain rule for one would file all their mail in one project, so only a
    /// sender rule is offered there. Not complete: the user may decline an offer.
    nonisolated static let sharedMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "aol.com", "proton.me",
        "protonmail.com", "gmx.com", "gmx.net", "zoho.com", "yandex.com",
        "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net", "139.com", "sina.com",
        "sina.cn", "sohu.com", "aliyun.com",
        "yahoo.co.jp", "outlook.jp", "hotmail.co.jp", "docomo.ne.jp", "ezweb.ne.jp",
        "softbank.ne.jp", "i.softbank.jp",
        "hotmail.es", "outlook.es", "yahoo.es", "yahoo.com.mx", "hotmail.com.mx",
        "outlook.com.mx", "yahoo.com.ar", "hotmail.com.ar",
    ]

    @ObservationIgnored private let lookups: Lookups
    @ObservationIgnored private let saves: Saves
    @ObservationIgnored private let windowIsOpen: () -> Bool
    @ObservationIgnored private let ask: (ProjectsModelRequest) async throws -> String
    @ObservationIgnored private let now: () -> Date
    /// The projects prepared for sorting, until they change.
    @ObservationIgnored private var setup: Setup?
    /// Counts the calls of `projectsChanged()`, so a preparation under way is not kept.
    @ObservationIgnored private var setupGeneration = 0
    /// The batch under way or the last one, which the next one waits for.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// The batches not finished yet, by their number, which `stop()` cancels.
    private var batches: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var batchCount = 0
    /// The move under way or the last one, which the next one waits for.
    @ObservationIgnored private var lastMove: Task<RuleOffer?, Never>?

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

    /// The batches not finished yet: the one under way and those waiting for it. The window
    /// observes it, and tests wait on it to know that a batch they started waits.
    var unfinishedBatches: Int {
        batches.count
    }

    /// Sorts new emails, oldest first, after the batch under way. Returns once they are
    /// saved, or when the caller's task is cancelled or `stop()` is called. The email under
    /// way then is not saved. A likely filing keeps its place while the model cannot
    /// answer, and waits for it.
    func sort(_ emails: [Email]) async {
        await inTurn { await self.process(emails, pass: .new) }
    }

    /// Sorts the emails that wait for the model or were never sorted, such as when the
    /// window opens.
    func sortWaiting() async {
        await inTurn { await self.process(await self.lookups.waiting(), pass: .new) }
    }

    /// Sorts again, oldest first and after the batch under way, emails that a change of the
    /// projects in `changed` reaches, each with where sorting filed it, see ProjectsRuntime.
    /// An email the rules decide as before is left as it is, with its reply mark.
    /// - With `rulesOnly` the model is never asked. A decision the rules make on their own,
    ///   in a project or in Set Aside, is saved, and a filing of that kind the rules no
    ///   longer make goes to Needs a Project without waiting for the model, so it never
    ///   votes for its old project while the model decides. The others stay as they are.
    /// - Without it, the model is asked about an email the rules leave to it only where the
    ///   change can alter its answer, see `SortingPolicy.asksAgain`, and an answer is saved
    ///   when it differs. A likely filing keeps its place while the model cannot answer,
    ///   and waits for it.
    func sortAgain(_ emails: [Email], after changed: Set<UUID>, rulesOnly: Bool) async {
        await inTurn { await self.process(emails, pass: .again(changed: changed, rulesOnly: rulesOnly)) }
    }

    /// Prepares the projects again before the next email. Call it when the projects, their
    /// files or the user's addresses change.
    func projectsChanged() {
        setup = nil
        setupGeneration += 1
    }

    /// Stops the batch under way and every batch waiting, such as when Projects turns off,
    /// and their callers return. An email whose decision was not saved is sorted again by
    /// a later `sortWaiting()`.
    func stop() {
        for batch in batches.values {
            batch.cancel()
        }
        batches = [:]
        projectsChanged()
        Logger.projects.notice("Sorting: stopped")
    }

    // MARK: Corrections

    /// Saves the user's move of an email, counts it, and returns a rule to offer after
    /// `movesForOffer` moves of the same kind to the same project: a sender rule for the
    /// other side's address, else a domain rule for its domain. A domain of the user's own
    /// addresses or of a shared mail provider, and a rule the project has already, are
    /// never offered. An offer starts the counts of the move again, so a declined offer
    /// comes back only after as many moves again. Moves run one at a time, in the order
    /// they came, so two moves never count from the same tally.
    @discardableResult
    func move(_ email: Email, to project: UUID?) async -> RuleOffer? {
        let previous = lastMove
        let task = Task {
            _ = await previous?.value
            return await self.saveAndCount(Self.limited(email), to: project)
        }
        lastMove = task
        return await task.value
    }

    private func saveAndCount(_ email: Email, to project: UUID?) async -> RuleOffer? {
        await saves.move(email.messageID, project)
        guard let project else {
            Logger.projects.notice("Sorting: the user moved an email to Needs a Project")
            return nil
        }
        let setup = await currentSetup()
        guard let candidate = setup.projects.candidates.first(where: { $0.id == project }),
              let other = Self.otherSide(of: email, own: setup.own) else {
            Logger.projects.notice("Sorting: the user moved an email, counted nothing")
            return nil
        }
        var kinds: [SortingCandidate.Rule] = [.sender(other)]
        if let domain = Self.domain(of: other), Self.mayOffer(domain: domain, own: setup.own) {
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
        /// The user, with the addresses in the form of ProjectsAddress.
        let owner: Owner
        /// The same addresses, to look up.
        let own: Set<String>
    }

    /// How a batch sorts its emails.
    private enum Pass {
        /// New mail or mail that waits: every decision is saved.
        case new
        /// Sorting again after a change of the projects in `changed`, see
        /// `sortAgain(_:after:rulesOnly:)`.
        case again(changed: Set<UUID>, rulesOnly: Bool)
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
        /// Decisions the store did not save, since the user moved the email meanwhile, it
        /// holds a draft, or its project is gone.
        var notSaved = 0
        /// Emails sorted again and left as they were, since their decision stayed the same
        /// or only the model could change it.
        var left = 0
        /// Likely filings kept in their project until the model answers.
        var kept = 0
    }

    /// Runs `work` after the batch before it, and cancels it with the caller's task or
    /// `stop()`.
    private func inTurn(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await work()
        }
        tail = task
        batchCount += 1
        let number = batchCount
        batches[number] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        batches[number] = nil
    }

    private func process(_ emails: [Email], pass: Pass) async {
        guard !emails.isEmpty, !Task.isCancelled else { return }
        let started = ContinuousClock.now
        let ordered = emails.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        var log = BatchLog()
        var modelIsThere = true
        for email in ordered {
            // The projects as they are now, prepared again when they changed meanwhile.
            let setup = await currentSetup()
            guard !Task.isCancelled,
                  await sortOne(Self.limited(email), setup: setup, pass: pass, modelIsThere: &modelIsThere, log: &log) else { break }
        }
        let sorted = log.levels.values.reduce(0, +)
        Logger.projects.notice("Sorting: \(sorted, privacy: .public) of \(emails.count, privacy: .public) emails in \(Self.seconds(started.duration(to: .now)), privacy: .public): \(log.levels[.sure] ?? 0, privacy: .public) sure, \(log.levels[.likely] ?? 0, privacy: .public) likely, \(log.levels[.unsure] ?? 0, privacy: .public) unsure, \(log.levels[.setAside] ?? 0, privacy: .public) set aside. The model was asked \(log.asked, privacy: .public) times for \(Self.seconds(log.modelTime), privacy: .public), \(log.waiting, privacy: .public) wait for it, \(log.notSaved, privacy: .public) not saved since the user moved them, they hold a draft or the project is gone, \(log.left, privacy: .public) left as they were, \(log.kept, privacy: .public) kept in their project until the model answers")
    }

    /// Sorts one email and saves what it found, as `pass` says. False when the caller's task
    /// was cancelled before the decision was saved.
    private func sortOne(_ email: Email, setup: Setup, pass: Pass, modelIsThere: inout Bool, log: inout BatchLog) async -> Bool {
        let parent = await parent(of: email)
        let people = Self.people(of: email, own: setup.own)
        var projects = setup.projects
        projects.seen = people.isEmpty ? [:] : await lookups.peopleSeen(people)
        let thread = await lookups.thread(email)
        let ruled = await Self.rules(
            for: email, parent: parent, thread: thread,
            projects: projects, owner: setup.owner, scores: lookups.scores)
        let before = email.decided
        var decision = ruled.decision
        var asks = decision.waitsForModel
        if case .again(let changed, let rulesOnly) = pass {
            let files = decision.level == .sure || decision.level == .setAside
            let filedBefore = before?.level == .sure || before?.level == .setAside
            if decision == before || (rulesOnly && !files && !filedBefore) {
                // Nothing changed for it, or only the model could change it.
                log.left += 1
                return true
            }
            if rulesOnly, !files {
                // The setting that filed it is gone. It waits for nothing in Needs a Project,
                // so it never votes for its old project while the model decides.
                let reasons = decision.reasons.filter { $0 != .waitingForModel }
                decision.reasons = reasons.isEmpty ? [.noSignal] : reasons
            }
            asks = !rulesOnly && decision.waitsForModel && SortingPolicy.asksAgain(ruled.signals, before: before, changed: changed)
            if decision.waitsForModel, !asks {
                // The change cannot alter the model's answer.
                log.left += 1
                return true
            }
        }
        if asks, modelIsThere, windowIsOpen(), let prompt = ruled.prompt {
            let asked = ContinuousClock.now
            log.asked += 1
            do {
                let request = ProjectsModelRequest(prompt: prompt.text, maximumTokens: SortingPrompt.maximumTokens, priority: .background)
                let answer = try await ask(request)
                decision = SortingPolicy.decide(ruled.signals, model: prompt.answer(SortingPrompt.prefill + answer))
            } catch RewriteError.promptTooLong {
                // It never fits, so it goes to Needs a Project rather than wait for ever. The
                // chip says why, since the model never answered.
                decision = SortingPolicy.decide(ruled.signals, model: .invalid)
                decision.reasons = decision.reasons.map { $0 == .modelAnswerInvalid ? .tooLongForModel : $0 }
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
        if decision.waitsForModel, before?.level == .likely {
            // The model did not answer, so the likely filing keeps its place and waits for it.
            // A right guess never drops to Needs a Project for a closed window.
            await saves.wait(email.messageID)
            log.kept += 1
            guard case .new = pass else { return true }
        } else if case .again = pass, decision == before {
            // The model answered as before.
            log.left += 1
            return true
        } else if await saves.decision(email.messageID, decision) {
            log.levels[decision.level, default: 0] += 1
            if decision.waitsForModel {
                log.waiting += 1
            }
        } else {
            log.notSaved += 1
        }
        await saves.reply(email.messageID, ruled.reply)
        if ruled.reply == .noReply(.sentByUser) {
            // The user answered the earlier messages of the thread.
            for message in thread where message.date < email.date {
                guard let sender = ProjectsAddress.normalized(message.sender), !setup.own.contains(sender) else { continue }
                await saves.reply(message.messageID, .noReply(.answeredLater))
            }
        }
        return true
    }

    /// The projects prepared for sorting, prepared again after `projectsChanged()`, also
    /// when it is called while they are being prepared.
    private func currentSetup() async -> Setup {
        while true {
            if let setup {
                return setup
            }
            let generation = setupGeneration
            let owner = await lookups.owner()
            let own = Set(owner.addresses.compactMap(ProjectsAddress.normalized))
            var candidates = await lookups.projects()
            for index in candidates.indices {
                candidates[index].fileNames = await lookups.fileNames(candidates[index].id)
            }
            let projects = await SortingProjects.prepare(candidates, ownAddresses: own.sorted())
            if generation == setupGeneration {
                let fresh = Setup(projects: projects, owner: Owner(addresses: own.sorted(), name: owner.name), own: own)
                setup = fresh
                return fresh
            }
        }
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
            recipients: email.recipients.map(address).filter { !$0.isEmpty },
            subject: cleaned(email.subject),
            text: cleaned(email.text),
            attachmentNames: email.attachmentNames.map(cleaned).filter { !$0.allSatisfy(\.isWhitespace) },
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

    /// The address in its one form. Text that is not one address is cleaned, trimmed and
    /// lowercased, and empty when the hygiene took all of it out.
    private nonisolated static func address(_ text: String) -> String {
        ProjectsAddress.normalized(text) ?? SortingText.address(cleaned(text))
    }

    /// The email with at most `maximumRecipients` To and Cc addresses, so a header with
    /// thousands costs little.
    private nonisolated static func limited(_ email: Email) -> Email {
        guard email.recipients.count > maximumRecipients else { return email }
        var email = email
        email.recipients = Array(email.recipients.prefix(maximumRecipients))
        return email
    }

    /// The addresses of the email that are not the user's, each once.
    private nonisolated static func people(of email: Email, own: Set<String>) -> [String] {
        var known = own
        var people: [String] = []
        for address in ([email.sender] + email.recipients).compactMap(ProjectsAddress.normalized) where known.insert(address).inserted {
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

    /// Whether a domain rule may be offered for the domain: not one of the user's own, and
    /// not a shared mail provider or a domain under one.
    private nonisolated static func mayOffer(domain: String, own: Set<String>) -> Bool {
        let ownDomains = Set(own.compactMap(Self.domain(of:)))
        return !ownDomains.contains(domain) && !sharedMailDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }
}
