import Foundation
import os

/// How long Projects keeps mail and drafts, by decision 11 of the phase 1 plan (approved
/// 2026-10-20), and the runs that remove what is older. Every period counts from when Orra
/// read the mail, never from a date the mail gives, so mail read from further back, when
/// the user chose more days, is kept as long as new mail, and a forged date keeps nothing
/// longer.
///
/// - **Mail text, 90 days:** the email's own text, its visible text, the text of its
///   attachments, the words that find it, and its latest explanation, draft versions and
///   the text the user typed into the draft, which hold the text, go 90 days after Orra
///   read the email, and so does the user's choice of files for it, which serves only an
///   explanation of that text.
/// - **The rest of an email, 180 days:** its headers, people, project, marks, warnings and
///   attachment names, types and sizes go with its whole thread, 180 days after Orra read
///   the thread's newest message.
/// - **Drafts, 30 days:** the versions of a draft and the text the user typed into it go 30
///   days after the draft last changed, by a new version or by the user's typing, and so
///   does the first draft, which the explanation holds. The rest of the explanation stays as
///   long as the text, see `Explanation.Draft.expired`. It can be explained again for a new
///   draft while the text is kept.
/// - **Counts of moves, 180 days:** a count goes 180 days after the last move it counted.
///   SortingService already reads such a count as zero after 30 days, so this never changes
///   what sorting sees.
/// - **Gone Message-IDs, 365 days:** see `goneIDs`.
///
/// It runs when Projects starts and then once a day while it runs, see `start(store:)`. What
/// it removes is overwritten in the file, see ProjectsDatabase.compactAfterDeletes. Logs
/// counts only.
nonisolated enum Retention {
    /// What one run removed.
    nonisolated struct Removed: Sendable, Equatable {
        /// Emails whose text went.
        var texts = 0
        var explanations = 0
        /// First drafts taken out of their explanations, which stay.
        var drafts = 0
        var emails = 0
        var draftVersions = 0
        /// Texts the user typed into drafts.
        var editedDrafts = 0
        /// Files the user chose for emails whose text went.
        var chosenFiles = 0
        var tallies = 0
        /// Hashes of Message-IDs of removed mail that no scan can reach any more.
        var goneIDs = 0

        var isEmpty: Bool {
            self == Removed()
        }
    }

    static let day: TimeInterval = 86_400
    /// How often it runs while Projects runs.
    static let interval: Duration = .seconds(86_400)

    static let mailText: TimeInterval = 90 * day
    static let emails: TimeInterval = 180 * day
    static let drafts: TimeInterval = 30 * day
    static let tallies: TimeInterval = 180 * day
    /// How long the hash of a removed email's Message-ID stays after Orra read the email:
    /// the most days a scan reads back, the longest choice of MailChoice. Mail received that
    /// long before is out of every scan's reach, so it is never read again.
    static let goneIDs: TimeInterval = 365 * day

    /// Removes from the store what is older than its period at `now`, in one write.
    @discardableResult
    static func apply(to store: MailStore, now: Date) async throws -> Removed {
        let started = ContinuousClock.now
        func cutoff(_ period: TimeInterval) -> ProjectsDatabase.Value {
            .real(now.addingTimeInterval(-period).timeIntervalSince1970)
        }
        let cutoffs = (text: cutoff(mailText), emails: cutoff(emails), drafts: cutoff(drafts), tallies: cutoff(tallies), now: cutoff(0))
        let removed = try await store.database.transaction { database in
            var removed = Removed()
            // The user's typing changes the draft too. It is saved apart from the email's
            // row, so its time joins the row's here.
            try database.run("""
                UPDATE mail_messages SET draft_changed = (SELECT e.changed FROM mail_edited_drafts e WHERE e.message = mail_messages.id)
                WHERE id IN (
                    SELECT e.message FROM mail_edited_drafts e JOIN mail_messages m ON m.id = e.message
                    WHERE m.draft_changed IS NULL OR e.changed > m.draft_changed
                )
                """)
            // Drafts first, with the first draft that the explanation holds.
            removed.draftVersions = try database.run("""
                DELETE FROM mail_draft_versions WHERE message IN (SELECT id FROM mail_messages WHERE draft_changed < ?)
                RETURNING message
                """, [cutoffs.drafts]).count
            removed.editedDrafts = try database.run("""
                DELETE FROM mail_edited_drafts WHERE message IN (SELECT id FROM mail_messages WHERE draft_changed < ?)
                RETURNING message
                """, [cutoffs.drafts]).count
            for row in try database.run(
                "SELECT id, explanation FROM mail_messages WHERE draft_changed < ? AND explanation_draft = 1", [cutoffs.drafts]
            ) where row.count == 2 {
                guard let id = row[0].integer else { continue }
                if var explanation = MailStore.decoded(Explanation.self, row[1]) {
                    // What the draft check needs goes too, since it serves the draft alone.
                    explanation.draft = .expired
                    explanation.draftCheck = nil
                    try database.run(
                        "UPDATE mail_messages SET explanation = ?, explanation_draft = 0 WHERE id = ?",
                        [.blob(try JSONEncoder().encode(explanation)), .integer(id)])
                    removed.drafts += 1
                } else {
                    // Written by an Orra whose explanations read differently, so it goes whole.
                    try database.run(
                        "UPDATE mail_messages SET explanation = NULL, explained = NULL, explanation_draft = 0 WHERE id = ?",
                        [.integer(id)])
                    removed.explanations += 1
                }
            }
            try database.run("UPDATE mail_messages SET draft_changed = NULL WHERE draft_changed < ?", [cutoffs.drafts])
            // The text, with the explanation and the drafts that hold it.
            removed.draftVersions += try database.run("""
                DELETE FROM mail_draft_versions WHERE message IN (SELECT id FROM mail_messages WHERE saved < ?)
                RETURNING message
                """, [cutoffs.text]).count
            removed.editedDrafts += try database.run("""
                DELETE FROM mail_edited_drafts WHERE message IN (SELECT id FROM mail_messages WHERE saved < ?)
                RETURNING message
                """, [cutoffs.text]).count
            removed.explanations += try database.run("""
                UPDATE mail_messages SET explanation = NULL, explained = NULL, explanation_draft = 0, draft_changed = NULL
                WHERE saved < ? AND explanation IS NOT NULL
                RETURNING id
                """, [cutoffs.text]).count
            removed.texts = try database.run("""
                UPDATE mail_messages SET text = NULL, visible_text = NULL, words = NULL, attachment_text = NULL, draft_changed = NULL
                WHERE saved < ? AND (text IS NOT NULL OR visible_text IS NOT NULL OR words IS NOT NULL OR attachment_text IS NOT NULL)
                RETURNING id
                """, [cutoffs.text]).count
            removed.chosenFiles = try database.run("""
                DELETE FROM mail_chosen_files WHERE message IN (SELECT id FROM mail_messages WHERE saved < ?)
                RETURNING message
                """, [cutoffs.text]).count
            // Whole threads, by the newest message read. Their people and drafts go with them.
            removed.emails = try MailStore.deleteGone(
                where: "thread_root IN (SELECT thread_root FROM mail_messages GROUP BY thread_root HAVING MAX(saved) < ?)",
                [cutoffs.emails], in: database)
            removed.tallies = try database.run("DELETE FROM mail_tallies WHERE last < ? RETURNING project", [cutoffs.tallies]).count
            removed.goneIDs = try database.run("DELETE FROM mail_gone WHERE until < ? RETURNING id_hash", [cutoffs.now]).count
            return removed
        }
        if !removed.isEmpty {
            try await store.database.compactAfterDeletes()
        }
        let seconds = started.duration(to: .now) / .seconds(1)
        Logger.projects.notice("Retention removed the text of \(removed.texts, privacy: .public) emails, \(removed.explanations, privacy: .public) explanations, \(removed.drafts, privacy: .public) first drafts, \(removed.emails, privacy: .public) emails, \(removed.draftVersions, privacy: .public) draft versions, \(removed.editedDrafts, privacy: .public) texts typed into drafts, \(removed.chosenFiles, privacy: .public) chosen files, \(removed.tallies, privacy: .public) counts of moves and \(removed.goneIDs, privacy: .public) gone Message-IDs in \(String(format: "%.3f s", seconds), privacy: .public)")
        return removed
    }

    /// Runs `apply` now and then every `interval` until the task is cancelled, which the
    /// app does when Projects stops. A failed run is logged with its code, and the next one
    /// tries again.
    /// - Parameters:
    ///   - now: the time, which tests set.
    ///   - sleep: waits for a time. Tests pass one that does not.
    ///   - removed: runs after a run that removed something, so the window reads its mail
    ///     again, such as an email whose draft went while it shows.
    static func start(
        store: MailStore,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        removed: @escaping @Sendable () async -> Void = {}
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    if try await !apply(to: store, now: now()).isEmpty {
                        await removed()
                    }
                } catch {
                    MailStore.log(error, "removing old mail and drafts")
                }
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            }
        }
    }
}
