import Foundation
import Observation
import os

/// Suggested Projects in the Projects window: the groups of Needs a Project that could be
/// projects, named by the model.
///
/// - `refresh()` groups the mail in code, see ProjectSuggestions. The window calls it when
///   it opens and when the mail, Mail's running or the model changes. Refreshes that come
///   while one runs make one more run after it.
/// - The model names each group, those that would take the most emails first, one at a
///   time as background work through ProjectsModelQueue, so it reads each prompt in slices
///   and pauses for a dictation. It names only while the window is open, and a name is kept
///   for the group's anchor while the window stays open. It stops once
///   `ProjectSuggestions.maximumSuggestions` groups show.
/// - A group shows once the model named it. One the model says is no project never shows,
///   and the next group takes its place. While the model is not on this Mac, or gives no
///   usable answer, a group shows with its name in code, see
///   ProjectSuggestions.Group.fallbackName.
/// - Nothing is created here. The window opens New Project prefilled from a suggestion,
///   and the user creates it with a click, see ProjectsSetupView.Draft(suggestion:). Once
///   it is saved, or dismissed, the suggestion is hidden at once.
/// - The prompts are built and the answers read off the main actor, since PromptHygiene
///   reads every value.
///
/// It reads through closures, so it never waits for the store and tests pass fakes. Logs
/// counts and times only.
@Observable
final class ProjectSuggestionService {
    /// What the service reads.
    struct Lookups {
        /// The emails of Needs a Project, see MailStore.suggestionMail(limit:textLength:).
        var mail: () async -> [ProjectSuggestions.Mail]
        /// The user's projects.
        var projects: () -> [SortingCandidate]
        var owner: () async -> SortingService.Owner
        /// The keys of the suggestions the user dismissed, see
        /// ProjectSuggestions.dismissalKey(_:).
        var dismissed: () -> Set<String>
    }

    /// A suggestion as the window shows it.
    nonisolated struct Suggestion: Sendable, Equatable, Identifiable {
        var group: ProjectSuggestions.Group
        var name: String
        /// One line, empty when the model wrote none.
        var description: String
        /// Whether the model named it.
        var isNamed: Bool

        var id: String {
            group.id
        }
    }

    /// The suggestions to show, those that would take the most emails first.
    private(set) var suggestions: [Suggestion] = []
    /// Whether the model names groups now.
    private(set) var isNaming = false

    @ObservationIgnored private let lookups: Lookups
    @ObservationIgnored private let ask: (ProjectsModelRequest) async throws -> String
    @ObservationIgnored private let windowIsOpen: () -> Bool
    /// The groups of the last refresh.
    @ObservationIgnored private var groups: [ProjectSuggestions.Group] = []
    /// The emails of those groups, by Message-ID, for the prompts.
    @ObservationIgnored private var mail: [String: ProjectSuggestions.Mail] = [:]
    @ObservationIgnored private var owner = SortingService.Owner(addresses: [])
    /// What the model said of each group. `invalid` keeps the group's name in code.
    @ObservationIgnored private var namings: [String: ProjectSuggestionPrompt.Answer] = [:]
    /// Whether the model was missing at the last ask.
    @ObservationIgnored private var modelMissing = false
    /// Suggestions the user dismissed or made a project of in this window.
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var namingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - ask: runs a request on the model, ProjectsModelQueue.run in the app.
    ///   - windowIsOpen: whether the Projects window is open and holds the model.
    init(lookups: Lookups, ask: @escaping (ProjectsModelRequest) async throws -> String, windowIsOpen: @escaping () -> Bool) {
        self.lookups = lookups
        self.ask = ask
        self.windowIsOpen = windowIsOpen
    }

    /// Groups the mail of Needs a Project again and names the new groups, and returns once
    /// the groups are read, not waiting for the model.
    func refresh() async {
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            repeat {
                self?.refreshAgain = false
                await self?.regroup()
            } while self?.refreshAgain == true
            // Cleared with no wait after the last check, so a refresh that comes later runs
            // again.
            self?.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// Hides a suggestion the user dismissed. The window keeps the dismissal in the project
    /// list, see ProjectsRuntime.dismissSuggestion(_:).
    func dismiss(_ id: Suggestion.ID) {
        hide(id)
    }

    /// Hides a suggestion the user made a project of, before sorting files its mail and the
    /// grouping leaves it out, so it is not created twice.
    func projectCreated(from id: Suggestion.ID) {
        hide(id)
    }

    /// Waits until the naming under way ends, for tests.
    func untilNamed() async {
        await namingTask?.value
    }

    private func hide(_ id: Suggestion.ID) {
        hidden.insert(id)
        publish()
        startNaming()
    }

    private func regroup() async {
        let started = ContinuousClock.now
        let owner = await lookups.owner()
        let all = await lookups.mail()
        let groups = await ProjectSuggestions.groups(in: all, ownAddresses: owner.addresses, projects: lookups.projects(), dismissed: lookups.dismissed())
        let members = Set(groups.flatMap(\.messageIDs))
        mail = Dictionary(all.filter { members.contains($0.messageID) }.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        self.owner = owner
        self.groups = groups
        publish()
        Logger.projects.notice("Suggested Projects: \(groups.count, privacy: .public) groups of \(all.count, privacy: .public) emails in \(Self.seconds(started.duration(to: .now)), privacy: .public)")
        startNaming()
    }

    /// Shows the first `maximumSuggestions` groups that are neither hidden nor no project,
    /// once named, or with their names in code.
    private func publish() {
        var shown: [Suggestion] = []
        for group in groups where !hidden.contains(group.id) && shown.count < ProjectSuggestions.maximumSuggestions {
            switch namings[group.id] {
            case .project(let name, let description)?:
                shown.append(Suggestion(group: group, name: name, description: description, isNamed: true))
            case .noProject?:
                continue
            case .invalid?:
                shown.append(Suggestion(group: group, name: group.fallbackName, description: "", isNamed: false))
            case nil:
                if modelMissing {
                    shown.append(Suggestion(group: group, name: group.fallbackName, description: "", isNamed: false))
                }
            }
        }
        if shown != suggestions {
            suggestions = shown
        }
    }

    /// The next group to name: the first with no answer yet that is not hidden, while fewer
    /// than `maximumSuggestions` groups before it show.
    private var nextUnnamed: ProjectSuggestions.Group? {
        var shown = 0
        for group in groups where !hidden.contains(group.id) {
            switch namings[group.id] {
            case nil: return group
            case .noProject?: continue
            case .project?, .invalid?: shown += 1
            }
            if shown >= ProjectSuggestions.maximumSuggestions {
                return nil
            }
        }
        return nil
    }

    private func startNaming() {
        guard namingTask == nil, windowIsOpen(), nextUnnamed != nil else { return }
        isNaming = true
        namingTask = Task { [weak self] in
            await self?.nameGroups()
            self?.namingTask = nil
            self?.isNaming = false
        }
    }

    /// Names the groups one at a time while the window is open. It stops when the model is
    /// missing, and when the window closed, which ends background work.
    private func nameGroups() async {
        var named = 0
        let started = ContinuousClock.now
        defer {
            Logger.projects.notice("Suggested Projects: the model answered for \(named, privacy: .public) groups in \(Self.seconds(started.duration(to: .now)), privacy: .public)")
        }
        while let group = nextUnnamed, windowIsOpen(), !Task.isCancelled {
            let prompt = await Self.prompt(for: group, mail: group.messageIDs.compactMap { mail[$0] }, owner: owner)
            do {
                let output = try await ask(ProjectsModelRequest(prompt: prompt, maximumTokens: ProjectSuggestionPrompt.maximumTokens, priority: .background))
                modelMissing = false
                named += 1
                namings[group.id] = await Self.answer(output)
            } catch RewriteError.notLoaded {
                // The model is not on this Mac or did not load. The groups show their names in
                // code, and the next refresh asks again.
                modelMissing = true
                publish()
                return
            } catch {
                // The window closed, which ends background work.
                if error is CancellationError || Task.isCancelled || !windowIsOpen() {
                    return
                }
                // The prompt was too long, an unload dropped the job, or the model failed.
                // The group keeps its name in code, and the next one is asked.
                namings[group.id] = .invalid
            }
            publish()
        }
    }

    /// The prompt for a group, off the main actor.
    @concurrent
    private nonisolated static func prompt(for group: ProjectSuggestions.Group, mail: [ProjectSuggestions.Mail], owner: SortingService.Owner) async -> String {
        ProjectSuggestionPrompt(group: group, mail: mail, ownName: owner.name, ownAddresses: owner.addresses).text
    }

    /// The model's answer, read off the main actor.
    @concurrent
    private nonisolated static func answer(_ output: String) async -> ProjectSuggestionPrompt.Answer {
        ProjectSuggestionPrompt.answer(output)
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }
}
