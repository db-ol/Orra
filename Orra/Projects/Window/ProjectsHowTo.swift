import SwiftUI

/// The third column of the Projects window while no email is selected and no project's page
/// shows: how Projects goes from the mailboxes to a reply in Mail, in five steps, with the
/// buttons for the first two. The step about Settings shows only until Start Reading Mail
/// confirmed the mailboxes, with Open Mail first while Mail is closed. The step about
/// projects names Suggested Projects only once the sidebar shows them. It shows at every
/// open until an email is selected, so it keeps no setting of its own. The last line says
/// that Projects changes only its own data.
struct ProjectsHowTo: View {
    /// Whether the mailboxes wait for Start Reading Mail, which the first step is about.
    let showsSetup: Bool
    /// Whether New Project… works now, as under the sidebar.
    let canCreate: Bool
    /// Opens Settings at the Projects page.
    let openSettings: () -> Void
    /// Opens New Project.
    let newProject: () -> Void
    /// Whether the sidebar shows Suggested Projects, which it does only with a suggestion
    /// or while the model names one, see ProjectsSuggestedSection.
    var hasSuggestions = true
    /// Whether Mail runs, as the runtime last read it. While it does not, the first step
    /// offers Open Mail.
    var mailIsRunning = true
    /// Opens the Mail app on the user's click. Nil leaves out Open Mail.
    var openMail: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How to Use Projects")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if showsSetup {
                    step("Open Mail. In Projects Settings, allow Mail access, choose the mailboxes and click Start Reading Mail.", systemImage: "gearshape") {
                        setupButtons
                    }
                }
                step(Self.projectStep(hasSuggestions: hasSuggestions), systemImage: "folder.badge.plus") {
                    Button("New Project…", action: newProject)
                        .disabled(!canCreate)
                }
                step("Select an email and click Explain. If a draft follows, read every line of it and change what you need.", systemImage: "text.magnifyingglass")
                step("In the toolbar, Explain Message Selected in Mail shows and explains the message you selected in Mail.", systemImage: "envelope.badge")
                step("Open Reply in Mail puts the draft on the clipboard. Press ⌘V in the reply window, check the recipients and send it yourself.", systemImage: "arrowshape.turn.up.left")
                Divider()
                Text("Assigning, editing and deleting in Projects change only what it keeps on this Mac, never your mail in Mail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    /// The step about making a project. It names Suggested Projects only while the sidebar
    /// shows them, and before that says that they may come once Projects has read the mail.
    static func projectStep(hasSuggestions: Bool) -> LocalizedStringKey {
        if hasSuggestions {
            "Make a project from a suggestion under Suggested Projects, or with New Project…, and add its folders. Explanations use the files in them."
        } else {
            "Make a project with New Project…, and add its folders and the people you exchange mail with. Explanations use the files in its folders. Once Projects has read your mail, it may also suggest projects in the sidebar."
        }
    }

    /// Open Projects Settings…, with Open Mail before it while Mail is closed. The whole
    /// names in a row while they fit, then the short Settings… of the lines under the list,
    /// and in the third column of a narrow window one under the other.
    @ViewBuilder private var setupButtons: some View {
        if let openMail, !mailIsRunning {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Open Mail", action: openMail)
                    Button("Open Projects Settings…", action: openSettings)
                }
                HStack {
                    Button("Open Mail", action: openMail)
                    Button("Settings…", action: openSettings)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Open Mail", action: openMail)
                    settingsButton
                }
            }
        } else {
            settingsButton
        }
    }

    /// The whole name while it fits, the short one of the lines under the list in the third
    /// column of a narrow window.
    private var settingsButton: some View {
        ViewThatFits(in: .horizontal) {
            Button("Open Projects Settings…", action: openSettings)
            Button("Settings…", action: openSettings)
        }
    }

    private func step(_ text: LocalizedStringKey, systemImage: String) -> some View {
        step(text, systemImage: systemImage) {
            EmptyView()
        }
    }

    /// A step with its icon, and the button that does it under its words, so the two line
    /// up whatever the width of the icon.
    private func step(_ text: LocalizedStringKey, systemImage: String, @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                button()
            }
        }
    }
}
