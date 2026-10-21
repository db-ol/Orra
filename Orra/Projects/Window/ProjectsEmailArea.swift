import SwiftUI

/// The email view, the third column of the Projects window while an email is selected
/// (plan section 5, projects-email-view), top to bottom:
/// - the sender, date and subject, the marks, and Explain or Explain Again
/// - the project chip with its reasons, whose menu moves the email to another project
/// - the attachments, with whether Projects read their text, see ProjectsAttachmentList
/// - once the email is explained, the choice between the explanation and the email itself,
///   see ProjectsEmailOriginal. Before that the email itself shows under its warnings.
/// - the warnings, always with those the code found, and what was taken out of the text
///   before the model read it
/// - What it says: the points, each with chips for its sources. A file's chip shows the
///   excerpt with its page inside Orra, an attachment's chip the excerpt the model read, and
///   an earlier email's chip shows that email in the window (decision 20). Nothing opens
///   outside Orra.
/// - Before you reply: the questions only the user can answer
/// - the draft with its tools, see DraftSection
///
/// Mail text, names and model output show as plain text only: `Text(verbatim:)`, or an
/// AttributedString made from plain strings for the highlight of a change. No Markdown,
/// links or images (plan section 2.8).
struct ProjectsEmailArea: View {
    let runtime: ProjectsRuntime
    let model: ProjectsWindowModel
    let email: MailStore.Listed

    /// Reads the explanation again when the email changes project, is explained, Retention
    /// removed its explanation, or the window let go of its email view, such as after Forget
    /// Project, and made a new one.
    struct Reload: Hashable {
        var messageID: String
        var project: UUID?
        var isExplained: Bool
        var explained: Int
        var generation: Int

        init(email: MailStore.Listed, model: ProjectsWindowModel) {
            messageID = email.messageID
            project = email.project
            isExplained = email.isExplained
            explained = model.explained[email.messageID] ?? 0
            generation = model.emailViewGeneration
        }
    }

    var body: some View {
        @Bindable var emailModel = model.emailModel(for: email.messageID)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ProjectChip(runtime: runtime, model: model, email: email)
                ProjectsAttachmentList(attachments: email.attachments)
                Divider()
                if let explanation = emailModel.explanation {
                    Picker("Show", selection: $emailModel.showsOriginal) {
                        Text("Explanation").tag(false)
                        Text("Original Email").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if emailModel.showsOriginal {
                        let warnings = ExplanationSections.warnings(explanation, listed: email.warnings)
                        if !warnings.isEmpty {
                            WarningList(items: warnings, model: model, emailModel: emailModel)
                        }
                        original(emailModel)
                        // The draft is the model's text, so a line sets it apart from the mail's.
                        Divider()
                    } else {
                        ExplanationSections(model: model, emailModel: emailModel, email: email, explanation: explanation)
                    }
                    DraftSection(runtime: runtime, emailModel: emailModel, explanation: explanation)
                } else {
                    // Before it is explained: the rule findings, and the email itself.
                    let warnings = ProjectsWarning.allCases.filter(email.warnings.contains).map { ExplanationSections.Item(warning: $0, places: []) }
                    if !warnings.isEmpty {
                        WarningList(items: warnings, model: model, emailModel: emailModel)
                    }
                    original(emailModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task(id: Reload(email: email, model: model)) {
            // The answer check runs on its own only for a draft made in this window, see
            // ProjectsWindowModel.explain(_:).
            await emailModel.load()
        }
    }

    /// The email itself, or its first sentence while it is read.
    @ViewBuilder
    private func original(_ emailModel: ProjectsEmailModel) -> some View {
        if let content = emailModel.original {
            ProjectsEmailOriginal(content: content)
        } else if !email.summary.isEmpty {
            Text(verbatim: email.summary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: email.subject)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: Self.sender(email.sender))
                    .textSelection(.enabled)
                Spacer()
                Text(email.date, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            let marks = ProjectsWindowView.MailRow.marks(email, deadline: model.deadlines[email.messageID].flatMap {
                ProjectsWindowText.deadline($0, now: runtime.dependencies.now())
            })
            if !marks.isEmpty {
                ProjectsWindowView.Marks(marks: marks)
            }
            explainControls
        }
    }

    @ViewBuilder
    private var explainControls: some View {
        let state = model.explaining[email.messageID]
        let isChanging = model.emailModel(for: email.messageID).isBusy
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
            .disabled(state == .explaining || isChanging || !email.hasText || runtime.phase != .on)
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

// MARK: The project chip

extension ProjectsEmailArea {
    /// The email's project, or Needs a Project or Set Aside, with why it is there. One click
    /// opens the menu that moves it, as Move To in the list does: the window stays on its
    /// list. The rule offer follows two moves of one kind.
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
                .help("Move To")
                .accessibilityHint(Text("Move To"))
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
    /// The warnings, What it says and Before you reply.
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
                    Text("The model named no points.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(explanation.points.enumerated()), id: \.offset) { _, point in
                    PointRow(point: point, model: model, emailModel: emailModel)
                }
                if !explanation.problems.isEmpty {
                    Text("Part of the model's answer could not be read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if explanation.reply.draftLanguage != nil || !explanation.questions.isEmpty {
                section("Before you reply") {
                    if explanation.questions.isEmpty {
                        Text("Nothing for you to decide first.")
                            .foregroundStyle(.secondary)
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
    /// The chips of a point's sources. A file's chip shows its excerpt with its page in a
    /// popover, an attachment's chip the excerpt the model read, this email's chip its text,
    /// and an earlier email's chip shows that email in the window (decision 20).
    struct SourceChips: View {
        let ids: [String]
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel

        var body: some View {
            HStack(spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    if let source = emailModel.sources[id] {
                        SourceChip(source: source, emailText: emailModel.emailText) { messageID in
                            Task { await model.show(messageID) }
                        }
                    }
                }
            }
        }
    }

    struct SourceChip: View {
        let source: ProjectsEmailModel.Source
        let emailText: String
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
                    Text(verbatim: ProjectsWindowText.source(source))
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                Excerpt(source: source, emailText: emailText)
            }
        }

        private var icon: String {
            switch source {
            case .thisEmail, .mail: "envelope"
            case .file: "doc.text"
            case .attachment: "paperclip"
            }
        }

        /// An earlier email the store no longer holds, which the window cannot show.
        static func isGone(_ source: ProjectsEmailModel.Source) -> Bool {
            if case .mail(_, nil, _) = source { true } else { false }
        }
    }

    /// The text behind a chip: a file's excerpt with its page and heading, the excerpt of an
    /// attachment the model read, or the email's own text.
    struct Excerpt: View {
        let source: ProjectsEmailModel.Source
        let emailText: String

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch source {
                    case .file(let chunk):
                        Text(verbatim: chunk.file.lastPathComponent)
                            .font(.headline)
                        if let page = chunk.page {
                            Text("Page \(page)")
                                .foregroundStyle(.secondary)
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
                        Text(verbatim: emailText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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
