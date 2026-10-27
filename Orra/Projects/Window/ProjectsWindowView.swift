import SwiftUI

/// The Projects window in three columns: the projects with Needs a Project and Set Aside,
/// the mail of the chosen one, and the selected email or the project's page.
///
/// Mail text, names and model output show with `Text(verbatim:)` only: no Markdown, no
/// links, no images (plan section 2.8). The third column holds the email view,
/// ProjectsEmailArea, or the project's page, or, while neither shows, How to Use Projects,
/// see ProjectsHowTo.
///
/// While the model compares, see ProjectsWindowModel.isComparing, the window asks its split
/// view to hide the sidebar and keep the list, so the email view gets the sidebar's room for
/// Compare with Original. It never asks for the detail column alone, which the split view
/// does not honor on macOS 26 and answers with all three columns. Every end of the
/// comparison asks for the columns that showed before, and a column the user shows ends it.
/// A window that is never shown applies the columns it asks for only once it is resized, so
/// the tests read what it asks for, and an opt in test and a live check show the window.
struct ProjectsWindowView: View {
    let runtime: ProjectsRuntime
    @State var model: ProjectsWindowModel
    /// Opens Settings at the Projects page.
    let openSettings: () -> Void
    /// Opens the Mail app on the user's click, MailApp.open in the app. Nil leaves out every
    /// Open Mail button.
    var openMail: (() -> Void)? = nil
    /// Hears each change of the columns asked of the split view, for tests, since a window
    /// that is never shown does not apply them and its split view cannot say.
    var columnsChanged: (NavigationSplitViewVisibility) -> Void = { _ in }
    /// The project being set up, nil while no setup sheet shows.
    @State private var setup: ProjectsSetupView.Draft?
    @State private var forgetting: Project?
    /// The columns the window asks its split view for, without the sidebar while the model
    /// compares. All three at first, as the split view shows them, never `.automatic`, which
    /// compares equal to `.doubleColumn`, so a change could not tell the two apart.
    @State private var columns = NavigationSplitViewVisibility.all
    /// The columns before the comparison, which every end of it asks for again.
    @State private var columnsBeforeComparing = NavigationSplitViewVisibility.all

    /// Reads the list again when another list is chosen or the mail changed.
    private struct Reload: Hashable {
        var place: MailStore.Place?
        var changes: Int
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            mailColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            detail
        }
        .onChange(of: model.isComparing, initial: true) { _, comparing in
            if comparing {
                columnsBeforeComparing = columns
            }
            if let wanted = Self.columnsToAsk(comparing: comparing, shown: columns, before: columnsBeforeComparing) {
                ask(wanted, animated: !comparing)
            }
        }
        .onChange(of: columns) { _, shown in
            columnsChanged(shown)
            // A column the user showed, which the comparison hides, such as the sidebar
            // dragged open or shown by the split view's own toggle.
            if model.isComparing, Self.columnCount(shown) > Self.columnCount(Self.columnsWhileComparing(columnsBeforeComparing)) {
                model.endComparing()
            }
        }
        // The window keeps its name for the Window menu and VoiceOver, and the list chosen
        // shows under it.
        .navigationTitle("Projects")
        .navigationSubtitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.explainSelectedMessage() }
                } label: {
                    // With its title, since an envelope alone does not say what it explains.
                    Label("Explain Message Selected in Mail", systemImage: "envelope.badge")
                        .labelStyle(.titleAndIcon)
                }
                .help("Shows the message you selected in Mail in this window and explains it. It must be in a mailbox Projects reads, within the period it reads.")
                .disabled(runtime.phase != .on || model.isReadingSelection)
            }
        }
        .task(id: Reload(place: model.place, changes: runtime.mailChanges)) {
            await model.reload()
        }
        .task(id: ProjectsSuggestedSection.Reload(
            changes: runtime.mailChanges, holdsModel: runtime.windowHoldsModel,
            modelIsInstalled: runtime.dependencies.modelIsInstalled(), mailIsRunning: runtime.mailIsRunning
        )) {
            try? await Task.sleep(for: ProjectsSuggestedSection.reloadDelay)
            guard !Task.isCancelled else { return }
            await model.suggestions.refresh()
        }
        .sheet(item: $setup) { draft in
            ProjectsSetupView(runtime: runtime, draft: draft, done: { saved in
                if let saved {
                    model.place = .project(saved)
                    if let suggestion = draft.suggestion {
                        model.suggestions.projectCreated(from: suggestion.id)
                    }
                }
                setup = nil
            }, dismissSuggestion: draft.suggestion.map { suggestion in
                { ProjectsSuggestedSection.dismiss(suggestion, from: model.suggestions, runtime: runtime) }
            })
        }
        // Choose Files for This Email…, whose Explain runs once the sheet closed, so Replace
        // your draft? shows as a dialog of the window.
        .sheet(item: $model.choosingFiles, onDismiss: {
            Task { await model.explainAfterTheSheet() }
        }) { choosing in
            ProjectsChooseFiles(runtime: runtime, model: model, email: choosing.email)
        }
        // Edit Project… beside a linked mailbox in Settings. A sheet, an alert or a dialog of
        // the window that shows already stays as it is, with the list behind it. The Remove
        // Rule dialog is the project page's own, and a sheet that follows it saves the rules
        // as the list has them then, see ProjectsRuntime.update(_:).
        .onChange(of: model.projectToEdit, initial: true) {
            if let project = model.takeProjectToEdit(presenting: setup != nil || forgetting != nil) {
                setup = ProjectsSetupView.Draft(project)
            }
        }
        .onChange(of: model.ruleOffer) { _, offer in
            // The offer shows above the list, so VoiceOver says it.
            if let offer, let project = runtime.projectList.first(where: { $0.id == offer.project }) {
                AccessibilityNotification.Announcement(ProjectsWindowText.ruleOffer(offer.rule, project: project.name)).post()
            }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice {
                let line = ProjectsWindowText.notice(notice)
                if !line.isEmpty {
                    AccessibilityNotification.Announcement(line).post()
                }
            }
        }
        .alert(
            Text("Forget “\(forgetting?.name ?? "")”?"),
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { project in
            Button("Forget Project", role: .destructive) {
                Task {
                    do {
                        try await runtime.forget(project.id)
                        // The email views may hold text of the forgotten project.
                        model.forgetEmails()
                        if model.place == .project(project.id) {
                            model.place = .needsProject
                        }
                    } catch {
                        model.notice = .projectNotForgotten
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the project with its index, mail and drafts from Projects, and the explanations and drafts of other emails that used its files. Your mail in Mail and the files in its folders stay as they are.")
        }
        .confirmationDialog(
            "Change this email's project?",
            isPresented: Binding(get: { model.pendingMove != nil }, set: { if !$0 { model.pendingMove = nil } }),
            presenting: model.pendingMove
        ) { move in
            Button("Change Project") {
                Task { await model.confirmMove(move) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes its explanation and its draft with your changes, since they were made for the project it is in now. You can explain it again after the change. The email stays where it is in Mail.")
        }
        .confirmationDialog(
            "Replace your draft?",
            isPresented: Binding(get: { model.pendingExplain != nil }, set: { if !$0 { model.pendingExplain = nil } }),
            presenting: model.pendingExplain
        ) { messageID in
            Button("Replace Draft") {
                Task { await model.confirmExplain(messageID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Explaining this email again replaces its draft and your changes to it with a new draft.")
        }
    }

    // MARK: The sidebar

    private var sidebar: some View {
        List(selection: $model.place) {
            Section {
                Label("Needs a Project", systemImage: "tray")
                    .tag(MailStore.Place.needsProject)
                Label("Set Aside", systemImage: "archivebox")
                    .tag(MailStore.Place.setAside)
            }
            ProjectsSuggestedSection(runtime: runtime, suggestions: model.suggestions) { suggestion in
                setup = ProjectsSetupView.Draft(suggestion: suggestion)
            }
            Section("Projects") {
                ForEach(runtime.projectList) { project in
                    Label {
                        Text(verbatim: project.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(MailStore.Place.project(project.id))
                    .contextMenu {
                        Button("Edit Project…") {
                            setup = ProjectsSetupView.Draft(project)
                        }
                        Button("Forget Project…", role: .destructive) {
                            forgetting = project
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    setup = ProjectsSetupView.Draft()
                } label: {
                    Label("New Project…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(runtime.phase != .on)
                Spacer()
            }
            .padding(10)
        }
    }

    // MARK: The mail list

    private var mailColumn: some View {
        VStack(spacing: 0) {
            if let offer = model.ruleOffer, let project = runtime.projectList.first(where: { $0.id == offer.project }) {
                RuleOfferBar(text: ProjectsWindowText.ruleOffer(offer.rule, project: project.name)) {
                    Task { await model.acceptRule() }
                } decline: {
                    model.ruleOffer = nil
                }
                Divider()
            }
            ScrollViewReader { scroller in
                List(model.rows, id: \.messageID, selection: $model.selectedMessageID) { email in
                    MailRow(email: email, deadline: model.deadlines[email.messageID].flatMap { ProjectsWindowText.deadline($0, now: runtime.dependencies.now()) })
                        .contextMenu {
                            moveMenu(email)
                            // So a choice can come before the first Explain.
                            Button("Choose Files for This Email…") {
                                model.chooseFiles(for: email)
                            }
                            .disabled(runtime.phase != .on || ProjectsWindowText.noText(email) != nil)
                        }
                }
                .overlay {
                    if model.rows.isEmpty {
                        EmptyList(runtime: runtime, model: model, openSettings: openSettings, openMail: openMail)
                    }
                }
                .onChange(of: model.showCount) {
                    // The email a source or Explain Message Selected in Mail showed, which
                    // may be far down the list.
                    if let id = model.selectedMessageID {
                        scroller.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: model.isComparing) { _, comparing in
                    // The end of the comparison: the selected row in view, with the least
                    // scrolling. An email read alone has no row, and the list stays where it
                    // was.
                    if !comparing, let id = model.selectedRow {
                        scroller.scrollTo(id)
                    }
                }
            }
            if model.hasOlderEmails {
                OlderEmailsBar(shown: model.rows.count, total: model.total) {
                    Task { await model.loadOlderEmails() }
                }
            }
            StatusLines(runtime: runtime, model: model, openSettings: openSettings, openMail: openMail)
        }
    }

    /// How many columns the split view shows for a visibility the window asks for.
    static func columnCount(_ columns: NavigationSplitViewVisibility) -> Int {
        if columns == .detailOnly {
            1
        } else if columns == .doubleColumn {
            2
        } else {
            3
        }
    }

    /// The columns Compare with Original asks for: the list and the email view, with the
    /// sidebar hidden. Columns that hide the sidebar already stay as they are.
    static func columnsWhileComparing(_ shown: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        columnCount(shown) < 3 ? shown : .doubleColumn
    }

    /// What the window asks its split view for as the comparison starts or ends, from the
    /// columns shown and those before the comparison, nil for nothing: the columns of the
    /// comparison at its start, and at every end the columns from before, so a sidebar the
    /// user hid before stays hidden. Not after a column the user showed while comparing,
    /// which ended it and stays as the user left it.
    static func columnsToAsk(comparing: Bool, shown: NavigationSplitViewVisibility, before: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility? {
        if comparing {
            return columnsWhileComparing(shown)
        }
        return columnCount(shown) <= columnCount(columnsWhileComparing(before)) ? before : nil
    }

    /// Asks the split view for columns, when they differ from those asked before. The
    /// comparison's columns come at once, so the email view takes its new width rather than
    /// growing into it. The columns before come back animated, as the split view's own
    /// toggle shows the sidebar, which at the window's smallest size takes the sidebar's room
    /// from the email view again. Shown at once, the sidebar kept the email view's width and
    /// widened the window, as the shown window test found.
    private func ask(_ wanted: NavigationSplitViewVisibility, animated: Bool = false) {
        guard columns != wanted else { return }
        var transaction = Transaction(animation: animated ? .default : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            columns = wanted
        }
    }

    private var title: String {
        switch model.place {
        case .needsProject?: String(localized: "Needs a Project")
        case .setAside?: String(localized: "Set Aside")
        case .project(let id)?: runtime.projectList.first { $0.id == id }?.name ?? String(localized: "Projects")
        case nil: String(localized: "Projects")
        }
    }

    private func moveMenu(_ email: MailStore.Listed) -> some View {
        Menu("Assign to Project") {
            MoveMenuItems(runtime: runtime, model: model, email: email)
        }
        .disabled(runtime.phase != .on)
    }

    // MARK: The third column

    @ViewBuilder
    private var detail: some View {
        if let email = model.selectedEmail {
            ProjectsEmailArea(runtime: runtime, model: model, email: email, openSettings: openSettings)
        } else if case .project(let id)? = model.place, let project = runtime.projectList.first(where: { $0.id == id }) {
            ProjectsProjectPage(runtime: runtime, project: project) {
                setup = ProjectsSetupView.Draft(project)
            } forget: {
                forgetting = project
            } removeRule: { rule in
                Task { await model.removeRule(rule, from: project.id) }
            }
            // A page of its own for each project, so a Remove Rule dialog that is open goes
            // away with its project rather than act on the next one.
            .id(project.id)
        } else {
            Self.howTo(runtime: runtime, model: model, openSettings: openSettings, openMail: openMail) {
                setup = ProjectsSetupView.Draft()
            }
        }
    }

    /// How to Use as the window shows it: the step about Settings until Start Reading Mail
    /// confirmed the mailboxes, with Open Mail while Mail is closed, and the step about
    /// projects, which names Suggested Projects only while the sidebar shows them, with a
    /// suggestion or while the model names one, as ProjectsSuggestedSection does.
    static func howTo(runtime: ProjectsRuntime, model: ProjectsWindowModel, openSettings: @escaping () -> Void, openMail: (() -> Void)?, newProject: @escaping () -> Void) -> ProjectsHowTo {
        ProjectsHowTo(
            showsSetup: !runtime.choice.isConfirmed, canCreate: runtime.phase == .on,
            openSettings: openSettings, newProject: newProject,
            hasSuggestions: !model.suggestions.suggestions.isEmpty || model.suggestions.isNaming,
            mailIsRunning: runtime.mailIsRunning, openMail: openMail)
    }
}

// MARK: Rows and lines

extension ProjectsWindowView {
    /// The narrowest the lines above and under the mail list get: the narrowest mail column,
    /// 280 points, less their padding. A line there that wraps is at least this wide. SwiftUI
    /// measures a column at no width for its minimum size, where such a line would take a
    /// line for each letter, and every column would grow taller than the window, with its
    /// top and bottom cut off.
    static let narrowestLineWidth: CGFloat = 260

    /// One email in the list: its sender, date, subject, the line under the subject and its
    /// marks.
    struct MailRow: View {
        let email: MailStore.Listed
        /// The deadline mark from the explanation's dates, nil without one.
        var deadline: String? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: email.sender.name.isEmpty ? email.sender.address : email.sender.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(email.date, format: Self.dateFormat(email.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: email.subject)
                    .lineLimit(1)
                // Decision 16: the first sentence until it is explained, then the first point.
                if !email.summary.isEmpty {
                    Text(verbatim: email.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                let marks = Self.marks(email, deadline: deadline)
                if !marks.isEmpty {
                    Marks(marks: marks)
                }
            }
            .padding(.vertical, 2)
        }

        /// The time for mail of today, the day without the year for mail of this year, and
        /// the day with the year for older mail, as Mail shows them.
        static func dateFormat(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Date.FormatStyle {
            var format = Date.FormatStyle.dateTime
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            if calendar.isDate(date, inSameDayAs: now) {
                return format.hour().minute()
            }
            if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                return format.month(.abbreviated).day()
            }
            return format.year().month(.abbreviated).day()
        }

        /// Needs reply while a reply is due, the deadline from the explanation's dates,
        /// Unsure project for a project the model chose, and Not sorted yet before sorting
        /// decided.
        static func marks(_ email: MailStore.Listed, deadline: String? = nil) -> [String] {
            var marks: [String] = []
            if case .reply? = email.reply {
                marks.append(String(localized: "Needs reply"))
            }
            if let deadline {
                marks.append(deadline)
            }
            switch email.level {
            case .likely?: marks.append(String(localized: "Unsure project"))
            case nil: marks.append(String(localized: "Not sorted yet"))
            default: break
            }
            return marks
        }
    }

    /// The items of an Assign to Project menu, in the list's context menu and on the email
    /// view's project chip: Needs a Project and the other projects. A click moves the email
    /// to that list in Orra, after the user's yes when the move takes a changed draft away,
    /// see ProjectsWindowModel.requestMove(_:to:). The words say assign, not move, since the
    /// email stays where it is in Mail.
    struct MoveMenuItems: View {
        let runtime: ProjectsRuntime
        let model: ProjectsWindowModel
        let email: MailStore.Listed

        var body: some View {
            if email.project != nil || email.level == .setAside {
                Button("Needs a Project") {
                    move(to: nil)
                }
            }
            ForEach(runtime.projectList.filter { $0.id != email.project }) { project in
                Button {
                    move(to: project.id)
                } label: {
                    Text(verbatim: project.name)
                }
            }
        }

        private func move(to project: UUID?) {
            let id = email.messageID
            Task { await model.requestMove(id, to: project) }
        }
    }

    /// The marks of an email, each in a capsule.
    struct Marks: View {
        let marks: [String]

        var body: some View {
            HStack(spacing: 6) {
                ForEach(marks, id: \.self) { mark in
                    Text(verbatim: mark)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The offer of a rule after two moves of the same kind.
    struct RuleOfferBar: View {
        let text: String
        let accept: () -> Void
        let decline: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add Rule", action: accept)
                    Button("Not Now", action: decline)
                }
            }
            .frame(minWidth: ProjectsWindowView.narrowestLineWidth, maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    /// The line under a list that shows only its newest emails, with how many it holds, and
    /// Load Older Emails.
    struct OlderEmailsBar: View {
        let shown: Int
        let total: Int
        let load: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(verbatim: ProjectsWindowText.olderEmails(shown: shown, total: total))
                    .foregroundStyle(.secondary)
                Button("Load Older Emails", action: load)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: ProjectsWindowView.narrowestLineWidth, maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom], 10)
        }
    }

    /// A line about mail coming into the window, see `StatusLines.mailLines(runtime:)`.
    nonisolated struct MailLine: Equatable, Sendable {
        /// What the button under the line does.
        nonisolated enum Action: Sendable {
            /// Starts the scan again at once, see ProjectsRuntime.readAgain().
            case tryAgain
            /// Opens Settings at the Projects page.
            case settings
            /// Opens the Mail app, on the user's click.
            case openMail
        }

        var text: String
        /// Whether Projects works on it now, which a spinner shows.
        var isActivity = false
        var action: Action?
    }

    /// A line about mail coming in, with a spinner while Projects works on it, and its
    /// button. Open Mail shows only with `openMail`.
    struct MailLineView: View {
        let line: MailLine
        let alignment: HorizontalAlignment
        let runtime: ProjectsRuntime
        let openSettings: () -> Void
        var openMail: (() -> Void)? = nil

        var body: some View {
            VStack(alignment: alignment, spacing: 6) {
                HStack(spacing: 8) {
                    if line.isActivity {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: line.text)
                }
                switch line.action {
                case .tryAgain?:
                    Button("Try Again") {
                        runtime.readAgain()
                    }
                case .settings?:
                    Button("Settings…", action: openSettings)
                case .openMail?:
                    if let openMail {
                        Button("Open Mail", action: openMail)
                    }
                case nil:
                    EmptyView()
                }
            }
        }
    }

    /// What the list says while it shows no mail, in place of No Mail when that would not
    /// be the whole story: that the store could not read it, with Try Again, or the lines
    /// about mail coming in. Else No Mail, and for a project how mail gets there.
    struct EmptyList: View {
        let runtime: ProjectsRuntime
        let model: ProjectsWindowModel
        let openSettings: () -> Void
        var openMail: (() -> Void)? = nil

        var body: some View {
            let lines = StatusLines.mailLines(runtime: runtime)
            if model.listFailed {
                VStack(spacing: 6) {
                    Text("This list could not be read.")
                    Button("Try Again") {
                        Task { await model.reload() }
                    }
                }
                .foregroundStyle(.secondary)
                .padding()
            } else if !lines.isEmpty {
                VStack(spacing: 16) {
                    ForEach(lines, id: \.text) { line in
                        MailLineView(line: line, alignment: .center, runtime: runtime, openSettings: openSettings, openMail: openMail)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            } else {
                ContentUnavailableView {
                    Label("No Mail", systemImage: "tray")
                } description: {
                    if case .project? = model.place {
                        Text("Choose an email in Needs a Project and assign it to this project with Assign to Project.")
                    }
                }
            }
        }
    }

    /// The lines under the list: the lines about mail coming in while the list shows mail,
    /// the line about the cleanup model while it is not on this Mac, Explain Message
    /// Selected in Mail at work, why the model work waits, and what the last action found.
    struct StatusLines: View {
        let runtime: ProjectsRuntime
        let model: ProjectsWindowModel
        let openSettings: () -> Void
        var openMail: (() -> Void)? = nil

        var body: some View {
            let lines = Self.lines(runtime: runtime, notice: model.notice)
            // While the list shows no mail, the lines about mail show in its middle instead,
            // see EmptyList.
            let mailLines = model.rows.isEmpty && !model.listFailed ? [] : Self.mailLines(runtime: runtime)
            // Under the list also while it shows no mail, since the model is not about mail.
            let modelLine = Self.modelLine(runtime: runtime)
            if !lines.isEmpty || !mailLines.isEmpty || modelLine != nil || runtime.phase == .failed || model.isReadingSelection {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    if runtime.phase == .failed {
                        HStack {
                            Text("Projects could not open its data on this Mac.")
                            Button("Try Again") {
                                runtime.retry()
                            }
                        }
                    }
                    ForEach(mailLines, id: \.text) { line in
                        MailLineView(line: line, alignment: .leading, runtime: runtime, openSettings: openSettings, openMail: openMail)
                    }
                    if let modelLine {
                        MailLineView(line: modelLine, alignment: .leading, runtime: runtime, openSettings: openSettings)
                    }
                    if model.isReadingSelection {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reading the message in Mail…")
                        }
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                    }
                    if Self.leadsToSettings(runtime: runtime, notice: model.notice) {
                        Button("Settings…", action: openSettings)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: ProjectsWindowView.narrowestLineWidth, maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], 10)
            }
        }

        /// What Projects does with mail now, reading or sorting it, then why it reads none
        /// or stopped reading: no mailbox confirmed, Mail not open, Orra not allowed to
        /// control Mail, Mail slow to answer, or mail that could not be read. Try Again goes
        /// with the last two, where asking Mail again helps, and Open Mail with Mail not
        /// open.
        static func mailLines(runtime: ProjectsRuntime) -> [MailLine] {
            guard runtime.phase == .on else { return [] }
            var lines: [MailLine] = []
            if let state = runtime.scanState, case .reading = state {
                lines.append(MailLine(text: ProjectsWindowText.scan(state), isActivity: true))
            } else if runtime.isSorting {
                lines.append(MailLine(text: String(localized: "Sorting mail…"), isActivity: true))
            }
            if !runtime.choice.isConfirmed {
                lines.append(MailLine(text: ProjectsWindowText.selection(.noMailboxChosen), action: .settings))
            } else if !runtime.mailIsRunning {
                lines.append(MailLine(text: String(localized: "Mail is not open. Projects reads new mail while Mail runs."), action: .openMail))
            } else if let state = runtime.scanState {
                switch state {
                case .reading: break
                case .mailIsSlow, .failed: lines.append(MailLine(text: ProjectsWindowText.scan(state), action: .tryAgain))
                case .notAllowed: lines.append(MailLine(text: ProjectsWindowText.scan(state), action: .settings))
                }
            }
            return lines
        }

        /// The line about the cleanup model while it is not on this Mac: its download or the
        /// check of its files with a spinner, or Settings… while it is missing, where it
        /// downloads. The email view still says so too when Explain finds no model.
        static func modelLine(runtime: ProjectsRuntime) -> MailLine? {
            guard runtime.phase == .on else { return nil }
            let status = runtime.dependencies.modelDownloadStatus()
            guard let text = ProjectsWindowText.modelLine(status) else { return nil }
            let isMissing = status == .missing
            return MailLine(text: text, isActivity: !isMissing, action: isMissing ? .settings : nil)
        }

        /// Whether the notice sends the user to Settings: Orra not allowed to control Mail,
        /// or a message in a mailbox Projects does not read or no mailbox chosen. Not when
        /// a line about mail says the same, which has the button.
        static func leadsToSettings(runtime: ProjectsRuntime, notice: ProjectsWindowModel.Notice?) -> Bool {
            guard runtime.phase == .on, noticeLine(runtime: runtime, notice: notice) != nil else { return false }
            switch notice {
            case .selection(.notAllowed)?, .selection(.notInChosenMailbox)?, .selection(.noMailboxChosen)?: return true
            default: return false
            }
        }

        /// Why the model work waits, and what the last action found.
        static func lines(runtime: ProjectsRuntime, notice: ProjectsWindowModel.Notice?) -> [String] {
            var lines: [String] = []
            if let pause = runtime.pause {
                lines.append(ProjectsWindowText.pause(pause))
            }
            if let line = noticeLine(runtime: runtime, notice: notice) {
                lines.append(line)
            }
            return lines
        }

        /// The notice's line, nil when it says nothing or a line about mail says the same.
        private static func noticeLine(runtime: ProjectsRuntime, notice: ProjectsWindowModel.Notice?) -> String? {
            guard let notice else { return nil }
            let line = ProjectsWindowText.notice(notice)
            guard !line.isEmpty, !mailLines(runtime: runtime).contains(where: { $0.text == line }) else { return nil }
            return line
        }
    }
}
