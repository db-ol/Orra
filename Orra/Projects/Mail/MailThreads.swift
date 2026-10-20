import Foundation

/// The thread of an email, named by the Message-ID of its root. Mail has no thread id, so
/// threads come from the headers.
///
/// - References lists the thread from its first message, so its first entry is the root.
///   When that message is known, its own root counts, so a thread once joined by subject
///   stays together.
/// - Without References, the message In-Reply-To names: its root when it is known, else
///   itself, as References does with a first entry no one has seen, so a reply that names
///   only its parent joins the replies that list the whole thread.
/// - Else, for a subject that starts with Re:, 回复：, 答复：, AW:, Fwd:, FW: or 转发：, the
///   newest known message with the same subject and the same people within four weeks of
///   this one. The same people means the people of one, the user left out, are all among
///   the people of the other, so a reply to the sender alone still joins a reply to all.
/// - Else the email is the root of its own thread.
nonisolated enum MailThreads {
    /// An email as threading sees it.
    nonisolated struct Message: Sendable, Equatable {
        /// Without angle brackets, as all Message-IDs here.
        var messageID: String
        var inReplyTo: [String] = []
        var references: [String] = []
        /// The subject, decoded.
        var subject: String
        /// The addresses of the sender and the recipients, as
        /// `ProjectsAddress.normalized(_:)` gives them.
        var people: Set<String>
        var date: Date
    }

    /// An email seen before, with the root found for it.
    nonisolated struct Known: Sendable, Equatable {
        var messageID: String
        var root: String
        /// The subject in the form `subjectKey(_:)` gives.
        var subjectKey: String
        var people: Set<String>
        var date: Date
    }

    /// How far apart in time two emails joined by subject may be.
    static let subjectWindow: TimeInterval = 28 * 86_400

    /// The root of the email's thread. `known` finds a message seen before by its
    /// Message-ID, and `sameSubject` the ones seen before with a subject key.
    /// `ownAddresses` are the user's, which every email shares and so never count as a
    /// person in common.
    static func root(
        of message: Message,
        ownAddresses: Set<String>,
        known: (String) -> Known?,
        sameSubject: (String) -> [Known]
    ) -> String {
        let id = message.messageID
        if let first = message.references.first(where: { $0 != id }) {
            return known(first)?.root ?? first
        }
        if let parent = message.inReplyTo.first(where: { $0 != id }) {
            return known(parent)?.root ?? parent
        }
        let subject = subjectKey(message.subject)
        guard subject.isReply, !subject.key.isEmpty else { return id }
        let people = message.people.subtracting(ownAddresses)
        guard !people.isEmpty else { return id }
        let match = sameSubject(subject.key)
            .filter {
                let others = $0.people.subtracting(ownAddresses)
                return $0.messageID != id
                    && !others.isEmpty
                    && (others.isSubset(of: people) || people.isSubset(of: others))
                    && abs($0.date.timeIntervalSince(message.date)) <= subjectWindow
            }
            .max { $0.date < $1.date }
        return match?.root ?? id
    }

    /// The roots of a set of emails, read in date order so each one knows the ones before
    /// it, by Message-ID.
    static func roots(of messages: [Message], ownAddresses: Set<String>) -> [String: String] {
        var byID: [String: Known] = [:]
        var bySubject: [String: [Known]] = [:]
        var roots: [String: String] = [:]
        let ordered = messages.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
        for message in ordered.map(\.element) {
            let root = Self.root(of: message, ownAddresses: ownAddresses, known: { byID[$0] }, sameSubject: { bySubject[$0] ?? [] })
            let key = subjectKey(message.subject).key
            let entry = Known(messageID: message.messageID, root: root, subjectKey: key, people: message.people, date: message.date)
            byID[message.messageID] = entry
            if !key.isEmpty { bySubject[key, default: []].append(entry) }
            roots[message.messageID] = root
        }
        return roots
    }

    /// The subject without the prefixes of replies and forwards, in lowercase with single
    /// spaces, and whether it had such a prefix. Prefixes may repeat, carry a count as in
    /// Re[2]: and end in a full width colon.
    static func subjectKey(_ subject: String) -> (key: String, isReply: Bool) {
        var rest = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        var isReply = false
        for _ in 0..<maximumPrefixes {
            guard let after = withoutPrefix(rest) else { break }
            rest = after
            isReply = true
        }
        let key = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return (key, isReply)
    }

    private static let maximumPrefixes = 10

    private static let prefixes = ["re", "fwd", "fw", "aw", "回复", "答复", "转发"]

    /// The text after one prefix such as "Re: " or "回复：", or nil without one.
    private static func withoutPrefix(_ text: Substring) -> Substring? {
        for prefix in prefixes {
            guard text.prefix(prefix.count + 1).count > prefix.count, text.prefix(prefix.count).lowercased() == prefix else { continue }
            var rest = text.dropFirst(prefix.count)
            // A count, as in Re[2]: or Re(2):
            if let open = rest.first, open == "[" || open == "(" {
                let digits = rest.dropFirst().prefix(while: \.isNumber)
                let close: Character = open == "[" ? "]" : ")"
                guard !digits.isEmpty, rest.dropFirst(1 + digits.count).first == close else { continue }
                rest = rest.dropFirst(2 + digits.count)
            }
            rest = rest.drop { $0 == " " }
            guard let colon = rest.first, colon == ":" || colon == "：" else { continue }
            return rest.dropFirst().drop(while: \.isWhitespace)
        }
        return nil
    }
}
