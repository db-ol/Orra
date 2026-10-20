import Foundation
import Testing
@testable import Orra

/// The mailbox choice: what each build suggests, the confirm, and what is saved. Each test
/// has preferences of its own, never the real ones.
@MainActor
struct MailChoiceTests {
    static let account = MailEvents.Specifier.textID(MailEvents.Code.account, "5C1E-account", of: .application)
    static let archive = MailMailbox(
        kind: .mailbox,
        reference: .name(MailEvents.Code.mailbox, "Archive", of: account),
        name: "Archive",
        account: "Studio"
    )

    let suite = "io.github.db-ol.OrraTests.mail-choice-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var saved: [String: Any] {
        defaults.persistentDomain(forName: suite) ?? [:]
    }

    /// Release builds suggest the inbox and the sent mailbox, Debug builds nothing, and
    /// neither saves or confirms anything by itself (decision 17).
    @Test(arguments: [false, true])
    func eachBuildSuggestsItsMailboxesAndConfirmsNothing(suggests: Bool) {
        defer { cleanUp() }
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: suggests)
        #expect(choice.mailboxes == (suggests ? [.inbox, .sent] : []))
        #expect(choice.days == 90)
        #expect(!choice.isConfirmed)
        #expect(saved.isEmpty)
    }

    @Test func thisBuildSuggestsWhatItsConfigurationShould() {
        #if DEBUG
        #expect(!MailChoice.suggestsInboxAndSentByDefault)
        #else
        #expect(MailChoice.suggestsInboxAndSentByDefault)
        #endif
    }

    @Test func theConfirmIsSavedAndReadAtTheNextLaunch() {
        defer { cleanUp() }
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        choice.choose([Self.archive])
        #expect(!MailChoice(defaults: defaults, suggestsInboxAndSent: false).isConfirmed)
        choice.confirm()
        #expect(choice.isConfirmed)
        let next = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        #expect(next.isConfirmed)
        #expect(next.mailboxes == [Self.archive])
        #expect(next.mailboxes.first?.name == "Archive")
        #expect(next.mailboxes.first?.account == "Studio")
    }

    /// A suggestion the user confirmed stays chosen, even in a build that suggests nothing.
    @Test func aConfirmedSuggestionIsSavedAsChosen() {
        defer { cleanUp() }
        MailChoice(defaults: defaults, suggestsInboxAndSent: true).confirm()
        let next = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        #expect(next.mailboxes == [.inbox, .sent])
        #expect(next.days == 90)
    }

    @Test func choosingKeepsEachMailboxOnceInItsOrder() {
        defer { cleanUp() }
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: true)
        let renamed = MailMailbox(kind: .mailbox, reference: Self.archive.reference, name: "Archive 2026", account: "Studio")
        choice.choose([.sent, Self.archive, .sent, renamed])
        #expect(choice.mailboxes == [.sent, Self.archive])
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes == [.sent, Self.archive])
        // Unticking every mailbox is saved too, and the suggestion does not come back.
        choice.choose([])
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes == [])
    }

    @Test func onlyTheOfferedDaysAreTaken() {
        defer { cleanUp() }
        #expect(MailChoice.dayChoices == [30, 90, 180, 365])
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: true)
        choice.choose(days: 365)
        #expect(choice.days == 365)
        choice.choose(days: 45)
        #expect(choice.days == 365)
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).days == 365)
        defaults.set(7, forKey: MailChoice.daysKey)
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).days == 90)
    }

    /// A saved choice that cannot be read chooses nothing, so a release build never falls
    /// back to reading the inbox and the sent mailbox the user may have unticked.
    @Test func aSavedChoiceThatCannotBeReadChoosesNothing() {
        defer { cleanUp() }
        defaults.set(Data("not a list".utf8), forKey: MailChoice.mailboxesKey)
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes == [])
        defaults.set("Inbox", forKey: MailChoice.mailboxesKey)
        #expect(MailChoice(defaults: defaults, suggestsInboxAndSent: true).mailboxes == [])
    }

    /// The cleanup steps of the test guide list Orra's preferences that hold "projects".
    @Test func theKeysNameProjects() {
        for key in [MailChoice.mailboxesKey, MailChoice.daysKey, MailChoice.confirmedKey] {
            #expect(key.hasPrefix("projects"))
        }
    }
}
