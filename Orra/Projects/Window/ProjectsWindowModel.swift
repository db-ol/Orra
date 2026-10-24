import Foundation
import Observation

/// What the Projects window shows and what the user does there: the list chosen in the
/// sidebar, its newest mail a page at a time with the deadline marks of the explained ones,
/// the selected email, the way back after a source showed another email, a move that waits
/// for the user's yes, the rule offered after moves, the explanations under way, the email
/// view of each email the user opened with the window's one handoff at a time, the line
/// after Explain Selected Message, and Suggested Projects. ProjectsRuntime does the work.
@Observable
final class ProjectsWindowModel {
    /// A line the window shows after an action of the user.
    nonisolated enum Notice: Equatable, Sendable {
        /// What Explain Selected Message found, when it found no email to show.
        case selection(ProjectsRuntime.SelectedMessage)
        case projectNotSaved
        case projectNotForgotten
        case ruleNotSaved
    }

    /// A move from a Move To menu that waits for the user's yes, since it takes away a draft
    /// the user changed, see `requestMove(_:to:)`.
    nonisolated struct PendingMove: Equatable, Sendable {
        var messageID: String
        /// The project, nil for Needs a Project.
        var project: UUID?
    }

    /// Why an explanation did not come.
    nonisolated enum ExplainFailure: Equatable, Sendable {
        /// The cleanup model is not on this Mac, or did not load.
        case noModel
        /// Even the trimmed prompt is too long for the model.
        case tooLong
        case other
    }

    /// An explanation under way or one that failed, by the email's Message-ID.
    nonisolated enum ExplainState: Equatable, Sendable {
        case explaining
        case failed(ExplainFailure)
    }

    /// Where the window was before it showed the email a source cites: the list, how many of
    /// its emails it read, and the email selected there, with the email the source showed.
    private struct Visit {
        var place: MailStore.Place
        var limit: Int
        var messageID: String
        var shown: String
    }

    /// The most visits Back to Previous Email goes back through.
    static let maximumHistory = 20

    let runtime: ProjectsRuntime
    /// The list chosen in the sidebar.
    var place: MailStore.Place? = .needsProject {
        didSet {
            if place != oldValue {
                followed = nil
                selectedMessageID = nil
                rows = []
                total = 0
                limit = MailStore.listPage
            }
        }
    }
    /// The email selected in the list, by its Message-ID.
    var selectedMessageID: String? {
        didSet {
            // The user chose another email, so the one Explain Selected Message showed is
            // not followed any more.
            if let selectedMessageID, selectedMessageID != followed {
                followed = nil
            }
        }
    }
    /// The emails of the chosen list, newest first.
    private(set) var rows: [MailStore.Listed] = []
    /// How many emails the chosen list holds, also those older than `rows`.
    private(set) var total = 0
    /// How many of the newest emails of the chosen list the window reads: a page, a page
    /// more for each Load Older Emails, or down to an older email the window shows.
    private(set) var limit = MailStore.listPage
    /// Counts the times the window showed an email on its own, such as the one a source
    /// cites, so the list scrolls to it.
    private(set) var showCount = 0
    /// The visits the window left to show the email of a source, the newest last, while the
    /// window is open.
    private var history: [Visit] = []
    /// The rule offered after two moves of the same kind, until the user answers.
    var ruleOffer: SortingService.RuleOffer?
    var notice: Notice?
    /// Whether Explain Selected Message reads Mail now.
    private(set) var isReadingSelection = false
    private(set) var explaining: [String: ExplainState] = [:]
    /// The email Explain Selected Message showed. When sorting files it in another list,
    /// that list shows with the email still selected, until the user chooses another email
    /// or list, or moves it.
    @ObservationIgnored private var followed: String?
    /// Counts the explanations made in the window, by Message-ID, so the email view reads
    /// its explanation again.
    private(set) var explained: [String: Int] = [:]
    /// The deadline of each explained email of the list, from its explanation's dates.
    private(set) var deadlines: [String: Date] = [:]
    /// The emails whose deadline was read from their explanation.
    @ObservationIgnored private var deadlinesRead: Set<String> = []
    /// A move that waits for the user's yes.
    var pendingMove: PendingMove?
    /// Counts the times the window let go of its email views, so the email view shown reads
    /// its email again into a new one.
    private(set) var emailViewGeneration = 0
    /// The email view of each email the user opened while the window is open, so edits to
    /// a draft stay while the user looks at other mail.
    @ObservationIgnored private var emailModels: [String: ProjectsEmailModel] = [:]
    /// The handoffs of the window, one at a time for all its emails.
    @ObservationIgnored let handoffs = ProjectsEmailModel.Handoffs()
    /// Makes the actions of an email view, the runtime's in the app.
    @ObservationIgnored private let emailActions: () -> ProjectsEmailModel.Actions
    /// Suggested Projects in the sidebar, while the window is open.
    @ObservationIgnored let suggestions: ProjectSuggestionService

    init(runtime: ProjectsRuntime, emailActions: (() -> ProjectsEmailModel.Actions)? = nil) {
        self.runtime = runtime
        self.emailActions = emailActions ?? { .live(runtime) }
        suggestions = runtime.suggestionService()
    }

    /// The email view of an email, the same one each time while the window is open.
    func emailModel(for messageID: String) -> ProjectsEmailModel {
        if let model = emailModels[messageID] {
            return model
        }
        let model = ProjectsEmailModel(messageID: messageID, actions: emailActions(), handoffs: handoffs)
        emailModels[messageID] = model
        return model
    }

    /// Puts the words of a dictation into the change box of the selected email while it has
    /// the focus, and returns whether it took them (decision 13). They change the draft at
    /// once while Projects runs and the setting for it is on, see
    /// ProjectsSwitch.revisesAfterDictation, and only at the end of a dictation. Paste
    /// Original Text in the menu puts its words in the box and changes nothing, so the words
    /// of one dictation never change the draft twice. The window takes them only while it is
    /// the key window, see ProjectsWindow.takeDictation(_:into:appIsActive:windowIsKey:).
    func takeDictation(_ words: String) -> Bool {
        guard let id = selectedMessageID, let model = emailModels[id], model.changeBoxHasFocus else { return false }
        let revises = runtime.phase == .on && runtime.projects.revisesAfterDictation && runtime.dependencies.isDictating()
        return model.takeDictation(words, revises: revises)
    }

    /// Lets go of the email views with their drafts, translations and answer checks, and
    /// ends their requests, such as when the window closes or a project is forgotten.
    func forgetEmails() {
        for model in emailModels.values {
            model.cancelWork()
        }
        emailModels = [:]
        emailViewGeneration += 1
        deadlines = [:]
        deadlinesRead = []
        history = []
    }

    /// The selected email as the list shows it.
    var selectedEmail: MailStore.Listed? {
        selectedMessageID.flatMap { id in rows.first { $0.messageID == id } }
    }

    /// Whether the chosen list holds older emails than the window read, for Load Older
    /// Emails.
    var hasOlderEmails: Bool {
        rows.count >= limit && total > rows.count
    }

    /// Reads the chosen list again with how many emails it holds. When the selected email,
    /// or the one Explain Selected Message or a source showed, is older than the emails
    /// read, such as an email a source cites, it reads down to that email. When sorting
    /// filed the email Explain Selected Message or a source showed in another list, that
    /// list shows with it.
    func reload() async {
        guard let place else {
            rows = []
            total = 0
            return
        }
        var listed = await runtime.list(place, limit: limit)
        guard place == self.place else { return }
        if let id = followed ?? selectedMessageID, !listed.contains(where: { $0.messageID == id }),
           let found = await runtime.position(of: id), place == self.place {
            if found.place == place {
                // Whole pages, as Load Older Emails reads them.
                limit = max(limit, (found.index / MailStore.listPage + 1) * MailStore.listPage)
                listed = await runtime.list(place, limit: limit)
            } else if id == followed {
                await show(id, in: found.place)
                return
            }
        }
        let total = await runtime.count(place)
        guard place == self.place else { return }
        rows = listed
        self.total = total
        await readDeadlines(listed)
    }

    /// Load Older Emails: reads a page more of the chosen list.
    func loadOlderEmails() async {
        limit += MailStore.listPage
        await reload()
    }

    /// Reads the deadline of each explained email of the list that has none read yet.
    private func readDeadlines(_ rows: [MailStore.Listed]) async {
        let now = runtime.dependencies.now()
        for row in rows {
            // Changes only what differs, since each change makes the window draw again.
            guard row.isExplained else {
                if deadlines[row.messageID] != nil {
                    deadlines[row.messageID] = nil
                }
                deadlinesRead.remove(row.messageID)
                continue
            }
            guard deadlinesRead.insert(row.messageID).inserted else { continue }
            let explanation = await runtime.explanation(for: row.messageID)
            let deadline = explanation.flatMap { ProjectsEmailModel.deadline(of: $0, now: now) }
            if deadlines[row.messageID] != deadline {
                deadlines[row.messageID] = deadline
            }
        }
    }

    /// Shows an email in the window, such as the earlier one a point cites: chooses its
    /// list and selects it. Back to Previous Email returns to the email selected before.
    func show(_ messageID: String) async {
        let left = place.flatMap { place in
            selectedMessageID.map { Visit(place: place, limit: limit, messageID: $0, shown: messageID) }
        }
        await show(messageID, in: await runtime.place(of: messageID))
        if let left, left.messageID != messageID {
            history = Array((history + [left]).suffix(Self.maximumHistory))
        }
    }

    /// The email Back to Previous Email returns to: the one selected before a source showed
    /// the selected email. Nil once the user chose another email or list.
    var previousEmail: String? {
        guard let visit = history.last, visit.shown == selectedMessageID else { return nil }
        return visit.messageID
    }

    /// Back to Previous Email: selects the email `previousEmail` names in its list, read as
    /// far as before. An email that moved meanwhile shows in its list now. The email view
    /// with its draft is the same as before, see `emailModel(for:)`.
    func showPreviousEmail() async {
        guard previousEmail != nil, let visit = history.popLast(),
              let now = await runtime.position(of: visit.messageID)?.place else { return }
        place = now
        if now == visit.place {
            limit = max(limit, visit.limit)
        }
        await show(visit.messageID, in: now)
    }

    /// Shows an email selected in its list, and follows it from there.
    private func show(_ messageID: String, in place: MailStore.Place) async {
        self.place = place
        followed = messageID
        selectedMessageID = messageID
        await reload()
        showCount += 1
    }

    /// Moves an email to a project, or to Needs a Project with nil, and offers a rule after
    /// two moves of the same kind. The window stays on its list. When the moved email was
    /// selected, the next one of the list is.
    func move(_ messageID: String, to project: UUID?) async {
        if messageID == followed {
            followed = nil
        }
        let next = selectedMessageID == messageID ? neighbor(of: messageID) : nil
        let offer = await runtime.move(messageID, to: project)
        if selectedMessageID == messageID, await runtime.place(of: messageID) != place {
            selectedMessageID = next
        }
        if let offer {
            ruleOffer = offer
        }
    }

    /// The email after this one in the list, or before it when it is the last.
    private func neighbor(of messageID: String) -> String? {
        guard let index = rows.firstIndex(where: { $0.messageID == messageID }) else { return nil }
        if index + 1 < rows.count {
            return rows[index + 1].messageID
        }
        return index > 0 ? rows[index - 1].messageID : nil
    }

    /// A move from a Move To menu. A move takes the explanation and the draft away, since
    /// they hold text of the project they were made for (#146). When the user changed the
    /// draft, or the model made versions of it, the move waits for the user's yes.
    func requestMove(_ messageID: String, to project: UUID?) async {
        if await takesDraftAway(messageID) {
            pendingMove = PendingMove(messageID: messageID, project: project)
        } else {
            await move(messageID, to: project)
        }
    }

    /// The user said yes to the move that waited.
    func confirmMove(_ move: PendingMove) async {
        pendingMove = nil
        await self.move(move.messageID, to: move.project)
    }

    /// Whether the user changed the email's draft in this window, or it has versions.
    private func takesDraftAway(_ messageID: String) async -> Bool {
        if let model = emailModels[messageID], model.isEdited || !model.versions.isEmpty {
            return true
        }
        guard rows.first(where: { $0.messageID == messageID })?.isExplained ?? true else { return false }
        return !(await runtime.versions(of: messageID)).isEmpty
    }

    /// Adds the offered rule to its project.
    func acceptRule() async {
        guard let offer = ruleOffer else { return }
        ruleOffer = nil
        do {
            try await runtime.accept(offer)
        } catch {
            notice = .ruleNotSaved
        }
    }

    /// Explains an email, on the user's click.
    func explain(_ messageID: String) async {
        guard explaining[messageID] != .explaining else { return }
        explaining[messageID] = .explaining
        do {
            _ = try await runtime.explain(messageID)
            explaining[messageID] = nil
            explained[messageID, default: 0] += 1
            deadlinesRead.remove(messageID)
            // Decision 9: the answer check of the new draft, once, also when the user went
            // on to other mail meanwhile.
            emailModel(for: messageID).perform { await $0.explained() }
        } catch is CancellationError {
            explaining[messageID] = nil
        } catch RewriteError.notLoaded {
            explaining[messageID] = .failed(.noModel)
        } catch RewriteError.promptTooLong {
            explaining[messageID] = .failed(.tooLong)
        } catch {
            explaining[messageID] = .failed(.other)
        }
    }

    /// Explain Selected Message: finds the message selected in Mail, shows it in its list
    /// and explains it, or says why not (decision 18). It waits a moment for sorting to file
    /// a message the scan just saved, never for the sorting of other mail, so the user's
    /// explanation goes before the background work. Its button stays off until the
    /// explanation started.
    func explainSelectedMessage() async {
        guard !isReadingSelection else { return }
        isReadingSelection = true
        notice = nil
        let found = await runtime.messageSelectedInMail()
        guard case .found(let messageID) = found else {
            isReadingSelection = false
            notice = .selection(found)
            return
        }
        await runtime.waitUntilSorted(messageID)
        await show(messageID, in: await runtime.place(of: messageID))
        isReadingSelection = false
        // Marks the explanation as under way before it first waits.
        await explain(messageID)
    }
}
