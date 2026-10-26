import SwiftUI

extension ProjectsEmailArea {
    /// The draft and its tools, in the email's language:
    /// - the draft as plain text the user may edit, with Show in My Language beside it, or
    ///   under it in a narrow window, the tone, and the flags of the draft check inline.
    ///   "Drafts need checking" always shows. The toggle names the language it shows. Saved
    ///   on this Mac shows once the store keeps the user's changes, never before, and its
    ///   line keeps its place while a save waits. The editor waits while the email is
    ///   explained again, which replaces the draft.
    /// - the answer check, such as "They asked 3 things, your draft answers 2", and the
    ///   people outside the project a reply to all reaches
    /// - Open Reply in Mail, Reply All and Copy, with the line above them that says to press
    ///   Command V in Mail, and the hint again after the handoff. There is no Send button.
    /// - the change box, which makes a new version, and the newest change highlighted, with
    ///   Undo. The talk key's words go straight into it while it has the focus (decision 13),
    ///   see ProjectsWindow.takeDictation(_:). A change under way shows why it waits, if it
    ///   does, and Cancel Change. Copy takes the draft as it is meanwhile.
    ///
    /// Without a draft it says why: no reply is due, the language gets no draft, or the model
    /// wrote none. The requests run through `ProjectsEmailModel.perform(_:)`, so closing the
    /// window ends them.
    struct DraftSection: View {
        let runtime: ProjectsRuntime
        let emailModel: ProjectsEmailModel
        let explanation: Explanation
        /// Whether the email is explained again, which replaces the draft.
        let isExplaining: Bool
        /// The width of the draft's column, for putting the translation beside the editor or
        /// under it.
        @State private var width: CGFloat = 0

        /// The narrowest column that holds the editor and the translation side by side.
        static let sideBySideWidth: CGFloat = 560

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Draft")
                    .font(.headline)
                if emailModel.hasDraft {
                    draft
                } else if let why = ProjectsWindowText.noDraft(explanation.draft) {
                    Text(verbatim: why)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        @ViewBuilder
        private var draft: some View {
            @Bindable var emailModel = emailModel
            let isOn = runtime.phase == .on
            HStack(spacing: 12) {
                Menu("Tone") {
                    ForEach(RevisePrompt.Tone.allCases, id: \.self) { tone in
                        Button {
                            emailModel.perform { await $0.makeChange(.tone(tone)) }
                        } label: {
                            Text(verbatim: ProjectsWindowText.tone(tone))
                        }
                    }
                }
                .fixedSize()
                .disabled(emailModel.isBusy || !isOn)
                if emailModel.offersTranslation {
                    Toggle(isOn: Binding(
                        get: { emailModel.showsTranslation },
                        set: { shows in emailModel.perform { await $0.showTranslation(shows) } }
                    )) {
                        Text(verbatim: ProjectsWindowText.showTranslation(in: emailModel.translationLanguage))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!isOn)
                }
            }
            Label("Drafts need checking. Read every line before you send it.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let sideBySide = width >= Self.sideBySideWidth
            let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                TextEditor(text: $emailModel.text)
                    .font(.body)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    // What the user types while the email is explained again would go with
                    // the draft it replaces.
                    .disabled(emailModel.isBusy || isExplaining)
                if emailModel.offersTranslation, emailModel.showsTranslation {
                    translation
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            switch emailModel.saveNote {
            case .saved?:
                Text(verbatim: ProjectsWindowText.save(.saved))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .notSaved?:
                warningLine(ProjectsWindowText.save(.notSaved))
                    .font(.callout)
            case nil:
                // The line keeps its place while a save waits, so what is under it stays
                // put while the user types.
                if emailModel.isEdited || !emailModel.versions.isEmpty {
                    Text(verbatim: ProjectsWindowText.save(.saved))
                        .font(.callout)
                        .hidden()
                }
            }
            checks
            answers
            handoff
            // One box for each email, so the focus of one never passes to the next.
            ChangeBox(runtime: runtime, emailModel: emailModel)
                .id(ObjectIdentifier(emailModel))
            if let change = emailModel.lastChange {
                changes(change.segments, version: change.version)
            }
        }

        // MARK: Checks

        @ViewBuilder
        private var checks: some View {
            let result = emailModel.draftCheck
            let flags = emailModel.flags
            let removals = result?.removals ?? []
            if !flags.isEmpty || !removals.isEmpty || !emailModel.outsideRecipients.isEmpty || !dropped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !emailModel.outsideRecipients.isEmpty {
                        warningLine(ProjectsWindowText.outsideRecipients(emailModel.outsideRecipients))
                    }
                    ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                        warningLine(ProjectsWindowText.flag(flag))
                    }
                    ForEach(Array(removals.enumerated()), id: \.offset) { _, removal in
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(verbatim: ProjectsWindowText.removal(removal.kind))
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "scissors")
                            }
                            Text(verbatim: removal.text)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .padding(.leading, 26)
                        }
                    }
                    if !dropped.isEmpty {
                        warningLine(dropped)
                    }
                }
                .font(.callout)
            }
        }

        /// The placeholders the newest version left out of the draft before it.
        private var dropped: String {
            guard let version = emailModel.versions.last?.version, !version.droppedPlaceholders.isEmpty else { return "" }
            if case .tone = version.change {
                return ProjectsWindowText.dropped(version.droppedPlaceholders, tone: true)
            }
            return ProjectsWindowText.dropped(version.droppedPlaceholders, tone: false)
        }

        private func warningLine(_ text: String) -> some View {
            Label {
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        // MARK: The translation

        @ViewBuilder
        private var translation: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let current = emailModel.currentTranslation {
                    Text(verbatim: current.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let older = emailModel.translation {
                    Text(verbatim: older.text)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if emailModel.isTranslating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Translating…")
                            .foregroundStyle(.secondary)
                    }
                } else if emailModel.currentTranslation == nil {
                    if let note = emailModel.translationNote {
                        Text(verbatim: ProjectsWindowText.note(note, for: .translation))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Translate Again") {
                        emailModel.perform { await $0.translate() }
                    }
                    .disabled(runtime.phase != .on || emailModel.isBusy)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }

        // MARK: The answer check

        @ViewBuilder
        private var answers: some View {
            if let answers = emailModel.currentAnswers {
                if answers.asked > 0 {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(answers.questions.enumerated()), id: \.offset) { _, question in
                                LabeledContent {
                                    Text(verbatim: ProjectsWindowText.status(question.status))
                                        .foregroundStyle(question.status == .answered ? Color.secondary : Color.orange)
                                } label: {
                                    Text(verbatim: question.text)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    } label: {
                        Text(verbatim: ProjectsWindowText.answers(asked: answers.asked, answered: answers.answered))
                    }
                    .disclosureGroupStyle(RowDisclosureStyle())
                }
            } else if emailModel.isCheckingAnswers {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking which questions the draft answers…")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    if let note = emailModel.answersNote {
                        Text(verbatim: ProjectsWindowText.note(note, for: .answers))
                            .foregroundStyle(.secondary)
                    }
                    Button("Check Answers") {
                        emailModel.perform { await $0.checkAnswers() }
                    }
                    .disabled(runtime.phase != .on || emailModel.isBusy)
                }
            }
        }

        // MARK: The change box

        /// The change box with Change Draft, under it in a narrow column, and the change under
        /// way with why it waits and Cancel Change, or why the last one gave nothing. It tells
        /// the email view while it has the focus, so the talk key's words go there. It stays
        /// open to typing and to the talk key while a change runs, so it keeps the focus.
        /// Words said meanwhile change the draft next, see
        /// ProjectsEmailModel.takeDictation(_:revises:).
        private struct ChangeBox: View {
            let runtime: ProjectsRuntime
            let emailModel: ProjectsEmailModel
            @FocusState private var isFocused: Bool
            /// The width of the box, for putting Change Draft beside the field or under it.
            @State private var width: CGFloat = 0

            /// The narrowest box that holds the field and Change Draft side by side.
            static let sideBySideWidth: CGFloat = 300

            var body: some View {
                @Bindable var emailModel = emailModel
                VStack(alignment: .leading, spacing: 10) {
                    // One layout that changes, so the field keeps its focus at any width.
                    let layout = width >= Self.sideBySideWidth ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    layout {
                        TextField("Say what to change", text: $emailModel.instruction, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($isFocused)
                            .onSubmit {
                                emailModel.perform { await $0.applyInstruction() }
                            }
                        Button("Change Draft") {
                            emailModel.perform { await $0.applyInstruction() }
                        }
                        .disabled(emailModel.isBusy || runtime.phase != .on || emailModel.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    if emailModel.changing != nil || emailModel.isUndoing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Changing the draft…")
                                .foregroundStyle(.secondary)
                            // An undo puts the saved text back at once, so only a change can
                            // be cancelled.
                            if emailModel.changing != nil {
                                Button("Cancel Change") {
                                    emailModel.cancelChange()
                                }
                            }
                        }
                        // Why the change waits, such as for a dictation or Live Captions.
                        if emailModel.changing != nil, let pause = runtime.pause {
                            Text(verbatim: ProjectsWindowText.pause(pause))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let note = emailModel.changeNote {
                        Text(verbatim: ProjectsWindowText.note(note, for: .change))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: isFocused, initial: true) { _, focused in
                    emailModel.changeBoxHasFocus = focused
                }
                .onDisappear {
                    emailModel.changeBoxHasFocus = false
                }
            }
        }

        /// The newest version with what it changed highlighted, and Undo.
        private func changes(_ segments: [ProjectsDraftDiff.Segment], version: MailStore.DraftVersion) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                let title = Text("Changes in version \(version.number)")
                    .font(.subheadline.weight(.semibold))
                // Undo Change goes under the title in a column too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        title
                        Spacer()
                        undoButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        title
                        undoButton
                    }
                }
                if ProjectsDraftDiff.hasChanges(segments) {
                    // VoiceOver reads what went and what came, which the marks show.
                    Text(Self.highlighted(segments))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: ProjectsWindowText.changeSummary(segments)))
                } else {
                    Text("The new version reads the same.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }

        private var undoButton: some View {
            Button("Undo Change") {
                emailModel.perform { await $0.undo() }
            }
            .disabled(emailModel.isBusy)
        }

        /// The segments as plain text, what came new marked and what went struck through.
        /// Made from plain strings, so it holds no Markdown or links.
        static func highlighted(_ segments: [ProjectsDraftDiff.Segment]) -> AttributedString {
            var text = AttributedString()
            for segment in segments {
                var part = AttributedString(segment.text)
                switch segment.kind {
                case .same:
                    break
                case .added:
                    part.backgroundColor = Color.accentColor.opacity(0.25)
                case .removed:
                    part.strikethroughStyle = .single
                    part.foregroundColor = Color.secondary
                }
                text += part
            }
            return text
        }

        // MARK: The handoff

        @ViewBuilder
        private var handoff: some View {
            // Said before the click, since Mail comes to the front then and the line after
            // the handoff may go unseen.
            Text("Open Reply in Mail puts the draft on the clipboard. Press ⌘V in the reply window, check the recipients and send it yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // One under another in a column too narrow for a row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    handoffButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    handoffButtons
                }
            }
            if let note = emailModel.handoffNote {
                Text(verbatim: ProjectsWindowText.handoff(note))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        /// Open Reply in Mail, Reply All and Copy, and a spinner while the reply opens.
        @ViewBuilder
        private var handoffButtons: some View {
            Group {
                Button("Open Reply in Mail") {
                    emailModel.perform { await $0.openReply(all: false) }
                }
                if emailModel.offersReplyAll {
                    Button("Reply All") {
                        emailModel.perform { await $0.openReply(all: true) }
                    }
                }
            }
            .disabled(!emailModel.canHandOff)
            // A change that waits leaves the draft as it is, which Copy takes.
            Button("Copy") {
                emailModel.copy()
            }
            .disabled(!emailModel.canCopy)
            if emailModel.isHandingOff {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
