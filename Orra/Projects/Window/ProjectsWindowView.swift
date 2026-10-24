import SwiftUI

/// The Projects window in three columns: the projects with Needs a Project and Set Aside,
/// the mail of the chosen one, and the selected email or the project's page.
///
/// Mail text, names and model output show with `Text(verbatim:)` only: no Markdown, no
/// links, no images (plan section 2.8). The third column holds the email view,
/// ProjectsEmailArea, or the project's page.
struct ProjectsWindowView: View {
    let runtime: ProjectsRuntime
    @State var model: ProjectsWindowModel
    /// Opens Settings at the Projects page.
    let openSettings: () -> Void
    /// The project being set up, nil while no setup sheet shows.
    @State private var setup: ProjectsSetupView.Draft?
    @State private var forgetting: Project?

    /// Reads the list again when another list is chosen or the mail changed.
    private struct Reload: Hashable {
        var place: MailStore.Place?
        var changes: Int
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            mailColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            detail
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
                    Label("Explain Selected Message", systemImage: "envelope.badge")
                }
                .help("Explain Selected Message")
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
            Text("This removes the project with its index, mail and drafts from Projects. Your mail in Mail and the files in its folders stay as they are.")
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
            List(model.rows, id: \.messageID, selection: $model.selectedMessageID) { email in
                MailRow(email: email, deadline: model.deadlines[email.messageID].flatMap { ProjectsWindowText.deadline($0, now: runtime.dependencies.now()) })
                    .contextMenu {
                        moveMenu(email)
                    }
            }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView("No Mail", systemImage: "tray")
                }
            }
            StatusLines(runtime: runtime, model: model, openSettings: openSettings)
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
            ProjectsEmailArea(runtime: runtime, model: model, email: email)
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
            ContentUnavailableView("No Email Selected", systemImage: "envelope")
        }
    }
}

// MARK: Rows and lines

extension ProjectsWindowView {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    /// The lines under the list: why the model work waits, whether Mail is open, whether
    /// Projects reads mail yet, Explain Selected Message at work, and what the last action
    /// found.
    struct StatusLines: View {
        let runtime: ProjectsRuntime
        let model: ProjectsWindowModel
        let openSettings: () -> Void

        var body: some View {
            let lines = Self.lines(runtime: runtime, notice: model.notice)
            if !lines.isEmpty || runtime.phase == .failed || model.isReadingSelection {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], 10)
            }
        }

        /// Whether a line sends the user to Settings: no mailbox confirmed, Orra not allowed
        /// to control Mail, or a message in a mailbox Projects does not read.
        static func leadsToSettings(runtime: ProjectsRuntime, notice: ProjectsWindowModel.Notice?) -> Bool {
            guard runtime.phase == .on else { return false }
            switch notice {
            case .selection(.notAllowed)?, .selection(.notInChosenMailbox)?, .selection(.noMailboxChosen)?: return true
            default: return !runtime.choice.isConfirmed
            }
        }

        static func lines(runtime: ProjectsRuntime, notice: ProjectsWindowModel.Notice?) -> [String] {
            var lines: [String] = []
            if let pause = runtime.pause {
                lines.append(ProjectsWindowText.pause(pause))
            }
            if runtime.phase == .on {
                if !runtime.choice.isConfirmed {
                    lines.append(ProjectsWindowText.selection(.noMailboxChosen))
                } else if !runtime.mailIsRunning {
                    lines.append(String(localized: "Mail is not open. Projects reads new mail while Mail runs."))
                }
            }
            if let notice {
                let line = ProjectsWindowText.notice(notice)
                if !line.isEmpty, !lines.contains(line) {
                    lines.append(line)
                }
            }
            return lines
        }
    }
}
