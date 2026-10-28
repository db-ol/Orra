import Foundation

extension Explanation {
    /// What a reply to the email needs besides its draft, saved with the explanation when a
    /// reply is due: the files the email asks for, whether Projects knows its sender, and
    /// whom a reply and a reply to all reach. The window offers files for the requests and
    /// names the people a ticked file would reach outside its project. Nothing here holds
    /// more than the email's own words and the addresses of its headers.
    ///
    /// Every field reads leniently, so an explanation saved by a later Orra with another
    /// shape of these facts still reads: a field that is missing or of another shape reads
    /// as empty, and a sender as not known. An explanation saved before 0.6.1 has no facts.
    nonisolated struct ReplyFacts: Sendable, Equatable, Codable {
        /// The files the sender's own words ask for, see FileRequests.find(in:subject:).
        var requests: [FileRequest]
        /// Whether the sender is among the people the user knows or at a domain the user
        /// listed for a project.
        var senderIsKnown: Bool
        /// The addresses a reply reaches: the Reply-To addresses, or the sender without them,
        /// the user's own left out, each as ProjectsAddress.normalized gives it.
        var reply: [String]
        /// The addresses a reply to all reaches, the user's own left out, in the same form.
        var replyAll: [String]

        init(requests: [FileRequest], senderIsKnown: Bool, reply: [String], replyAll: [String]) {
            self.requests = requests
            self.senderIsKnown = senderIsKnown
            self.reply = reply
            self.replyAll = replyAll
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            requests = (try? container?.decodeIfPresent([Lenient<FileRequest>].self, forKey: .requests))?.compactMap(\.value) ?? []
            senderIsKnown = (try? container?.decodeIfPresent(Bool.self, forKey: .senderIsKnown)) ?? false
            reply = (try? container?.decodeIfPresent([String].self, forKey: .reply)) ?? []
            replyAll = (try? container?.decodeIfPresent([String].self, forKey: .replyAll)) ?? []
        }

        /// A value that reads as nil when it does not decode, so one broken request leaves
        /// the others.
        private nonisolated struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
            var value: Value?

            init(from decoder: any Decoder) throws {
                value = try? Value(from: decoder)
            }
        }
    }
}

extension ExplainService {
    /// The facts of a reply, nil when no reply is due. The requests come from the sender's
    /// own words only, see `sendersOwnWords(_:)`, so a request in quoted history, in a
    /// forwarded message, in the signature, in hidden text or in a line to an assistant is
    /// none. Pure, and bounded as FileRequests is.
    nonisolated static func replyFacts(_ prepared: Prepared) -> Explanation.ReplyFacts? {
        guard case .reply = prepared.reply else { return nil }
        let email = prepared.gathered.email
        let known = prepared.gathered.known
        let own = Set(known.ownAddresses.compactMap(ProjectsAddress.normalized))
        func addresses(_ people: [ExplainPrompt.Person]) -> [String] {
            var seen: Set<String> = []
            return people.compactMap { person in
                let address = ProjectsAddress.normalized(person.address) ?? person.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !address.isEmpty, !own.contains(address), seen.insert(address).inserted else { return nil }
                return address
            }
        }
        return Explanation.ReplyFacts(
            requests: FileRequests.find(in: sendersOwnWords(email), subject: email.subject),
            senderIsKnown: senderIsKnown(email, known: known),
            reply: addresses(email.replyTo.isEmpty ? [email.sender] : email.replyTo),
            replyAll: addresses(prepared.recipients)
        )
    }

    /// The words the sender wrote in the email, as the reply rule reads them: its visible
    /// text without quoted history, forwarded messages and the signature, after PromptHygiene,
    /// so hidden text and lines to an assistant are left out too. Only the first part a
    /// request is read in goes through the hygiene. The markers of what the hygiene took out
    /// go, and the blank lines stay, so a greeting on a line of its own, such as 林様, stays
    /// apart from the paragraph after it.
    nonisolated static func sendersOwnWords(_ email: Email) -> String {
        let text = email.visibleText.isEmpty ? email.text : email.visibleText
        let note = QuotedHistory(splitting: text, subject: email.subject).note
        let read = String(note.prefix(FileRequests.readLength * 2))
        var words = PromptHygiene(read, source: .mail).text
        for marker in PromptHygiene.Markers(.zh).all + PromptHygiene.Markers(.en).all {
            words = words.replacingOccurrences(of: marker, with: "")
        }
        return words
    }

    /// Whether the sender asks for a file and is neither the user, nor among the people the
    /// user knows, nor at a domain the user listed: the request for files of a stranger,
    /// which the Warnings name as a request to forward mail or files, and which keeps other
    /// projects' files out of the explanation, see `otherProjectWarnings`.
    nonisolated static func asksAStrangerForFiles(_ email: Email, known: Known) -> Bool {
        guard !senderIsKnown(email, known: known) else { return false }
        return !FileRequests.find(in: sendersOwnWords(email), subject: email.subject).isEmpty
    }

    /// Whether the sender is the user, among the people the user knows, or at a domain the
    /// user listed for a project.
    private nonisolated static func senderIsKnown(_ email: Email, known: Known) -> Bool {
        let own = Set(known.ownAddresses.compactMap(ProjectsAddress.normalized))
        if let address = ProjectsAddress.normalized(email.sender.address), own.contains(address) {
            return true
        }
        let people = known.projects.flatMap { $0.people.map { SenderChecks.Person(name: $0.name, address: $0.address) } } + known.correspondents
        return senderIsKnown(email.sender.address, people: people, projects: known.projects)
    }
}
