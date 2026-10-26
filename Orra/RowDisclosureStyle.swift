import SwiftUI

/// A disclosure whose whole header row opens and closes it: the chevron, the words and the
/// rest of the row, at least 24 points tall, with a light highlight under the pointer. The
/// system style on macOS turns only on its small chevron. The content shows under the
/// header, outside its button, so its text can be selected, and at once, since quoted text
/// can be long. Space presses the header under keyboard navigation, and VoiceOver reads it
/// as a button with Expanded or Collapsed.
///
/// Outside Orra/Projects, since Settings and Report a Problem use it too.
struct RowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(isExpanded: configuration.$isExpanded, label: configuration.label)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }

    /// What VoiceOver reads after the header's words.
    static func state(isExpanded: Bool) -> String {
        isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }

    /// The header row, a view of its own, since a style cannot keep the hover state.
    private struct Header: View {
        @Binding var isExpanded: Bool
        let label: DisclosureGroupStyleConfiguration.Label
        @State private var isHovering = false

        var body: some View {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    label
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .background {
                    if isHovering {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.quinary)
                    }
                }
                // The whole row takes the click, as a row of the sidebar does.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityValue(Text(verbatim: RowDisclosureStyle.state(isExpanded: isExpanded)))
        }
    }
}
