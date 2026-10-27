import SwiftUI

/// The email view, the third column of the Projects window while an email is selected
/// (plan section 5, projects-email-view), top to bottom:
/// - Back to Previous Email, after an earlier email's chip showed this email. It stays
///   above the rest, which scrolls, since the chip is often far down.
/// - the sender, date and subject, the marks, and Explain or Explain Again, with Hide
///   Explanation or Show Explanation once the email is explained
/// - the project chip with its reasons, whose menu assigns the email to another project in
///   Orra. The email stays where it is in Mail.
/// - the warnings, always with those the code found, and what was taken out of the text
///   before the model read it
/// - What it says: the points, each with chips for its sources, or a line that it has
///   none. A file's chip shows the excerpt the explanation saved, with its page, slide or
///   sheet, inside Orra, an attachment's chip the excerpt the model read, and an earlier
///   email's chip shows that email in the window (decision 20). The chip of another
///   project's file names that project in brackets, and a line under the points says that
///   such files are for the user only and that the draft was written without them. Nothing
///   opens outside Orra. A line says when Projects could not read an attachment.
/// - Project Files for This Explanation, folded: each project file the explanation gave the
///   model, with Edit Project…, see FilesSection
/// - Before you reply: the questions only the user can answer
/// - the draft with its tools, see DraftSection
/// - the email itself under Original Email, see ProjectsEmailOriginal, which also lists the
///   attachments with whether Projects read their text
///
/// Hide Explanation puts the email itself first, under the warnings, and the draft under
/// it, for every email until the window closes, see ProjectsWindowModel.showsExplanation.
/// Before the email is explained, the email itself shows under its warnings.
///
/// Compare with Original, beside Hide Explanation once the email is explained, shows the
/// email in two panes while the window hides its sidebar, see
/// ProjectsWindowModel.isComparing: a bar above them with Exit Comparison and the subject,
/// the sender and the date, then Original Email, the email itself with the sender's words
/// first and its recipients and attachments folded under them, and Explanation and Draft,
/// with the rest of the view from the marks down to the draft. Each pane scrolls on its
/// own. They stand side by side where the view is wide enough, see Panes, and one above the
/// other where it is not. Another email chosen in the list shows the same way. The draft
/// keeps its editor through every switch, since the pane that holds it is the same view in
/// every layout. The This email chip shows the whole email too, see Excerpt.
///
/// A section the model's answer does not hold says so, rather than that the model found
/// nothing, see ProjectsWindowText.noQuestions(_:).
///
/// Mail text, names and model output show as plain text only: `Text(verbatim:)`, or an
/// AttributedString made from plain strings for the highlight of a change. No Markdown,
/// links or images (plan section 2.8).
struct ProjectsEmailArea: View {
    let runtime: ProjectsRuntime
    let model: ProjectsWindowModel
    let email: MailStore.Listed
    /// Opens Settings at the Projects page, nil where the view is shown without it, which
    /// leaves out its button.
    var openSettings: (() -> Void)? = nil

    /// Reads the explanation again when the email changes project, is explained, Retention
    /// removed its explanation or its draft, or the window let go of its email view, such
    /// as after Forget Project, and made a new one.
    struct Reload: Hashable {
        var messageID: String
        var project: UUID?
        var isExplained: Bool
        var hasDraft: Bool
        var explained: Int
        var generation: Int

        init(email: MailStore.Listed, model: ProjectsWindowModel) {
            messageID = email.messageID
            project = email.project
            isExplained = email.isExplained
            hasDraft = email.hasDraft
            explained = model.explained[email.messageID] ?? 0
            generation = model.emailViewGeneration
        }
    }

    /// The button of the comparison that VoiceOver's cursor or the keyboard focus is on.
    @AccessibilityFocusState private var voiceOverFocus: SwitchButton?
    @FocusState private var keyboardFocus: SwitchButton?
    /// Where the focus goes once the layout switched, nil after a click.
    @State private var focusAfterSwitch: FocusMove?
    /// The room a scroll bar takes beside the content of a pane, which changes when a mouse
    /// comes or goes.
    @State private var scroller = Panes.scrollerWidth()

    var body: some View {
        let emailModel = model.emailModel(for: email.messageID)
        let comparing = model.isComparing
        // The bars, then the panes in one layout whose values change, so the scroll with the
        // draft keeps its place, and the editor its text, selection, focus, marked text and
        // undo, as the comparison starts and ends and as its panes go from side by side to
        // one above the other.
        Panes(scroller: scroller) {
            if model.previousEmail != nil {
                bar(backBar)
            }
            if comparing {
                bar(compareBar)
                originalPane(emailModel)
                Rectangle()
                    .fill(.separator)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if comparing {
                        Text("Explanation and Draft")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    header(comparing: comparing)
                    ProjectChip(runtime: runtime, model: model, email: email)
                    Divider()
                    if let explanation = emailModel.explanation {
                        // The draft keeps one place between the two parts, so Hide Explanation
                        // and Show Explanation keep its editor with the text, the selection and
                        // the focus. The comparison shows the explanation either way, and
                        // leaves Hide Explanation as it was.
                        if model.showsExplanation || comparing {
                            ExplanationSections(model: model, emailModel: emailModel, email: email, explanation: explanation)
                        } else {
                            let warnings = ExplanationSections.warnings(explanation, listed: email.warnings)
                            if !warnings.isEmpty {
                                WarningList(items: warnings, model: model, emailModel: emailModel)
                            }
                            original(emailModel)
                            // The draft is the model's text, so a line sets it apart from the mail's.
                            Divider()
                        }
                        DraftSection(
                            runtime: runtime, emailModel: emailModel, explanation: explanation,
                            isExplaining: model.explaining[email.messageID] == .explaining,
                            chooseFiles: { model.chooseFiles(for: email) })
                        // While comparing, the email itself has a pane of its own.
                        if model.showsExplanation, !comparing {
                            Divider()
                            Text("Original Email")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            original(emailModel)
                        }
                    } else {
                        // Before it is explained: the rule findings, and the email itself,
                        // which has a pane of its own while comparing.
                        let warnings = ProjectsWarning.allCases.filter(email.warnings.contains).map { ExplanationSections.Item(warning: $0, places: []) }
                        if !warnings.isEmpty {
                            WarningList(items: warnings, model: model, emailModel: emailModel)
                        }
                        if !comparing {
                            original(emailModel)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // VoiceOver names the pane while comparing, as it names Original Email.
            .accessibilityLabel(Text("Explanation and Draft"), isEnabled: comparing)
        }
        .task(id: Reload(email: email, model: model)) {
            // The answer check runs on its own only for a draft made in this window, see
            // ProjectsWindowModel.explain(_:).
            await emailModel.load()
        }
        .onChange(of: comparing) {
            // After a press of Compare with Original or Exit Comparison with VoiceOver or the
            // keyboard, on the next turn, once the other button is there. A click and every
            // other end of the comparison move no focus.
            guard let move = focusAfterSwitch else { return }
            focusAfterSwitch = nil
            Task {
                if move.keyboard {
                    keyboardFocus = move.button
                }
                if move.voiceOver {
                    voiceOverFocus = move.button
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scroller = Panes.scrollerWidth()
        }
    }

    /// Original Email, the left pane or the upper one while comparing: the email itself with
    /// the sender's words first. A pane for each email, so another email starts at its top
    /// with its rows folded.
    private func originalPane(_ emailModel: ProjectsEmailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Original Email")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                original(emailModel, wordsFirst: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Panes.padding)
        }
        .accessibilityLabel(Text("Original Email"))
        .id(email.messageID)
    }

    /// The email itself with its attachments, or its attachments and its first sentence
    /// while it is read. The attachments show also when the store keeps none of its text.
    @ViewBuilder
    private func original(_ emailModel: ProjectsEmailModel, wordsFirst: Bool = false) -> some View {
        if let content = emailModel.original {
            ProjectsEmailOriginal(content: content, attachments: email.attachments, wordsFirst: wordsFirst)
        } else {
            ProjectsAttachmentList(attachments: email.attachments)
            if !email.summary.isEmpty {
                Text(verbatim: email.summary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The bars and the header

    /// Back to Previous Email, after an earlier email's chip showed this email.
    private var backBar: some View {
        Button {
            Task { await model.showPreviousEmail() }
        } label: {
            Label("Back to Previous Email", systemImage: "chevron.backward")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The bar above the panes while comparing: Exit Comparison and the subject in one line,
    /// cut at its end with the whole subject in its help tag, and under them the sender and
    /// the date, which the panes leave out, one under the other where a row has no room. It
    /// stays put while the panes scroll.
    private var compareBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button("Exit Comparison") {
                    let move = Self.focusAfterPress(.exit, voiceOver: voiceOverFocus, keyboard: keyboardFocus)
                    model.endComparing()
                    focusAfterSwitch = model.isComparing ? nil : move
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("Ends the comparison and puts the sidebar and the email view back as they were.")
                .accessibilityFocused($voiceOverFocus, equals: .exit)
                .focused($keyboardFocus, equals: .exit)
                Text(verbatim: email.subject)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(Text(verbatim: email.subject))
            }
            ViewThatFits(in: .horizontal) {
                senderAndDate
                VStack(alignment: .leading, spacing: 2) {
                    sender
                    date
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Panes.padding)
        .padding(.vertical, 8)
    }

    /// The sender as the header shows it, and the date.
    private var senderAndDate: some View {
        HStack(alignment: .firstTextBaseline) {
            sender
            Spacer()
            date
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var sender: some View {
        Text(verbatim: Self.sender(email.sender))
            .textSelection(.enabled)
    }

    private var date: some View {
        Text(email.date, format: .dateTime.year().month().day().hour().minute())
    }

    /// The subject, the sender and the date, which the bar shows while comparing, then the
    /// marks and the buttons.
    private func header(comparing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !comparing {
                Text(verbatim: email.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                senderAndDate
            }
            let marks = ProjectsWindowView.MailRow.marks(email, deadline: model.deadlines[email.messageID].flatMap {
                ProjectsWindowText.deadline($0, now: runtime.dependencies.now())
            })
            if !marks.isEmpty {
                ProjectsWindowView.Marks(marks: marks)
            }
            explainControls(comparing: comparing)
        }
    }

    @ViewBuilder
    private func explainControls(comparing: Bool) -> some View {
        let state = model.explaining[email.messageID]
        let isChanging = model.emailModel(for: email.messageID).isBusy
        let noText = ProjectsWindowText.noText(email)
        // One under another in a column too narrow for a row, such as the third column of the
        // window at its smallest size. Each button once, so the focus that follows a press
        // of Compare with Original or Exit Comparison has one button to go to.
        RowOrColumn {
            explainButtons(state: state, isChanging: isChanging, noText: noText, comparing: comparing)
        }
        // A name a little too long for the column, such as Compare with Original beside a
        // scroll bar at the window's smallest size, tightens or shrinks by up to a tenth
        // rather than being cut. A row needs every name at its full size.
        .allowsTightening(true)
        .minimumScaleFactor(0.9)
        // What the next explanation uses of the files the user chose.
        if let note = model.emailModel(for: email.messageID).choiceNote {
            Text(verbatim: ProjectsWindowText.choiceNote(note))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .failed(let failure)? = state {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: ProjectsWindowText.explainFailure(failure))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The way out when the model is missing or could not be loaded. The button
                // keeps its whole name, and the line wraps beside it.
                switch failure {
                case .noModel:
                    if let openSettings {
                        Button("Open Projects Settings…", action: openSettings)
                            .fixedSize()
                    }
                case .modelNotLoaded:
                    // It explains the email after the load, so it waits for a change or
                    // an undo of the draft, as Explain does.
                    Button("Try Loading Again") {
                        Task { await model.loadModelAgain(explaining: email.messageID) }
                    }
                    .fixedSize()
                    .disabled(isChanging || runtime.phase != .on)
                case .tooLong, .other:
                    EmptyView()
                }
            }
        } else if let noText {
            Text(verbatim: noText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Explain, or Explain Again with Hide Explanation or Show Explanation and Compare with
    /// Original once the email is explained, and Explaining… while the model explains it.
    /// While comparing, the bar has the way back, and the pane shows the explanation, so
    /// Explain or Explain Again stands alone.
    @ViewBuilder
    private func explainButtons(state: ProjectsWindowModel.ExplainState?, isChanging: Bool, noText: String?, comparing: Bool) -> some View {
        Group {
            if email.isExplained {
                // Asks first when the new draft would replace one the user changed.
                Button("Explain Again") {
                    Task { await model.requestExplain(email.messageID) }
                }
            } else {
                Button("Explain") {
                    Task { await model.explain(email.messageID) }
                }
            }
        }
        .disabled(state == .explaining || isChanging || noText != nil || runtime.phase != .on)
        // The window's choice, so the next email shows the same way.
        if model.emailModel(for: email.messageID).explanation != nil, !comparing {
            Button {
                model.showsExplanation.toggle()
            } label: {
                if model.showsExplanation {
                    Text("Hide Explanation")
                } else {
                    Text("Show Explanation")
                }
            }
            // It only changes the layout, as Hide Explanation does, so it is never off.
            Button("Compare with Original") {
                let move = Self.focusAfterPress(.compare, voiceOver: voiceOverFocus, keyboard: keyboardFocus)
                model.compare(email.messageID)
                focusAfterSwitch = model.isComparing ? move : nil
            }
            .help("Shows the email itself next to its explanation and draft, each scrolling on its own, and hides the sidebar until you click Exit Comparison.")
            .accessibilityFocused($voiceOverFocus, equals: .compare)
            .focused($keyboardFocus, equals: .compare)
        }
        if state == .explaining {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Explaining…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The sender as "Name <address>", or the address alone.
    static func sender(_ person: MailStore.Person) -> String {
        person.name.isEmpty ? person.address : "\(person.name) <\(person.address)>"
    }
}

// MARK: The project chip

extension ProjectsEmailArea {
    /// The email's project, or Needs a Project or Set Aside, with why it is there. One click
    /// opens the menu that assigns it to another project, as Assign to Project in the list
    /// does: the window stays on its list. The rule offer follows two moves of one kind.
    struct ProjectChip: View {
        let runtime: ProjectsRuntime
        let model: ProjectsWindowModel
        let email: MailStore.Listed

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ProjectsWindowView.MoveMenuItems(runtime: runtime, model: model, email: email)
                } label: {
                    Label {
                        Text(verbatim: title)
                    } icon: {
                        Image(systemName: email.level == .setAside ? "archivebox" : email.project == nil ? "tray" : "folder")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("Assign to Project")
                .accessibilityHint(Text("Assign to Project"))
                .disabled(runtime.phase != .on)
                let reasons = ProjectsWindowText.reasons(email)
                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(reasons, id: \.self) { reason in
                            Text(verbatim: reason)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }

        private var title: String {
            if let project = email.project {
                return runtime.projectList.first { $0.id == project }?.name ?? String(localized: "Projects")
            }
            return email.level == .setAside ? String(localized: "Set Aside") : String(localized: "Needs a Project")
        }
    }
}

// MARK: What the explanation says

extension ProjectsEmailArea {
    /// The warnings, What it says, Project Files for This Explanation and Before you reply.
    struct ExplanationSections: View {
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel
        let email: MailStore.Listed
        let explanation: Explanation

        var body: some View {
            let warnings = Self.warnings(explanation, listed: email.warnings)
            if !warnings.isEmpty || !explanation.modelWarnings.isEmpty || !explanation.removed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    WarningList(items: warnings, model: model, emailModel: emailModel)
                    if !explanation.modelWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The model also noted:")
                                .foregroundStyle(.secondary)
                            ForEach(Array(explanation.modelWarnings.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !explanation.removed.isEmpty {
                        TakenOut(explanation: explanation, model: model, emailModel: emailModel)
                    }
                }
            }
            section("What it says") {
                if explanation.points.isEmpty {
                    Text(verbatim: ProjectsWindowText.noPoints(explanation))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(explanation.points.enumerated()), id: \.offset) { _, point in
                    PointRow(point: point, model: model, emailModel: emailModel)
                }
                if explanation.citesOtherProjectFile {
                    Text(verbatim: ProjectsWindowText.otherProjectsNote(explanation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = ProjectsWindowText.unreadAttachments(email.attachments) {
                    Text(verbatim: notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !explanation.problems.isEmpty {
                    Text("Part of the model's answer could not be read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            FilesSection(model: model, emailModel: emailModel, email: email, explanation: explanation)
            if explanation.reply.draftLanguage != nil || !explanation.questions.isEmpty {
                section("Before you reply") {
                    if explanation.questions.isEmpty {
                        Text(verbatim: ProjectsWindowText.noQuestions(explanation))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(explanation.questions.enumerated()), id: \.offset) { _, question in
                        Label {
                            Text(verbatim: question)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                }
            }
        }

        private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }

        /// A warning with the places it was found, the email's first.
        struct Item: Equatable {
            var warning: ProjectsWarning
            var places: [ExplainPrompt.Place]
        }

        /// The warnings of the explanation and of the list, each kind once, in the order of
        /// `ProjectsWarning.allCases`, so the rule findings always show.
        static func warnings(_ explanation: Explanation, listed: [ProjectsWarning]) -> [Item] {
            var places: [ProjectsWarning: [ExplainPrompt.Place]] = [:]
            for finding in explanation.warnings where !(places[finding.warning]?.contains(finding.place) ?? false) {
                places[finding.warning, default: []].append(finding.place)
            }
            let kinds = Set(listed).union(places.keys)
            return ProjectsWarning.allCases.filter(kinds.contains).map { Item(warning: $0, places: places[$0] ?? []) }
        }

        /// The source id a chip shows for a place. The email itself needs no chip.
        static func sourceID(_ place: ExplainPrompt.Place) -> String? {
            switch place {
            case .email: nil
            case .file(let id), .thread(let id), .projectMail(let id), .attachment(let id): id
            }
        }
    }

    /// The warnings, each with the chips of where it was found, under their heading.
    struct WarningList: View {
        let items: [ExplanationSections.Item]
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warnings")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items, id: \.warning) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(verbatim: ProjectsWindowText.warning(item.warning))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        let places = item.places.compactMap(ExplanationSections.sourceID)
                        if !places.isEmpty {
                            SourceChips(ids: places, model: model, emailModel: emailModel)
                                .padding(.leading, 26)
                        }
                    }
                }
            }
        }
    }

    /// One point with its source chips and what OutputChecks found in it.
    struct PointRow: View {
        let point: Explanation.Point
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .accessibilityHidden(true)
                    Text(verbatim: point.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !point.sources.isEmpty {
                    SourceChips(ids: point.sources, model: model, emailModel: emailModel)
                        .padding(.leading, 14)
                } else if let line = ProjectsWindowText.noSource(point) {
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
                ForEach(Array(point.flags.enumerated()), id: \.offset) { _, flag in
                    Label {
                        Text(verbatim: ProjectsWindowText.finding(flag))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 14)
                }
            }
        }
    }

    /// What PromptHygiene took out of the texts before the model read them, for the user to
    /// read: hidden text and lines that speak to an assistant.
    struct TakenOut: View {
        let explanation: Explanation
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel

        /// The most characters of one finding shown.
        static let maximumCharacters = 1_000

        var body: some View {
            DisclosureGroup("Taken out before the model read it") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.findings(explanation).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(verbatim: ProjectsWindowText.takenOut(item.finding.kind))
                                    .font(.caption.weight(.semibold))
                                if let id = ExplanationSections.sourceID(item.place) {
                                    SourceChips(ids: [id], model: model, emailModel: emailModel)
                                }
                            }
                            if !item.finding.text.isEmpty {
                                Text(verbatim: String(item.finding.text.prefix(Self.maximumCharacters)))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(8)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .disclosureGroupStyle(RowDisclosureStyle())
        }

        /// Each finding with its place, the email's first.
        static func findings(_ explanation: Explanation) -> [(place: ExplainPrompt.Place, finding: PromptHygiene.Finding)] {
            let order: (ExplainPrompt.Place) -> (Int, String) = { place in
                switch place {
                case .email: (0, "")
                case .attachment(let id): (1, id)
                case .thread(let id): (2, id)
                case .projectMail(let id): (3, id)
                case .file(let id): (4, id)
                }
            }
            return explanation.removed
                .sorted { order($0.key) < order($1.key) }
                .flatMap { place, hygiene in hygiene.flatMap(\.findings).map { (place, $0) } }
        }
    }
}

// MARK: Source chips

extension ProjectsEmailArea {
    /// The chips of a point's sources. A file's chip shows its saved excerpt with its page,
    /// slide or sheet in a popover, an attachment's chip the excerpt the model read, this
    /// email's chip the whole email, and an earlier email's chip shows that email in the
    /// window (decision 20). The chips go one under another in a column too narrow for a
    /// row. A chip keeps one line and is cut in the middle, and the chip of another project's
    /// file cuts only the file's name, so the project's stays whole.
    struct SourceChips: View {
        let ids: [String]
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    chips
                }
                VStack(alignment: .leading, spacing: 4) {
                    chips
                }
            }
        }

        private var chips: some View {
            ForEach(ids, id: \.self) { id in
                if let source = emailModel.sources[id] {
                    SourceChip(
                        source: source, emailText: emailModel.emailText, original: emailModel.original,
                        attachments: model.listed(emailModel.messageID)?.attachments ?? [],
                        takenOut: emailModel.explanation?.removed[.file(id)] != nil
                    ) { messageID in
                        Task { await model.show(messageID) }
                    }
                }
            }
        }
    }

    struct SourceChip: View {
        let source: ProjectsEmailModel.Source
        let emailText: String
        /// This email as Original Email shows it, and its attachments, for the chip of this
        /// email.
        var original: ProjectsEmailOriginal.Content? = nil
        var attachments: [MailAttachment] = []
        /// Whether the hygiene took lines out of a file's excerpt before the model read it.
        var takenOut = false
        let show: (String) -> Void
        @State private var showsExcerpt = false

        var body: some View {
            Button {
                if case .mail(let messageID, _?, _) = source {
                    show(messageID)
                } else {
                    showsExcerpt = true
                }
            } label: {
                Label {
                    if let parts = ProjectsWindowText.sourceParts(source) {
                        // The project's name stays whole, and the file's name gives way.
                        HStack(spacing: 0) {
                            Text(verbatim: parts.file)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(verbatim: parts.project)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    } else {
                        Text(verbatim: ProjectsWindowText.source(source))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: icon)
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(Text(verbatim: ProjectsWindowText.sourceLabel(source)))
            .disabled(Self.isGone(source))
            .popover(isPresented: $showsExcerpt, arrowEdge: .bottom) {
                Excerpt(source: source, emailText: emailText, original: original, attachments: attachments, takenOut: takenOut)
            }
        }

        private var icon: String {
            switch source {
            case .thisEmail, .mail: "envelope"
            case .file: "doc.text"
            // As the project chip shows a project.
            case .otherProjectFile: "folder"
            case .attachment: "paperclip"
            }
        }

        /// An earlier email the store no longer holds, which the window cannot show.
        static func isGone(_ source: ProjectsEmailModel.Source) -> Bool {
            if case .mail(_, nil, _) = source { true } else { false }
        }
    }

    /// The text behind a chip: a file's excerpt as the explanation saved it, with its page,
    /// slide or sheet and heading, whether its text was recognized, and the project of
    /// another project's file, the excerpt of an attachment the model read, or the whole
    /// email in the order of Original Email while comparing, its own text when the store
    /// keeps none of it. A file's saved excerpt keeps the lines the hygiene took out before
    /// the model read it, so it says so when it holds any.
    struct Excerpt: View {
        let source: ProjectsEmailModel.Source
        let emailText: String
        /// This email as Original Email shows it, nil when the store keeps none of its text,
        /// and its attachments with their states.
        var original: ProjectsEmailOriginal.Content? = nil
        var attachments: [MailAttachment] = []
        /// Whether the hygiene took lines out of a file's excerpt before the model read it.
        var takenOut = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch source {
                    case .file(let chunk), .otherProjectFile(let chunk, _):
                        Text(verbatim: chunk.file.lastPathComponent)
                            .font(.headline)
                        if case .otherProjectFile(_, let project) = source {
                            Text(verbatim: ProjectsWindowText.otherProject(project))
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: ProjectsWindowText.savedExcerpt(chunk))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let recognized = ProjectsWindowText.recognized(chunk) {
                            Text(verbatim: recognized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let heading = chunk.heading, !heading.isEmpty {
                            Text(verbatim: heading)
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("Changed \(chunk.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(verbatim: chunk.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if takenOut {
                            Text("The model read it without the lines listed under Taken out before the model read it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .attachment(let name, let excerpt):
                        Text(verbatim: name)
                            .font(.headline)
                        Text("The part of this attachment the model read")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(verbatim: excerpt)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .thisEmail:
                        Text("This email")
                            .font(.headline)
                        Divider()
                        if let original {
                            ProjectsEmailOriginal(content: original, attachments: attachments, wordsFirst: true)
                        } else {
                            Text(verbatim: emailText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .mail:
                        // An earlier email's chip shows that email in the window, or is off.
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(width: 420)
            .frame(maxHeight: 420)
        }
    }
}
