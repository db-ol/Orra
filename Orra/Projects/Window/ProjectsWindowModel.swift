import Foundation
import Observation

/// What the Projects window shows and what the user does there: the list chosen in the
/// sidebar, its mail with the deadline marks of the explained ones, the selected email, a
/// move that waits for the user's yes, the rule offered after moves, the explanations under
/// way, the email view of each email the user opened with the window's one handoff at a
/// time, the line after Explain Selected Message, and Suggested Projects. ProjectsRuntime
/// does the work.
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
        /// The cleanup model is not on this Mac.
        case noModel
        /// The cleanup model is on this Mac but could not be loaded.
        case modelNotLoaded
        /// Even the trimmed prompt is too long for the model.
        case tooLong
        case other
    }

    /// An explanation under way or one that failed, by the email's Message-ID.
    nonisolated enum ExplainState: Equatable, Sendable {
        case explaining
        case failed(ExplainFailure)
    }

    let runtime: ProjectsRuntime
    /// The list chosen in the sidebar.
    var place: MailStore.Place? = .needsProject {
        didSet {
            if place != oldValue {
                followed = nil
                selectedMessageID = nil
                rows = []
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
    }

    /// The selected email as the list shows it.
    var selectedEmail: MailStore.Listed? {
        selectedMessageID.flatMap { id in rows.first { $0.messageID == id } }
    }

    /// Reads the chosen list again, and follows the email Explain Selected Message showed
    /// when sorting filed it in another list.
    func reload() async {
        guard let place else {
            rows = []
            return
        }
        let listed = await runtime.list(place)
        guard place == self.place else { return }
        rows = listed
        if let followed, !listed.contains(where: { $0.messageID == followed }) {
            let now = await runtime.place(of: followed)
            if followed == self.followed, place == self.place, now != place {
                await show(followed, in: now)
                return
            }
        }
        await readDeadlines(listed)
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
    /// list and selects it.
    func show(_ messageID: String) async {
        await show(messageID, in: await runtime.place(of: messageID))
    }

    /// Shows an email selected in its list, and follows it from there.
    private func show(_ messageID: String, in place: MailStore.Place) async {
        self.place = place
        followed = messageID
        selectedMessageID = messageID
        await reload()
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
        } catch ProjectsRuntime.Failure.modelNotLoaded {
            explaining[messageID] = .failed(.modelNotLoaded)
        } catch RewriteError.promptTooLong {
            explaining[messageID] = .failed(.tooLong)
        } catch {
            explaining[messageID] = .failed(.other)
        }
    }

    /// Try Loading Again, after the cleanup model could not be loaded: looks at the model's
    /// files and loads it again, then explains the email. A new explanation starts the
    /// draft again, so it is left out when a change or an undo of the draft began
    /// meanwhile. Explain is there again once that is done.
    func loadModelAgain(explaining messageID: String) async {
        guard explaining[messageID] != .explaining else { return }
        explaining[messageID] = .explaining
        await runtime.dependencies.retryLoadingModel()
        explaining[messageID] = nil
        guard emailModels[messageID]?.isBusy != true else { return }
        await explain(messageID)
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
