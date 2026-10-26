import SwiftUI

/// The email itself in the email view, as Mail shows it: To and Cc, its attachments with
/// whether Projects read their text (the email view's only list of them, see
/// ProjectsAttachmentList), the sender's own words with the signature, each message it
/// forwards under that message's own header block, and the text it quotes folded away under
/// Quoted Text. The subject, the sender and the date stand in the header of the email view
/// above it.
///
/// Before the email is explained the view shows it under the header. After that it follows
/// the draft under Original Email, or comes first while the explanation is hidden, so the
/// email's own text never goes out of reach.
///
/// It shows the visible text the scan kept, so text the email hides from its reader is not
/// here. The warnings above it say that it was there. Plain text only, with
/// `Text(verbatim:)`: no HTML, no links that open, no images, and an attachment is a name.
/// It shows the first `shownLength` characters at most, so a long email does not hold up
/// the window while it lays out, and says that Mail has the rest. QuotedHistory finds at
/// most 10 forwarded messages, so the view holds that many blocks at most.
struct ProjectsEmailOriginal: View {
    /// What the view shows, worked out off the main actor from the email the store holds.
    nonisolated struct Content: Sendable, Equatable {
        /// The people of To and Cc, each as "Name <address>" or the address alone.
        var to: [String] = []
        var cc: [String] = []
        /// The sender's own words, before the first forwarded message.
        var note: String
        var signature: String = ""
        var forwards: [QuotedHistory.Forward] = []
        /// The history the email and its forwarded messages quote.
        var quoted: String = ""
        /// Whether the text reached the length the store reads or the length the view shows,
        /// so Mail holds more of it.
        var isCut = false

        /// The characters of the email's text the view shows at most.
        static let shownLength = 20_000

        /// The content of an email, split as QuotedHistory splits it, or nil when the store
        /// keeps none of its text, such as after Retention removed it.
        static func of(_ email: ExplainService.Email) -> Content? {
            let whole = email.visibleText.allSatisfy(\.isWhitespace) ? email.text : email.visibleText
            guard !whole.allSatisfy(\.isWhitespace) else { return nil }
            let text = String(whole.prefix(shownLength))
            let split = QuotedHistory(splitting: text, subject: email.subject)
            func person(_ person: ExplainPrompt.Person) -> String {
                person.name.isEmpty ? person.address : "\(person.name) <\(person.address)>"
            }
            return Content(
                to: email.to.map(person),
                cc: email.cc.map(person),
                note: split.note,
                signature: split.signature,
                // A marker with neither a header nor text shows nothing.
                forwards: split.forwards.filter { $0 != QuotedHistory.Forward() },
                quoted: split.quotedText,
                // The store reads text by its Unicode scalars.
                isCut: text.count < whole.count || whole.unicodeScalars.count >= MailStore.readLength
            )
        }

        /// The content, worked out off the main actor, since an email's text may be long.
        @concurrent
        static func reading(_ email: ExplainService.Email) async -> Content? {
            of(email)
        }
    }

    let content: Content
    /// The attachments with their states, from the list of the window.
    var attachments: [MailAttachment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let people = rows([("To:", content.to.joined(separator: ", ")), ("Cc:", content.cc.joined(separator: ", "))])
            if !people.isEmpty {
                Fields(rows: people)
                Divider()
            }
            if !attachments.isEmpty {
                ProjectsAttachmentList(attachments: attachments)
                Divider()
            }
            if !content.note.isEmpty {
                Self.text(content.note)
            }
            if !content.signature.isEmpty {
                Self.text(content.signature)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(content.forwards.enumerated()), id: \.offset) { _, forward in
                ForwardedMessage(forward: forward)
            }
            if !content.quoted.isEmpty {
                DisclosureGroup("Quoted Text") {
                    Self.text(content.quoted)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .disclosureGroupStyle(RowDisclosureStyle())
            }
            if content.isCut {
                Text("The rest of this email is in Mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mail text as plain text the user can select.
    private static func text(_ value: String) -> some View {
        Text(verbatim: value)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A header row with a value. Empty values have no row.
    struct Row {
        var label: LocalizedStringKey
        var value: String
    }

    private func rows(_ values: [(LocalizedStringKey, String)]) -> [Row] {
        values.filter { !$0.1.isEmpty }.map { Row(label: $0.0, value: $0.1) }
    }

    /// The rows of a header block, the labels in a column of their own as in Mail.
    struct Fields: View {
        let rows: [Row]

        var body: some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        // VoiceOver reads the label with the value, in one stop.
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                        Text(verbatim: row.value)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(row.label) + Text(verbatim: " " + row.value))
                    }
                }
            }
            .font(.callout)
        }
    }

    /// A forwarded message under its own header block, set apart by a bar on its leading
    /// side.
    struct ForwardedMessage: View {
        let forward: QuotedHistory.Forward

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Forwarded Message")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                let header = [
                    Row(label: "From:", value: forward.sender), Row(label: "Date:", value: forward.date),
                    Row(label: "Subject:", value: forward.subject), Row(label: "To:", value: forward.to),
                    Row(label: "Cc:", value: forward.cc),
                ].filter { !$0.value.isEmpty }
                if !header.isEmpty {
                    Fields(rows: header)
                }
                if !forward.text.isEmpty {
                    ProjectsEmailOriginal.text(forward.text)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.quaternary)
                    .frame(width: 3)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Forwarded Message"))
        }
    }
}
