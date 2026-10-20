import SwiftUI

/// The third column of the Projects window while an email is selected. For now it shows the
/// email's sender, date and subject, and explains it on a click, so the list shows its first
/// point (decision 16). The email view of wave 5 (projects-email-view) replaces this body
/// with the project chip, what it says, Before you reply, the draft and the handoff.
///
/// What the email view gets here:
/// - `email`, the row of the list, with its Message-ID, project, level, reasons and marks.
/// - `runtime.explain(_:)` and `runtime.explanation(for:)` for the explanation, and
///   `model.explain(_:)` with `model.explaining` for its state in the window.
/// - `runtime.reviseService(startedAt:)` for each revision, which saves its version as made
///   when the revision started. Each revision runs through `runtime.userRequest(_:)`, so
///   turning Projects off ends it before the files close.
/// - `runtime.handoff` with `runtime.mailReference(for:)` for Open Reply in Mail and Copy.
/// - `model.move(_:to:)` for the project chip.
struct ProjectsEmailArea: View {
    let runtime: ProjectsRuntime
    let model: ProjectsWindowModel
    let email: MailStore.Listed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: email.subject)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: Self.sender(email.sender))
                            .textSelection(.enabled)
                        Spacer()
                        Text(email.date, format: .dateTime.year().month().day().hour().minute())
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Divider()
                if !email.summary.isEmpty {
                    Text(verbatim: email.summary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                explainControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    @ViewBuilder
    private var explainControls: some View {
        let state = model.explaining[email.messageID]
        HStack(spacing: 10) {
            Group {
                if email.isExplained {
                    Button("Explain Again") {
                        Task { await model.explain(email.messageID) }
                    }
                } else {
                    Button("Explain") {
                        Task { await model.explain(email.messageID) }
                    }
                }
            }
            .disabled(state == .explaining || !email.hasText || runtime.phase != .on)
            if state == .explaining {
                ProgressView()
                    .controlSize(.small)
                Text("Explaining…")
                    .foregroundStyle(.secondary)
            }
        }
        if case .failed(let failure)? = state {
            Text(verbatim: ProjectsWindowText.explainFailure(failure))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !email.hasText {
            // Retention removed its text, or it was too large to read.
            Text("This email has no text to explain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sender as "Name <address>", or the address alone.
    static func sender(_ person: MailStore.Person) -> String {
        person.name.isEmpty ? person.address : "\(person.name) <\(person.address)>"
    }
}
