import SwiftUI

/// The attachments of an email in the email view, each with its name, and its kind, size and
/// whether Projects read its text on one line below, with a line when hidden text in it was
/// taken out. Nothing here opens an attachment, and its name shows as plain text only.
struct ProjectsAttachmentList: View {
    let attachments: [MailAttachment]

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Attachments")
                    .font(.headline)
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    Row(attachment: attachment)
                }
            }
        }
    }

    struct Row: View {
        let attachment: MailAttachment

        var body: some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: attachment.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(verbatim: ProjectsWindowText.attachmentLine(attachment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if attachment.hiddenRuns > 0 {
                        Label("Hidden text in it was taken out.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: Self.icon(attachment))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        /// A page with lines for an attachment Projects read, a plain page otherwise.
        static func icon(_ attachment: MailAttachment) -> String {
            attachment.state == .read ? "doc.text" : "doc"
        }
    }
}
