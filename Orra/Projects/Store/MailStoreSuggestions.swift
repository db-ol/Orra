import Foundation

nonisolated extension MailStore {
    /// The most emails of Needs a Project that Suggested Projects reads, the newest.
    static let maximumSuggestionMail = 2_000

    /// The emails of Needs a Project that sorting may still file, newest first, at most
    /// `limit`, with their To and Cc and their text read `textLength` far, for Suggested
    /// Projects. Mail the user moved there is left out, since sorting never files it again.
    func suggestionMail(limit: Int = MailStore.maximumSuggestionMail, textLength: Int = SuggestionPrompt.textLimit * 4) async throws -> [ProjectSuggestions.Mail] {
        let parameters: [ProjectsDatabase.Value] = [.integer(Int64(max(0, textLength))), .integer(Int64(max(0, limit)))]
        return try await database.transaction { database in
            let rows = try database.run("""
                SELECT id, message_id, mailbox, date, sender_name, sender, subject, thread_root, in_reply_to, refs,
                    list_id, list_unsubscribe, precedence, attachments, substr(text, 1, ?1)
                FROM mail_messages
                WHERE project IS NULL AND (level IS NULL OR level = 'unsure') AND moved_by_user = 0
                ORDER BY date DESC, id DESC LIMIT ?2
                """, parameters)
            var mail: [Int64: ProjectSuggestions.Mail] = [:]
            var order: [Int64] = []
            for row in rows where row.count == 15 {
                guard let id = row[0].integer, let messageID = row[1].text, let date = row[3].real,
                      let senderName = row[4].text, let sender = row[5].text, let subject = row[6].text else { continue }
                order.append(id)
                mail[id] = ProjectSuggestions.Mail(
                    messageID: messageID,
                    date: Date(timeIntervalSince1970: date),
                    sender: ProjectSuggestions.Person(name: senderName, address: sender),
                    subject: subject,
                    text: row[14].text ?? "",
                    attachmentNames: Self.suggestionAttachmentNames(row[13]),
                    mailbox: row[2].text,
                    inReplyTo: Self.suggestionStrings(row[8]),
                    references: Self.suggestionStrings(row[9]),
                    threadRoot: row[7].text ?? messageID,
                    list: ListMail(listID: row[10].text, listUnsubscribe: row[11].text, precedence: row[12].text))
            }
            guard !order.isEmpty else { return [] }
            let ids = String(decoding: try JSONEncoder().encode(order), as: UTF8.self)
            for person in try database.run(
                "SELECT message, name, address FROM mail_people WHERE message IN (SELECT value FROM json_each(?)) AND role IN ('to', 'cc') ORDER BY message, role DESC, position",
                [.text(ids)]) where person.count == 3 {
                guard let message = person[0].integer, let name = person[1].text, let address = person[2].text else { continue }
                mail[message]?.recipients.append(ProjectSuggestions.Person(name: name, address: address))
            }
            return order.compactMap { mail[$0] }
        }
    }

    /// The strings of a JSON array in a column, none when it holds none.
    private static func suggestionStrings(_ value: ProjectsDatabase.Value) -> [String] {
        guard let text = value.text else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    /// The names of the attachments in the attachments column.
    private static func suggestionAttachmentNames(_ value: ProjectsDatabase.Value) -> [String] {
        struct Named: Decodable {
            var name: String
        }
        guard let text = value.text else { return [] }
        return ((try? JSONDecoder().decode([Named].self, from: Data(text.utf8))) ?? []).map(\.name)
    }
}
