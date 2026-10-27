import SwiftUI

/// One step of a setup checklist, in the welcome window and on the Projects page of
/// Settings: its badge, then its title with its words and controls under it. The badge is
/// the step's number until it is done, a spinner while it runs and a check mark after.
///
/// VoiceOver skips the badge and reads the title as a heading, with the step's state as its
/// value, such as "Open the Mail app, Not done yet, heading", so the headings rotor goes
/// from step to step. Each control of the step keeps its own focus.
struct SetupStepRow<Detail: View>: View {
    let number: Int
    let status: SetupChecklist.Status
    let title: LocalizedStringKey
    /// The step the guide talks about, or the first that waits for the user, shown with a
    /// tint.
    var isCurrent = false
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StepBadge(number: number, status: status)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    // A key, so the locale of the environment applies, as the welcome window
                    // sets it for a language picked there.
                    .accessibilityValue(Text(status.spokenKey))
                detail
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            Color.accentColor.opacity(isCurrent ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(-8)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}

extension SetupChecklist.Status {
    /// The state as VoiceOver reads it after a step's title.
    var spokenKey: LocalizedStringKey {
        switch self {
        case .done: "Done"
        case .inProgress: "In progress"
        case .todo: "Not done yet"
        }
    }
}

/// A step's number, its spinner or its check mark. VoiceOver skips it, since the title
/// says the step's state.
private struct StepBadge: View {
    let number: Int
    let status: SetupChecklist.Status

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
            case .todo:
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1.5)
                Text(number, format: .number)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
