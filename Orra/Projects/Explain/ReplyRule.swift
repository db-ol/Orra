import Foundation

/// Decides in code whether an email needs a reply, and in which language the draft is
/// written. Code step 1 of phase 0, its largest single gain: the reply decision went from
/// 62 to 88 right of 105, and the reply language from 42 to 49 right of 50.
///
/// No reply is due when the user sent the email, when the user answered it later in its
/// thread, or for list mail. Otherwise the draft is in the language of the email's own
/// text, Chinese or English, read with `ProjectsLanguage.reading(_:)` without the lines that
/// PromptHygiene takes out, so a fake English system line in a Chinese email does not turn
/// the reply into English. An email in another language needs a reply but gets no draft.
/// Of an email that forwards a message, only the sender's own words count, see
/// `QuotedHistory.sendersWords(in:subject:)`, so a Chinese note over a forwarded English
/// mail gets a Chinese draft, and the footer of a forwarded newsletter makes it no list
/// mail.
nonisolated struct ReplyRule: Sendable, Equatable {
    /// Another message of the email's thread.
    nonisolated struct Message: Sendable, Equatable {
        /// The sender's address.
        var sender: String
        var date: Date
    }

    nonisolated enum NoReplyReason: String, Sendable, Equatable, Codable {
        /// The user sent the email.
        case sentByUser
        /// The user answered it later in the thread.
        case answeredLater
        /// It went out to a list or came from a machine.
        case listMail
    }

    nonisolated enum Decision: Sendable, Equatable, Codable {
        case noReply(NoReplyReason)
        /// A reply is due. The language is zh or en for a draft, or other for an email that
        /// gets no draft.
        case reply(ProjectsLanguage)

        /// The language of the draft, or nil when no draft is written.
        var draftLanguage: ProjectsLanguage? {
            if case .reply(let language) = self, language != .other {
                return language
            }
            return nil
        }
    }

    /// The user's own addresses, normalized.
    let ownAddresses: Set<String>

    init(ownAddresses: [String]) {
        self.ownAddresses = Set(ownAddresses.compactMap(ProjectsAddress.normalized))
    }

    /// The decision for one email.
    /// - Parameters:
    ///   - sender: the email's sender, an address or "Name <address>".
    ///   - date: when the email was sent or received.
    ///   - thread: the other messages of its thread.
    ///   - list: its list headers.
    ///   - text: its own text, raw or already through PromptHygiene. It is cleaned here,
    ///     which changes nothing in text that was cleaned before.
    ///   - subject: its subject, read for the language when the text has no letters.
    func decision(sender: String, date: Date, thread: [Message], list: ListMail, text: String, subject: String) -> Decision {
        let address = ProjectsAddress.normalized(sender)
        if isOwn(address) {
            return .noReply(.sentByUser)
        }
        if thread.contains(where: { $0.date > date && isOwn(ProjectsAddress.normalized($0.sender)) }) {
            return .noReply(.answeredLater)
        }
        let words = QuotedHistory.sendersWords(in: text, subject: subject)
        let readable = PromptHygiene.withoutMarkers(PromptHygiene(words, source: .mail).text)
        if list.sign(sender: address ?? "", text: readable) != nil {
            return .noReply(.listMail)
        }
        return .reply(Self.language(text: readable, subject: subject))
    }

    /// The language of the text, or of the subject when the text has no letters. Text and
    /// subject without letters give other.
    static func language(text: String, subject: String) -> ProjectsLanguage {
        if hasLetters(text) {
            return ProjectsLanguage.reading(text)
        }
        let subject = PromptHygiene.withoutMarkers(PromptHygiene(subject, source: .mail).text)
        return hasLetters(subject) ? ProjectsLanguage.reading(subject) : .other
    }

    private func isOwn(_ address: String?) -> Bool {
        address.map(ownAddresses.contains) ?? false
    }

    private static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
}
