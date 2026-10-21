import SwiftUI
import os

extension ProjectsRuntime {
    /// Suggested Projects for the Projects window: the mail of Needs a Project from the
    /// store, named by the model through the queue while the window holds the model.
    func suggestionService() -> SuggestionService {
        SuggestionService(
            lookups: SuggestionService.Lookups(
                mail: { [weak self] in await self?.suggestionMail() ?? [] },
                projects: { [weak self] in self?.projectList.map(\.candidate) ?? [] },
                owner: { [weak self] in await self?.owner() ?? SortingService.Owner(addresses: []) },
                dismissed: { [weak self] in Set(self?.running?.list.dismissedSuggestions ?? []) }
            ),
            ask: { [weak self] request in
                guard let self, let queue = self.running?.queue, self.windowHoldsModel else { throw Failure.windowClosed }
                return try await queue.run(request)
            },
            windowIsOpen: { [weak self] in self?.windowHoldsModel ?? false }
        )
    }

    /// The mail of Needs a Project that sorting may still file, for Suggested Projects.
    private func suggestionMail() async -> [ProjectSuggestions.Mail] {
        guard let store = running?.store else { return [] }
        do {
            return try await store.suggestionMail()
        } catch {
            MailStore.log(error, "reading mail for Suggested Projects")
            return []
        }
    }

    /// Keeps the user's dismissal of a suggestion in the project list, so it does not come
    /// back.
    func dismissSuggestion(_ group: ProjectSuggestions.Group) async throws {
        guard let running else { throw Failure.off }
        try await running.list.dismissSuggestion(ProjectSuggestions.dismissalKey(group.anchor))
    }
}

/// The Suggested Projects section of the Projects window's sidebar, under Needs a Project:
/// each suggestion with the number of emails it would take. A click opens New Project
/// prefilled from it, and its menu dismisses it.
struct ProjectsSuggestedSection: View {
    let runtime: ProjectsRuntime
    let suggestions: SuggestionService
    /// Opens New Project prefilled from a suggestion.
    let create: (SuggestionService.Suggestion) -> Void

    var body: some View {
        if !suggestions.suggestions.isEmpty || suggestions.isNaming {
            Section("Suggested Projects") {
                ForEach(suggestions.suggestions) { suggestion in
                    Button {
                        create(suggestion)
                    } label: {
                        Label {
                            Text(verbatim: suggestion.name)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                    .buttonStyle(.plain)
                    .badge(suggestion.group.takes.count)
                    .help(Text(Self.takes(suggestion)))
                    .accessibilityValue(Text(Self.takes(suggestion)))
                    .contextMenu {
                        Button("Create Project…") {
                            create(suggestion)
                        }
                        Button("Dismiss Suggestion") {
                            Self.dismiss(suggestion, from: suggestions, runtime: runtime)
                        }
                    }
                    .disabled(runtime.phase != .on)
                }
                if suggestions.suggestions.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking for projects in your mail…")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// How many emails a suggestion would take from Needs a Project.
    static func takes(_ suggestion: SuggestionService.Suggestion) -> String {
        String(localized: "Emails it would take from Needs a Project: \(suggestion.group.takes.count)")
    }

    /// Hides a suggestion at once and keeps the dismissal in the project list. When the list
    /// cannot be saved, it stays hidden while the window is open.
    static func dismiss(_ suggestion: SuggestionService.Suggestion, from suggestions: SuggestionService, runtime: ProjectsRuntime) {
        suggestions.dismiss(suggestion.id)
        Task {
            do {
                try await runtime.dismissSuggestion(suggestion.group)
            } catch {
                Logger.projects.error("Suggested Projects: a dismissal was not saved")
            }
        }
    }

    /// What makes the window group its mail again: a change of the mail or the projects,
    /// the model's hold, and the model's arrival.
    struct Reload: Hashable {
        var changes: Int
        var holdsModel: Bool
        var modelIsInstalled: Bool
    }

    /// How long the window waits after a change before it groups again, so the saves of a
    /// scan group once (a guess).
    static let reloadDelay: Duration = .seconds(1)
}
