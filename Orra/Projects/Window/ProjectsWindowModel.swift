import Foundation
import Observation

/// What the Projects window shows and what the user does there: the list chosen in the
/// sidebar, its mail, the selected email, the rule offered after moves, the explanations
/// under way, and the line after Explain Selected Message. ProjectsRuntime does the work.
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

    init(runtime: ProjectsRuntime) {
        self.runtime = runtime
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
        guard let followed, !listed.contains(where: { $0.messageID == followed }) else { return }
        let now = await runtime.place(of: followed)
        guard followed == self.followed, place == self.place, now != place else { return }
        await show(followed, in: now)
    }

    /// Shows an email selected in its list, and follows it from there.
    private func show(_ messageID: String, in place: MailStore.Place) async {
        self.place = place
        followed = messageID
        selectedMessageID = messageID
        await reload()
    }

    /// Moves an email to a project, or to Needs a Project with nil, and offers a rule after
    /// two moves of the same kind.
    func move(_ messageID: String, to project: UUID?) async {
        if messageID == followed {
            followed = nil
        }
        if let offer = await runtime.move(messageID, to: project) {
            ruleOffer = offer
        }
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
