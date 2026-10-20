import Foundation
import os

/// How long Projects keeps mail and drafts, by decision 11 of the phase 1 plan (approved
/// 2026-10-20), and the runs that remove what is older.
///
/// - **Mail text, 90 days:** the email's own text, its visible text, the words that find
///   it, and its latest explanation, which holds the text, go 90 days after Orra read the
///   email. Mail read from further back, when the user chose more days, keeps its text for
///   90 days from the read, never longer.
/// - **The rest of an email, 180 days:** its headers, people, project, marks, warnings and
///   attachment names go 180 days after the newest message of its thread. A date in the
///   future counts as the day Orra read the email, so a wrong date never keeps a thread.
/// - **Drafts, 30 days:** the versions of a draft go 30 days after the draft last changed.
///   The explanation holds the first draft, so an explanation with a draft goes with it.
///   It can be explained again while the text is kept.
/// - **Counts of moves, 180 days:** a count goes 180 days after the last move it counted.
///   SortingService already reads such a count as zero after 30 days, so this never changes
///   what sorting sees.
///
/// It runs when Projects starts and then once a day while it runs, see `start(store:)`. What
/// it removes is overwritten in the file, see ProjectsDatabase.compactAfterDeletes. Logs
/// counts only.
nonisolated struct Retention: Sendable, Equatable {
    /// What one run removed.
    nonisolated struct Removed: Sendable, Equatable {
        /// Emails whose text went.
        var texts = 0
        var explanations = 0
        var emails = 0
        var draftVersions = 0
        var tallies = 0

        var isEmpty: Bool {
            self == Removed()
        }
    }

    static let day: TimeInterval = 86_400
    /// How often it runs while Projects runs.
    static let interval: Duration = .seconds(86_400)

    var mailText: TimeInterval = 90 * day
    var emails: TimeInterval = 180 * day
    var drafts: TimeInterval = 30 * day
    var tallies: TimeInterval = 180 * day

    /// Removes from the store what is older than its period at `now`, in one write.
    @discardableResult
    func apply(to store: MailStore, now: Date) async throws -> Removed {
        let started = ContinuousClock.now
        let cutoffs = (
            text: ProjectsDatabase.Value.real(now.addingTimeInterval(-mailText).timeIntervalSince1970),
            emails: ProjectsDatabase.Value.real(now.addingTimeInterval(-emails).timeIntervalSince1970),
            drafts: ProjectsDatabase.Value.real(now.addingTimeInterval(-drafts).timeIntervalSince1970),
            tallies: ProjectsDatabase.Value.real(now.addingTimeInterval(-tallies).timeIntervalSince1970)
        )
        let removed = try await store.database.transaction { database in
            var removed = Removed()
            // Drafts first, with the explanations that hold them.
            removed.draftVersions = try database.run("""
                DELETE FROM mail_draft_versions WHERE message IN (SELECT id FROM mail_messages WHERE draft_changed < ?)
                RETURNING message
                """, [cutoffs.drafts]).count
            removed.explanations = try database.run("""
                UPDATE mail_messages SET explanation = NULL, explained = NULL, explanation_draft = 0
                WHERE draft_changed < ? AND explanation_draft = 1
                RETURNING id
                """, [cutoffs.drafts]).count
            try database.run("UPDATE mail_messages SET draft_changed = NULL WHERE draft_changed < ?", [cutoffs.drafts])
            // The text, with the explanation that holds it.
            removed.explanations += try database.run("""
                UPDATE mail_messages SET explanation = NULL, explained = NULL, explanation_draft = 0
                WHERE saved < ? AND explanation IS NOT NULL
                RETURNING id
                """, [cutoffs.text]).count
            removed.texts = try database.run("""
                UPDATE mail_messages SET text = NULL, visible_text = NULL, words = NULL
                WHERE saved < ? AND (text IS NOT NULL OR visible_text IS NOT NULL OR words IS NOT NULL)
                RETURNING id
                """, [cutoffs.text]).count
            // Whole threads, by their newest message. Their people and drafts go with them.
            removed.emails = try database.run("""
                DELETE FROM mail_messages WHERE thread_root IN (
                    SELECT thread_root FROM mail_messages GROUP BY thread_root HAVING MAX(MIN(date, saved)) < ?
                )
                RETURNING id
                """, [cutoffs.emails]).count
            removed.tallies = try database.run("DELETE FROM mail_tallies WHERE last < ? RETURNING project", [cutoffs.tallies]).count
            return removed
        }
        if !removed.isEmpty {
            try await store.database.compactAfterDeletes()
        }
        let seconds = started.duration(to: .now) / .seconds(1)
        Logger.projects.notice("Retention removed the text of \(removed.texts, privacy: .public) emails, \(removed.explanations, privacy: .public) explanations, \(removed.emails, privacy: .public) emails, \(removed.draftVersions, privacy: .public) draft versions and \(removed.tallies, privacy: .public) counts of moves in \(String(format: "%.3f s", seconds), privacy: .public)")
        return removed
    }

    /// Runs `apply` now and then every `interval` until the task is cancelled, which the
    /// app does when Projects stops. A failed run is logged with its code, and the next one
    /// tries again.
    /// - Parameters:
    ///   - now: the time, which tests set.
    ///   - sleep: waits for a time. Tests pass one that does not.
    func start(
        store: MailStore,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    try await apply(to: store, now: now())
                } catch {
                    MailStore.log(error, "removing old mail and drafts")
                }
                do {
                    try await sleep(Self.interval)
                } catch {
                    return
                }
            }
        }
    }
}
