import Foundation
import Observation

/// The Mail mailboxes Projects reads, how many days back, and whether the user confirmed
/// the choice, saved in three preferences. No mail is read before the user confirms once
/// with Start Reading Mail in Settings (decision 17). After that the user may change the
/// mailboxes and the days without confirming again.
///
/// Until the user chooses, a release build suggests the inbox and the sent mailbox of all
/// accounts, and a Debug build suggests nothing. A Debug run on the maintainer's Mac so
/// reads only a mailbox ticked by hand, such as an imported test mailbox. MailScan also
/// reads the mailboxes linked to a project, and those too only after the confirm.
///
/// Only the chosen mailboxes are saved, never the others the picker lists.
@Observable
final class MailChoice {
    /// The preference that holds the chosen mailboxes, as JSON.
    nonisolated static let mailboxesKey = "projectsMailboxes"
    /// The preference that holds the days.
    nonisolated static let daysKey = "projectsMailDays"
    /// The preference that holds whether the user confirmed the choice.
    nonisolated static let confirmedKey = "projectsMailConfirmed"
    /// The days Settings offers.
    nonisolated static let dayChoices = [30, 90, 180, 365]
    nonisolated static let defaultDays = 90

    /// Whether this build suggests the inbox and the sent mailbox before the user chose.
    /// Only release builds do (decision 17).
    nonisolated static var suggestsInboxAndSentByDefault: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// The chosen mailboxes, or the suggestion while nothing is saved.
    private(set) var mailboxes: [MailMailbox]
    /// How many days back the scan reads, one of `dayChoices`.
    private(set) var days: Int
    /// Whether the user confirmed the choice once.
    private(set) var isConfirmed: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let suggestion: [MailMailbox]

    init(defaults: UserDefaults = .standard, suggestsInboxAndSent: Bool = MailChoice.suggestsInboxAndSentByDefault) {
        self.defaults = defaults
        suggestion = suggestsInboxAndSent ? [.inbox, .sent] : []
        if let data = defaults.object(forKey: Self.mailboxesKey) {
            // A saved value that cannot be read chooses nothing, never the suggestion.
            mailboxes = (data as? Data).flatMap { try? JSONDecoder().decode([MailMailbox].self, from: $0) } ?? []
        } else {
            mailboxes = suggestion
        }
        let savedDays = defaults.integer(forKey: Self.daysKey)
        days = Self.dayChoices.contains(savedDays) ? savedDays : Self.defaultDays
        isConfirmed = defaults.bool(forKey: Self.confirmedKey)
    }

    /// Chooses these mailboxes, each once, in this order, and saves them.
    func choose(_ mailboxes: [MailMailbox]) {
        var seen = Set<MailMailbox>()
        self.mailboxes = mailboxes.filter { seen.insert($0).inserted }
        saveMailboxes()
    }

    /// Chooses how many days back to read and saves it. A value Settings does not offer
    /// changes nothing.
    func choose(days: Int) {
        guard Self.dayChoices.contains(days) else { return }
        self.days = days
        defaults.set(days, forKey: Self.daysKey)
    }

    /// Confirms the choice as it stands, with Start Reading Mail, and saves all of it, so a
    /// suggestion the user confirmed stays as it was.
    func confirm() {
        isConfirmed = true
        saveMailboxes()
        defaults.set(days, forKey: Self.daysKey)
        defaults.set(true, forKey: Self.confirmedKey)
    }

    /// Forgets the mailboxes, the days and the confirm, and removes their preferences, as
    /// Delete All Projects Data should. Nothing is read again before the user confirms
    /// anew, and the suggestion of this build comes back.
    func forget() {
        for key in [Self.mailboxesKey, Self.daysKey, Self.confirmedKey] {
            defaults.removeObject(forKey: key)
        }
        mailboxes = suggestion
        days = Self.defaultDays
        isConfirmed = false
    }

    private func saveMailboxes() {
        // Encoding plain values cannot fail. If it ever did, the old choice stays saved.
        if let data = try? JSONEncoder().encode(mailboxes) {
            defaults.set(data, forKey: Self.mailboxesKey)
        }
    }
}
